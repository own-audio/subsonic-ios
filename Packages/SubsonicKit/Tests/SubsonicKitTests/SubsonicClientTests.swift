import CryptoKit
import Foundation
import Testing

@testable import SubsonicKit

@Suite("SubsonicClient")
struct SubsonicClientTests {
    private let host = URL(string: "http://music.example.com")!

    private func client(_ mock: MockURLProtocol.StubbedSession, password: String = "p") -> SubsonicClient {
        SubsonicClient(host: host, username: "u", password: password, session: mock.urlSession)
    }

    // MARK: - normalizeHost

    @Test("a bare host defaults to http")
    func normalizeHostDefaultsToHttp() {
        #expect(SubsonicClient.normalizeHost("music.example.com")?.absoluteString == "http://music.example.com")
    }

    @Test("an explicit https:// is kept")
    func normalizeHostKeepsExplicitHttps() {
        #expect(SubsonicClient.normalizeHost("https://music.example.com")?.absoluteString == "https://music.example.com")
    }

    @Test("a port is kept")
    func normalizeHostKeepsPort() {
        #expect(SubsonicClient.normalizeHost("192.168.1.10:4533")?.absoluteString == "http://192.168.1.10:4533")
    }

    @Test("empty or whitespace-only input is rejected")
    func normalizeHostRejectsEmpty() {
        #expect(SubsonicClient.normalizeHost("   ") == nil)
        #expect(SubsonicClient.normalizeHost("") == nil)
    }

    // MARK: - Auth

