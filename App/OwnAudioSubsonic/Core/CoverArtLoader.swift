import Foundation
import SubsonicKit
import UIKit

/// Cover art, cached in memory and on disk.
///
/// `URLCache` can't do this job: every Subsonic URL carries a fresh salt and token, so the same
/// image never has the same URL twice. The cache key is the server, the cover id and the size.
actor CoverArtLoader {
    private let registry: ClientRegistry
    private let offline: OfflineSwitch?
    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init(registry: ClientRegistry, offline: OfflineSwitch? = nil) {
        self.registry = registry
        self.offline = offline
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 300
    }

    /// `artworkId` is a composite id (`TrackID`). `size` is in pixels.
    func image(artworkId: String, size: Int) async -> UIImage? {
        let key = "\(artworkId)@\(size)"
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let task = inFlight[key] { return await task.value }

        let task = Task { await load(artworkId: artworkId, size: size, key: key) }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    func data(artworkId: String, size: Int) async -> Data? {
        await image(artworkId: artworkId, size: size)?.jpegData(compressionQuality: 0.9)
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func load(artworkId: String, size: Int, key: String) async -> UIImage? {
        let file = directory.appendingPathComponent(Self.fileName(artworkId: artworkId, size: size))
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        guard offline?.isOn != true,
              let (serverId, coverId) = TrackID.parse(artworkId),
              let client = await registry.client(for: serverId),
              let (data, response) = try? await URLSession.shared.data(from: client.coverURL(id: coverId, size: size)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data)
        else {
            // Offline, or the server is down: any size of the same cover beats a placeholder.
            return cachedOtherSize(artworkId: artworkId, near: size)
        }
        memory.setObject(image, forKey: key as NSString)
        try? data.write(to: file, options: .atomic)
        return image
    }

    /// The closest size at or above `size`, else the largest below it.
    private func cachedOtherSize(artworkId: String, near size: Int) -> UIImage? {
        let prefix = Self.encode(artworkId) + "@"
        let sizes = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
            .compactMap { Int($0.dropFirst(prefix.count)) }
        let ordered = sizes.filter { $0 >= size }.sorted() + sizes.filter { $0 < size }.sorted(by: >)
        for candidate in ordered {
            let file = directory.appendingPathComponent(Self.fileName(artworkId: artworkId, size: candidate))
            if let data = try? Data(contentsOf: file), let image = UIImage(data: data) { return image }
        }
        return nil
    }

    private static func fileName(artworkId: String, size: Int) -> String {
        "\(encode(artworkId))@\(size)"
    }

    private static func encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }
}
