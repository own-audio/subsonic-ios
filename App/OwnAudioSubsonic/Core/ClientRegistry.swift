import Foundation
import SubsonicKit

/// The connected servers' clients, reachable from the engine's background resolver as well as
/// from the UI.
actor ClientRegistry {
    private var clients: [UUID: SubsonicClient] = [:]

    func set(_ clients: [UUID: SubsonicClient]) {
        self.clients = clients
    }

    func client(for serverId: UUID) -> SubsonicClient? {
        clients[serverId]
    }

    /// The stream URL for one of our composite track ids.
    func streamURL(trackId: String) throws -> URL {
        guard let (serverId, songId) = TrackID.parse(trackId), let client = clients[serverId] else {
            throw URLError(.badURL)
        }
        return client.streamURL(songId: songId)
    }
}
