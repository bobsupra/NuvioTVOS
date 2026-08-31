import XCTest
@testable import NuvioTV

final class AuthReauthFlowTests: XCTestCase {

    func testAuthSessionExpiration() {
        let expiredSession = AuthSession(
            accessToken: "test_access",
            refreshToken: "test_refresh",
            userId: "user_123",
            email: "test@example.com",
            expiresAt: Date().timeIntervalSince1970 - 100 // 100s in past
        )
        XCTAssertTrue(expiredSession.isExpired)

        let validSession = AuthSession(
            accessToken: "test_access",
            refreshToken: "test_refresh",
            userId: "user_123",
            email: "test@example.com",
            expiresAt: Date().timeIntervalSince1970 + 3600 // 1 hr in future
        )
        XCTAssertFalse(validSession.isExpired)

        let nilExpirySession = AuthSession(
            accessToken: "test_access",
            refreshToken: "test_refresh",
            userId: "user_123",
            email: "test@example.com",
            expiresAt: nil
        )
        XCTAssertFalse(nilExpirySession.isExpired)
    }

    func testAuthErrorProperties() {
        let error400 = AuthError(message: "Invalid Refresh Token: Refresh Token Not Found", statusCode: 400)
        XCTAssertEqual(error400.statusCode, 400)
        XCTAssertEqual(error400.errorDescription, "Invalid Refresh Token: Refresh Token Not Found")

        let error401 = AuthError(message: "JWT expired", statusCode: 401)
        XCTAssertEqual(error401.statusCode, 401)

        let error403 = AuthError(message: "bad_jwt", statusCode: 403)
        XCTAssertEqual(error403.statusCode, 403)
    }

    func testReauthenticationMessage() {
        XCTAssertEqual(
            NuvioSyncManager.reauthenticationMessage,
            "Your Nuvio session expired. Sign in again to resume syncing."
        )
    }

    func testReauthLocalizationFallbacks() {
        XCTAssertFalse(L10n.string("reauth_title", fallback: "Reconnect Nuvio Account").isEmpty)
        XCTAssertFalse(L10n.string("reauth_subtitle", fallback: "Your session expired.").isEmpty)
        XCTAssertFalse(L10n.string("reauth_banner_title", fallback: "Account Sync Paused").isEmpty)
        XCTAssertFalse(L10n.string("reauth_banner_subtitle", fallback: "Your Nuvio session expired.").isEmpty)
        XCTAssertFalse(L10n.string("reauth_action_title", fallback: "Reconnect Account").isEmpty)
        XCTAssertFalse(L10n.string("reauth_action_subtitle", fallback: "Your session expired.").isEmpty)
        XCTAssertFalse(L10n.string("reauth_success", fallback: "Reconnected successfully! Resuming sync…").isEmpty)
    }
}
