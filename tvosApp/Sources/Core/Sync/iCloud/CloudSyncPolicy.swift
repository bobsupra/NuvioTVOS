import Foundation

/// Which settings travel over iCloud, which stay on this Apple TV, and which
/// must ride an encrypted field.
///
/// Ownership is one-record-per-concern: any key a dedicated record already
/// carries (`SMBServer`, `JellyfinServer`, `AddonList`, `HomeLayout`) is kept
/// out of the settings payload, so no value ever has two sources of truth.
enum CloudSyncPolicy {
    /// Never leaves this Apple TV.
    static let deviceLocal: Set<String> = [
        // Per-device sync policy. Exporting it would let one TV — or a
        // temporary test — switch off progress pulls everywhere. Same
        // reasoning as `NuvioSyncService.exportSettings`.
        SettingsKey.accountSyncWatchState,
        // The sync switches are per-device by definition. Syncing them would
        // let turning iCloud off on one Apple TV turn it off on every other.
        SettingsKey.iCloudSyncEnabled,
        SettingsKey.iCloudSyncSecrets,
        // Large derived scan output. Each TV rescans the shares it can
        // actually reach, and these blobs would dominate the record size.
        SettingsKey.smbLibraryIndex,
        SettingsKey.jellyfinLibraryIndex,
        // Local derived snapshots that Home rewrites on every load.
        SettingsKey.homeCatalogTitles,
        SettingsKey.homeCatalogDisabledAddonIDs,
        SettingsKey.homeCatalogDisabledAddonNames
    ]

    /// Carried by a dedicated record rather than the settings payload, so that
    /// two Apple TVs adding different servers both survive instead of the whole
    /// list being overwritten wholesale.
    static let ownedByDedicatedRecord: Set<String> = [
        SettingsKey.smbServers,
        SettingsKey.jellyfinServers,
        SettingsKey.streamAddonManifestURL,
        SettingsKey.streamAddonManifestURLs,
        SettingsKey.streamAddonManifestStates
    ]

    /// Carried in the record's end-to-end encrypted field, never in `payload`.
    ///
    /// Wider than `SettingsKey.deviceLocal`, which the Nuvio account sync uses
    /// to keep API credentials off its server entirely. iCloud's private
    /// database is a different trust model: the fields are encrypted with keys
    /// only the user's devices hold, so credentials can travel.
    static let secrets: Set<String> = [
        SettingsKey.traktClientID,
        SettingsKey.traktClientSecret,
        SettingsKey.simklClientID,
        SettingsKey.tmdbApiKey,
        SettingsKey.mdbListApiKey,
        SettingsKey.debridApiKey,
        SettingsKey.torboxAccessToken,
        SettingsKey.premiumizeAccessToken,
        SettingsKey.realDebridAccessToken,
        SettingsKey.aiSubtitlesGeminiAPIKey
    ]

    /// Plain settings carried in the `ProfileSettings` record's `payload`.
    static let plainKeys: [String] = SettingsKey.all.filter {
        !deviceLocal.contains($0)
            && !ownedByDedicatedRecord.contains($0)
            && !secrets.contains($0)
    }

    /// Settings carried in the `ProfileSettings` record's encrypted field.
    static let secretKeys: [String] = SettingsKey.all.filter { secrets.contains($0) }

    /// Keys the `AddonList` record carries.
    static let addonKeys: [String] = [
        SettingsKey.streamAddonManifestURL,
        SettingsKey.streamAddonManifestURLs,
        SettingsKey.streamAddonManifestStates
    ]

    /// Keys the `HomeLayout` record carries. These are deliberately absent from
    /// `SettingsKey.all` — they sync to the Nuvio account through their own RPC
    /// (`sync_push_home_catalog_settings`), so account-less users never had
    /// them travel at all. See ICLOUD_SYNC_PLAN.md §5.
    static let homeLayoutKeys: [String] = [
        SettingsKey.homeCatalogOrder,
        SettingsKey.homeCatalogSyncedOrder,
        SettingsKey.homeCatalogDisabled,
        SettingsKey.homeCollectionDisabled
    ]

    /// Secrets that live in the Keychain rather than a settings suite, and so
    /// have to be read through `KeychainSecretBridge` instead of by key.
    static let keychainSecretKeys: [String] = KeychainSecretBridge.keys

    /// Every key the change journal watches for local edits.
    static let stampedKeys: [String] =
        plainKeys + secretKeys + addonKeys + homeLayoutKeys + keychainSecretKeys
}
