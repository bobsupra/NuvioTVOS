import XCTest
@testable import NuvioTV

final class ProviderCredentialSyncTests: XCTestCase {
    private var store: UserDefaults!
    private var suiteName: String!
    private var profileScope: String!
    private var keychain: MemoryProviderCredentialKeychain!
    private var profileIDs: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "ProviderCredentialSyncTests.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
        profileScope = "ProviderCredentialSyncTests.\(UUID().uuidString)"
        keychain = MemoryProviderCredentialKeychain()
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        for profileID in profileIDs + [profileScope] {
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
            for key in ProviderCredentialStore.keys {
                let account = "\(profileID):\(key)"
                _ = SystemProviderCredentialKeychain.shared.delete(
                    service: ProviderCredentialStore.service,
                    account: account
                )
                UserDefaults.standard.removeObject(forKey: "nuvio.tv.security.providerCredentialDeletionPending.\(account)")
                UserDefaults.standard.removeObject(forKey: "nuvio.tv.security.providerCredentialExplicitlyCleared.\(account)")
            }
        }
        store = nil
        profileScope = nil
        keychain = nil
        super.tearDown()
    }

    private func row(_ provider: String, _ credential: [String: Any]) -> [String: Any] {
        ["provider": provider, "credential_json": credential, "updated_at": "2026-11-21T20:00:00Z"]
    }

    private func credential(_ key: String) -> String? {
        ProviderCredentialStore.string(
            forKey: key,
            in: store,
            profileScope: profileScope,
            keychain: keychain
        )
    }

    private func apply(_ rows: [[String: Any]]) -> [ProviderCredentialSync.Provider] {
        ProviderCredentialSync.apply(
            rows: rows,
            to: store,
            profileScope: profileScope,
            keychain: keychain
        )
    }

    func testPullAppliesNonEmptyKeysTrimmedToKeychain() {
        let rows = [row("mdblist", ["api_key": "  mdb-key \n"]), row("TMDB", ["api_key": "tmdb-key"])]
        let changed = apply(rows)

        XCTAssertEqual(Set(changed), [.mdblist, .tmdb])
        XCTAssertEqual(credential(SettingsKey.mdbListApiKey), "mdb-key")
        XCTAssertEqual(credential(SettingsKey.tmdbApiKey), "tmdb-key")
        XCTAssertNil(store.object(forKey: SettingsKey.mdbListApiKey))
        XCTAssertNil(store.object(forKey: SettingsKey.tmdbApiKey))
    }

    func testPullNeverClearsALocalKey() {
        store.set("local-tmdb", forKey: SettingsKey.tmdbApiKey)
        store.set("local-mdb", forKey: SettingsKey.mdbListApiKey)
        let rows = [row("tmdb", ["api_key": ""]), row("mdblist", [:])]

        XCTAssertTrue(apply(rows).isEmpty)
        XCTAssertEqual(credential(SettingsKey.tmdbApiKey), "local-tmdb")
        XCTAssertEqual(credential(SettingsKey.mdbListApiKey), "local-mdb")
    }

    func testPullIgnoresOtherProvidersAndReportsNoChangeForSameKey() {
        XCTAssertTrue(ProviderCredentialStore.set(
            "same",
            forKey: SettingsKey.mdbListApiKey,
            in: store,
            profileScope: profileScope,
            keychain: keychain
        ))
        let rows = [row("mdblist", ["api_key": "same"]), row("introdb", ["api_key": "x"]), row("animeskip", ["client_id": "y"])]

        XCTAssertTrue(apply(rows).isEmpty)
        XCTAssertNil(credential(SettingsKey.tmdbApiKey))
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

    func testDebridKeyFillsAnEmptySlotAndSelectsTheService() {
        let changed = apply([row("debrid:torbox", ["api_key": "tb-key"])])
        XCTAssertEqual(changed, [.torbox])
        XCTAssertEqual(credential(SettingsKey.torboxAccessToken), "tb-key")
        XCTAssertEqual(store.string(forKey: SettingsKey.debridProvider), DebridProviderKind.torbox.rawValue)
        XCTAssertEqual(credential(SettingsKey.debridApiKey), "tb-key")
        XCTAssertNil(store.object(forKey: SettingsKey.debridApiKey))
    }

    func testDebridKeyNeverReplacesThisAppleTVsToken() {
        store.set("device-token", forKey: SettingsKey.realDebridAccessToken)
        store.set(DebridProviderKind.realDebrid.rawValue, forKey: SettingsKey.debridProvider)

        let changed = apply([row("debrid:realdebrid", ["api_key": "account-key"])])
        XCTAssertTrue(changed.isEmpty)
        XCTAssertEqual(credential(SettingsKey.realDebridAccessToken), "device-token")
    }

    func testDebridKeyKeepsAnExistingServiceChoice() {
        store.set(DebridProviderKind.realDebrid.rawValue, forKey: SettingsKey.debridProvider)
        store.set("rd", forKey: SettingsKey.realDebridAccessToken)

        _ = apply([row("debrid:premiumize", ["api_key": "pm"])])
        XCTAssertEqual(credential(SettingsKey.premiumizeAccessToken), "pm")
        XCTAssertEqual(store.string(forKey: SettingsKey.debridProvider), DebridProviderKind.realDebrid.rawValue)
    }

    func testDebridKeysAreNeverPushed() {
        XCTAssertFalse(ProviderCredentialSync.Provider.torbox.isPushed)
        XCTAssertFalse(ProviderCredentialSync.Provider.realDebrid.isPushed)
        XCTAssertTrue(ProviderCredentialSync.Provider.mdblist.isPushed)
    }

    func testLegacyCredentialMigratesAndRemovesMirrorAfterKeychainWrite() {
        store.set("legacy-tmdb", forKey: SettingsKey.tmdbApiKey)

        XCTAssertEqual(credential(SettingsKey.tmdbApiKey), "legacy-tmdb")
        XCTAssertEqual(keychain.value(for: SettingsKey.tmdbApiKey, profileScope: profileScope), "legacy-tmdb")
        XCTAssertNil(store.object(forKey: SettingsKey.tmdbApiKey))
    }

    func testExistingKeychainCredentialWinsOverLegacyMirror() {
        keychain.put("secure-tmdb", for: SettingsKey.tmdbApiKey, profileScope: profileScope)
        store.set("stale-mirror", forKey: SettingsKey.tmdbApiKey)

        XCTAssertEqual(credential(SettingsKey.tmdbApiKey), "secure-tmdb")
        XCTAssertNil(store.object(forKey: SettingsKey.tmdbApiKey))
    }

    func testFailedMigrationKeepsLegacyCredentialReadable() {
        store.set("legacy-mdb", forKey: SettingsKey.mdbListApiKey)
        keychain.failWrites = true

        XCTAssertEqual(credential(SettingsKey.mdbListApiKey), "legacy-mdb")
        XCTAssertEqual(store.string(forKey: SettingsKey.mdbListApiKey), "legacy-mdb")
        XCTAssertNil(keychain.value(for: SettingsKey.mdbListApiKey, profileScope: profileScope))
    }

    func testFailedUpdateKeepsPreviousDurableCredential() {
        keychain.put("previous", for: SettingsKey.tmdbApiKey, profileScope: profileScope)
        keychain.failWrites = true

        XCTAssertFalse(ProviderCredentialStore.set(
            "replacement",
            forKey: SettingsKey.tmdbApiKey,
            in: store,
            profileScope: profileScope,
            keychain: keychain
        ))
        XCTAssertEqual(credential(SettingsKey.tmdbApiKey), "previous")
        XCTAssertNil(store.object(forKey: SettingsKey.tmdbApiKey))
    }

    func testNewCredentialWritesOnlyToKeychain() {
        XCTAssertTrue(ProviderCredentialStore.set(
            "new-seekr-key",
            forKey: SettingsKey.seekrApiKey,
            in: store,
            profileScope: profileScope,
            keychain: keychain
        ))

        XCTAssertNil(store.object(forKey: SettingsKey.seekrApiKey))
        XCTAssertEqual(credential(SettingsKey.seekrApiKey), "new-seekr-key")
    }

    func testCredentialValuesAreSeparatedByProfileScope() {
        XCTAssertTrue(ProviderCredentialStore.set(
            "profile-one",
            forKey: SettingsKey.tmdbApiKey,
            in: store,
            profileScope: "profile-one",
            keychain: keychain
        ))
        XCTAssertTrue(ProviderCredentialStore.set(
            "profile-two",
            forKey: SettingsKey.tmdbApiKey,
            in: store,
            profileScope: "profile-two",
            keychain: keychain
        ))

        XCTAssertEqual(ProviderCredentialStore.string(forKey: SettingsKey.tmdbApiKey, in: store, profileScope: "profile-one", keychain: keychain), "profile-one")
        XCTAssertEqual(ProviderCredentialStore.string(forKey: SettingsKey.tmdbApiKey, in: store, profileScope: "profile-two", keychain: keychain), "profile-two")
    }

    func testLegacyFeatureDoesNotOverwriteExistingOrUnreadableCredential() {
        keychain.put("current", for: SettingsKey.tmdbApiKey, profileScope: profileScope)
        XCTAssertFalse(ProviderCredentialStore.adoptLegacyValueIfMissing(
            "old-feature-value",
            forKey: SettingsKey.tmdbApiKey,
            in: store,
            profileScope: profileScope,
            keychain: keychain
        ))
        XCTAssertEqual(credential(SettingsKey.tmdbApiKey), "current")

        keychain.failReads = true
        XCTAssertFalse(ProviderCredentialStore.adoptLegacyValueIfMissing(
            "remote-value",
            forKey: SettingsKey.tmdbApiKey,
            in: store,
            profileScope: profileScope,
            keychain: keychain
        ))
        XCTAssertEqual(keychain.value(for: SettingsKey.tmdbApiKey, profileScope: profileScope), "current")
    }

    func testLegacyFeatureCredentialIsAdoptedOnlyForAnEmptyProfile() {
        XCTAssertTrue(ProviderCredentialStore.adoptLegacyValueIfMissing(
            "old-feature-value",
            forKey: SettingsKey.tmdbApiKey,
            in: store,
            profileScope: profileScope,
            keychain: keychain
        ))

        XCTAssertEqual(credential(SettingsKey.tmdbApiKey), "old-feature-value")
        XCTAssertNil(store.object(forKey: SettingsKey.tmdbApiKey))
    }

    func testKeychainReadFailureDoesNotApplyRemoteCredential() {
        keychain.failReads = true

        XCTAssertTrue(apply([row("tmdb", ["api_key": "account-key"])]).isEmpty)
        XCTAssertNil(keychain.value(for: SettingsKey.tmdbApiKey, profileScope: profileScope))
        XCTAssertNil(store.object(forKey: SettingsKey.tmdbApiKey))
    }

    func testExplicitClearBlocksStaleLegacyFeatureCredential() {
        XCTAssertTrue(ProviderCredentialStore.set(
            nil,
            forKey: SettingsKey.tmdbApiKey,
            in: store,
            profileScope: profileScope,
            keychain: keychain
        ))

        XCTAssertFalse(ProviderCredentialStore.adoptLegacyValueIfMissing(
            "stale-feature-value",
            forKey: SettingsKey.tmdbApiKey,
            in: store,
            profileScope: profileScope,
            keychain: keychain
        ))
        XCTAssertNil(credential(SettingsKey.tmdbApiKey))
    }

    func testProviderCredentialRPCStillAppliesAfterLocalClear() {
        XCTAssertTrue(ProviderCredentialStore.set(
            nil,
            forKey: SettingsKey.tmdbApiKey,
            in: store,
            profileScope: profileScope,
            keychain: keychain
        ))

        XCTAssertEqual(apply([row("tmdb", ["api_key": "account-key"])]), [.tmdb])
        XCTAssertEqual(credential(SettingsKey.tmdbApiKey), "account-key")
    }

    func testGenericNuvioSettingsExportAndImportExcludeCredentials() {
        let profileID = "provider-credential-generic-sync-\(UUID().uuidString)"
        profileIDs.append(profileID)
        let profileDefaults = ProfileSettings.store(for: profileID)
        for key in ProviderCredentialStore.keys {
            profileDefaults.set("local-\(key)", forKey: key)
        }

        let client = NuvioAPIClient()
        let exported = client.exportSettings(localProfileId: profileID)
        let remote = Dictionary(uniqueKeysWithValues: ProviderCredentialStore.keys.map {
            ($0, ["type": "string", "value": "remote-\($0)"] as [String: Any])
        })
        client.importSettings(remote, localProfileId: profileID)

        for key in ProviderCredentialStore.keys {
            XCTAssertNil(exported[key])
            XCTAssertEqual(profileDefaults.string(forKey: key), "local-\(key)")
        }
    }

    func testNewProfileDoesNotCopyProviderCredentials() {
        let profileID = "provider-credential-seed-\(UUID().uuidString)"
        profileIDs.append(profileID)
        for key in ProviderCredentialStore.keys {
            store.set("source-\(key)", forKey: key)
        }

        ProfileSettings.seedNewProfile(profileID, copyingFrom: store)
        let destination = ProfileSettings.store(for: profileID)

        for key in ProviderCredentialStore.keys {
            XCTAssertNil(destination.object(forKey: key), "\(key) must not cross profile boundaries")
        }
    }
}

private final class MemoryProviderCredentialKeychain: ProviderCredentialKeychain {
    private var entries: [String: String] = [:]
    var failReads = false
    var failWrites = false
    var failDeletes = false

    func read(service: String, account: String) -> ProviderCredentialKeychainRead {
        guard !failReads else { return .failed }
        guard let value = entries[entry(service: service, account: account)] else { return .missing }
        return .value(value)
    }

    func write(_ value: String, service: String, account: String) -> Bool {
        guard !failWrites else { return false }
        entries[entry(service: service, account: account)] = value
        return true
    }

    func delete(service: String, account: String) -> Bool {
        guard !failDeletes else { return false }
        entries.removeValue(forKey: entry(service: service, account: account))
        return true
    }

    func put(_ value: String, for key: String, profileScope: String) {
        entries[entry(service: ProviderCredentialStore.service, account: "\(profileScope):\(key)")] = value
    }

    func value(for key: String, profileScope: String) -> String? {
        entries[entry(service: ProviderCredentialStore.service, account: "\(profileScope):\(key)")]
    }

    private func entry(service: String, account: String) -> String {
        "\(service)|\(account)"
    }
}
