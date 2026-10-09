import Foundation
import SubsonicKit

/// The library as the downloads describe it, for screens with no server to ask. Only the active
/// server's songs, the same scope as the online screens.
extension AppModel {
    private var downloadedOnActiveServer: [DownloadManager.DownloadedTrack] {
        guard let serverId = activeServerId else { return [] }
        return downloads.tracks.values.filter { TrackID.parse($0.trackId)?.serverId == serverId }
    }

    /// In album order: artist, album, disc, track.
    var offlineSongs: [Song] {
        downloadedOnActiveServer.map(\.song).sorted { a, b in
            let keyA = (a.artist ?? "", a.album ?? "", a.discNumber ?? 1, a.track ?? 0)
            let keyB = (b.artist ?? "", b.album ?? "", b.discNumber ?? 1, b.track ?? 0)
            if keyA.0 != keyB.0 { return keyA.0.localizedStandardCompare(keyB.0) == .orderedAscending }
            if keyA.1 != keyB.1 { return keyA.1.localizedStandardCompare(keyB.1) == .orderedAscending }
            if keyA.2 != keyB.2 { return keyA.2 < keyB.2 }
            return keyA.3 < keyB.3
        }
    }

    /// One album per album id among the downloads, newest download first.
    var offlineAlbumsByDownloadDate: [Album] {
        let grouped = Dictionary(grouping: downloadedOnActiveServer) { $0.song.albumId ?? $0.song.album ?? "" }
        return grouped.compactMap { id, items -> (Album, Date)? in
            guard !id.isEmpty, let first = items.first?.song else { return nil }
            let album = Album(
                id: first.albumId ?? id, name: first.album ?? "", artist: first.artist,
                artistId: first.artistId, songCount: items.count,
                duration: items.compactMap(\.song.duration).reduce(0, +),
                coverArt: first.coverArt ?? first.albumId, year: nil
            )
            return (album, items.map(\.downloadedAt).max() ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    var offlineAlbums: [Album] {
        offlineAlbumsByDownloadDate.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var offlineArtists: [Artist] {
        let albums = offlineAlbums
        let grouped = Dictionary(grouping: albums) { $0.artistId ?? $0.artist ?? "" }
        return grouped.compactMap { id, albums -> Artist? in
            guard !id.isEmpty, let name = albums.first?.artist else { return nil }
            return Artist(id: id, name: name, albumCount: albums.count, artistImageUrl: nil)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var offlineGenres: [Genre] {
        let songs = downloadedOnActiveServer.map(\.song)
        let grouped = Dictionary(grouping: songs) { $0.genre ?? "" }
        return grouped.compactMap { name, songs -> Genre? in
            guard !name.isEmpty else { return nil }
            return Genre(value: name, albumCount: Set(songs.compactMap(\.albumId)).count, songCount: songs.count)
        }
        .sorted { $0.value.localizedStandardCompare($1.value) == .orderedAscending }
    }

    func offlineAlbums(artist: Artist) -> [Album] {
        offlineAlbums.filter { $0.artistId == artist.id || ($0.artistId == nil && $0.artist == artist.name) }
    }

    func offlineSongs(albumId: String) -> [Song] {
        offlineSongs.filter { $0.albumId == albumId }
    }

    func offlineSongs(genre: String) -> [Song] {
        offlineSongs.filter { $0.genre == genre }
    }

    func offlineAlbums(genre: String) -> [Album] {
        let ids = Set(offlineSongs(genre: genre).compactMap(\.albumId))
        return offlineAlbums.filter { ids.contains($0.id) }
    }

    /// Downloaded playlists, in the form the playlist screens take.
    var offlinePlaylists: [Playlist] {
        guard let serverId = activeServerId else { return [] }
        return downloads.collections.values
            .filter { $0.kind == .playlist && $0.serverId == serverId }
            .map { Playlist(id: $0.itemId, name: $0.name, comment: nil, owner: nil, songCount: $0.trackIds.count, duration: nil, coverArt: $0.coverArt) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A downloaded playlist's songs that are on the phone, in its order.
    func offlineSongs(playlistId: String) -> [Song]? {
        guard let serverId = activeServerId,
              let collection = downloads.collections[DownloadManager.collectionId(kind: .playlist, serverId: serverId, itemId: playlistId)]
        else { return nil }
        return downloads.songs(in: collection).map(\.song)
    }

    /// Matches in title, artist and album among the downloads.
    func offlineSearch(_ text: String) -> SearchResult {
        let matches = { (value: String?) in value?.localizedCaseInsensitiveContains(text) ?? false }
        return SearchResult(
            artists: offlineArtists.filter { matches($0.name) },
            albums: offlineAlbums.filter { matches($0.name) || matches($0.artist) },
            songs: offlineSongs.filter { matches($0.title) || matches($0.artist) || matches($0.album) }
        )
    }

    /// Whether a song can play right now: always online, only when downloaded offline.
    func isPlayable(_ song: Song) -> Bool {
        guard isOffline else { return true }
        guard let id = compositeId(song.id) else { return false }
        return downloads.isDownloaded(id)
    }
}
