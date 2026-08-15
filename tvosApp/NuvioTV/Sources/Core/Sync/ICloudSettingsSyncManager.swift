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
            let previous = isEnabled
            UserDefaults.standard.set(newValue, forKey: SettingsKey.iCloudSyncEnabled)
            if newValue && !previous {
                syncNow()
            }
        }
    }

    /// Starts observing iCloud and local UserDefaults changes.
    func start() {
        guard !didStart else { return }
        didStart = true

        let center = NotificationCenter.default

        // Inbound changes from iCloud
        observers.append(center.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.isEnabled else { return }
            let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            self.applyRemoteChanges(changedKeys: changedKeys)
        })

        // Outbound local changes
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isEnabled, !self.isApplyingRemote else { return }
            self.schedulePush()
        })

        // Initial check and registration with iCloud
        NSUbiquitousKeyValueStore.default.synchronize()
        if isEnabled {
            applyRemoteChanges(changedKeys: nil)
            schedulePush()
        }
    }

    /// Trigger an immediate sync (both push local and pull remote).
    func syncNow() {
        guard isEnabled else { return }
        NSUbiquitousKeyValueStore.default.synchronize()
        applyRemoteChanges(changedKeys: nil)
        pushLocalSettingsToCloud()
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

    private func pushLocalSettingsToCloud() {
        guard isEnabled, !isApplyingRemote else { return }

        let store = NSUbiquitousKeyValueStore.default
        let knownProfileIds = collectProfileIds()

        for profileId in knownProfileIds {
            let profileDefaults = ProfileSettings.store(for: profileId)
            let payload = extractSettingsPayload(from: profileDefaults)
            if !payload.isEmpty {
                store.set(payload, forKey: "\(Self.profileSettingsPrefix)\(profileId)")
            }
        }

        // Global settings in UserDefaults.standard
        let globalPayload = extractSettingsPayload(from: .standard)
        if !globalPayload.isEmpty {
            store.set(globalPayload, forKey: Self.globalSettingsKey)
        }

        store.set(Date().timeIntervalSince1970, forKey: Self.cloudTimestampKey)
        let success = store.synchronize()
        if success {
            let now = Date()
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: SettingsKey.iCloudLastSyncDate)
        }
    }

    // MARK: - Inbound: Pull from iCloud

    private func applyRemoteChanges(changedKeys: [String]?) {
        guard isEnabled else { return }
        let store = NSUbiquitousKeyValueStore.default

        isApplyingRemote = true
        defer { isApplyingRemote = false }

        var appliedAny = false
        let allCloudKeys = store.dictionaryRepresentation.keys

        // Apply profile-scoped settings
        for key in allCloudKeys where key.hasPrefix(Self.profileSettingsPrefix) {
            if let changedKeys, !changedKeys.contains(key) {
                continue
            }
            let profileId = String(key.dropFirst(Self.profileSettingsPrefix.count))
            guard !profileId.isEmpty, let dict = store.dictionary(forKey: key) else { continue }

            let profileDefaults = ProfileSettings.store(for: profileId)
            applySettingsPayload(dict, to: profileDefaults)
            appliedAny = true
        }

        // Apply global settings
        if changedKeys == nil || (changedKeys?.contains(Self.globalSettingsKey) ?? false) {
            if let globalDict = store.dictionary(forKey: Self.globalSettingsKey) {
                applySettingsPayload(globalDict, to: .standard)
                appliedAny = true
            }
        }

        if appliedAny {
            let now = Date()
            lastSyncDate = now
            UserDefaults.standard.set(now, forKey: SettingsKey.iCloudLastSyncDate)

            // Notify UI to refresh appearance, layout, integrations
            AppLocaleManager.shared.reloadFromProfileStore()
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

    private func applySettingsPayload(_ payload: [String: Any], to defaults: UserDefaults) {
        for (key, value) in payload {
            guard SettingsKey.all.contains(key) else { continue }
            // Don't overwrite if identical
            let currentVal = defaults.object(forKey: key)
            if let strVal = value as? String, (currentVal as? String) != strVal {
                defaults.set(strVal, forKey: key)
            } else if let numVal = value as? NSNumber, (currentVal as? NSNumber) != numVal {
                defaults.set(numVal, forKey: key)
            } else if let dataVal = value as? Data, (currentVal as? Data) != dataVal {
                defaults.set(dataVal, forKey: key)
            } else if let arrayVal = value as? [String], (currentVal as? [String]) != arrayVal {
                defaults.set(arrayVal, forKey: key)
            }
        }
    }
}
