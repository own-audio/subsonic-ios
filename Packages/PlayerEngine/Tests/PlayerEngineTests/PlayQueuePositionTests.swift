import Testing

@testable import PlayerEngine

@Suite("PlayQueue position")
struct PlayQueuePositionTests {
    private func track(_ id: String, secs: Int? = 100) -> Track {
        Track(id: id, title: id, artist: nil, album: nil, durationSecs: secs)
    }

    @Test("the position counts from one, against the whole list")
    func position() {
        let queue = PlayQueue(tracks: (1 ... 12).map { track("t\($0)") }, startTrackId: "t4")
        #expect(queue.positionDisplay.current == 4)
        #expect(queue.positionDisplay.total == 12)
    }

    /// What a container-wide progress bar measures against, so it must not include the track
    /// currently playing — that one is measured by its own position.
    @Test("the played tracks are the ones before this, and none of them is this one")
    func played() {
        let queue = PlayQueue(tracks: (1 ... 5).map { track("t\($0)") }, startTrackId: "t3")
        #expect(queue.played.map(\.id) == ["t1", "t2"])
    }

    @Test("the first track has nothing behind it")
    func firstTrack() {
        let queue = PlayQueue(tracks: (1 ... 5).map { track("t\($0)") })
        #expect(queue.played.isEmpty)
        #expect(queue.positionDisplay.current == 1)
    }
}

@Suite("PlayQueue position under shuffle")
struct PlayQueueShuffleTests {
    private func track(_ id: String) -> Track {
        Track(id: id, title: id, artist: nil, album: nil, durationSecs: 100)
    }

    /// The number on the player has to be findable among the rows on screen, and the list does
    /// not reorder itself when shuffle goes on.
    @Test("the list position follows the list, not the shuffled play order")
    func listPosition() {
        var queue = PlayQueue(tracks: (1 ... 5).map { track("t\($0)") }, startTrackId: "t5")
        #expect(queue.listPositionDisplay?.current == 5)
        queue.setShuffled(true)
        let current = queue.currentTrack!
        let expected = queue.tracks.firstIndex { $0.id == current.id }! + 1
        #expect(queue.listPositionDisplay?.current == expected)
        #expect(queue.listPositionDisplay?.total == 5)
    }
}

@Suite("Shuffling mid-queue")
struct PlayQueueShuffleMidwayTests {
    private func track(_ id: String) -> Track {
        Track(id: id, title: id, artist: nil, album: nil, durationSecs: 100)
    }

    /// The bug behind "the progress jumps when I press shuffle": tracks nobody had played ended
    /// up behind the cursor, counted as heard and dropped from what was still to come.
    @Test("nothing unplayed ends up behind the current track")
    func nothingLandsBehind() {
        for _ in 0 ..< 50 {
            var queue = PlayQueue(tracks: (1 ... 17).map { track("t\($0)") })
            queue.setShuffled(true)
            #expect(queue.played.isEmpty, "on track 1 nothing has been heard yet")
            #expect(queue.upcoming.count == 16, "every other track is still to come")
            #expect(queue.currentTrack?.id == "t1")
        }
    }

    @Test("what was already heard stays heard, in the order it was heard")
    func keepsHistory() {
        var queue = PlayQueue(tracks: (1 ... 17).map { track("t\($0)") })
        queue.advance()
        queue.advance()
        let heard = queue.played.map(\.id)
        queue.setShuffled(true)
        #expect(queue.played.map(\.id) == heard)
        #expect(queue.currentTrack?.id == "t3")
        #expect(queue.upcoming.count == 14)
    }

    /// Everything still has to be in the queue exactly once, however it was reordered.
    @Test("shuffling loses nothing and duplicates nothing")
    func keepsEveryTrack() {
        var queue = PlayQueue(tracks: (1 ... 17).map { track("t\($0)") })
        queue.advance()
        queue.setShuffled(true)
        let all = queue.played.map(\.id) + [queue.currentTrack!.id] + queue.upcoming.map(\.id)
        #expect(Set(all).count == 17)
        #expect(all.count == 17)
    }

    @Test("turning shuffle off restores the list's order around the current track")
    func unshuffle() {
        var queue = PlayQueue(tracks: (1 ... 17).map { track("t\($0)") }, startTrackId: "t5")
        queue.setShuffled(true)
        queue.setShuffled(false)
        #expect(queue.currentTrack?.id == "t5")
        #expect(queue.upcoming.first?.id == "t6")
    }
}
