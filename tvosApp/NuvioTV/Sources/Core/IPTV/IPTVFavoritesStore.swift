import Foundation
import CryptoKit

/// Device-local favorites. Values contain only a source UUID and a digest,
/// never a channel URL, portal command, token or MAC address.
struct IPTVFavoritesStore {
    private static let storageKey = "nuvio.tv.iptv.favorites.v1"
    let defaults: UserDefaults

    func load() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    }

    func save(_ favorites: Set<String>) {
        defaults.set(favorites.sorted(), forKey: Self.storageKey)
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
