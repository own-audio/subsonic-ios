import SubsonicKit
import SwiftUI

/// Every album, in one of the server's list orders, loaded a page at a time.
struct AlbumsView: View {
    @Environment(AppModel.self) private var model
    @State private var type: AlbumListType
    @State private var state: LoadState<[Album]> = .loading
    @State private var isLoadingMore = false
    @State private var reachedEnd = false

    private static let pageSize = 60
    private static let choices: [AlbumListType] = [
        .alphabeticalByName, .alphabeticalByArtist, .newest, .recent, .frequent, .random, .starred,
    ]

    init(initialType: AlbumListType) {
        _type = State(initialValue: initialType)
    }

    var body: some View {
        LoadStateView(state: state, retry: reload) { albums in
            if albums.isEmpty {
                ContentUnavailableView(
                    type == .starred ? "No Favorites" : "No Albums",
                    systemImage: type == .starred ? "star" : "square.stack"
                )
            } else {
                ScrollView {
                    AlbumGrid(albums: albums) { loadMore() }
                        .padding(.vertical, Theme.Spacing.md)
                    if isLoadingMore { ProgressView().padding() }
                }
            }
        }
        .navigationTitle(type == .starred ? "Favorites" : "Albums")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $type) {
                        ForEach(Self.choices, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityIdentifier("albums.sort")
            }
        }
        .refreshable { await reload() }
        .task(id: type) { await reload() }
    }

    private func reload() async {
        guard let client = model.activeClient else { return }
        reachedEnd = false
        do {
            let page = try await client.albumList(type, size: Self.pageSize)
            reachedEnd = page.count < Self.pageSize || type == .random
            state = .loaded(page)
        } catch {
            state = .failed(error.userMessage)
        }
    }

    private func loadMore() {
        guard !isLoadingMore, !reachedEnd, case .loaded(let albums) = state, let client = model.activeClient else { return }
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await client.albumList(type, size: Self.pageSize, offset: albums.count) else { return }
            reachedEnd = page.count < Self.pageSize
            // A server can repeat an album across pages if the library changed in between.
            let known = Set(albums.map(\.id))
            state = .loaded(albums + page.filter { !known.contains($0.id) })
        }
    }
}
