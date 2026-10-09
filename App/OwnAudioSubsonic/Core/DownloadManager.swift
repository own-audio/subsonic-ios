import Foundation
import Observation
import PlayerEngine
import SubsonicKit

/// Songs kept on the phone for offline listening, and the albums and playlists they were
/// downloaded as.
///
/// Files live in Application Support, which iOS doesn't clear the way it clears Caches, and are
/// excluded from iCloud backup: they can always be downloaded again. An index file records what
/// each file is, so the Downloads screen works with no network at all.
@Observable
@MainActor
final class DownloadManager {
    enum State: Equatable {
        case queued
        case downloading
        case downloaded
        case failed(String)
    }

    struct DownloadedTrack: Codable, Equatable {
        let trackId: String
        let song: Song
        let fileName: String
        let bytes: Int64
        let downloadedAt: Date
    }

    /// An album or playlist downloaded as a whole, in its own order.
    struct Collection: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case album, playlist }
        let id: String
        let kind: Kind
        let serverId: UUID
        let itemId: String
        let name: String
        let artist: String?
        let coverArt: String?
        var trackIds: [String]
    }

    private struct Index: Codable {
        var tracks: [String: DownloadedTrack] = [:]
        var collections: [String: Collection] = [:]
        /// Waiting or interrupted, in order; resumed on the next launch.
        var queue: [QueuedTrack] = []
    }

    struct QueuedTrack: Codable, Equatable {
        let trackId: String
        let song: Song
    }

    private(set) var tracks: [String: DownloadedTrack] = [:]
    private(set) var collections: [String: Collection] = [:]
    private(set) var states: [String: State] = [:]

    /// Read by the engine's resolver off the main actor.
    let files: LocalFileIndex
    private let directory: URL
    private let indexURL: URL
    private var queue: [QueuedTrack] = []
    private var running: [String: Task<Void, Never>] = [:]
    private let registry: ClientRegistry
    private let session: URLSession
    private static let parallelDownloads = 2

    init(registry: ClientRegistry, root: URL? = nil) {
        self.registry = registry
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("Downloads", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: configuration)
        files = LocalFileIndex()
        loadIndex()
    }

    // MARK: - Reading

    var totalBytes: Int64 { tracks.values.reduce(0) { $0 + $1.bytes } }

    func state(of trackId: String) -> State? { states[trackId] }

    func isDownloaded(_ trackId: String) -> Bool { tracks[trackId] != nil }

    /// Downloaded songs that belong to no downloaded album or playlist.
    var looseTracks: [DownloadedTrack] {
        let inCollections = Set(collections.values.flatMap(\.trackIds))
        return tracks.values.filter { !inCollections.contains($0.trackId) }.sorted { $0.downloadedAt > $1.downloadedAt }
    }

    /// The collection's songs that are on the phone, in its order.
    func songs(in collection: Collection) -> [DownloadedTrack] {
        collection.trackIds.compactMap { tracks[$0] }
    }

    /// How far a collection has got: (downloaded, total).
    func progress(of collectionId: String) -> (done: Int, total: Int)? {
        guard let collection = collections[collectionId] else { return nil }
        return (collection.trackIds.filter { tracks[$0] != nil }.count, collection.trackIds.count)
    }

    static func collectionId(kind: Collection.Kind, serverId: UUID, itemId: String) -> String {
        "\(kind.rawValue):\(TrackID.make(serverId: serverId, itemId: itemId))"
    }

    // MARK: - Changing

    func download(songs: [Song], serverId: UUID) {
        for song in songs {
            let trackId = TrackID.make(serverId: serverId, itemId: song.id)
            guard tracks[trackId] == nil, !queue.contains(where: { $0.trackId == trackId }) else { continue }
            queue.append(QueuedTrack(trackId: trackId, song: song))
            states[trackId] = .queued
        }
        saveIndex()
        pump()
    }

    func download(album: Album, songs: [Song], serverId: UUID) {
        let id = Self.collectionId(kind: .album, serverId: serverId, itemId: album.id)
        collections[id] = Collection(
            id: id, kind: .album, serverId: serverId, itemId: album.id, name: album.name,
            artist: album.artist, coverArt: album.coverArt ?? album.id,
            trackIds: songs.map { TrackID.make(serverId: serverId, itemId: $0.id) }
        )
        download(songs: songs, serverId: serverId)
    }

    func download(playlist: Playlist, songs: [Song], serverId: UUID) {
        let id = Self.collectionId(kind: .playlist, serverId: serverId, itemId: playlist.id)
        collections[id] = Collection(
            id: id, kind: .playlist, serverId: serverId, itemId: playlist.id, name: playlist.name,
            artist: nil, coverArt: playlist.coverArt,
            trackIds: songs.map { TrackID.make(serverId: serverId, itemId: $0.id) }
        )
        download(songs: songs, serverId: serverId)
    }

    /// Removes a song's file, unless another downloaded album or playlist still needs it.
    func remove(trackId: String) {
        let stillNeeded = collections.values.contains { $0.trackIds.contains(trackId) }
        if !stillNeeded { deleteFile(trackId) }
        saveIndex()
    }

    func remove(collectionId: String) {
        guard let collection = collections.removeValue(forKey: collectionId) else { return }
        let stillNeeded = Set(collections.values.flatMap(\.trackIds))
        for trackId in collection.trackIds where !stillNeeded.contains(trackId) {
            cancel(trackId)
            deleteFile(trackId)
        }
        saveIndex()
    }

    func removeAll(serverId: UUID? = nil) {
        let doomed = tracks.keys.filter { serverId == nil || TrackID.parse($0)?.serverId == serverId }
            + queue.map(\.trackId).filter { serverId == nil || TrackID.parse($0)?.serverId == serverId }
        collections = collections.filter { serverId != nil && $0.value.serverId != serverId }
        for trackId in Set(doomed) {
            cancel(trackId)
            deleteFile(trackId)
        }
        saveIndex()
    }

    /// Tries failed downloads again.
    func retryFailed() {
        for item in queue {
            if case .failed? = states[item.trackId] { states[item.trackId] = .queued }
        }
        pump()
    }

    var failedCount: Int {
        queue.filter { if case .failed? = states[$0.trackId] { true } else { false } }.count
    }

    var pendingCount: Int {
        queue.filter { states[$0.trackId] == .queued || states[$0.trackId] == .downloading }.count
    }

    // MARK: - Work

    private func pump() {
        let waiting = queue.filter { states[$0.trackId] == .queued && running[$0.trackId] == nil }
        let free = Self.parallelDownloads - running.count
        for item in waiting.prefix(max(free, 0)) {
            states[item.trackId] = .downloading
            running[item.trackId] = Task { await self.fetch(item) }
        }
    }

    private func fetch(_ item: QueuedTrack) async {
        defer {
            running[item.trackId] = nil
            pump()
        }
        do {
            let url = try await registry.streamURL(trackId: item.trackId)
            let (temp, response) = try await session.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: temp)
                throw URLError(.badServerResponse)
            }
            let head = (try? FileHandle(forReadingFrom: temp)).flatMap { handle in
                defer { try? handle.close() }
                return try? handle.read(upToCount: 12)
            } ?? Data()
            // Subsonic reports errors as HTTP 200 with JSON; that must not be saved as a song.
            guard let ext = TrackFileCache.fileExtension(prefix: head)
                    ?? TrackFileCache.fileExtension(mimeType: http.mimeType) else {
                try? FileManager.default.removeItem(at: temp)
                throw URLError(.cannotDecodeContentData)
            }
            guard !Task.isCancelled, queue.contains(where: { $0.trackId == item.trackId }) else {
                try? FileManager.default.removeItem(at: temp)
                return
            }
            let fileName = "\(Self.safeName(item.trackId)).\(ext)"
            let destination = directory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

            let track = DownloadedTrack(trackId: item.trackId, song: item.song, fileName: fileName, bytes: bytes, downloadedAt: Date())
            tracks[item.trackId] = track
            files.set(item.trackId, destination)
            states[item.trackId] = .downloaded
            queue.removeAll { $0.trackId == item.trackId }
            saveIndex()
        } catch is CancellationError {
            return
        } catch {
            guard queue.contains(where: { $0.trackId == item.trackId }) else { return }
            states[item.trackId] = .failed(error.userMessage)
        }
    }

    private func cancel(_ trackId: String) {
        running[trackId]?.cancel()
        running[trackId] = nil
        queue.removeAll { $0.trackId == trackId }
        states[trackId] = nil
    }

    private func deleteFile(_ trackId: String) {
        cancel(trackId)
        if let track = tracks.removeValue(forKey: trackId) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(track.fileName))
        }
        files.set(trackId, nil)
        states[trackId] = nil
    }

    // MARK: - Index

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(Index.self, from: data)
        else { return }
        // A file the index lists but the disk lost (restored backup, manual cleanup) isn't
        // downloaded any more.
        tracks = index.tracks.filter {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.value.fileName).path)
        }
        collections = index.collections
        queue = index.queue
        for track in tracks.values {
            states[track.trackId] = .downloaded
            files.set(track.trackId, directory.appendingPathComponent(track.fileName))
        }
        for item in queue { states[item.trackId] = .queued }
        if tracks.count != index.tracks.count { saveIndex() }
    }

    /// Resumes what was waiting when the app last stopped.
    func resume() {
        pump()
    }

    private func saveIndex() {
        let index = Index(tracks: tracks, collections: collections, queue: queue)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func safeName(_ trackId: String) -> String {
        Data(trackId.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }
}

/// Track id → local file, readable from any thread: the engine asks from its own tasks.
final class LocalFileIndex: @unchecked Sendable {
    private var files: [String: URL] = [:]
    private let lock = NSLock()

    func set(_ trackId: String, _ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        files[trackId] = url
    }

    func url(for trackId: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return files[trackId]
    }
}
