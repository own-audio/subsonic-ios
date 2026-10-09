import Foundation
import Testing

@testable import SubsonicKit

@Suite("Offline cache")
struct OfflineCacheTests {
    private let host = URL(string: "http://music.example.com")!

    private actor Network {
        var isUp = true
        func set(_ up: Bool) { isUp = up }
    }

    private static let albumBody = SubsonicClientTests.envelope(#"""
    "album":{"id":"al-1","name":"Opera","songCount":1,"song":[{"id":"s-1","title":"One"}]}
    """#)

    private func setUp() async -> (SubsonicClient, Network, OfflineSwitch, MockURLProtocol.StubbedSession) {
        let network = Network()
        let mock = await MockURLProtocol.makeStubbedSession { _ in
            guard await network.isUp else { throw URLError(.notConnectedToInternet) }
            return .init(statusCode: 200, body: Self.albumBody)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let offline = OfflineSwitch()
        let client = SubsonicClient(
            host: host, username: "u", password: "p", session: mock.urlSession,
            cache: DiskResponseCache(directory: directory), offline: offline
        )
        return (client, network, offline, mock)
    }

    @Test("a failed request falls back to the answer saved earlier")
    func networkFailureUsesSavedAnswer() async throws {
        let (client, network, _, _) = await setUp()
        _ = try await client.album(id: "al-1")
        await network.set(false)
        let loaded = try await client.album(id: "al-1")
        #expect(loaded.songs.map(\.title) == ["One"])
    }

    @Test("offline answers from the cache without a request")
    func offlineSkipsNetwork() async throws {
        let (client, _, offline, mock) = await setUp()
        _ = try await client.album(id: "al-1")
        offline.isOn = true
        _ = try await client.album(id: "al-1")
        #expect(await mock.requestLog().count == 1)
    }

    @Test("offline with nothing saved is .offline, and writes are refused")
    func offlineWithoutSavedAnswer() async throws {
        let (client, _, offline, mock) = await setUp()
        offline.isOn = true
        await #expect(throws: SubsonicClient.SubsonicError.offline) { try await client.album(id: "al-2") }
        await #expect(throws: SubsonicClient.SubsonicError.offline) { try await client.star(songIds: ["s-1"]) }
        #expect(await mock.requestLog().isEmpty)
    }

    @Test("the key ignores the per-request salt and token")
    func keyIsStable() {
        let client = SubsonicClient(host: host, username: "u", password: "p")
        let a = client.cacheKey(path: "getAlbum", query: [URLQueryItem(name: "id", value: "1")])
        let b = client.cacheKey(path: "getAlbum", query: [URLQueryItem(name: "id", value: "1")])
        let other = client.cacheKey(path: "getAlbum", query: [URLQueryItem(name: "id", value: "2")])
        #expect(a == b)
        #expect(a != other)
    }
}
