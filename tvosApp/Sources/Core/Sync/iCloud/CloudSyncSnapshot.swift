import Foundation

// MARK: - SettingValue

/// A `UserDefaults` value in a form that survives a round trip through JSON.
///
/// `Data` carries more weight here than it looks. `SMBServerStore` and
/// `JellyfinServerStore` persist their configs as JSON `Data` blobs, and the
/// account sync's codec (`NuvioSyncService.encodeSettingValue`) returns nil for
/// anything that isn't a string, number, or bool — which is why SMB and
/// Jellyfin servers have never actually propagated between devices despite
/// being listed in `SettingsKey.all`.
enum SettingValue: Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case data(Data)
    case stringArray([String])

    /// Reads a key, preserving its real type.
    ///
    /// `UserDefaults` bridges both bools and numbers to `NSNumber`, so a plain
    /// `as? Bool` succeeds for any integer 0 or 1 — a `networkCache` of 1 would
    /// come back as `true`. Ask CoreFoundation for the underlying type instead.
    static func read(from defaults: UserDefaults, key: String) -> SettingValue? {
        guard let object = defaults.object(forKey: key) else { return nil }

        if let number = object as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return CFNumberIsFloatType(number as CFNumber)
                ? .double(number.doubleValue)
                : .int(number.intValue)
        }
        if let string = object as? String { return .string(string) }
        if let data = object as? Data { return .data(data) }
        if let array = object as? [String] { return .stringArray(array) }
        return nil
    }

    func write(to defaults: UserDefaults, key: String) {
        switch self {
        case .string(let value): defaults.set(value, forKey: key)
        case .bool(let value): defaults.set(value, forKey: key)
        case .int(let value): defaults.set(value, forKey: key)
        case .double(let value): defaults.set(value, forKey: key)
        case .data(let value): defaults.set(value, forKey: key)
        case .stringArray(let value): defaults.set(value, forKey: key)
        }
    }
}

