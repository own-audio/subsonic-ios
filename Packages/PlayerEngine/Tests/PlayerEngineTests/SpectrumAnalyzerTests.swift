import AVFoundation
import Foundation
import Testing

@testable import PlayerEngine

@Suite("SpectrumAnalyzer")
struct SpectrumAnalyzerTests {
    private let sampleRate = 44_100.0

    private func sineBuffer(frequencyHz: Double, frameCount: Int = 1_024, amplitude: Float = 1.0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let samples = buffer.floatChannelData![0]
        for frame in 0..<frameCount {
            samples[frame] = amplitude * Float(sin(2 * .pi * frequencyHz * Double(frame) / sampleRate))
        }
        return buffer
    }

    @Test("a buffer shorter than the FFT size returns nil rather than a zeroed spectrum")
    func tooShortBufferReturnsNil() {
        let analyzer = SpectrumAnalyzer()
        let buffer = sineBuffer(frequencyHz: 440, frameCount: 128)
        #expect(analyzer.magnitudes(from: buffer) == nil)
    }

    @Test("output always has bandCount values, each within 0...1")
    func outputShapeIsAlwaysValid() throws {
        let analyzer = SpectrumAnalyzer()
        let bands = analyzer.magnitudes(from: sineBuffer(frequencyHz: 1_000))
        let unwrapped = try #require(bands)
        #expect(unwrapped.count == SpectrumAnalyzer.bandCount)
        for value in unwrapped {
            #expect(value >= 0 && value <= 1)
        }
    }

    @Test("a low-frequency tone reads louder in an early band than a high-frequency tone does in that same band")
    func lowToneConcentratesEnergyInAnEarlyBand() throws {
        let analyzer = SpectrumAnalyzer()
        // Same analyzer instance for both, same as a real tap reusing one across callbacks —
        // this also exercises that state (the FFT setup, the window) doesn't leak between calls.
        let lowBands = try #require(analyzer.magnitudes(from: sineBuffer(frequencyHz: 100)))
        let highBands = try #require(analyzer.magnitudes(from: sineBuffer(frequencyHz: 12_000)))

        // Band 0 covers roughly the lowest handful of FFT bins (~43Hz-wide bins at this sample
        // rate/FFT size) -- a 100Hz tone should dominate it far more than a 12kHz one does.
        #expect(lowBands[0] > highBands[0])
    }

    @Test("silence produces a near-silent spectrum, not noise")
    func silenceIsNearZero() throws {
        let analyzer = SpectrumAnalyzer()
        let bands = try #require(analyzer.magnitudes(from: sineBuffer(frequencyHz: 440, amplitude: 0)))
        for value in bands {
            #expect(value < 0.1)
        }
    }
}
