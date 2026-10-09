import PlayerEngine
import SwiftUI

/// The full player: blurred-cover background, large cover, title, a format badge, scrubber,
/// transport, and a row of tools (shuffle, repeat, crossfade, sleep timer, queue, AirPlay).
struct PlayerView: View {
    private enum ActiveSheet: Identifiable {
        case queue, sleepTimer, crossfade
        var id: Self { self }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var seekTarget: Double?
    @State private var isScrubbing = false
    @State private var activeSheet: ActiveSheet?

    private var engine: PlaybackEngine { model.engine }

    var body: some View {
        NavigationStack {
            ZStack {
                ambientBackground
                content
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Close Player")
                    .accessibilityIdentifier("player.close")
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .queue: QueueSheet()
            case .sleepTimer: SleepTimerSheet(timer: engine.sleepTimer)
            case .crossfade: CrossfadeSheet(settings: model.playbackSettings)
            }
        }
        .onChange(of: engine.currentTrack == nil) { _, isEmpty in
            if isEmpty { dismiss() }
        }
        .task(id: engine.currentTrack?.id) {
            if let id = engine.currentTrack?.id { await model.refreshState(trackId: id) }
        }
    }

    /// Kept dark even with no cover, so the white controls stay legible.
    private var ambientBackground: some View {
        ZStack {
            Color.black
            if let track = engine.currentTrack {
                CoverArtView(artworkId: track.artworkId, pointSize: 300)
                    .scaledToFill()
                    .blur(radius: 60)
                    .overlay(Color.black.opacity(0.55))
                    .id(track.id)
                    .transition(.opacity.animation(.easeInOut(duration: Theme.coverCrossfade)))
            }
        }
        .ignoresSafeArea()
    }

    /// `Slider`-style controls go blank on a non-finite value, without crashing; a stream's first
    /// moments can produce one.
    private var currentTimeSafe: Double {
        let value = engine.currentTime
        guard value.isFinite else { return 0 }
        return min(max(value, 0), durationSafe)
    }

    /// Never zero: a 0...0 range is its own invisible control.
    private var durationSafe: Double {
        let value = engine.duration
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }

    private var content: some View {
        // `maxWidth: .infinity` stops the horizontal tool row's content width leaking into
        // the layout of its siblings.
        VStack(spacing: Theme.Spacing.xl) {
            Spacer(minLength: 0)
            cover
            titles
            scrubber
            transport
            if let errorMessage = engine.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("player.error")
            }
            Spacer(minLength: 0)
            tools
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var cover: some View {
        Group {
            if let track = engine.currentTrack {
                CoverArtView(artworkId: track.artworkId, pointSize: PlayerLayout.coverSide)
                    .id(track.id)
                    .transition(.opacity.animation(.easeInOut(duration: Theme.coverCrossfade)))
            } else {
                Rectangle().fill(Color.white.opacity(0.1))
            }
        }
        .frame(width: PlayerLayout.coverSide, height: PlayerLayout.coverSide)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
        .shadow(radius: 16)
        // Swipe the cover left for the next track, right for the previous one. The minimum
        // distance and the horizontal check keep a diagonal touch from skipping.
        .gesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                guard engine.currentTrack != nil, abs(value.translation.width) > abs(value.translation.height) else { return }
                Haptics.impact(.light)
                value.translation.width < 0 ? engine.next() : engine.previous()
            }
        )
        .accessibilityIdentifier("player.cover")
    }

