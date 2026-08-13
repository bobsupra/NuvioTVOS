import CloudKit
import Foundation

/// The CloudKit shape of iCloud settings sync: one zone, six record types, and
/// the mapping between `CKRecord`s and the Phase 1 snapshots.
///
/// Record names are deterministic (`settings-<profile>`, `smb-<server>`) rather
/// than random, so any device can address the same record without first
/// fetching an index — and a server deleted on one Apple TV becomes a real
/// tombstone the others can act on.
enum CloudSyncSchema {
    static let zoneName = "NuvioSync"

    static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    enum RecordType {
        static let profileList = "ProfileList"
        static let profileSettings = "ProfileSettings"
        static let smbServer = "SMBServer"
        static let jellyfinServer = "JellyfinServer"
        static let addonList = "AddonList"
        static let homeLayout = "HomeLayout"
    }

    /// Field names shared across record types. `secrets`, `password`, and
    /// `token` are only ever written through `CKRecord.encryptedValues`, which
    /// the private database encrypts with keys only the user's devices hold.
    enum Field {
        static let payload = "payload"
        static let stamps = "stamps"
        static let secrets = "secrets"
        static let config = "config"
        static let password = "password"
        static let token = "token"
        static let profileID = "profileID"
        static let deviceID = "deviceID"
        static let updatedAt = "updatedAt"
        static let schemaVersion = "schemaVersion"
    }

    // MARK: - Record identity

    /// What a record name refers to. Parsed from the name so an arriving change
    /// can be routed without consulting any local index.
    enum Identity: Equatable {
        case profileList
        case profileSettings(profileID: String)
        case smbServer(serverID: String)
        case jellyfinServer(serverID: String)
        case addonList(profileID: String)
        case homeLayout(profileID: String)
    }

    private enum Prefix {
        static let profileList = "profiles"
        static let profileSettings = "settings-"
        static let smbServer = "smb-"
        static let jellyfinServer = "jf-"
        static let addonList = "addons-"
        static let homeLayout = "home-"
    }

    static func recordID(for identity: Identity) -> CKRecord.ID {
        CKRecord.ID(recordName: recordName(for: identity), zoneID: zoneID)
    }

    static func recordName(for identity: Identity) -> String {
        switch identity {
        case .profileList: return Prefix.profileList
        case .profileSettings(let id): return Prefix.profileSettings + id
        case .smbServer(let id): return Prefix.smbServer + id
        case .jellyfinServer(let id): return Prefix.jellyfinServer + id
        case .addonList(let id): return Prefix.addonList + id
        case .homeLayout(let id): return Prefix.homeLayout + id
        }
    }

    static func identity(forRecordName name: String) -> Identity? {
        if name == Prefix.profileList { return .profileList }
        if let id = suffix(of: name, after: Prefix.profileSettings) { return .profileSettings(profileID: id) }
        if let id = suffix(of: name, after: Prefix.smbServer) { return .smbServer(serverID: id) }
        if let id = suffix(of: name, after: Prefix.jellyfinServer) { return .jellyfinServer(serverID: id) }
        if let id = suffix(of: name, after: Prefix.addonList) { return .addonList(profileID: id) }
        if let id = suffix(of: name, after: Prefix.homeLayout) { return .homeLayout(profileID: id) }
        return nil
    }

    static func recordType(for identity: Identity) -> String {
        switch identity {
        case .profileList: return RecordType.profileList
        case .profileSettings: return RecordType.profileSettings
        case .smbServer: return RecordType.smbServer
        case .jellyfinServer: return RecordType.jellyfinServer
        case .addonList: return RecordType.addonList
        case .homeLayout: return RecordType.homeLayout
        }
    }

    private static func suffix(of name: String, after prefix: String) -> String? {
        guard name.hasPrefix(prefix) else { return nil }
        let value = String(name.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }
}

// MARK: - Settings record

extension CloudSyncSchema {
    static func makeSettingsRecord(
        _ snapshot: SettingsSnapshot,
        profileID: String,
        base: CKRecord?
    ) throws -> CKRecord {
        let identity = Identity.profileSettings(profileID: profileID)
        let record = base ?? CKRecord(
            recordType: recordType(for: identity),
            recordID: recordID(for: identity)
        )

        let encoder = JSONEncoder()
        record[Field.payload] = try encoder.encode(snapshot.values) as CKRecordValue
        record[Field.stamps] = try encoder.encode(snapshot.stamps) as CKRecordValue
        record[Field.deviceID] = snapshot.deviceID as CKRecordValue
        record[Field.schemaVersion] = snapshot.schemaVersion as CKRecordValue
        // Credentials never touch a plain field.
        record.encryptedValues[Field.secrets] = try encoder.encode(snapshot.secrets) as CKRecordValue
        return record
    }

