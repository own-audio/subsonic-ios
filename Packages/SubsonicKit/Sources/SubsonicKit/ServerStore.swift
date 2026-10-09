import Foundation
import Security
import os

public struct ServerCredentials: Codable, Sendable, Equatable {
    public let host: URL
    public let username: String
    /// Kept because token+salt auth needs it for every request; hence Keychain-only storage.
    public let password: String

    public init(host: URL, username: String, password: String) {
        self.host = host
        self.username = username
        self.password = password
    }
}

/// One configured server. `displayName` defaults to the host and can be renamed later,
/// independently of the credentials.
public struct ServerRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var displayName: String
    public var credentials: ServerCredentials

    public init(id: UUID = UUID(), displayName: String, credentials: ServerCredentials) {
        self.id = id
        self.displayName = displayName
        self.credentials = credentials
    }
}

/// Every configured server, stored as a single Keychain item so adding or removing one is a
/// single write.
public actor ServerStore {
    private let service: String
    private let account = "servers"
    private let logger = Logger(subsystem: "audio.own.subsonic", category: "ServerStore")

    public init(service: String = "audio.own.subsonic.servers") {
        self.service = service
    }

    public func loadAll() -> [ServerRecord] {
        guard let data = loadRawData() else { return [] }
        do {
            return try JSONDecoder().decode([ServerRecord].self, from: data)
        } catch {
            logger.error("Saved servers could not be decoded.")
            return []
        }
    }

    public func add(_ record: ServerRecord) throws {
        try persist(loadAll() + [record])
    }

    public func remove(id: UUID) throws {
        try persist(loadAll().filter { $0.id != id })
    }

    public func rename(id: UUID, to displayName: String) throws {
        var records = loadAll()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].displayName = displayName
        try persist(records)
    }

    public func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private func loadRawData() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                logger.error("Server load failed: OSStatus \(status, privacy: .public)")
            }
            return nil
        }
        return data
    }

    private func persist(_ records: [ServerRecord]) throws {
        let data = try JSONEncoder().encode(records)
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery()
            addQuery[kSecValueData as String] = data
            // Playback continues with the screen locked, and requests need the password then.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw ServerStoreError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw ServerStoreError.keychain(updateStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum ServerStoreError: Error, Sendable {
    case keychain(OSStatus)
}
