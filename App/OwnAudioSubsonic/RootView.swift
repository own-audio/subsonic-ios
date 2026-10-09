import SwiftUI

/// First run: add a server. After that four tabs, as in own.audio's music app: Home, Library,
/// Playlists and Search, with the mini player above the tab bar and the full player as a cover.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingPlayer = false

    var body: some View {
        Group {
            if !model.hasLoaded {
                ProgressView()
            } else if model.servers.isEmpty {
                OnboardingView()
            } else {
                tabs
            }
        }
        .fullScreenCover(isPresented: $isShowingPlayer) {
            PlayerView()
        }
        .alert(
            "That Didn't Work",
            isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.actionError ?? "")
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Home", systemImage: "house") {
                NavigationStack {
                    HomeView().libraryDestinations()
                }
                .miniPlayerInset { isShowingPlayer = true }
            }
            Tab("Library", systemImage: "square.stack") {
                LibraryTab()
                    .miniPlayerInset { isShowingPlayer = true }
            }
            Tab("Playlists", systemImage: "music.note.list") {
                NavigationStack {
                    PlaylistsView().libraryDestinations()
                }
                .miniPlayerInset { isShowingPlayer = true }
            }
            // The search role puts it in its own capsule at the trailing edge, as in Apple's apps.
            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                NavigationStack {
                    SearchView().libraryDestinations()
                }
                .miniPlayerInset { isShowingPlayer = true }
            }
        }
        // Switching servers starts every tab over: their screens belong to the old library.
        .id(model.activeServerId)
    }
}

/// A grid of sections on iPhone; on iPad, a sidebar beside the open section.
private struct LibraryTab: View {
    private enum SidebarItem: Hashable {
        case section(LibrarySection)
        case downloads
    }

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: SidebarItem? = .section(.artists)

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List(selection: $selection) {
                    ForEach(LibrarySection.allCases) { section in
                        Label(section.title, systemImage: section.systemImage)
                            .tag(SidebarItem.section(section))
                            .accessibilityIdentifier("library.\(section.rawValue)")
                    }
                    Label("Downloads", systemImage: "arrow.down.circle")
                        .tag(SidebarItem.downloads)
                        .accessibilityIdentifier("library.downloads")
                }
                .navigationTitle("Library")
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            } detail: {
                NavigationStack {
                    detail.libraryDestinations()
                }
                .id(selection)
            }
        } else {
            NavigationStack {
                LibraryView().libraryDestinations()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .section(.artists): ArtistsView()
        case .section(.albums): AlbumsView(initialType: .alphabeticalByName)
        case .section(.songs): SongsView()
        case .section(.genres): GenresView()
        case .section(.favorites): FavoritesView()
        case .downloads: DownloadsView()
        case nil: ContentUnavailableView("Pick a Section", systemImage: "square.stack")
        }
    }
}

private extension View {
    func miniPlayerInset(onTap: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar(onTap: onTap)
        }
    }
}
