import AVFoundation
import Foundation
import Testing

@testable import PlayerEngine

/// The network plumbing around `AudioStreamDecoder`: real fixture bytes served through
/// `MockURLProtocol`, so the actual `URLSession.bytes` path runs without a live server.
///
/// The `onBuffer` closure is `@Sendable`, so a captured `var` can't be mutated from it; a small
/// reference box can.
private final class FrameCounter: @unchecked Sendable {
    var total: AVAudioFramePosition = 0
}

@Suite("StreamingTrackSource")
struct StreamingTrackSourceTests {
    private static let streamURL = URL(string: "https://music.example.com/rest/stream.view?id=1")!

    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func makeSource(_ mock: MockURLProtocol.StubbedSession) -> StreamingTrackSource {
        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming-tests-\(UUID().uuidString)", isDirectory: true)
        let fileCache = TrackFileCache(
            remoteURL: { _ in Self.streamURL }, session: mock.urlSession, cacheDirectory: cacheDirectory
        )
        return StreamingTrackSource(fileCache: fileCache, session: mock.urlSession)
    }

    private func serving(_ data: Data, contentType: String) async -> MockURLProtocol.StubbedSession {
        await MockURLProtocol.makeStubbedSession { request in
            guard request.url == Self.streamURL else { return .init(statusCode: 404, body: Data()) }
            return .init(statusCode: 200, body: data, headers: ["Content-Type": contentType])
        }
    }

    @Test("streams a real MP3 end to end, producing roughly its known duration")
    func streamsMP3() async throws {
        let source = makeSource(await serving(try fixtureData("test-tone.mp3"), contentType: "audio/mpeg"))

        let counter = FrameCounter()
        try await source.stream(trackId: "track-1") { decoded in
            counter.total += AVAudioFramePosition(decoded.buffer.frameLength)
        }

        let format = try #require(await source.currentFormatInfo())
        let seconds = Double(counter.total) / format.sampleRate
        #expect((2.9...3.3).contains(seconds), "decoded \(seconds)s from a 3.0s source")
    }

    @Test("streams a real FLAC end to end and reports it as lossless")
    func streamsFLAC() async throws {
        let source = makeSource(await serving(try fixtureData("test-tone.flac"), contentType: "audio/flac"))

        let counter = FrameCounter()
        try await source.stream(trackId: "track-2") { decoded in
            counter.total += AVAudioFramePosition(decoded.buffer.frameLength)
        }

        let format = try #require(await source.currentFormatInfo())
        #expect(format.isLossless)
        let seconds = Double(counter.total) / format.sampleRate
        #expect((2.9...3.2).contains(seconds), "decoded \(seconds)s from a 3.0s source")
    }

    /// An M4A/ALAC with its `moov` atom after the audio can't be parsed in pieces. That must
    /// turn into a playable local file, not a failure.
    @Test("falls back to a full local download for the trailing-moov M4A")
    func fallsBackForNotOptimizedALAC() async throws {
        let source = makeSource(await serving(try fixtureData("test-tone.m4a"), contentType: "audio/mp4"))

        do {
            try await source.stream(trackId: "track-3") { _ in }
            Issue.record("expected FallbackToLocalPlaybackRequired")
        } catch let fallback as StreamingTrackSource.FallbackToLocalPlaybackRequired {
            let file = try AVAudioFile(forReading: fallback.localURL)
            let seconds = Double(file.length) / file.fileFormat.sampleRate
            #expect((2.9...3.2).contains(seconds))
            #expect(fallback.localURL.pathExtension == "m4a")
        }
    }

    @Test("a non-2xx response is a network error, not a decode error")
    func nonSuccessStatusIsNetworkError() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 403, body: Data()) }
        await #expect(throws: PlaybackError.self) {
            try await makeSource(mock).stream(trackId: "track-4") { _ in }
        }
    }

    /// Subsonic answers "not found" and similar with HTTP 200 and a JSON body.
    @Test("a Subsonic error body sent with HTTP 200 is caught before decoding")
    func subsonicErrorBodyIsCaught() async throws {
        let body = Data(String(repeating: " ", count: 64).utf8)
        let json = Data(#"{"subsonic-response":{"status":"failed","error":{"code":70,"message":"not found"}}}"#.utf8) + body
        let source = makeSource(await serving(json, contentType: "application/json"))
        await #expect(throws: PlaybackError.self) {
            try await source.stream(trackId: "track-5") { _ in }
        }
    }
}
