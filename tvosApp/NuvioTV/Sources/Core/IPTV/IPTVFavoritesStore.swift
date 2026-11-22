import Foundation
import CryptoKit

/// Device-local favorites. Values contain only a source UUID and a digest,
/// never a channel URL, portal command, token or MAC address.
struct IPTVFavoritesStore {
    private static let storageKey = "nuvio.tv.iptv.favorites.v1"
    private static let orderStorageKey = "nuvio.tv.iptv.favorites.order.v1"
    let defaults: UserDefaults

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func save(_ favorites: Set<String>) {
        defaults.set(favorites.sorted(), forKey: Self.storageKey)
        saveOrder(loadOrder().filter { favorites.contains($0) })
    }

    func loadOrder() -> [String] {
        var seen = Set<String>()
        return (defaults.stringArray(forKey: Self.orderStorageKey) ?? []).filter { seen.insert($0).inserted }
    }

    func saveOrder(_ order: [String]) {
        var seen = Set<String>()
        defaults.set(order.filter { seen.insert($0).inserted }, forKey: Self.orderStorageKey)
    }

    /// Keeps stored order, inserts legacy favorites in playlist order, and drops stale keys.
    func reconciledOrder(_ order: [String], playlistOrder: [String], favorites: Set<String>) -> [String] {
        var seen = Set<String>()
        return (order + playlistOrder).filter {
            favorites.contains($0) && seen.insert($0).inserted
        }
    }

    static func key(sourceID: UUID, channelID: String) -> String {
        let hash = SHA256.hash(data: Data(channelID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(sourceID.uuidString):\(hash)"
    }

    static func removingSource(_ sourceID: UUID, from favorites: Set<String>) -> Set<String> {
        let prefix = "\(sourceID.uuidString):"
        return Set(favorites.filter { !$0.hasPrefix(prefix) })
    }
}
