import XCTest
@testable import NuvioTV

/// A login waits for AniList or MAL to answer. These cover what the viewer can do meanwhile:
/// log out (or sign out of Nuvio), start another login, or switch profiles.
final class AccountLoginGenerationsTests: XCTestCase {
    private var savedAniList: AniListTokenStorage!
    private var savedMAL: MALLoginStorage!
    private var profile = ""
    private var otherProfile = ""

    override func setUp() {
        super.setUp()
        savedAniList = AniListAccount.storage
        savedMAL = MALKeychain.storage
        AniListAccount.storage = AniListMemoryTokenStorage()
        MALKeychain.storage = MALMemoryLoginStorage()
        profile = "login-a-\(UUID().uuidString)"
        otherProfile = "login-b-\(UUID().uuidString)"
    }

    override func tearDown() {
        AniListAccount.storage = savedAniList
        MALKeychain.storage = savedMAL
        super.tearDown()
    }

    private func aniList(_ name: String) -> AniListAccount.Login {
        AniListAccount.Login(token: "\(name)-token", viewerID: 1, viewerName: name, savedAt: Date())
    }

    private func mal(_ name: String) -> MALAccount.Login {
        MALAccount.Login(accessToken: "\(name)-access", refreshToken: "\(name)-refresh",
                         expiresAt: Date().addingTimeInterval(3600), userName: name, clientID: "client")
    }

    // MARK: AniList

    func testAniListLoginAnsweredAfterLogoutSavesNothing() {
        let generation = AniListAccount.beginLogin(for: profile)
        AniListAccount.removeLogin(for: profile)   // logOut(), or signing out of Nuvio
        XCTAssertFalse(AniListAccount.save(aniList("late"), ifCurrent: generation, for: profile))
        XCTAssertNil(AniListAccount.storage.login(for: profile))
    }

    func testAniListOnlyTheNewestOfTwoLoginsSaves() {
        let first = AniListAccount.beginLogin(for: profile)
        let second = AniListAccount.beginLogin(for: profile)
        XCTAssertTrue(AniListAccount.save(aniList("second"), ifCurrent: second, for: profile))
        XCTAssertFalse(AniListAccount.save(aniList("first"), ifCurrent: first, for: profile))
        XCTAssertEqual(AniListAccount.storage.login(for: profile)?.viewerName, "second")

        // The older one answering first can't save either.
        let older = AniListAccount.beginLogin(for: otherProfile)
        let newer = AniListAccount.beginLogin(for: otherProfile)
        XCTAssertFalse(AniListAccount.save(aniList("older"), ifCurrent: older, for: otherProfile))
        XCTAssertTrue(AniListAccount.save(aniList("newer"), ifCurrent: newer, for: otherProfile))
        XCTAssertEqual(AniListAccount.storage.login(for: otherProfile)?.viewerName, "newer")
    }

    func testAniListLoginStillSavesToItsProfileAfterAProfileSwitch() {
        let generation = AniListAccount.beginLogin(for: profile)
        // Meanwhile the other profile is used, logs in and out.
        let other = AniListAccount.beginLogin(for: otherProfile)
        AniListAccount.save(aniList("other"), ifCurrent: other, for: otherProfile)
        AniListAccount.removeLogin(for: otherProfile)
        XCTAssertTrue(AniListAccount.save(aniList("mine"), ifCurrent: generation, for: profile))
        XCTAssertEqual(AniListAccount.storage.login(for: profile)?.viewerName, "mine")
        XCTAssertNil(AniListAccount.storage.login(for: otherProfile))
    }

    // MARK: MAL

    func testMALLoginAnsweredAfterLogoutSavesNothing() {
        let generation = MALKeychain.beginLogin(for: profile)
        MALKeychain.remove(for: profile)
        XCTAssertFalse(MALKeychain.save(mal("late"), ifCurrent: generation, for: profile))
        XCTAssertNil(MALKeychain.login(for: profile))
    }

    func testMALOnlyTheNewestOfTwoLoginsSaves() {
        let first = MALKeychain.beginLogin(for: profile)
        let second = MALKeychain.beginLogin(for: profile)
        XCTAssertFalse(MALKeychain.save(mal("first"), ifCurrent: first, for: profile))
        XCTAssertTrue(MALKeychain.save(mal("second"), ifCurrent: second, for: profile))
        XCTAssertFalse(MALKeychain.save(mal("first"), ifCurrent: first, for: profile))
        XCTAssertEqual(MALKeychain.login(for: profile)?.userName, "second")
    }

    func testMALLoginStillSavesToItsProfileAfterAProfileSwitch() {
        let generation = MALKeychain.beginLogin(for: profile)
        MALKeychain.remove(for: otherProfile)
        XCTAssertTrue(MALKeychain.save(mal("mine"), ifCurrent: generation, for: profile))
        XCTAssertEqual(MALKeychain.login(for: profile)?.userName, "mine")
    }

    func testARenewalAfterLogoutDoesNotRestoreTheLogin() {
        let generation = MALKeychain.beginLogin(for: profile)
        let login = mal("viewer")
        XCTAssertTrue(MALKeychain.save(login, ifCurrent: generation, for: profile))
        MALKeychain.remove(for: profile)
        let renewed = MALAccount.Tokens(accessToken: "new", refreshToken: "new-refresh", expiresAt: Date().addingTimeInterval(3600))
        XCTAssertNil(MALAccount.storeRenewed(renewed, replacing: login, for: profile))
        XCTAssertNil(MALKeychain.login(for: profile))
    }

