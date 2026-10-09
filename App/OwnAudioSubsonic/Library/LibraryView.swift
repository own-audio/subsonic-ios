import SubsonicKit
import SwiftUI

/// The Library tab's sections.
enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case artists, albums, songs, genres, favorites

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .artists: "Artists"
        case .albums: "Albums"
        case .songs: "Songs"
        case .genres: "Genres"
        case .favorites: "Favorites"
        }
    }

    var systemImage: String {
        switch self {
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genres: "guitars"
        case .favorites: "star"
        }
    }

    var route: Route {
        switch self {
        case .artists: .artists
        case .albums: .albums(.alphabeticalByName)
        case .songs: .songs
        case .genres: .genres
        case .favorites: .favorites
        }
    }
}

/// The Library tab's root on iPhone: a grid of sections. Downloads is a toolbar button.
struct LibraryView: View {
    private let columns = [
        GridItem(.flexible(), spacing: Theme.Spacing.md),
        GridItem(.flexible(), spacing: Theme.Spacing.md),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Theme.Spacing.md) {
                ForEach(LibrarySection.allCases) { section in
                    NavigationLink(value: section.route) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Image(systemName: section.systemImage)
                                .font(.title2)
                                .foregroundStyle(.tint)
                            Text(section.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                        .padding(Theme.Spacing.lg)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("library.\(section.rawValue)")
                }
            }
            .padding(Theme.Spacing.screenEdge)
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { DownloadsButton() }
        }
    }
}

struct DownloadsButton: View {
    var body: some View {
        NavigationLink(value: Route.downloads) {
            Label("Downloads", systemImage: "arrow.down.circle")
        }
        .accessibilityIdentifier("library.downloads")
    }
}

/// Every song, a page at a time, in the server's search order.
struct SongsView: View {
    @Environment(AppModel.self) private var model
    @State private var songs: [Song] = []
    @State private var state: LoadState<Void> = .loading
    @State private var isLoadingMore = false
    @State private var reachedEnd = false

    private static let pageSize = 100

    var body: some View {
        LoadStateView(state: state, retry: reload) { _ in
            if songs.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "music.note")
            } else {
                List {
                    PlayShuffleButtons(isEnabled: true) {
                        model.play(songs, containerId: "songs")
                    } shuffle: {
                        model.play(songs, shuffled: true, containerId: "songs")
                    }
                    .listRowSeparator(.hidden)
                    ForEach(songs) { song in
                        Button {
                            Haptics.impact(.light)
                            model.play(songs, startSongId: song.id, containerId: "songs")
                        } label: {
                            SongRow(song: song, showsCover: true)
                        }
                        .buttonStyle(.plain)
                        .songActions(song)
                        .onAppear { if song.id == songs.last?.id { loadMore() } }
                    }
                    if isLoadingMore { ProgressView().frame(maxWidth: .infinity) }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Songs")
        .refreshable { await reload() }
        .task(id: model.isOffline) { await reload() }
    }

    private func reload() async {
        if model.isOffline {
            songs = model.offlineSongs
            reachedEnd = true
            state = .loaded(())
            return
        }
        guard let client = model.activeClient else { return }
        do {
            let page = try await client.songs(size: Self.pageSize)
            songs = page
            reachedEnd = page.count < Self.pageSize
            model.learn(songs: page)
            state = .loaded(())
        } catch {
            state = .failed(error.userMessage)
        }
    }

    /// Stops when a page brings nothing new, as well as on a short page: a server that ignores
    /// the offset would otherwise hand back the first page for ever.
    private func loadMore() {
        guard !isLoadingMore, !reachedEnd, let client = model.activeClient else { return }
        isLoadingMore = true
        Task {
            defer { isLoadingMore = false }
            guard let page = try? await client.songs(size: Self.pageSize, offset: songs.count) else { return }
            let known = Set(songs.map(\.id))
            let fresh = page.filter { !known.contains($0.id) }
            reachedEnd = page.count < Self.pageSize || fresh.isEmpty
            songs += fresh
            model.learn(songs: fresh)
        }
    }
}

struct GenresView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<[Genre]> = .loading

    var body: some View {
        LoadStateView(state: state, retry: load) { genres in
            if genres.isEmpty {
                ContentUnavailableView("No Genres", systemImage: "guitars")
            } else {
                List(genres) { genre in
                    NavigationLink(value: Route.genre(genre)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(genre.value)
                            if let albums = genre.albumCount, let songs = genre.songCount {
                                Text("\(albumCountText(albums)) · \(songCountText(songs))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Genres")
        .refreshable { await load() }
        .task(id: model.isOffline) { await load() }
    }

    private func load() async {
        if model.isOffline {
            state = .loaded(model.offlineGenres)
            return
        }
        guard let client = model.activeClient else { return }
        do {
            state = .loaded(try await client.genres())
        } catch {
            state = .failed(error.userMessage)
        }
    }
}

/// A genre's albums, and a shuffle across its songs.
struct GenreView: View {
    @Environment(AppModel.self) private var model
    let genre: Genre
    @State private var state: LoadState<[Album]> = .loading
    @State private var isShuffling = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.lg) {
                Button {
                    shuffle()
                } label: {
                    Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isShuffling)
                .padding(.horizontal, Theme.Spacing.screenEdge)
                LoadStateView(state: state, retry: load) { albums in
                    AlbumGrid(albums: albums)
                }
                .frame(minHeight: 200)
            }
            .padding(.vertical, Theme.Spacing.md)
        }
        .navigationTitle(genre.value)
        .task(id: model.isOffline) { await load() }
    }

    private func load() async {
        if model.isOffline {
            state = .loaded(model.offlineAlbums(genre: genre.value))
            return
        }
        guard let client = model.activeClient else { return }
        do {
            state = .loaded(try await client.albums(genre: genre.value, size: 200))
        } catch {
            state = .failed(error.userMessage)
        }
    }

    private func shuffle() {
        guard let client = model.activeClient else { return }
        if model.isOffline {
            model.play(model.offlineSongs(genre: genre.value), shuffled: true, containerId: "genre:\(genre.value)")
            return
        }
        isShuffling = true
        Task {
            defer { isShuffling = false }
            do {
                model.play(try await client.randomSongs(size: 100, genre: genre.value), containerId: "genre:\(genre.value)")
            } catch {
                model.actionError = error.userMessage
            }
        }
    }
}

/// "1 album", "12 albums".
func albumCountText(_ count: Int) -> String {
    count == 1 ? String(localized: "1 album") : String(localized: "\(count) albums")
}
