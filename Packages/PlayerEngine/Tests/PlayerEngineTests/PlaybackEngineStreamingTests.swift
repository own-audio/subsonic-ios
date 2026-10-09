import AVFoundation
import Foundation
import Testing

@testable import PlayerEngine

/// A real `AVAudioEngine` scheduling real decoded buffers from the fixtures, with only the
/// network mocked. Proves the engine reaches a genuinely playing state; whether it *sounds*
/// right (no gap, no artefact) still needs a device and an ear.
@Suite("PlaybackEngine — streaming")
@MainActor
struct PlaybackEngineStreamingTests {
    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private nonisolated static func streamURL(_ trackId: String) -> URL {
        URL(string: "https://music.example.com/rest/stream.view?id=\(trackId)")!
    }

    private struct Harness {
        let engine: PlaybackEngine
        let streamRequestLog: MockURLProtocol.StubbedSession
    }

    /// `failingTrackIds` answer 404.
    private func makeHarness(
        suffix: String, audioData: Data, failingTrackIds: Set<String> = []
    ) async throws -> Harness {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            let id = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
                .first { $0.name == "id" }?.value ?? ""
            if failingTrackIds.contains(id) { return .init(statusCode: 404, body: Data()) }
            return .init(statusCode: 200, body: audioData, headers: ["Content-Type": "audio/mpeg"])
        }
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-tests-\(UUID().uuidString)", isDirectory: true)
        let fileCache = TrackFileCache(
            remoteURL: { Self.streamURL($0) }, session: mock.urlSession, cacheDirectory: cacheDirectory
        )
        let engine = PlaybackEngine(
            fileCache: fileCache,
            nowPlayingController: NowPlayingController(),
            settingsStore: PlaybackSettingsStore(defaults: UserDefaults(suiteName: "test.engine.settings.\(suffix)")!),
            equalizerStore: EqualizerStore(defaults: UserDefaults(suiteName: "test.engine.eq.\(suffix)")!),
            resumeStore: InMemoryResumeStore()
        )
        return Harness(engine: engine, streamRequestLog: mock)
    }

    private func makeTrack(id: String = "track-1", durationSecs: Int = 3) -> Track {
        Track(id: id, title: "Test Tone", artist: "Fixture", album: nil, durationSecs: durationSecs)
    }

    @Test("play() on an uncached track streams it: real AVAudioEngine reaches isPlaying with real decoded audio")
    func playStreamsAndReachesPlayingState() async throws {
        let harness = try await makeHarness(suffix: "mp3", audioData: try fixtureData("test-tone.mp3"))

        await harness.engine.play(tracks: [makeTrack()])
        // The stream has to actually traverse the mocked network + real decode before the first
        // buffer is scheduled — generous relative to the ~1s a real StreamingTrackSourceTests
        // run takes for the same fixture, tight enough that a real hang still fails the test.
        try await waitUntil(timeout: 5) { harness.engine.isPlaying }

        #expect(harness.engine.isPlaying)
        #expect(harness.engine.currentTrack?.id == "track-1")
        #expect(await harness.streamRequestLog.requestLog().count >= 1)

        harness.engine.stop()
    }

    @Test("currentTime genuinely advances while a streamed track plays — proof real audio is scheduled, not just state flags")
    func currentTimeAdvancesDuringStreamedPlayback() async throws {
        let harness = try await makeHarness(suffix: "flac", audioData: try fixtureData("test-tone.flac"))

        await harness.engine.play(tracks: [makeTrack(id: "track-2")])
        try await waitUntil(timeout: 5) { harness.engine.isPlaying }

        let firstReading = harness.engine.currentTime
        try await Task.sleep(nanoseconds: 900_000_000) // comfortably more than one 250ms tick
        let secondReading = harness.engine.currentTime

        #expect(secondReading > firstReading, "currentTime didn't advance: \(firstReading) -> \(secondReading)")

        harness.engine.stop()
    }

    @Test("the ALAC trailing-moov fallback still reaches a real playing state via the local-file path")
    func alacFallbackStillReachesPlayingState() async throws {
        let harness = try await makeHarness(suffix: "alac", audioData: try fixtureData("test-tone.m4a"))

        await harness.engine.play(tracks: [makeTrack(id: "track-3")])
        // The fallback needs an extra round trip (the failed stream attempt, then a full
        // re-download through `TrackFileCache.localURL`) — more generous timeout than the
        // straightforward streaming cases above.
        try await waitUntil(timeout: 8) { harness.engine.isPlaying }

        #expect(harness.engine.isPlaying)
        #expect(harness.engine.currentTrack?.id == "track-3")

        harness.engine.stop()
    }

    @Test("a track that fails to stream is skipped automatically, landing on the next one in the queue")
    func failedTrackAutoAdvancesToNext() async throws {
        let harness = try await makeHarness(
            suffix: "autoadvance", audioData: try fixtureData("test-tone.mp3"), failingTrackIds: ["track-fail"]
        )
        let engine = harness.engine

        await engine.play(tracks: [makeTrack(id: "track-fail"), makeTrack(id: "track-2")])
        // The failed track has to actually round-trip its 404 before the auto-skip fires, then
        // the second track has to stream for real — generous relative to the single-track cases
        // above, which only pay one of those two costs.
        try await waitUntil(timeout: 8) { engine.isPlaying }

        #expect(engine.isPlaying)
        #expect(engine.currentTrack?.id == "track-2", "a failed track should be skipped automatically, not leave playback stuck on it")
        #expect(engine.errorMessage == nil, "a track that later succeeds should clear the error the earlier failure left behind")

        engine.stop()
    }

    @Test("a failed track with nothing next just reports the error, rather than looping")
    func failedTrackWithNoNextJustReportsError() async throws {
        let harness = try await makeHarness(
            suffix: "nonext", audioData: Data(), failingTrackIds: ["track-only"]
        )
        let engine = harness.engine

        await engine.play(tracks: [makeTrack(id: "track-only")])
        try await waitUntil(timeout: 5) { engine.errorMessage != nil }

        #expect(!engine.isPlaying)
        #expect(engine.errorMessage == "Could not play this track.")
    }

    /// Reproduces a real crash: a server-saved position past the end of the decoded file (the
    /// fixture is 3 s) went negative converting to `AVAudioFrameCount` and trapped.
    @Test("a resume position past the end of the file starts the track over instead of crashing")
    func resumePastEndStartsOver() async throws {
        let harness = try await makeHarness(suffix: "pastend", audioData: try fixtureData("test-tone.mp3"))

        await harness.engine.play(tracks: [makeTrack(id: "track-5")], startTrackId: "track-5", startPositionSecs: 10)
        try await waitUntil(timeout: 8) { harness.engine.isPlaying }

        #expect(harness.engine.isPlaying)
        #expect(harness.engine.currentTime < 3)

        harness.engine.stop()
    }

    @Test("stop() during an in-flight stream cancels cleanly — no crash, no stale state")
    func stopDuringStreamingIsClean() async throws {
        let harness = try await makeHarness(suffix: "cancel", audioData: try fixtureData("test-tone.mp3"))

        await harness.engine.play(tracks: [makeTrack(id: "track-4")])
        // Deliberately not waiting for `isPlaying` — this exercises a stop that lands *during*
        // the network/decode race, the case most likely to leave a dangling Task or a stale
        // completion handler if the generation-check plumbing were wrong.
        harness.engine.stop()

        #expect(!harness.engine.isPlaying)
        #expect(harness.engine.currentTrack == nil)
        // If a stale streaming callback slipped past the generation check, this would flip back
        // to `true` sometime after `stop()` returns — give it a moment, then confirm it didn't.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(!harness.engine.isPlaying)
        #expect(harness.engine.currentTrack == nil)
    }

    /// Polls `condition` instead of a single fixed sleep — real network + real decode timing on
    /// a loaded CI machine is not exactly reproducible, and a flat `#expect` immediately after a
    /// single `Task.sleep` is exactly the kind of flaky test that shape produces.
    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
