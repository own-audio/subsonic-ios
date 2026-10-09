import AVFoundation
import AudioToolbox
import Foundation

/// Decodes a compressed audio byte stream into PCM, incrementally, using Core Audio's own
/// stream parser and converter rather than requiring a complete file — this is the one piece
/// that makes music streaming possible at all (`AVAudioFile`, what the rest of this engine
/// uses for local playback, can only open a file that already exists in full on disk).
///
/// Deliberately separate from `StreamingTrackSource`: this type knows nothing about
/// `URLSession` or HTTP — it only turns `Data` chunks into
/// `AVAudioPCMBuffer`s. That split is what makes it testable against real audio bytes fed in
/// arbitrary, adversarial chunk sizes without a network stack anywhere near the test.
public actor AudioStreamDecoder {
    public struct FormatInfo: Sendable, Equatable {
        public let sampleRate: Double
        public let channelCount: UInt32
        public let bitsPerChannel: UInt32?
        public let formatID: AudioFormatID
        public let bitrate: UInt32?

        /// PCM formats this decoder round-trips without lossy re-encoding anywhere in the
        /// chain (FLAC/ALAC/WAV/AIFF), read off the same `AudioFormatID` Core Audio itself reports.
        public var isLossless: Bool {
            switch formatID {
            case kAudioFormatFLAC, kAudioFormatAppleLossless, kAudioFormatLinearPCM: true
            default: false
            }
        }
    }

    /// `AVAudioPCMBuffer` is a reference type Apple has not marked `Sendable`, even though a
    /// buffer this decoder just finished producing is safe to hand to exactly one receiver, which
    /// then owns it exclusively (schedules it on a player node and drops its own reference) — the
    /// same "safe in practice, not provably so to the compiler" situation `NowPlayingController`
    /// already documents for `MPMediaItemArtwork`. This box is the one place that unsafety is
    /// named, rather than sprinkling `nonisolated(unsafe)` through every call site that awaits
    /// `nextBuffer()`.
    public struct DecodedBuffer: @unchecked Sendable {
        public let buffer: AVAudioPCMBuffer
    }

    public enum DecoderError: Error, Sendable, Equatable {
        case streamOpenFailed(OSStatus)
        case streamParseFailed(OSStatus)
        case converterCreationFailed(OSStatus)
        case converterFailed(OSStatus)
        /// The stream finished before ever reaching `kAudioFileStreamProperty_ReadyToProducePackets`
        /// — a truncated response, a non-audio body (an error page),
        /// or a format Core Audio's parser doesn't recognise.
        case neverReadyToProducePackets
    }

    /// Boxes the state Core Audio's C callbacks need, so a raw pointer to *this* — not to the
    /// actor itself, which Swift gives no stable address for — can be threaded through
    /// `AudioFileStreamOpen`. `fileprivate`, not `private`: the free-function callbacks below
    /// live at file scope, not inside `AudioStreamDecoder`'s body, and need to see this type.
    ///
    /// Every field here is touched only from inside this actor's isolation, indirectly: the
    /// callbacks run synchronously on the calling thread's stack, as part of the single
    /// `AudioFileStreamParseBytes` call `ingest(_:)` makes — never on their own thread, and
    /// never overlapping with another call into this actor. That is what makes touching a
    /// plain (non-`Sendable`) class from a `@convention(c)` free function safe here, despite
    /// there being no compiler-enforced proof of it.
    fileprivate final class CallbackContext {
        var streamDescription: AudioStreamBasicDescription?
        var packets: [(data: Data, description: AudioStreamPacketDescription)] = []
        var magicCookie: Data?
        var dataOffset: Int64 = 0
        var audioDataByteCount: UInt64 = 0
        var bitrate: UInt32?
        /// Set once `kAudioFileStreamProperty_ReadyToProducePackets` fires — the point at which
        /// `streamDescription` is trustworthy and the converter can be built.
        var isReady = false
    }

    /// `nonisolated(unsafe)`: read and written only from actor-isolated methods *except*
    /// `deinit`, which Swift 6 treats as running nonisolated even on an actor — there is no
    /// other reference by the time `deinit` runs, so there is nothing for it to race with.
    private nonisolated(unsafe) var audioFileStreamID: AudioFileStreamID?
    private let context = CallbackContext()
    private nonisolated(unsafe) var converter: AudioConverterRef?
    /// The processing format handed to the caller's `AVAudioPCMBuffer`s — Float32,
    /// non-interleaved, **the source file's own sample rate** (never resampled here; the
    /// engine's mixer does that once, and a hi-res session can ask the output route for the
    /// native rate instead).
    private var outputFormat: AVAudioFormat?
    /// Packets not yet consumed by an `AudioConverterFillComplexBuffer` call — the converter
    /// pulls via a callback, so packets arriving from the parser have to be queued rather than
    /// handed over synchronously. `nonisolated(unsafe)`: written by `drainNewPackets()` (actor-
    /// isolated) and read by `supplyNextPacketForConversion` (necessarily `nonisolated`, since
    /// it is called synchronously from a C callback with no `await` available) — safe for the
    /// same single-call-stack reason `CallbackContext`'s own doc comment gives.
    private nonisolated(unsafe) var pendingPackets: [(data: Data, description: AudioStreamPacketDescription)] = []
    private nonisolated(unsafe) var packetsConsumed = 0
    /// Keeps the packet `AudioConverterFillComplexBuffer`'s input callback most recently pointed
    /// into alive for the duration of that one call — the callback hands back a raw pointer into
    /// this `Data`'s storage, which must not be deallocated before the converter finishes reading
    /// it.
    /// Keeps the *batch* of packets the most recent converter callback pointed into alive for
    /// the duration of that call — see `supplyNextPacketForConversion`'s own doc comment for why
    /// packets are batched rather than supplied one at a time.
    private nonisolated(unsafe) var inputCallbackDataHolder: Data?
    private nonisolated(unsafe) var inputCallbackDescriptionsHolder: [AudioStreamPacketDescription]?

    private let typeHint: AudioFileTypeID?

    /// `typeHint` narrows Core Audio's format sniffing when the container is ambiguous from
    /// bytes alone (rare with normal MP3/FLAC/M4A, kept as an escape hatch); `nil` lets it infer.
    public init(typeHint: AudioFileTypeID? = nil) {
        self.typeHint = typeHint
    }

    deinit {
        if let audioFileStreamID {
            AudioFileStreamClose(audioFileStreamID)
        }
        if let converter {
            AudioConverterDispose(converter)
        }
    }

    // MARK: - Feeding bytes in

    /// Opens the stream on the first call. Safe to call with any chunk size, including sizes
    /// far smaller than a single packet — Core Audio's parser buffers internally across calls;
    /// this decoder adds no chunking assumptions of its own.
    public func ingest(_ data: Data) throws {
        if audioFileStreamID == nil {
            try openStream()
        }
        guard let audioFileStreamID else { return }

        let status = data.withUnsafeBytes { buffer -> OSStatus in
            AudioFileStreamParseBytes(audioFileStreamID, UInt32(buffer.count), buffer.baseAddress, [])
        }
        guard status == noErr else {
            throw DecoderError.streamParseFailed(status)
        }

        if context.isReady, converter == nil {
            try buildConverterIfNeeded()
        }
        drainNewPackets()
    }

    /// Called once no more bytes are coming (the HTTP response finished normally). A stream
    /// that never became ready is treated as an error rather than silently yielding nothing —
    /// see `DecoderError.neverReadyToProducePackets`'s own doc comment for why that distinction
    /// matters to the caller.
    public func finish() throws {
        if let audioFileStreamID {
            AudioFileStreamClose(audioFileStreamID)
            self.audioFileStreamID = nil
        }
        guard context.isReady else {
            throw DecoderError.neverReadyToProducePackets
        }
    }

    // MARK: - Reading decoded audio out

    /// One PCM buffer, or `nil` when every ingested byte has already been converted and handed
    /// out — the caller (`StreamingTrackSource`) calls this in a loop as bytes keep arriving,
    /// not once per `ingest`.
    public func nextBuffer(frameCapacity: AVAudioFrameCount = 4096) throws -> DecodedBuffer? {
        guard let converter, let outputFormat else { return nil }
        guard packetsConsumed < pendingPackets.count else { return nil }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return nil
        }
        // `mutableAudioBufferList.pointee.mBuffers.mDataByteSize` tracks `frameLength`, not
        // `frameCapacity` — a freshly created buffer reports **zero** bytes of space available
        // until `frameLength` is set, which made `AudioConverterFillComplexBuffer` fail
        // immediately with `paramErr` (-50) before ever reaching the input callback (found by
        // hitting it: MP3 and FLAC both failed identically despite otherwise-correct decode
        // setup, which pointed at something common to every call rather than a format-specific
        // bug). Claim the full capacity up front so the converter sees real room to write into,
        // then shrink to what it actually produced.
        buffer.frameLength = frameCapacity

        var packetCount = frameCapacity
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioConverterFillComplexBuffer(
            converter, audioConverterInputProc, selfPointer, &packetCount, buffer.mutableAudioBufferList, nil
        )
        guard status == noErr || status == Self.noMorePacketsStatus else {
            throw DecoderError.converterFailed(status)
        }
        buffer.frameLength = packetCount
        guard buffer.frameLength > 0 else { return nil }
        return DecodedBuffer(buffer: buffer)
    }

    /// The custom status this decoder's own input-data callback returns to tell the converter
    /// "nothing more is available yet" — there is no Core Audio–defined constant for this; every
    /// caller of `AudioConverterFillComplexBuffer` picks its own sentinel, and the converter
    /// only cares that it is non-`noErr`.
    fileprivate static let noMorePacketsStatus: OSStatus = 1_935_763_568 // 'nomo', chosen for readability in a debugger

    /// Whether the parser has seen enough of the stream to describe its format and start
    /// producing packets. Exposed mainly for tests measuring *when* that happens relative to
    /// how many bytes have arrived — the honest answer differs by container (see
    /// `AudioStreamDecoderTests`'s progressive-delivery tests).
    public var isReadyToProducePackets: Bool { context.isReady }

    public func currentFormatInfo() -> FormatInfo? {
        guard let asbd = context.streamDescription else { return nil }
        return FormatInfo(
            sampleRate: asbd.mSampleRate,
            channelCount: asbd.mChannelsPerFrame,
            bitsPerChannel: asbd.mBitsPerChannel > 0 ? asbd.mBitsPerChannel : nil,
            formatID: asbd.mFormatID,
            bitrate: context.bitrate
        )
    }

    // MARK: - Setup

    private func openStream() throws {
        var streamID: AudioFileStreamID?
        let contextPointer = Unmanaged.passUnretained(context).toOpaque()
        let status = AudioFileStreamOpen(
            contextPointer, audioFileStreamPropertyListener, audioFileStreamPacketsProc, typeHint ?? 0, &streamID
        )
        guard status == noErr, let streamID else {
            throw DecoderError.streamOpenFailed(status)
        }
        audioFileStreamID = streamID
    }

    private func buildConverterIfNeeded() throws {
        guard var sourceFormat = context.streamDescription else { return }

        // Built from `AVAudioFormat`'s own canonical constructor, not a hand-rolled
        // `AudioStreamBasicDescription` — the two must describe *exactly* the same memory
        // layout `AudioConverterFillComplexBuffer` will write into and `AVAudioPCMBuffer` will
        // read from. A hand-built ASBD that merely *looks* equivalent (same sample rate, same
        // flags) but differs from what `AVAudioPCMBuffer(pcmFormat:)` actually allocates is
        // exactly the kind of mismatch that fails silently as `paramErr` (-50) with no further
        // detail — found by hitting it, not by reasoning about it in advance.
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.mSampleRate,
            channels: AVAudioChannelCount(sourceFormat.mChannelsPerFrame),
            interleaved: false
        ) else {
            throw DecoderError.converterCreationFailed(-1)
        }
        var destinationFormat = format.streamDescription.pointee

        var newConverter: AudioConverterRef?
        let status = AudioConverterNew(&sourceFormat, &destinationFormat, &newConverter)
        guard status == noErr, let newConverter else {
            throw DecoderError.converterCreationFailed(status)
        }

        if let cookie = context.magicCookie, !cookie.isEmpty {
            cookie.withUnsafeBytes { buffer in
                _ = AudioConverterSetProperty(
                    newConverter, kAudioConverterDecompressionMagicCookie, UInt32(buffer.count), buffer.baseAddress!
                )
            }
        }

        converter = newConverter
        outputFormat = format
    }

    /// Moves everything the parser handed to `context.packets` (written from the C callback,
    /// which cannot itself touch actor-isolated state) into this actor's own queue, where
    /// `AudioConverterFillComplexBuffer`'s pull callback can read it.
    private func drainNewPackets() {
        guard !context.packets.isEmpty else { return }
        pendingPackets.append(contentsOf: context.packets)
        context.packets.removeAll()
    }

    // MARK: - Converter input callback

    /// `AudioConverterFillComplexBuffer` pulls packets through this rather than being handed
    /// them. `nonisolated(unsafe)` for the same reason `pendingPackets`/`packetsConsumed` are:
    /// this is only ever invoked synchronously, from inside `nextBuffer()`, on the same thread,
    /// while `nextBuffer()` itself already holds this actor's isolation — there is no `await`
    /// point between them for anything else to interleave through.
    /// Supplies exactly **one** packet per call. Not the first thing tried: an early version
    /// batched several packets into one combined buffer per call (a common pattern in other
    /// implementations, meant to save callback round-trips), and it produced *silently wrong*
    /// output against a real MP3 fixture — `packetsConsumed` advanced by the whole batch every
    /// call, but the converter only ever needed the first few packets of a 64-packet batch to
    /// fill one output buffer, so the rest were marked consumed without ever being decoded, and
    /// `nextBuffer()` kept re-decoding the same handful of leading packets in a loop. There is no
    /// way to ask the converter how much of a given batch it actually used, so the only
    /// correct accounting is one packet in, one packet marked consumed. A genuine early failure
    /// (`paramErr`/-50 after a few calls) turned out to be a different, unrelated bug — a raw
    /// `UnsafeMutablePointer<AudioStreamPacketDescription>.allocate` for the packet description
    /// that was never `deallocate`d, fixed by holding the description in a normal Swift array
    /// instead (`inputCallbackDescriptionsHolder`, below) and handing the converter a pointer
    /// into *that*.
    fileprivate nonisolated func supplyNextPacketForConversion(
        packetCount: UnsafeMutablePointer<UInt32>,
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        packetDescriptions: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?
    ) -> OSStatus {
        guard packetsConsumed < pendingPackets.count else {
            packetCount.pointee = 0
            return Self.noMorePacketsStatus
        }

        let (data, description) = pendingPackets[packetsConsumed]
        packetsConsumed += 1
        inputCallbackDataHolder = data
        // `description.mStartOffset` was captured relative to the *original* parse buffer the
        // packets callback received, not to `data` — `data` is this one packet's bytes copied
        // out on their own (see `audioFileStreamPacketsProc`), so it always starts at 0. Handing
        // the converter the stale offset made it read past the end of a 400-odd-byte buffer,
        // which is the real cause the earlier `paramErr` (-50) traced back to — not the
        // leaked-pointer bug fixed above, a second, independent one found the same way.
        var adjustedDescription = description
        adjustedDescription.mStartOffset = 0
        inputCallbackDescriptionsHolder = [adjustedDescription]

        data.withUnsafeBytes { buffer in
            bufferList.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: buffer.baseAddress)
            bufferList.pointee.mBuffers.mDataByteSize = UInt32(buffer.count)
        }
        bufferList.pointee.mNumberBuffers = 1
        packetCount.pointee = 1

        if let packetDescriptions {
            inputCallbackDescriptionsHolder!.withUnsafeMutableBufferPointer { pointer in
                packetDescriptions.pointee = pointer.baseAddress
            }
        }
        return noErr
    }
}

