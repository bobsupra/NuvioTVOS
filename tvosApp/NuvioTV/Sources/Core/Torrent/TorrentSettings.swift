import Foundation

enum TorrentSettings {
    static let defaultCacheLimitGB: Double = 4.0
    static let defaultMaxPeers: Int = 80

    static func isEnabled(store: UserDefaults = ProfileSettings.current) -> Bool {
        let enabled = store.object(forKey: SettingsKey.p2pEnabled) as? Bool ?? false
        return enabled && hasConsent(store: store)
    }

    static func setEnabled(_ enabled: Bool, store: UserDefaults = ProfileSettings.current) {
        store.set(enabled, forKey: SettingsKey.p2pEnabled)
    }

    static func hasConsent(store: UserDefaults = ProfileSettings.current) -> Bool {
        store.bool(forKey: SettingsKey.p2pConsentAccepted)
    }

    static func setConsentAccepted(_ accepted: Bool, store: UserDefaults = ProfileSettings.current) {
        store.set(accepted, forKey: SettingsKey.p2pConsentAccepted)
    }

    static func hideStats(store: UserDefaults = ProfileSettings.current) -> Bool {
        store.bool(forKey: SettingsKey.p2pHideTorrentStats)
    }

    static func setHideStats(_ hide: Bool, store: UserDefaults = ProfileSettings.current) {
        store.set(hide, forKey: SettingsKey.p2pHideTorrentStats)
    }

    static func cacheLimitGB(store: UserDefaults = ProfileSettings.current) -> Double {
        let value = store.double(forKey: SettingsKey.p2pCacheLimitGB)
        return value > 0 ? value : defaultCacheLimitGB
    }

    static func setCacheLimitGB(_ limit: Double, store: UserDefaults = ProfileSettings.current) {
        store.set(limit, forKey: SettingsKey.p2pCacheLimitGB)
    }

    static var torrentCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("NuvioTorrents", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func currentCacheSizeBytes() -> Int64 {
        let dir = torrentCacheDirectory
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    static func clearTorrentCache() {
        let dir = torrentCacheDirectory
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }

    static func clearCache() {
        clearTorrentCache()
    }

    static func cacheSizeFormatted() -> String {
        let bytes = currentCacheSizeBytes()
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
