import PlayerEngine
import SubsonicKit
import SwiftUI

/// Where a library screen can lead. One `navigationDestination` per tab resolves these.
enum Route: Hashable {
    case artist(Artist)
    case album(Album)
    case playlist(Playlist)
    case albums(AlbumListType)
    case artists
    case playlists
    case favorites
}

extension View {
    func libraryDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .artist(let artist): ArtistDetailView(artist: artist)
            case .album(let album): AlbumDetailView(album: album)
            case .playlist(let playlist): PlaylistDetailView(playlist: playlist)
            case .albums(let type): AlbumsView(initialType: type)
            case .artists: ArtistsView()
            case .playlists: PlaylistsView()
            case .favorites: FavoritesView()
            }
        }
    }
}

extension AppModel {
    /// A cover id from the active server, in the composite form `CoverArtLoader` takes.
    func artworkId(_ coverId: String?) -> String? {
        guard let coverId, let serverId = activeServerId else { return nil }
        return TrackID.make(serverId: serverId, itemId: coverId)
    }
}

extension AlbumListType {
    var title: LocalizedStringKey {
        switch self {
        case .newest: "Recently Added"
        case .recent: "Recently Played"
        case .frequent: "Most Played"
        case .random: "Random"
        case .alphabeticalByName: "By Title"
        case .alphabeticalByArtist: "By Artist"
        case .starred: "Favorites"
        case .highest: "Top Rated"
        }
    }
}

/// Loading, failed or loaded, for screens that fetch once on appear.
enum LoadState<Value> {
    case loading
    case failed(String)
    case loaded(Value)
}

/// The spinner / error-with-retry / content switch every library screen needs.
struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await retry() } }
                    .buttonStyle(.bordered)
            }
        case .loaded(let value):
            content(value)
        }
    }
}

struct AlbumTile: View {
    @Environment(AppModel.self) private var model
    let album: Album
    var size: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            CoverArtView(artworkId: model.artworkId(album.coverArt ?? album.id), pointSize: size)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
            Text(album.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(album.artist ?? "")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AlbumGrid: View {
    let albums: [Album]
    /// Called when the last tile appears, for paging.
    var onReachEnd: (() -> Void)?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.lg)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: Theme.Spacing.xl) {
            ForEach(albums) { album in
                NavigationLink(value: Route.album(album)) {
                    AlbumTile(album: album)
                }
                .buttonStyle(.plain)
                .onAppear { if album.id == albums.last?.id { onReachEnd?() } }
            }
        }
        .padding(.horizontal, Theme.Spacing.screenEdge)
    }
}

/// A song in a list: number or cover, title, artist, duration, and a marker on the one playing.
struct SongRow: View {
    @Environment(AppModel.self) private var model
    let song: Song
    var showsCover = false
    var showsTrackNumber = true

    private var isCurrent: Bool {
        guard let current = model.engine.currentTrack, let serverId = model.activeServerId else { return false }
        return current.id == TrackID.make(serverId: serverId, itemId: song.id)
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if showsCover {
                CoverArtView(artworkId: model.artworkId(song.coverArt ?? song.albumId), pointSize: 44)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if showsTrackNumber {
                Group {
                    if isCurrent {
                        Image(systemName: model.engine.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundStyle(.tint)
                    } else {
                        Text(song.track.map(String.init) ?? "")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline.monospacedDigit())
                .frame(width: 28, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if let artist = song.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let id = model.compositeId(song.id), model.isStarred(id) {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("Favorite")
            }
            if let duration = song.duration {
                Text(formatDuration(Double(duration)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Play and Shuffle, side by side, under a detail header.
struct PlayShuffleButtons: View {
    let isEnabled: Bool
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button {
                Haptics.impact(.medium)
                play()
            } label: {
                Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("detail.play")
            Button {
                Haptics.impact(.medium)
                shuffle()
            } label: {
                Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("detail.shuffle")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!isEnabled)
    }
}

/// Total running time of a list of songs, e.g. "12 songs, 48 min".
func songsSummary(_ songs: [Song]) -> String {
    let seconds = songs.compactMap(\.duration).reduce(0, +)
    let minutes = Int((Double(seconds) / 60).rounded())
    return minutes > 0
        ? String(localized: "\(songs.count) songs, \(minutes) min")
        : String(localized: "\(songs.count) songs")
}
