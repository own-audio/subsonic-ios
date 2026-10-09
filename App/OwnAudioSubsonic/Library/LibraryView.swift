import SubsonicKit
import SwiftUI

/// The Library tab's first screen: links into the library, then recently added and recently
/// played albums.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var newest: LoadState<[Album]> = .loading
    @State private var recent: [Album] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(spacing: 0) {
                    link("Artists", systemImage: "music.mic", route: .artists)
                    Divider().padding(.leading, 52)
                    link("Albums", systemImage: "square.stack", route: .albums(.alphabeticalByName))
                    Divider().padding(.leading, 52)
                    link("Playlists", systemImage: "music.note.list", route: .playlists)
                    Divider().padding(.leading, 52)
                    link("Favorites", systemImage: "star", route: .albums(.starred))
                }
                .padding(.horizontal, Theme.Spacing.screenEdge)

                LoadStateView(state: newest, retry: load) { albums in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        if !recent.isEmpty {
                            shelf("Recently Played", albums: recent, route: .albums(.recent))
                        }
                        if albums.isEmpty {
                            ContentUnavailableView(
                                "No Music Yet", systemImage: "music.note",
                                description: Text("This server's library is empty.")
                            )
                        } else {
                            shelf("Recently Added", albums: albums, route: .albums(.newest))
                        }
                    }
                }
                .frame(minHeight: 200)
            }
            .padding(.vertical, Theme.Spacing.md)
        }
        .navigationTitle(model.activeServer?.displayName ?? String(localized: "Library"))
        .refreshable { await load() }
        .task { await load() }
    }

    private func link(_ title: LocalizedStringKey, systemImage: String, route: Route) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                Text(title).font(.title3)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(.vertical, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func shelf(_ title: LocalizedStringKey, albums: [Album], route: Route) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            NavigationLink(value: route) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(title).font(.title2.bold())
                    Image(systemName: "chevron.right").font(.headline).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.screenEdge)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    ForEach(albums) { album in
                        NavigationLink(value: Route.album(album)) {
                            AlbumTile(album: album, size: 150).frame(width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Spacing.screenEdge)
            }
        }
    }

    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            async let newestAlbums = client.albumList(.newest, size: 20)
            async let recentAlbums = client.albumList(.recent, size: 20)
            let loaded = try await newestAlbums
            recent = (try? await recentAlbums) ?? []
            newest = .loaded(loaded)
        } catch {
            newest = .failed(error.userMessage)
        }
    }
}
