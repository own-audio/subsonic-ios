import Foundation
import Testing

@testable import SubsonicKit

/// Runs against a real server. Stubbed tests only prove we parse JSON we wrote ourselves; the
/// real risk with a third-party protocol is whether actual servers send what the models expect.
///
/// Skipped unless configured:
///
/// ```
/// SUBSONIC_HOST=https://music.example.com SUBSONIC_USER=someone SUBSONIC_PASSWORD=… \
///   swift test --filter LiveServer
/// ```
@Suite("Live server", .enabled(if: LiveServerConfig.current != nil))
struct LiveServerTests {
    private func makeClient(passwordSuffix: String = "") throws -> SubsonicClient {
        let config = try #require(LiveServerConfig.current)
        let host = try #require(SubsonicClient.normalizeHost(config.host))
        return SubsonicClient(host: host, username: config.username, password: config.password + passwordSuffix)
    }

    @Test("the token+salt auth is accepted")
    func authIsAccepted() async throws {
        #expect(await try makeClient().checkConnection() == .ok)
    }

    @Test("a wrong password is rejected, not reported as unreachable")
    func wrongPasswordIsRejected() async throws {
        #expect(await try makeClient(passwordSuffix: "-wrong").checkConnection() == .rejected)
    }

    @Test("artists decode")
    func artistsDecode() async throws {
        let artists = try await makeClient().artists()
        let first = try #require(artists.first)
        #expect(!first.id.isEmpty && !first.name.isEmpty)
    }

    @Test("albums decode despite the many fields the models ignore")
    func albumsDecode() async throws {
        let albums = try await makeClient().albumList(size: 10)
        #expect(try #require(albums.first).songCount > 0)
    }

    @Test("an album's songs decode")
    func albumSongsDecode() async throws {
        let api = try makeClient()
        let target = try #require(try await api.albumList(size: 10).first { $0.songCount > 0 })
        let (album, songs) = try await api.album(id: target.id)
        #expect(album.id == target.id)
        #expect(songs.count == target.songCount)
    }

    /// Reads only the first megabyte: enough to tell audio from an error page.
    @Test("a stream URL returns audio, not an error page")
    func streamReturnsAudio() async throws {
        let api = try makeClient()
        let target = try #require(try await api.albumList(size: 10).first { $0.songCount > 0 })
        let song = try #require(try await api.album(id: target.id).songs.first)

        var request = URLRequest(url: api.streamURL(songId: song.id))
        request.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200 || http.statusCode == 206)

        // Which container arrives depends on the server's transcoding settings; any real one
        // passes, a JSON error body served as audio/* doesn't.
        let magic = Array(data.prefix(12))
        let looksLikeAudio =
            magic.starts(with: Array("fLaC".utf8))
            || magic.starts(with: Array("OggS".utf8))
            || magic.starts(with: Array("ID3".utf8))
            || (magic.count >= 2 && magic[0] == 0xFF && (magic[1] & 0xE0) == 0xE0)
            || (magic.count >= 8 && Array(magic[4..<8]) == Array("ftyp".utf8))
        #expect(looksLikeAudio, "not a known audio container: \(magic.prefix(4))")
    }

    /// The only test that writes. It cleans up after itself even on failure, and the name makes
    /// a leftover from a crashed run easy to spot and delete.
    @Test("playlist create, add, remove, delete")
    func playlistRoundTrip() async throws {
        let api = try makeClient()
        let target = try #require(try await api.albumList(size: 10).first { $0.songCount > 0 })
        let song = try #require(try await api.album(id: target.id).songs.first)

        let created = try await api.createPlaylist(name: "subsonic-ios test \(UUID().uuidString.prefix(8))")
        do {
            try await api.updatePlaylist(id: created.id, songIdsToAdd: [song.id])
            #expect(try await api.playlist(id: created.id).songs.map(\.id) == [song.id])
            try await api.updatePlaylist(id: created.id, songIndicesToRemove: [0])
            #expect(try await api.playlist(id: created.id).songs.isEmpty)
            try await api.deletePlaylist(id: created.id)
        } catch {
            try? await api.deletePlaylist(id: created.id)
            throw error
        }
        #expect(!(try await api.playlists()).contains { $0.id == created.id })
    }
}

enum LiveServerConfig {
    struct Config {
        let host: String
        let username: String
        let password: String
    }

    static var current: Config? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["SUBSONIC_HOST"], let username = env["SUBSONIC_USER"], let password = env["SUBSONIC_PASSWORD"],
              !host.isEmpty, !username.isEmpty, !password.isEmpty
        else { return nil }
        return Config(host: host, username: username, password: password)
    }
}