    @Test("every request carries u/t/s/v/c/f and t is md5(password+salt)")
    func requestCarriesTokenSaltAuth() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.envelope()) }
        let api = SubsonicClient(host: host, username: "alice", password: "secret", session: mock.urlSession)
        _ = await api.checkConnection()

        let byName = Dictionary(uniqueKeysWithValues: await mock.firstQuery().map { ($0.name, $0.value ?? "") })
        #expect(byName["u"] == "alice")
        #expect(byName["v"] == "1.16.1")
        #expect(byName["c"] == "own.audio-subsonic")
        #expect(byName["f"] == "json")
        #expect(byName["p"] == nil)
        let salt = try #require(byName["s"])
        #expect(byName["t"] == Self.md5Hex("secret" + salt))
    }

    @Test("two requests use two different salts")
    func eachRequestGetsAFreshSalt() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.envelope()) }
        let api = client(mock)
        _ = await api.checkConnection()
        _ = await api.checkConnection()

        let salts = await mock.requestLog().compactMap {
            $0.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
                .first(where: { $0.name == "s" })?.value
        }
        #expect(salts.count == 2)
        #expect(salts[0] != salts[1])
    }

    // MARK: - Browsing

    @Test("artists flattens the index groups")
    func artistsFlattensIndex() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#"""
            "artists":{"ignoredArticles":"","index":[
                {"name":"A","artist":[{"id":"ar-2","name":"ABBA","albumCount":3}]},
                {"name":"Q","artist":[{"id":"ar-1","name":"Queen","albumCount":19}]}
            ]}
            """#))
        }
        let artists = try await client(mock).artists()
        #expect(artists.map(\.name) == ["ABBA", "Queen"])
        #expect(artists.last?.albumCount == 19)
    }

    @Test("an empty library (no index key) decodes as no artists")
    func artistsHandlesMissingIndex() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#""artists":{"ignoredArticles":""}"#))
        }
        #expect(try await client(mock).artists().isEmpty)
    }

    @Test("album decodes its songs and its own cover and year")
    func albumDecodesSongs() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#"""
            "album":{"id":"al-1","name":"A Night At The Opera","artist":"Queen","artistId":"ar-1","coverArt":"al-1","year":1975,"song":[
                {"id":"so-1","title":"Death On Two Legs","track":1,"discNumber":1,"duration":221,"genre":"Rock","suffix":"flac"},
                {"id":"so-2","title":"Bohemian Rhapsody","track":11,"duration":354}
            ]}
            """#))
        }
        let (album, songs) = try await client(mock).album(id: "al-1")
        #expect(album.name == "A Night At The Opera")
        #expect(album.coverArt == "al-1")
        #expect(album.year == 1975)
        #expect(album.songCount == 2)
        #expect(songs.map(\.id) == ["so-1", "so-2"])
        #expect(songs.first?.suffix == "flac")
        #expect(songs.last?.genre == nil)
    }

    @Test("albumList sends the list type")
    func albumListSendsType() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#""albumList2":{}"#))
        }
        let albums = try await client(mock).albumList(.newest, size: 20)
        #expect(albums.isEmpty)
        let query = await mock.firstQuery()
        #expect(query.first { $0.name == "type" }?.value == "newest")
        #expect(query.first { $0.name == "size" }?.value == "20")
    }

    @Test("allAlbums keeps paging until a short page")
    func allAlbumsPages() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { request in
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "offset" }?.value ?? "0"
            let count = offset == "0" ? 500 : 3
            let albums = (0..<count).map { #"{"id":"al-\#(offset)-\#($0)","name":"x","songCount":1}"# }
            return .init(statusCode: 200, body: Self.envelope(#""albumList2":{"album":[\#(albums.joined(separator: ","))]}"#))
        }
        let albums = try await client(mock).allAlbums()
        #expect(albums.count == 503)
        #expect(await mock.requestLog().count == 2)
    }

    @Test("search splits artists, albums and songs")
    func searchSplitsResults() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#"""
            "searchResult3":{"artist":[{"id":"ar-1","name":"Queen","albumCount":1}],"song":[{"id":"so-1","title":"Bohemian Rhapsody"}]}
            """#))
        }
        let result = try await client(mock).search("queen")
        #expect(result.artists.count == 1)
        #expect(result.albums.isEmpty)
        #expect(result.songs.first?.title == "Bohemian Rhapsody")
        #expect(await mock.firstQuery().first { $0.name == "query" }?.value == "queen")
    }

    // MARK: - Playlists

    @Test("playlists decodes the flat array")
    func playlistsDecode() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#"""
            "playlists":{"playlist":[
                {"id":"pl-1","name":"Road Trip","songCount":12,"duration":0,"owner":"alice"},
                {"id":"pl-2","name":"Focus","comment":"Deep work","songCount":40,"duration":9600,"coverArt":"pl-2"}
            ]}
            """#))
        }
        let playlists = try await client(mock).playlists()
        #expect(playlists.map(\.id) == ["pl-1", "pl-2"])
        #expect(playlists.first?.owner == "alice")
        #expect(playlists.last?.comment == "Deep work")
    }

    @Test("playlists is empty when the server sends no playlist key")
    func playlistsHandlesMissingKey() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#""playlists":{}"#))
        }
        #expect(try await client(mock).playlists().isEmpty)
    }

    @Test("playlist decodes its entries as songs")
    func playlistDecodesEntries() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#"""
            "playlist":{"id":"pl-1","name":"Road Trip","owner":"alice","songCount":2,"duration":0,"entry":[
                {"id":"so-1","title":"Death On Two Legs"},{"id":"so-2","title":"Bohemian Rhapsody"}
            ]}
            """#))
        }
        let (playlist, songs) = try await client(mock).playlist(id: "pl-1")
        #expect(playlist.name == "Road Trip")
        #expect(songs.map(\.id) == ["so-1", "so-2"])
    }

    @Test("createPlaylist sends the name and every songId")
    func createPlaylistSendsParams() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#""playlist":{"id":"pl-9","name":"New Mix","songCount":2}"#))
        }
        let created = try await client(mock).createPlaylist(name: "New Mix", songIds: ["so-1", "so-2"])
        #expect(created.id == "pl-9")
        let query = await mock.firstQuery()
        #expect(query.first { $0.name == "name" }?.value == "New Mix")
        #expect(query.filter { $0.name == "songId" }.map(\.value) == ["so-1", "so-2"])
    }

    @Test("updatePlaylist sends only what is being changed")
    func updatePlaylistSendsOnlyChanges() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.envelope()) }
        try await client(mock).updatePlaylist(id: "pl-1", songIdsToAdd: ["so-3"])
        let query = await mock.firstQuery()
        #expect(query.first { $0.name == "playlistId" }?.value == "pl-1")
        #expect(query.filter { $0.name == "songIdToAdd" }.map(\.value) == ["so-3"])
        #expect(!query.contains { $0.name == "songIndexToRemove" })
        #expect(!query.contains { $0.name == "name" })
        #expect(!query.contains { $0.name == "comment" })
    }

    @Test("updatePlaylist sends songIndexToRemove")
    func updatePlaylistSendsRemovals() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.envelope()) }
        try await client(mock).updatePlaylist(id: "pl-1", songIndicesToRemove: [2])
        #expect(await mock.firstQuery().filter { $0.name == "songIndexToRemove" }.map(\.value) == ["2"])
    }

    @Test("deletePlaylist sends the id")
    func deletePlaylistSendsId() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.envelope()) }
        try await client(mock).deletePlaylist(id: "pl-1")
        #expect(await mock.firstQuery().first { $0.name == "id" }?.value == "pl-1")
    }

    // MARK: - Favorites, ratings, scrobbling

    @Test("star sends songs as id, albums as albumId, artists as artistId")
    func starParameters() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.envelope()) }
        try await client(mock).star(songIds: ["so-1"], albumIds: ["al-1"], artistIds: ["ar-1"])
        let query = await mock.firstQuery()
        #expect(await mock.requestLog().first?.url?.path == "/rest/star.view")
        #expect(query.first { $0.name == "id" }?.value == "so-1")
        #expect(query.first { $0.name == "albumId" }?.value == "al-1")
        #expect(query.first { $0.name == "artistId" }?.value == "ar-1")
    }

    @Test("unstar uses its own endpoint")
    func unstarEndpoint() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.envelope()) }
        try await client(mock).unstar(songIds: ["so-1"])
        #expect(await mock.requestLog().first?.url?.path == "/rest/unstar.view")
    }

    @Test("a rating is clamped to 0...5")
    func ratingClamped() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.envelope()) }
        try await client(mock).setRating(id: "so-1", rating: 9)
        #expect(await mock.firstQuery().first { $0.name == "rating" }?.value == "5")
    }

    @Test("scrobble sends submission and the start time in milliseconds")
    func scrobbleParameters() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.envelope()) }
        try await client(mock).scrobble(songId: "so-1", submission: true, time: Date(timeIntervalSince1970: 1_700_000_000))
        let query = await mock.firstQuery()
        #expect(query.first { $0.name == "submission" }?.value == "true")
        #expect(query.first { $0.name == "time" }?.value == "1700000000000")
    }

    @Test("starred decodes songs, albums and artists")
    func starredDecodes() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#"""
            "starred2":{"song":[{"id":"so-1","title":"A","starred":"2026-01-01T00:00:00Z","userRating":4}],"album":[{"id":"al-1","name":"B","songCount":3,"starred":"2026-01-01T00:00:00Z"}]}
            """#))
        }
        let starred = try await client(mock).starred()
        #expect(starred.songs.first?.starred != nil)
        #expect(starred.songs.first?.userRating == 4)
        #expect(starred.albums.count == 1)
        #expect(starred.artists.isEmpty)
    }

    @Test("extensions are read by name; a classic server's error means none")
    func extensions() async throws {
        let open = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#""openSubsonicExtensions":[{"name":"songLyrics","versions":[1,2]},{"name":"transcodeOffset","versions":[1]}]"#))
        }
        let classic = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#""error":{"code":0,"message":"unknown"}"#, status: "failed"))
        }
        #expect(await client(open).openSubsonicExtensions() == ["songLyrics", "transcodeOffset"])
        #expect(await client(classic).openSubsonicExtensions().isEmpty)
    }

    // MARK: - Errors (HTTP 200 with status "failed")

    @Test("a failed write surfaces the server's code and message")
    func failedWriteSurfacesServerError() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#""error":{"code":70,"message":"Playlist not found"}"#, status: "failed"))
        }
        await #expect(throws: SubsonicClient.SubsonicError.server(code: 70, message: "Playlist not found")) {
            try await client(mock).updatePlaylist(id: "gone", songIdsToAdd: ["so-1"])
        }
    }

    @Test("code 40 is wrongCredentials, not a decoding failure")
    func wrongCredentials() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#""error":{"code":40,"message":"Wrong username or password"}"#, status: "failed"))
        }
        await #expect(throws: SubsonicClient.SubsonicError.wrongCredentials) {
            _ = try await client(mock, password: "wrong").artists()
        }
    }

    @Test("an HTTP error status is reported as such")
    func httpError() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 502, body: Data()) }
        await #expect(throws: SubsonicClient.SubsonicError.http(502)) {
            _ = try await client(mock).artists()
        }
    }

    @Test("a non-Subsonic body (e.g. a proxy's HTML page) is a decoding error")
    func htmlBodyIsDecodingError() async throws {
        let mock = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Data("<html></html>".utf8)) }
        await #expect(throws: SubsonicClient.SubsonicError.decoding) {
            _ = try await client(mock).artists()
        }
    }

    @Test("checkConnection: rejected, ok, unreachable")
    func checkConnectionStates() async throws {
        let rejected = await MockURLProtocol.makeStubbedSession { _ in
            .init(statusCode: 200, body: Self.envelope(#""error":{"code":40,"message":"x"}"#, status: "failed"))
        }
        let ok = await MockURLProtocol.makeStubbedSession { _ in .init(statusCode: 200, body: Self.envelope()) }
        let down = await MockURLProtocol.makeStubbedSession { _ in throw URLError(.notConnectedToInternet) }
        #expect(await client(rejected).checkConnection() == .rejected)
        #expect(await client(ok).checkConnection() == .ok)
        #expect(await client(down).checkConnection() == .unreachable)
        #expect(await ok.requestLog().first?.url?.path == "/rest/ping.view")
    }

    // MARK: - URLs

    @Test("streamURL builds /rest/stream.view with the id and auth")
    func streamURL() {
        let api = SubsonicClient(host: host, username: "alice", password: "secret")
        let url = api.streamURL(songId: "so-1")
        #expect(url.path == "/rest/stream.view")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.contains { $0.name == "id" && $0.value == "so-1" })
        #expect(items.contains { $0.name == "u" && $0.value == "alice" })
    }

    @Test("a server under a sub-path keeps it")
    func subPathHost() {
        let api = SubsonicClient(host: URL(string: "https://example.com/navidrome")!, username: "u", password: "p")
        #expect(api.streamURL(songId: "1").path == "/navidrome/rest/stream.view")
    }

    @Test("coverURL adds size only when asked")
    func coverURL() {
        let api = SubsonicClient(host: host, username: "u", password: "p")
        let plain = URLComponents(url: api.coverURL(id: "al-1"), resolvingAgainstBaseURL: false)?.queryItems ?? []
        let sized = URLComponents(url: api.coverURL(id: "al-1", size: 300), resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(!plain.contains { $0.name == "size" })
        #expect(sized.contains { $0.name == "size" && $0.value == "300" })
    }

    // MARK: - Helpers

    static func envelope(_ payload: String = "", status: String = "ok") -> Data {
        let extra = payload.isEmpty ? "" : ",\(payload)"
        return Data(#"{"subsonic-response":{"status":"\#(status)","version":"1.16.1"\#(extra)}}"#.utf8)
    }

    private static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@Suite("Models")
struct ModelTests {
    @Test("an image URL without a size parameter is left alone")
    func imageUrlWithoutSize() {
        #expect(Artist.displaySizedImageURL("https://x.example.com/a.jpg") == "https://x.example.com/a.jpg")
    }

    @Test("a sized image URL is rewritten to the display size")
    func imageUrlWithSize() {
        #expect(Artist.displaySizedImageURL("https://m.example.com/share/img/abc?size=600") == "https://m.example.com/share/img/abc?size=320")
    }
}
