import Foundation
import Testing

@testable import SubsonicKit

@Suite("ScrobbleTracker")
@MainActor
struct ScrobbleTrackerTests {
    /// A clock the test moves by hand.
    final class Clock {
        var time = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: Double) { time += seconds }
    }

    private func make() -> (ScrobbleTracker, Clock, () -> [ScrobbleTracker.Event]) {
        let clock = Clock()
        var events: [ScrobbleTracker.Event] = []
        let tracker = ScrobbleTracker(now: { clock.time }, send: { events.append($0) })
        return (tracker, clock, { events })
    }

    @Test("a start sends now playing at once")
    func nowPlayingOnStart() {
        let (tracker, _, events) = make()
        tracker.started(key: "a", durationSecs: 200)
        #expect(events() == [.nowPlaying(key: "a")])
    }

    @Test("half the track heard counts as a play, with the time listening began")
    func halfCounts() {
        let (tracker, clock, events) = make()
        let began = clock.time
        tracker.started(key: "a", durationSecs: 200)
        clock.advance(100)
        tracker.stopped(key: "a", isEnd: true)
        #expect(events() == [.nowPlaying(key: "a"), .played(key: "a", startedAt: began)])
    }

    @Test("skipping before half doesn't count")
    func earlySkipDoesNotCount() {
        let (tracker, clock, events) = make()
        tracker.started(key: "a", durationSecs: 200)
        clock.advance(99)
        tracker.stopped(key: "a", isEnd: true)
        #expect(events() == [.nowPlaying(key: "a")])
    }

    @Test("four minutes count for a long track")
    func fourMinutesCount() {
        let (tracker, clock, events) = make()
        tracker.started(key: "long", durationSecs: 1800)
        clock.advance(240)
        tracker.stopped(key: "long", isEnd: true)
        #expect(events().last == .played(key: "long", startedAt: Date(timeIntervalSince1970: 1_000_000)))
    }

    @Test("a track under 30 seconds never counts")
    func shortTrackNeverCounts() {
        let (tracker, clock, events) = make()
        tracker.started(key: "jingle", durationSecs: 20)
        clock.advance(20)
        tracker.stopped(key: "jingle", isEnd: true)
        #expect(events() == [.nowPlaying(key: "jingle")])
    }

    @Test("time spent paused isn't listening")
    func pauseDoesNotCount() {
        let (tracker, clock, events) = make()
        tracker.started(key: "a", durationSecs: 200)
        clock.advance(60)
        tracker.stopped(key: "a", isEnd: false)      // pause
        clock.advance(600)
        tracker.started(key: "a", durationSecs: 200) // resume: no second now playing
        clock.advance(30)
        tracker.stopped(key: "a", isEnd: true)
        #expect(events() == [.nowPlaying(key: "a")])
    }

    @Test("listening across a pause adds up")
    func listeningAddsUpAcrossPause() {
        let (tracker, clock, events) = make()
        tracker.started(key: "a", durationSecs: 200)
        clock.advance(60)
        tracker.stopped(key: "a", isEnd: false)
        clock.advance(600)
        tracker.started(key: "a", durationSecs: 200)
        clock.advance(40)
        tracker.stopped(key: "a", isEnd: true)
        #expect(events().count == 2)
    }

    @Test("a play counts once, however many stops follow")
    func countsOnce() {
        let (tracker, clock, events) = make()
        tracker.started(key: "a", durationSecs: 200)
        clock.advance(150)
        tracker.stopped(key: "a", isEnd: false)
        tracker.started(key: "a", durationSecs: 200)
        clock.advance(50)
        tracker.stopped(key: "a", isEnd: true)
        #expect(events().filter { if case .played = $0 { true } else { false } }.count == 1)
    }

    @Test("the next track starting finishes the previous one")
    func nextTrackFinishesPrevious() {
        let (tracker, clock, events) = make()
        tracker.started(key: "a", durationSecs: 200)
        clock.advance(120)
        // A gapless change can report the next start without a stop in between.
        tracker.started(key: "b", durationSecs: 200)
        #expect(events() == [
            .nowPlaying(key: "a"),
            .played(key: "a", startedAt: Date(timeIntervalSince1970: 1_000_000)),
            .nowPlaying(key: "b"),
        ])
    }

    @Test("repeat-one: the same track played again is a new listen")
    func repeatOneIsANewListen() {
        let (tracker, clock, events) = make()
        tracker.started(key: "a", durationSecs: 60)
        clock.advance(60)
        tracker.stopped(key: "a", isEnd: true)
        tracker.started(key: "a", durationSecs: 60)
        clock.advance(60)
        tracker.stopped(key: "a", isEnd: true)
        #expect(events().filter { if case .played = $0 { true } else { false } }.count == 2)
    }

    @Test("a tick counts a play while still playing, so it survives the app being killed")
    func tickCountsWhilePlaying() {
        let (tracker, clock, events) = make()
        tracker.started(key: "a", durationSecs: 200)
        clock.advance(101)
        tracker.tick()
        #expect(events().count == 2)
    }

    @Test("an unknown length counts after four minutes")
    func unknownLength() {
        let (tracker, clock, events) = make()
        tracker.started(key: "a", durationSecs: nil)
        clock.advance(239)
        tracker.tick()
        #expect(events().count == 1)
        clock.advance(1)
        tracker.tick()
        #expect(events().count == 2)
    }
}