// MARK: - Core Audio C callbacks

/// `AudioFileStreamOpen`'s property-listener callback. Free function, not a method — Core Audio
/// calls this as a plain C function pointer, which cannot capture `self`; all state instead
/// lives in the `CallbackContext` reached via `inClientData`.
private let audioFileStreamPropertyListener: AudioFileStream_PropertyListenerProc = {
    inClientData, streamID, propertyID, _ in
    let context = Unmanaged<AudioStreamDecoder.CallbackContext>.fromOpaque(inClientData).takeUnretainedValue()

    switch propertyID {
    case kAudioFileStreamProperty_DataFormat, kAudioFileStreamProperty_FormatList:
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr {
            context.streamDescription = asbd
        }
    case kAudioFileStreamProperty_MagicCookieData:
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        if AudioFileStreamGetPropertyInfo(streamID, propertyID, &size, &writable) == noErr, size > 0 {
            var cookieData = Data(count: Int(size))
            let status = cookieData.withUnsafeMutableBytes { buffer -> OSStatus in
                AudioFileStreamGetProperty(streamID, propertyID, &size, buffer.baseAddress!)
            }
            if status == noErr {
                context.magicCookie = cookieData
            }
        }
    case kAudioFileStreamProperty_DataOffset:
        var offset: Int64 = 0
        var size = UInt32(MemoryLayout<Int64>.size)
        if AudioFileStreamGetProperty(streamID, propertyID, &size, &offset) == noErr {
            context.dataOffset = offset
        }
    case kAudioFileStreamProperty_AudioDataByteCount:
        var count: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        if AudioFileStreamGetProperty(streamID, propertyID, &size, &count) == noErr {
            context.audioDataByteCount = count
        }
    case kAudioFileStreamProperty_BitRate:
        var bitrate: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioFileStreamGetProperty(streamID, propertyID, &size, &bitrate) == noErr {
            context.bitrate = bitrate
        }
    case kAudioFileStreamProperty_ReadyToProducePackets:
        context.isReady = true
    default:
        break
    }
}

