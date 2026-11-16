import Foundation

/// The last Continue Watching row a remote progress source (Trakt, Simkl, ...)
/// returned, kept on disk per profile and source.
///
/// With a remote source Home has no row until the provider answers, so the row
/// appears late and after focus has settled elsewhere. Home shows this copy at
/// once and replaces it when the fresh list arrives.
enum RemoteContinueWatchingRowCache {
    private static let directory = "RemoteContinueWatchingRow"
    /// Older than this, the row is more likely wrong than useful.
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60

    private struct Payload: Codable {
        let savedAt: Date
        let items: [ContinueWatchingItem]
    }

    static func key(profileId: String?, source: String) -> String {
        "\(profileId ?? "default")-\(source)"
    }

    static func load(profileId: String?, source: String, now: Date = Date()) -> [ContinueWatchingItem] {
        guard let data = LargePayloadStore.read(key: key(profileId: profileId, source: source), directory: directory),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              now.timeIntervalSince(payload.savedAt) <= maxAge else { return [] }
        return payload.items
    }

    /// Saves off the main thread; an empty row removes the copy.
    @discardableResult
    static func save(
        _ items: [ContinueWatchingItem], profileId: String?, source: String, now: Date = Date()
    ) -> Task<Void, Never> {
        let key = key(profileId: profileId, source: source)
        return Task.detached(priority: .utility) {
            guard !items.isEmpty,
                  let data = try? JSONEncoder().encode(Payload(savedAt: now, items: items)) else {
                LargePayloadStore.remove(key: key, directory: directory)
                return
            }
            LargePayloadStore.write(data, key: key, directory: directory)
        }
    }

    /// Forgets every saved row: an account behind them changed.
    static func removeAll() {
        LargePayloadStore.removeDirectory(directory)
    }
}
