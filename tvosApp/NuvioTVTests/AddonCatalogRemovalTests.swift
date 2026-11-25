import XCTest
@testable import NuvioTV

final class AddonCatalogRemovalTests: XCTestCase {
    private var profiles: [String] = []
    private let aURL = "https://a.example/manifest.json"
    private let bURL = "https://b.example/manifest.json"

    override func tearDown() {
        TVHomeCatalogOrder.waitForSnapshotPersistenceForTesting()
        for id in profiles {
            let settings = ProfileSettings.store(for: id)
            HomeCatalogPayloadStore.removeAll(in: settings, profileID: id)
            LargePayloadStore.remove(key: "homeCatalogTitles_\(id)", directory: "catalogSnapshots")
            settings.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(id)")
        }
        TVHomeCatalogOrder.invalidateSnapshotCache()
        ProfileSettings.clearActiveProfile()
        super.tearDown()
    }

    private func profile() -> (String, UserDefaults) {
        let id = "addon-removal-\(UUID().uuidString)"
        profiles.append(id)
        ProfileSettings.setActiveProfile(id, isPrimary: false)
        return (id, ProfileSettings.store(for: id))
    }

    private func row(_ id: String, url: String?, catalog: String = "top") -> TVHomeCatalogOrder.SnapshotRow {
        TVHomeCatalogOrder.SnapshotRow(
            id: "addon_\(id)_movie_\(catalog)", title: id, addonName: id,
            addonId: id, contentType: "movie", catalogId: catalog,
            manifestURL: url, settingsKey: "\(id)_movie_\(catalog)"
        )
    }

    private func install(_ settings: UserDefaults) {
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences([
            StreamAddonPreference(url: aURL, enabled: true),
            StreamAddonPreference(url: bURL, enabled: true)
        ], in: settings)
    }

    private func removeA(_ settings: UserDefaults) {
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences([
            StreamAddonPreference(url: bURL, enabled: true)
        ], in: settings, knownManifestIDs: [aURL: "a", bURL: "a_b"])
    }

    private func keys(_ key: String, in settings: UserDefaults) throws -> [String] {
        let data = try XCTUnwrap(HomeCatalogPayloadStore.data(forKey: key, in: settings))
        return try JSONDecoder().decode([String].self, from: data)
    }