extension SettingValue: Codable {
    private enum CodingKeys: String, CodingKey { case type, value }
    private enum Kind: String, Codable {
        case string, bool, int, double, data, stringArray
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .string: self = .string(try container.decode(String.self, forKey: .value))
        case .bool: self = .bool(try container.decode(Bool.self, forKey: .value))
        case .int: self = .int(try container.decode(Int.self, forKey: .value))
        case .double: self = .double(try container.decode(Double.self, forKey: .value))
        case .data: self = .data(try container.decode(Data.self, forKey: .value))
        case .stringArray: self = .stringArray(try container.decode([String].self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(Kind.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .type)
            try container.encode(value, forKey: .value)
        case .int(let value):
            try container.encode(Kind.int, forKey: .type)
            try container.encode(value, forKey: .value)
        case .double(let value):
            try container.encode(Kind.double, forKey: .type)
            try container.encode(value, forKey: .value)
        case .data(let value):
            try container.encode(Kind.data, forKey: .type)
            try container.encode(value, forKey: .value)
        case .stringArray(let value):
            try container.encode(Kind.stringArray, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

// MARK: - SettingsSnapshot

/// One profile's settings, carrying a modification stamp per key so two Apple
/// TVs editing different settings merge instead of clobbering each other.
///
/// A key with a stamp but no value is a **tombstone** — it was deleted at that
/// time. That is what lets "user cleared their TMDB key" propagate, rather than
/// the other device silently restoring it on the next merge.
struct SettingsSnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    var values: [String: SettingValue] = [:]
    var secrets: [String: SettingValue] = [:]
    /// Milliseconds since epoch, per key.
    var stamps: [String: Int64] = [:]
    var deviceID: String = ""
    var schemaVersion: Int = SettingsSnapshot.currentSchemaVersion

    static func export(
        from defaults: UserDefaults,
        stamps: [String: Int64],
        deviceID: String
    ) -> SettingsSnapshot {
        var snapshot = SettingsSnapshot(deviceID: deviceID)
        snapshot.stamps = stamps

        for key in CloudSyncPolicy.plainKeys {
            snapshot.values[key] = SettingValue.read(from: defaults, key: key)
        }
        for key in CloudSyncPolicy.secretKeys {
            snapshot.secrets[key] = SettingValue.read(from: defaults, key: key)
        }
        return snapshot
    }

    /// Writes every carried key, removing the ones this snapshot tombstones.
    ///
    /// `includeSecrets` is false when the user has opted this device out of
    /// credential sync — it then reads plain settings but leaves its own
    /// credentials untouched.
    func apply(to defaults: UserDefaults, includeSecrets: Bool = true) {
        for key in CloudSyncPolicy.plainKeys {
            guard stamps[key] != nil else { continue }
            if let value = values[key] {
                value.write(to: defaults, key: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        guard includeSecrets else { return }
        for key in CloudSyncPolicy.secretKeys {
            guard stamps[key] != nil else { continue }
            if let value = secrets[key] {
                value.write(to: defaults, key: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Per-key last-writer-wins.
    ///
    /// Ties are broken on device id rather than left to arrive-order, so both
    /// sides of a simultaneous edit converge on the same answer instead of
    /// each preferring its own and pushing forever.
    static func merge(local: SettingsSnapshot, remote: SettingsSnapshot) -> SettingsSnapshot {
        var merged = local
        merged.schemaVersion = max(local.schemaVersion, remote.schemaVersion)

        let touchedKeys = Set(local.stamps.keys)
            .union(remote.stamps.keys)
            .union(local.values.keys)
            .union(remote.values.keys)
            .union(local.secrets.keys)
            .union(remote.secrets.keys)

        for key in touchedKeys {
            let localStamp = local.stamps[key] ?? 0
            let remoteStamp = remote.stamps[key] ?? 0

            let remoteWins = remoteStamp == localStamp
                ? remote.deviceID > local.deviceID
                : remoteStamp > localStamp
            guard remoteWins else { continue }

            merged.stamps[key] = remoteStamp
            // Assigning nil removes the key, which is exactly the tombstone.
            merged.values[key] = remote.values[key]
            merged.secrets[key] = remote.secrets[key]
        }
        return merged
    }
}

// MARK: - Profile list

/// One profile as it travels between Apple TVs.
///
/// `isPinProtected` is deliberately absent. The PIN itself is device-local
/// Keychain data that never syncs, so carrying the flag alone would mark a
/// profile as locked on a TV that holds no secret to unlock it — and without a
/// Nuvio account there is no remote verifier to fall back on. That is a lockout,
/// not a sync.
struct ProfileSnapshot: Codable, Equatable {
    var id: String
    var name: String
    var avatarId: String
    var isAdmin: Bool
}

struct ProfileListSnapshot: Codable, Equatable {
    var profiles: [ProfileSnapshot] = []
    var updatedAt: Int64 = 0

    static func merge(
        local: ProfileListSnapshot,
        remote: ProfileListSnapshot
    ) -> ProfileListSnapshot {
        remote.updatedAt > local.updatedAt ? remote : local
    }
}

// MARK: - Per-entity snapshots

/// One configured SMB server. The password travels in the record's encrypted
/// field, never in `config`.
struct SMBServerSnapshot: Codable, Equatable {
    var config: SMBServerConfig
    var password: String
    var updatedAt: Int64
}

/// One configured Jellyfin server. The access token travels in the record's
/// encrypted field, never in `config`.
struct JellyfinServerSnapshot: Codable, Equatable {
    var config: JellyfinServerConfig
    var token: String
    var updatedAt: Int64
}

/// A small, cohesive group of settings keys carried by one dedicated record —
/// the add-on list and the home layout.
///
/// Unlike `SettingsSnapshot` this merges whole-record rather than per key. An
/// ordering and the set of hidden rows only make sense together; taking the
/// order from one TV and the hidden set from another produces a layout neither
/// user asked for.
struct KeyedSettingsSnapshot: Codable, Equatable {
    var values: [String: SettingValue] = [:]
    var updatedAt: Int64 = 0

    static func export(
        keys: [String],
        from defaults: UserDefaults,
        updatedAt: Int64
    ) -> KeyedSettingsSnapshot {
        var snapshot = KeyedSettingsSnapshot(updatedAt: updatedAt)
        for key in keys {
            snapshot.values[key] = SettingValue.read(from: defaults, key: key)
        }
        return snapshot
    }

    func apply(keys: [String], to defaults: UserDefaults) {
        for key in keys {
            if let value = values[key] {
                value.write(to: defaults, key: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    static func merge(
        local: KeyedSettingsSnapshot,
        remote: KeyedSettingsSnapshot
    ) -> KeyedSettingsSnapshot {
        remote.updatedAt > local.updatedAt ? remote : local
    }
}
