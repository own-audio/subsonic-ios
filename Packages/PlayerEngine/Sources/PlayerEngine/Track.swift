import Foundation
import OSLog

/// What the engine needs to know about a track. It knows nothing about servers: `id` is opaque
/// and is handed back to `TrackFileCache`'s resolver to find the audio.
public struct Track: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let title: String
    public let artist: String?
    public let album: String?
    public let durationSecs: Int?
    /// Opaque, like `id`: whatever the app needs to find this track's cover.
    public let artworkId: String?

    public init(
        id: String, title: String, artist: String? = nil, album: String? = nil,
        durationSecs: Int? = nil, artworkId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSecs = durationSecs
        self.artworkId = artworkId
    }
}

public enum PlaybackError: Error, Sendable {
    case network(String)
    case invalidURL(String)
}

/// Strings shown to the listener. The app's catalog translates them.
func loc(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

extension Logger {
    /// The reason a track "did not play" has to live somewhere; this is where.
    static let playback = Logger(subsystem: "audio.own.player", category: "playback")
}
