import SubsonicKit
import SwiftUI

struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    let artist: Artist
    @State private var state: LoadState<[Album]> = .loading
    @State private var isStarting = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                ArtistImage(artist: artist, size: 160)
                    .padding(.top, Theme.Spacing.md)
                Text(artist.name)
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.screenEdge)

                PlayShuffleButtons(isEnabled: !isStarting && !(albums?.isEmpty ?? true)) {
                    playAll(shuffled: false)
                } shuffle: {
                    playAll(shuffled: true)
                }
                .padding(.horizontal, Theme.Spacing.screenEdge)

                LoadStateView(state: state, retry: load) { albums in
                    AlbumGrid(albums: albums)
                }
                .frame(minHeight: 200)
            }
            .padding(.bottom, Theme.Spacing.xl)
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let id = model.compositeId(artist.id) {
                ToolbarItem(placement: .topBarTrailing) {
                    let starred = model.isStarred(id)
                    Button {
                        Haptics.selection()
                        model.perform { try await model.toggleStar(id, kind: .artist) }
                    } label: {
                        Image(systemName: starred ? "star.fill" : "star")
                    }
                    .accessibilityLabel(starred ? "Unfavorite Artist" : "Favorite Artist")
                }
            }
        }
        .onAppear {
            // The artist list says whether it is starred; remember that for the button.
            if artist.starred != nil, let id = model.compositeId(artist.id) { model.noteStarred(id) }
        }
        .task { await load() }
    }

    private var albums: [Album]? {
        if case .loaded(let albums) = state { albums } else { nil }
    }

    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            state = .loaded(try await client.artist(id: artist.id).albums)
        } catch {
            state = .failed(error.userMessage)
        }
    }

    /// Fetches every album's songs, so this costs one request per album.
    private func playAll(shuffled: Bool) {
        guard let albums, let client = model.activeClient else { return }
        isStarting = true
        Task {
            defer { isStarting = false }
            var songs: [Song] = []
            for album in albums {
                if let loaded = try? await client.album(id: album.id).songs { songs += loaded }
            }
            model.play(songs, shuffled: shuffled, containerId: "artist:\(artist.id)")
        }
    }
}
