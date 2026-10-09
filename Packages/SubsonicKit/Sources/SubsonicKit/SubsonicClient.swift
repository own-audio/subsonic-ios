import CryptoKit
import Foundation

/// A client for any Subsonic or OpenSubsonic server (Navidrome, Gonic, Airsonic, LMS, …).
///
/// Auth is the token+salt scheme: `t = md5(password + salt)` with a fresh salt per request.
/// Every Subsonic server supports it, and the password never goes over the wire. The protocol
/// has no login step, so the password itself has to be kept (see `ServerStore`).
public struct SubsonicClient: Sendable {
    public enum SubsonicError: Error, Sendable, Equatable {
        case wrongCredentials
        case notAuthorized
        case http(Int)
        case server(code: Int, message: String)
        case decoding
        case network
    }

    public let host: URL
    public let username: String
    private let password: String
    private let clientName: String
    private let session: URLSession

    /// Servers use the version only to decide which optional fields to send; none reject an
    /// older one.
    static let apiVersion = "1.16.1"

    public init(
        host: URL, username: String, password: String,
        clientName: String = "own.audio-subsonic", session: URLSession = .shared
    ) {
        self.host = host
        self.username = username
        self.password = password
        self.clientName = clientName
        self.session = session
    }

    /// Accepts "host", "host:port" or a full URL. Defaults to http because most home servers
    /// have no TLS on the local network; an explicit https:// is kept.
    public static func normalizeHost(_ rawInput: String) -> URL? {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
            ? trimmed
            : "http://\(trimmed)"
        guard let url = URL(string: withScheme), url.host != nil else { return nil }
        return url
    }

    /// Three states, so a mistyped password isn't reported as an outage.
    public func checkConnection() async -> ConnectionStatus {
        do {
            let _: SubsonicStatus = try await get("ping")
            return .ok
        } catch SubsonicError.wrongCredentials, SubsonicError.notAuthorized {
            return .rejected
        } catch {
            return .unreachable
        }
    }

    // MARK: - Browsing

    public func artists() async throws -> [Artist] {
        let payload: ArtistsPayload = try await get("getArtists")
        return payload.flattened
    }

    public func artist(id: String) async throws -> (artist: Artist, albums: [Album]) {
        let payload: ArtistPayload = try await get("getArtist", query: [URLQueryItem(name: "id", value: id)])
        let artist = Artist(
            id: payload.artist.id, name: payload.artist.name,
            albumCount: payload.artist.album?.count ?? 0,
            artistImageUrl: payload.artist.artistImageUrl
        )
        return (artist, payload.artist.album ?? [])
    }