    // MARK: Profile deletion

    /// A ProfileManager on a temporary folder holding `profile` and `otherProfile`.
    private func profileManager() throws -> (ProfileManager, cleanUp: () -> Void) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("logins-\(UUID().uuidString)")
        let activeKey = "nuvio.active_profile_id"
        let previousActive = UserDefaults.standard.string(forKey: activeKey)
        // Written first, so the manager doesn't migrate any profiles stored in
        // UserDefaults: only these two exist, and nothing else is touched.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let profiles = [Profile(id: profile, name: "A"), Profile(id: otherProfile, name: "B")]
        try JSONEncoder().encode(profiles.map(StoredProfile.init(from:)))
            .write(to: directory.appendingPathComponent("nuvio-profiles.json"))
        let manager = try ProfileManager(baseDir: directory.path)
        XCTAssertEqual(try manager.getProfiles().map(\.id), [profile, otherProfile])
        return (manager, {
            try? FileManager.default.removeItem(at: directory)
            UserDefaults.standard.set(previousActive, forKey: activeKey)
        })
    }

    private func logInOtherProfile() {
        AniListAccount.save(aniList("other"), ifCurrent: AniListAccount.beginLogin(for: otherProfile), for: otherProfile)
        MALKeychain.save(mal("other"), ifCurrent: MALKeychain.beginLogin(for: otherProfile), for: otherProfile)
    }

    private func assertOtherProfileStillLoggedIn(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(AniListAccount.storage.login(for: otherProfile)?.viewerName, "other", file: file, line: line)
        XCTAssertEqual(MALKeychain.login(for: otherProfile)?.userName, "other", file: file, line: line)
    }

    func testAProfileRemovedBySyncStopsItsPendingLoginsAndDropsItsLogins() throws {
        let (manager, cleanUp) = try profileManager()
        defer { cleanUp() }
        logInOtherProfile()
        AniListAccount.save(aniList("old"), ifCurrent: AniListAccount.beginLogin(for: profile), for: profile)
        let aniListPending = AniListAccount.beginLogin(for: profile)
        let malPending = MALKeychain.beginLogin(for: profile)

        // Deleted on another device: the next sync replaces the profile list without it.
        try manager.replaceProfiles([Profile(id: otherProfile, name: "B")])

        XCTAssertNil(AniListAccount.storage.login(for: profile), "a reused profile id must not inherit it")
        XCTAssertFalse(AniListAccount.save(aniList("late"), ifCurrent: aniListPending, for: profile))
        XCTAssertFalse(MALKeychain.save(mal("late"), ifCurrent: malPending, for: profile))
        XCTAssertNil(AniListAccount.storage.login(for: profile))
        XCTAssertNil(MALKeychain.login(for: profile))
        assertOtherProfileStillLoggedIn()
    }

    func testDeletingAProfileStopsItsPendingLoginsAndDropsItsLogins() throws {
        let (manager, cleanUp) = try profileManager()
        defer { cleanUp() }
        logInOtherProfile()
        MALKeychain.save(mal("old"), ifCurrent: MALKeychain.beginLogin(for: profile), for: profile)
        let aniListPending = AniListAccount.beginLogin(for: profile)
        let malPending = MALKeychain.beginLogin(for: profile)

        try manager.deleteProfile(id: profile)

        XCTAssertNil(MALKeychain.login(for: profile))
        XCTAssertFalse(AniListAccount.save(aniList("late"), ifCurrent: aniListPending, for: profile))
        XCTAssertFalse(MALKeychain.save(mal("late"), ifCurrent: malPending, for: profile))
        XCTAssertNil(AniListAccount.storage.login(for: profile))
        assertOtherProfileStillLoggedIn()
    }

    func testTheSupersededMessageIsLocalized() {
        let expected = L10n.string(
            "account_login_superseded",
            fallback: "This login was replaced: you logged out or started another login meanwhile."
        )
        XCTAssertEqual(AniListAccount.AccountError.superseded.localizedDescription, expected)
        XCTAssertEqual(MALAccount.Failure.superseded.localizedDescription, expected)
    }
}

final class AccountLoginGenerationsSemanticsTests: XCTestCase {
    func testAProfileWithNoHistoryIsAtGenerationZeroAndCanCommitIt() {
        let generations = AccountLoginGenerations()
        XCTAssertEqual(generations.current(for: "new"), 0)
        var saved = false
        XCTAssertTrue(generations.commit(0, for: "new") { saved = true })
        XCTAssertTrue(saved)
    }

    func testRemovalAndNewLoginsMoveTheGenerationOn() {
        let generations = AccountLoginGenerations()
        let initial = generations.current(for: "p")
        generations.invalidate("p")
        XCTAssertFalse(generations.commit(initial, for: "p") {})
        let started = generations.begin(for: "p")
        XCTAssertEqual(generations.current(for: "p"), started)
        XCTAssertTrue(generations.commit(started, for: "p") {})
    }
}
