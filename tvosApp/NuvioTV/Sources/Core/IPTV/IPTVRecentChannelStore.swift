import Foundation

/// Stores the last selected channel key per profile, without a stream URL.
struct IPTVRecentChannelStore {
    private static let key = "nuvio.tv.iptv.recentChannel.v1"
    let defaults: UserDefaults

    func load() -> String? { defaults.string(forKey: Self.key) }

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
    func save(_ value: String?) {
        if let value { defaults.set(value, forKey: Self.key) }
        else { defaults.removeObject(forKey: Self.key) }
    }

    func removeIfOwned(by sourceID: UUID) {
        guard let current = load(), current.hasPrefix("\(sourceID.uuidString):") else { return }
        save(nil)
    }
}
