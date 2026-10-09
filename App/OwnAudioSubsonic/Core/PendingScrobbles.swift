import Foundation

/// Plays that couldn't be reported (no network, server down), kept until they can be. The
/// server records each with the time listening began, so a late report is still accurate.
struct PendingScrobbles {
    struct Entry: Codable, Equatable {
        let trackId: String
        let startedAt: Date
    }

    private let defaults: UserDefaults
    private let key: String
    /// A phone offline for weeks shouldn't grow this without bound.
    static let limit = 500

    init(defaults: UserDefaults = .standard, key: String = "pendingScrobbles") {
        self.defaults = defaults
        self.key = key
    }

    var all: [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    func add(_ entry: Entry) {
        save(Array((all + [entry]).suffix(Self.limit)))
    }

    func remove(_ entries: [Entry]) {
        save(all.filter { !entries.contains($0) })
    }

    private func save(_ entries: [Entry]) {
        defaults.set(try? JSONEncoder().encode(entries), forKey: key)
    }
}
