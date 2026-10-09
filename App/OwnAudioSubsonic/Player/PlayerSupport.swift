import AudioToolbox
import AVKit
import MusicEngine
import SwiftUI
import UIKit

/// The player's column width. Its `GeometryReader`s can be handed an oversized width (see
/// `PlaybackScrubber`), so rows clamp against this instead; on an iPad it also keeps the
/// controls in a readable column rather than edge to edge.
enum PlayerLayout {
    static let maxColumnWidth: CGFloat = 600

    @MainActor static var columnWidth: CGFloat {
        min(UIScreen.main.bounds.width, maxColumnWidth)
    }

    /// 280 on a phone, up to 400 on an iPad.
    @MainActor static var coverSide: CGFloat {
        min(max(280, columnWidth - 120), 400)
    }

    @MainActor static var contentWidth: CGFloat {
        columnWidth - 2 * Theme.Spacing.screenEdge
    }
}

/// The system AirPlay picker. It works on the app's audio session, so it doesn't need to know
/// the player is `AVAudioEngine` rather than `AVPlayer`.
struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// "FLAC · 44.1 kHz · 16-bit" for lossless with a known bit depth, "MP3 320" for lossy with a
/// known bitrate, otherwise just the codec. Makes lossless visible rather than claimed.
enum FormatBadge {
    /// Adds the ReplayGain applied, when there is one, so normalization is visible too.
    static func text(for info: AudioStreamDecoder.FormatInfo?, gainDb: Double) -> String? {
        guard let format = text(for: info) else { return nil }
        guard abs(gainDb) >= 0.05 else { return format }
        return "\(format) · " + String(format: "%+.1f dB", gainDb)
    }

    static func text(for info: AudioStreamDecoder.FormatInfo?) -> String? {
        guard let info else { return nil }
        let codec = codecName(for: info.formatID)
        if info.isLossless {
            // A streamed FLAC's bit depth isn't known until the file is complete; the rate is.
            guard let bits = info.bitsPerChannel else { return "\(codec) · \(sampleRateText(info.sampleRate))" }
            return "\(codec) · \(sampleRateText(info.sampleRate)) · \(bits)-bit"
        }
        if let bitrate = info.bitrate {
            return "\(codec) \(bitrate / 1000)"
        }
        return codec
    }

    private static func sampleRateText(_ sampleRate: Double) -> String {
        let kHz = sampleRate / 1000
        return kHz.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f kHz", kHz) : String(format: "%.1f kHz", kHz)
    }

    private static func codecName(for formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatAppleLossless: "ALAC"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatMPEG4AAC: "AAC"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatLinearPCM: "PCM"
        default: "Audio"
        }
    }
}

private struct MarqueeTextSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// One line that scrolls when it is too wide, like Apple Music's Now Playing title, instead of
/// wrapping or truncating. Still and centred when it fits, and always with Reduce Motion on.
struct MarqueeText: View {
    let text: String
    var font: Font = .body

    private static let gap: CGFloat = 40
    private static let pointsPerSecond: CGFloat = 30

    @State private var measuredSize: CGSize = .zero
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let containerWidth = min(geometry.size.width, PlayerLayout.contentWidth)
            let overflows = measuredSize.width > containerWidth + 1

            Group {
                if overflows && !reduceMotion {
                    let cycle = measuredSize.width + Self.gap
                    TimelineView(.animation) { timeline in
                        let elapsed = timeline.date.timeIntervalSinceReferenceDate
                        let offset = CGFloat(elapsed.truncatingRemainder(dividingBy: cycle / Self.pointsPerSecond)) * Self.pointsPerSecond
                        HStack(spacing: Self.gap) {
                            measuredLine
                            measuredLine
                        }
                        .offset(x: -offset)
                    }
                } else {
                    HStack {
                        Spacer(minLength: 0)
                        measuredLine.lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(width: containerWidth, height: geometry.size.height, alignment: .leading)
            .clipped()
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: max(measuredSize.height, 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var measuredLine: some View {
        Text(text)
            .font(font)
            .fixedSize()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: MarqueeTextSizeKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(MarqueeTextSizeKey.self) { measuredSize = $0 }
    }
}

/// A hand-rolled scrubber rather than `Slider`. On this screen (a sibling of a horizontal
/// `ScrollView`, inside a full-screen cover) `Slider` was handed an oversized, mis-centred frame
/// and drew nothing where it should be, whatever modifiers were applied. Here the width is
/// clamped explicitly and the content re-centred inside the oversized proposal.
struct PlaybackScrubber: View {
    /// 0...1.
    let progress: Double
    /// 0...1, the part that has arrived; for a streamed track.
    let buffered: Double
    let onScrub: (Double) -> Void
    let onScrubEnded: (Double) -> Void

    private static let thumbDiameter: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let width = min(geometry.size.width, PlayerLayout.contentWidth)
            let clamped = progress.isFinite ? min(max(progress, 0), 1) : 0
            let bufferedClamped = buffered.isFinite ? min(max(buffered, 0), 1) : 0
            let thumbX = width * clamped

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25)).frame(width: width, height: 4)
                if bufferedClamped > clamped {
                    Capsule().fill(Color.white.opacity(0.45)).frame(width: width * bufferedClamped, height: 4)
                }
                Capsule().fill(Color.white).frame(width: max(0, thumbX), height: 4)
                Circle().fill(Color.white)
                    .frame(width: Self.thumbDiameter, height: Self.thumbDiameter)
                    .offset(x: min(max(thumbX, 0), width) - Self.thumbDiameter / 2)
            }
            .frame(width: width, height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard width > 0 else { return }
                        onScrub(min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { value in
                        guard width > 0 else { return }
                        onScrubEnded(min(max(value.location.x / width, 0), 1))
                    }
            )
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}
