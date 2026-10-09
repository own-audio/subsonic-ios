import PlayerEngine
import SwiftUI

/// What has played and what comes next; tap a track to jump to it.
struct QueueSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var engine: PlaybackEngine { model.engine }

    var body: some View {
        NavigationStack {
            List {
                if let current = engine.currentTrack {
                    Section("Now Playing") {
                        row(current, isCurrent: true)
                    }
                }
                Section("Up Next") {
                    if engine.upcomingTracks.isEmpty {
                        Text("Nothing after this track.").foregroundStyle(.secondary)
                    } else {
                        ForEach(engine.upcomingTracks) { track in
                            Button {
                                engine.jump(toTrackId: track.id)
                                dismiss()
                            } label: {
                                row(track, isCurrent: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !engine.playedTracks.isEmpty {
                    Section("Played") {
                        ForEach(engine.playedTracks) { track in
                            Button {
                                engine.jump(toTrackId: track.id)
                                dismiss()
                            } label: {
                                row(track, isCurrent: false).opacity(0.6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(_ track: Track, isCurrent: Bool) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            CoverArtView(artworkId: track.artworkId, pointSize: 44)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(track.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let secs = track.durationSecs {
                Text(formatDuration(Double(secs))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct SleepTimerSheet: View {
    let timer: SleepTimer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let remaining = timer.remainingSecs {
                    Section {
                        LabeledContent("Time remaining", value: formatDuration(remaining))
                        Button("+10 minutes") { timer.extend(bySecs: 600) }
                        Button("Turn Off Sleep Timer", role: .destructive) {
                            timer.cancel()
                            dismiss()
                        }
                    }
                } else if timer.stopsAtEndOfItem {
                    Section {
                        Text("Stops at the end of this track.")
                        Button("Turn Off Sleep Timer", role: .destructive) {
                            timer.cancel()
                            dismiss()
                        }
                    }
                } else {
                    Section {
                        ForEach(SleepTimer.Preset.allCases) { preset in
                            Button(preset.label) {
                                timer.start(preset: preset)
                                dismiss()
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// Crossfade on or off and its length. Here as well as in Settings, because it is something
/// you change while listening.
struct CrossfadeSheet: View {
    let settings: PlaybackSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                CrossfadeSettings(settings: settings)
            }
            .navigationTitle("Crossfade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct CrossfadeSettings: View {
    let settings: PlaybackSettingsStore

    var body: some View {
        Section {
            Toggle("Crossfade", isOn: Binding(
                get: { settings.crossfadeEnabled },
                set: { settings.setCrossfadeEnabled($0) }
            ))
            .accessibilityIdentifier("settings.crossfade")
            if settings.crossfadeEnabled {
                Stepper(
                    "Fade: \(Int(settings.fadeDurationSecs)) s",
                    value: Binding(get: { settings.fadeDurationSecs }, set: { settings.setFadeDurationSecs($0) }),
                    in: 1...12, step: 1
                )
            }
        } footer: {
            Text(settings.crossfadeEnabled
                ? "Tracks fade into each other near the end."
                : "Tracks play back to back with no gap, so live and classical albums flow as recorded.")
        }
    }
}
