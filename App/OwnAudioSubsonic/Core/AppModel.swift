import Foundation
import Observation
import MusicEngine
import SubsonicKit

/// The app's single source of truth: configured servers, which one is being browsed, and the
/// one shared player. Built once, in the `App`.
@Observable
@MainActor
final class AppModel {
    /// One per process: the phone UI and CarPlay drive the same player.
    static let shared = AppModel()

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
    let downloads: DownloadManager

    /// Starred songs, albums and artists, as composite ids (`TrackID`), learned from whatever
    /// the screens have loaded and kept current when the listener stars or unstars.
    private(set) var starredIds: Set<String> = []
    /// Ratings 1–5 by composite id, learned the same way.
    private(set) var ratings: [String: Int] = [:]

    /// A failed action (star, rate, playlist edit), shown once as an alert by `RootView`.
    var actionError: String?

    /// Runs a user action and reports a failure in the shared alert.
    func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                actionError = error.userMessage
            }
        }
    }

    /// Set by the listener: play and show only downloaded music, even with a network.
    var downloadedOnly: Bool {
        didSet {
            UserDefaults.standard.set(downloadedOnly, forKey: Self.downloadedOnlyKey)
            applyOfflineState()
        }
    }

    let network = NetworkMonitor()

    /// No network, or the listener chose downloaded music only. Screens then show what is on the
    /// phone and what was seen before, and the player passes over songs that aren't downloaded.
    var isOffline: Bool {
        downloadedOnly || !network.isConnected || Self.isSimulatingOffline
    }

    /// The listener chose it, rather than the network being gone.
    var isOfflineByChoice: Bool { downloadedOnly && network.isConnected && !Self.isSimulatingOffline }

    private func applyOfflineState() {
        offlineSwitch.isOn = isOffline
        engine.requiresLocalFiles = isOffline
    }

    /// Report "now playing" and counted plays to the server.
    var scrobblingEnabled: Bool {
        didSet { UserDefaults.standard.set(scrobblingEnabled, forKey: Self.scrobblingKey) }
    }

    private let store: ServerStore
    private let registry: ClientRegistry
    private let fileCache: TrackFileCache
    private var clients: [UUID: SubsonicClient] = [:]
    /// OpenSubsonic extensions per server, asked for once.
    private var extensions: [UUID: Set<String>] = [:]

    private static let activeServerKey = "activeServerId"
    private static let scrobblingKey = "scrobblingEnabled"
    private static let downloadedOnlyKey = "downloadedOnly"

    /// UI tests check offline behaviour by starting the app as if there were no network.
    private static var isSimulatingOffline: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-simulateOffline")
        #else
        false
        #endif
    }
    private var scrobbler: ScrobbleTracker?
    private var scrobbleTickTask: Task<Void, Never>?
    private let pendingScrobbles = PendingScrobbles()
    private let responseCache = DiskResponseCache()
    private let offlineSwitch = OfflineSwitch()
    /// Short timeouts: on a network that is there but goes nowhere, the default minute per
    /// request looks like a frozen app.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    init(store: ServerStore = ServerStore()) {
        self.store = store
        let registry = ClientRegistry()
        self.registry = registry
        covers = CoverArtLoader(registry: registry, offline: offlineSwitch)
        downloads = DownloadManager(registry: registry)
        fileCache = TrackFileCache(remoteURL: { try await registry.streamURL(trackId: $0) }, session: Self.session)
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
        scrobblingEnabled = UserDefaults.standard.object(forKey: Self.scrobblingKey) as? Bool ?? true
        downloadedOnly = UserDefaults.standard.bool(forKey: Self.downloadedOnlyKey)
        applyOfflineState()
        network.onChange = { [weak self] connected in
            guard let self else { return }
            self.applyOfflineState()
            if connected { Task { await self.flushPendingScrobbles() } }
        }
        wireScrobbling()
        // A downloaded song plays from the phone whether or not the server can be reached.
        let files = downloads.files
        let fileCache = fileCache
        Task { await fileCache.setLocalFileLookup { files.url(for: $0) } }
    }

    var activeServer: ServerRecord? {
        servers.first { $0.id == activeServerId }
    }

    var activeClient: SubsonicClient? {
        activeServerId.flatMap { clients[$0] }
    }

    private var loadTask: Task<Void, Never>?

    /// Loads once, however many callers ask: the phone UI and CarPlay can both start the app.
    func load() async {
        if let loadTask { return await loadTask.value }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        // UI tests start from a clean slate; the Keychain survives reinstalling the app.
        if ProcessInfo.processInfo.arguments.contains("-uiTestReset") {
            await store.clear()
            UserDefaults.standard.removeObject(forKey: Self.activeServerKey)
            await covers.clear()
            downloads.removeAll()
            responseCache.removeAll()
        }
        servers = await store.loadAll()
        await addServerFromLaunchArguments()
        await rebuildClients()
        let saved = UserDefaults.standard.string(forKey: Self.activeServerKey).flatMap(UUID.init)
        activeServerId = servers.contains { $0.id == saved } ? saved : servers.first?.id
        hasLoaded = true
        downloads.resume()
        await flushPendingScrobbles()
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
        downloads.removeAll(serverId: id)
        // Saved answers are keyed by server; this server's are of no further use, and it is
        // simpler to let the others be fetched again than to pick them apart.
        responseCache.removeAll()
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
    /// Offline, only the downloaded ones; a tapped song that isn't downloaded starts the list at
    /// the next one that is.
    func play(_ songs: [Song], startSongId: String? = nil, shuffled: Bool = false, containerId: String? = nil) {
        guard let serverId = activeServerId, !songs.isEmpty else { return }
        var songs = songs
        var startSongId = startSongId
        if isOffline {
            let isLocal = { (song: Song) in self.downloads.isDownloaded(TrackID.make(serverId: serverId, itemId: song.id)) }
            if let start = startSongId, let index = songs.firstIndex(where: { $0.id == start }), !isLocal(songs[index]) {
                startSongId = songs[index...].first(where: isLocal)?.id
            }
            songs = songs.filter(isLocal)
            guard !songs.isEmpty else {
                actionError = String(localized: "You're offline, and none of these songs are downloaded.")
                return
            }
        }
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

    /// Debug builds only: `-debugServerHost <url> -debugServerUser <name> -debugServerPassword <secret>`
    /// adds that server at launch if it isn't there yet, so a simulator can be handed to someone
    /// already connected.
    private func addServerFromLaunchArguments() async {
        #if DEBUG
        let defaults = UserDefaults.standard
        guard let address = defaults.string(forKey: "debugServerHost"),
              let username = defaults.string(forKey: "debugServerUser"),
              let password = defaults.string(forKey: "debugServerPassword"),
              let host = SubsonicClient.normalizeHost(address)
        else { return }
        if let existing = servers.first(where: { $0.credentials.host == host && $0.credentials.username == username }) {
            // The demo server issues a new key each day; keep the saved one current.
            guard existing.credentials.password != password else { return }
            try? await store.remove(id: existing.id)
            servers.removeAll { $0.id == existing.id }
        }
        let record = ServerRecord(
            displayName: defaults.string(forKey: "debugServerName") ?? host.host ?? address,
            credentials: ServerCredentials(host: host, username: username, password: password)
        )
        try? await store.add(record)
        servers.append(record)
        UserDefaults.standard.set(record.id.uuidString, forKey: Self.activeServerKey)
        #endif
    }

    // MARK: - Scrobbling

    private func wireScrobbling() {
        let scrobbler = ScrobbleTracker { [weak self] event in self?.report(event) }
        self.scrobbler = scrobbler
        engine.onPlaybackStarted = { [weak self] track, _ in
            guard let self, self.scrobblingEnabled else { return }
            scrobbler.started(key: track.id, durationSecs: track.durationSecs)
            self.startScrobbleTicks()
        }
        engine.onPlaybackStopped = { [weak self] track, _, reason in
            guard let self, self.scrobblingEnabled else { return }
            let isEnd: Bool = switch reason {
            case .completed, .skipped, .replaced: true
            case .stopped, .seeked: false
            }
            scrobbler.stopped(key: track.id, isEnd: isEnd)
        }
    }

    /// Counts a play while it is still playing, so it isn't lost if the app is killed.
    private func startScrobbleTicks() {
        guard scrobbleTickTask == nil else { return }
        scrobbleTickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                if self.engine.isPlaying { self.scrobbler?.tick() }
            }
        }
    }

    private func report(_ event: ScrobbleTracker.Event) {
        Task {
            switch event {
            case .nowPlaying(let trackId):
                guard let (client, songId) = await resolve(trackId) else { return }
                try? await client.scrobble(songId: songId, submission: false)
            case .played(let trackId, let startedAt):
                let entry = PendingScrobbles.Entry(trackId: trackId, startedAt: startedAt)
                if await submit(entry) {
                    await flushPendingScrobbles()
                } else {
                    pendingScrobbles.add(entry)
                }
            }
        }
    }

    private func submit(_ entry: PendingScrobbles.Entry) async -> Bool {
        guard let (client, songId) = await resolve(entry.trackId) else {
            // The server was removed; there's nowhere to report it.
            return true
        }
        do {
            try await client.scrobble(songId: songId, submission: true, time: entry.startedAt)
            return true
        } catch {
            return false
        }
    }

    /// Sends plays that couldn't be reported earlier. Called after a play goes through, and on
    /// launch.
    func flushPendingScrobbles() async {
        var sent: [PendingScrobbles.Entry] = []
        for entry in pendingScrobbles.all {
            guard await submit(entry) else { break }
            sent.append(entry)
        }
        pendingScrobbles.remove(sent)
    }

    private func resolve(_ trackId: String) async -> (SubsonicClient, String)? {
        guard let (serverId, songId) = TrackID.parse(trackId), let client = clients[serverId] else { return nil }
        return (client, songId)
    }

    // MARK: - Favorites and ratings

    /// Remembers star and rating state from loaded songs, so every screen shows it.
    func learn(songs: [Song]) {
        guard let serverId = activeServerId else { return }
        for song in songs {
            let id = TrackID.make(serverId: serverId, itemId: song.id)
            if song.starred != nil { starredIds.insert(id) } else { starredIds.remove(id) }
            ratings[id] = song.userRating
        }
    }

    func learn(albums: [Album]) {
        guard let serverId = activeServerId else { return }
        for album in albums {
            let id = TrackID.make(serverId: serverId, itemId: album.id)
            if album.starred != nil { starredIds.insert(id) } else { starredIds.remove(id) }
            ratings[id] = album.userRating
        }
    }

    func noteStarred(_ compositeId: String) {
        starredIds.insert(compositeId)
    }

    func isStarred(_ compositeId: String) -> Bool {
        starredIds.contains(compositeId)
    }

    enum StarTarget { case song, album, artist }

    /// Flips the star at once and puts it back if the server refuses.
    func toggleStar(_ compositeId: String, kind: StarTarget) async throws {
        guard let (client, itemId) = await resolve(compositeId) else { return }
        let starring = !starredIds.contains(compositeId)
        if starring { starredIds.insert(compositeId) } else { starredIds.remove(compositeId) }
        do {
            let ids = [itemId]
            switch (kind, starring) {
            case (.song, true): try await client.star(songIds: ids)
            case (.song, false): try await client.unstar(songIds: ids)
            case (.album, true): try await client.star(albumIds: ids)
            case (.album, false): try await client.unstar(albumIds: ids)
            case (.artist, true): try await client.star(artistIds: ids)
            case (.artist, false): try await client.unstar(artistIds: ids)
            }
        } catch {
            if starring { starredIds.remove(compositeId) } else { starredIds.insert(compositeId) }
            throw error
        }
    }

    /// `rating` 1–5, or 0 to clear it.
    func setRating(_ compositeId: String, rating: Int) async throws {
        guard let (client, itemId) = await resolve(compositeId) else { return }
        let previous = ratings[compositeId]
        ratings[compositeId] = rating == 0 ? nil : rating
        do {
            try await client.setRating(id: itemId, rating: rating)
        } catch {
            ratings[compositeId] = previous
            throw error
        }
    }

    /// The playing track may have come from a screen that didn't know its star state.
    func refreshState(trackId: String) async {
        guard let (client, songId) = await resolve(trackId),
              let song = try? await client.song(id: songId),
              let serverId = TrackID.parse(trackId)?.serverId
        else { return }
        let id = TrackID.make(serverId: serverId, itemId: song.id)
        if song.starred != nil { starredIds.insert(id) } else { starredIds.remove(id) }
        ratings[id] = song.userRating
    }

    func compositeId(_ itemId: String) -> String? {
        activeServerId.map { TrackID.make(serverId: $0, itemId: itemId) }
    }

    // MARK: - Lyrics

    func lyrics(for track: Track) async throws -> [Lyrics] {
        guard let (client, songId) = await resolve(track.id), let serverId = TrackID.parse(track.id)?.serverId else { return [] }
        if extensions[serverId] == nil { extensions[serverId] = await client.openSubsonicExtensions() }
        let song = Song(id: songId, title: track.title, album: track.album, artist: track.artist)
        return try await client.lyrics(for: song, useSongLyricsExtension: extensions[serverId]?.contains("songLyrics") == true)
    }

    // MARK: - Downloads

    func download(album: Album, songs: [Song]) {
        guard let serverId = activeServerId else { return }
        downloads.download(album: album, songs: songs, serverId: serverId)
        prefetchCovers([album.coverArt ?? album.id] + songs.compactMap { $0.coverArt ?? $0.albumId }, serverId: serverId)
    }

    func download(playlist: Playlist, songs: [Song]) {
        guard let serverId = activeServerId else { return }
        downloads.download(playlist: playlist, songs: songs, serverId: serverId)
        prefetchCovers([playlist.coverArt].compactMap { $0 } + songs.compactMap { $0.coverArt ?? $0.albumId }, serverId: serverId)
    }

    func download(songs: [Song]) {
        guard let serverId = activeServerId else { return }
        downloads.download(songs: songs, serverId: serverId)
        prefetchCovers(songs.compactMap { $0.coverArt ?? $0.albumId }, serverId: serverId)
    }

    /// Covers at the sizes the screens ask for, so a downloaded album looks the same offline.
    private func prefetchCovers(_ coverIds: [String], serverId: UUID) {
        let covers = covers
        let ids = Array(Set(coverIds)).map { TrackID.make(serverId: serverId, itemId: $0) }
        Task.detached(priority: .utility) {
            for id in ids {
                for size in [120, 300, 600, 1000] { _ = await covers.image(artworkId: id, size: size) }
            }
        }
    }

    /// Plays downloaded songs, each from the server it came from, whichever is selected.
    func play(downloaded: [DownloadManager.DownloadedTrack], startTrackId: String? = nil, shuffled: Bool = false, containerId: String? = nil) {
        let tracks = downloaded.compactMap { item -> Track? in
            guard let serverId = TrackID.parse(item.trackId)?.serverId else { return nil }
            return item.song.track(serverId: serverId)
        }
        guard !tracks.isEmpty else { return }
        engine.setShuffled(shuffled)
        Task { await engine.play(tracks: tracks, startTrackId: startTrackId, containerId: containerId) }
    }

    private func rebuildClients() async {
        clients = Dictionary(uniqueKeysWithValues: servers.map { record in
            (record.id, SubsonicClient(
                host: record.credentials.host,
                username: record.credentials.username, password: record.credentials.password,
                session: Self.session, cache: responseCache, offline: offlineSwitch
            ))
        })
        await registry.set(clients)
        extensions = [:]
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
        case .offline:
            return String(localized: "Not available offline.")
        }
    }
}
