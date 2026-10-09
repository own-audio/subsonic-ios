import SwiftUI

/// First run: add a server. After that: Library, Search and Settings, with the mini player
/// above the tab bar and the full player as a cover.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var isShowingPlayer = false

    var body: some View {
        Group {
            if !model.hasLoaded {
                ProgressView()
            } else if model.servers.isEmpty {
                NavigationStack { AddServerView(isOnboarding: true) }
            } else {
                tabs
            }
        }
        .fullScreenCover(isPresented: $isShowingPlayer) {
            PlayerView()
        }
    }

    private var tabs: some View {
        TabView {
            Tab("Library", systemImage: "music.note.house") {
                NavigationStack {
                    LibraryView().libraryDestinations()
                }
                .miniPlayerInset { isShowingPlayer = true }
            }
            Tab("Search", systemImage: "magnifyingglass") {
                NavigationStack {
                    SearchView().libraryDestinations()
                }
                .miniPlayerInset { isShowingPlayer = true }
            }
            Tab("Settings", systemImage: "gear") {
                NavigationStack {
                    SettingsView()
                }
                .miniPlayerInset { isShowingPlayer = true }
            }
        }
        // Switching servers starts every tab over: their screens belong to the old library.
        .id(model.activeServerId)
    }
}

private extension View {
    func miniPlayerInset(onTap: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerBar(onTap: onTap)
        }
    }
}
