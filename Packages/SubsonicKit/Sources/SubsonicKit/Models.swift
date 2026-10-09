import Foundation

/// `ArtistID3`. Servers send many more fields than these; only what the app shows is decoded.
public struct Artist: Decodable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let albumCount: Int
    /// A Navidrome extension, so optional: other servers don't send it.
    public let artistImageUrl: String?

    public init(id: String, name: String, albumCount: Int, artistImageUrl: String?) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.artistImageUrl = artistImageUrl
    }

    /// Navidrome signs artist images at `size=600`, about 50 KB for a tile that is at most 160
    /// points wide. Measured on a real server: 5.9 KB at 160, 15.8 KB at 300. `size` sits
    /// outside the signature, so it can be rewritten safely.
    public static func displaySizedImageURL(_ raw: String?, size: Int = 320) -> String? {
        guard let raw, var components = URLComponents(string: raw) else { return raw }
        guard var items = components.queryItems, items.contains(where: { $0.name == "size" }) else {
            return raw
        }
        items = items.map { $0.name == "size" ? URLQueryItem(name: "size", value: String(size)) : $0 }
        components.queryItems = items
        return components.url?.absoluteString ?? raw
    }
}

/// `AlbumID3`.
public struct Album: Decodable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let artist: String?
    public let artistId: String?
    public let songCount: Int
    public let duration: Int?
    public let coverArt: String?
    public let year: Int?

    public init(
        id: String, name: String, artist: String?, artistId: String?, songCount: Int,
        duration: Int?, coverArt: String?, year: Int?
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistId = artistId
        self.songCount = songCount
        self.duration = duration
        self.coverArt = coverArt
        self.year = year
    }
}

/// `Child`, as used for songs. Numbers that aren't set are left out of the JSON rather than
/// sent as null, hence the optionals.
public struct Song: Decodable, Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let album: String?
    public let artist: String?
    public let albumId: String?
    public let artistId: String?
    public let track: Int?
    public let discNumber: Int?
    public let duration: Int?
    public let genre: String?
    public let coverArt: String?
    public let suffix: String?
    public let bitRate: Int?

    public init(
        id: String, title: String, album: String? = nil, artist: String? = nil,
        albumId: String? = nil, artistId: String? = nil, track: Int? = nil, discNumber: Int? = nil,
        duration: Int? = nil, genre: String? = nil, coverArt: String? = nil,
        suffix: String? = nil, bitRate: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.album = album
        self.artist = artist
        self.albumId = albumId
        self.artistId = artistId
        self.track = track
        self.discNumber = discNumber
        self.duration = duration
        self.genre = genre
        self.coverArt = coverArt
        self.suffix = suffix
        self.bitRate = bitRate
    }
}

public struct Playlist: Decodable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let comment: String?
    /// The owner's username per the spec. Not every server follows it, so a mismatch should
    /// only hide edit actions, never fail.
    public let owner: String?
    public let songCount: Int
    /// Some servers always send 0; don't show it.
    public let duration: Int?
    public let coverArt: String?

    public init(
        id: String, name: String, comment: String?, owner: String?, songCount: Int,
        duration: Int?, coverArt: String?
    ) {
        self.id = id
        self.name = name
        self.comment = comment
        self.owner = owner
        self.songCount = songCount
        self.duration = duration
        self.coverArt = coverArt
    }
}

public struct SearchResult: Sendable {
    public let artists: [Artist]
    public let albums: [Album]
    public let songs: [Song]

    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

// MARK: - Response payloads

/// `{"subsonic-response": {"status": …, <payload key>: …}}`. Each endpoint decodes its own
/// payload key from the same object the status is read from.
struct SubsonicEnvelope<Payload: Decodable>: Decodable {
    let response: Payload

    private enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}

struct SubsonicStatus: Decodable {
    let status: String
}

struct ArtistsPayload: Decodable {
    struct Artists: Decodable {
        struct Index: Decodable { let artist: [Artist]? }
        let index: [Index]?
    }
    let artists: Artists

    var flattened: [Artist] { (artists.index ?? []).flatMap { $0.artist ?? [] } }
}

struct ArtistPayload: Decodable {
    struct ArtistDetail: Decodable {
        let id: String
        let name: String
        let album: [Album]?
        let artistImageUrl: String?
    }
    let artist: ArtistDetail
}

struct AlbumListPayload: Decodable {
    struct AlbumList2: Decodable { let album: [Album]? }
    let albumList2: AlbumList2
}

struct AlbumPayload: Decodable {
    struct AlbumDetail: Decodable {
        let id: String
        let name: String
        let artist: String?
        let artistId: String?
        let duration: Int?
        let coverArt: String?
        let year: Int?
        let song: [Song]?
    }
    let album: AlbumDetail
}

struct SongPayload: Decodable {
    let song: Song
}

struct SearchPayload: Decodable {
    struct Result: Decodable {
        let artist: [Artist]?
        let album: [Album]?
        let song: [Song]?
    }
    let searchResult3: Result
}

struct PlaylistsPayload: Decodable {
    struct Playlists: Decodable { let playlist: [Playlist]? }
    let playlists: Playlists
}

struct PlaylistPayload: Decodable {
    struct PlaylistDetail: Decodable {
        let id: String
        let name: String
        let comment: String?
        let owner: String?
        let songCount: Int
        let duration: Int?
        let coverArt: String?
        let entry: [Song]?
    }
    let playlist: PlaylistDetail
}

struct CreatePlaylistPayload: Decodable {
    let playlist: Playlist
}
