import Accelerate
import AVFoundation

/// Turns a raw PCM buffer into a small, log-spaced magnitude spectrum for a visualizer, fed by
/// `PlaybackEngine.setSpectrumEnabled(_:)`.
///
/// Deliberately not `@MainActor`: `AVAudioNode.installTap`'s callback runs on the audio engine's
/// own real-time render thread, and doing FFT setup/teardown or Swift allocations there would
/// risk an audio glitch (a dropped render deadline). This type does the actual number-crunching
/// on whatever thread calls it — the tap callback, off the main actor — and the caller hops the
/// *result* (a plain `[Float]`) back to the main actor, not the computation itself.
public final class SpectrumAnalyzer: @unchecked Sendable {
    /// 32 bars. Public so a visualizer can size itself against it.
    public static let bandCount = 32

    /// A real-time-safe power of two comfortably above `bandCount` — big enough for the log-
    /// spaced grouping below to have several raw FFT bins per band even at the low end, small
    /// enough that the FFT itself is cheap per callback (a 44.1kHz/1024-frame tap fires roughly
    /// every 23ms).
    private static let fftSize = 1024
    private static let log2n = vDSP_Length(log2(Double(fftSize)))

    private let fftSetup: FFTSetup
    private let window: [Float]

    init() {
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(
            ofType: Float.self, usingSequence: .hanningDenormalized,
            count: Self.fftSize, isHalfWindow: false
        )
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// `nil` if the buffer has fewer frames than `fftSize` (the last, short buffer before a
    /// stream pauses, typically) — not enough signal for a meaningful FFT, and the caller should
    /// just keep showing whatever it last had rather than flash a zeroed spectrum.
    func magnitudes(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData, buffer.frameLength >= Self.fftSize else { return nil }

        // Downmixes to one channel by reading channel 0 only, not averaging L/R — a visualizer
        // reacting to "roughly what's playing" doesn't need a true mono sum, and every sample
        // this skips is one the render thread doesn't have to touch.
        var samples = [Float](repeating: 0, count: Self.fftSize)
        vDSP.multiply(
            UnsafeBufferPointer(start: channelData[0], count: Self.fftSize), window, result: &samples
        )

        var realp = [Float](repeating: 0, count: Self.fftSize / 2)
        var imagp = [Float](repeating: 0, count: Self.fftSize / 2)
        var magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)

        realp.withUnsafeMutableBufferPointer { realPtr in
            imagp.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                samples.withUnsafeBufferPointer { samplesPtr in
                    samplesPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(Self.fftSize / 2))
            }
        }

        return Self.logSpacedBands(from: magnitudes)
    }

    /// Groups the linear FFT bins (bin 0 = DC, bin N/2 ≈ Nyquist) into `bandCount` log-spaced
    /// bands — a linear grouping would put almost the entire audible range humans actually
    /// perceive as "bass/mid/treble" into the first handful of bars, since music's energy skews
    /// low and pitch perception itself is logarithmic. Normalized to a rough 0...1 with a fixed
    /// scale + clamp rather than a running max, so the bars don't visibly "breathe" their own
    /// scale during a quiet passage.
    private static func logSpacedBands(from magnitudes: [Float]) -> [Float] {
        let binCount = magnitudes.count
        var bands = [Float](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            let lowFraction = pow(Float(binCount), Float(band) / Float(bandCount))
            let highFraction = pow(Float(binCount), Float(band + 1) / Float(bandCount))
            let low = max(1, Int(lowFraction))
            let high = min(binCount, max(low + 1, Int(highFraction)))
            var sum: Float = 0
            vDSP_sve(magnitudes[low..<high].map { $0 }, 1, &sum, vDSP_Length(high - low))
            let average = sum / Float(high - low)
            // Magnitudes from `vDSP_zvmags` are squared amplitude, spanning many orders of
            // magnitude — `log10` compresses that into something a linear bar height reads as
            // proportional loudness, the same reason real spectrum displays are always dB-scaled.
            let db = 10 * log10(average + 1e-9)
            // -50dB still maps to 0 (silence stays silent), but reported live as "too sensitive"
            // — ordinary music was pinning bars near 1.0 almost constantly, leaving no dynamic
            // range to actually react to a loud moment. Raising what maps to 1.0 from 0dB to
            // +25dB (a wider 75dB span instead of 50dB, same floor) means it now takes a
            // genuinely loud passage to reach full height rather than any ordinary one.
            bands[band] = min(max((db + 50) / 75, 0), 1)
        }
        return bands
    }
}
