import XCTest
@testable import AetherEngineSMB

final class SMBAuthTests: XCTestCase {
    func testAnonymousModeHasNoAccount() {
        let attempt = SMBAuth.attempt(for: .anonymous)
        XCTAssertNil(attempt.username)
        XCTAssertNil(attempt.password)
        XCTAssertNil(attempt.domain)
    }

    func testGuestModeUsesGuestUsernameWithNoPassword() {
        let attempt = SMBAuth.attempt(for: .guest)
        XCTAssertEqual(attempt.username, "guest")
        XCTAssertNil(attempt.password)
        XCTAssertNil(attempt.domain)
    }

    func testUserModeCarriesCredentials() {
        let attempt = SMBAuth.attempt(for: .user(name: "alice", password: "s3cret", domain: "WORKGROUP"))
        XCTAssertEqual(attempt.username, "alice")
        XCTAssertEqual(attempt.password, "s3cret")
        XCTAssertEqual(attempt.domain, "WORKGROUP")
    }

    /// An empty password/domain on an explicit account must map to `nil`, not
    /// an empty string — `SMBClient.login` treats a non-nil empty password as
    /// "authenticate with an empty password" rather than "no password".
    func testUserModeTreatsEmptyPasswordAndDomainAsNil() {
        let attempt = SMBAuth.attempt(for: .user(name: "alice", password: "", domain: ""))
        XCTAssertEqual(attempt.username, "alice")
        XCTAssertNil(attempt.password)
        XCTAssertNil(attempt.domain)
    }

    func testUserModeDomainDefaultsEmpty() {
        let attempt = SMBAuth.attempt(for: .user(name: "alice", password: "s3cret"))
        XCTAssertEqual(attempt.username, "alice")
        XCTAssertEqual(attempt.password, "s3cret")
        XCTAssertNil(attempt.domain)
    }

    func testAdminShareClassification() {
        XCTAssertTrue(SMBShareInfo.isAdminShare(name: "ADMIN$", isIPC: false))
        XCTAssertTrue(SMBShareInfo.isAdminShare(name: "C$", isIPC: false))
        XCTAssertTrue(SMBShareInfo.isAdminShare(name: "IPC$", isIPC: true))
        XCTAssertFalse(SMBShareInfo.isAdminShare(name: "Media", isIPC: false))
    }
}