    private var titles: some View {
        VStack(spacing: 4) {
            // The marquee's `GeometryReader` takes all the width offered, so in a plain HStack it
            // pushed the star off screen. It gets an explicit width that leaves room for the star
            // on each side, keeping the title centred.
            ZStack(alignment: .trailing) {
                MarqueeText(text: engine.currentTrack?.title ?? "", font: .title2.bold())
                    .foregroundStyle(.white)
                    .frame(width: PlayerLayout.contentWidth - 2 * Theme.minTarget)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("player.title")
                if let track = engine.currentTrack {
                    let starred = model.isStarred(track.id)
                    Button {
                        Haptics.impact(.light)
                        model.perform { try await model.toggleStar(track.id, kind: .song) }
                    } label: {
                        Image(systemName: starred ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(starred ? Color.yellow : Color.white.opacity(0.8))
                            .frame(width: Theme.minTarget, height: Theme.minTarget)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(starred ? "Unfavorite" : "Favorite")
                    .accessibilityIdentifier("player.star")
                }
            }
            .frame(width: PlayerLayout.contentWidth)
            Text([engine.currentTrack?.artist, engine.currentTrack?.album].compactMap { $0 }.joined(separator: " · "))
                .font(.headline)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .frame(maxWidth: PlayerLayout.contentWidth)
            if let badge = FormatBadge.text(for: engine.currentFormat) {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.top, 2)
                    .accessibilityLabel("Format: \(badge)")
            }
            if let trackIndex = engine.trackIndexDisplay {
                Text("Track \(trackIndex.current) of \(trackIndex.total)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, Theme.Spacing.screenEdge)
    }

    private var scrubber: some View {
        VStack(spacing: Theme.Spacing.xs) {
            PlaybackScrubber(
                progress: (isScrubbing ? (seekTarget ?? currentTimeSafe) : currentTimeSafe) / durationSafe,
                buffered: engine.bufferedTime / durationSafe,
                onScrub: { fraction in
                    if !isScrubbing { Haptics.selection() }
                    isScrubbing = true
                    seekTarget = fraction * durationSafe
                },
                onScrubEnded: { fraction in
                    let target = fraction * durationSafe
                    isScrubbing = false
                    Task { await engine.seek(to: target) }
                }
            )
            // A fixed height: a `GeometryReader` takes all the height it is offered.
            .frame(maxWidth: .infinity)
            .frame(height: Theme.minTarget)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("player.scrubber")
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(formatDuration(currentTimeSafe)) of \(formatDuration(durationSafe))")
            .accessibilityAdjustableAction { direction in
                let step = durationSafe * 0.05
                let target = min(max(currentTimeSafe + (direction == .increment ? step : -step), 0), durationSafe)
                Task { await engine.seek(to: target) }
            }

            HStack {
                Text(formatDuration(isScrubbing ? (seekTarget ?? currentTimeSafe) : currentTimeSafe))
                Spacer()
                Text("-" + formatDuration(max(durationSafe - currentTimeSafe, 0)))
            }
            .frame(maxWidth: PlayerLayout.contentWidth)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Spacing.screenEdge)
    }

    private var transport: some View {
        HStack(spacing: Theme.Spacing.xxl) {
            Button {
                Haptics.impact(.light)
                engine.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title)
                    .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("player.previous")
            .accessibilityLabel("Previous")

            Button {
                Haptics.impact(.medium)
                engine.togglePlayPause()
            } label: {
                Group {
                    if engine.isLoading {
                        ProgressView().tint(.white).controlSize(.large)
                    } else {
                        Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                }
                .frame(width: 72, height: 72)
            }
            .accessibilityIdentifier("player.playPause")
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

            Button {
                Haptics.impact(.light)
                engine.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title)
                    .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                    .contentShape(Rectangle())
            }
            .disabled(!engine.hasNextTrack)
            .accessibilityIdentifier("player.next")
            .accessibilityLabel("Next")
        }
        .foregroundStyle(.white)
    }

    /// Scrolls sideways if it doesn't fit; the same width clamp as the scrubber keeps the row
    /// from starting mid-content.
    private var tools: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    tool(
                        engine.isShuffled ? "shuffle.circle.fill" : "shuffle", "Shuffle",
                        isActive: engine.isShuffled
                    ) {
                        Haptics.selection()
                        engine.setShuffled(!engine.isShuffled)
                    }
                    tool(repeatImage, "Repeat", isActive: engine.repeatMode != .off) {
                        Haptics.selection()
                        engine.setRepeatMode(nextRepeatMode)
                    }
                    .accessibilityValue(repeatValue)
                    tool("waveform.path.ecg", "Crossfade", isActive: model.playbackSettings.crossfadeEnabled) {
                        activeSheet = .crossfade
                    }
                    tool(
                        engine.sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz", "Sleep",
                        isActive: engine.sleepTimer.isActive
                    ) {
                        activeSheet = .sleepTimer
                    }
                    tool("list.bullet", "Queue", isEnabled: engine.currentTrack != nil) {
                        activeSheet = .queue
                    }
                    AirPlayRouteButton()
                        .frame(width: Theme.minTarget, height: Theme.minTarget)
                        .accessibilityLabel("AirPlay")
                }
                .padding(.horizontal, Theme.Spacing.screenEdge)
                .frame(minWidth: min(geometry.size.width, PlayerLayout.columnWidth))
            }
            .frame(width: min(geometry.size.width, PlayerLayout.columnWidth), height: geometry.size.height)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: Theme.minTarget + 20)
    }

    private func tool(
        _ systemImage: String, _ label: LocalizedStringKey, isActive: Bool = false, isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.soft)
            action()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.title3)
                Text(label).font(.caption2)
            }
            .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
            .contentShape(Rectangle())
        }
        .disabled(!isEnabled)
        .foregroundStyle(!isEnabled ? Color.white.opacity(0.3) : isActive ? Color.accentColor : Color.white)
    }

    /// Off → All → One → Off, one button, like Apple Music.
    private var nextRepeatMode: RepeatMode {
        switch engine.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    private var repeatImage: String {
        switch engine.repeatMode {
        case .off: "repeat"
        case .all: "repeat.circle.fill"
        case .one: "repeat.1.circle.fill"
        }
    }

    /// An icon alone gives VoiceOver nothing to tell the three states apart.
    private var repeatValue: Text {
        switch engine.repeatMode {
        case .off: Text("Off")
        case .all: Text("All")
        case .one: Text("One")
        }
    }
}
