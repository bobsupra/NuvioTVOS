import Foundation

/// Durable on-device cache for remote-backed libraries (Trakt, Simkl, MDBList, WeTrakr).
/// Partitioned per source, profile, and account binding ID so one account's library
/// never shows under another.
enum RemoteLibraryStore {
    private static let storageDirectoryName = "RemoteLibraryStore"
    private static let trackedKeysPrefix = "nuvio.tv.remoteLibrary.trackedKeys"
    private static let lock = NSRecursiveLock()

    static func storageKey(
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) -> String {
        let safeProfile = (profileId?.isEmpty == false) ? profileId! : "default"
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
        let key = storageKey(source: source, profileId: profileId, accountBindingId: accountBindingId)
        guard let data = LargePayloadStore.read(key: key, directory: storageDirectoryName) else { return nil }
        return try? JSONDecoder().decode([LibraryStoreItem].self, from: data)
    }

    @discardableResult
    static func save(
        items: [LibraryStoreItem],
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) -> Bool {
        guard source != .local, let accountBindingId, !accountBindingId.isEmpty else { return false }
        let key = storageKey(source: source, profileId: profileId, accountBindingId: accountBindingId)
        guard let data = try? JSONEncoder().encode(items) else { return false }
        let success = LargePayloadStore.write(data, key: key, directory: storageDirectoryName)
        if success {
            trackKey(key, profileId: profileId)
        }
        return success
    }

    static func applyMutation(
        meta: NuvioMeta,
        isInWatchlist: Bool,
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) {
        guard source != .local, let accountBindingId, !accountBindingId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

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
        save(items: current, source: source, profileId: profileId, accountBindingId: accountBindingId)
    }

    static func clear(
        source: TraktLibrarySourceMode,
        profileId: String?,
        accountBindingId: String?
    ) {
        let key = storageKey(source: source, profileId: profileId, accountBindingId: accountBindingId)
        LargePayloadStore.remove(key: key, directory: storageDirectoryName)
        untrackKey(key, profileId: profileId)
    }

    static func clear(
        source: TraktLibrarySourceMode,
        profileId: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        let keys = trackedKeys(for: profileId)
        let prefix = "remoteLibrary.\(source.rawValue)."
        for key in keys where key.hasPrefix(prefix) {
            LargePayloadStore.remove(key: key, directory: storageDirectoryName)
            untrackKey(key, profileId: profileId)
        }
    }

    static func clearAll(for profileId: String?) {
        lock.lock()
        defer { lock.unlock() }
        let keys = trackedKeys(for: profileId)
        for key in keys {
            LargePayloadStore.remove(key: key, directory: storageDirectoryName)
        }
        let profileKey = trackedKeysStorageKey(for: profileId)
        UserDefaults.standard.removeObject(forKey: profileKey)
    }

    static func clearAll() {
        LargePayloadStore.removeDirectory(storageDirectoryName)
    }

    // MARK: - Key tracking

    private static func trackedKeysStorageKey(for profileId: String?) -> String {
        let safeProfile = (profileId?.isEmpty == false) ? profileId! : "default"
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
