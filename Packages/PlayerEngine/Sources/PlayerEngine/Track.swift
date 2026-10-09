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
    public let replayGain: TrackGain?

    public init(
        id: String, title: String, artist: String? = nil, album: String? = nil,
        durationSecs: Int? = nil, artworkId: String? = nil, replayGain: TrackGain? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSecs = durationSecs
        self.artworkId = artworkId
        self.replayGain = replayGain
    }
}

/// ReplayGain values in dB, peaks linear (1.0 = full scale).
public struct TrackGain: Sendable, Hashable, Codable {
    public let trackGainDb: Double?
    public let albumGainDb: Double?
    public let trackPeak: Double?
    public let albumPeak: Double?

    public init(trackGainDb: Double?, albumGainDb: Double?, trackPeak: Double?, albumPeak: Double?) {
        self.trackGainDb = trackGainDb
        self.albumGainDb = albumGainDb
        self.trackPeak = trackPeak
        self.albumPeak = albumPeak
    }
}

public enum ReplayGainMode: String, Sendable, CaseIterable, Codable {
    case off
    /// Every track at the same loudness.
    case track
    /// Albums keep their own quiet and loud songs; albums match each other.
    case album
}

enum ReplayGainCalculator {
    /// The gain to apply, in dB. Falls back to the other value when the preferred one is
    /// missing, and never raises a track so far that its peak would clip.
    static func gainDb(for gain: TrackGain?, mode: ReplayGainMode) -> Double {
        guard let gain, mode != .off else { return 0 }
        let (db, peak): (Double?, Double?) = mode == .album
            ? (gain.albumGainDb ?? gain.trackGainDb, gain.albumGainDb != nil ? gain.albumPeak : gain.trackPeak)
            : (gain.trackGainDb ?? gain.albumGainDb, gain.trackGainDb != nil ? gain.trackPeak : gain.albumPeak)
        guard var value = db else { return 0 }
        if let peak, peak > 0 {
            value = min(value, -20 * log10(peak))
        }
        return min(max(value, -24), 24)
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
