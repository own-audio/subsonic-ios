import AudioToolbox
import Foundation

/// Streams one track from its URL, decoding it progressively via `AudioStreamDecoder`
/// and handing PCM buffers to a caller as they become available — the piece that lets
/// `PlaybackEngine` start playing before a track has fully downloaded.
///
/// Deliberately split from `AudioStreamDecoder`: that type is pure Core Audio with no networking
/// (and is unit tested that way, against real audio bytes with no HTTP anywhere near the test);
/// this type is pure networking plumbing around it. Uses `URLSession.bytes(for:)` rather than a
/// `URLSessionDataDelegate` — Swift's `AsyncSequence` already gives pull-based back-pressure for
/// free: the network is only asked for the next chunk once the last one is decoded.
public actor StreamingTrackSource {
    /// Thrown instead of a decode error specifically for `AudioStreamDecoder.DecoderError
    /// .streamParseFailed` carrying `kAudioFileStreamError_NotOptimized` — an M4A/ALAC file
    /// whose `moov` atom trails the audio data, which Core Audio's stream parser refuses to
    /// parse progressively no matter how it arrives (see `AudioStreamDecoderTests`). The caller should not treat this as a playback failure —
    /// it should fetch `localURL` (a full download through the existing `TrackFileCache`,
    /// the same path a downloaded track already takes) and play that via `AVAudioFile` instead.
    public struct FallbackToLocalPlaybackRequired: Error, Sendable {
        public let localURL: URL
    }

    private let fileCache: TrackFileCache
    private let session: URLSession
    private let decoder = AudioStreamDecoder()

    /// Bytes are batched to this size before being handed to `AudioStreamDecoder.ingest(_:)` —
    /// large enough that decoding isn't dominated by per-call overhead, small enough that "first
    /// sound" latency isn't held hostage to an oversized first read. iOS's own default TCP
    /// receive-buffer growth means real reads from `URLSession.bytes` arrive in chunks close to
    /// this size anyway.
    private static let ingestChunkSize = 16 * 1024

    public init(fileCache: TrackFileCache, session: URLSession = .shared) {
        self.fileCache = fileCache
        self.session = session
    }

    /// Streams `trackId`, calling `onBuffer` for every decoded chunk in order as it becomes
    /// available, and returning once the stream is exhausted. Throws
    /// `FallbackToLocalPlaybackRequired` for the ALAC trailing-`moov` case (see that type's own
    /// doc comment) — every other thrown error is a genuine playback failure.
    public func stream(
        trackId: String,
        onBuffer: @Sendable (AudioStreamDecoder.DecodedBuffer) async -> Void,
        /// Fired once, the first time the decoder's format becomes readable — the source of a
        /// "FLAC · 44.1 kHz · 16-bit" badge for a streamed track.
        onFormatKnown: @Sendable (AudioStreamDecoder.FormatInfo) async -> Void = { _ in }
    ) async throws {
        let remoteURL = try await fileCache.resolveRemoteURL(trackId: trackId)
        let (byteStream, response) = try await session.bytes(from: remoteURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlaybackError.network("Could not stream track \(trackId) (status \((response as? HTTPURLResponse)?.statusCode ?? -1))")
        }

        var pending = Data()
        pending.reserveCapacity(Self.ingestChunkSize)
        var formatReported = false
        // Checked once, on the first chunk: a Subsonic error body arrives with a 200 (see
        // `AudioPayloadCheck`), and handing it to the decoder produces an opaque parse failure
        // rather than naming what actually went wrong.
        var payloadChecked = false

        do {
            for try await byte in byteStream {
                pending.append(byte)
                if !payloadChecked, pending.count >= 64 {
                    payloadChecked = true
                    guard AudioPayloadCheck.looksLikeAudio(
                        contentType: http.mimeType, prefix: pending
                    ) else {
                        throw PlaybackError.network("Server sent an error instead of track \(trackId)")
                    }
                }
                if pending.count >= Self.ingestChunkSize {
                    try await ingestAndDrain(pending, onBuffer: onBuffer, formatReported: &formatReported, onFormatKnown: onFormatKnown)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if !pending.isEmpty {
                try await ingestAndDrain(pending, onBuffer: onBuffer, formatReported: &formatReported, onFormatKnown: onFormatKnown)
            }
            try await decoder.finish()
            while let decoded = try await decoder.nextBuffer() {
                if !formatReported, let format = await decoder.currentFormatInfo() {
                    formatReported = true
                    await onFormatKnown(format)
                }
                await onBuffer(decoded)
            }
        } catch let error as AudioStreamDecoder.DecoderError {
            // *Any* decoding failure falls back to the file, not only the one known
            // trailing-`moov` case this started as. A track in this library reproduced the
            // point exactly: a perfectly ordinary 44.1 kHz/16-bit FLAC that `AVAudioFile` reads
            // end to end, and that progressive decoding rejects with `'bada'` on its very first
            // chunk. Whatever the decoder cannot take in pieces, it can still take whole, and
            // "could not play this track" was a lie about the music rather than about us.
            guard let localURL = try? await fileCache.localURL(trackId: trackId) else { throw error }
            throw FallbackToLocalPlaybackRequired(localURL: localURL)
        }
    }

    /// The engine's own format read-out, once streaming has produced at least one buffer —
    /// `nil` before that point, same as `AudioStreamDecoder.currentFormatInfo()` itself.
    public func currentFormatInfo() async -> AudioStreamDecoder.FormatInfo? {
        await decoder.currentFormatInfo()
    }

    private func ingestAndDrain(
        _ chunk: Data, onBuffer: @Sendable (AudioStreamDecoder.DecodedBuffer) async -> Void,
        formatReported: inout Bool, onFormatKnown: @Sendable (AudioStreamDecoder.FormatInfo) async -> Void
    ) async throws {
        try await decoder.ingest(chunk)
        while let decoded = try await decoder.nextBuffer() {
            if !formatReported, let format = await decoder.currentFormatInfo() {
                formatReported = true
                await onFormatKnown(format)
            }
            await onBuffer(decoded)
        }
    }
}
