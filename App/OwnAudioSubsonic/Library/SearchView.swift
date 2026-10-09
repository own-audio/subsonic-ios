import SubsonicKit
import SwiftUI

/// Artists, albums and songs matching what is typed, from the server's `search3`.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var result: SearchResult?
    @State private var errorMessage: String?
    @State private var isSearching = false

    var body: some View {
        List {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else if let result {
                if result.isEmpty {
                    ContentUnavailableView.search(text: query)
                        .listRowSeparator(.hidden)
                }
                if !result.artists.isEmpty {
                    Section("Artists") {
                        ForEach(result.artists) { artist in
                            NavigationLink(value: Route.artist(artist)) {
                                HStack(spacing: Theme.Spacing.md) {
                                    ArtistImage(artist: artist, size: 40)
                                    Text(artist.name)
                                }
                            }
                        }
                    }
                }
                if !result.albums.isEmpty {
                    Section("Albums") {
                        ForEach(result.albums) { album in
                            NavigationLink(value: Route.album(album)) {
                                HStack(spacing: Theme.Spacing.md) {
                                    CoverArtView(artworkId: model.artworkId(album.coverArt ?? album.id), pointSize: 44)
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(album.name).lineLimit(1)
                                        Text(album.artist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }
                if !result.songs.isEmpty {
                    Section("Songs") {
                        ForEach(result.songs) { song in
                            Button {
                                Haptics.impact(.light)
                                // Just this song: a search result isn't an album to continue into.
                                model.play([song])
                            } label: {
                                SongRow(song: song, showsCover: true)
                            }
                            .buttonStyle(.plain)
                            .songActions(song)
                        }
                    }
                }
            } else if !isSearching {
                ContentUnavailableView(
                    "Search Your Library", systemImage: "magnifyingglass",
                    description: Text("Artists, albums and songs on \(model.activeServer?.displayName ?? "")")
                )
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .overlay { if isSearching && result == nil { ProgressView() } }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Artists, Albums, Songs")
        .autocorrectionDisabled()
        .task(id: query) { await search() }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            result = nil
            errorMessage = nil
            return
        }
        // Typing cancels this task; only a pause in typing reaches the server.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let client = model.activeClient else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await client.search(text)
            guard !Task.isCancelled else { return }
            model.learn(songs: found.songs)
            model.learn(albums: found.albums)
            result = found
            errorMessage = nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.userMessage
        }
    }
}
