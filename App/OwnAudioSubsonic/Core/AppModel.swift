import Foundation
import Observation
import PlayerEngine
import SubsonicKit

/// The app's single source of truth: configured servers, which one is being browsed, and the
/// one shared player. Built once, in the `App`.
@Observable
@MainActor
final class AppModel {
    private(set) var servers: [ServerRecord] = []
    private(set) var hasLoaded = false
    private(set) var activeServerId: UUID? {
        didSet { UserDefaults.standard.set(activeServerId?.uuidString, forKey: Self.activeServerKey) }
    }

    let engine: PlaybackEngine
    let playbackSettings: PlaybackSettingsStore
    let equalizer: EqualizerStore
    let covers: CoverArtLoader
    let resumeStore: ResumeStore

    private let store: ServerStore
    private let registry: ClientRegistry
    private let fileCache: TrackFileCache
    private var clients: [UUID: SubsonicClient] = [:]

    private static let activeServerKey = "activeServerId"

    init(store: ServerStore = ServerStore()) {
        self.store = store
        let registry = ClientRegistry()
        self.registry = registry
        covers = CoverArtLoader(registry: registry)
        fileCache = TrackFileCache(remoteURL: { try await registry.streamURL(trackId: $0) })
        playbackSettings = PlaybackSettingsStore()
        equalizer = EqualizerStore()
        resumeStore = UserDefaultsResumeStore()
        engine = PlaybackEngine(
            fileCache: fileCache,
            nowPlayingController: NowPlayingController(),
            settingsStore: playbackSettings,
            equalizerStore: equalizer,
            resumeStore: resumeStore
        )
        let covers = covers
        engine.artworkProvider = { track in
            guard let artworkId = track.artworkId else { return nil }
            return await covers.data(artworkId: artworkId, size: 600)
        }
    }

    var activeServer: ServerRecord? {
        servers.first { $0.id == activeServerId }
    }

    var activeClient: SubsonicClient? {
        activeServerId.flatMap { clients[$0] }
    }

    func load() async {
        // UI tests start from a clean slate; the Keychain survives reinstalling the app.
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            await store.clear()
            UserDefaults.standard.removeObject(forKey: Self.activeServerKey)
            await covers.clear()
        }
        servers = await store.loadAll()
        await rebuildClients()
        let saved = UserDefaults.standard.string(forKey: Self.activeServerKey).flatMap(UUID.init)
        activeServerId = servers.contains { $0.id == saved } ? saved : servers.first?.id
        hasLoaded = true
    }

    /// Checks the credentials against the server before saving anything, so a typo is caught
    /// here rather than on the first screen that fails.
    func addServer(address: String, username: String, password: String, name: String) async throws {
        guard let host = SubsonicClient.normalizeHost(address) else { throw AddServerError.invalidAddress }
        let client = SubsonicClient(host: host, username: username, password: password)
        switch await client.checkConnection() {
        case .ok: break
        case .rejected: throw AddServerError.rejected
        case .unreachable: throw AddServerError.unreachable
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = ServerRecord(
            displayName: trimmedName.isEmpty ? (host.host ?? address) : trimmedName,
            credentials: ServerCredentials(host: host, username: username, password: password)
        )
        try await store.add(record)
        servers.append(record)
        await rebuildClients()
        activeServerId = record.id
    }

    func removeServer(id: UUID) async throws {
        try await store.remove(id: id)
        servers.removeAll { $0.id == id }
        if let track = engine.currentTrack, TrackID.parse(track.id)?.serverId == id { engine.stop() }
        await rebuildClients()
        if activeServerId == id { activeServerId = servers.first?.id }
    }

    func renameServer(id: UUID, to name: String) async throws {
        try await store.rename(id: id, to: name)
        if let index = servers.firstIndex(where: { $0.id == id }) { servers[index].displayName = name }
    }

    func selectServer(id: UUID) {
        guard servers.contains(where: { $0.id == id }) else { return }
        activeServerId = id
    }

    func checkConnection(id: UUID) async -> ConnectionStatus {
        guard let client = clients[id] else { return .unreachable }
        return await client.checkConnection()
    }

    /// Plays `songs` from the active server, starting at `startSongId` or the first song.
    /// `containerId` ("album:…") lets the engine remember where in it listening stopped.
    func play(_ songs: [Song], startSongId: String? = nil, shuffled: Bool = false, containerId: String? = nil) {
        guard let serverId = activeServerId, !songs.isEmpty else { return }
        let tracks = songs.map { $0.track(serverId: serverId) }
        engine.setShuffled(shuffled)
        Task {
            await engine.play(
                tracks: tracks,
                startTrackId: startSongId.map { TrackID.make(serverId: serverId, itemId: $0) },
                containerId: containerId.map { "\(serverId.uuidString)|\($0)" }
            )
        }
    }

    private func rebuildClients() async {
        clients = Dictionary(uniqueKeysWithValues: servers.map { record in
            (record.id, SubsonicClient(
                host: record.credentials.host, username: record.credentials.username,
                password: record.credentials.password
            ))
        })
        await registry.set(clients)
    }
}

enum AddServerError: LocalizedError {
    case invalidAddress, rejected, unreachable

    var errorDescription: String? {
        switch self {
        case .invalidAddress: String(localized: "That doesn't look like a server address.")
        case .rejected: String(localized: "The server didn't accept that username and password.")
        case .unreachable: String(localized: "Couldn't reach the server. Check the address, and that this phone can reach it.")
        }
    }
}

extension Error {
    /// A short sentence for a failed request.
    var userMessage: String {
        guard let error = self as? SubsonicClient.SubsonicError else {
            return String(localized: "Something went wrong.")
        }
        switch error {
        case .wrongCredentials, .notAuthorized:
            return String(localized: "The server no longer accepts this sign-in. Check it in Settings.")
        case .http(let code):
            return String(localized: "The server returned an error (\(code)).")
        case .server(_, let message):
            return message.isEmpty ? String(localized: "The server returned an error.") : message
        case .decoding:
            return String(localized: "The server's answer couldn't be read. Is this a Subsonic server?")
        case .network:
            return String(localized: "Couldn't reach the server.")
        }
    }
}