/// `AudioFileStreamOpen`'s packets callback — every time the parser has assembled one or more
/// complete packets from the bytes handed to `AudioFileStreamParseBytes`, this fires once with
/// all of them.
private let audioFileStreamPacketsProc: AudioFileStream_PacketsProc = {
    inClientData, numberBytes, numberPackets, inputData, packetDescriptions in
    let context = Unmanaged<AudioStreamDecoder.CallbackContext>.fromOpaque(inClientData).takeUnretainedValue()
    guard numberPackets > 0 else { return }

    let bytePointer = inputData.assumingMemoryBound(to: UInt8.self)

    if let packetDescriptions {
        for index in 0..<Int(numberPackets) {
            let description = packetDescriptions[index]
            let packetData = Data(bytes: bytePointer + Int(description.mStartOffset), count: Int(description.mDataByteSize))
            context.packets.append((packetData, description))
        }
    } else {
        // CBR formats (some WAV/AIFF) carry no per-packet descriptions — the parser instead
        // reports one fixed-size run; `mBytesPerPacket` on the stream description (already
        // captured) gives the fixed size, so a description is synthesized here rather than
        // skipped, keeping `pendingPackets`' shape uniform for every downstream consumer.
        guard let asbd = context.streamDescription, asbd.mBytesPerPacket > 0 else { return }
        let bytesPerPacket = Int(asbd.mBytesPerPacket)
        for index in 0..<Int(numberPackets) {
            let offset = index * bytesPerPacket
            guard offset + bytesPerPacket <= Int(numberBytes) else { break }
            let packetData = Data(bytes: bytePointer + offset, count: bytesPerPacket)
            let description = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytesPerPacket)
            )
            context.packets.append((packetData, description))
        }
    }
}

/// `AudioConverterFillComplexBuffer`'s input-data callback. `inUserData` here is the
/// `AudioStreamDecoder` itself (unretained) — its `supplyNextPacketForConversion` does the real
/// work; this free function only bridges the C calling convention into a (`nonisolated(unsafe)`)
/// method call, since a `@convention(c)` function can neither capture `self` nor `await`.
private func audioConverterInputProc(
    inAudioConverter: AudioConverterRef,
    ioNumberDataPackets: UnsafeMutablePointer<UInt32>,
    ioData: UnsafeMutablePointer<AudioBufferList>,
    outDataPacketDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    inUserData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inUserData else { return AudioStreamDecoder.noMorePacketsStatus }
    let decoder = Unmanaged<AudioStreamDecoder>.fromOpaque(inUserData).takeUnretainedValue()
    return decoder.supplyNextPacketForConversion(
        packetCount: ioNumberDataPackets, bufferList: ioData, packetDescriptions: outDataPacketDescription
    )
}
