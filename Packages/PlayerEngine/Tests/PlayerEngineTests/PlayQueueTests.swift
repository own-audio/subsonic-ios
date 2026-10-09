import Testing

@testable import PlayerEngine

private func track(_ id: String) -> Track {
    Track(id: id, title: "Track \(id)", artist: "Artist", album: "Album", durationSecs: 200)
}

@Suite("PlayQueue")
struct PlayQueueTests {
    private let threeTracks = [track("t1"), track("t2"), track("t3")]

    @Test("starts at the first track by default")
    func startsAtFirstTrack() {
        let queue = PlayQueue(tracks: threeTracks)
        #expect(queue.currentTrack?.id == "t1")
        #expect(queue.nextTrack?.id == "t2")
        #expect(queue.previousTrack == nil)
    }

    @Test("starts at the given track id when provided")
    func startsAtGivenTrack() {
        let queue = PlayQueue(tracks: threeTracks, startTrackId: "t2")
        #expect(queue.currentTrack?.id == "t2")
        #expect(queue.nextTrack?.id == "t3")
        #expect(queue.previousTrack?.id == "t1")
    }

    @Test("an unknown startTrackId falls back to the first track")
    func unknownStartTrackIdFallsBackToFirst() {
        let queue = PlayQueue(tracks: threeTracks, startTrackId: "does-not-exist")
        #expect(queue.currentTrack?.id == "t1")
    }

    @Test("advance moves forward in order, nil once the queue is exhausted")
    func advanceMovesForwardThenExhausts() {
        var queue = PlayQueue(tracks: threeTracks)
        #expect(queue.advance()?.id == "t2")
        #expect(queue.advance()?.id == "t3")
        #expect(queue.advance() == nil)
        #expect(queue.currentTrack == nil)
    }

    @Test("goToPrevious does not move before the first track")
    func goToPreviousStopsAtStart() {
        var queue = PlayQueue(tracks: threeTracks)
        #expect(queue.goToPrevious()?.id == "t1")
    }

    @Test("jumpTo moves directly to a track by id, ignoring unknown ids")
    func jumpToMovesDirectly() {
        var queue = PlayQueue(tracks: threeTracks)
        #expect(queue.jumpTo(trackId: "t3")?.id == "t3")
        #expect(queue.jumpTo(trackId: "does-not-exist") == nil)
        #expect(queue.currentTrack?.id == "t3", "a failed jump must not move the queue")
    }

    @Test("shuffle reorders the queue but keeps the current track in place")
    func shufflePreservesCurrentTrack() {
        var queue = PlayQueue(tracks: threeTracks, startTrackId: "t2")
        queue.setShuffled(true)
        #expect(queue.isShuffled)
        #expect(queue.currentTrack?.id == "t2", "shuffling must not change what's currently playing")
    }

    @Test("shuffling a fresh queue starts anywhere, not always at track one")
    func shuffleFromStartDoesNotPinTheFirstTrack() {
        // Ten tracks, shuffled many times: if the start were pinned, every run would begin at t1.
        let tracks = (1 ... 10).map { index in
            Track(id: "t\(index)", title: "Track \(index)", artist: nil, album: nil, durationSecs: 100)
        }
        var starts: Set<String> = []
        for _ in 0 ..< 50 {
            var queue = PlayQueue(tracks: tracks)
            queue.shuffleFromStart()
            #expect(queue.isShuffled)
            starts.insert(queue.currentTrack?.id ?? "")
        }
        #expect(starts.count > 1, "shuffle always began with the same track: \(starts)")
    }

    @Test("un-shuffling restores the original canonical order")
    func unshuffleRestoresOriginalOrder() {
        var queue = PlayQueue(tracks: threeTracks)
        queue.setShuffled(true)
        queue.setShuffled(false)
        #expect(!queue.isShuffled)
        #expect(queue.currentTrack?.id == "t1")
        #expect(queue.nextTrack?.id == "t2")
    }

    @Test("trackAfterCurrent under .off matches nextTrack, nil at the end")
    func trackAfterCurrentOffMatchesNextTrack() {
        var queue = PlayQueue(tracks: threeTracks, startTrackId: "t3")
        #expect(queue.trackAfterCurrent(repeatMode: .off) == nil)
        queue.jumpTo(trackId: "t1")
        #expect(queue.trackAfterCurrent(repeatMode: .off)?.id == "t2")
    }

    @Test("trackAfterCurrent under .one is always the current track")
    func trackAfterCurrentOneIsCurrentTrack() {
        let queue = PlayQueue(tracks: threeTracks, startTrackId: "t2")
        #expect(queue.trackAfterCurrent(repeatMode: .one)?.id == "t2")
    }

    @Test("trackAfterCurrent under .all wraps to the first track only once nextTrack runs out")
    func trackAfterCurrentAllWrapsAtTheEnd() {
        var queue = PlayQueue(tracks: threeTracks)
        #expect(queue.trackAfterCurrent(repeatMode: .all)?.id == "t2", "mid-queue, .all behaves exactly like .off")
        queue.jumpTo(trackId: "t3")
        #expect(queue.trackAfterCurrent(repeatMode: .all)?.id == "t1", "at the last track, .all wraps instead of returning nil")
    }

    @Test("advance(repeatMode: .off) matches plain advance()")
    func advanceOffMatchesPlainAdvance() {
        var queue = PlayQueue(tracks: threeTracks, startTrackId: "t3")
        #expect(queue.advance(repeatMode: .off) == nil)
        #expect(queue.currentTrack == nil, "exhausting the queue under .off must still stop, same as today")
    }

    @Test("advance(repeatMode: .one) replays the current track without moving position")
    func advanceOneReplaysCurrentTrack() {
        var queue = PlayQueue(tracks: threeTracks, startTrackId: "t2")
        #expect(queue.advance(repeatMode: .one)?.id == "t2")
        #expect(queue.currentTrack?.id == "t2", "position must not move under .one")
        #expect(queue.advance(repeatMode: .one)?.id == "t2", "repeated finishes keep replaying the same track")
    }

    @Test("advance(repeatMode: .all) wraps to the first track instead of exhausting")
    func advanceAllWrapsInsteadOfExhausting() {
        var queue = PlayQueue(tracks: threeTracks, startTrackId: "t3")
        #expect(queue.advance(repeatMode: .all)?.id == "t1")
        #expect(queue.currentTrack?.id == "t1")
        #expect(queue.nextTrack?.id == "t2", "wrapping must land at a real position the queue can advance from again")
    }

    @Test("advance(repeatMode: .all) behaves like plain advance() away from the boundary")
    func advanceAllMatchesPlainAdvanceMidQueue() {
        var queue = PlayQueue(tracks: threeTracks)
        #expect(queue.advance(repeatMode: .all)?.id == "t2")
        #expect(queue.currentTrack?.id == "t2")
    }
}
