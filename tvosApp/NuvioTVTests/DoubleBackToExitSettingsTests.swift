import XCTest
@testable import NuvioTV

final class DoubleBackToExitSettingsTests: XCTestCase {
    func testDoubleBackToExitStaysOnThisAppleTV() {
        XCTAssertEqual(SettingsKey.doubleBackToExit, "nuvio.tv.settings.layout.doubleBackToExit")
        // Like the Nuvio Icon Sidebar: kept out of account and iCloud sync.
        XCTAssertTrue(SettingsKey.deviceLocal.contains(SettingsKey.doubleBackToExit))
        XCTAssertFalse(SettingsKey.all.contains(SettingsKey.doubleBackToExit))
    }
}
