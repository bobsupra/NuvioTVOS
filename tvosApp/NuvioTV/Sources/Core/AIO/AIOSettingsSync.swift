import Foundation

/// AIOStreams (AIOStreamsHost) in the Nuvio account,
/// when this Apple TV opts in (AIOStreams sheet → Save to Nuvio Account), like
/// Usenet's servers (`UsenetSettingsSync`). In the account: Nuvio's settings
/// for AIOStreams (Start with Nuvio, Use the AIOStreams Addon, Anime searches,
/// Source, Detailed AIOStreams log) and the backup of the configuration with
/// its password, as the Keychain keeps it here. Stored as it is, without
/// encryption, as Usenet's passwords and debrid keys are.
///
/// Another Apple TV or a reinstall that opts in gets them back: the settings
/// at once, the configuration when its AIOStreams has started (created there
/// from the backup, and its addon added). Changes saved on the configuration
/// page reach the account, and the other Apple TVs take them over: the backup
/// saved last wins (`savedAt`, written by nuvio-main.mjs). Each Apple TV still
/// runs its own AIOStreams with its own addon address, which is never synced,
/// nor are its installed version, its anime databases, db.sqlite or the cache.
///
/// Kept in its own feature of the profile's "tv" settings blob. The choice is
/// part of the copy: turning it off clears the copy from the account for every
/// Apple TV (theirs stay as they are). An Apple TV where it was never chosen
/// leaves the account's copy alone.
enum AIOSettingsSync {
    static let featureKey = "tvos_aio_settings"
    /// Nil: never chosen on this Apple TV. AIOStreams is the Apple TV's, not a
    /// profile's: its keys are in the standard user defaults.
    static let syncToAccountKey = "aio.experiment.syncToAccount"
    /// Counts the configuration page's backups, so the account sync notices one.
    static let backupRevisionKey = "aio.experiment.backupRevision"
    /// A backup from the account waits to be loaded into AIOStreams.
    static let pendingBackupKey = "aio.experiment.syncedBackupPending"

    private enum Key {
        static let enabled = "enabled"
        static let settings = "settings"
        static let backup = "backup"
    }

    private enum SettingKey {
        static let startWithNuvio = "startWithNuvio"
        static let useAddon = "useAddon"
        static let animeRequest = "animeRequest"
        static let source = "source"
        static let detailedLog = "detailedLog"
    }

    private enum BackupKey {
        static let config = "config"
        static let password = "password"
        static let savedAt = "savedAt"
        /// This Apple TV's configuration (in the Keychain only, never in the account).
        static let uuid = "uuid"
    }

    /// What an account pull brought.
    struct Imported: Equatable {
        /// The settings changed here.
        var settings: Bool
        /// A newer backup: to be loaded into AIOStreams.
        var backup: Bool
    }

    static func syncChoice(store: UserDefaults = .standard) -> Bool? {
        store.object(forKey: syncToAccountKey) as? Bool
    }

    static func setSyncChoice(_ value: Bool, store: UserDefaults = .standard) {
        store.set(value, forKey: syncToAccountKey)
    }

    /// The configuration page saved a new backup.
    static func noteNewBackup(store: UserDefaults = .standard) {
        store.set(store.integer(forKey: backupRevisionKey) &+ 1, forKey: backupRevisionKey)
    }

    /// For the account sync's snapshot of the settings it watches.
    static func observedValues(store: UserDefaults = .standard) -> [String: Any] {
        var values: [String: Any] = [:]
        for key in [syncToAccountKey, backupRevisionKey, AIOStreamsHost.autoStartKey, AIOStreamsHost.addonKey,
                    AIOStreamsHost.animeRequestKey, AIOStreamsHost.sourceKey, AIOStreamsHost.detailedLogKey] {
            if let value = store.object(forKey: key) { values[key] = value }
        }
        return values
    }

    /// The feature to write. Never chosen: the account's copy unchanged (nil
    /// when there is none). Off: only the choice. On: the settings and the
    /// newer of the two backups (this Apple TV's or the account's).
    static func export(
        store: UserDefaults = .standard,
        existing: [String: Any]?,
        backup: [String: Any]?
    ) -> [String: Any]? {
        switch syncChoice(store: store) {
        case nil:
            return existing
        case false?:
            return [Key.enabled: false]
        case true?:
            var feature: [String: Any] = [
                Key.enabled: true,
                Key.settings: [
                    SettingKey.startWithNuvio: store.bool(forKey: AIOStreamsHost.autoStartKey),
                    SettingKey.useAddon: store.object(forKey: AIOStreamsHost.addonKey) as? Bool ?? true,
                    SettingKey.animeRequest: store.string(forKey: AIOStreamsHost.animeRequestKey)
                        .flatMap(AIOStreamsHost.AnimeRequest.init(rawValue:))?.rawValue ?? AIOStreamsHost.AnimeRequest.both.rawValue,
                    SettingKey.source: store.string(forKey: AIOStreamsHost.sourceKey) ?? AIOStreamsHost.defaultSource,
                    SettingKey.detailedLog: store.bool(forKey: AIOStreamsHost.detailedLogKey),
                ] as [String: Any],
            ]
            let local = accountBackup(from: backup)
            let remote = accountBackup(from: existing?[Key.backup] as? [String: Any])
            if let newer = newer(local, remote) {
                feature[Key.backup] = newer
            }
            return feature
        }
    }

