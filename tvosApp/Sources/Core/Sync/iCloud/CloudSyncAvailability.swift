import CloudKit
import Foundation
import Security

/// Shared identifiers for iCloud settings sync. The container belongs to the
/// developer team, while the records themselves live in each user's own private
/// database — switching teams never moves user data, it only changes which
/// container the app reaches for.
enum CloudSync {
    static let containerID = "iCloud.com.rb.nuviotvos"
}

/// Whether this Apple TV can sync at all.
///
/// Two states must degrade to a silent no-op rather than an error: a sideloaded
/// build ships without the iCloud entitlement, and a TV signed out of iCloud has
/// no private database to write to. Both are ordinary for this app — see the
/// unsigned/sideload handling in `ProfileViewModel.makeDefaultProfileManager` —
/// so neither deserves an alert.
enum CloudSyncAvailability {
    enum Status: Equatable {
        /// Signed in, with a usable private database.
        case available
        /// No Apple Account signed into this Apple TV.
        case noAccount
        /// Parental controls or an MDM profile block iCloud.
        case restricted
        /// Network or CloudKit hiccup — worth retrying later.
        case temporarilyUnavailable
        /// Reaching the container failed outright, which is what a sideloaded
        /// build without the entitlement looks like.
        case unavailable(String)

        var canSync: Bool { self == .available }

        /// Short, non-sensitive text for the Settings diagnostics row.
        var displayText: String {
            switch self {
            case .available: return "Available"
            case .noAccount: return "No iCloud account"
            case .restricted: return "Restricted"
            case .temporarilyUnavailable: return "Temporarily unavailable"
            case .unavailable(let reason): return reason
            }
        }
    }

    static func current() async -> Status {
        do {
            let status = try await CKContainer(identifier: CloudSync.containerID).accountStatus()
            switch status {
            case .available: return .available
            case .noAccount: return .noAccount
            case .restricted: return .restricted
            case .couldNotDetermine, .temporarilyUnavailable: return .temporarilyUnavailable
            @unknown default: return .temporarilyUnavailable
            }
        } catch {
            return .unavailable(shortDescription(for: error))
        }
    }

    private static func shortDescription(for error: Error) -> String {
        let singleLine = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        return String(singleLine.prefix(120))
    }
}

// MARK: - Phase 0 gate

/// Round-trip test for iCloud Keychain on tvOS.
///
/// A successful `SecItemAdd` with `kSecAttrSynchronizable` only proves the
/// keychain *accepts* the attribute; it cannot tell whether the item ever
/// leaves the device. The only conclusive check is writing on one Apple TV and
/// reading it back on another signed into the same Apple Account — so `write`
/// is deliberately behind an explicit action, never run on view appearance.
///
/// Note the accessibility class below. A synchronizing item may not use any
/// `...ThisDeviceOnly` value, which is exactly what every existing credential
/// store uses today — `SMBCredentialStore`, `JellyfinCredentialStore`,
/// `AISubtitleKeyStore`. Adopting iCloud Keychain would mean relaxing all three
/// from `AfterFirstUnlockThisDeviceOnly` to `AfterFirstUnlock`, which is a real
/// (if small) security tradeoff, not a free win.
enum CloudKeychainProbe {
    private static let service = "com.nuvio.tv.icloud-probe"
    private static let account = "roundtrip"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any
        ]
    }

    /// Stamps this Apple TV into a synchronizable item. Run on TV A.
    static func write(marker: String) -> String {
        SecItemDelete(baseQuery as CFDictionary)

        var insert = baseQuery
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        insert[kSecValueData as String] = Data(marker.utf8)

        let status = SecItemAdd(insert as CFDictionary, nil)
        return status == errSecSuccess ? "wrote: \(marker)" : "write failed (OSStatus \(status))"
    }

    /// Reads whatever the account currently holds. Run on TV B. A marker naming
    /// the *other* Apple TV is the only result that proves cross-device sync.
    static func read() -> String {
        var lookup = baseQuery
        lookup[kSecReturnData as String] = kCFBooleanTrue
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return status == errSecItemNotFound
                ? "not found"
                : "read failed (OSStatus \(status))"
        }
        return value
    }
}
