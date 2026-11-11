import XCTest
@testable import NuvioTV

/// Sign-out runs `ProfileSettings.eraseAll`, which must not leave integration
/// logins in the Keychain: profile ids are reused by the next account, and the
/// Trakt fallback scopes would otherwise restore the previous user's session.
final class SignOutIntegrationLoginTests: XCTestCase {
    private var profileID = ""
    private var previousSettingsProfileID: String?
    private var previousSettingsProfileIsPrimary = false
    private var previousAniListStorage: AniListTokenStorage!

    override func setUp() {
        super.setUp()
        previousSettingsProfileID = ProfileSettings.activeProfileID
        previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousAniListStorage = AniListAccount.storage
        AniListAccount.storage = AniListMemoryTokenStorage()
        profileID = "signout-logins-\(UUID().uuidString)"
    }

    override func tearDown() {
        TraktKeychainStorage.shared.removeSession(for: profileID)
        MALKeychain.remove(for: profileID)
        AniListAccount.storage = previousAniListStorage
        if let previousSettingsProfileID {
            ProfileSettings.setActiveProfile(
                previousSettingsProfileID,
                isPrimary: previousSettingsProfileIsPrimary
            )
        } else {
            ProfileSettings.clearActiveProfile()
        }
        super.tearDown()
    }

    func testEraseAllRemovesTraktSession() {
        let session = TraktStoredSession(
            accessToken: "trakt-access",
            refreshToken: "trakt-refresh",
            username: "previous-user"
        )
        XCTAssertTrue(TraktKeychainStorage.shared.saveSession(session, for: profileID))
        XCTAssertNotNil(TraktKeychainStorage.shared.session(for: profileID))

        ProfileSettings.eraseAll(profileIds: [profileID])

        XCTAssertNil(TraktKeychainStorage.shared.session(for: profileID))
    }

    func testEraseAllRemovesAniListLogin() {
        let login = AniListAccount.Login(token: "anilist-token", viewerID: 1, viewerName: "previous-user", savedAt: Date())
        AniListAccount.storage.save(login, for: profileID)
        AniListAccount.storage.save(login, for: "default")

        ProfileSettings.eraseAll(profileIds: [profileID])

        XCTAssertNil(AniListAccount.storage.login(for: profileID))
        XCTAssertNil(AniListAccount.storage.login(for: "default"))
    }

    func testEraseAllRemovesMALLogin() {
        let login = MALAccount.Login(
            accessToken: "mal-access",
            refreshToken: "mal-refresh",
            expiresAt: Date().addingTimeInterval(3600),
            userName: "previous-user",
            clientID: "client"
        )
        MALKeychain.save(login, for: profileID)
        XCTAssertNotNil(MALKeychain.login(for: profileID))

        ProfileSettings.eraseAll(profileIds: [profileID])

        XCTAssertNil(MALKeychain.login(for: profileID))
    }
}
