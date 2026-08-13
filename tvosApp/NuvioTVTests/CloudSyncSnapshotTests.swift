import XCTest
@testable import NuvioTV

/// Phase 1 of iCloud settings sync — the transport-agnostic snapshot layer.
/// These run without an iCloud account or a CloudKit container, which is the
/// point: merge correctness gets proven here, not on two Apple TVs.
final class CloudSyncSnapshotTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "nuvio.tests.cloudsync.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - SettingValue

    /// The reason this type exists instead of reusing the account sync's codec:
    /// `UserDefaults` bridges bools and numbers alike to `NSNumber`, so a naive
    /// `as? Bool` turns an integer 1 into `true`.
    func testIntegerOneDoesNotRoundTripAsBool() {
        defaults.set(1, forKey: SettingsKey.networkCache)

        XCTAssertEqual(
            SettingValue.read(from: defaults, key: SettingsKey.networkCache),
            .int(1)
        )
    }

    func testBoolRoundTripsAsBool() {
        defaults.set(true, forKey: SettingsKey.autoPlayNext)

        XCTAssertEqual(
            SettingValue.read(from: defaults, key: SettingsKey.autoPlayNext),
            .bool(true)
        )
    }

    /// `SMBServerStore` and `JellyfinServerStore` persist as JSON `Data`. The
    /// account sync's codec drops it, which is why servers have never synced.
    func testDataRoundTrips() throws {
        let blob = Data("[{\"id\":\"server-1\"}]".utf8)
        defaults.set(blob, forKey: SettingsKey.smbServers)

        let value = SettingValue.read(from: defaults, key: SettingsKey.smbServers)
        XCTAssertEqual(value, .data(blob))

        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(SettingValue.self, from: encoded)
        XCTAssertEqual(decoded, .data(blob))
    }

    func testEveryCaseSurvivesJSONRoundTrip() throws {
        let cases: [SettingValue] = [
            .string("hello"),
            .bool(false),
            .int(-42),
            .double(1.5),
            .data(Data([0x01, 0x02])),
            .stringArray(["a", "b"])
        ]

        for value in cases {
            let encoded = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(SettingValue.self, from: encoded)
            XCTAssertEqual(decoded, value)
        }
    }

    func testWriteThenReadPreservesType() {
        SettingValue.double(2.5).write(to: defaults, key: SettingsKey.trailerDelay)

        XCTAssertEqual(
            SettingValue.read(from: defaults, key: SettingsKey.trailerDelay),
            .double(2.5)
        )
    }

    func testMissingKeyReadsAsNil() {
        XCTAssertNil(SettingValue.read(from: defaults, key: SettingsKey.theme))
    }

    // MARK: - Policy

    func testDedicatedRecordKeysStayOutOfTheSettingsPayload() {
        // Otherwise the server list would have two sources of truth: the
        // per-server records and a whole-blob copy that overwrites them.
        for key in CloudSyncPolicy.ownedByDedicatedRecord {
            XCTAssertFalse(CloudSyncPolicy.plainKeys.contains(key), key)
            XCTAssertFalse(CloudSyncPolicy.secretKeys.contains(key), key)
        }
    }

    func testDeviceLocalKeysNeverSync() {
        for key in CloudSyncPolicy.deviceLocal {
            XCTAssertFalse(CloudSyncPolicy.plainKeys.contains(key), key)
            XCTAssertFalse(CloudSyncPolicy.secretKeys.contains(key), key)
            XCTAssertFalse(CloudSyncPolicy.stampedKeys.contains(key), key)
        }
    }

    func testSecretsAreSeparatedFromPlainKeys() {
        XCTAssertFalse(CloudSyncPolicy.plainKeys.contains(SettingsKey.debridApiKey))
        XCTAssertTrue(CloudSyncPolicy.secretKeys.contains(SettingsKey.debridApiKey))
        XCTAssertTrue(CloudSyncPolicy.secretKeys.contains(SettingsKey.aiSubtitlesGeminiAPIKey))
    }

    func testScanIndexesAreExcluded() {
        // Large derived blobs — each TV rescans what it can actually reach.
        XCTAssertTrue(CloudSyncPolicy.deviceLocal.contains(SettingsKey.smbLibraryIndex))
        XCTAssertTrue(CloudSyncPolicy.deviceLocal.contains(SettingsKey.jellyfinLibraryIndex))
    }

    // MARK: - Export / apply

    func testExportSeparatesSecretsFromPlainValues() {
        defaults.set("midnight", forKey: SettingsKey.theme)
        defaults.set("secret-key", forKey: SettingsKey.debridApiKey)

        let snapshot = SettingsSnapshot.export(from: defaults, stamps: [:], deviceID: "A")

        XCTAssertEqual(snapshot.values[SettingsKey.theme], .string("midnight"))
        XCTAssertNil(snapshot.values[SettingsKey.debridApiKey])
        XCTAssertEqual(snapshot.secrets[SettingsKey.debridApiKey], .string("secret-key"))
    }

    func testApplyOnlyWritesStampedKeys() {
        // An unstamped key was never touched on the sending device, so it must
        // not overwrite whatever this device has.
        defaults.set("local-theme", forKey: SettingsKey.theme)

        var snapshot = SettingsSnapshot(deviceID: "B")
        snapshot.values[SettingsKey.theme] = .string("remote-theme")
        snapshot.apply(to: defaults)

        XCTAssertEqual(defaults.string(forKey: SettingsKey.theme), "local-theme")

        snapshot.stamps[SettingsKey.theme] = 100
        snapshot.apply(to: defaults)

        XCTAssertEqual(defaults.string(forKey: SettingsKey.theme), "remote-theme")
    }

    func testApplyRemovesTombstonedKeys() {
        defaults.set("stale-key", forKey: SettingsKey.tmdbApiKey)

        var snapshot = SettingsSnapshot(deviceID: "B")
        snapshot.stamps[SettingsKey.tmdbApiKey] = 100  // stamped, no value

        snapshot.apply(to: defaults)

        XCTAssertNil(defaults.string(forKey: SettingsKey.tmdbApiKey))
    }

    // MARK: - Merge

    func testNewerRemoteValueWins() {
        var local = SettingsSnapshot(deviceID: "A")
        local.values[SettingsKey.theme] = .string("local")
        local.stamps[SettingsKey.theme] = 100

        var remote = SettingsSnapshot(deviceID: "B")
        remote.values[SettingsKey.theme] = .string("remote")
        remote.stamps[SettingsKey.theme] = 200

        let merged = SettingsSnapshot.merge(local: local, remote: remote)

        XCTAssertEqual(merged.values[SettingsKey.theme], .string("remote"))
        XCTAssertEqual(merged.stamps[SettingsKey.theme], 200)
    }

    func testOlderRemoteValueLoses() {
        var local = SettingsSnapshot(deviceID: "A")
        local.values[SettingsKey.theme] = .string("local")
        local.stamps[SettingsKey.theme] = 300

        var remote = SettingsSnapshot(deviceID: "B")
        remote.values[SettingsKey.theme] = .string("remote")
        remote.stamps[SettingsKey.theme] = 200

        let merged = SettingsSnapshot.merge(local: local, remote: remote)

        XCTAssertEqual(merged.values[SettingsKey.theme], .string("local"))
        XCTAssertEqual(merged.stamps[SettingsKey.theme], 300)
    }

    /// The whole point of per-key stamps: edits to different settings on two
    /// Apple TVs must both survive rather than one blob overwriting the other.
    func testConcurrentEditsToDifferentKeysBothSurvive() {
        var local = SettingsSnapshot(deviceID: "A")
        local.values[SettingsKey.theme] = .string("midnight")
        local.stamps[SettingsKey.theme] = 500
        local.values[SettingsKey.subtitleSize] = .int(100)
        local.stamps[SettingsKey.subtitleSize] = 100

        var remote = SettingsSnapshot(deviceID: "B")
        remote.values[SettingsKey.theme] = .string("daylight")
        remote.stamps[SettingsKey.theme] = 200
        remote.values[SettingsKey.subtitleSize] = .int(180)
        remote.stamps[SettingsKey.subtitleSize] = 900

        let merged = SettingsSnapshot.merge(local: local, remote: remote)

        XCTAssertEqual(merged.values[SettingsKey.theme], .string("midnight"))
        XCTAssertEqual(merged.values[SettingsKey.subtitleSize], .int(180))
    }

    func testRemoteTombstonePropagates() {
        var local = SettingsSnapshot(deviceID: "A")
        local.secrets[SettingsKey.tmdbApiKey] = .string("still-here")
        local.stamps[SettingsKey.tmdbApiKey] = 100

        // Cleared on the other TV: stamped later, carrying no value.
        var remote = SettingsSnapshot(deviceID: "B")
        remote.stamps[SettingsKey.tmdbApiKey] = 200

        let merged = SettingsSnapshot.merge(local: local, remote: remote)

        XCTAssertNil(merged.secrets[SettingsKey.tmdbApiKey])
        XCTAssertEqual(merged.stamps[SettingsKey.tmdbApiKey], 200)
    }

    /// Equal stamps must resolve the same way on both devices, or each keeps
    /// preferring its own value and they push at each other forever.
    func testEqualStampsResolveDeterministicallyOnBothSides() {
        var a = SettingsSnapshot(deviceID: "device-A")
        a.values[SettingsKey.theme] = .string("from-A")
        a.stamps[SettingsKey.theme] = 100

        var b = SettingsSnapshot(deviceID: "device-B")
        b.values[SettingsKey.theme] = .string("from-B")
        b.stamps[SettingsKey.theme] = 100

        let mergedOnA = SettingsSnapshot.merge(local: a, remote: b)
        let mergedOnB = SettingsSnapshot.merge(local: b, remote: a)

        XCTAssertEqual(mergedOnA.values[SettingsKey.theme], .string("from-B"))
        XCTAssertEqual(
            mergedOnA.values[SettingsKey.theme],
            mergedOnB.values[SettingsKey.theme],
            "both devices must converge on the same winner"
        )
    }

    func testKeysPresentOnlyRemotelyAreAdopted() {
        let local = SettingsSnapshot(deviceID: "A")

        var remote = SettingsSnapshot(deviceID: "B")
        remote.values[SettingsKey.posterLabels] = .bool(true)
        remote.stamps[SettingsKey.posterLabels] = 50

        let merged = SettingsSnapshot.merge(local: local, remote: remote)

        XCTAssertEqual(merged.values[SettingsKey.posterLabels], .bool(true))
    }

    // MARK: - KeyedSettingsSnapshot

    func testHomeLayoutMergesWholeRecord() {
        // Order and hidden-set only make sense together, so this is
        // deliberately not per-key.
        var local = KeyedSettingsSnapshot(updatedAt: 100)
        local.values[SettingsKey.homeCatalogOrder] = .string("[\"a\",\"b\"]")

        var remote = KeyedSettingsSnapshot(updatedAt: 200)
        remote.values[SettingsKey.homeCatalogOrder] = .string("[\"b\",\"a\"]")

        let merged = KeyedSettingsSnapshot.merge(local: local, remote: remote)

        XCTAssertEqual(merged.values[SettingsKey.homeCatalogOrder], .string("[\"b\",\"a\"]"))
        XCTAssertEqual(merged.updatedAt, 200)
    }

    func testHomeLayoutExportApplyRoundTrip() {
        defaults.set("[\"row-1\"]", forKey: SettingsKey.homeCatalogOrder)

        let snapshot = KeyedSettingsSnapshot.export(
            keys: CloudSyncPolicy.homeLayoutKeys,
            from: defaults,
            updatedAt: 10
        )

        let target = UserDefaults(suiteName: "\(suiteName!).target")!
        defer { UserDefaults.standard.removePersistentDomain(forName: "\(suiteName!).target") }

        snapshot.apply(keys: CloudSyncPolicy.homeLayoutKeys, to: target)

        XCTAssertEqual(target.string(forKey: SettingsKey.homeCatalogOrder), "[\"row-1\"]")
    }
}
