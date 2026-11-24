import XCTest
@testable import NuvioTV

@MainActor
final class ICloudSettingsSyncTests: XCTestCase {
    private var originalEnabled = false

    override func setUp() async throws {
        try await super.setUp()
        originalEnabled = UserDefaults.standard.bool(forKey: SettingsKey.iCloudSyncEnabled)
    }

    override func tearDown() async throws {
        let manager = ICloudSettingsSyncManager.shared
        manager.stopForTesting()
        UserDefaults.standard.set(originalEnabled, forKey: SettingsKey.iCloudSyncEnabled)
        try await super.tearDown()
    }

    /// The Settings switch is bound with @AppStorage, so the key is already true when
    /// `.onChange` sets `isEnabled`. Sync must still start without a relaunch.
    func testTurningOnAfterTheSwitchStoredTheKeyStartsSync() {
        let manager = ICloudSettingsSyncManager.shared
        manager.isEnabled = false
        manager.stopForTesting()
        XCTAssertFalse(manager.isStarted)

        UserDefaults.standard.set(true, forKey: SettingsKey.iCloudSyncEnabled)
        manager.isEnabled = true

        XCTAssertTrue(manager.isStarted)
    }

    func testTurningOffDoesNotStartSync() {
        let manager = ICloudSettingsSyncManager.shared
        manager.isEnabled = false
        manager.stopForTesting()

        manager.isEnabled = false

        XCTAssertFalse(manager.isStarted)
    }

    func testPayloadMatchingICloudIsNotPushed() {
        let key = "nuvio.icloud.profile.settings.1"
        let payload: [String: Any] = ["theme": "Ocean", "rows": NSNumber(value: 4)]

        let changed = ICloudSettingsSyncManager.payloadsToPush(
            local: [key: payload],
            cloud: [key: payload as NSDictionary, "nuvio.icloud.lastModified": 1_700_000_000.0]
        )

        XCTAssertTrue(changed.isEmpty)
    }

    func testChangedValueIsPushed() {
        let key = "nuvio.icloud.global.settings"
        let changed = ICloudSettingsSyncManager.payloadsToPush(
            local: [key: ["theme": "Ocean"]],
            cloud: [key: ["theme": "Crimson"] as NSDictionary]
        )

        XCTAssertEqual(Set(changed.keys), [key])
        XCTAssertEqual(changed[key]?["theme"] as? String, "Ocean")
    }

    func testPayloadMissingFromICloudIsPushed() {
        let key = "nuvio.icloud.profile.settings.2"
        let changed = ICloudSettingsSyncManager.payloadsToPush(
            local: [key: ["theme": "Ocean"]],
            cloud: [:]
        )

        XCTAssertEqual(Set(changed.keys), [key])
    }

    func testEmptyPayloadIsNotPushed() {
        let changed = ICloudSettingsSyncManager.payloadsToPush(
            local: ["nuvio.icloud.profile.settings.3": [:]],
            cloud: [:]
        )

        XCTAssertTrue(changed.isEmpty)
    }

    /// iCloud returns a stored Bool as an NSNumber; it must compare equal to the local value.
    func testBoolStoredInICloudMatchesLocalBool() {
        let key = "nuvio.icloud.profile.settings.4"
        let changed = ICloudSettingsSyncManager.payloadsToPush(
            local: [key: ["amoled": true]],
            cloud: [key: ["amoled": NSNumber(value: 1)] as NSDictionary]
        )

        XCTAssertTrue(changed.isEmpty)
    }
}
