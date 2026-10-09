import MusicEngine
import SubsonicKit
import SwiftUI

/// Lyrics for the playing track. Synced lyrics follow the music, the current line bright and
/// centred, and a tap on a line jumps there; plain lyrics just scroll.
struct LyricsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var state: LoadState<[Lyrics]> = .loading
    @State private var choice = 0

    private var engine: PlaybackEngine { model.engine }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                LoadStateView(state: state, retry: load) { all in
                    if all.isEmpty {
                        ContentUnavailableView(
                            "No Lyrics", systemImage: "quote.bubble",
                            description: Text("The server has no lyrics for this song. Navidrome reads them from the file's tags or an .lrc file next to it.")
                        )
                        .foregroundStyle(.white)
                    } else {
                        lyricsBody(all[min(choice, all.count - 1)])
                    }
                }
            }
            .navigationTitle(engine.currentTrack?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if case .loaded(let all) = state, all.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Picker("Version", selection: $choice) {
                            ForEach(Array(all.enumerated()), id: \.offset) { index, lyrics in
                                Text(label(for: lyrics)).tag(index)
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: engine.currentTrack?.id) { await load() }
    }

    @ViewBuilder
    private func lyricsBody(_ lyrics: Lyrics) -> some View {
        let current = lyrics.lineIndex(at: engine.currentTime)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.title2.bold())
                            .foregroundStyle(lyrics.isSynced
                                ? (index == current ? Color.white : Color.white.opacity(0.35))
                                : Color.white.opacity(0.9))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard let start = line.startMs else { return }
                                Haptics.selection()
                                Task { await engine.seek(to: Double(start + lyrics.offsetMs) / 1000) }
                            }
                            .id(index)
                            .accessibilityAddTraits(index == current ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, 200)
            }
            .onChange(of: current) { _, line in
                guard let line else { return }
                withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(line, anchor: .center) }
            }
            .accessibilityIdentifier(lyrics.isSynced ? "lyrics.synced" : "lyrics.plain")
        }
    }

    private func label(for lyrics: Lyrics) -> String {
        let language = lyrics.language.flatMap { $0 == "xxx" ? nil : Locale.current.localizedString(forLanguageCode: $0) }
        let kind = lyrics.isSynced ? String(localized: "Synced") : String(localized: "Plain")
        return [language, kind].compactMap { $0 }.joined(separator: " · ")
    }

    private func load() async {
        choice = 0
        guard let track = engine.currentTrack else { return }
        state = .loading
        do {
            state = .loaded(try await model.lyrics(for: track))
        } catch {
            state = .failed(error.userMessage)
        }
    }
}
