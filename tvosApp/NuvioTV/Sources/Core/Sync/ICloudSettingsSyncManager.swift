//
//  ICloudSettingsSyncManager.swift
//  NuvioTV
//
//  Synchronizes local application settings, player configurations, UI themes,
//  and third-party API credentials across Apple TVs using NSUbiquitousKeyValueStore.
//

import Combine
import Foundation

@MainActor
final class ICloudSettingsSyncManager: ObservableObject {
    static let shared = ICloudSettingsSyncManager()

    /// Posted when iCloud settings are pulled and applied to local UserDefaults.
    static let iCloudSettingsDidSyncNotification = Notification.Name("nuvio.tv.icloud.settingsDidSync")

    private static let profileSettingsPrefix = "nuvio.icloud.profile.settings."
    private static let globalSettingsKey = "nuvio.icloud.global.settings"
    private static let cloudTimestampKey = "nuvio.icloud.lastModified"

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?

    private var observers: [NSObjectProtocol] = []
    private var pushDebounceTask: Task<Void, Never>?
    private var isApplyingRemote = false
    private var didStart = false

    private init() {
        if let storedTime = UserDefaults.standard.object(forKey: SettingsKey.iCloudLastSyncDate) as? Date {
            self.lastSyncDate = storedTime
        }
    }

    deinit {
        pushDebounceTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Whether iCloud Settings Sync is enabled by the user.
    var isEnabled: Bool {
        get {
            UserDefaults.standard.bool(forKey: SettingsKey.iCloudSyncEnabled)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: SettingsKey.iCloudSyncEnabled)
            // The Settings switch writes this key through @AppStorage before it sets this
            // property, so the stored value can't tell whether sync was just turned on.
            // `start()` runs once; turning sync on again only syncs.
            if newValue {
                start()
                syncNow()
            }
        }
    }

    /// Whether `start()` has registered the iCloud and UserDefaults observers.
    var isStarted: Bool {
        didStart
    }

