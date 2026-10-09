import Foundation
import Observation

/// Gapless-or-crossfade and the fade length: a per-device preference, kept in `UserDefaults`.
@Observable
@MainActor
public final class PlaybackSettingsStore {
    private enum Keys {
        static let crossfadeEnabled = "player.crossfadeEnabled"
        static let fadeDurationSecs = "player.fadeDurationSecs"
        static let replayGainMode = "player.replayGainMode"
    }

    /// Mutually exclusive with strict gapless playback — see `PlaybackEngine`'s own doc
    /// comment on why the two need genuinely different scheduling, not just a volume tweak.
    /// Off by default: gapless is the "does what a music player promises" default, crossfade is
    /// the opt-in extra.
    public private(set) var crossfadeEnabled: Bool
    /// Clamped to 1–12s — under a second isn't a perceptible crossfade, and this app's tracks
    /// are ordinary songs, not multi-minute DJ mixes that could justify much longer.
    public private(set) var fadeDurationSecs: Double

    /// On by default: a shuffled library jumping in loudness is the more common complaint.
    public private(set) var replayGainMode: ReplayGainMode

    /// The engine registers here to re-apply the current track's gain.
    public var onReplayGainModeChanged: (() -> Void)?

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        crossfadeEnabled = defaults.object(forKey: Keys.crossfadeEnabled) != nil
            ? defaults.bool(forKey: Keys.crossfadeEnabled)
            : false
        let storedDuration = defaults.object(forKey: Keys.fadeDurationSecs) as? Double
        fadeDurationSecs = (storedDuration ?? 4).clamped(to: 1...12)
        replayGainMode = defaults.string(forKey: Keys.replayGainMode).flatMap(ReplayGainMode.init) ?? .track
    }

    public func setReplayGainMode(_ mode: ReplayGainMode) {
        replayGainMode = mode
        defaults.set(mode.rawValue, forKey: Keys.replayGainMode)
        onReplayGainModeChanged?()
    }

    public func setCrossfadeEnabled(_ enabled: Bool) {
        crossfadeEnabled = enabled
        defaults.set(enabled, forKey: Keys.crossfadeEnabled)
    }

    public func setFadeDurationSecs(_ seconds: Double) {
        let clamped = seconds.clamped(to: 1...12)
        fadeDurationSecs = clamped
        defaults.set(clamped, forKey: Keys.fadeDurationSecs)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
