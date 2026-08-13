import CloudKit
import XCTest
@testable import NuvioTV

/// Record mapping for iCloud settings sync. `CKRecord` is a local object until
/// it is saved, so every one of these runs without a container or an iCloud
/// account — including the `encryptedValues` paths.
final class CloudSyncSchemaTests: XCTestCase {

    // MARK: - Record identity

    func testEveryIdentityRoundTripsThroughItsRecordName() {
        let identities: [CloudSyncSchema.Identity] = [
            .profileList,
            .profileSettings(profileID: "1"),
            .smbServer(serverID: "A1B2-C3"),
            .jellyfinServer(serverID: "server-9"),
            .addonList(profileID: "2"),
            .homeLayout(profileID: "guest")
        ]

        for identity in identities {
            let name = CloudSyncSchema.recordName(for: identity)
            XCTAssertEqual(CloudSyncSchema.identity(forRecordName: name), identity, name)
        }
    }

    func testIdentityPrefixesDoNotCollide() {
        // "smb-" vs "settings-" both start with "s"; a sloppy prefix match
        // would route a settings record into the SMB branch.
        XCTAssertEqual(
            CloudSyncSchema.identity(forRecordName: "settings-1"),
            .profileSettings(profileID: "1")
        )
        XCTAssertEqual(
            CloudSyncSchema.identity(forRecordName: "smb-1"),
            .smbServer(serverID: "1")
        )
    }

    func testUnknownOrEmptyRecordNamesAreRejected() {
        XCTAssertNil(CloudSyncSchema.identity(forRecordName: "nonsense"))
        XCTAssertNil(CloudSyncSchema.identity(forRecordName: ""))
        // A prefix with no identifier addresses no profile.
        XCTAssertNil(CloudSyncSchema.identity(forRecordName: "settings-"))
        XCTAssertNil(CloudSyncSchema.identity(forRecordName: "smb-"))
    }

    func testRecordIDsLandInTheSyncZone() {
        let recordID = CloudSyncSchema.recordID(for: .profileSettings(profileID: "1"))
        XCTAssertEqual(recordID.zoneID.zoneName, CloudSyncSchema.zoneName)
    }

    // MARK: - Settings record

    func testSettingsRecordRoundTripsValuesStampsAndSecrets() throws {
        var snapshot = SettingsSnapshot(deviceID: "device-A")
        snapshot.values[SettingsKey.theme] = .string("midnight")
        snapshot.values[SettingsKey.subtitleSize] = .int(140)
        snapshot.stamps[SettingsKey.theme] = 1_700_000_000_000
        snapshot.stamps[SettingsKey.debridApiKey] = 1_700_000_000_001
        snapshot.secrets[SettingsKey.debridApiKey] = .string("super-secret")

        let record = try CloudSyncSchema.makeSettingsRecord(snapshot, profileID: "1", base: nil)
        let decoded = try XCTUnwrap(CloudSyncSchema.settingsSnapshot(from: record))

        XCTAssertEqual(decoded.values[SettingsKey.theme], .string("midnight"))
        XCTAssertEqual(decoded.values[SettingsKey.subtitleSize], .int(140))
        XCTAssertEqual(decoded.stamps[SettingsKey.theme], 1_700_000_000_000)
        XCTAssertEqual(decoded.secrets[SettingsKey.debridApiKey], .string("super-secret"))
        XCTAssertEqual(decoded.deviceID, "device-A")
    }

    /// The whole point of the plain/encrypted split: a credential must never
    /// appear in a field CloudKit stores unencrypted.
    func testSecretsAreNotWrittenToAPlainField() throws {
        var snapshot = SettingsSnapshot(deviceID: "A")
        snapshot.secrets[SettingsKey.debridApiKey] = .string("super-secret")
        snapshot.stamps[SettingsKey.debridApiKey] = 1

        let record = try CloudSyncSchema.makeSettingsRecord(snapshot, profileID: "1", base: nil)

        XCTAssertNil(record[CloudSyncSchema.Field.secrets])
        XCTAssertNotNil(record.encryptedValues[CloudSyncSchema.Field.secrets])

        // And nothing anywhere in the plain payload contains the value.
        let payload = try XCTUnwrap(record[CloudSyncSchema.Field.payload] as? Data)
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(text.contains("super-secret"))
    }

