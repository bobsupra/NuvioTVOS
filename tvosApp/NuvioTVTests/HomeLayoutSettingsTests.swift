import XCTest
@testable import NuvioTV

final class HomeLayoutSettingsTests: XCTestCase {
    private func title(_ id: String, type: String = "movie") throws -> NuvioMeta {
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "type": type, "name": id])
        return try JSONDecoder().decode(NuvioMeta.self, from: data)
    }

    func testHomeTitleIdentitySurvivesWindowShiftInsertionAndReorder() throws {
        let a = try title("a")
        let b = try title("b")
        let c = try title("c")
        var section = TVHomeSection(id: "provider", title: "Catalog", items: [a, b, b, c])
        XCTAssertEqual(section.items.map(\.id), ["a", "b", "c"])
        let original = TVHomeCardIdentity.materializedTitles(rowID: section.id, items: section.items, indices: [0, 1])
        let shifted = TVHomeCardIdentity.materializedTitles(rowID: section.id, items: section.items, indices: [1, 2])
        XCTAssertEqual(original[1].id, shifted[0].id)
        XCTAssertEqual(shifted[0].id, TVHomeCardIdentity.key(rowID: section.id, item: b))
        section.items = [c, b, a, b]
        let reordered = TVHomeCardIdentity.materializedTitles(rowID: section.id, items: section.items, indices: [1, 2])
        XCTAssertEqual(reordered[0].id, original[1].id)
        section.items.insert(try title("inserted"), at: 0)
        XCTAssertEqual(TVHomeCardIdentity.key(rowID: section.id, item: section.items[2]), original[1].id)
    }

    func testHomeIdentityDistinguishesTypeAndProviderWithoutPayloadCollisions() throws {
        let movie = try title("shared")
        let series = try title("shared", type: "series")
        let section = TVHomeSection(id: "p", title: "Mixed", items: [movie, series, movie])
        XCTAssertEqual(section.items.count, 2)
        XCTAssertNotEqual(TVHomeCardIdentity.key(rowID: "p", item: movie), TVHomeCardIdentity.key(rowID: "p", item: series))
        XCTAssertNotEqual(TVHomeCardIdentity.key(rowID: "p", item: movie), TVHomeCardIdentity.key(rowID: "q", item: movie))
        XCTAssertNotEqual(TVHomeCardIdentity.titleID(try title("bc", type: "a")), TVHomeCardIdentity.titleID(try title("c", type: "ab")))
    }

    func testRestoreKeepsSurvivorAndUsesNearestSlotForRemovedTitle() {
        let row = TVHomeFocusRow(id: "row", keys: ["row\u{1}a", "row\u{1}c"])
        XCTAssertEqual(TVHomeFocusRestoration.target(saved: row.keys[1], rows: [row], preferredIndex: 0), row.keys[1])
        XCTAssertEqual(TVHomeFocusRestoration.target(saved: "row\u{1}removed", rows: [row], preferredIndex: 1), row.keys[1])
        XCTAssertEqual(TVHomeFocusRestoration.target(saved: "row\u{1}removed", rows: [row], preferredIndex: 99), row.keys[1])
        XCTAssertEqual(TVHomeFocusRestoration.target(saved: "gone\u{1}a", rows: [row], preferredIndex: 0), row.keys[0])
        XCTAssertNil(TVHomeFocusRestoration.target(saved: row.keys[0], rows: [], preferredIndex: 0))
    }

    func testRestoreSupportsRowIDsContainingSeparators() {
        let row = TVHomeFocusRow(id: "row\u{1}nested", keys: ["row\u{1}nested\u{1}b"])
        let other = TVHomeFocusRow(id: "row", keys: ["row\u{1}a"])
        XCTAssertEqual(TVHomeFocusRestoration.target(saved: "row\u{1}nested\u{1}removed", rows: [other, row], preferredIndex: 0), row.keys[0])
    }

    func testFolderDuplicatesCollapseBeforeLayoutAndRetainIdentityAfterReordering() throws {
        let decoded = try JSONDecoder().decode(NuvioCollectionFolder.self, from: Data(#"{"id":"folder","title":"Folder"}"#.utf8))
        let first = TVCollectionFolderItem(collectionId: "one", folder: decoded, sources: [])
        let second = TVCollectionFolderItem(collectionId: "two", folder: decoded, sources: [])
        var section = TVHomeSection(id: "folders", title: "Folders", items: [], collectionFolders: [first, first, second])
        XCTAssertEqual(section.collectionFolders.count, 2)
        let key = TVHomeCardIdentity.folderKey(rowID: section.id, folder: second)
        section.collectionFolders = [second, first, second]
        XCTAssertEqual(section.collectionFolders.count, 2)
        XCTAssertEqual(TVHomeCardIdentity.folderKey(rowID: section.id, folder: section.collectionFolders[0]), key)
    }

    func testFullscreenHeroBackdropSettingsKeyDefined() {
        XCTAssertEqual(SettingsKey.fullscreenHeroBackdrop, "nuvio.tv.settings.layout.fullscreenHeroBackdrop")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.fullscreenHeroBackdrop))
    }

    func testFullscreenHeroBackdropDefaultIsTrue() {
        let defaults = UserDefaults(suiteName: "HomeLayoutSettingsTestsDefaults")!
        defaults.removePersistentDomain(forName: "HomeLayoutSettingsTestsDefaults")

        // Default should be on (true)
        let isFullscreenDefault = defaults.object(forKey: SettingsKey.fullscreenHeroBackdrop) as? Bool ?? true
        XCTAssertTrue(isFullscreenDefault)

        // Can be toggled to false
        defaults.set(false, forKey: SettingsKey.fullscreenHeroBackdrop)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.fullscreenHeroBackdrop))

        // Can be toggled back to true
        defaults.set(true, forKey: SettingsKey.fullscreenHeroBackdrop)
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.fullscreenHeroBackdrop))
    }

    func testLocalizationStringsExist() {
        let title = L10n.string("layout_fullscreen_hero_backdrop", fallback: "Fullscreen Hero Backdrop")
        let subtitle = L10n.string("layout_fullscreen_hero_backdrop_sub", fallback: "Expand the hero backdrop to fill the entire screen.")
        XCTAssertFalse(title.isEmpty)
        XCTAssertFalse(subtitle.isEmpty)

        L10n.reload(languageTag: "en")
        XCTAssertEqual(L10n.string("layout_fullscreen_hero_backdrop", fallback: "Fullscreen Hero Backdrop"), "Fullscreen Hero Backdrop")
        XCTAssertEqual(L10n.string("layout_fullscreen_hero_backdrop_sub", fallback: "Expand the hero backdrop to fill the entire screen."), "Expand the hero backdrop to fill the entire screen.")
    }

    func testCatalogAddonNamesSetting() {
        XCTAssertEqual(SettingsKey.catalogAddonNames, "nuvio.tv.settings.layout.catalogAddonNames")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.catalogAddonNames))

        let defaults = UserDefaults(suiteName: "CatalogAddonNamesTestsDefaults")!
        defaults.removePersistentDomain(forName: "CatalogAddonNamesTestsDefaults")

        // Default should be true
        let isAddonNamesDefault = defaults.object(forKey: SettingsKey.catalogAddonNames) as? Bool ?? true
        XCTAssertTrue(isAddonNamesDefault)

        defaults.set(false, forKey: SettingsKey.catalogAddonNames)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.catalogAddonNames))
    }

    func testTVCatalogRowEquatableChecksShowAddonName() {
        let rowWithAddonName = TVCatalogRow(
            id: "catalog-1",
            title: "Popular Movies",
            addonName: "Cinemeta",
            showAddonName: true,
            horizontalEdgeInset: 40,
            items: [],
            initialFocusCardKey: nil,
            landscapeFocusedId: nil,
            onInitialFocusRequested: {},
            onFocus: { _ in },
            onBlur: { _ in },
            onApproachEnd: { _ in },
            onSelect: { _ in }
        )

        let rowWithoutAddonName = TVCatalogRow(
            id: "catalog-1",
            title: "Popular Movies",
            addonName: "Cinemeta",
            showAddonName: false,
            horizontalEdgeInset: 40,
            items: [],
            initialFocusCardKey: nil,
            landscapeFocusedId: nil,
            onInitialFocusRequested: {},
            onFocus: { _ in },
            onBlur: { _ in },
            onApproachEnd: { _ in },
            onSelect: { _ in }
        )

        let rowIdentical = TVCatalogRow(
            id: "catalog-1",
            title: "Popular Movies",
            addonName: "Cinemeta",
            showAddonName: true,
            horizontalEdgeInset: 40,
            items: [],
            initialFocusCardKey: nil,
            landscapeFocusedId: nil,
            onInitialFocusRequested: {},
            onFocus: { _ in },
            onBlur: { _ in },
            onApproachEnd: { _ in },
            onSelect: { _ in }
        )

        // Equatable must be false when showAddonName differs so SwiftUI invalidates and re-renders the row
        XCTAssertNotEqual(rowWithAddonName, rowWithoutAddonName)
        // Equatable must be true when all properties match
        XCTAssertEqual(rowWithAddonName, rowIdentical)
    }

    func testClearCatalogOrder() {
        let order = ["addon_1", "addon_2"]
        let orderData = try? JSONEncoder().encode(order)
        ProfileSettings.current.set(orderData, forKey: SettingsKey.homeCatalogOrder)
        ProfileSettings.current.set(orderData, forKey: SettingsKey.homeCatalogSyncedOrder)
        ProfileSettings.current.set(orderData, forKey: SettingsKey.homeCatalogTitles)

        TVHomeCatalogOrder.clearOrder()

        XCTAssertNil(ProfileSettings.current.data(forKey: SettingsKey.homeCatalogOrder))
        XCTAssertNil(ProfileSettings.current.data(forKey: SettingsKey.homeCatalogSyncedOrder))
        XCTAssertNil(ProfileSettings.current.data(forKey: SettingsKey.homeCatalogTitles))
    }

    @MainActor
    func testClearCachePreservesGeneralSettings() async {
        // Set user preferences
        ProfileSettings.current.set("Charcoal", forKey: SettingsKey.bodyColor)
        ProfileSettings.current.set("RealDebrid", forKey: SettingsKey.debridProvider)
        ProfileSettings.current.set(true, forKey: SettingsKey.fastNavigation)

        // Set catalog order
        let order = ["test_key"]
        let orderData = try? JSONEncoder().encode(order)
        ProfileSettings.current.set(orderData, forKey: SettingsKey.homeCatalogOrder)

        // Execute clearCache
        await AppCacheManager.clearCache()

        // Verify catalog order is wiped
        XCTAssertNil(ProfileSettings.current.data(forKey: SettingsKey.homeCatalogOrder))

        // Verify user preferences are preserved
        XCTAssertEqual(ProfileSettings.current.string(forKey: SettingsKey.bodyColor), "Charcoal")
        XCTAssertEqual(ProfileSettings.current.string(forKey: SettingsKey.debridProvider), "RealDebrid")
        XCTAssertTrue(ProfileSettings.current.bool(forKey: SettingsKey.fastNavigation))
    }

    func testCacheLocalizationStrings() {
        L10n.reload(languageTag: "en")
        XCTAssertEqual(L10n.string("settings_cache_title", fallback: "Cache"), "Cache")
        XCTAssertEqual(L10n.string("settings_clear_cache", fallback: "Clear Cache"), "Clear Cache")
        XCTAssertEqual(L10n.string("action_clearing", fallback: "Clearing…"), "Clearing…")
        XCTAssertEqual(L10n.string("action_cleared", fallback: "Cleared"), "Cleared")
        XCTAssertEqual(L10n.string("action_clear", fallback: "Clear"), "Clear")
    }

    @MainActor
    func testAppCacheManagerPostsNotification() async {
        let expectation = expectation(description: "didClearCacheNotification posted")
        let observer = NotificationCenter.default.addObserver(
            forName: AppCacheManager.didClearCacheNotification,
            object: nil,
            queue: .main
        ) { _ in
            expectation.fulfill()
        }

        await AppCacheManager.clearCache()

        await fulfillment(of: [expectation], timeout: 2.0)
        NotificationCenter.default.removeObserver(observer)
    }

    func testCinemetaEnabledBehavior() {
        let testDefaults = UserDefaults(suiteName: "CinemetaEnabledBehaviorTests")!
        testDefaults.removePersistentDomain(forName: "CinemetaEnabledBehaviorTests")

        // 1. Fresh install / no preferences configured: Cinemeta defaults to true
        XCTAssertTrue(CinemetaCatalogRepository.isCinemetaEnabled(in: testDefaults))

        // 2. Explicitly disabled via SettingsKey.cinemetaDisabled
        CinemetaCatalogRepository.setCinemetaDisabled(true, in: testDefaults)
        XCTAssertFalse(CinemetaCatalogRepository.isCinemetaEnabled(in: testDefaults))
        CinemetaCatalogRepository.setCinemetaDisabled(false, in: testDefaults)
        XCTAssertTrue(CinemetaCatalogRepository.isCinemetaEnabled(in: testDefaults))

        // 3. User has configured/synced addons (e.g., XPerience), but Cinemeta is NOT in preferences:
        let otherAddon = StreamAddonPreference(url: "https://xperience.example/manifest.json", enabled: true)
        let otherAddonData = try! JSONEncoder().encode([otherAddon])
        testDefaults.set(String(data: otherAddonData, encoding: .utf8)!, forKey: SettingsKey.streamAddonManifestStates)
        // Now preferences has XPerience, but not Cinemeta -> Cinemeta must be false
        XCTAssertFalse(CinemetaCatalogRepository.isCinemetaEnabled(in: testDefaults))

        // 4. Cinemeta is explicitly in preferences with enabled = false
        let cinemetaDisabledPref = StreamAddonPreference(url: "https://v3-cinemeta.strem.io/manifest.json", enabled: false)
        let disabledData = try! JSONEncoder().encode([otherAddon, cinemetaDisabledPref])
        testDefaults.set(String(data: disabledData, encoding: .utf8)!, forKey: SettingsKey.streamAddonManifestStates)
        XCTAssertFalse(CinemetaCatalogRepository.isCinemetaEnabled(in: testDefaults))

        // 5. Cinemeta is explicitly in preferences with enabled = true
        let cinemetaEnabledPref = StreamAddonPreference(url: "https://v3-cinemeta.strem.io/manifest.json", enabled: true)
        let enabledData = try! JSONEncoder().encode([otherAddon, cinemetaEnabledPref])
        testDefaults.set(String(data: enabledData, encoding: .utf8)!, forKey: SettingsKey.streamAddonManifestStates)
        XCTAssertTrue(CinemetaCatalogRepository.isCinemetaEnabled(in: testDefaults))
    }

    func testTVHomeCatalogOrderSectionKeyMatching() {
        let cinemetaSection = TVHomeSection(
            id: "movie_top",
            title: "Popular Movies",
            items: [],
            contentType: "movie",
            catalogId: "top",
            addonId: "com.linvo.cinemeta",
            addonName: "Cinemeta"
        )
        let xperienceSection = TVHomeSection(
            id: "addon_xperience_series_top",
            title: "XPerience Series",
            items: [],
            contentType: "series",
            catalogId: "top",
            addonId: "xperience",
            addonName: "XPerience"
        )

        // Account synced order: XPerience first, then Cinemeta
        let syncedOrder = ["xperience_series_top", "com.linvo.cinemeta_movie_top"]
        let data = try! JSONEncoder().encode(syncedOrder)
        ProfileSettings.current.set(data, forKey: SettingsKey.homeCatalogSyncedOrder)
        ProfileSettings.current.removeObject(forKey: SettingsKey.homeCatalogOrder)

        let ordered = TVHomeCatalogOrder.apply(to: [cinemetaSection, xperienceSection])
        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered[0].id, "addon_xperience_series_top")
        XCTAssertEqual(ordered[1].id, "movie_top")

        // Clean up
        ProfileSettings.current.removeObject(forKey: SettingsKey.homeCatalogSyncedOrder)
    }

    func testMergeHomeCatalogItemsPreservesRemoteCatalogs() {
        let remoteItems: [[String: Any]] = [
            [
                "addon_id": "xperience",
                "type": "movie",
                "catalog_id": "featured",
                "enabled": true,
                "order": 0,
                "custom_title": "XPerience Featured",
                "is_collection": false,
                "collection_id": ""
            ],
            [
                "addon_id": "com.linvo.cinemeta",
                "type": "movie",
                "catalog_id": "top",
                "enabled": true,
                "order": 1,
                "custom_title": "Cinemeta Top Movies",
                "is_collection": false,
                "collection_id": ""
            ]
        ]

        // Local tvOS snapshot only has the Cinemeta catalog (e.g. XPerience was still loading or not yet mounted)
        let localItems: [[String: Any]] = [
            [
                "addon_id": "com.linvo.cinemeta",
                "type": "movie",
                "catalog_id": "top",
                "enabled": false,
                "order": 0,
                "custom_title": "",
                "is_collection": false,
                "collection_id": ""
            ]
        ]

        let merged = NuvioSyncManager.mergeHomeCatalogItems(local: localItems, remote: remoteItems)

        // Must NOT drop the XPerience item!
        XCTAssertEqual(merged.count, 2)

        // Local update must apply to Cinemeta (enabled = false, preserved custom_title)
        let cinemetaMerged = merged.first(where: { ($0["addon_id"] as? String) == "com.linvo.cinemeta" })
        XCTAssertNotNil(cinemetaMerged)
        XCTAssertEqual(cinemetaMerged?["enabled"] as? Bool, false)
        XCTAssertEqual(cinemetaMerged?["custom_title"] as? String, "Cinemeta Top Movies")

        // Remote XPerience item must be preserved
        let xperienceMerged = merged.first(where: { ($0["addon_id"] as? String) == "xperience" })
        XCTAssertNotNil(xperienceMerged)
        XCTAssertEqual(xperienceMerged?["enabled"] as? Bool, true)
        XCTAssertEqual(xperienceMerged?["custom_title"] as? String, "XPerience Featured")
    }

    func testRowEnabledChecksCinemetaDisabled() {
        let row = TVHomeCatalogOrder.SnapshotRow(
            id: "movie_top",
            title: "Popular - Movies",
            addonName: "Cinemeta",
            addonId: "com.linvo.cinemeta",
            contentType: "movie",
            catalogId: "top",
            settingsKey: "com.linvo.cinemeta_movie_top"
        )

        CinemetaCatalogRepository.setCinemetaDisabled(false)
        XCTAssertTrue(TVHomeCatalogOrder.isRowEnabled(row))

        CinemetaCatalogRepository.setCinemetaDisabled(true)
        XCTAssertFalse(TVHomeCatalogOrder.isRowEnabled(row))

        // Reset
        CinemetaCatalogRepository.setCinemetaDisabled(false)
    }

    func testWriteSnapshotPreservesActiveRowsWhenMissingFromLiveSections() {
        let row1 = TVHomeCatalogOrder.SnapshotRow(
            id: "addon_org.stremio.movieleaks_movie_movieleaks",
            title: "Movie Leaks: New - Movies",
            addonName: "MovieLeaks",
            addonId: "org.stremio.movieleaks",
            contentType: "movie",
            catalogId: "movieleaks",
            settingsKey: "org.stremio.movieleaks_movie_movieleaks"
        )
        let row2 = TVHomeCatalogOrder.SnapshotRow(
            id: "addon_com.aio.metadata_series_trakt_up_next",
            title: "Trakt Up Next - Series",
            addonName: "AIOMetadata",
            addonId: "com.aio.metadata",
            contentType: "series",
            catalogId: "trakt_up_next",
            settingsKey: "com.aio.metadata_series_trakt_up_next"
        )
        let row3 = TVHomeCatalogOrder.SnapshotRow(
            id: "movie_top",
            title: "Popular - Movies",
            addonName: "Cinemeta",
            addonId: "com.linvo.cinemeta",
            contentType: "movie",
            catalogId: "top",
            settingsKey: "com.linvo.cinemeta_movie_top"
        )

        // Seed initial snapshot with 3 active rows in specific order
        TVHomeCatalogOrder.writeSnapshotRows([row1, row2, row3])
        XCTAssertEqual(TVHomeCatalogOrder.snapshotRows().count, 3)

        // Now simulate a Home load where only row3 (Cinemeta) loaded, while row1 & row2 returned empty/failed
        let liveSection = TVHomeSection(
            id: "movie_top",
            title: "Popular - Movies",
            items: [],
            contentType: "movie",
            catalogId: "top",
            addonId: "com.linvo.cinemeta",
            addonName: "Cinemeta"
        )

        TVHomeCatalogOrder.writeSnapshot([liveSection])

        // All 3 rows must be preserved in their exact order
        let resultRows = TVHomeCatalogOrder.snapshotRows()
        XCTAssertEqual(resultRows.count, 3)
        XCTAssertEqual(resultRows[0].id, "addon_org.stremio.movieleaks_movie_movieleaks")
        XCTAssertEqual(resultRows[1].id, "addon_com.aio.metadata_series_trakt_up_next")
        XCTAssertEqual(resultRows[2].id, "movie_top")

        // Clean up
        TVHomeCatalogOrder.clearOrder()
    }

    func testManifestDrivenCatalogRegistrationReplacesSnapshotWithoutNetworkCall() {
        let manifestCatalog1 = TVHomeCatalogOrder.SnapshotRow(
            id: "addon_org.stremio.movieleaks_movie_movieleaks",
            title: "Movie Leaks: New - Movies",
            addonName: "MovieLeaks",
            addonId: "org.stremio.movieleaks",
            contentType: "movie",
            catalogId: "movieleaks",
            settingsKey: "org.stremio.movieleaks_movie_movieleaks"
        )
        let manifestCatalog2 = TVHomeCatalogOrder.SnapshotRow(
            id: "addon_org.stremio.movieleaks_movie_movieleaks-top-monthly",
            title: "Movie Leaks: Top Monthly - Movies",
            addonName: "MovieLeaks",
            addonId: "org.stremio.movieleaks",
            contentType: "movie",
            catalogId: "movieleaks-top-monthly",
            settingsKey: "org.stremio.movieleaks_movie_movieleaks-top-monthly"
        )

        // The user installs MovieLeaks: Settings replaces snapshot rows for that addon immediately
        TVHomeCatalogOrder.replaceSnapshotRows(
            forAddonID: "org.stremio.movieleaks",
            addonName: "MovieLeaks",
            with: [manifestCatalog1, manifestCatalog2]
        )

        let rows = TVHomeCatalogOrder.snapshotRows()
        XCTAssertTrue(rows.contains(where: { $0.id == manifestCatalog1.id }))
        XCTAssertTrue(rows.contains(where: { $0.id == manifestCatalog2.id }))

        // Clean up
        TVHomeCatalogOrder.clearOrder()
    }
}
