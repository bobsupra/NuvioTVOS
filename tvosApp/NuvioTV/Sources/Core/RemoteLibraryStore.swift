import Foundation

/// Durable on-device cache for remote-backed libraries (Trakt, Simkl, MDBList, WeTrakr).
/// Partitioned per source, profile, and account binding ID so one account's library
/// never shows under another.
enum RemoteLibraryStore {
    enum ConditionalSaveResult: Equatable {
        case saved
        case revisionChanged
        case failed
    }

    private static let storageDirectoryName = "RemoteLibraryStore"
    private static let trackedKeysPrefix = "nuvio.tv.remoteLibrary.trackedKeys"
    private static let lock = NSRecursiveLock()
    private struct RevisionKey: Hashable {
        let source: TraktLibrarySourceMode
        let profileId: String
        let accountBindingId: String
    }
    private static var revisions: [RevisionKey: UInt64] = [:]
    private static var memoryCache: [RevisionKey: [LibraryStoreItem]] = [:]

    static func storageKey(
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) -> String {
        let safeProfile = normalizedProfileId(profileId)
        let safeBinding = (accountBindingId?.isEmpty == false) ? accountBindingId! : "none"
        return "remoteLibrary.\(source.rawValue).\(safeProfile).\(safeBinding)"
    }

    static func accountBindingID(
        for source: TraktLibrarySourceMode,
        profileId: String?,
        in store: UserDefaults = ProfileSettings.current
    ) -> String? {
        switch source {
        case .local:
            return WatchedStore.nuvioSyncAccountBinding(profileId: profileId)
        case .trakt:
            let state = TraktAuthStore.state(in: store)
            return TraktAuthStore.accountBindingID(in: store)
                ?? state.username?.lowercased()
                ?? state.refreshToken
        case .simkl:
            return SimklAuthStore.accountBindingID(in: store)
        case .mdblist:
            return MdbListAuthStore.accountBindingID(in: store)
        case .wetrakr:
            return WeTrakrAuthStore.accountBindingID(in: store)
        }
    }