    static func settingsSnapshot(from record: CKRecord) -> SettingsSnapshot? {
        let decoder = JSONDecoder()
        var snapshot = SettingsSnapshot()

        if let data = record[Field.payload] as? Data {
            snapshot.values = (try? decoder.decode([String: SettingValue].self, from: data)) ?? [:]
        }
        if let data = record[Field.stamps] as? Data {
            snapshot.stamps = (try? decoder.decode([String: Int64].self, from: data)) ?? [:]
        }
        if let data = record.encryptedValues[Field.secrets] as? Data {
            snapshot.secrets = (try? decoder.decode([String: SettingValue].self, from: data)) ?? [:]
        }
        snapshot.deviceID = record[Field.deviceID] as? String ?? ""
        snapshot.schemaVersion = record[Field.schemaVersion] as? Int ?? SettingsSnapshot.currentSchemaVersion

        // A record with nothing in it carries nothing actionable — treat it as
        // absent rather than applying an empty snapshot over live settings.
        // Secrets count: a profile whose only synced setting is an API key has
        // an empty `values` and would otherwise be silently dropped.
        let isEmpty = snapshot.stamps.isEmpty
            && snapshot.values.isEmpty
            && snapshot.secrets.isEmpty
        return isEmpty ? nil : snapshot
    }
}

// MARK: - Profile list record

extension CloudSyncSchema {
    static func makeProfileListRecord(
        _ snapshot: ProfileListSnapshot,
        base: CKRecord?
    ) throws -> CKRecord {
        let record = base ?? CKRecord(
            recordType: recordType(for: .profileList),
            recordID: recordID(for: .profileList)
        )
        record[Field.payload] = try JSONEncoder().encode(snapshot.profiles) as CKRecordValue
        record[Field.updatedAt] = snapshot.updatedAt as CKRecordValue
        return record
    }

    static func profileListSnapshot(from record: CKRecord) -> ProfileListSnapshot? {
        guard let data = record[Field.payload] as? Data,
              let profiles = try? JSONDecoder().decode([ProfileSnapshot].self, from: data),
              !profiles.isEmpty else {
            return nil
        }
        return ProfileListSnapshot(
            profiles: profiles,
            updatedAt: record[Field.updatedAt] as? Int64 ?? 0
        )
    }
}

// MARK: - Keyed records (add-on list, home layout)

extension CloudSyncSchema {
    static func makeKeyedRecord(
        _ snapshot: KeyedSettingsSnapshot,
        identity: Identity,
        base: CKRecord?
    ) throws -> CKRecord {
        let record = base ?? CKRecord(
            recordType: recordType(for: identity),
            recordID: recordID(for: identity)
        )
        record[Field.payload] = try JSONEncoder().encode(snapshot.values) as CKRecordValue
        record[Field.updatedAt] = snapshot.updatedAt as CKRecordValue
        return record
    }

    static func keyedSnapshot(from record: CKRecord) -> KeyedSettingsSnapshot? {
        guard let data = record[Field.payload] as? Data,
              let values = try? JSONDecoder().decode([String: SettingValue].self, from: data) else {
            return nil
        }
        return KeyedSettingsSnapshot(
            values: values,
            updatedAt: record[Field.updatedAt] as? Int64 ?? 0
        )
    }
}

// MARK: - Server records

extension CloudSyncSchema {
    static func makeSMBRecord(
        _ snapshot: SMBServerSnapshot,
        profileID: String,
        base: CKRecord?
    ) throws -> CKRecord {
        let identity = Identity.smbServer(serverID: snapshot.config.id)
        let record = base ?? CKRecord(
            recordType: recordType(for: identity),
            recordID: recordID(for: identity)
        )
        record[Field.config] = try JSONEncoder().encode(snapshot.config) as CKRecordValue
        record[Field.profileID] = profileID as CKRecordValue
        record[Field.updatedAt] = snapshot.updatedAt as CKRecordValue
        record.encryptedValues[Field.password] = snapshot.password as CKRecordValue
        return record
    }

    static func smbSnapshot(from record: CKRecord) -> (snapshot: SMBServerSnapshot, profileID: String)? {
        guard let data = record[Field.config] as? Data,
              let config = try? JSONDecoder().decode(SMBServerConfig.self, from: data),
              let profileID = record[Field.profileID] as? String else {
            return nil
        }
        let snapshot = SMBServerSnapshot(
            config: config,
            password: record.encryptedValues[Field.password] as? String ?? "",
            updatedAt: record[Field.updatedAt] as? Int64 ?? 0
        )
        return (snapshot, profileID)
    }

    static func makeJellyfinRecord(
        _ snapshot: JellyfinServerSnapshot,
        profileID: String,
        base: CKRecord?
    ) throws -> CKRecord {
        let identity = Identity.jellyfinServer(serverID: snapshot.config.id)
        let record = base ?? CKRecord(
            recordType: recordType(for: identity),
            recordID: recordID(for: identity)
        )
        record[Field.config] = try JSONEncoder().encode(snapshot.config) as CKRecordValue
        record[Field.profileID] = profileID as CKRecordValue
        record[Field.updatedAt] = snapshot.updatedAt as CKRecordValue
        record.encryptedValues[Field.token] = snapshot.token as CKRecordValue
        return record
    }

    static func jellyfinSnapshot(from record: CKRecord) -> (snapshot: JellyfinServerSnapshot, profileID: String)? {
        guard let data = record[Field.config] as? Data,
              let config = try? JSONDecoder().decode(JellyfinServerConfig.self, from: data),
              let profileID = record[Field.profileID] as? String else {
            return nil
        }
        let snapshot = JellyfinServerSnapshot(
            config: config,
            token: record.encryptedValues[Field.token] as? String ?? "",
            updatedAt: record[Field.updatedAt] as? Int64 ?? 0
        )
        return (snapshot, profileID)
    }
}
