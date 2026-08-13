import Foundation

/// Carries Keychain-resident credentials through the settings record's
/// encrypted field.
///
/// Most secrets live in the profile's `UserDefaults` suite and export by key.
/// These three do not: `AISubtitleKeyStore` migrates its value out of
/// `UserDefaults` into the Keychain and *removes* the original
/// (`SettingsView.swift:674`), and the Simkl token was never in a suite at all.
/// Without this bridge they read as nil and sync silently exports nothing —
/// the failure being an API key that just never appears on the second Apple TV.
///
/// The identifiers below are sync-only. They are deliberately not `SettingsKey`
/// values, because nothing reads them from a suite.
enum KeychainSecretBridge {
    /// Posted when a Keychain secret changes. `UserDefaults.didChangeNotification`
    /// cannot see a Keychain write, so without this the change journal would not
    /// stamp it until some unrelated setting happened to change.
    static let changedNotification = Notification.Name("nuvio.tv.icloud.keychainSecretChanged")

    enum Secret: String, CaseIterable {
        case aiGemini = "nuvio.icloud.secret.ai.gemini"
        case aiOpenRouter = "nuvio.icloud.secret.ai.openRouter"
        case simklAccessToken = "nuvio.icloud.secret.simkl.accessToken"
    }

    static let keys: [String] = Secret.allCases.map(\.rawValue)

    /// Reads the active profile's secret.
    ///
    /// `AISubtitleKeyStore.apiKey` resolves the scope internally from the active
    /// profile, so unlike the write path this cannot address another profile.
    /// That is sufficient: only the active profile's settings record is exported.
    static func read(_ secret: Secret) -> String? {
        let value: String
        switch secret {
        case .aiGemini:
            value = AISubtitleKeyStore.apiKey(for: .gemini)
        case .aiOpenRouter:
            value = AISubtitleKeyStore.apiKey(for: .openRouter)
        case .simklAccessToken:
            value = SimklKeychainTokenStorage()
                .accessToken(for: ProfileSettings.activeProfileScope) ?? ""
        }
        return value.isEmpty ? nil : value
    }

    static func write(_ value: String?, secret: Secret, profileScope: String) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch secret {
        case .aiGemini:
            if trimmed.isEmpty {
                AISubtitleKeyStore.remove(for: .gemini, profileScope: profileScope)
            } else {
                AISubtitleKeyStore.save(trimmed, for: .gemini, profileScope: profileScope)
            }
        case .aiOpenRouter:
            if trimmed.isEmpty {
                AISubtitleKeyStore.remove(for: .openRouter, profileScope: profileScope)
            } else {
                AISubtitleKeyStore.save(trimmed, for: .openRouter, profileScope: profileScope)
            }
        case .simklAccessToken:
            SimklKeychainTokenStorage()
                .setAccessToken(trimmed.isEmpty ? nil : trimmed, for: profileScope)
        }
    }

    /// Folds the Keychain secrets into a snapshot that was exported from a suite.
    static func inject(into snapshot: inout SettingsSnapshot) {
        for secret in Secret.allCases {
            snapshot.secrets[secret.rawValue] = read(secret).map(SettingValue.string)
        }
    }

    /// Writes merged secrets back into the Keychain.
    ///
    /// Unstamped entries are skipped — the sending device never touched them,
    /// so they must not clear a credential this device holds. A stamped entry
    /// with no value is a tombstone and does clear it.
    static func apply(_ snapshot: SettingsSnapshot, profileScope: String) {
        for secret in Secret.allCases {
            guard snapshot.stamps[secret.rawValue] != nil else { continue }
            if case .string(let value)? = snapshot.secrets[secret.rawValue] {
                write(value, secret: secret, profileScope: profileScope)
            } else {
                write(nil, secret: secret, profileScope: profileScope)
            }
        }
    }

    static func postChanged() {
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
