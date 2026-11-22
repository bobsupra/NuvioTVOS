import Foundation

/// Stores recently watched channel keys per profile, without stream URLs.
struct IPTVRecentChannelStore {
    private static let key = "nuvio.tv.iptv.recentChannel.v1"
    private static let limit = 32
    let defaults: UserDefaults

    /// The newest key, preserving the original single-channel API.
    func load() -> String? { loadAll().first }

    /// Newest first. A string value is the previous persisted format.
    func loadAll() -> [String] {
        if let values = defaults.stringArray(forKey: Self.key) { return Self.deduplicated(values) }
        if let value = defaults.string(forKey: Self.key) { return [value] }
        return []
    }

    /// Forgets the recent history, for a deleted profile.
    static func remove(from defaults: UserDefaults) { defaults.removeObject(forKey: key) }

    /// The source UUID is public local identity; the rest of the key is an
    /// opaque channel digest. Reject old or malformed values safely.
    func sourceID() -> UUID? {
        guard let value = load() else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])),
              parts[1].utf8.count == 64,
              parts[1].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return id
    }

    /// Saves a key as the newest entry, migrating the old string representation.
    func save(_ value: String?) {
        guard let value else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(Self.deduplicated([value] + loadAll()), forKey: Self.key)
    }

    func removeIfOwned(by sourceID: UUID) {
        let prefix = "\(sourceID.uuidString):"
        let remaining = loadAll().filter { !$0.hasPrefix(prefix) }
        if remaining.isEmpty { defaults.removeObject(forKey: Self.key) }
        else { defaults.set(remaining, forKey: Self.key) }
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }.prefix(limit).map { $0 }
    }
}
