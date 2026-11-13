import Foundation
import Security

/// Device-local Jellyfin access tokens, one per server per profile. Mirrors
/// `SMBCredentialStore`'s Keychain pattern: the server config (base URL,
/// username, auth kind) lives in per-profile UserDefaults via
/// `JellyfinServerStore`, while the secret — the raw API key in `.apiKey`
/// mode, or the token `AuthenticateByName` returned in `.login` mode — stays
/// in Keychain and is never included in a profile copy, a sync payload, or a
/// bug-report export.
enum JellyfinCredentialStore {
    static var storage: JellyfinCredentialStorage = JellyfinKeychainCredentialStorage()

    static func token(
        forServerID serverID: String,
        profileScope: String = ProfileSettings.activeProfileScope
    ) -> String {
        storage.token(forServerID: serverID, profileScope: profileScope) ?? ""
    }

    @discardableResult
    static func save(
        _ token: String,
        forServerID serverID: String,
        profileScope: String = ProfileSettings.activeProfileScope
    ) -> Bool {
        guard !token.isEmpty else {
            return storage.remove(forServerID: serverID, profileScope: profileScope)
        }
        return storage.save(token, forServerID: serverID, profileScope: profileScope)
    }

    @discardableResult
    static func remove(
        forServerID serverID: String,
        profileScope: String = ProfileSettings.activeProfileScope
    ) -> Bool {
        storage.remove(forServerID: serverID, profileScope: profileScope)
    }
}

protocol JellyfinCredentialStorage: AnyObject {
    func token(forServerID serverID: String, profileScope: String) -> String?
    @discardableResult
    func save(_ token: String, forServerID serverID: String, profileScope: String) -> Bool
    @discardableResult
    func remove(forServerID serverID: String, profileScope: String) -> Bool
}

/// Production Jellyfin credentials stay in the device-only Keychain.
final class JellyfinKeychainCredentialStorage: JellyfinCredentialStorage {
    private static let service = "com.nuvio.tv.jellyfin"

    func token(forServerID serverID: String, profileScope: String) -> String? {
        var query = Self.keychainQuery(for: serverID, profileScope: profileScope)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func save(_ token: String, forServerID serverID: String, profileScope: String) -> Bool {
        let data = Data(token.utf8)
        var addQuery = Self.keychainQuery(for: serverID, profileScope: profileScope)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(
                Self.keychainQuery(for: serverID, profileScope: profileScope) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    func remove(forServerID serverID: String, profileScope: String) -> Bool {
        let status = SecItemDelete(Self.keychainQuery(for: serverID, profileScope: profileScope) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func keychainQuery(for serverID: String, profileScope: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(serverID).\(profileScope)"
        ]
    }
}