    func testEmptySettingsRecordDecodesAsAbsent() {
        let record = CKRecord(
            recordType: CloudSyncSchema.RecordType.profileSettings,
            recordID: CloudSyncSchema.recordID(for: .profileSettings(profileID: "1"))
        )
        // Applying an empty snapshot over live settings would wipe them.
        XCTAssertNil(CloudSyncSchema.settingsSnapshot(from: record))
    }

    /// A profile whose only synced setting is an API key has an empty `values`
    /// and empty `stamps` from the plain side — it must still decode.
    func testSecretOnlySettingsRecordIsNotTreatedAsEmpty() throws {
        var snapshot = SettingsSnapshot(deviceID: "A")
        snapshot.secrets[SettingsKey.tmdbApiKey] = .string("key")

        let record = try CloudSyncSchema.makeSettingsRecord(snapshot, profileID: "1", base: nil)
        let decoded = try XCTUnwrap(CloudSyncSchema.settingsSnapshot(from: record))

        XCTAssertEqual(decoded.secrets[SettingsKey.tmdbApiKey], .string("key"))
    }

    func testSettingsRecordReusesTheBaseRecordIdentity() throws {
        let base = CKRecord(
            recordType: CloudSyncSchema.RecordType.profileSettings,
            recordID: CloudSyncSchema.recordID(for: .profileSettings(profileID: "1"))
        )
        var snapshot = SettingsSnapshot(deviceID: "A")
        snapshot.stamps[SettingsKey.theme] = 1

        let record = try CloudSyncSchema.makeSettingsRecord(snapshot, profileID: "1", base: base)

        // Replaying the base is what keeps the change tag current.
        XCTAssertTrue(record === base)
    }

    // MARK: - Server records

    func testSMBRecordCarriesConfigAndPasswordSeparately() throws {
        let config = SMBServerConfig(
            id: "server-1",
            displayName: "Basement",
            host: "10.0.1.5",
            port: 445,
            authKind: .credentials,
            username: "raul",
            selectedShares: ["Media"]
        )
        let snapshot = SMBServerSnapshot(config: config, password: "hunter2", updatedAt: 42)

        let record = try CloudSyncSchema.makeSMBRecord(snapshot, profileID: "1", base: nil)
        let (decoded, profileID) = try XCTUnwrap(CloudSyncSchema.smbSnapshot(from: record))

        XCTAssertEqual(profileID, "1")
        XCTAssertEqual(decoded.config, config)
        XCTAssertEqual(decoded.password, "hunter2")
        XCTAssertEqual(decoded.updatedAt, 42)

        XCTAssertNil(record[CloudSyncSchema.Field.password])
        let configData = try XCTUnwrap(record[CloudSyncSchema.Field.config] as? Data)
        XCTAssertFalse(String(decoding: configData, as: UTF8.self).contains("hunter2"))
    }

    func testSMBRecordUsesTheServerIDAsItsRecordName() throws {
        let config = SMBServerConfig(id: "server-1", displayName: "Basement", host: "10.0.1.5")
        let snapshot = SMBServerSnapshot(config: config, password: "", updatedAt: 0)

        let record = try CloudSyncSchema.makeSMBRecord(snapshot, profileID: "1", base: nil)

        // Deterministic naming is what makes a deletion elsewhere addressable.
        XCTAssertEqual(record.recordID.recordName, "smb-server-1")
    }

