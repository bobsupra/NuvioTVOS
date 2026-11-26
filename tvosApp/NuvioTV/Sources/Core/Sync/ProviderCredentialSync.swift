import Foundation
import Security

enum ProviderCredentialKeychainRead {
    case value(String)
    case missing
    case failed
}

protocol ProviderCredentialKeychain: AnyObject {
    func read(service: String, account: String) -> ProviderCredentialKeychainRead
    func write(_ value: String, service: String, account: String) -> Bool
    func delete(service: String, account: String) -> Bool
}

final class SystemProviderCredentialKeychain: ProviderCredentialKeychain {
    static let shared = SystemProviderCredentialKeychain()
    private init() {}

    func read(service: String, account: String) -> ProviderCredentialKeychainRead {
        var query = Self.query(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return .failed
        }
        return .value(value)
    }

    func write(_ value: String, service: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query = Self.query(service: service, account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { return true }
            if addStatus != errSecDuplicateItem { return false }
            let retryStatus = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            return retryStatus == errSecSuccess
        }
        return updateStatus == errSecSuccess
    }

    func delete(service: String, account: String) -> Bool {
        let status = SecItemDelete(Self.query(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func query(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Profile-scoped storage for provider API keys and device tokens. UserDefaults
/// is read only as a migration source; new credentials are written only after
/// Keychain confirms that the value is durable.
enum ProviderCredentialStore {
    static let service = "tv.nuvio.provider-credentials.v1"
    static let changedNotification = Notification.Name("nuvio.tv.providerCredentials.changed")
    private static let lock = NSRecursiveLock()
    private static let standardDefaults = UserDefaults.standard
    private static let cacheLimit = 128
    private static var cachedValues: [String: String] = [:]
    private static var inProgressAccounts: Set<String> = []
    static let keys: Set<String> = [
        SettingsKey.tmdbApiKey,
        SettingsKey.mdbListApiKey,
        SettingsKey.debridApiKey,
        SettingsKey.torboxAccessToken,
        SettingsKey.premiumizeAccessToken,
        SettingsKey.realDebridAccessToken,
        SettingsKey.seekrApiKey
    ]

    static func string(
        forKey key: String,
        in store: UserDefaults = ProfileSettings.current,
        profileScope: String? = nil
    ) -> String? {
        string(forKey: key, in: store, profileScope: profileScope, keychain: SystemProviderCredentialKeychain.shared)
    }

    static func string(
        forKey key: String,
        in store: UserDefaults,
        profileScope: String?,
        keychain: ProviderCredentialKeychain
    ) -> String? {
        guard keys.contains(key) else { return store.string(forKey: key) }
        lock.lock()
        defer { lock.unlock() }
        let account = account(forKey: key, in: store, profileScope: profileScope)
        if inProgressAccounts.contains(account) { return cachedValues[account] }
        inProgressAccounts.insert(account)
        defer { inProgressAccounts.remove(account) }
        let resolvedScope = profileScope ?? ProfileSettings.credentialScope(for: store)
        let isPrimaryProfile = ProfileSettings.isPrimaryCredentialScope(resolvedScope)
        let deletionMarker = pendingDeletionMarker(for: account)
        let clearMarker = explicitClearMarker(for: account)
        if standardDefaults.bool(forKey: clearMarker) {
            cachedValues.removeValue(forKey: account)
            if standardDefaults.bool(forKey: deletionMarker) {
                if keychain.delete(service: service, account: account) {
                    removeDefaultsValue(forKey: deletionMarker, from: standardDefaults)
                    removeLegacyMirrors(forKey: key, in: store, isPrimaryProfile: isPrimaryProfile)
                }
            } else {
                removeLegacyMirrors(forKey: key, in: store, isPrimaryProfile: isPrimaryProfile)
            }
            return nil
        }
        if standardDefaults.bool(forKey: deletionMarker) {
            cachedValues.removeValue(forKey: account)
            if keychain.delete(service: service, account: account) {
                removeDefaultsValue(forKey: deletionMarker, from: standardDefaults)
                removeLegacyMirrors(forKey: key, in: store, isPrimaryProfile: isPrimaryProfile)
            }
            return nil
        }
        if let cachedValue = cachedValues[account] {
            removeLegacyMirrors(forKey: key, in: store, isPrimaryProfile: isPrimaryProfile)
            return cachedValue
        }
        let legacyValue = store.string(forKey: key)
            ?? ((isPrimaryProfile && store !== standardDefaults)
                ? standardDefaults.string(forKey: key)
                : nil)
        switch keychain.read(service: service, account: account) {
        case .value(let value):
            cacheValue(value, for: account)
            removeLegacyMirrors(forKey: key, in: store, isPrimaryProfile: isPrimaryProfile)
            return value
        case .missing:
            guard let legacyValue, !legacyValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            if keychain.write(legacyValue, service: service, account: account),
               case .value(let persistedValue) = keychain.read(service: service, account: account),
               persistedValue == legacyValue {
                cacheValue(persistedValue, for: account)
                removeLegacyMirrors(forKey: key, in: store, isPrimaryProfile: isPrimaryProfile)
            }
            return legacyValue
        case .failed:
            cachedValues.removeValue(forKey: account)
            // Keep the legacy value readable if Keychain is temporarily
            // unavailable. It is never rewritten to defaults.
            return legacyValue
        }
    }

    static func keychainReadIsAvailable(
        forKey key: String,
        in store: UserDefaults,
        profileScope: String? = nil,
        keychain: ProviderCredentialKeychain = SystemProviderCredentialKeychain.shared
    ) -> Bool {
        guard keys.contains(key) else { return true }
        lock.lock()
        defer { lock.unlock() }
        let account = account(forKey: key, in: store, profileScope: profileScope)
        if standardDefaults.bool(forKey: explicitClearMarker(for: account))
            || standardDefaults.bool(forKey: pendingDeletionMarker(for: account)) {
            return true
        }
        if case .failed = keychain.read(service: service, account: account) { return false }
        return true
    }

    @discardableResult
    static func set(
        _ value: String?,
        forKey key: String,
        in store: UserDefaults = ProfileSettings.current,
        profileScope: String? = nil
    ) -> Bool {
        set(
            value,
            forKey: key,
            in: store,
            profileScope: profileScope,
            keychain: SystemProviderCredentialKeychain.shared,
            notifyChange: true
        )
    }

    @discardableResult
    static func set(
        _ value: String?,
        forKey key: String,
        in store: UserDefaults,
        profileScope: String?,
        keychain: ProviderCredentialKeychain,
        notifyChange: Bool = true
    ) -> Bool {
        guard keys.contains(key) else { return false }
        lock.lock()
        defer { lock.unlock() }
        let account = account(forKey: key, in: store, profileScope: profileScope)
        guard !inProgressAccounts.contains(account) else { return false }
        inProgressAccounts.insert(account)
        defer { inProgressAccounts.remove(account) }
        let resolvedScope = profileScope ?? ProfileSettings.credentialScope(for: store)
        let isPrimaryProfile = ProfileSettings.isPrimaryCredentialScope(resolvedScope)
        let deletionMarker = pendingDeletionMarker(for: account)
        let clearMarker = explicitClearMarker(for: account)
        let previousValue: String? = {
            if case .value(let value) = keychain.read(service: service, account: account) { return value }
            return nil
        }()
        let hadLegacyValue = store.object(forKey: key) != nil
            || (isPrimaryProfile && store !== standardDefaults && standardDefaults.object(forKey: key) != nil)
        if let value, !value.isEmpty {
            guard keychain.write(value, service: service, account: account),
                  case .value(let persistedValue) = keychain.read(service: service, account: account),
                  persistedValue == value else { return false }
            cacheValue(value, for: account)
            removeDefaultsValue(forKey: deletionMarker, from: standardDefaults)
            removeDefaultsValue(forKey: clearMarker, from: standardDefaults)
        } else {
            cachedValues.removeValue(forKey: account)
            setFlagIfNeeded(clearMarker)
            setFlagIfNeeded(deletionMarker)
            guard keychain.delete(service: service, account: account) else {
                // A non-secret tombstone blocks reads if a profile ID is reused
                // before Keychain becomes available to finish the deletion.
                return false
            }
            removeDefaultsValue(forKey: deletionMarker, from: standardDefaults)
        }
        removeLegacyMirrors(forKey: key, in: store, isPrimaryProfile: isPrimaryProfile)
        if notifyChange && (previousValue != (value?.isEmpty == true ? nil : value) || hadLegacyValue) {
            notifyChanged()
        }
        return true
    }

    /// Moves all legacy mirrors in this profile's defaults domain into its
    /// Keychain namespace. A failed item remains available for the next launch.
    static func migrateLegacyCredentials(in store: UserDefaults, profileScope: String) {
        for key in keys {
            _ = string(forKey: key, in: store, profileScope: profileScope)
        }
    }

    /// Adopts a credential from an older provider feature only when this
    /// profile has no local or Keychain value yet.
    @discardableResult
    static func adoptLegacyValueIfMissing(
        _ value: String,
        forKey key: String,
        in store: UserDefaults,
        profileScope: String,
        keychain: ProviderCredentialKeychain = SystemProviderCredentialKeychain.shared
    ) -> Bool {
        guard keys.contains(key),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        let account = account(forKey: key, in: store, profileScope: profileScope)
        guard !standardDefaults.bool(forKey: explicitClearMarker(for: account)) else { return false }
        switch keychain.read(service: service, account: account) {
        case .value, .failed:
            return false
        case .missing:
            let hasLegacyValue = store.string(forKey: key) != nil
                || (ProfileSettings.isPrimaryCredentialScope(profileScope)
                    && store !== standardDefaults
                    && standardDefaults.string(forKey: key) != nil)
            guard !hasLegacyValue else { return false }
            return set(
                value,
                forKey: key,
                in: store,
                profileScope: profileScope,
                keychain: keychain
            )
        }
    }

    /// Removes credentials from this profile and leaves a tombstone when
    /// Keychain is temporarily unavailable so a reused profile ID stays signed out.
    @discardableResult
    static func removeAll(in store: UserDefaults, profileScope: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        var succeeded = true
        var changed = false
        for key in keys {
            let account = account(forKey: key, in: store, profileScope: profileScope)
            let hadKeychainValue: Bool = {
                if case .value = SystemProviderCredentialKeychain.shared.read(service: service, account: account) {
                    return true
                }
                return false
            }()
            let hadLegacyValue = store.object(forKey: key) != nil
                || (ProfileSettings.isPrimaryCredentialScope(profileScope)
                    && store !== standardDefaults
                    && standardDefaults.object(forKey: key) != nil)
            if set(
                nil,
                forKey: key,
                in: store,
                profileScope: profileScope,
                keychain: SystemProviderCredentialKeychain.shared,
                notifyChange: false
            ) == false {
                succeeded = false
            } else if hadKeychainValue || hadLegacyValue {
                changed = true
            }
        }
        if changed { notifyChanged() }
        return succeeded
    }

    private static func account(forKey key: String, in store: UserDefaults, profileScope: String?) -> String {
        "\(profileScope ?? ProfileSettings.credentialScope(for: store)):\(key)"
    }

    private static func pendingDeletionMarker(for account: String) -> String {
        "nuvio.tv.security.providerCredentialDeletionPending.\(account)"
    }

    private static func explicitClearMarker(for account: String) -> String {
        "nuvio.tv.security.providerCredentialExplicitlyCleared.\(account)"
    }

    private static func setFlagIfNeeded(_ key: String) {
        guard !standardDefaults.bool(forKey: key) else { return }
        standardDefaults.set(true, forKey: key)
    }

    private static func removeLegacyMirrors(
        forKey key: String,
        in store: UserDefaults,
        isPrimaryProfile: Bool
    ) {
        removeDefaultsValue(forKey: key, from: store)
        if isPrimaryProfile, store !== standardDefaults {
            removeDefaultsValue(forKey: key, from: standardDefaults)
        }
    }

    private static func removeDefaultsValue(forKey key: String, from store: UserDefaults) {
        guard store.object(forKey: key) != nil else { return }
        store.removeObject(forKey: key)
    }

    private static func cacheValue(_ value: String, for account: String) {
        if cachedValues[account] == nil, cachedValues.count >= cacheLimit,
           let evictedAccount = cachedValues.keys.first {
            cachedValues.removeValue(forKey: evictedAccount)
        }
        cachedValues[account] = value
    }

    static func notifyChanged() {
        let post = {
            NotificationCenter.default.post(name: changedNotification, object: nil)
            ProfileSettings.notifySettingsChanged()
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}

/// API keys the desktop and mobile apps keep out of the settings blobs and
/// sync through `sync_pull_provider_credentials` /
/// `sync_push_provider_credentials` instead: one row per provider, with
/// `credential_json` such as `{"api_key": "…"}`.
///
/// The Apple TV handles the MDBList, TMDB and debrid keys, more carefully
/// than the desktop app in both directions so a key is never lost:
/// - a pull applies only non-empty keys, so a device without one cannot
///   clear this Apple TV's;
/// - a push happens only when a non-empty key that differs from the
///   account's is saved here, and sends every row the account already has
///   with just that provider changed, so keys this Apple TV doesn't know
///   (AnimeSkip, IntroDB) stay as they are.
///
/// Debrid keys only come in, and only into an empty slot: the Apple TV's own
/// debrid sign-in stores a device token that can expire, which must neither
/// be replaced by nor sent to the account as an API key.
enum ProviderCredentialSync {
    enum Provider: String, CaseIterable, Sendable {
        case mdblist
        case tmdb
        case realDebrid = "debrid:realdebrid"
        case premiumize = "debrid:premiumize"
        case torbox = "debrid:torbox"

        var field: String { "api_key" }

        var localKey: String {
            switch self {
            case .mdblist: return SettingsKey.mdbListApiKey
            case .tmdb: return SettingsKey.tmdbApiKey
            case .realDebrid: return SettingsKey.realDebridAccessToken
            case .premiumize: return SettingsKey.premiumizeAccessToken
            case .torbox: return SettingsKey.torboxAccessToken
            }
        }

        var isDebrid: Bool { rawValue.hasPrefix("debrid:") }

        /// Whether a key saved on this Apple TV is sent to the account.
        var isPushed: Bool { !isDebrid }

        var debridKind: DebridProviderKind? {
            switch self {
            case .realDebrid: return .realDebrid
            case .premiumize: return .premiumize
            case .torbox: return .torbox
            case .mdblist, .tmdb: return nil
            }
        }
    }

    /// The non-empty key for each provider in the pulled rows.
    static func remoteKeys(in rows: [[String: Any]]) -> [Provider: String] {
        var keys: [Provider: String] = [:]
        for row in rows {
            guard let name = (row["provider"] as? String)?.lowercased(),
                  let provider = Provider(rawValue: name),
                  let credential = row["credential_json"] as? [String: Any],
                  let value = (credential[provider.field] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            keys[provider] = value
        }
        return keys
    }

    /// Writes the pulled keys that differ from the stored ones and returns
    /// the providers that changed.
    @discardableResult
    static func apply(
        rows: [[String: Any]],
        to store: UserDefaults,
        profileScope: String? = nil,
        keychain: ProviderCredentialKeychain = SystemProviderCredentialKeychain.shared
    ) -> [Provider] {
        var changed: [Provider] = []
        for (provider, value) in remoteKeys(in: rows).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard ProviderCredentialStore.keychainReadIsAvailable(
                forKey: provider.localKey,
                in: store,
                profileScope: profileScope,
                keychain: keychain
            ) else { continue }
            let current = ProviderCredentialStore.string(
                forKey: provider.localKey,
                in: store,
                profileScope: profileScope,
                keychain: keychain
            )?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard current != value else { continue }
            if provider.isDebrid, !current.isEmpty { continue }
            guard ProviderCredentialStore.set(
                value,
                forKey: provider.localKey,
                in: store,
                profileScope: profileScope,
                keychain: keychain,
                notifyChange: false
            ) else { continue }
            changed.append(provider)
        }
        if changed.contains(where: \.isDebrid) {
            selectDebridProviderIfNeeded(in: store, profileScope: profileScope, keychain: keychain)
        }
        if !changed.isEmpty { ProviderCredentialStore.notifyChanged() }
        return changed
    }

    /// With no debrid service chosen yet, picks the first one that now has a
    /// key, in the order the settings import uses (TorBox, Premiumize,
    /// Real-Debrid), and keeps the active key in step with the choice.
    static func selectDebridProviderIfNeeded(
        in store: UserDefaults,
        profileScope: String? = nil,
        keychain: ProviderCredentialKeychain = SystemProviderCredentialKeychain.shared
    ) {
        var selected = DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider))
        if selected == .none {
            for provider in [Provider.torbox, .premiumize, .realDebrid] {
                let key = ProviderCredentialStore.string(
                    forKey: provider.localKey,
                    in: store,
                    profileScope: profileScope,
                    keychain: keychain
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !key.isEmpty, let kind = provider.debridKind {
                    selected = kind
                    break
                }
            }
        }
        guard selected != .none else { return }
        store.set(selected.rawValue, forKey: SettingsKey.debridProvider)
        let token = DebridCredentials.token(
            for: selected,
            store: store,
            profileScope: profileScope,
            keychain: keychain
        )
        _ = ProviderCredentialStore.set(
            token,
            forKey: SettingsKey.debridApiKey,
            in: store,
            profileScope: profileScope,
            keychain: keychain,
            notifyChange: false
        )
    }

    /// The push payload: every pulled row as it is, with `provider`'s row
    /// replaced by `value` (or added when the account has none).
    static func pushRows(
        merging provider: Provider,
        value: String,
        into rows: [[String: Any]]
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var replaced = false
        for row in rows {
            guard let name = row["provider"] as? String else { continue }
            let credential = row["credential_json"] as? [String: Any] ?? [:]
            if name.lowercased() == provider.rawValue {
                guard !replaced else { continue }
                replaced = true
                result.append(["provider": provider.rawValue, "credential_json": [provider.field: value]])
            } else {
                result.append(["provider": name, "credential_json": credential])
            }
        }
        if !replaced {
            result.append(["provider": provider.rawValue, "credential_json": [provider.field: value]])
        }
        return result
    }
}