    /// Starts observing iCloud and local UserDefaults changes.
    func start() {
        guard isEnabled, !didStart else { return }
        didStart = true

        let center = NotificationCenter.default

        // Inbound changes from iCloud
        observers.append(center.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] notification in
            let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                self.applyRemoteChanges(changedKeys: changedKeys)
            }
        })

        // Outbound local changes
        // UserDefaults writes can hold a store lock; this Task hops to MainActor without blocking the posting thread.
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled, !self.isApplyingRemote else { return }
                self.schedulePush()
            }
        })

        // Initial check and registration with iCloud
        NSUbiquitousKeyValueStore.default.synchronize()
        if isEnabled {
            applyRemoteChanges(changedKeys: nil)
            schedulePush()
        }
    }

    /// Removes the observers so a test can check `start()` from a stopped manager.
    func stopForTesting() {
        pushDebounceTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        didStart = false
    }

    /// Trigger an immediate sync (both push local and pull remote).
    func syncNow() {
        guard isEnabled else { return }
        NSUbiquitousKeyValueStore.default.synchronize()
        applyRemoteChanges(changedKeys: nil)
        pushLocalSettingsToCloud()
        markSynced()
    }

    // MARK: - Outbound: Push to iCloud

    private func schedulePush() {
        pushDebounceTask?.cancel()
        pushDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 seconds debounce
            guard !Task.isCancelled else { return }
            self.pushLocalSettingsToCloud()
        }
    }

    /// Writes the payloads that differ from iCloud and returns whether it wrote any.
    ///
    /// Recording the sync date is itself a UserDefaults change, and applying iCloud
    /// values posts one too. Pushing only what differs lets those notifications end in
    /// a push that writes nothing, instead of a new write every 1.5 seconds.
    @discardableResult
    private func pushLocalSettingsToCloud() -> Bool {
        guard isEnabled, !isApplyingRemote else { return false }

        let store = NSUbiquitousKeyValueStore.default
        var localPayloads: [String: [String: Any]] = [:]

        for profileId in collectProfileIds() {
            let profileDefaults = ProfileSettings.store(for: profileId)
            localPayloads["\(Self.profileSettingsPrefix)\(profileId)"] = extractSettingsPayload(from: profileDefaults)
        }

        // Global settings in UserDefaults.standard
        localPayloads[Self.globalSettingsKey] = extractSettingsPayload(from: .standard)

        let changed = Self.payloadsToPush(local: localPayloads, cloud: store.dictionaryRepresentation)
        guard !changed.isEmpty else { return false }

        for (key, payload) in changed {
            store.set(payload, forKey: key)
        }
        store.set(Date().timeIntervalSince1970, forKey: Self.cloudTimestampKey)
        if store.synchronize() {
            markSynced()
        }
        return true
    }

    /// The non-empty local payloads whose value in iCloud is missing or different.
    nonisolated static func payloadsToPush(
        local: [String: [String: Any]],
        cloud: [String: Any]
    ) -> [String: [String: Any]] {
        local.filter { key, payload in
            guard !payload.isEmpty else { return false }
            guard let stored = cloud[key] as? NSDictionary else { return true }
            return !stored.isEqual(to: payload)
        }
    }

    private func markSynced() {
        let now = Date()
        lastSyncDate = now
        UserDefaults.standard.set(now, forKey: SettingsKey.iCloudLastSyncDate)
    }

    // MARK: - Inbound: Pull from iCloud

    private func applyRemoteChanges(changedKeys: [String]?) {
        guard isEnabled else { return }
        let store = NSUbiquitousKeyValueStore.default

        isApplyingRemote = true
        defer { isApplyingRemote = false }

        var appliedAny = false
        var changedAny = false
        let allCloudKeys = store.dictionaryRepresentation.keys

        // Apply profile-scoped settings
        for key in allCloudKeys where key.hasPrefix(Self.profileSettingsPrefix) {
            if let changedKeys, !changedKeys.contains(key) {
                continue
            }
            let profileId = String(key.dropFirst(Self.profileSettingsPrefix.count))
            guard !profileId.isEmpty, let dict = store.dictionary(forKey: key) else { continue }

            let profileDefaults = ProfileSettings.store(for: profileId)
            if applySettingsPayload(dict, to: profileDefaults) { changedAny = true }
            appliedAny = true
        }

        // Apply global settings
        if changedKeys == nil || (changedKeys?.contains(Self.globalSettingsKey) ?? false) {
            if let globalDict = store.dictionary(forKey: Self.globalSettingsKey) {
                if applySettingsPayload(globalDict, to: .standard) { changedAny = true }
                appliedAny = true
            }
        }

        if appliedAny {
            markSynced()
        }

        if changedAny {
            // Notify UI to refresh appearance, layout, integrations
            AppLocaleManager.shared.reloadFromProfileStore()
            AppFontManager.shared.reloadFromProfileStore()
            NotificationCenter.default.post(name: Self.iCloudSettingsDidSyncNotification, object: nil)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        }
    }

    // MARK: - Helpers

    private func collectProfileIds() -> Set<String> {
        var ids: Set<String> = ["guest", "default", "1", "2", "3", "4", "5", "6"]
        if let active = ProfileSettings.activeProfileID {
            ids.insert(active)
        }
        return ids
    }

    private func extractSettingsPayload(from defaults: UserDefaults) -> [String: Any] {
        var payload: [String: Any] = [:]
        for key in SettingsKey.all {
            guard !SettingsKey.deviceLocal.contains(key) else { continue }
            if let value = defaults.object(forKey: key) {
                // Only encode plist-compatible types supported by NSUbiquitousKeyValueStore
                if let str = value as? String {
                    payload[key] = str
                } else if let num = value as? NSNumber {
                    payload[key] = num
                } else if let data = value as? Data {
                    payload[key] = data
                } else if let array = value as? [String] {
                    payload[key] = array
                }
            }
        }
        return payload
    }

    /// Writes the iCloud values that differ from `defaults` and returns whether it wrote any.
    @discardableResult
    private func applySettingsPayload(_ payload: [String: Any], to defaults: UserDefaults) -> Bool {
        var changed = false
        for (key, value) in payload {
            guard SettingsKey.all.contains(key), !SettingsKey.deviceLocal.contains(key) else { continue }
            // Don't overwrite if identical
            let currentVal = defaults.object(forKey: key)
            if let strVal = value as? String, (currentVal as? String) != strVal {
                defaults.set(strVal, forKey: key)
                changed = true
            } else if let numVal = value as? NSNumber, (currentVal as? NSNumber) != numVal {
                defaults.set(numVal, forKey: key)
                changed = true
            } else if let dataVal = value as? Data, (currentVal as? Data) != dataVal {
                defaults.set(dataVal, forKey: key)
                changed = true
            } else if let arrayVal = value as? [String], (currentVal as? [String]) != arrayVal {
                defaults.set(arrayVal, forKey: key)
                changed = true
            }
        }

        if payload[SettingsKey.trailerSound] as? Bool != nil {
            ProfileSettings.markTrailerSoundExplicit(in: defaults)
        } else if payload[SettingsKey.trailerSound] == nil,
                  let legacySound = payload[SettingsKey.trailerPreviewSound] as? Bool {
            ProfileSettings.importLegacyTrailerSoundIfNeeded(legacySound, in: defaults)
        }
        return changed
    }
}
