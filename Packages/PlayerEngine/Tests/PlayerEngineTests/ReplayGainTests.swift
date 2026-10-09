import Foundation
import Testing

@testable import PlayerEngine

@Suite("ReplayGain")
struct ReplayGainTests {
    private let loudTrack = TrackGain(trackGainDb: -6.5, albumGainDb: -5, trackPeak: 0.9, albumPeak: 0.95)
    private let quietTrack = TrackGain(trackGainDb: 3.2, albumGainDb: -5, trackPeak: 0.8, albumPeak: 0.95)

    @Test("off applies nothing")
    func off() {
        #expect(ReplayGainCalculator.gainDb(for: loudTrack, mode: .off) == 0)
    }

    @Test("track and album modes pick their own value")
    func modes() {
        #expect(ReplayGainCalculator.gainDb(for: loudTrack, mode: .track) == -6.5)
        #expect(ReplayGainCalculator.gainDb(for: loudTrack, mode: .album) == -5)
    }

    /// +3.2 dB on a peak of 0.8 would clip; 0.8 can rise by 1.94 dB to reach full scale.
    @Test("a raise is capped so the peak doesn't clip")
    func peakProtection() {
        let db = ReplayGainCalculator.gainDb(for: quietTrack, mode: .track)
        #expect(abs(db - (-20 * log10(0.8))) < 0.0001)
        #expect(db < 3.2)
    }

    @Test("a missing value falls back to the other one")
    func fallback() {
        let onlyAlbum = TrackGain(trackGainDb: nil, albumGainDb: -4, trackPeak: nil, albumPeak: nil)
        let onlyTrack = TrackGain(trackGainDb: -3, albumGainDb: nil, trackPeak: nil, albumPeak: nil)
        #expect(ReplayGainCalculator.gainDb(for: onlyAlbum, mode: .track) == -4)
        #expect(ReplayGainCalculator.gainDb(for: onlyTrack, mode: .album) == -3)
        #expect(ReplayGainCalculator.gainDb(for: nil, mode: .track) == 0)
    }
}
