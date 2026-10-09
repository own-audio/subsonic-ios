import Foundation

/// Decides when a track counts as played, from the player's start and stop events.
///
/// The rule is the one Last.fm established and most scrobblers follow: "now playing" as soon as
/// a track starts, and a play once it has been *heard* for half its length or four minutes,
/// whichever comes first. Tracks under 30 seconds never count. Heard means wall-clock time while
/// playing, so seeking to the end doesn't count as listening, and a pause doesn't either.
@MainActor
public final class ScrobbleTracker {
    public enum Event: Equatable, Sendable {
        case nowPlaying(key: String)
        /// `startedAt` is when listening began, which the server records as the play's time.
        case played(key: String, startedAt: Date)
    }

    private struct Current {
        let key: String
        let durationSecs: Int?
        let startedAt: Date
        var heardSecs: Double = 0
        var playingSince: Date?
        var counted = false
    }

    private let now: () -> Date
    private let send: (Event) -> Void
    private var current: Current?

    static let minimumTrackSecs = 30
    static let maximumThresholdSecs = 240.0

    /// `key` is whatever the caller needs to send the scrobble (its track id).
    public init(now: @escaping () -> Date = Date.init, send: @escaping (Event) -> Void) {
        self.now = now
        self.send = send
    }

    /// Audio for `key` started or resumed.
    public func started(key: String, durationSecs: Int?) {
        if let current, current.key == key {
            self.current?.playingSince = current.playingSince ?? now()
            return
        }
        finish()
        current = Current(key: key, durationSecs: durationSecs, startedAt: now(), playingSince: now())
        send(.nowPlaying(key: key))
    }

    /// Audio for `key` stopped. `isEnd` is true when the track is over (played to its end,
    /// skipped, replaced) rather than paused or seeked; the next start is then a new listen even
    /// for the same track, as with repeat-one.
    public func stopped(key: String, isEnd: Bool) {
        guard current?.key == key else { return }
        accumulate()
        countIfDue()
        if isEnd { current = nil }
    }

    /// For a periodic check while playing, so a play counts even if the app is killed before
    /// the track ends.
    public func tick() {
        guard current?.playingSince != nil else { return }
        accumulate()
        current?.playingSince = now()
        countIfDue()
    }

    private func finish() {
        guard current != nil else { return }
        accumulate()
        countIfDue()
        current = nil
    }

    private func accumulate() {
        guard let since = current?.playingSince else { return }
        current?.heardSecs += max(now().timeIntervalSince(since), 0)
        current?.playingSince = nil
    }

    private func countIfDue() {
        guard let current, !current.counted, current.heardSecs >= threshold(for: current) else { return }
        self.current?.counted = true
        send(.played(key: current.key, startedAt: current.startedAt))
    }

    private func threshold(for track: Current) -> Double {
        guard let duration = track.durationSecs else { return Self.maximumThresholdSecs }
        guard duration >= Self.minimumTrackSecs else { return .infinity }
        return min(Double(duration) / 2, Self.maximumThresholdSecs)
    }
}
