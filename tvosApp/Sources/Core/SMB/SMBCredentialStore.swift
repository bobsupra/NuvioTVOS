import Foundation
import Security

/// Device-local SMB passwords, one per server per profile. Mirrors
/// `AISubtitleKeyStore`'s Keychain pattern (`UI/Settings/SettingsView.swift`):
/// the server config (host, username, auth kind) lives in per-profile
/// UserDefaults via `SMBServerStore`, while the password itself stays in
/// Keychain and is never included in a profile copy, a sync payload, or a
/// bug-report export.
enum SMBCredentialStore {
    private static let service = "com.nuvio.tv.smb"

    static func password(
        forServerID serverID: String,
        profileScope: String = ProfileSettings.activeProfileScope
    ) -> String {
        read(for: serverID, profileScope: profileScope) ?? ""
    }

    @discardableResult
    static func save(
        _ password: String,
        forServerID serverID: String,
        profileScope: String = ProfileSettings.activeProfileScope
    ) -> Bool {
        guard !password.isEmpty else {
            return remove(forServerID: serverID, profileScope: profileScope)
        }

        let data = Data(password.utf8)
        var addQuery = keychainQuery(for: serverID, profileScope: profileScope)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(
                keychainQuery(for: serverID, profileScope: profileScope) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        }
        return status == errSecSuccess
    }

    @discardableResult
    static func remove(
        forServerID serverID: String,
        profileScope: String = ProfileSettings.activeProfileScope
    ) -> Bool {
        let status = SecItemDelete(keychainQuery(for: serverID, profileScope: profileScope) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func read(for serverID: String, profileScope: String) -> String? {
        var query = keychainQuery(for: serverID, profileScope: profileScope)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainQuery(for serverID: String, profileScope: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(serverID).\(profileScope)"
        ]
    }
}
