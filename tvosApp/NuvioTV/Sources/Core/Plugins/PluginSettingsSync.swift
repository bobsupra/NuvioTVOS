import Foundation

/// The profile's plugin settings (each provider's `onSettings()` form: API keys,
/// logins, passwords, choices) in the Nuvio account, when the profile opts in
/// (Settings → Plugins → Save to Nuvio Account). The repository list already
/// syncs with the account's `plugins` table; the settings stayed in this Apple
/// TV's Keychain only, so a reinstall or another Apple TV got the providers back
/// without them. Stored as they are, without encryption, as Usenet's passwords
/// and debrid keys are.
///
/// Kept in its own feature of the profile's "tv" settings blob, by the
/// provider's id (its repository and its id in the manifest), with its
/// repository. The choice is part of the copy, so turning it off on one Apple TV
/// clears the settings from the account for all of them. A device where it was
/// never chosen leaves the account's copy as it is: a fresh install doesn't wipe
/// it before its first pull brings it back.
///
/// A pull saves the settings into the Keychain at once, before the providers
/// themselves are downloaded again (their repositories come back from the
/// account and download afterwards); a push keeps the account's settings of
/// providers still on their way, as long as their repository is in the list.
enum PluginSettingsSync {
    static let featureKey = "tvos_plugin_settings"
    /// Whether this profile keeps its plugin settings in the Nuvio account.
    /// Absent until chosen on this device.
    static let syncToAccountKey = "nuvio.tv.settings.plugins.settingsSyncToAccount"
    /// Bumped when a provider's settings change, which the Keychain alone
    /// doesn't show, so the account sync notices (`PluginSettingsVault`).
    static let revisionKey = "nuvio.tv.settings.plugins.settingsRevision"
    /// The keys whose changes the account sync watches.
    static let syncObservedKeys = [syncToAccountKey, revisionKey]
    /// Posted on the main thread after a pull brought the choice or settings in.
    static let syncedFromAccountNotification = Notification.Name("nuvio.tv.plugins.settingsSyncedFromAccount")

    private enum Key {
        static let enabled = "enabled"
        static let scrapers = "scrapers"
    }

    private enum ScraperKey {
        static let repository = "repository"
        static let settings = "settings"
    }

    /// Nil: never chosen on this device, so the account's copy is left alone.
    static func syncChoice(store: UserDefaults = ProfileSettings.current) -> Bool? {
        store.object(forKey: syncToAccountKey) as? Bool
    }

    static func setSyncChoice(_ value: Bool, store: UserDefaults = ProfileSettings.current) {
        store.set(value, forKey: syncToAccountKey)
    }

    /// The feature to write. Never chosen: the account's copy unchanged (nil
    /// when there is none). Off: only the choice. On: the settings of every
    /// provider that has some, and the account's settings of providers not
    /// downloaded here yet whose repository is still in the list.
    static func export(
        store: UserDefaults,
        existing: [String: Any]?,
        state: PluginStore.State,
        settings: (_ scraperID: String) -> [String: Any]
    ) -> [String: Any]? {
        switch syncChoice(store: store) {
        case nil:
            return existing
        case false?:
            return [Key.enabled: false]
        case true?:
            let local = Set(state.scrapers.map(\.id))
            let repositories = Set(state.repositories.map(\.manifestURL))
            var scrapers: [String: Any] = [:]
            for (id, raw) in existing?[Key.scrapers] as? [String: Any] ?? [:] {
                guard !local.contains(id),
                      let entry = raw as? [String: Any],
                      let repository = entry[ScraperKey.repository] as? String,
                      repositories.contains(repository),
                      let values = entry[ScraperKey.settings] as? [String: Any],
                      !values.isEmpty else { continue }
                scrapers[id] = [ScraperKey.repository: repository, ScraperKey.settings: values] as [String: Any]
            }
            for scraper in state.scrapers {
                let values = settings(scraper.id)
                guard !values.isEmpty, JSONSerialization.isValidJSONObject(values) else { continue }
                scrapers[scraper.id] = [ScraperKey.repository: scraper.repositoryURL, ScraperKey.settings: values] as [String: Any]
            }
            return [Key.enabled: true, Key.scrapers: scrapers]
        }
    }

    /// Applies the account's copy. On: each provider's settings replace the
    /// ones here (saved only where they differ), and the choice turns on here
    /// too; settings of providers the account doesn't list stay. Off: the
    /// choice turns off and the settings here stay.
    static func importPayload(
        _ remote: [String: Any]?,
        store: UserDefaults,
        current: (_ scraperID: String) -> [String: Any],
        save: (_ settings: [String: Any], _ scraperID: String) -> Void
    ) {
        guard let remote, let enabled = remote[Key.enabled] as? Bool else { return }
        if enabled {
            for (id, raw) in remote[Key.scrapers] as? [String: Any] ?? [:] {
                guard !id.isEmpty,
                      let entry = raw as? [String: Any],
                      let values = entry[ScraperKey.settings] as? [String: Any],
                      !values.isEmpty,
                      !NSDictionary(dictionary: current(id)).isEqual(to: values) else { continue }
                save(values, id)
            }
        }
        setSyncChoice(enabled, store: store)
        // Settings listens on the main thread; the pull runs off it.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: PluginSettingsSync.syncedFromAccountNotification, object: nil)
        }
    }
}