    /// Applies the account's copy. On: its settings replace the local ones,
    /// and a newer backup replaces this Apple TV's (kept for AIOStreams:
    /// `pendingBackupKey`); the choice turns on here too. Off: the choice
    /// turns off, and the settings and the configuration here stay.
    /// `localBackup`: the Keychain's; `saveBackup`: into the Keychain.
    @discardableResult
    static func importPayload(
        _ remote: [String: Any]?,
        store: UserDefaults = .standard,
        localBackup: [String: Any]?,
        saveBackup: ([String: Any]) -> Void
    ) -> Imported? {
        guard let remote, let enabled = remote[Key.enabled] as? Bool else { return nil }
        guard enabled else {
            guard syncChoice(store: store) != false else { return nil }
            setSyncChoice(false, store: store)
            return Imported(settings: false, backup: false)
        }
        var result = Imported(settings: syncChoice(store: store) != true, backup: false)
        setSyncChoice(true, store: store)
        if let settings = remote[Key.settings] as? [String: Any] {
            for (name, key) in [(SettingKey.startWithNuvio, AIOStreamsHost.autoStartKey),
                                (SettingKey.useAddon, AIOStreamsHost.addonKey),
                                (SettingKey.detailedLog, AIOStreamsHost.detailedLogKey)] {
                guard let value = settings[name] as? Bool, store.object(forKey: key) as? Bool != value else { continue }
                store.set(value, forKey: key)
                result.settings = true
            }
            let animeRequest = (settings[SettingKey.animeRequest] as? String).flatMap(AIOStreamsHost.AnimeRequest.init(rawValue:))?.rawValue
            let source = (settings[SettingKey.source] as? String).flatMap { $0.isEmpty ? nil : $0 }
            for (value, key) in [(animeRequest, AIOStreamsHost.animeRequestKey), (source, AIOStreamsHost.sourceKey)] {
                guard let value, store.string(forKey: key) != value else { continue }
                store.set(value, forKey: key)
                result.settings = true
            }
        }
        if let backup = accountBackup(from: remote[Key.backup] as? [String: Any]), isNewer(backup, than: localBackup) {
            var stored = backup
            // The same password: AIOStreams' configuration here can take the
            // changes as it is (the addon keeps its address).
            if let localBackup, let uuid = localBackup[BackupKey.uuid] as? String,
               localBackup[BackupKey.password] as? String == backup[BackupKey.password] as? String {
                stored[BackupKey.uuid] = uuid
            }
            saveBackup(stored)
            store.set(true, forKey: pendingBackupKey)
            result.backup = true
        }
        return result
    }

    /// A backup as the account keeps it: the configuration, its password and
    /// when it was saved; nil without a configuration or password.
    private static func accountBackup(from backup: [String: Any]?) -> [String: Any]? {
        guard let backup, let config = backup[BackupKey.config], !(config is NSNull),
              let password = backup[BackupKey.password] as? String, !password.isEmpty else { return nil }
        return [
            BackupKey.config: config,
            BackupKey.password: password,
            BackupKey.savedAt: backup[BackupKey.savedAt] as? String ?? "",
        ]
    }

    /// `backup` was saved after `other` (an ISO 8601 time, as toISOString writes it).
    private static func isNewer(_ backup: [String: Any], than other: [String: Any]?) -> Bool {
        guard let other = accountBackup(from: other) else { return true }
        let mine = backup[BackupKey.savedAt] as? String ?? ""
        let theirs = other[BackupKey.savedAt] as? String ?? ""
        return mine > theirs
    }

    private static func newer(_ first: [String: Any]?, _ second: [String: Any]?) -> [String: Any]? {
        switch (first, second) {
        case let (first?, second?): return isNewer(second, than: first) ? second : first
        case let (first?, nil): return first
        case let (nil, second?): return second
        case (nil, nil): return nil
        }
    }
}
