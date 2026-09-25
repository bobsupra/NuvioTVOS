import XCTest
import SwiftUI
@testable import NuvioTV

final class HomeLayoutSettingsTests: XCTestCase {
    override func tearDown() {
        ProfileSettings.clearActiveProfile()
        super.tearDown()
    }
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
        let savedPrefs = ProfileSettings.current.string(forKey: SettingsKey.streamAddonManifestStates)
        let savedURLs = ProfileSettings.current.string(forKey: SettingsKey.streamAddonManifestURLs)
        let savedSingleURL = ProfileSettings.current.string(forKey: SettingsKey.streamAddonManifestURL)
        let savedDisabledCatalogs = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogDisabled)
        let savedDisabledAddons = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogDisabledAddonIDs)
        let savedDisabledNames = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogDisabledAddonNames)
        defer {
            ProfileSettings.current.set(savedPrefs, forKey: SettingsKey.streamAddonManifestStates)
            ProfileSettings.current.set(savedURLs, forKey: SettingsKey.streamAddonManifestURLs)
            ProfileSettings.current.set(savedSingleURL, forKey: SettingsKey.streamAddonManifestURL)
            ProfileSettings.current.set(savedDisabledCatalogs, forKey: SettingsKey.homeCatalogDisabled)
            ProfileSettings.current.set(savedDisabledAddons, forKey: SettingsKey.homeCatalogDisabledAddonIDs)
            ProfileSettings.current.set(savedDisabledNames, forKey: SettingsKey.homeCatalogDisabledAddonNames)
            CinemetaCatalogRepository.setCinemetaDisabled(false)
        }
        ProfileSettings.current.removeObject(forKey: SettingsKey.streamAddonManifestStates)
        ProfileSettings.current.removeObject(forKey: SettingsKey.streamAddonManifestURLs)
        ProfileSettings.current.removeObject(forKey: SettingsKey.streamAddonManifestURL)
        ProfileSettings.current.removeObject(forKey: SettingsKey.homeCatalogDisabled)
        ProfileSettings.current.removeObject(forKey: SettingsKey.homeCatalogDisabledAddonIDs)
        ProfileSettings.current.removeObject(forKey: SettingsKey.homeCatalogDisabledAddonNames)

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

    func testWriteSnapshotKeepsFirstLiveRowWhenSectionIDsRepeat() {
        let profileID = "snapshot-dedup-\(UUID().uuidString)"
        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        defer { TVHomeCatalogOrder.clearOrder() }

        let previous = TVHomeCatalogOrder.SnapshotRow(
            id: "duplicate",
            title: "Previous row",
            addonName: "Previous source",
            addonId: "previous-source"
        )
        let retained = TVHomeCatalogOrder.SnapshotRow(id: "retained", title: "Retained row")
        TVHomeCatalogOrder.writeSnapshotRows([previous, retained])

        let firstLiveSection = TVHomeSection(
            id: "duplicate",
            title: "First live row",
            items: [],
            addonId: "current-source",
            addonName: "Current source"
        )
        let duplicateLiveSection = TVHomeSection(
            id: "duplicate",
            title: "Second live row",
            items: [],
            addonId: "later-source",
            addonName: "Later source"
        )

        TVHomeCatalogOrder.writeSnapshot([firstLiveSection, duplicateLiveSection])

        let rows = TVHomeCatalogOrder.snapshotRows()
        XCTAssertEqual(rows.map(\.id), ["duplicate", "retained"])
        XCTAssertEqual(rows.first?.title, "First live row")
        XCTAssertEqual(rows.first?.addonId, "current-source")
    }

    func testWriteSnapshotRowsKeepsFirstRowForDuplicateIDs() {
        let profileID = "snapshot-write-dedup-\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: "HomeCatalogSnapshotTests-\(profileID)")!
        settings.set(profileID, forKey: "nuvio.tv.profile.settings.profileID")

        let first = TVHomeCatalogOrder.SnapshotRow(id: "duplicate", title: "First row")
        let duplicate = TVHomeCatalogOrder.SnapshotRow(id: "duplicate", title: "Second row")
        let next = TVHomeCatalogOrder.SnapshotRow(id: "next", title: "Next row")
        TVHomeCatalogOrder.writeSnapshotRows([first, duplicate, next], in: settings)

        let rows = TVHomeCatalogOrder.snapshotRows(in: settings)
        XCTAssertEqual(rows.map(\.id), ["duplicate", "next"])
        XCTAssertEqual(rows.first?.title, "First row")
    }

    func testSnapshotRowsKeepsFirstRowWhenReadingLegacyDuplicateIDs() {
        let profileID = "snapshot-legacy-dedup-\(UUID().uuidString)"
        let settings = UserDefaults(suiteName: "HomeCatalogSnapshotTests-\(profileID)")!
        settings.set(profileID, forKey: "nuvio.tv.profile.settings.profileID")
        let legacyJSON = #"""
        [
            {"id":"duplicate","title":"First legacy row"},
            {"id":"duplicate","title":"Second legacy row"},
            {"id":"next","title":"Next legacy row"}
        ]
        """#
        settings.set(Data(legacyJSON.utf8), forKey: SettingsKey.homeCatalogTitles)

        let rows = TVHomeCatalogOrder.snapshotRows(in: settings)

        XCTAssertEqual(rows.map(\.id), ["duplicate", "next"])
        XCTAssertEqual(rows.first?.title, "First legacy row")
        XCTAssertEqual(TVHomeCatalogOrder.snapshotRows(in: settings), rows)
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

    func testHomeCatalogSyncItemDecodesCustomTitle() {
        let dict: [String: Any] = [
            "addon_id": "com.aio.metadata",
            "type": "series",
            "catalog_id": "top_20",
            "custom_title": "Top 20 TV Shows of the Week",
            "enabled": true,
            "order": 1
        ]
        guard let item = HomeCatalogSyncItem(dictionary: dict) else {
            XCTFail("Failed to initialize HomeCatalogSyncItem")
            return
        }
        XCTAssertEqual(item.addonId, "com.aio.metadata")
        XCTAssertEqual(item.type, "series")
        XCTAssertEqual(item.catalogId, "top_20")
        XCTAssertEqual(item.customTitle, "Top 20 TV Shows of the Week")
        XCTAssertTrue(item.enabled)
    }

    func testTVHomeCatalogOrderCustomTitlesPersistenceAndSync() {
        let profileId = "test_custom_titles_profile"
        // Clean up any leftover data from previous runs
        let store = ProfileSettings.store(for: profileId)
        store.removeObject(forKey: SettingsKey.homeCatalogSyncedOrder)
        store.removeObject(forKey: SettingsKey.homeCatalogDisabled)
        store.removeObject(forKey: SettingsKey.homeCollectionDisabled)
        store.removeObject(forKey: SettingsKey.homeCatalogCustomTitles)
        store.removeObject(forKey: SettingsKey.homeCatalogShowType)

        let itemDict: [String: Any] = [
            "addon_id": "com.aio.metadata",
            "type": "series",
            "catalog_id": "top_20",
            "custom_title": "Top 20 TV Shows of the Week",
            "enabled": true,
            "order": 0
        ]
        let payload = HomeCatalogSyncPayload(dictionary: [
            "items": [itemDict],
            "show_catalog_type": false
        ])

        let didChange = NuvioSyncManager.applyHomeCatalogSettings(payload, localProfileId: profileId)
        XCTAssertTrue(didChange)

        guard let data = store.data(forKey: SettingsKey.homeCatalogCustomTitles),
              let titles = try? JSONDecoder().decode([String: String].self, from: data) else {
            XCTFail("Custom titles not saved to store")
            return
        }
        XCTAssertEqual(titles["com.aio.metadata_series_top_20"], "Top 20 TV Shows of the Week")

        // Clean up
        store.removeObject(forKey: SettingsKey.homeCatalogSyncedOrder)
        store.removeObject(forKey: SettingsKey.homeCatalogDisabled)
        store.removeObject(forKey: SettingsKey.homeCollectionDisabled)
        store.removeObject(forKey: SettingsKey.homeCatalogCustomTitles)
        store.removeObject(forKey: SettingsKey.homeCatalogShowType)
    }

    func testHomeVerticalScrollAnimationCadenceMatchesFluidTiming() {
        // Vertical scrolling uses critically damped spring (damping 1.0) to eliminate bounce-back,
        // while horizontal strip scrolling uses 0.86 with momentum preservation.
        XCTAssertEqual(
            TVHomeLayout.verticalScrollAnimation,
            Animation.interactiveSpring(response: 0.28, dampingFraction: 1.0, blendDuration: 0.20)
        )
        XCTAssertEqual(
            TVHomeLayout.fastVerticalScrollAnimation,
            Animation.interactiveSpring(response: 0.18, dampingFraction: 1.0, blendDuration: 0.12)
        )
        XCTAssertEqual(
            TVHomeLayout.scrollAnimation,
            Animation.interactiveSpring(response: 0.24, dampingFraction: 0.86, blendDuration: 0.18)
        )
    }

    func testPosterShapeAndRowTileShapeResolution() {
        let landscapeMeta = NuvioMeta(
            id: "sport:1",
            name: "Sky Sports Premier League",
            description: nil,
            posterUrl: "https://example.com/sky.jpg",
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: "channel",
            year: 2026,
            genres: ["Sport"],
            posterShape: "landscape"
        )
        XCTAssertEqual(landscapeMeta.tileShape, CollectionTileShape.landscape)

        let row = TVCatalogRow(
            id: "row:sports",
            title: "Live Now - Sport",
            horizontalEdgeInset: 40,
            items: [landscapeMeta],
            initialFocusCardKey: nil,
            landscapeFocusedId: nil,
            onInitialFocusRequested: {},
            onFocus: { _ in },
            onBlur: { _ in },
            onApproachEnd: { _ in },
            onSelect: { _ in }
        )
        XCTAssertEqual(row.rowTileShape, CollectionTileShape.landscape)

        // Sizing tests for landscape vs portrait
        XCTAssertEqual(TVCollectionFolderCardLayout.cardWidth(shape: .landscape, layoutMode: "Modern"), 560)
        XCTAssertEqual(TVCollectionFolderCardLayout.cardWidth(shape: .landscape, layoutMode: "Compact"), 454)
        XCTAssertEqual(TVCollectionFolderCardLayout.cardWidth(shape: .poster, layoutMode: "Modern"), 210)
        XCTAssertEqual(TVCollectionFolderCardLayout.cardWidth(shape: .poster, layoutMode: "Compact"), 170)
        XCTAssertEqual(TVCollectionFolderCardLayout.cardWidth(shape: .square, layoutMode: "Modern"), 315)
    }

    func testLargePayloadStorePurgesLegacyOversizedPreferences() {
        let suite = UserDefaults(suiteName: "nuvio.test.purge.\(UUID().uuidString)")!
        defer { suite.removePersistentDomain(forName: suite.description) }

        suite.set("legacy-data".data(using: .utf8), forKey: "nuvio.tv.settings.layout.homeCatalogTitles")
        suite.set("legacy-data".data(using: .utf8), forKey: "nuvio.tv.settings.integrations.jellyfinLibraryIndex")
        suite.set("legacy-data".data(using: .utf8), forKey: "nuvio.tv.settings.integrations.smbLibraryIndex")
        suite.set("legacy-data".data(using: .utf8), forKey: "nuvio.tv.bingeGroup.tt12345")
        suite.set("legacy-data".data(using: .utf8), forKey: "nuvio.tv.lastStreamQuality.tt12345")
        suite.set("legacy-data".data(using: .utf8), forKey: "nuvio.tv.lastPlaybackStream.tt12345")
        suite.set("safe-value", forKey: SettingsKey.theme)

        LargePayloadStore.purgeLegacyOversizedPreferences(in: suite)

        XCTAssertNil(suite.data(forKey: "nuvio.tv.settings.layout.homeCatalogTitles"))
        XCTAssertNil(suite.data(forKey: "nuvio.tv.settings.integrations.jellyfinLibraryIndex"))
        XCTAssertNil(suite.data(forKey: "nuvio.tv.settings.integrations.smbLibraryIndex"))
        XCTAssertNil(suite.data(forKey: "nuvio.tv.bingeGroup.tt12345"))
        XCTAssertNil(suite.data(forKey: "nuvio.tv.lastStreamQuality.tt12345"))
        XCTAssertNil(suite.data(forKey: "nuvio.tv.lastPlaybackStream.tt12345"))
        XCTAssertEqual(suite.string(forKey: SettingsKey.theme), "safe-value")
    }

    func testTVHomeCatalogOrderSnapshotStorageViaLargePayloadStore() {
        let testProfileID = "test-profile-\(UUID().uuidString)"
        let suite = ProfileSettings.store(for: testProfileID)

        let rows = [
            TVHomeCatalogOrder.SnapshotRow(
                id: "addon_test_row",
                title: "Test Row",
                addonName: "Torrentio",
                addonId: "torrentio",
                contentType: "movie",
                catalogId: "top",
                settingsKey: "torrentio_movie_top",
                posterShape: "poster"
            )
        ]

        TVHomeCatalogOrder.writeSnapshotRows(rows, in: suite)

        // UserDefaults should NOT hold the snapshot data directly
        XCTAssertNil(suite.data(forKey: SettingsKey.homeCatalogTitles))

        // snapshotRows should read back from LargePayloadStore correctly
        let loaded = TVHomeCatalogOrder.snapshotRows(in: suite)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, "addon_test_row")
        XCTAssertEqual(loaded.first?.title, "Test Row")
        XCTAssertEqual(loaded.first?.addonName, "Torrentio")
    }

    func testBingeGroupStoreAndStreamQualityStoresViaLargePayloadStore() {
        let testProfileID = "test-profile-\(UUID().uuidString)"

        BingeGroupStore.save(
            seriesId: "tt99999",
            bingeGroup: "release-group-x",
            addonName: "Torrentio",
            releaseFingerprint: "fingerprint-123",
            resolution: 1080,
            quality: .bluray,
            isCached: true,
            profileId: testProfileID
        )

        let loadedBinge = BingeGroupStore.load(seriesId: "tt99999", profileId: testProfileID)
        XCTAssertNotNil(loadedBinge)
        XCTAssertEqual(loadedBinge?.bingeGroup, "release-group-x")
        XCTAssertEqual(loadedBinge?.addonName, "Torrentio")
        XCTAssertEqual(loadedBinge?.resolution, 1080)

        // StreamQualityTags store
        let tags = StreamQualityTags(
            resolution: 2160,
            isDolbyVision: true,
            isHDR: true,
            isAtmos: true,
            isCached: true,
            quality: .webDl,
            bingeGroup: "release-group-x"
        )
        LastStreamQualityStore.save(metaId: "tt99999", tags: tags, profileId: testProfileID)

        let loadedTags = LastStreamQualityStore.load(metaId: "tt99999", profileId: testProfileID)
        XCTAssertNotNil(loadedTags)
        XCTAssertEqual(loadedTags?.resolution, 2160)
        XCTAssertTrue(loadedTags?.isDolbyVision ?? false)
        XCTAssertTrue(loadedTags?.isAtmos ?? false)

        // LastPlaybackStream store
        LastPlaybackStreamStore.save(
            metaId: "tt99999",
            url: "https://example.com/stream.mkv",
            httpHeaders: ["User-Agent": "Nuvio"],
            season: 1,
            episode: 2,
            profileId: testProfileID
        )

        let loadedPlayback = LastPlaybackStreamStore.load(
            metaId: "tt99999",
            season: 1,
            episode: 2,
            profileId: testProfileID
        )
        XCTAssertNotNil(loadedPlayback)
        XCTAssertEqual(loadedPlayback?.url, "https://example.com/stream.mkv")
        XCTAssertEqual(loadedPlayback?.httpHeaders["User-Agent"], "Nuvio")
    }

    func testProfileSettingsStoreIsReadOnlyAndDoesNotMutateOversizedSuite() {
        let profileId = "test-readonly-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: "nuvio.tv.profile.settings.\(profileId)")!
        defer {
            ProfileSettings.clearActiveProfile()
            suite.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileId)")
        }

        // Simulate legacy unpurged data in the suite before activation
        let dummyData = Data(repeating: 0x41, count: 100_000)
        suite.set(dummyData, forKey: "nuvio.tv.settings.layout.homeCatalogTitles")

        // Calling store(for:) MUST be completely read-only and not set the profileScopeKey
        let retrievedStore = ProfileSettings.store(for: profileId)
        XCTAssertNil(retrievedStore.string(forKey: "nuvio.tv.profile.settings.profileID"))

        // Activating the profile purges the legacy blob and marks the suite safely
        ProfileSettings.setActiveProfile(profileId, isPrimary: false)
        XCTAssertNil(retrievedStore.data(forKey: "nuvio.tv.settings.layout.homeCatalogTitles"))
        XCTAssertEqual(retrievedStore.string(forKey: "nuvio.tv.profile.settings.profileID"), profileId)
    }

    func testLargePayloadStoreMultiMegabyteCapacityWithoutTouchingUserDefaults() {
        let testKey = "heavy-payload-\(UUID().uuidString)"
        let directory = "stressTestSnapshots"
        defer { LargePayloadStore.removeDirectory(directory) }

        // Create a 5MB payload (which would crash UserDefaults cfprefsd)
        let largeData = Data(repeating: 0x42, count: 5 * 1024 * 1024)
        let writeSuccess = LargePayloadStore.write(largeData, key: testKey, directory: directory)
        XCTAssertTrue(writeSuccess)

        let readData = LargePayloadStore.read(key: testKey, directory: directory)
        XCTAssertEqual(readData?.count, 5 * 1024 * 1024)
        XCTAssertEqual(readData, largeData)

        // Ensure standard UserDefaults has zero bytes of this test data
        XCTAssertNil(UserDefaults.standard.data(forKey: testKey))
    }

    func testBingeGroupStoreAndStreamQualityStoresLRULimits() {
        let profileId = "test-lru-\(UUID().uuidString)"

        // Save 220 items (max is 200)
        for i in 1...220 {
            BingeGroupStore.save(
                seriesId: "series_\(i)",
                bingeGroup: "group_\(i)",
                addonName: "Torrentio",
                releaseFingerprint: "fp_\(i)",
                resolution: 1080,
                quality: .webDl,
                isCached: true,
                profileId: profileId
            )
        }

        // The most recently saved item (series_220) must exist
        let latest = BingeGroupStore.load(seriesId: "series_220", profileId: profileId)
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.bingeGroup, "group_220")

        // Oldest items (e.g. series_1 to series_20) should have been evicted by the 200-cap LRU
        let evicted = BingeGroupStore.load(seriesId: "series_1", profileId: profileId)
        XCTAssertNil(evicted)
    }

    func testCatalogInCollectionFolderRemainsVisibleInLayoutMatchingAndroid() throws {
        let manifestURL = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        let source = CatalogHomeVisibilityResolver.Source(
            addonIdentifier: "sports.addon",
            contentType: "sports",
            catalogID: "live_streams",
            collectionID: "sports_collection"
        )
        // Direct collection sources remain included in layout & Home matching Android TV
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "sports.addon",
            contentType: "sports",
            catalogID: "live_streams",
            collectionSources: [source],
            manifestURL: manifestURL,
            explicitHomeKeys: []
        ))
    }
}
