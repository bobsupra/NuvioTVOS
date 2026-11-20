import XCTest
@testable import NuvioTV

final class ProfileSettingsStoreIdentityTests: XCTestCase {
    func testSameProfileReturnsSameStore() {
        let id = "store-identity-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(id)") }
        XCTAssertTrue(ProfileSettings.store(for: id) === ProfileSettings.store(for: id))
    }

    func testDifferentProfilesKeepSeparateValues() {
        let a = "store-identity-a-\(UUID().uuidString)", b = "store-identity-b-\(UUID().uuidString)"
        defer {
            for id in [a, b] { UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(id)") }
        }
        ProfileSettings.store(for: a).set("A", forKey: "storeIdentityProbe")
        XCTAssertFalse(ProfileSettings.store(for: a) === ProfileSettings.store(for: b))
        XCTAssertNil(ProfileSettings.store(for: b).string(forKey: "storeIdentityProbe"))
        XCTAssertEqual(ProfileSettings.store(for: a).string(forKey: "storeIdentityProbe"), "A")
    }

    func testNoProfileIsStandard() {
        XCTAssertTrue(ProfileSettings.store(for: nil) === UserDefaults.standard)
        XCTAssertTrue(ProfileSettings.store(for: "") === UserDefaults.standard)
    }
}