    public func albumList(_ type: AlbumListType = .alphabeticalByArtist, size: Int = 500, offset: Int = 0) async throws -> [Album] {
        let payload: AlbumListPayload = try await get("getAlbumList2", query: [
            URLQueryItem(name: "type", value: type.rawValue),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
        return payload.albumList2.album ?? []
    }

    /// One call stops at 500 (the protocol's maximum); a library of 905 albums showed only the
    /// first 500.
    public func allAlbums() async throws -> [Album] {
        var albums: [Album] = []
        while true {
            let page = try await albumList(size: 500, offset: albums.count)
            albums += page
            if page.count < 500 { return albums }
        }
    }

    public func album(id: String) async throws -> (album: Album, songs: [Song]) {
        let payload: AlbumPayload = try await get("getAlbum", query: [URLQueryItem(name: "id", value: id)])
        let album = Album(
            id: payload.album.id, name: payload.album.name, artist: payload.album.artist,
            artistId: payload.album.artistId, songCount: payload.album.song?.count ?? 0,
            duration: payload.album.duration, coverArt: payload.album.coverArt, year: payload.album.year
        )
        return (album, payload.album.song ?? [])
    }

    public func song(id: String) async throws -> Song {
        let payload: SongPayload = try await get("getSong", query: [URLQueryItem(name: "id", value: id)])
        return payload.song
    }

    public func search(_ query: String, limit: Int = 40) async throws -> SearchResult {
        let payload: SearchPayload = try await get("search3", query: [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "artistCount", value: String(limit)),
            URLQueryItem(name: "albumCount", value: String(limit)),
            URLQueryItem(name: "songCount", value: String(limit)),
        ])
        let result = payload.searchResult3
        return SearchResult(artists: result.artist ?? [], albums: result.album ?? [], songs: result.song ?? [])
    }

    // MARK: - Playlists

    public func playlists() async throws -> [Playlist] {
        let payload: PlaylistsPayload = try await get("getPlaylists")
        return payload.playlists.playlist ?? []
    }

    public func playlist(id: String) async throws -> (playlist: Playlist, songs: [Song]) {
        let payload: PlaylistPayload = try await get("getPlaylist", query: [URLQueryItem(name: "id", value: id)])
        let p = payload.playlist
        let playlist = Playlist(
            id: p.id, name: p.name, comment: p.comment, owner: p.owner,
            songCount: p.songCount, duration: p.duration, coverArt: p.coverArt
        )
        return (playlist, p.entry ?? [])
    }

    @discardableResult
    public func createPlaylist(name: String, songIds: [String] = []) async throws -> Playlist {
        var query = [URLQueryItem(name: "name", value: name)]
        query.append(contentsOf: songIds.map { URLQueryItem(name: "songId", value: $0) })
        let payload: CreatePlaylistPayload = try await get("createPlaylist", query: query)
        return payload.playlist
    }

    /// The server applies additions first and then removes by index against the resulting
    /// order, so pass either additions or removals, not both, and reload afterwards.
    public func updatePlaylist(
        id: String, name: String? = nil, comment: String? = nil,
        songIdsToAdd: [String] = [], songIndicesToRemove: [Int] = []
    ) async throws {
        var query = [URLQueryItem(name: "playlistId", value: id)]
        if let name { query.append(URLQueryItem(name: "name", value: name)) }
        if let comment { query.append(URLQueryItem(name: "comment", value: comment)) }
        query.append(contentsOf: songIdsToAdd.map { URLQueryItem(name: "songIdToAdd", value: $0) })
        query.append(contentsOf: songIndicesToRemove.map { URLQueryItem(name: "songIndexToRemove", value: String($0)) })
        let _: SubsonicStatus = try await get("updatePlaylist", query: query)
    }

    public func deletePlaylist(id: String) async throws {
        let _: SubsonicStatus = try await get("deletePlaylist", query: [URLQueryItem(name: "id", value: id)])
    }

    // MARK: - URLs for the player and image loading

    /// Synchronous: auth is computed locally, so there is nothing to fetch first.
    public func streamURL(songId: String) -> URL {
        buildURL(path: "stream", query: [URLQueryItem(name: "id", value: songId)])
    }

    public func coverURL(id: String, size: Int? = nil) -> URL {
        var query = [URLQueryItem(name: "id", value: id)]
        if let size { query.append(URLQueryItem(name: "size", value: String(size))) }
        return buildURL(path: "getCoverArt", query: query)
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let url = buildURL(path: path, query: query)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: URLRequest(url: url))
        } catch {
            throw SubsonicError.network
        }
        guard let http = response as? HTTPURLResponse else { throw SubsonicError.network }
        guard (200..<300).contains(http.statusCode) else { throw SubsonicError.http(http.statusCode) }

        let decoder = JSONDecoder()
        guard let envelope = try? decoder.decode(SubsonicEnvelope<SubsonicStatus>.self, from: data) else {
            throw SubsonicError.decoding
        }
        // Subsonic reports failures, including bad credentials, as HTTP 200 with
        // `status: "failed"` in the body.
        if envelope.response.status == "failed" {
            let failure = try? decoder.decode(SubsonicEnvelope<SubsonicFailure>.self, from: data)
            let code = failure?.response.error.code ?? 0
            switch code {
            case 40: throw SubsonicError.wrongCredentials
            case 50: throw SubsonicError.notAuthorized
            default: throw SubsonicError.server(code: code, message: failure?.response.error.message ?? "")
            }
        }
        guard let decoded = try? decoder.decode(SubsonicEnvelope<T>.self, from: data) else {
            throw SubsonicError.decoding
        }
        return decoded.response
    }

    private func buildURL(path: String, query: [URLQueryItem]) -> URL {
        var url = host.appendingPathComponent("rest").appendingPathComponent("\(path).view")
        url.append(queryItems: authQueryItems() + query)
        return url
    }

    private func authQueryItems() -> [URLQueryItem] {
        let salt = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return [
            URLQueryItem(name: "u", value: username),
            URLQueryItem(name: "t", value: token),
            URLQueryItem(name: "s", value: salt),
            URLQueryItem(name: "v", value: Self.apiVersion),
            URLQueryItem(name: "c", value: clientName),
            URLQueryItem(name: "f", value: "json"),
        ]
    }
}

public enum ConnectionStatus: Equatable, Sendable {
    case ok
    case rejected
    case unreachable
}

public enum AlbumListType: String, Sendable, CaseIterable {
    case alphabeticalByArtist, alphabeticalByName, newest, recent, frequent, random, starred, highest
}

private struct SubsonicFailure: Decodable {
    struct Failure: Decodable {
        let code: Int
        let message: String?
    }
    let error: Failure
}