    func testUninstallPurgesOwnedPreferencesAndPreservesOtherSourcesAndCollections() throws {
        let (_, settings) = profile()
        install(settings)
        let a = row("a", url: aURL)
        let b = row("a_b", url: bURL)
        TVHomeCatalogOrder.writeSnapshotRows([a, b], in: settings)
        let values = ["a_movie_top", "a_series_old", "a_b_movie_top", "collection_keep"]
        for key in [SettingsKey.homeCatalogOrder, SettingsKey.homeCatalogSyncedOrder,
                    SettingsKey.homeCatalogDisabled, SettingsKey.homeCatalogExplicitEnabled,
                    SettingsKey.homeCatalogDeleted] {
            let stored = key == SettingsKey.homeCatalogDeleted ? values.filter { $0 != "a_b_movie_top" } : values
            HomeCatalogPayloadStore.write(try JSONEncoder().encode(stored), forKey: key, in: settings)
        }
        HomeCatalogPayloadStore.write(try JSONEncoder().encode([
            "a_movie_top": "A title", "a_b_movie_top": "B title", "collection_keep": "Collection"
        ]), forKey: SettingsKey.homeCatalogCustomTitles, in: settings)
        settings.set(try JSONEncoder().encode([a.id, b.id]), forKey: SettingsKey.heroCatalogs)
        removeA(settings)
        for key in [SettingsKey.homeCatalogOrder, SettingsKey.homeCatalogSyncedOrder,
                    SettingsKey.homeCatalogDisabled, SettingsKey.homeCatalogExplicitEnabled,
                    SettingsKey.homeCatalogDeleted] {
            let expected = key == SettingsKey.homeCatalogDeleted ? ["collection_keep"] : ["a_b_movie_top", "collection_keep"]
            XCTAssertEqual(try keys(key, in: settings), expected)
        }
        let titlesData = try XCTUnwrap(HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogCustomTitles, in: settings))
        let titles = try JSONDecoder().decode([String: String].self, from: titlesData)
        XCTAssertNil(titles["a_movie_top"])
        XCTAssertEqual(titles["a_b_movie_top"], "B title")
        XCTAssertEqual(titles["collection_keep"], "Collection")
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: XCTUnwrap(settings.data(forKey: SettingsKey.heroCatalogs))), [b.id])
        XCTAssertEqual(TVHomeCatalogOrder.snapshotRows(in: settings).map(\.id), [b.id])
    }

    func testDisablingAndReorderingPreserveCatalogState() throws {
        let (_, settings) = profile()
        install(settings)
        let a = row("a", url: aURL)
        TVHomeCatalogOrder.writeSnapshotRows([a], in: settings)
        HomeCatalogPayloadStore.write(try JSONEncoder().encode(["a_movie_top"]), forKey: SettingsKey.homeCatalogOrder, in: settings)
        let generation = AddonCatalogRemovalStore.generation(in: settings)
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences([
            StreamAddonPreference(url: bURL, enabled: true),
            StreamAddonPreference(url: aURL, enabled: false)
        ], in: settings)
        XCTAssertEqual(try keys(SettingsKey.homeCatalogOrder, in: settings), ["a_movie_top"])
        XCTAssertEqual(TVHomeCatalogOrder.snapshotRows(in: settings).map(\.id), [a.id])
        XCTAssertEqual(AddonCatalogRemovalStore.generation(in: settings), generation)
    }

    func testLateSnapshotAndLegacyIdentityCannotRestoreRemovedCatalogs() {
        let (_, settings) = profile()
        install(settings)
        let a = row("a", url: aURL)
        let b = row("a_b", url: bURL)
        TVHomeCatalogOrder.writeSnapshotRows([a, b], in: settings)
        removeA(settings)
        TVHomeCatalogOrder.writeSnapshotRows([a, row("a", url: nil, catalog: "legacy"), b], in: settings)
        TVHomeCatalogOrder.waitForSnapshotPersistenceForTesting()
        TVHomeCatalogOrder.invalidateSnapshotCache()
        XCTAssertEqual(TVHomeCatalogOrder.snapshotRows(in: settings).map(\.id), [b.id])
    }

    func testStaleRemoteCatalogLayoutIsFilteredAndReinstallClearsRemoval() throws {
        let (id, settings) = profile()
        install(settings)
        TVHomeCatalogOrder.writeSnapshotRows([row("a", url: aURL)], in: settings)
        removeA(settings)
        let payload = HomeCatalogSyncPayload(dictionary: ["items": [
            ["addon_id": "a", "type": "movie", "catalog_id": "top", "enabled": false, "order": 0],
            ["is_collection": true, "collection_id": "keep", "enabled": true, "order": 1]
        ]])
        _ = NuvioSyncManager.applyHomeCatalogSettings(payload, localProfileId: id)
        XCTAssertEqual(try keys(SettingsKey.homeCatalogSyncedOrder, in: settings), ["collection_keep"])
        install(settings)
        XCTAssertTrue(AddonCatalogRemovalStore.context(in: settings).addonIDs.isEmpty)
        let fresh = row("a", url: aURL)
        TVHomeCatalogOrder.writeSnapshotRows([fresh], in: settings)
        XCTAssertEqual(TVHomeCatalogOrder.snapshotRows(in: settings).map(\.id), [fresh.id])
        XCTAssertEqual(try keys(SettingsKey.homeCatalogDisabled, in: settings), [])
    }

    func testRemovalInOneProfileDoesNotChangeAnotherProfile() throws {
        let (_, other) = profile()
        install(other)
        let a = row("a", url: aURL)
        TVHomeCatalogOrder.writeSnapshotRows([a], in: other)
        HomeCatalogPayloadStore.write(try JSONEncoder().encode(["a_movie_top"]), forKey: SettingsKey.homeCatalogOrder, in: other)
        let (_, current) = profile()
        install(current)
        TVHomeCatalogOrder.writeSnapshotRows([a], in: current)
        removeA(current)
        XCTAssertEqual(try keys(SettingsKey.homeCatalogOrder, in: other), ["a_movie_top"])
        XCTAssertEqual(TVHomeCatalogOrder.snapshotRows(in: other).map(\.id), [a.id])
        XCTAssertTrue(AddonCatalogRemovalStore.context(in: other).addonIDs.isEmpty)
    }

    func testAnotherInstalledConfigurationWithSameManifestIDKeepsSharedPreferences() throws {
        let (_, settings) = profile()
        install(settings)
        let a = row("shared", url: aURL, catalog: "first")
        let b = row("shared", url: bURL, catalog: "second")
        TVHomeCatalogOrder.writeSnapshotRows([a, b], in: settings)
        HomeCatalogPayloadStore.write(try JSONEncoder().encode(["shared_movie_first", "shared_movie_second"]), forKey: SettingsKey.homeCatalogOrder, in: settings)
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences([
            StreamAddonPreference(url: bURL, enabled: true)
        ], in: settings, knownManifestIDs: [aURL: "shared", bURL: "shared"])
        XCTAssertEqual(try keys(SettingsKey.homeCatalogOrder, in: settings), ["shared_movie_first", "shared_movie_second"])
        XCTAssertEqual(TVHomeCatalogOrder.snapshotRows(in: settings).map(\.id), [b.id])
        XCTAssertTrue(AddonCatalogRemovalStore.context(in: settings).addonIDs.isEmpty)
    }

    func testDiscoveredIdentityCleansSettingsEvenWhenCatalogSnapshotWasRemoved() throws {
        let (_, settings) = profile()
        install(settings)
        AddonCatalogRemovalStore.didDiscover(addonID: "a", manifestURL: aURL, in: settings)
        HomeCatalogPayloadStore.write(try JSONEncoder().encode(["a_series_old"]), forKey: SettingsKey.homeCatalogOrder, in: settings)
        TVHomeCatalogOrder.writeSnapshotRows([], in: settings)
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences([
            StreamAddonPreference(url: bURL, enabled: true)
        ], in: settings)
        XCTAssertEqual(try keys(SettingsKey.homeCatalogOrder, in: settings), [])
        XCTAssertTrue(AddonCatalogRemovalStore.context(in: settings).addonIDs.contains("a"))
        let receipt = try XCTUnwrap(settings.data(forKey: "nuvio.tv.settings.layout.removedAddonCatalogSources"))
        XCTAssertFalse(String(decoding: receipt, as: UTF8.self).contains(aURL))
    }

    func testImplicitCinemetaRemovalCleansLegacyKeysWithoutTouchingCollections() throws {
        let (_, settings) = profile()
        HomeCatalogPayloadStore.write(try JSONEncoder().encode([
            "movie_top", "com.linvo.cinemeta_series_imdbRating", "collection_keep"
        ]), forKey: SettingsKey.homeCatalogOrder, in: settings)
        AddonCatalogRemovalStore.removeBuiltInCinemeta(in: settings)
        XCTAssertEqual(try keys(SettingsKey.homeCatalogOrder, in: settings), ["collection_keep"])
        let legacy = TVHomeCatalogOrder.SnapshotRow(id: "movie_top", title: "Popular", settingsKey: "com.linvo.cinemeta_movie_top")
        XCTAssertTrue(AddonCatalogRemovalStore.context(in: settings).removes(legacy))
    }

    func testGenericSettingsImportCannotRestoreOwnedHeroOrCatalogSelections() throws {
        let (_, settings) = profile()
        install(settings)
        let a = row("a", url: aURL)
        let b = row("a_b", url: bURL)
        TVHomeCatalogOrder.writeSnapshotRows([a, b], in: settings)
        removeA(settings)
        settings.set(try JSONEncoder().encode([a.id, b.id]), forKey: SettingsKey.heroCatalogs)
        HomeCatalogPayloadStore.write(try JSONEncoder().encode(["a_movie_top", "a_b_movie_top"]), forKey: SettingsKey.homeCatalogOrder, in: settings)
        AddonCatalogRemovalStore.reconcile(in: settings)
        XCTAssertEqual(try keys(SettingsKey.homeCatalogOrder, in: settings), ["a_b_movie_top"])
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: XCTUnwrap(settings.data(forKey: SettingsKey.heroCatalogs))), [b.id])
    }

    func testStaleAddonPullIsBlockedUntilServerAcknowledgesRemoval() {
        let (_, settings) = profile()
        install(settings)
        removeA(settings)
        let old = [StreamAddonPreference(url: aURL, enabled: true), StreamAddonPreference(url: bURL, enabled: true)]
        XCTAssertEqual(AddonCatalogRemovalStore.filterRemote(old, in: settings).map(\.url), [bURL])
        XCTAssertTrue(AddonCatalogRemovalStore.hasPendingRemoval(in: settings))
        _ = AddonCatalogRemovalStore.filterRemote([StreamAddonPreference(url: bURL, enabled: true)], in: settings)
        XCTAssertFalse(AddonCatalogRemovalStore.hasPendingRemoval(in: settings))
        XCTAssertEqual(AddonCatalogRemovalStore.filterRemote(old, in: settings).map(\.url), [aURL, bURL])
    }

    func testExplicitLocalReinstallClearsPendingServerRemoval() {
        let (_, settings) = profile()
        install(settings)
        removeA(settings)
        XCTAssertTrue(AddonCatalogRemovalStore.hasPendingRemoval(in: settings))
        install(settings)
        XCTAssertFalse(AddonCatalogRemovalStore.hasPendingRemoval(in: settings))
        XCTAssertTrue(AddonCatalogRemovalStore.context(in: settings).addonIDs.isEmpty)
    }

    func testGenericProfileSettingsSyncNeverExportsOrOverwritesInstalledAddons() {
        let (id, settings) = profile()
        install(settings)
        settings.set("Modern", forKey: SettingsKey.homeLayout)

        let client = NuvioAPIClient()
        let exported = client.exportSettings(localProfileId: id)
        XCTAssertNil(exported[SettingsKey.streamAddonManifestStates])
        XCTAssertNil(exported[SettingsKey.streamAddonManifestURL])
        XCTAssertNil(exported[SettingsKey.streamAddonManifestURLs])
        XCTAssertNotNil(exported[SettingsKey.homeLayout])

        let snapshot = ProfileSettingsSnapshot.capture(for: id)
        XCTAssertNil(snapshot[SettingsKey.streamAddonManifestStates])
        XCTAssertNil(snapshot[SettingsKey.streamAddonManifestURL])
        XCTAssertNil(snapshot[SettingsKey.streamAddonManifestURLs])

        // A stale/empty tvos_settings blob from another device must not wipe installed add-ons.
        client.importSettings([
            SettingsKey.streamAddonManifestStates: ["type": "string", "value": "[]"],
            SettingsKey.streamAddonManifestURL: ["type": "string", "value": ""],
            SettingsKey.streamAddonManifestURLs: ["type": "string", "value": ""],
            SettingsKey.homeLayout: ["type": "string", "value": "Grid"]
        ], localProfileId: id)

        XCTAssertEqual(
            CinemetaCatalogRepository.configuredStreamAddonPreferences(in: settings).map(\.url),
            [aURL, bURL]
        )
        XCTAssertEqual(settings.string(forKey: SettingsKey.homeLayout), "Grid")
    }

    @MainActor
    func testICloudSettingsSyncNeverExportsOrOverwritesInstalledAddons() {
        let (_, settings) = profile()
        install(settings)
        settings.set("Modern", forKey: SettingsKey.homeLayout)

        let manager = ICloudSettingsSyncManager.shared
        let payload = manager.extractSettingsPayload(from: settings)
        XCTAssertNil(payload[SettingsKey.streamAddonManifestStates])
        XCTAssertNil(payload[SettingsKey.streamAddonManifestURL])
        XCTAssertNil(payload[SettingsKey.streamAddonManifestURLs])
        XCTAssertEqual(payload[SettingsKey.homeLayout] as? String, "Modern")

        // An incoming iCloud snapshot carrying empty add-on keys must leave local add-ons intact.
        manager.applySettingsPayload([
            SettingsKey.streamAddonManifestStates: "[]",
            SettingsKey.streamAddonManifestURL: "",
            SettingsKey.streamAddonManifestURLs: "",
            SettingsKey.homeLayout: "Classic"
        ], to: settings)

        XCTAssertEqual(
            CinemetaCatalogRepository.configuredStreamAddonPreferences(in: settings).map(\.url),
            [aURL, bURL]
        )
        XCTAssertEqual(settings.string(forKey: SettingsKey.homeLayout), "Classic")
    }

    func testMalformedRemoteAddonsDoNotWipeInstalledAddons() {
        let (id, settings) = profile()
        install(settings)

        let client = NuvioAPIClient()
        XCTAssertThrowsError(try client.applyAddons([
            RemoteAddon(url: "", enabled: true, sortOrder: 0),
            RemoteAddon(url: "   ", enabled: true, sortOrder: 1)
        ], localProfileId: id))

        XCTAssertEqual(
            CinemetaCatalogRepository.configuredStreamAddonPreferences(in: settings).map(\.url),
            [aURL, bURL]
        )
    }

    @MainActor
    func testAddonPushIsBlockedUntilAddonPullCompletesForProfile() {
        let syncManager = NuvioSyncManager()
        let key = "user-1:1"
        XCTAssertFalse(syncManager.canPushAddonPreferences(forSyncKey: key))

        syncManager.completedAddonPullKeys.insert(key)
        XCTAssertTrue(syncManager.canPushAddonPreferences(forSyncKey: key))
        XCTAssertFalse(syncManager.canPushAddonPreferences(forSyncKey: "user-1:2"))
    }
}