    func testJellyfinRecordCarriesConfigAndTokenSeparately() throws {
        let config = JellyfinServerConfig(
            id: "jf-1",
            displayName: "Living Room",
            baseURLString: "http://10.0.1.9:8096",
            username: "raul"
        )
        let snapshot = JellyfinServerSnapshot(config: config, token: "tok-abc", updatedAt: 7)

        let record = try CloudSyncSchema.makeJellyfinRecord(snapshot, profileID: "2", base: nil)
        let (decoded, profileID) = try XCTUnwrap(CloudSyncSchema.jellyfinSnapshot(from: record))

        XCTAssertEqual(profileID, "2")
        XCTAssertEqual(decoded.config, config)
        XCTAssertEqual(decoded.token, "tok-abc")
        XCTAssertNil(record[CloudSyncSchema.Field.token])
    }

    func testServerRecordMissingItsProfileIsRejected() {
        let record = CKRecord(
            recordType: CloudSyncSchema.RecordType.smbServer,
            recordID: CloudSyncSchema.recordID(for: .smbServer(serverID: "x"))
        )
        // Without a profile there is no suite to merge it into.
        XCTAssertNil(CloudSyncSchema.smbSnapshot(from: record))
    }

    // MARK: - Keyed records

    func testKeyedRecordRoundTrips() throws {
        var snapshot = KeyedSettingsSnapshot(updatedAt: 99)
        snapshot.values[SettingsKey.homeCatalogOrder] = .string("[\"a\",\"b\"]")
        snapshot.values[SettingsKey.homeCollectionDisabled] = .stringArray(["c1"])

        let record = try CloudSyncSchema.makeKeyedRecord(
            snapshot,
            identity: .homeLayout(profileID: "1"),
            base: nil
        )
        let decoded = try XCTUnwrap(CloudSyncSchema.keyedSnapshot(from: record))

        XCTAssertEqual(decoded.values[SettingsKey.homeCatalogOrder], .string("[\"a\",\"b\"]"))
        XCTAssertEqual(decoded.values[SettingsKey.homeCollectionDisabled], .stringArray(["c1"]))
        XCTAssertEqual(decoded.updatedAt, 99)
    }

    func testKeyedRecordUsesTheRightRecordType() throws {
        let snapshot = KeyedSettingsSnapshot(updatedAt: 1)

        let addons = try CloudSyncSchema.makeKeyedRecord(
            snapshot, identity: .addonList(profileID: "1"), base: nil
        )
        let home = try CloudSyncSchema.makeKeyedRecord(
            snapshot, identity: .homeLayout(profileID: "1"), base: nil
        )

        XCTAssertEqual(addons.recordType, CloudSyncSchema.RecordType.addonList)
        XCTAssertEqual(home.recordType, CloudSyncSchema.RecordType.homeLayout)
    }

    // MARK: - Profile list

    func testProfileListRoundTrips() throws {
        let snapshot = ProfileListSnapshot(
            profiles: [
                ProfileSnapshot(id: "1", name: "Raul", avatarId: "av1", isAdmin: true),
                ProfileSnapshot(id: "2", name: "Guest", avatarId: "", isAdmin: false)
            ],
            updatedAt: 5
        )

        let record = try CloudSyncSchema.makeProfileListRecord(snapshot, base: nil)
        let decoded = try XCTUnwrap(CloudSyncSchema.profileListSnapshot(from: record))

        XCTAssertEqual(decoded.profiles.count, 2)
        XCTAssertEqual(decoded.profiles.first?.name, "Raul")
        XCTAssertEqual(decoded.updatedAt, 5)
    }

    func testEmptyProfileListDecodesAsAbsent() throws {
        let record = try CloudSyncSchema.makeProfileListRecord(ProfileListSnapshot(), base: nil)

        // Replacing the local profiles with an empty list would strand the user
        // on a device with no profile to select.
        XCTAssertNil(CloudSyncSchema.profileListSnapshot(from: record))
    }
}
