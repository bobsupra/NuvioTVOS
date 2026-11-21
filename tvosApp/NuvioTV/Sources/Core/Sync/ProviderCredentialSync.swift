import Foundation

/// API keys the desktop and mobile apps keep out of the settings blobs and
/// sync through `sync_pull_provider_credentials` /
/// `sync_push_provider_credentials` instead: one row per provider, with
/// `credential_json` such as `{"api_key": "…"}`.
///
/// The Apple TV handles the MDBList and TMDB keys, more carefully than the
/// desktop app in both directions so a key is never lost:
/// - a pull applies only non-empty keys, so a device without one cannot
///   clear this Apple TV's;
/// - a push happens only when a non-empty key that differs from the
///   account's is saved here, and sends every row the account already has
///   with just that provider changed, so keys this Apple TV doesn't know
///   (debrid, AnimeSkip, IntroDB) stay as they are.
enum ProviderCredentialSync {
    enum Provider: String, CaseIterable, Sendable {
        case mdblist
        case tmdb

        var field: String { "api_key" }

        var localKey: String {
            switch self {
            case .mdblist: return SettingsKey.mdbListApiKey
            case .tmdb: return SettingsKey.tmdbApiKey
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
    static func apply(rows: [[String: Any]], to store: UserDefaults) -> [Provider] {
        var changed: [Provider] = []
        for (provider, value) in remoteKeys(in: rows).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let current = store.string(forKey: provider.localKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard current != value else { continue }
            store.set(value, forKey: provider.localKey)
            changed.append(provider)
        }
        return changed
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
