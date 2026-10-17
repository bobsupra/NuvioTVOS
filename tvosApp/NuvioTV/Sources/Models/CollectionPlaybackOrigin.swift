import Foundation

/// Navigation provenance only; never changes metadata or watch-progress keys.
struct CollectionOriginReference: Codable, Equatable, Hashable {
    let collectionID: String
    let folderID: String
}

struct CollectionOriginPresentation: Equatable {
    let reference: CollectionOriginReference
    let title: String
    let imageURLs: [String]
    let emoji: String?

    static func service(folder: TVCollectionFolderItem) -> Self? {
        let style = folder.presentationStyle?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard style != "STUDIO_FRANCHISE", !folder.sources.isEmpty else { return nil }
        // Explicit service templates also support addon-based/custom sources.
        // Otherwise require actual provider filters on every configured source.
        let providerSources = folder.sources.allSatisfy {
            $0.normalizedProvider == "tmdb"
                && $0.tmdbSourceType?.uppercased() == "DISCOVER"
                && !($0.filters?.withWatchProviders?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && ($0.filters?.withCompanies?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                && ($0.filters?.withNetworks?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
        guard style == "STREAMING_SERVICE" || providerSources else { return nil }
        var seen = Set<String>()
        let urls = [folder.titleLogoUrl, folder.coverImageUrl].compactMap { raw -> String? in
            guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: value),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, seen.insert(value).inserted else { return nil }
            return value
        }
        return Self(
            reference: CollectionOriginReference(collectionID: folder.collectionId, folderID: folder.folderId),
            title: folder.title, imageURLs: urls,
            emoji: folder.coverEmoji.flatMap { $0.isEmpty ? nil : String($0.prefix(8)) }
        )
    }

    static func configured(profileID: String) -> [CollectionOriginReference: Self] {
        guard CollectionsStore.activeProfileId == profileID else { return [:] }
        var result: [CollectionOriginReference: Self] = [:]
        for collection in CollectionsStore.collections() {
            for folder in collection.folders {
                let item = TVCollectionFolderItem(
                    collectionId: collection.id, folder: folder, sources: folder.resolvedSources
                )
                if let value = service(folder: item) { result[value.reference] = value }
            }
        }
        return result
    }
}

/// Captured for a specific navigation and profile, rather than consulting the
/// currently selected tab when an asynchronous stream finally starts.
struct CollectionPlaybackContext: Codable, Equatable {
    let profileID: String
    let titleKeys: Set<String>
    let type: String
    let origin: CollectionOriginReference?
    let preservesStoredOrigin: Bool

    init(profileID: String, contentID: String, type: String,
         origin: CollectionOriginReference? = nil, preservesStoredOrigin: Bool = false) {
        self.profileID = profileID
        titleKeys = WatchedStore.contentIdentityKeys(metaId: contentID, imdbId: nil, tmdbId: nil)
        self.type = WatchedStore.normalizedType(type)
        self.origin = origin
        self.preservesStoredOrigin = preservesStoredOrigin
    }

    func matches(_ meta: NuvioMeta) -> Bool {
        type == WatchedStore.normalizedType(meta.type)
            && !titleKeys.isDisjoint(with: WatchedStore.contentIdentityKeys(for: meta))
    }
}

/// Local, bounded, per-profile title annotations. Remote progress without a
/// local annotation gets no guessed badge. No stream URLs or artwork are saved.
enum CollectionPlaybackOriginStore {
    static let changedNotification = Notification.Name("CollectionPlaybackOriginChanged")
    private static let prefix = "nuvio.tv.collectionPlaybackOrigin.v1."
    private static let lock = NSLock()
    private static let limit = 256

    struct Entry: Codable, Equatable {
        let type: String
        let aliases: Set<String>
        let origin: CollectionOriginReference
    }

    private static func key(_ profileID: String) -> String { prefix + profileID }

    static func entries(profileID: String, defaults: UserDefaults = .standard) -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return read(profileID: profileID, defaults: defaults)
    }

    private static func read(profileID: String, defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: key(profileID)),
              let rows = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return Array(rows.suffix(limit))
    }

    /// Called after the first rendered frame, or a valid external-player
    /// progress callback. Opening Details or a failed stream never writes.
    static func recordStarted(
        meta: NuvioMeta, context: CollectionPlaybackContext,
        activeProfileID: String?, defaults: UserDefaults = .standard
    ) {
        guard !context.profileID.isEmpty, context.profileID == activeProfileID else { return }
        let matches = context.matches(meta)
        if matches && context.preservesStoredOrigin { return }
        let aliases = WatchedStore.contentIdentityKeys(for: meta)
        guard !aliases.isEmpty else { return }
        let type = WatchedStore.normalizedType(meta.type)
        lock.lock()
        let old = read(profileID: context.profileID, defaults: defaults)
        let previous = old.filter { $0.type == type && !$0.aliases.isDisjoint(with: aliases) }
        var mergedAliases = aliases
        previous.forEach { mergedAliases.formUnion($0.aliases) }
        var rows = old.filter { $0.type != type || $0.aliases.isDisjoint(with: mergedAliases) }
        if matches, let origin = context.origin {
            rows.append(Entry(type: type, aliases: mergedAliases, origin: origin))
        }
        rows = Array(rows.suffix(limit))
        guard rows != old, let data = try? JSONEncoder().encode(rows) else {
            lock.unlock()
            return
        }
        defaults.set(data, forKey: key(context.profileID))
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func presentations(
        for metas: [NuvioMeta], profileID: String,
        services: [CollectionOriginReference: CollectionOriginPresentation],
        defaults: UserDefaults = .standard
    ) -> [String: CollectionOriginPresentation] {
        let rows = entries(profileID: profileID, defaults: defaults)
        var index: [String: CollectionOriginReference] = [:]
        for row in rows {
            for alias in row.aliases { index["\(row.type)\u{1f}\(alias)"] = row.origin }
        }
        var result: [String: CollectionOriginPresentation] = [:]
        for meta in metas {
            let type = WatchedStore.normalizedType(meta.type)
            let references = Set(WatchedStore.contentIdentityKeys(for: meta).compactMap {
                index["\(type)\u{1f}\($0)"]
            })
            // Conflicting aliases are ambiguous; never guess a service.
            if references.count == 1, let reference = references.first, let service = services[reference] {
                result[meta.id] = service
            }
        }
        return result
    }

    static func eraseProfile(_ profileID: String, defaults: UserDefaults = .standard) {
        lock.lock()
        defaults.removeObject(forKey: key(profileID))
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func eraseAllProfiles(defaults: UserDefaults = .standard) {
        lock.lock()
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(prefix) }
            .forEach { defaults.removeObject(forKey: $0) }
        lock.unlock()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
