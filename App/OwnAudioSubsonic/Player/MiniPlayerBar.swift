import PlayerEngine
import SwiftUI

/// Sits above the tab bar while something is loaded: a thin progress line (with the
/// still-arriving part of a streamed track shown lighter), cover, title, play/pause and next.
struct MiniPlayerBar: View {
    @Environment(AppModel.self) private var model
    let onTap: () -> Void

    private var engine: PlaybackEngine { model.engine }

    var body: some View {
        if let track = engine.currentTrack {
            VStack(spacing: 0) {
                progressLine
                Button {
                    Haptics.impact(.medium)
                    onTap()
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        CoverArtView(artworkId: track.artworkId, pointSize: 40)
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(track.artist ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        if engine.isLoading {
                            ProgressView().frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                        } else {
                            Button {
                                Haptics.impact(.medium)
                                engine.togglePlayPause()
                            } label: {
                                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                                    .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("miniPlayer.playPause")
                            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
                        }

                        if engine.hasNextTrack {
                            Button {
                                Haptics.impact(.light)
                                engine.next()
                            } label: {
                                Image(systemName: "forward.fill")
                                    .font(.subheadline)
                                    .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("miniPlayer.next")
                            .accessibilityLabel("Next")
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    // Without this only the drawn parts are tappable, not the gap after the title.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("miniPlayer")
                .accessibilityHint("Opens the player")
            }
            .background {
                // Material alone is barely visible over a white or black list; the tint gives
                // the bar an edge.
                RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer)
                    .fill(.regularMaterial)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer).fill(Color.accentColor.opacity(0.15)))
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer))
            .padding(.horizontal, Theme.Spacing.screenEdge)
            .padding(.bottom, Theme.Spacing.xs)
        }
    }

    /// Two fills on one track, played and buffered; `ProgressView` has no second value.
    private var progressLine: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = engine.duration
            let played = duration > 0 ? min(max(engine.currentTime / duration, 0), 1) : 0
            let buffered = duration > 0 ? min(max(engine.bufferedTime / duration, 0), 1) : 0
            ZStack(alignment: .leading) {
                Rectangle().fill(Color(.secondarySystemFill))
                if buffered > played {
                    Rectangle().fill(Color.accentColor.opacity(0.3)).frame(width: width * buffered)
                }
                Rectangle().fill(Color.accentColor).frame(width: width * played)
            }
        }
        .frame(height: 2)
        .accessibilityHidden(true)
    }
}
