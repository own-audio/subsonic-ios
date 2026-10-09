import SubsonicKit
import SwiftUI

struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[Playlist]> = .loading

    var body: some View {
        LoadStateView(state: state, retry: load) { playlists in
            if playlists.isEmpty {
                ContentUnavailableView(
                    "No Playlists", systemImage: "music.note.list",
                    description: Text("Playlists made on the server appear here.")
                )
            } else {
                List(playlists) { playlist in
                    NavigationLink(value: Route.playlist(playlist)) {
                        HStack(spacing: Theme.Spacing.md) {
                            CoverArtView(artworkId: model.artworkId(playlist.coverArt), pointSize: 56)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).lineLimit(1)
                                Text("\(playlist.songCount) songs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Playlists")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            state = .loaded(try await client.playlists())
        } catch {
            state = .failed(error.userMessage)
        }
    }
}

struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    let playlist: Playlist
    @State private var state: LoadState<[Song]> = .loading

    var body: some View {
        List {
            Section {
                VStack(spacing: Theme.Spacing.md) {
                    CoverArtView(artworkId: model.artworkId(playlist.coverArt), pointSize: 200)
                        .frame(width: 200, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
                    Text(playlist.name).font(.title2.bold()).multilineTextAlignment(.center)
                    if let comment = playlist.comment, !comment.isEmpty {
                        Text(comment).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    PlayShuffleButtons(isEnabled: songs?.isEmpty == false) {
                        if let songs { model.play(songs, containerId: "playlist:\(playlist.id)") }
                    } shuffle: {
                        if let songs { model.play(songs, shuffled: true, containerId: "playlist:\(playlist.id)") }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.sm)
            }
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            LoadStateView(state: state, retry: load) { songs in
                ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                    Button {
                        Haptics.impact(.light)
                        model.play(songs, startSongId: song.id, containerId: "playlist:\(playlist.id)")
                    } label: {
                        SongRow(song: song, showsCover: true)
                    }
                    .buttonStyle(.plain)
                }
                if !songs.isEmpty {
                    Text(songsSummary(songs))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var songs: [Song]? {
        if case .loaded(let songs) = state { songs } else { nil }
    }

    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            state = .loaded(try await client.playlist(id: playlist.id).songs)
        } catch {
            state = .failed(error.userMessage)
        }
    }
}
