import XCTest
@testable import NuvioTV

final class ProviderCredentialSyncTests: XCTestCase {
    private var store: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ProviderCredentialSyncTests.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
        super.tearDown()
    }

    private func row(_ provider: String, _ credential: [String: Any]) -> [String: Any] {
        ["provider": provider, "credential_json": credential, "updated_at": "2026-11-21T20:00:00Z"]
    }

    func testPullAppliesNonEmptyKeysTrimmed() {
        let rows = [row("mdblist", ["api_key": "  mdb-key \n"]), row("TMDB", ["api_key": "tmdb-key"])]
        let changed = ProviderCredentialSync.apply(rows: rows, to: store)
        XCTAssertEqual(Set(changed), [.mdblist, .tmdb])
        XCTAssertEqual(store.string(forKey: SettingsKey.mdbListApiKey), "mdb-key")
        XCTAssertEqual(store.string(forKey: SettingsKey.tmdbApiKey), "tmdb-key")
    }

    func testPullNeverClearsALocalKey() {
        store.set("local-tmdb", forKey: SettingsKey.tmdbApiKey)
        store.set("local-mdb", forKey: SettingsKey.mdbListApiKey)
        let rows = [row("tmdb", ["api_key": ""]), row("mdblist", [:])]
        XCTAssertTrue(ProviderCredentialSync.apply(rows: rows, to: store).isEmpty)
        XCTAssertEqual(store.string(forKey: SettingsKey.tmdbApiKey), "local-tmdb")
        XCTAssertEqual(store.string(forKey: SettingsKey.mdbListApiKey), "local-mdb")
    }

    func testPullIgnoresOtherProvidersAndReportsNoChangeForSameKey() {
        store.set("same", forKey: SettingsKey.mdbListApiKey)
        let rows = [row("mdblist", ["api_key": "same"]), row("debrid:torbox", ["api_key": "x"]), row("animeskip", ["client_id": "y"])]
        XCTAssertTrue(ProviderCredentialSync.apply(rows: rows, to: store).isEmpty)
        XCTAssertNil(store.string(forKey: SettingsKey.tmdbApiKey))
    }

    func testPushKeepsOtherRowsAndReplacesOnlyTheProvider() {
        let rows = [
            row("debrid:torbox", ["api_key": "tb"]),
            row("mdblist", ["api_key": "old"]),
            row("animeskip", ["client_id": "as"])
        ]
        let pushed = ProviderCredentialSync.pushRows(merging: .mdblist, value: "new", into: rows)
        XCTAssertEqual(pushed.count, 3)
        XCTAssertEqual(pushed.compactMap { $0["provider"] as? String }, ["debrid:torbox", "mdblist", "animeskip"])
        XCTAssertEqual((pushed[0]["credential_json"] as? [String: String])?["api_key"], "tb")
        XCTAssertEqual((pushed[1]["credential_json"] as? [String: String])?["api_key"], "new")
        XCTAssertEqual((pushed[2]["credential_json"] as? [String: String])?["client_id"], "as")
        XCTAssertNil(pushed[0]["updated_at"], "only provider and credential_json are sent")
    }

    func testPushAddsTheProviderWhenTheAccountHasNoRow() {
        let pushed = ProviderCredentialSync.pushRows(merging: .tmdb, value: "k", into: [row("mdblist", ["api_key": "m"])])
        XCTAssertEqual(pushed.compactMap { $0["provider"] as? String }, ["mdblist", "tmdb"])
        XCTAssertEqual((pushed[1]["credential_json"] as? [String: String])?["api_key"], "k")
    }
}
