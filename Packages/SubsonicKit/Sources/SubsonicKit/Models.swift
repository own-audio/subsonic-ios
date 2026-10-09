import Foundation

/// `ArtistID3`. Servers send many more fields than these; only what the app shows is decoded.
public struct Artist: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let albumCount: Int
    /// A Navidrome extension, so optional: other servers don't send it.
    public let artistImageUrl: String?
    /// When it was starred (an ISO 8601 timestamp), absent if it isn't.
    public let starred: String?

    public init(id: String, name: String, albumCount: Int, artistImageUrl: String?, starred: String? = nil) {
        self.id = id
        self.name = name
        self.albumCount = albumCount
        self.artistImageUrl = artistImageUrl
        self.starred = starred
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
public struct Album: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let artist: String?
    public let artistId: String?
    public let songCount: Int
    public let duration: Int?
    public let coverArt: String?
    public let year: Int?
    public let starred: String?
    /// 1–5, absent if unrated.
    public let userRating: Int?
    public let playCount: Int?

    public init(
        id: String, name: String, artist: String?, artistId: String?, songCount: Int,
        duration: Int?, coverArt: String?, year: Int?, starred: String? = nil,
        userRating: Int? = nil, playCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.artist = artist
        self.artistId = artistId
        self.songCount = songCount
        self.duration = duration
        self.coverArt = coverArt
        self.year = year
        self.starred = starred
        self.userRating = userRating
        self.playCount = playCount
    }
}

/// `Child`, as used for songs. Numbers that aren't set are left out of the JSON rather than
/// sent as null, hence the optionals.
public struct Song: Codable, Identifiable, Sendable, Hashable {
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
    public let starred: String?
    /// 1–5, absent if unrated.
    public let userRating: Int?
    public let playCount: Int?
    /// OpenSubsonic; absent on classic servers and on files without the tags.
    public let replayGain: ReplayGain?

    public init(
        id: String, title: String, album: String? = nil, artist: String? = nil,
        albumId: String? = nil, artistId: String? = nil, track: Int? = nil, discNumber: Int? = nil,
        duration: Int? = nil, genre: String? = nil, coverArt: String? = nil,
        suffix: String? = nil, bitRate: Int? = nil, starred: String? = nil,
        userRating: Int? = nil, playCount: Int? = nil, replayGain: ReplayGain? = nil
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
        self.starred = starred
        self.userRating = userRating
        self.playCount = playCount
        self.replayGain = replayGain
    }
}

/// Loudness normalization values, in dB and as linear peaks (1.0 = full scale).
public struct ReplayGain: Codable, Sendable, Hashable {
    public let trackGain: Double?
    public let albumGain: Double?
    public let trackPeak: Double?
    public let albumPeak: Double?

    public init(trackGain: Double? = nil, albumGain: Double? = nil, trackPeak: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain
        self.albumGain = albumGain
        self.trackPeak = trackPeak
        self.albumPeak = albumPeak
    }

    /// Servers send an empty object for files without the tags.
    public var isEmpty: Bool { trackGain == nil && albumGain == nil }
}

/// One set of lyrics. A server may return several (languages, synced and plain).
public struct Lyrics: Sendable, Hashable {
    public struct Line: Sendable, Hashable {
        /// Milliseconds from the start, for synced lyrics.
        public let startMs: Int?
        public let text: String
    }

    public let lines: [Line]
    public let isSynced: Bool
    /// ISO 639 code; "xxx" or nil when unknown.
    public let language: String?
    /// Added to every start time, in milliseconds.
    public let offsetMs: Int

    public init(lines: [Line], isSynced: Bool, language: String? = nil, offsetMs: Int = 0) {
        self.lines = lines
        self.isSynced = isSynced
        self.language = language
        self.offsetMs = offsetMs
    }

    /// The line playing at `seconds`, for synced lyrics.
    public func lineIndex(at seconds: Double) -> Int? {
        guard isSynced else { return nil }
        let ms = Int(seconds * 1000) - offsetMs
        return lines.lastIndex { ($0.startMs ?? .max) <= ms }
    }
}

public struct Playlist: Codable, Identifiable, Sendable, Hashable {
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

public struct Genre: Codable, Sendable, Hashable, Identifiable {
    /// The genre's name; Subsonic calls it `value`.
    public let value: String
    public let albumCount: Int?
    public let songCount: Int?

    public var id: String { value }

    public init(value: String, albumCount: Int? = nil, songCount: Int? = nil) {
        self.value = value
        self.albumCount = albumCount
        self.songCount = songCount
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
        let starred: String?
        let userRating: Int?
        let playCount: Int?
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

/// Everything the user has starred (`getStarred2`).
public struct StarredResult: Sendable {
    public let artists: [Artist]
    public let albums: [Album]
    public let songs: [Song]

    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
}

struct StarredPayload: Decodable {
    struct Starred: Decodable {
        let artist: [Artist]?
        let album: [Album]?
        let song: [Song]?
    }
    let starred2: Starred
}

struct ExtensionsPayload: Decodable {
    struct Extension: Decodable {
        let name: String
        let versions: [Int]
    }
    let openSubsonicExtensions: [Extension]?
}

struct StructuredLyricsPayload: Decodable {
    struct List: Decodable {
        struct Structured: Decodable {
            struct Line: Decodable {
                let start: Int?
                let value: String
            }
            let lang: String?
            let synced: Bool?
            let offset: Int?
            let line: [Line]?
        }
        let structuredLyrics: [Structured]?
    }
    let lyricsList: List
}

struct ClassicLyricsPayload: Decodable {
    struct Classic: Decodable {
        let value: String?
    }
    let lyrics: Classic?
}

struct GenresPayload: Decodable {
    struct Genres: Decodable { let genre: [Genre]? }
    let genres: Genres
}

struct RandomSongsPayload: Decodable {
    struct Songs: Decodable { let song: [Song]? }
    let randomSongs: Songs
}
