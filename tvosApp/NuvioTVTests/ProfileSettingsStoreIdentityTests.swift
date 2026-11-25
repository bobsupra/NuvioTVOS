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

    func testActivatingExistingSecondaryProfilePreservesWeTrakrSignInMarker() {
        let id = "wetrakr-secondary-preservation-\(UUID().uuidString)"
        let store = ProfileSettings.store(for: id)
        let tokenStorage = WeTrakrMemoryTokenStorage()
        let previousID = ProfileSettings.activeProfileID
        let previousWasPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        defer {
            WeTrakrAuthStore.clearAuth(profileScope: id, store: store, tokenStorage: tokenStorage)
            if let previousID {
                ProfileSettings.setActiveProfile(previousID, isPrimary: previousWasPrimary)
            } else {
                ProfileSettings.clearActiveProfile()
            }
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(id)")
        }

        store.set("existing-wetrakr-client", forKey: SettingsKey.wetrakrClientID)
        WeTrakrAuthStore.saveToken(
            "existing-wetrakr-token",
            clientID: "existing-wetrakr-client",
            profileScope: id,
            store: store,
            tokenStorage: tokenStorage
        )
        ProfileSettings.setActiveProfile(id, isPrimary: false)

        XCTAssertTrue(store.bool(forKey: "nuvio.tv.wetrakr.auth.hasAccessToken"))
        XCTAssertEqual(store.string(forKey: SettingsKey.wetrakrClientID), "existing-wetrakr-client")
    }
}
