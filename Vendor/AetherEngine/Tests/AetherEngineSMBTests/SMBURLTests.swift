import XCTest
@testable import AetherEngineSMB

final class SMBURLTests: XCTestCase {
    func testParsesUserPassHostShareAndPath() throws {
        let u = try SMBURL.parse("smb://alice:s3cret@nas.local/media/Movies/film.mkv")
        XCTAssertEqual(u.server.absoluteString, "smb://nas.local")
        XCTAssertEqual(u.user, "alice")
        XCTAssertEqual(u.password, "s3cret")
        XCTAssertEqual(u.share, "media")
        XCTAssertEqual(u.path, "Movies/film.mkv")
    }

    func testEmptyUserWhenNoCredentials() throws {
        // An omitted username parses to empty, SMBConnection.connect maps that
        // to the guest-then-anonymous fallback; the parser must not fabricate
        // "guest" or that fallback would never fire.
        let u = try SMBURL.parse("smb://nas.local/public/clip.mp4")
        XCTAssertEqual(u.user, "")
        XCTAssertEqual(u.password, "")
        XCTAssertEqual(u.share, "public")
        XCTAssertEqual(u.path, "clip.mp4")
    }

    func testRejectsNonSmbScheme() {
        XCTAssertThrowsError(try SMBURL.parse("http://nas.local/x/y"))
    }

    func testRejectsMissingFilePath() {
        XCTAssertThrowsError(try SMBURL.parse("smb://nas.local/onlyshare"))
    }
}