    static func load(
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) -> [LibraryStoreItem]? {
        guard source != .local, let accountBindingId, !accountBindingId.isEmpty else { return nil }
        guard let revKey = revisionKey(source: source, profileId: profileId, accountBindingId: accountBindingId) else { return nil }
        lock.lock()
        if let cached = memoryCache[revKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let key = storageKey(source: source, profileId: profileId, accountBindingId: accountBindingId)
        guard let data = LargePayloadStore.read(key: key, directory: storageDirectoryName) else { return nil }
        guard let items = try? JSONDecoder().decode([LibraryStoreItem].self, from: data) else { return nil }

        lock.lock()
        memoryCache[revKey] = items
        lock.unlock()
        return items
    }

    static func contains(
        meta: NuvioMeta,
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) -> Bool {
        guard source != .local, let items = load(source: source, profileId: profileId, accountBindingId: accountBindingId) else {
            return false
        }
        return items.contains {
            LibraryMutationIdentity.matches(
                itemID: $0.meta.id,
                itemType: $0.meta.type,
                cachedMetadata: $0.meta,
                mutation: meta
            )
        }
    }

    static func contains(
        metaId: String,
        type: String,
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) -> Bool {
        guard source != .local, let items = load(source: source, profileId: profileId, accountBindingId: accountBindingId) else {
            return false
        }
        return items.contains {
            LibraryMutationIdentity.matches(
                itemID: $0.meta.id,
                itemType: $0.meta.type,
                cachedMetadata: $0.meta,
                targetID: metaId,
                targetType: type
            )
        }
    }

    /// Revision used to prevent an older in-flight fetch from replacing a newer
    /// library save or mutation for the same source, profile, and account.
    static func revision(
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) -> UInt64 {
        guard let key = revisionKey(source: source, profileId: profileId, accountBindingId: accountBindingId) else {
            return 0
        }
        lock.lock()
        defer { lock.unlock() }
        let revision = revisions[key] ?? 0
        revisions[key] = revision
        return revision
    }

    @discardableResult
    static func save(
        items: [LibraryStoreItem],
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) -> Bool {
        persist(
            items: items,
            source: source,
            profileId: profileId,
            accountBindingId: accountBindingId,
            expectedRevision: nil
        ) == .saved
    }

    /// Commits a fetched snapshot only if no save, mutation, or clear has changed
    /// this cache key since the fetch began.
    @discardableResult
    static func saveIfUnchanged(
        items: [LibraryStoreItem],
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?,
        expectedRevision: UInt64
    ) -> ConditionalSaveResult {
        persist(
            items: items,
            source: source,
            profileId: profileId,
            accountBindingId: accountBindingId,
            expectedRevision: expectedRevision
        )
    }

    private static func persist(
        items: [LibraryStoreItem],
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?,
        expectedRevision: UInt64?
    ) -> ConditionalSaveResult {
        guard source != .local, let accountBindingId, !accountBindingId.isEmpty else { return .failed }
        let key = storageKey(source: source, profileId: profileId, accountBindingId: accountBindingId)
        let revisionKey = RevisionKey(
            source: source,
            profileId: normalizedProfileId(profileId),
            accountBindingId: accountBindingId
        )
        guard let data = try? JSONEncoder().encode(items) else { return .failed }

        lock.lock()
        if let expectedRevision, (revisions[revisionKey] ?? 0) != expectedRevision {
            lock.unlock()
            return .revisionChanged
        }
        let success = writeLocked(
            data,
            key: key,
            profileId: profileId,
            revisionKey: revisionKey,
            incrementsRevision: true
        )
        if success {
            memoryCache[revisionKey] = items
        }
        lock.unlock()

        if success {
            TopShelfLibraryFeed.write()
        }
        return success ? .saved : .failed
    }

    static func applyMutation(
        meta: NuvioMeta,
        isInWatchlist: Bool,
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) {
        guard source != .local, let accountBindingId, !accountBindingId.isEmpty else { return }
        let key = storageKey(source: source, profileId: profileId, accountBindingId: accountBindingId)
        let revisionKey = RevisionKey(
            source: source,
            profileId: normalizedProfileId(profileId),
            accountBindingId: accountBindingId
        )
        lock.lock()
        advanceRevision(for: revisionKey)

        var current = load(source: source, profileId: profileId, accountBindingId: accountBindingId) ?? []
        if isInWatchlist {
            let newItem = LibraryStoreItem(meta: meta, addedAt: Date())
            let filtered = current.filter {
                !LibraryMutationIdentity.matches(
                    itemID: $0.meta.id,
                    itemType: $0.meta.type,
                    cachedMetadata: $0.meta,
                    mutation: meta
                )
            }
            current = [newItem] + filtered
        } else {
            current.removeAll {
                LibraryMutationIdentity.matches(
                    itemID: $0.meta.id,
                    itemType: $0.meta.type,
                    cachedMetadata: $0.meta,
                    mutation: meta
                )
            }
        }
        let data = try? JSONEncoder().encode(current)
        let success = data.map {
            writeLocked(
                $0,
                key: key,
                profileId: profileId,
                revisionKey: revisionKey,
                incrementsRevision: false
            )
        } ?? false
        if success {
            memoryCache[revisionKey] = current
        }
        lock.unlock()

        if success {
            TopShelfLibraryFeed.write()
        }
    }

    static func clear(
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) {
        let key = storageKey(source: source, profileId: profileId, accountBindingId: accountBindingId)
        lock.lock()
        LargePayloadStore.remove(key: key, directory: storageDirectoryName)
        if let keyRevision = revisionKey(
            source: source,
            profileId: profileId,
            accountBindingId: accountBindingId
        ) {
            advanceRevision(for: keyRevision)
            memoryCache.removeValue(forKey: keyRevision)
        }
        untrackKey(key, profileId: profileId)
        lock.unlock()
        TopShelfLibraryFeed.write()
    }

    static func clear(
        source: TraktLibrarySourceMode,
        profileId: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        let storagePrefix = "remoteLibrary.\(source.rawValue)."
        let trackedSourceKeys = trackedKeys(for: profileId).filter { $0.hasPrefix(storagePrefix) }
        for key in trackedSourceKeys {
            LargePayloadStore.remove(key: key, directory: storageDirectoryName)
            untrackKey(key, profileId: profileId)
        }
        let profileKey = normalizedProfileId(profileId)
        for key in Array(revisions.keys.filter({ $0.source == source && $0.profileId == profileKey })) {
            advanceRevision(for: key)
            memoryCache.removeValue(forKey: key)
        }
    }

    static func clearAll(for profileId: String?) {
        lock.lock()
        defer { lock.unlock() }
        for key in trackedKeys(for: profileId) {
            LargePayloadStore.remove(key: key, directory: storageDirectoryName)
        }
        let profileKey = normalizedProfileId(profileId)
        for key in Array(revisions.keys.filter({ $0.profileId == profileKey })) {
            advanceRevision(for: key)
            memoryCache.removeValue(forKey: key)
        }
        let trackedProfileKey = trackedKeysStorageKey(for: profileId)
        UserDefaults.standard.removeObject(forKey: trackedProfileKey)
    }

    static func clearAll() {
        lock.lock()
        for key in Array(revisions.keys) {
            advanceRevision(for: key)
        }
        memoryCache.removeAll()
        LargePayloadStore.removeDirectory(storageDirectoryName)
        lock.unlock()
    }

    private static func normalizedProfileId(_ profileId: String?) -> String {
        (profileId?.isEmpty == false) ? profileId! : "default"
    }

    private static func revisionKey(
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) -> RevisionKey? {
        guard source != .local, let accountBindingId, !accountBindingId.isEmpty else { return nil }
        return RevisionKey(
            source: source,
            profileId: normalizedProfileId(profileId),
            accountBindingId: accountBindingId
        )
    }

    private static func advanceRevision(for key: RevisionKey) {
        revisions[key] = (revisions[key] ?? 0) &+ 1
    }

    /// Caller holds `lock` so the payload write and its revision update are atomic
    /// with respect to `saveIfUnchanged`.
    private static func writeLocked(
        _ data: Data,
        key: String,
        profileId: String?,
        revisionKey: RevisionKey,
        incrementsRevision: Bool
    ) -> Bool {
        guard LargePayloadStore.write(data, key: key, directory: storageDirectoryName) else { return false }
        if incrementsRevision {
            advanceRevision(for: revisionKey)
        }
        trackKey(key, profileId: profileId)
        return true
    }

    // MARK: - Key tracking

    private static func trackedKeysStorageKey(for profileId: String?) -> String {
        let safeProfile = normalizedProfileId(profileId)
        return "\(trackedKeysPrefix).\(safeProfile)"
    }

    private static func trackedKeys(for profileId: String?) -> Set<String> {
        let key = trackedKeysStorageKey(for: profileId)
        let array = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(array)
    }

    private static func trackKey(_ key: String, profileId: String?) {
        lock.lock()
        defer { lock.unlock() }
        var current = trackedKeys(for: profileId)
        if current.insert(key).inserted {
            let storageKey = trackedKeysStorageKey(for: profileId)
            UserDefaults.standard.set(Array(current), forKey: storageKey)
        }
    }

    private static func untrackKey(_ key: String, profileId: String?) {
        let storageKey = trackedKeysStorageKey(for: profileId)
        var current = trackedKeys(for: profileId)
        if current.remove(key) != nil {
            UserDefaults.standard.set(Array(current), forKey: storageKey)
        }
    }
}
