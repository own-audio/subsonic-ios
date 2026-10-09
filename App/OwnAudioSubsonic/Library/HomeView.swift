import SubsonicKit
import SwiftUI

/// The tab the app opens on: Shuffle All, then what was played lately, what's new, and the
/// playlists. Settings is a gear here rather than a tab of its own.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var recent: [Album] = []
    @State private var newest: [Album] = []
    @State private var playlists: [Playlist] = []
    @State private var state: LoadState<Void> = .loading
    @State private var isShuffling = false
    @State private var isShowingSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Button {
                    shuffleAll()
                } label: {
                    Group {
                        if isShuffling {
                            ProgressView()
                        } else {
                            Label("Shuffle All", systemImage: "shuffle")
                        }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isShuffling)
                .padding(.horizontal, Theme.Spacing.screenEdge)
                .accessibilityIdentifier("home.shuffleAll")

                LoadStateView(state: state, retry: load) { _ in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        if !recent.isEmpty {
                            albumShelf("Recently Played", albums: recent, route: .albums(.recent))
                        }
                        if !newest.isEmpty {
                            albumShelf("Recently Added", albums: newest, route: .albums(.newest))
                        }
                        if !playlists.isEmpty {
                            playlistShelf
                        }
                        if recent.isEmpty, newest.isEmpty, playlists.isEmpty {
                            ContentUnavailableView(
                                "No Music Yet", systemImage: "music.note",
                                description: Text("This server's library is empty.")
                            )
                        }
                    }
                }
                .frame(minHeight: 200)
            }
            .padding(.vertical, Theme.Spacing.md)
        }
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.servers.count > 1 {
                ToolbarItem(placement: .topBarLeading) { serverMenu }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("home.settings")
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            NavigationStack {
                SettingsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingSettings = false }
                                .accessibilityIdentifier("settings.done")
                        }
                    }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    /// With more than one server, which one the library shows is a tap away.
    private var serverMenu: some View {
        Menu {
            Picker("Server", selection: Binding(
                get: { model.activeServerId },
                set: { if let id = $0 { model.selectServer(id: id) } }
            )) {
                ForEach(model.servers) { server in
                    Text(server.displayName).tag(Optional(server.id))
                }
            }
        } label: {
            Label(model.activeServer?.displayName ?? "", systemImage: "server.rack")
        }
        .accessibilityIdentifier("home.serverMenu")
    }

    private func albumShelf(_ title: LocalizedStringKey, albums: [Album], route: Route) -> some View {
        shelf(title, route: route) {
            ForEach(albums) { album in
                NavigationLink(value: Route.album(album)) {
                    AlbumTile(album: album, size: 140).frame(width: 140)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var playlistShelf: some View {
        shelf("Playlists", route: .playlists) {
            ForEach(playlists) { playlist in
                NavigationLink(value: Route.playlist(playlist)) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        CoverArtView(artworkId: model.artworkId(playlist.coverArt), pointSize: 140)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
                        Text(playlist.name).font(.subheadline.weight(.medium)).lineLimit(1)
                        Text(songCountText(playlist.songCount)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 140)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func shelf<Content: View>(_ title: LocalizedStringKey, route: Route, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            NavigationLink(value: route) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(title).font(.title3.bold())
                    Image(systemName: "chevron.right").font(.subheadline.bold()).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.screenEdge)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    content()
                }
                .padding(.horizontal, Theme.Spacing.screenEdge)
            }
        }
    }

    private func load() async {
        guard let client = model.activeClient else { return }
        do {
            async let recentAlbums = client.albumList(.recent, size: 20)
            async let newestAlbums = client.albumList(.newest, size: 20)
            async let allPlaylists = client.playlists()
            newest = try await newestAlbums
            recent = (try? await recentAlbums) ?? []
            playlists = (try? await allPlaylists) ?? []
            state = .loaded(())
        } catch {
            state = .failed(error.userMessage)
        }
    }

    /// A random hundred from the whole library: the server picks, so it works for any size.
    private func shuffleAll() {
        guard let client = model.activeClient else { return }
        Haptics.impact(.medium)
        isShuffling = true
        Task {
            defer { isShuffling = false }
            do {
                let songs = try await client.randomSongs(size: 100)
                model.play(songs, containerId: "shuffle-all")
            } catch {
                model.actionError = error.userMessage
            }
        }
    }
}
