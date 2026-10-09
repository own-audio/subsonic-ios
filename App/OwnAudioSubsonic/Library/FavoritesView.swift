import SubsonicKit
import SwiftUI

/// Everything starred on the server, split into songs, albums and artists.
struct FavoritesView: View {
    private enum Kind: Hashable { case songs, albums, artists }

    @Environment(AppModel.self) private var model
    @State private var state: LoadState<StarredResult> = .loading
    @State private var kind: Kind = .songs

    var body: some View {
        LoadStateView(state: state, retry: load) { starred in
            List {
                Picker("Show", selection: $kind) {
                    Text("Songs (\(starred.songs.count))").tag(Kind.songs)
                    Text("Albums (\(starred.albums.count))").tag(Kind.albums)
                    Text("Artists (\(starred.artists.count))").tag(Kind.artists)
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)

                switch kind {
                case .songs: songs(starred.songs)
                case .albums: albums(starred.albums)
                case .artists: artists(starred.artists)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Favorites")
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func songs(_ songs: [Song]) -> some View {
        if songs.isEmpty {
            empty("No favorite songs", hint: "Long-press a song and choose Favorite.")
        } else {
            PlayShuffleButtons(isEnabled: true) {
                model.play(songs, containerId: "favorites")
            } shuffle: {
                model.play(songs, shuffled: true, containerId: "favorites")
            }
            .listRowSeparator(.hidden)
            ForEach(songs) { song in
                Button {
                    Haptics.impact(.light)
                    model.play(songs, startSongId: song.id, containerId: "favorites")
                } label: {
                    SongRow(song: song, showsCover: true)
                }
                .buttonStyle(.plain)
                .songActions(song)
            }
        }
    }

    @ViewBuilder
    private func albums(_ albums: [Album]) -> some View {
        if albums.isEmpty {
            empty("No favorite albums", hint: "Tap the star on an album.")
        } else {
            ForEach(albums) { album in
                NavigationLink(value: Route.album(album)) {
                    HStack(spacing: Theme.Spacing.md) {
                        CoverArtView(artworkId: model.artworkId(album.coverArt ?? album.id), pointSize: 56)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.name).lineLimit(1)
                            Text(album.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func artists(_ artists: [Artist]) -> some View {
        if artists.isEmpty {
            empty("No favorite artists", hint: "Tap the star on an artist.")
        } else {
            ForEach(artists) { artist in
                NavigationLink(value: Route.artist(artist)) {
                    HStack(spacing: Theme.Spacing.md) {
                        ArtistImage(artist: artist, size: 44)
                        Text(artist.name)
                    }
                }
            }
        }
    }

    private func empty(_ title: LocalizedStringKey, hint: LocalizedStringKey) -> some View {
        ContentUnavailableView(title, systemImage: "star", description: Text(hint))
            .listRowSeparator(.hidden)
    }

    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            let starred = try await client.starred()
            model.learn(songs: starred.songs)
            model.learn(albums: starred.albums)
            state = .loaded(starred)
        } catch {
            state = .failed(error.userMessage)
        }
    }
}
