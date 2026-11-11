import XCTest
@testable import NuvioTV

/// A MAL token renewal finishes after a network round trip; by then another profile may be
/// active. The renewed login belongs to the profile that asked for it.
final class MALTokenRenewalProfileTests: XCTestCase {
    private var askingProfile = ""
    private var otherProfile = ""

    override func setUp() {
        super.setUp()
        askingProfile = "mal-renew-a-\(UUID().uuidString)"
        otherProfile = "mal-renew-b-\(UUID().uuidString)"
    }

    override func tearDown() {
        MALKeychain.remove(for: askingProfile)
        MALKeychain.remove(for: otherProfile)
        super.tearDown()
    }

    private func login(_ name: String, refresh: String) -> MALAccount.Login {
        MALAccount.Login(
            accessToken: "\(name)-access",
            refreshToken: refresh,
            expiresAt: Date(),
            userName: name,
            clientID: "client"
        )
    }

    private let renewed = MALAccount.Tokens(
        accessToken: "renewed-access",
        refreshToken: "renewed-refresh",
        expiresAt: Date().addingTimeInterval(3600)
    )

    func testRenewedLoginIsSavedToTheProfileThatAskedForIt() {
        let asking = login("a", refresh: "a-refresh")
        let other = login("b", refresh: "b-refresh")
        MALKeychain.save(asking, for: askingProfile)
        MALKeychain.save(other, for: otherProfile)

        let token = MALAccount.storeRenewed(renewed, replacing: asking, for: askingProfile)

        XCTAssertEqual(token, "renewed-access")
        XCTAssertEqual(MALKeychain.login(for: askingProfile)?.refreshToken, "renewed-refresh")
        XCTAssertEqual(MALKeychain.login(for: askingProfile)?.userName, "a")
        XCTAssertEqual(MALKeychain.login(for: otherProfile), other)
    }

    func testRenewalAfterLogOutSavesNothing() {
        let asking = login("a", refresh: "a-refresh")

        let token = MALAccount.storeRenewed(renewed, replacing: asking, for: askingProfile)

        XCTAssertNil(token)
        XCTAssertNil(MALKeychain.login(for: askingProfile))
    }

    func testANewerLoginIsNotOverwritten() {
        let asking = login("a", refresh: "a-refresh")
        let newer = login("a2", refresh: "a2-refresh")
        MALKeychain.save(newer, for: askingProfile)

        let token = MALAccount.storeRenewed(renewed, replacing: asking, for: askingProfile)

        XCTAssertEqual(token, "a2-access")
        XCTAssertEqual(MALKeychain.login(for: askingProfile), newer)
    }
}
