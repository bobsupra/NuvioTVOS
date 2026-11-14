import Foundation
import CryptoKit

/// Local picker history only: never a playable-link cache or an autoplay choice.
@MainActor
enum LastManualSourceStore {
    private static let storageKey = "nuvio.tv.manualSourceFocus.v1"
    private static let maximumEntries = 400

    struct Match: Equatable {
        let sourceID: String
        let updatedAt: Date
    }

    static func contentType(for meta: NuvioMeta) -> String {
        meta.isSeries ? "series" : "movie"
    }

    static func eraseAll(store: UserDefaults = .standard) {
        store.removeObject(forKey: storageKey)
    }

    private struct Entry: Codable {
        let sourceDigest: String
        let updatedAt: Date
    }

    static func remember(
        sourceID: String, profileID: String, metaID: String, type: String,
        season: Int?, episode: Int?, store: UserDefaults = .standard
    ) {
        guard let key = contentKey(profileID: profileID, metaID: metaID, type: type,
                                   season: season, episode: episode),
              isPlayableIdentity(sourceID) else { return }
        var entries = read(store)
        entries[key] = Entry(sourceDigest: digest(sourceID), updatedAt: Date())
        if entries.count > maximumEntries {
            let retained = entries.sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(maximumEntries)
            entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
        if let data = try? JSONEncoder().encode(entries) {
            store.set(data, forKey: storageKey)
        }
    }

    static func hasRememberedSource(
        profileID: String, metaID: String, type: String, season: Int?, episode: Int?,
        store: UserDefaults = .standard
    ) -> Bool {
        guard let key = contentKey(profileID: profileID, metaID: metaID, type: type,
                                   season: season, episode: episode) else { return false }
        return read(store)[key] != nil
    }

    /// An ambiguous identity deliberately falls back to normal picker behavior.
    static func lastPlayedMatch(
        in sourceIDs: [String], profileID: String, metaID: String, type: String,
        season: Int?, episode: Int?, store: UserDefaults = .standard
    ) -> Match? {
        guard let key = contentKey(profileID: profileID, metaID: metaID, type: type,
                                   season: season, episode: episode),
              let entry = read(store)[key] else { return nil }
        let matches = sourceIDs.filter { isPlayableIdentity($0) && digest($0) == entry.sourceDigest }
        guard matches.count == 1, let sourceID = matches.first else { return nil }
        return Match(sourceID: sourceID, updatedAt: entry.updatedAt)
    }

    static func matchingID(
        in sourceIDs: [String], profileID: String, metaID: String, type: String,
        season: Int?, episode: Int?, store: UserDefaults = .standard
    ) -> String? {
        lastPlayedMatch(
            in: sourceIDs, profileID: profileID, metaID: metaID, type: type,
            season: season, episode: episode, store: store
        )?.sourceID
    }

    private static func contentKey(
        profileID: String, metaID: String, type: String, season: Int?, episode: Int?
    ) -> String? {
        guard !profileID.isEmpty, !metaID.isEmpty else { return nil }
        let parts: [String]
        switch type {
        case "movie":
            guard season == nil, episode == nil else { return nil }
            parts = [profileID, type, metaID]
        case "series":
            guard let season, let episode, season >= 0, episode >= 0 else { return nil }
            parts = [profileID, type, metaID, String(season), String(episode)]
        default:
            return nil
        }
        guard let data = try? JSONEncoder().encode(parts) else { return nil }
        return digest(data)
    }

    private static func isPlayableIdentity(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("stream:")
    }

    private static func read(_ store: UserDefaults) -> [String: Entry] {
        guard let data = store.data(forKey: storageKey), data.count <= 128 * 1024,
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data),
              entries.count <= maximumEntries else { return [:] }
        return entries
    }

    private static func digest(_ value: String) -> String { digest(Data(value.utf8)) }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
