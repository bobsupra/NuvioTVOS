import XCTest
import SwiftUI
@testable import NuvioTV

final class HomeLayoutSettingsTests: XCTestCase {
    override func tearDown() {
        ProfileSettings.clearActiveProfile()
        super.tearDown()
    }
    private func title(_ id: String, type: String = "movie", landscapePosterUrl: String? = nil) throws -> NuvioMeta {
        var payload: [String: Any] = ["id": id, "type": type, "name": id]
        if let landscapePosterUrl {
            payload["landscapePosterUrl"] = landscapePosterUrl
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(NuvioMeta.self, from: data)
    }

    func testWatchedBadgeUsesCheckmarkForFirstWatchAndCountsForRepeats() {
        L10n.reload(languageTag: "en")

        let firstWatch = WatchedCheckmarkPresentation(watchCount: 1)
        XCTAssertEqual(firstWatch.content, .checkmark)
        XCTAssertEqual(firstWatch.accessibilityLabel, "Watched")

        let secondWatch = WatchedCheckmarkPresentation(watchCount: 2)
        XCTAssertEqual(secondWatch.content, .count(2))
        XCTAssertEqual(secondWatch.accessibilityLabel, "Watched 2 times")

        let thirdWatch = WatchedCheckmarkPresentation(watchCount: 3)
        XCTAssertEqual(thirdWatch.content, .count(3))
        XCTAssertEqual(thirdWatch.accessibilityLabel, "Watched 3 times")

        let doubleDigitCount = WatchedCheckmarkPresentation(watchCount: 12)
        XCTAssertEqual(doubleDigitCount.content, .count(12))
        XCTAssertEqual(doubleDigitCount.accessibilityLabel, "Watched 12 times")
    }

    @MainActor
    func testWatchedBadgeDecisionCacheCanReplaceCheckmarkCountWithoutBooleanChange() {
        let cache = CatalogWatchedMetadataCache.shared
        let key = "badge-count-test-\(UUID().uuidString)"

        cache.setDecision(1, for: key)
        XCTAssertEqual(cache.cachedDecision(for: key), 1)

        cache.setDecision(2, for: key)
        XCTAssertEqual(cache.cachedDecision(for: key), 2)
    }

    func testIDOnlyMovieBadgePreservesKnownRepeatCountWithoutMetadata() throws {
        let movie = try title("raw-movie-id")
        let source = TraktWatchProgressSource.nuvioSync.rawValue
        let snapshot = WatchedSnapshot(
            items: [
                WatchedStoreItem(
                    meta: movie,
                    watchedAt: Date(timeIntervalSince1970: 1),
                    sources: [source],
                    watchCountsBySource: [source: 2]
                )
            ],
            source: .nuvioSync
        )

        let count = CatalogWatchedBadgeCountResolver.movieWatchCount(
            snapshot: snapshot,
            metaId: movie.id,
            type: movie.type,
            resolvedMeta: nil
        )

        XCTAssertEqual(count, 2)
    }

    func testIDOnlyMovieBadgeSelectsActiveCountAfterCombiningResolvedAliases() {
        let rawMovie = NuvioMeta(id: "raw-movie-id", name: "Raw Movie", type: "movie")
        let resolvedMovie = NuvioMeta(
            id: "canonical-movie-id",
            name: "Canonical Movie",
            imdbId: "tt1234567",
            type: "movie"
        )
        let trakt = TraktWatchProgressSource.trakt.rawValue
        let nuvio = TraktWatchProgressSource.nuvioSync.rawValue
        let snapshot = WatchedSnapshot(
            items: [
                WatchedStoreItem(
                    meta: rawMovie,
                    watchedAt: Date(timeIntervalSince1970: 1),
                    sources: [trakt],
                    watchCountsBySource: [trakt: 5]
                ),
                WatchedStoreItem(
                    meta: resolvedMovie,
                    watchedAt: Date(timeIntervalSince1970: 2),
                    sources: [nuvio],
                    watchCountsBySource: [nuvio: 2]
                )
            ],
            source: .nuvioSync,
            additionalVisibleSources: [.trakt]
        )

        let count = CatalogWatchedBadgeCountResolver.movieWatchCount(
            snapshot: snapshot,
            metaId: rawMovie.id,
            type: rawMovie.type,
            resolvedMeta: resolvedMovie
        )

        XCTAssertEqual(count, 2)
    }

    private func activateHomeVisibilityProfile() -> (id: String, suite: UserDefaults) {
        let id = "home-visibility-\(UUID().uuidString)"
        let suiteName = "nuvio.tv.profile.settings.\(id)"
        let suite = UserDefaults(suiteName: suiteName)!
        ProfileSettings.setActiveProfile(id, isPrimary: false)
        CollectionsStore.setActiveProfile(id)
        HomeCatalogPayloadStore.removeAll(in: suite, profileID: id)
        TVHomeCatalogOrder.invalidateSnapshotCache()
        return (id, suite)
    }

    private func clearHomeVisibilityProfile(_ profile: (id: String, suite: UserDefaults)) {
        TVHomeCatalogOrder.clearOrder()
        HomeCatalogPayloadStore.removeAll(in: profile.suite, profileID: profile.id)
        LargePayloadStore.remove(
            key: "nuvio.tv.collections.json.\(profile.id)",
            directory: "CollectionsStore"
        )
        LargePayloadStore.remove(
            key: "nuvio.tv.collections.lastPulledIds.\(profile.id)",
            directory: "CollectionsStore"
        )
        TVHomeCatalogOrder.invalidateSnapshotCache()
        CollectionsStore.setActiveProfile(nil)
        ProfileSettings.clearActiveProfile()
        profile.suite.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profile.id)")
    }

    private func applyFolderSource(
        parentID: String,
        addonIdentifier: String,
        contentType: String,
        catalogID: String
    ) throws {
        let payload: [[String: Any]] = [[
            "id": parentID,
            "title": "Parent",
            "folders": [[
                "id": "folder",
                "title": "Folder",
                "sources": [[
                    "provider": "addon",
                    "addonId": addonIdentifier,
                    "type": contentType,
                    "catalogId": catalogID
                ]]
            ]]
        ]]
        CollectionsStore.applyRemote(try JSONSerialization.data(withJSONObject: payload))
    }

    private func snapshotRow(
        addonID: String = "example.addon",
        type: String = "movie",
        catalogID: String = "popular",
        manifestURL: String? = "https://example.com/manifest.json",
        manifestShowInHome: Bool? = nil
    ) -> TVHomeCatalogOrder.SnapshotRow {
        TVHomeCatalogOrder.SnapshotRow(
            id: "addon_\(addonID)_\(type)_\(catalogID)",
            title: "Popular",
            addonName: "Example Addon",
            addonId: addonID,
            contentType: type,
            catalogId: catalogID,
            manifestURL: manifestURL,
            manifestShowInHome: manifestShowInHome,
            settingsKey: TVHomeCatalogOrder.catalogSettingsKey(
                addonId: addonID,
                contentType: type,
                catalogId: catalogID
            )
        )
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

    func testRestoreRestoresLoadedTitleFromPlaceholderKey() {
        let rowID = "top-picks-movies"
        let placeholderKey = TVHomeCardIdentity.placeholderKey(rowID: rowID, index: 1)
        let loadedRow = TVHomeFocusRow(id: rowID, keys: [
            "\(rowID)\u{1}title:movie:m1",
            "\(rowID)\u{1}title:movie:m2",
            "\(rowID)\u{1}title:movie:m3"
        ])
        XCTAssertEqual(
            TVHomeFocusRestoration.target(saved: placeholderKey, rows: [loadedRow], preferredIndex: 1),
            "\(rowID)\u{1}title:movie:m2"
        )
    }

    func testRestoreSupportsRowIDsContainingSeparators() {
        let row = TVHomeFocusRow(id: "row\u{1}nested", keys: ["row\u{1}nested\u{1}b"])
        let other = TVHomeFocusRow(id: "row", keys: ["row\u{1}a"])
        XCTAssertEqual(TVHomeFocusRestoration.target(saved: "row\u{1}nested\u{1}removed", rows: [other, row], preferredIndex: 0), row.keys[0])
    }

    func testOverlayReturnCompletesOnlyForTheCardTheRestoreTargets() {
        let rowID = "popular-movies"
        let target = "\(rowID)\u{1}title:movie:m5"
        let neighbour = "\(rowID)\u{1}title:movie:m4"

        // The restored card may complete the return through either marker.
        XCTAssertTrue(TVHomeOverlayFocusRestore.isTarget(target, restoringCardID: target, lockedCardID: target))
        XCTAssertTrue(TVHomeOverlayFocusRestore.isTarget(target, restoringCardID: target, lockedCardID: nil))
        XCTAssertTrue(TVHomeOverlayFocusRestore.isTarget(target, restoringCardID: nil, lockedCardID: target))

        // A neighbouring card that wins native focus mid-transition must not
        // be accepted while the lock is held, or the return lands on it and the
        // retries that would re-assert the target are cancelled.
        XCTAssertFalse(TVHomeOverlayFocusRestore.isTarget(neighbour, restoringCardID: target, lockedCardID: target))
        XCTAssertFalse(TVHomeOverlayFocusRestore.isTarget(target, restoringCardID: nil, lockedCardID: nil))
        XCTAssertFalse(TVHomeOverlayFocusRestore.isTarget(neighbour, restoringCardID: nil, lockedCardID: nil))
    }

    func testOverlayReturnRequiresNativeFocusAcknowledgementToComplete() {
        let target = "popular-movies\u{1}title:movie:m5"
        let neighbour = "popular-movies\u{1}title:movie:m4"

        XCTAssertFalse(TVHomeOverlayFocusRestore.canComplete(
            target,
            restoringCardID: target,
            lockedCardID: target
        ))
        XCTAssertFalse(TVHomeOverlayFocusRestore.canComplete(
            target,
            restoringCardID: target,
            lockedCardID: target,
            acknowledgedNativeCardID: neighbour
        ))
        XCTAssertFalse(TVHomeOverlayFocusRestore.canComplete(
            neighbour,
            restoringCardID: target,
            lockedCardID: target,
            acknowledgedNativeCardID: neighbour
        ))
        XCTAssertTrue(TVHomeOverlayFocusRestore.canComplete(
            target,
            restoringCardID: target,
            lockedCardID: target,
            acknowledgedNativeCardID: target
        ))
        XCTAssertFalse(TVHomeOverlayFocusRestore.canComplete(
            target,
            restoringCardID: nil,
            lockedCardID: nil,
            acknowledgedNativeCardID: target
        ))
    }

    func testTwoStepBackToggleReturnsToRowBeginningThenMovesToContinueWatchingWithoutAffectingHorizontalScroll() {
        let cwSectionID = TVHomeSection.continueWatchingId
        let cwFirstCardKey = "\(cwSectionID)\u{1}title:movie:cw0"
        let cwTargetCardKey = "\(cwSectionID)\u{1}title:movie:cw3"

        let catalogSectionID = "popular-movies"
        let catalogFirstCardKey = "\(catalogSectionID)\u{1}title:movie:m0"
        let catalogFocusedCardKey = "\(catalogSectionID)\u{1}title:movie:m5"

        // First press: user is at index 5 of popular-movies (not at the beginning).
        // Must return to the beginning of the current row (catalogFirstCardKey).
        let step1 = TVHomeBackNavigation.determineAction(
            focusedCardID: catalogFocusedCardKey,
            currentSectionID: catalogSectionID,
            currentRowFirstCardKey: catalogFirstCardKey,
            currentRowScrollIndex: 5,
            isGridHeroFocused: false,
            hasGridHero: false,
            continueWatchingOrTopSectionID: cwSectionID,
            continueWatchingOrTopTargetCardKey: cwTargetCardKey
        )
        XCTAssertEqual(
            step1,
            .returnToRowBeginning(sectionID: catalogSectionID, cardKey: catalogFirstCardKey)
        )

        // Second press: user is now at the beginning of popular-movies (index 0).
        // Must move to Continue Watching without resetting its horizontal scroll (targeting cwTargetCardKey at index 3).
        let step2 = TVHomeBackNavigation.determineAction(
            focusedCardID: catalogFirstCardKey,
            currentSectionID: catalogSectionID,
            currentRowFirstCardKey: catalogFirstCardKey,
            currentRowScrollIndex: 0,
            isGridHeroFocused: false,
            hasGridHero: false,
            continueWatchingOrTopSectionID: cwSectionID,
            continueWatchingOrTopTargetCardKey: cwTargetCardKey
        )
        XCTAssertEqual(
            step2,
            .moveToContinueWatchingOrTop(sectionID: cwSectionID, cardKey: cwTargetCardKey)
        )

        // Once at Continue Watching at index 3 (scrolled):
        // Press 3 returns to the beginning of Continue Watching (index 0).
        let step3 = TVHomeBackNavigation.determineAction(
            focusedCardID: cwTargetCardKey,
            currentSectionID: cwSectionID,
            currentRowFirstCardKey: cwFirstCardKey,
            currentRowScrollIndex: 3,
            isGridHeroFocused: false,
            hasGridHero: false,
            continueWatchingOrTopSectionID: cwSectionID,
            continueWatchingOrTopTargetCardKey: cwTargetCardKey
        )
        XCTAssertEqual(
            step3,
            .returnToRowBeginning(sectionID: cwSectionID, cardKey: cwFirstCardKey)
        )

        // Press 4: user is at the beginning of Continue Watching (index 0).
        // Must exit to sidebar.
        let step4 = TVHomeBackNavigation.determineAction(
            focusedCardID: cwFirstCardKey,
            currentSectionID: cwSectionID,
            currentRowFirstCardKey: cwFirstCardKey,
            currentRowScrollIndex: 0,
            isGridHeroFocused: false,
            hasGridHero: false,
            continueWatchingOrTopSectionID: cwSectionID,
            continueWatchingOrTopTargetCardKey: cwFirstCardKey
        )
        XCTAssertEqual(step4, .exitToSidebar)
    }

    func testTwoStepBackToggleWhenAlreadyAtBeginningOfCatalogRowMovesDirectlyToContinueWatching() {
        let cwSectionID = TVHomeSection.continueWatchingId
        let cwTargetCardKey = "\(cwSectionID)\u{1}title:movie:cw2"

        let catalogSectionID = "trending"
        let catalogFirstCardKey = "\(catalogSectionID)\u{1}title:movie:t0"

        // User is already at index 0 of trending. Press immediately moves to Continue Watching.
        let action = TVHomeBackNavigation.determineAction(
            focusedCardID: catalogFirstCardKey,
            currentSectionID: catalogSectionID,
            currentRowFirstCardKey: catalogFirstCardKey,
            currentRowScrollIndex: 0,
            isGridHeroFocused: false,
            hasGridHero: false,
            continueWatchingOrTopSectionID: cwSectionID,
            continueWatchingOrTopTargetCardKey: cwTargetCardKey
        )
        XCTAssertEqual(
            action,
            .moveToContinueWatchingOrTop(sectionID: cwSectionID, cardKey: cwTargetCardKey)
        )
    }

    func testBackToggleWithGridHeroMovesToHeroThenExitsToSidebar() {
        let topSectionID = "trending"
        let topFirstCardKey = "\(topSectionID)\u{1}title:movie:t0"

        // User is at beginning of top section, with Grid Hero active.
        let step1 = TVHomeBackNavigation.determineAction(
            focusedCardID: topFirstCardKey,
            currentSectionID: topSectionID,
            currentRowFirstCardKey: topFirstCardKey,
            currentRowScrollIndex: 0,
            isGridHeroFocused: false,
            hasGridHero: true,
            continueWatchingOrTopSectionID: topSectionID,
            continueWatchingOrTopTargetCardKey: topFirstCardKey
        )
        XCTAssertEqual(step1, .focusGridHero)

        // User is on Grid Hero. Next Back exits to sidebar.
        let step2 = TVHomeBackNavigation.determineAction(
            focusedCardID: nil,
            currentSectionID: nil,
            currentRowFirstCardKey: nil,
            currentRowScrollIndex: 0,
            isGridHeroFocused: true,
            hasGridHero: true,
            continueWatchingOrTopSectionID: topSectionID,
            continueWatchingOrTopTargetCardKey: topFirstCardKey
        )
        XCTAssertEqual(step2, .exitToSidebar)
    }

    func testBackToggleWhenScrolledFarHorizontallyReturnsToFirstCardInRow() {
        let cwSectionID = TVHomeSection.continueWatchingId
        let cwTargetCardKey = "\(cwSectionID)\u{1}title:movie:cw0"

        let catalogSectionID = "popular-movies"
        let catalogFirstCardKey = "\(catalogSectionID)\u{1}title:movie:m0"
        let farScrolledCardKey = "\(catalogSectionID)\u{1}title:movie:m18"

        // User is scrolled far horizontally (e.g. index 18) in the catalog row.
        // First back press MUST return to the first card in the row (index 0).
        let step1 = TVHomeBackNavigation.determineAction(
            focusedCardID: farScrolledCardKey,
            currentSectionID: catalogSectionID,
            currentRowFirstCardKey: catalogFirstCardKey,
            currentRowScrollIndex: 18,
            isGridHeroFocused: false,
            hasGridHero: false,
            continueWatchingOrTopSectionID: cwSectionID,
            continueWatchingOrTopTargetCardKey: cwTargetCardKey
        )
        XCTAssertEqual(
            step1,
            .returnToRowBeginning(sectionID: catalogSectionID, cardKey: catalogFirstCardKey)
        )

        // Focus restoration targets catalogFirstCardKey via focus restriction,
        // which forces row materialization and scrollIndex alignment to 0.
        // Second press: user is now at index 0 of the row. Back moves to Continue Watching.
        let step2 = TVHomeBackNavigation.determineAction(
            focusedCardID: catalogFirstCardKey,
            currentSectionID: catalogSectionID,
            currentRowFirstCardKey: catalogFirstCardKey,
            currentRowScrollIndex: 0,
            isGridHeroFocused: false,
            hasGridHero: false,
            continueWatchingOrTopSectionID: cwSectionID,
            continueWatchingOrTopTargetCardKey: cwTargetCardKey
        )
        XCTAssertEqual(
            step2,
            .moveToContinueWatchingOrTop(sectionID: cwSectionID, cardKey: cwTargetCardKey)
        )
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

    func testContinueWatchingVisibleSetting() {
        XCTAssertEqual(SettingsKey.continueWatchingVisible, "nuvio.tv.settings.layout.continueWatchingVisible")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.continueWatchingVisible))

        let defaults = UserDefaults(suiteName: "ContinueWatchingVisibleTestsDefaults")!
        defaults.removePersistentDomain(forName: "ContinueWatchingVisibleTestsDefaults")

        // Default should be true (on)
        let isVisibleDefault = defaults.object(forKey: SettingsKey.continueWatchingVisible) as? Bool ?? true
        XCTAssertTrue(isVisibleDefault)

        // Can be toggled to false
        defaults.set(false, forKey: SettingsKey.continueWatchingVisible)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.continueWatchingVisible))

        // Can be toggled back to true
        defaults.set(true, forKey: SettingsKey.continueWatchingVisible)
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.continueWatchingVisible))
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

    func testLandscapePostersSetting() {
        XCTAssertEqual(SettingsKey.landscapePosters, "nuvio.tv.settings.layout.landscapePosters")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.landscapePosters))

        let defaults = UserDefaults(suiteName: "LandscapePostersTestsDefaults")!
        defaults.removePersistentDomain(forName: "LandscapePostersTestsDefaults")

        // Default should be false
        let isLandscapeDefault = defaults.object(forKey: SettingsKey.landscapePosters) as? Bool ?? false
        XCTAssertFalse(isLandscapeDefault)

        defaults.set(true, forKey: SettingsKey.landscapePosters)
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.landscapePosters))

        defaults.set(false, forKey: SettingsKey.landscapePosters)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.landscapePosters))
    }

    func testContinueWatchingLandscapeSetting() {
        XCTAssertEqual(SettingsKey.continueWatchingLandscape, "nuvio.tv.settings.layout.continueWatchingLandscape")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.continueWatchingLandscape))

        let defaults = UserDefaults(suiteName: "ContinueWatchingLandscapeTestsDefaults")!
        defaults.removePersistentDomain(forName: "ContinueWatchingLandscapeTestsDefaults")

        // Default should be false
        let isCWLandscapeDefault = defaults.object(forKey: SettingsKey.continueWatchingLandscape) as? Bool ?? false
        XCTAssertFalse(isCWLandscapeDefault)

        defaults.set(true, forKey: SettingsKey.continueWatchingLandscape)
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.continueWatchingLandscape))

        defaults.set(false, forKey: SettingsKey.continueWatchingLandscape)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.continueWatchingLandscape))
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

    func testTVCatalogRowEquatableChecksExplicitTileShape() {
        let rowPortrait = TVCatalogRow(
            id: "catalog-1",
            title: "Popular Movies",
            addonName: "Cinemeta",
            showAddonName: true,
            horizontalEdgeInset: 40,
            items: [],
            initialFocusCardKey: nil,
            landscapeFocusedId: nil,
            explicitTileShape: .poster,
            onInitialFocusRequested: {},
            onFocus: { _ in },
            onBlur: { _ in },
            onApproachEnd: { _ in },
            onSelect: { _ in }
        )

        let rowLandscape = TVCatalogRow(
            id: "catalog-1",
            title: "Popular Movies",
            addonName: "Cinemeta",
            showAddonName: true,
            horizontalEdgeInset: 40,
            items: [],
            initialFocusCardKey: nil,
            landscapeFocusedId: nil,
            explicitTileShape: .landscape,
            onInitialFocusRequested: {},
            onFocus: { _ in },
            onBlur: { _ in },
            onApproachEnd: { _ in },
            onSelect: { _ in }
        )

        XCTAssertNotEqual(rowPortrait, rowLandscape)
    }

    func testPosterCardEquatableChecksCardIndex() throws {
        let meta = try title("item1")
        let cardAt0 = PosterCard(meta: meta, cardIndex: 0) {}
        let cardAt1 = PosterCard(meta: meta, cardIndex: 1) {}
        let cardAt0Again = PosterCard(meta: meta, cardIndex: 0) {}

        XCTAssertNotEqual(cardAt0, cardAt1)
        XCTAssertEqual(cardAt0, cardAt0Again)
    }

    func testPosterCardEquatableChecksLandscapePosterURL() throws {
        let withoutLandscape = PosterCard(meta: try title("item1")) {}
        let withLandscape = PosterCard(meta: try title("item1", landscapePosterUrl: "https://example.com/landscape.jpg")) {}
        let withChangedLandscape = PosterCard(meta: try title("item1", landscapePosterUrl: "https://example.com/changed-landscape.jpg")) {}
        let withoutLandscapeAgain = PosterCard(meta: try title("item1")) {}

        XCTAssertEqual(withoutLandscape, withoutLandscapeAgain)
        XCTAssertNotEqual(withoutLandscape, withLandscape)
        XCTAssertNotEqual(withLandscape, withChangedLandscape)
        XCTAssertNotEqual(withLandscape, withoutLandscapeAgain)
    }

    func testPosterCardEquatableChecksCustomPosterScreen() throws {
        let meta = try title("item1")
        let homeCard = PosterCard(meta: meta, customPosterScreen: .home) {}
        let searchCard = PosterCard(meta: meta, customPosterScreen: .search) {}

        XCTAssertNotEqual(homeCard, searchCard)
    }

    func testTVCatalogRowEquatableChecksLandscapePosterURL() throws {
        func row(item: NuvioMeta) -> TVCatalogRow {
            TVCatalogRow(
                id: "catalog-1",
                title: "Popular Movies",
                horizontalEdgeInset: 40,
                items: [item],
                initialFocusCardKey: nil,
                landscapeFocusedId: nil,
                onInitialFocusRequested: {},
                onFocus: { _ in },
                onBlur: { _ in },
                onApproachEnd: { _ in },
                onSelect: { _ in }
            )
        }

        let withoutLandscape = row(item: try title("item1"))
        let withLandscape = row(item: try title("item1", landscapePosterUrl: "https://example.com/landscape.jpg"))
        let withChangedLandscape = row(item: try title("item1", landscapePosterUrl: "https://example.com/changed-landscape.jpg"))
        let withoutLandscapeAgain = row(item: try title("item1"))

        XCTAssertEqual(withoutLandscape, withoutLandscapeAgain)
        XCTAssertNotEqual(withoutLandscape, withLandscape)
        XCTAssertNotEqual(withLandscape, withChangedLandscape)
        XCTAssertNotEqual(withLandscape, withoutLandscapeAgain)
    }

    func testTVCatalogRowEquatableChecksCustomPosterScreen() {
        func row(screen: CustomPosterScreen) -> TVCatalogRow {
            TVCatalogRow(
                id: "catalog-1",
                customPosterScreen: screen,
                title: "Popular Movies",
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
        }

        XCTAssertNotEqual(row(screen: .home), row(screen: .search))
    }

    func testTVCollectionFolderCardEquatableChecksCardIndex() throws {
        let decoded = try JSONDecoder().decode(NuvioCollectionFolder.self, from: Data(#"{"id":"folder","title":"Folder"}"#.utf8))
        let folder = TVCollectionFolderItem(collectionId: "one", folder: decoded, sources: [])
        let cardAt0 = TVCollectionFolderCard(folder: folder, cardIndex: 0) {}
        let cardAt1 = TVCollectionFolderCard(folder: folder, cardIndex: 1) {}
        let cardAt0Again = TVCollectionFolderCard(folder: folder, cardIndex: 0) {}

        XCTAssertNotEqual(cardAt0, cardAt1)
        XCTAssertEqual(cardAt0, cardAt0Again)
    }

    func testPosterCardEquatableInvalidatesCapturedFocusCallbackContext() throws {
        let meta = try title("item1")
        let cardKey = "catalog-1\u{1}item1"
        let neighborKey = "catalog-1\u{1}item2"

        func card(
            key: String = cardKey,
            restriction: String?,
            suppressFocusAnimations: Bool = false
        ) -> PosterCard {
            PosterCard(
                meta: meta,
                externalFocusValue: key,
                smoothFocusAnimations: false,
                allowsFocus: restriction == nil || restriction == key,
                focusCallbackContext: TVCardFocusCallbackContext(
                    restrictFocusToCardKey: restriction,
                    suppressFocusAnimations: suppressFocusAnimations
                )
            ) {}
        }

        let lockedTarget = card(restriction: cardKey)
        let unlockedTarget = card(restriction: nil)
        XCTAssertTrue(lockedTarget.allowsFocus)
        XCTAssertTrue(unlockedTarget.allowsFocus)
        XCTAssertNotEqual(lockedTarget, unlockedTarget)

        let targetAfterLockRetarget = card(restriction: neighborKey)
        XCTAssertFalse(targetAfterLockRetarget.allowsFocus)
        XCTAssertNotEqual(lockedTarget, targetAfterLockRetarget)

        let neighborBeforeRetarget = card(key: neighborKey, restriction: cardKey)
        let neighborAfterRetarget = card(key: neighborKey, restriction: neighborKey)
        XCTAssertFalse(neighborBeforeRetarget.allowsFocus)
        XCTAssertTrue(neighborAfterRetarget.allowsFocus)
        XCTAssertNotEqual(neighborBeforeRetarget, neighborAfterRetarget)

        let suppressed = card(restriction: cardKey, suppressFocusAnimations: true)
        let unsuppressed = card(restriction: cardKey, suppressFocusAnimations: false)
        XCTAssertFalse(suppressed.smoothFocusAnimations)
        XCTAssertFalse(unsuppressed.smoothFocusAnimations)
        XCTAssertTrue(suppressed.allowsFocus)
        XCTAssertTrue(unsuppressed.allowsFocus)
        XCTAssertNotEqual(suppressed, unsuppressed)
    }

    func testTVCollectionFolderCardEquatableInvalidatesCapturedFocusCallbackContext() throws {
        let decoded = try JSONDecoder().decode(NuvioCollectionFolder.self, from: Data(#"{"id":"folder","title":"Folder"}"#.utf8))
        let folder = TVCollectionFolderItem(collectionId: "one", folder: decoded, sources: [])
        let cardKey = "folder-row\u{1}folder"
        let neighborKey = "folder-row\u{1}neighbor"

        func card(
            key: String = cardKey,
            restriction: String?,
            suppressFocusAnimations: Bool = false
        ) -> TVCollectionFolderCard {
            TVCollectionFolderCard(
                folder: folder,
                externalFocusValue: key,
                smoothFocusAnimations: false,
                allowsFocus: restriction == nil || restriction == key,
                focusCallbackContext: TVCardFocusCallbackContext(
                    restrictFocusToCardKey: restriction,
                    suppressFocusAnimations: suppressFocusAnimations
                )
            ) {}
        }

        let lockedTarget = card(restriction: cardKey)
        let unlockedTarget = card(restriction: nil)
        XCTAssertTrue(lockedTarget.allowsFocus)
        XCTAssertTrue(unlockedTarget.allowsFocus)
        XCTAssertNotEqual(lockedTarget, unlockedTarget)

        let targetAfterLockRetarget = card(restriction: neighborKey)
        XCTAssertFalse(targetAfterLockRetarget.allowsFocus)
        XCTAssertNotEqual(lockedTarget, targetAfterLockRetarget)

        let neighborBeforeRetarget = card(key: neighborKey, restriction: cardKey)
        let neighborAfterRetarget = card(key: neighborKey, restriction: neighborKey)
        XCTAssertFalse(neighborBeforeRetarget.allowsFocus)
        XCTAssertTrue(neighborAfterRetarget.allowsFocus)
        XCTAssertNotEqual(neighborBeforeRetarget, neighborAfterRetarget)

        let suppressed = card(restriction: cardKey, suppressFocusAnimations: true)
        let unsuppressed = card(restriction: cardKey, suppressFocusAnimations: false)
        XCTAssertFalse(suppressed.smoothFocusAnimations)
        XCTAssertFalse(unsuppressed.smoothFocusAnimations)
        XCTAssertTrue(suppressed.allowsFocus)
        XCTAssertTrue(unsuppressed.allowsFocus)
        XCTAssertNotEqual(suppressed, unsuppressed)
    }

    func testTVCollectionFolderRowEquatableChecksExternalRestrictionPresence() throws {
        let decoded = try JSONDecoder().decode(NuvioCollectionFolder.self, from: Data(#"{"id":"folder","title":"Folder"}"#.utf8))
        let folder = TVCollectionFolderItem(collectionId: "one", folder: decoded, sources: [])

        func row(restriction: String?) -> TVCollectionFolderRow {
            TVCollectionFolderRow(
                id: "folder-row",
                title: "Folders",
                horizontalEdgeInset: 40,
                folders: [folder],
                initialScrollIndex: 0,
                onScrollIndexChange: { _ in },
                initialFocusCardKey: nil,
                restrictFocusToCardKey: restriction,
                onInitialFocusRequested: {},
                onFocus: { _ in },
                onSelect: { _ in }
            )
        }

        XCTAssertNotEqual(row(restriction: "another-row\u{1}one"), row(restriction: nil))
        XCTAssertEqual(row(restriction: "another-row\u{1}one"), row(restriction: "another-row\u{1}two"))
    }

    func testClearCatalogOrder() {
        let order = ["addon_1", "addon_2"]
        let orderData = try! JSONEncoder().encode(order)
        _ = HomeCatalogPayloadStore.write(orderData, forKey: SettingsKey.homeCatalogOrder)
        let deletedData = try! JSONEncoder().encode(["deleted_key"])
        _ = HomeCatalogPayloadStore.write(deletedData, forKey: SettingsKey.homeCatalogDeleted)

        TVHomeCatalogOrder.clearOrder()

        XCTAssertNil(HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogOrder))
        XCTAssertNil(HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogSyncedOrder))
        XCTAssertNil(HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogDeleted))
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
        let orderData = try! JSONEncoder().encode(order)
        _ = HomeCatalogPayloadStore.write(orderData, forKey: SettingsKey.homeCatalogOrder)

        // Execute clearCache
        await AppCacheManager.clearCache()

        // Verify catalog order is wiped
        XCTAssertNil(HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogOrder))

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
        _ = HomeCatalogPayloadStore.write(data, forKey: SettingsKey.homeCatalogSyncedOrder)
        HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogOrder)

        let ordered = TVHomeCatalogOrder.apply(to: [cinemetaSection, xperienceSection])
        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered[0].id, "addon_xperience_series_top")
        XCTAssertEqual(ordered[1].id, "movie_top")

        // Clean up
        HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogSyncedOrder)
    }

    func testDisabledAddonSourcesRemainInUserDefaults() {
        let store = ProfileSettings.current
        let previousIDs = store.data(forKey: SettingsKey.homeCatalogDisabledAddonIDs)
        let previousNames = store.data(forKey: SettingsKey.homeCatalogDisabledAddonNames)
        defer {
            if let previousIDs {
                store.set(previousIDs, forKey: SettingsKey.homeCatalogDisabledAddonIDs)
            } else {
                store.removeObject(forKey: SettingsKey.homeCatalogDisabledAddonIDs)
            }
            if let previousNames {
                store.set(previousNames, forKey: SettingsKey.homeCatalogDisabledAddonNames)
            } else {
                store.removeObject(forKey: SettingsKey.homeCatalogDisabledAddonNames)
            }
        }

        TVHomeCatalogOrder.setDisabledAddonSources(ids: ["test.addon"], names: ["Test Addon"])

        XCTAssertEqual(TVHomeCatalogOrder.disabledAddonIDs(), ["test.addon"])
        XCTAssertEqual(TVHomeCatalogOrder.disabledAddonNames(), ["testaddon"])
        XCTAssertNotNil(store.data(forKey: SettingsKey.homeCatalogDisabledAddonIDs))
        XCTAssertNotNil(store.data(forKey: SettingsKey.homeCatalogDisabledAddonNames))
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
        let savedDisabledCatalogs = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogDisabled)
        let savedDisabledAddons = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogDisabledAddonIDs)
        let savedDisabledNames = ProfileSettings.current.data(forKey: SettingsKey.homeCatalogDisabledAddonNames)
        defer {
            ProfileSettings.current.set(savedPrefs, forKey: SettingsKey.streamAddonManifestStates)
            ProfileSettings.current.set(savedURLs, forKey: SettingsKey.streamAddonManifestURLs)
            ProfileSettings.current.set(savedSingleURL, forKey: SettingsKey.streamAddonManifestURL)
            if let savedDisabledCatalogs {
                _ = HomeCatalogPayloadStore.write(savedDisabledCatalogs, forKey: SettingsKey.homeCatalogDisabled)
            } else {
                HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogDisabled)
            }
            ProfileSettings.current.set(savedDisabledAddons, forKey: SettingsKey.homeCatalogDisabledAddonIDs)
            ProfileSettings.current.set(savedDisabledNames, forKey: SettingsKey.homeCatalogDisabledAddonNames)
            CinemetaCatalogRepository.setCinemetaDisabled(false)
        }
        ProfileSettings.current.removeObject(forKey: SettingsKey.streamAddonManifestStates)
        ProfileSettings.current.removeObject(forKey: SettingsKey.streamAddonManifestURLs)
        ProfileSettings.current.removeObject(forKey: SettingsKey.streamAddonManifestURL)
        HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogDisabled)
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

    func testBatchReplaceSnapshotRowsAtomicallyAppliesMultipleAddonUpdates() {
        let addon1Catalog = TVHomeCatalogOrder.SnapshotRow(
            id: "addon_org.stremio.addon1_movie_top",
            title: "Addon1 Top Movies",
            addonName: "Addon1",
            addonId: "org.stremio.addon1",
            contentType: "movie",
            catalogId: "top",
            settingsKey: "org.stremio.addon1_movie_top"
        )
        let addon2Catalog = TVHomeCatalogOrder.SnapshotRow(
            id: "addon_org.stremio.addon2_series_popular",
            title: "Addon2 Popular Series",
            addonName: "Addon2",
            addonId: "org.stremio.addon2",
            contentType: "series",
            catalogId: "popular",
            settingsKey: "org.stremio.addon2_series_popular"
        )

        TVHomeCatalogOrder.batchReplaceSnapshotRows([
            (addonID: "org.stremio.addon1", addonName: "Addon1", additions: [addon1Catalog]),
            (addonID: "org.stremio.addon2", addonName: "Addon2", additions: [addon2Catalog])
        ])

        let rows = TVHomeCatalogOrder.snapshotRows()
        XCTAssertTrue(rows.contains(where: { $0.id == addon1Catalog.id }))
        XCTAssertTrue(rows.contains(where: { $0.id == addon2Catalog.id }))

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
        HomeCatalogPayloadStore.removeAll(in: store, profileID: profileId)
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

        guard let data = HomeCatalogPayloadStore.data(
            forKey: SettingsKey.homeCatalogCustomTitles,
            in: store,
            profileID: profileId
        ),
              let titles = try? JSONDecoder().decode([String: String].self, from: data) else {
            XCTFail("Custom titles not saved to store")
            return
        }
        XCTAssertEqual(titles["com.aio.metadata_series_top_20"], "Top 20 TV Shows of the Week")

        // Clean up
        HomeCatalogPayloadStore.removeAll(in: store, profileID: profileId)
        store.removeObject(forKey: SettingsKey.homeCatalogShowType)
    }

    func testHomeCatalogPayloadStoreMigratesLegacyDataAndIsolatesProfiles() throws {
        let firstProfileID = "test-home-payload-first-\(UUID().uuidString)"
        let secondProfileID = "test-home-payload-second-\(UUID().uuidString)"
        let firstStore = ProfileSettings.store(for: firstProfileID)
        let secondStore = ProfileSettings.store(for: secondProfileID)
        let defaultProfileStore = ProfileSettings.store(for: "default")
        let previousStandardOrder = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogOrder, in: .standard)
        let previousDefaultProfileOrder = HomeCatalogPayloadStore.data(
            forKey: SettingsKey.homeCatalogOrder,
            in: defaultProfileStore,
            profileID: "default"
        )
        defer {
            HomeCatalogPayloadStore.removeAll(in: firstStore, profileID: firstProfileID)
            HomeCatalogPayloadStore.removeAll(in: secondStore, profileID: secondProfileID)
            firstStore.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(firstProfileID)")
            secondStore.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(secondProfileID)")
            if let previousStandardOrder {
                _ = HomeCatalogPayloadStore.write(previousStandardOrder, forKey: SettingsKey.homeCatalogOrder, in: .standard)
            } else {
                HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogOrder, in: .standard)
            }
            if let previousDefaultProfileOrder {
                _ = HomeCatalogPayloadStore.write(
                    previousDefaultProfileOrder,
                    forKey: SettingsKey.homeCatalogOrder,
                    in: defaultProfileStore,
                    profileID: "default"
                )
            } else {
                HomeCatalogPayloadStore.remove(
                    forKey: SettingsKey.homeCatalogOrder,
                    in: defaultProfileStore,
                    profileID: "default"
                )
            }
        }

        let legacyOrder = try JSONEncoder().encode(["legacy_catalog"])
        firstStore.set(legacyOrder, forKey: SettingsKey.homeCatalogOrder)
        HomeCatalogPayloadStore.migrateLegacyPreferences(in: firstStore, profileID: firstProfileID)

        XCTAssertNil(firstStore.data(forKey: SettingsKey.homeCatalogOrder))
        XCTAssertEqual(
            HomeCatalogPayloadStore.data(
                forKey: SettingsKey.homeCatalogOrder,
                in: firstStore,
                profileID: firstProfileID
            ),
            legacyOrder
        )

        // A downgraded app can leave a newer defaults copy beside an older file.
        let downgradedOrder = try JSONEncoder().encode(["downgraded_catalog"])
        firstStore.set(downgradedOrder, forKey: SettingsKey.homeCatalogOrder)
        XCTAssertEqual(
            HomeCatalogPayloadStore.data(
                forKey: SettingsKey.homeCatalogOrder,
                in: firstStore,
                profileID: firstProfileID
            ),
            downgradedOrder
        )
        XCTAssertNil(firstStore.data(forKey: SettingsKey.homeCatalogOrder))

        let standardOrder = try JSONEncoder().encode(["global_catalog"])
        let defaultProfileOrder = try JSONEncoder().encode(["default_profile_catalog"])
        XCTAssertTrue(HomeCatalogPayloadStore.write(
            standardOrder,
            forKey: SettingsKey.homeCatalogOrder,
            in: .standard
        ))
        XCTAssertTrue(HomeCatalogPayloadStore.write(
            defaultProfileOrder,
            forKey: SettingsKey.homeCatalogOrder,
            in: defaultProfileStore,
            profileID: "default"
        ))
        XCTAssertEqual(
            HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogOrder, in: .standard),
            standardOrder
        )
        XCTAssertEqual(
            HomeCatalogPayloadStore.data(
                forKey: SettingsKey.homeCatalogOrder,
                in: defaultProfileStore,
                profileID: "default"
            ),
            defaultProfileOrder
        )

        let secondOrder = try JSONEncoder().encode(["second_profile_catalog"])
        XCTAssertTrue(HomeCatalogPayloadStore.write(
            secondOrder,
            forKey: SettingsKey.homeCatalogOrder,
            in: secondStore,
            profileID: secondProfileID
        ))
        XCTAssertEqual(
            HomeCatalogPayloadStore.data(
                forKey: SettingsKey.homeCatalogOrder,
                in: secondStore,
                profileID: secondProfileID
            ),
            secondOrder
        )
        XCTAssertEqual(
            HomeCatalogPayloadStore.data(
                forKey: SettingsKey.homeCatalogOrder,
                in: firstStore,
                profileID: firstProfileID
            ),
            downgradedOrder
        )
    }

    func testApplyHomeCatalogSettingsStoresOversizedPayloadOutsideUserDefaults() throws {
        let profileID = "test-home-payload-large-\(UUID().uuidString)"
        let store = ProfileSettings.store(for: profileID)
        defer {
            HomeCatalogPayloadStore.removeAll(in: store, profileID: profileID)
            store.removeObject(forKey: SettingsKey.homeCatalogShowType)
            store.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
        }

        let items: [[String: Any]] = (0..<8_000).map { index in
            [
                "addon_id": "test.addon.\(index)",
                "type": "movie",
                "catalog_id": "catalog_\(index)",
                "custom_title": "Catalog \(index) " + String(repeating: "T", count: 180),
                "enabled": true,
                "order": index
            ]
        }
        let payload = HomeCatalogSyncPayload(dictionary: [
            "items": items,
            "show_catalog_type": false
        ])

        XCTAssertTrue(NuvioSyncManager.applyHomeCatalogSettings(payload, localProfileId: profileID))
        XCTAssertFalse(NuvioSyncManager.applyHomeCatalogSettings(payload, localProfileId: profileID))
        XCTAssertNil(store.data(forKey: SettingsKey.homeCatalogSyncedOrder))
        XCTAssertNil(store.data(forKey: SettingsKey.homeCatalogDisabled))
        XCTAssertNil(store.data(forKey: SettingsKey.homeCollectionDisabled))
        XCTAssertNil(store.data(forKey: SettingsKey.homeCatalogCustomTitles))

        let customTitlesData = try XCTUnwrap(HomeCatalogPayloadStore.data(
            forKey: SettingsKey.homeCatalogCustomTitles,
            in: store,
            profileID: profileID
        ))
        XCTAssertGreaterThan(customTitlesData.count, 1024 * 1024)
        let customTitles = try JSONDecoder().decode([String: String].self, from: customTitlesData)
        XCTAssertEqual(customTitles.count, items.count)
        XCTAssertEqual(
            customTitles["test.addon.7999_movie_catalog_7999"],
            "Catalog 7999 " + String(repeating: "T", count: 180)
        )
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
            HomeCatalogPayloadStore.removeAll(in: suite, profileID: profileId)
            suite.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileId)")
        }

        // Simulate legacy unpurged data in the suite before activation
        let dummyData = Data(repeating: 0x41, count: 100_000)
        suite.set(dummyData, forKey: "nuvio.tv.settings.layout.homeCatalogTitles")
        let legacyOrder = try! JSONEncoder().encode(["profile_catalog"])
        suite.set(legacyOrder, forKey: SettingsKey.homeCatalogOrder)

        // Calling store(for:) MUST be completely read-only and not set the profileScopeKey
        let retrievedStore = ProfileSettings.store(for: profileId)
        XCTAssertNil(retrievedStore.string(forKey: "nuvio.tv.profile.settings.profileID"))

        // Activating the profile purges the legacy blob and marks the suite safely
        ProfileSettings.setActiveProfile(profileId, isPrimary: false)
        XCTAssertNil(retrievedStore.data(forKey: "nuvio.tv.settings.layout.homeCatalogTitles"))
        XCTAssertNil(retrievedStore.data(forKey: SettingsKey.homeCatalogOrder))
        XCTAssertEqual(
            HomeCatalogPayloadStore.data(
                forKey: SettingsKey.homeCatalogOrder,
                in: retrievedStore,
                profileID: profileId
            ),
            legacyOrder
        )
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

    func testCatalogInCollectionFolderIsHiddenUnlessExplicitlyEnabled() throws {
        let manifestURL = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        let source = CatalogHomeVisibilityResolver.Source(
            addonIdentifier: "sports.addon",
            contentType: "sports",
            catalogID: "live_streams",
            collectionID: "sports_collection"
        )
        let key = "sports.addon_sports_live_streams"
        XCTAssertFalse(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "sports.addon",
            contentType: "sports",
            catalogID: "live_streams",
            collectionSources: [source],
            manifestURL: manifestURL,
            explicitHomeKeys: []
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "sports.addon",
            contentType: "sports",
            catalogID: "live_streams",
            collectionSources: [source],
            manifestURL: manifestURL,
            explicitHomeKeys: [key]
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "sports.addon",
            contentType: "sports",
            catalogID: "live_streams",
            collectionSources: [source],
            manifestURL: manifestURL,
            explicitHomeKeys: [],
            manifestShowInHome: true
        ))
        XCTAssertFalse(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "sports.addon",
            contentType: "sports",
            catalogID: "live_streams",
            collectionSources: [source],
            manifestURL: manifestURL,
            explicitHomeKeys: [key],
            manifestShowInHome: false
        ))
        XCTAssertFalse(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "sports.addon",
            contentType: "sports",
            catalogID: "live_streams",
            collectionSources: [source],
            manifestURL: manifestURL,
            explicitHomeKeys: [key],
            manifestShowInHome: true,
            disabledHomeKeys: [key]
        ))

        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "other.addon",
            contentType: "sports",
            catalogID: "live_streams",
            collectionSources: [source],
            manifestURL: manifestURL,
            explicitHomeKeys: []
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "sports.addon",
            contentType: "series",
            catalogID: "live_streams",
            collectionSources: [source],
            manifestURL: manifestURL,
            explicitHomeKeys: []
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "sports.addon",
            contentType: "sports",
            catalogID: "other_catalog",
            collectionSources: [source],
            manifestURL: manifestURL,
            explicitHomeKeys: []
        ))

        let cinemeta = CatalogHomeVisibilityResolver.Source(
            addonIdentifier: "cinemeta",
            contentType: "movie",
            catalogID: "top"
        )
        XCTAssertFalse(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "com.linvo.cinemeta",
            contentType: "movie",
            catalogID: "top",
            collectionSources: [cinemeta],
            manifestURL: URL(string: "https://v3-cinemeta.strem.io/manifest.json"),
            explicitHomeKeys: []
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "com.linvo.cinemeta",
            contentType: "series",
            catalogID: "top",
            collectionSources: [cinemeta],
            manifestURL: URL(string: "https://v3-cinemeta.strem.io/manifest.json"),
            explicitHomeKeys: []
        ))

        let urlSource = CatalogHomeVisibilityResolver.Source(
            addonIdentifier: "https://example.com/Path/manifest.json?token=AbC",
            contentType: "movie",
            catalogID: "popular"
        )
        let lowerPathURL = URL(string: "https://example.com/path/manifest.json?token=AbC")
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon",
            contentType: "movie",
            catalogID: "popular",
            collectionSources: [urlSource],
            manifestURL: lowerPathURL,
            explicitHomeKeys: []
        ))
        XCTAssertFalse(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon",
            contentType: "movie",
            catalogID: "popular",
            collectionSources: [urlSource],
            manifestURL: URL(string: "https://example.com/Path/manifest.json?token=AbC"),
            explicitHomeKeys: []
        ))
    }

    func testCollectionSourcesIncludeFoldersUnderHiddenParents() throws {
        let profile = activateHomeVisibilityProfile()
        defer { clearHomeVisibilityProfile(profile) }

        try applyFolderSource(
            parentID: "hidden-parent",
            addonIdentifier: "example.addon",
            contentType: "movie",
            catalogID: "popular"
        )
        let disabledParents = try JSONEncoder().encode(["hidden-parent"])
        XCTAssertTrue(HomeCatalogPayloadStore.write(disabledParents, forKey: SettingsKey.homeCollectionDisabled))

        let sources = CatalogHomeVisibilityResolver.collectionSources()
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.collectionID, "hidden-parent")
        XCTAssertFalse(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon",
            contentType: "movie",
            catalogID: "popular",
            collectionSources: sources,
            manifestURL: URL(string: "https://example.com/manifest.json"),
            explicitHomeKeys: []
        ))
    }

    func testLocalExplicitCatalogIntentAndSyncDoNotInheritAccountOrReorderState() throws {
        let profile = activateHomeVisibilityProfile()
        defer { clearHomeVisibilityProfile(profile) }

        try applyFolderSource(
            parentID: "folder-parent",
            addonIdentifier: "example.addon",
            contentType: "movie",
            catalogID: "popular"
        )
        let row = snapshotRow()
        let key = try XCTUnwrap(row.settingsKey)
        let unrelatedAccountKey = "other.addon_series_trending"
        TVHomeCatalogOrder.writeSnapshotRows([row])
        TVHomeCatalogOrder.save([row.id])

        XCTAssertTrue(TVHomeCatalogOrder.explicitHomeCatalogKeys().isEmpty)
        XCTAssertFalse(TVHomeCatalogOrder.isRowEnabled(row))
        // Folder-backed catalogs remain implicit, but configured collections
        // must sync their own visibility even before Home records their rows.
        let implicitItems = TVHomeCatalogOrder.syncItems()
        XCTAssertFalse(implicitItems.contains { ($0["is_collection"] as? Bool) == false })
        let collectionItem = try XCTUnwrap(implicitItems.first {
            ($0["is_collection"] as? Bool) == true
                && ($0["collection_id"] as? String) == "folder-parent"
        })
        XCTAssertEqual(implicitItems.count, 1)
        XCTAssertEqual(collectionItem["enabled"] as? Bool, true)

        let accountOrder = try JSONEncoder().encode([key, unrelatedAccountKey])
        XCTAssertTrue(HomeCatalogPayloadStore.write(accountOrder, forKey: SettingsKey.homeCatalogSyncedOrder))
        XCTAssertEqual(TVHomeCatalogOrder.explicitHomeCatalogKeys(), [key, unrelatedAccountKey])
        XCTAssertTrue(TVHomeCatalogOrder.isRowEnabled(row))
        XCTAssertEqual(TVHomeCatalogOrder.syncItems().first?["enabled"] as? Bool, true)

        TVHomeCatalogOrder.setRowEnabled(row, isEnabled: true)
        let localData = try XCTUnwrap(HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogExplicitEnabled))
        let localKeys = try JSONDecoder().decode([String].self, from: localData)
        XCTAssertEqual(Set(localKeys), [key])

        XCTAssertTrue(HomeCatalogPayloadStore.write(try JSONEncoder().encode([String]()), forKey: SettingsKey.homeCatalogSyncedOrder))
        XCTAssertEqual(TVHomeCatalogOrder.explicitHomeCatalogKeys(), [key])
        XCTAssertTrue(TVHomeCatalogOrder.isRowEnabled(row))
        XCTAssertEqual(TVHomeCatalogOrder.syncItems().first?["enabled"] as? Bool, true)

        TVHomeCatalogOrder.setRowEnabled(row, isEnabled: false)
        XCTAssertFalse(TVHomeCatalogOrder.explicitHomeCatalogKeys().contains(key))
        XCTAssertTrue(TVHomeCatalogOrder.disabledCatalogKeys().contains(key))
        XCTAssertFalse(TVHomeCatalogOrder.isRowEnabled(row))
        XCTAssertEqual(TVHomeCatalogOrder.syncItems().first?["enabled"] as? Bool, false)

        TVHomeCatalogOrder.setRowEnabled(row, isEnabled: true)
        let disabledWins = try JSONEncoder().encode([key])
        XCTAssertTrue(HomeCatalogPayloadStore.write(disabledWins, forKey: SettingsKey.homeCatalogDisabled))
        XCTAssertFalse(TVHomeCatalogOrder.isRowEnabled(row))

        TVHomeCatalogOrder.clearOrder()
        XCTAssertTrue(TVHomeCatalogOrder.explicitHomeCatalogKeys().isEmpty)
    }

    func testHiddenCollectionSyncsWithoutHomeSnapshotAndKeepsPendingLocalChoice() throws {
        let profile = activateHomeVisibilityProfile()
        defer { clearHomeVisibilityProfile(profile) }

        try applyFolderSource(
            parentID: "hidden-parent",
            addonIdentifier: "example.addon",
            contentType: "movie",
            catalogID: "popular"
        )
        TVHomeCatalogOrder.setCollectionEnabled("hidden-parent", isEnabled: false)
        XCTAssertTrue(TVHomeCatalogOrder.snapshotRows().isEmpty)

        let items = TVHomeCatalogOrder.syncItems()
        let item = try XCTUnwrap(items.first {
            ($0["is_collection"] as? Bool) == true
                && ($0["collection_id"] as? String) == "hidden-parent"
        })
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(item["enabled"] as? Bool, false)

        // A stale remote enabled value must not override the explicit choice.
        XCTAssertTrue(HomeCatalogPayloadStore.write(
            try JSONEncoder().encode([String]()),
            forKey: SettingsKey.homeCollectionDisabled
        ))
        TVHomeCatalogOrder.acknowledgeCollectionVisibility([], in: profile.suite)
        TVHomeCatalogOrder.acknowledgeCollectionVisibility(
            [(id: "hidden-parent", enabled: true)], in: profile.suite
        )
        XCTAssertEqual(TVHomeCatalogOrder.pendingCollectionVisibility()["hidden-parent"], false)
        XCTAssertTrue(TVHomeCatalogOrder.disabledCollectionIds().contains("hidden-parent"))

        // A matching item only acknowledges the edit when every duplicate agrees.
        TVHomeCatalogOrder.acknowledgeCollectionVisibility(
            [(id: "hidden-parent", enabled: false), (id: "hidden-parent", enabled: true)],
            in: profile.suite
        )
        XCTAssertEqual(TVHomeCatalogOrder.pendingCollectionVisibility()["hidden-parent"], false)
        XCTAssertTrue(HomeCatalogPayloadStore.write(
            try JSONEncoder().encode(["hidden-parent"]),
            forKey: SettingsKey.homeCollectionDisabled
        ))
        TVHomeCatalogOrder.acknowledgeCollectionVisibility(
            [(id: "hidden-parent", enabled: false)], in: profile.suite
        )
        XCTAssertNil(TVHomeCatalogOrder.pendingCollectionVisibility()["hidden-parent"])
        XCTAssertTrue(TVHomeCatalogOrder.disabledCollectionIds().contains("hidden-parent"))
    }

    func testManifestSnapshotMetadataRoundTripsAndLegacyRowsRemainReadable() throws {
        let profile = activateHomeVisibilityProfile()
        defer { clearHomeVisibilityProfile(profile) }

        let row = snapshotRow(manifestShowInHome: false)
        TVHomeCatalogOrder.writeSnapshotRows([row])
        let storageKey = "homeCatalogTitles_\(profile.id)"
        let deadline = Date().addingTimeInterval(3)
        while LargePayloadStore.read(key: storageKey, directory: "catalogSnapshots") == nil,
              Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertNotNil(LargePayloadStore.read(key: storageKey, directory: "catalogSnapshots"))
        TVHomeCatalogOrder.invalidateSnapshotCache()

        let roundTripped = try XCTUnwrap(TVHomeCatalogOrder.snapshotRows().first)
        XCTAssertEqual(roundTripped.manifestURL, row.manifestURL)
        XCTAssertEqual(roundTripped.manifestShowInHome, false)

        let legacyProfileID = "\(profile.id)-legacy"
        let legacySuite = UserDefaults(suiteName: "nuvio.tv.profile.settings.\(legacyProfileID)")!
        legacySuite.set(legacyProfileID, forKey: "nuvio.tv.profile.settings.profileID")
        let legacyPayload = try JSONSerialization.data(withJSONObject: [[
            "id": "legacy-row",
            "title": "Legacy",
            "addonId": "example.addon",
            "type": "movie",
            "catalogId": "popular",
            "key": "example.addon_movie_popular"
        ]])
        legacySuite.set(legacyPayload, forKey: SettingsKey.homeCatalogTitles)
        TVHomeCatalogOrder.invalidateSnapshotCache()
        let legacyRow = try XCTUnwrap(TVHomeCatalogOrder.snapshotRows(in: legacySuite).first)
        XCTAssertNil(legacyRow.manifestURL)
        XCTAssertNil(legacyRow.manifestShowInHome)
        LargePayloadStore.remove(key: "homeCatalogTitles_\(legacyProfileID)", directory: "catalogSnapshots")
        legacySuite.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(legacyProfileID)")
    }

    func testHomeCatalogSignatureTracksFolderSourcesAndExplicitIntentOnly() throws {
        let profile = activateHomeVisibilityProfile()
        defer { clearHomeVisibilityProfile(profile) }

        let repository = CinemetaCatalogRepository()
        let baseSignature = repository.homeCatalogInputSignature
        let row = snapshotRow()
        TVHomeCatalogOrder.save([row.id])
        TVHomeCatalogOrder.writeSnapshotRows([row])
        XCTAssertEqual(repository.homeCatalogInputSignature, baseSignature)

        try applyFolderSource(
            parentID: "folder-parent",
            addonIdentifier: "example.addon",
            contentType: "movie",
            catalogID: "popular"
        )
        let sourceSignature = repository.homeCatalogInputSignature
        XCTAssertNotEqual(sourceSignature, baseSignature)

        XCTAssertTrue(HomeCatalogPayloadStore.write(
            try JSONEncoder().encode(["folder-parent"]),
            forKey: SettingsKey.homeCollectionDisabled
        ))
        XCTAssertEqual(repository.homeCatalogInputSignature, sourceSignature)

        let key = try XCTUnwrap(row.settingsKey)
        XCTAssertTrue(HomeCatalogPayloadStore.write(
            try JSONEncoder().encode([key]),
            forKey: SettingsKey.homeCatalogExplicitEnabled
        ))
        let explicitSignature = repository.homeCatalogInputSignature
        XCTAssertNotEqual(explicitSignature, sourceSignature)

        TVHomeCatalogOrder.clearOrder()
        XCTAssertEqual(repository.homeCatalogInputSignature, sourceSignature)

        CollectionsStore.applyRemote(Data("[]".utf8))
        XCTAssertNotEqual(repository.homeCatalogInputSignature, sourceSignature)
    }

    func testAllFolderBackedHomeSourcesYieldSuccessfulEmptyCatalogPublication() async throws {
        let profile = activateHomeVisibilityProfile()
        defer { clearHomeVisibilityProfile(profile) }

        try applyFolderSource(
            parentID: "folder-parent",
            addonIdentifier: "example.addon",
            contentType: "movie",
            catalogID: "popular"
        )
        CinemetaCatalogRepository.setCinemetaDisabled(true)
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences([])

        let context = TVHomeCatalogOrder.homeVisibilityContext()
        XCTAssertFalse(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon",
            contentType: "movie",
            catalogID: "popular",
            collectionSources: context.collectionSources,
            manifestURL: URL(string: "https://example.com/manifest.json"),
            explicitHomeKeys: context.explicitHomeKeys,
            disabledHomeKeys: context.disabledCatalogKeys
        ))

        let repository = CinemetaCatalogRepository()
        var publishedCounts: [Int] = []
        for try await catalogs in repository.homeCatalogsProgressively() {
            publishedCounts.append(catalogs.count)
        }
        XCTAssertEqual(publishedCounts, [0])
        XCTAssertFalse(repository.homeCatalogLoadWasPartial)
        XCTAssertNil(repository.homeCatalogFailureSignature)
    }

    func testDeleteCatalogRowPersistentlyRemovesFromSnapshotsAndOrder() throws {
        let profile = activateHomeVisibilityProfile()
        defer { clearHomeVisibilityProfile(profile) }

        let row1 = TVHomeCatalogOrder.SnapshotRow(
            id: "addon_test.addon_movie_popular",
            title: "Popular Movies",
            addonName: "Test Addon",
            addonId: "test.addon",
            contentType: "movie",
            catalogId: "popular",
            manifestURL: "https://example.com/manifest.json",
            manifestShowInHome: true,
            settingsKey: "test.addon_movie_popular"
        )
        let row2 = TVHomeCatalogOrder.SnapshotRow(
            id: "addon_test.addon_series_popular",
            title: "Popular Series",
            addonName: "Test Addon",
            addonId: "test.addon",
            contentType: "series",
            catalogId: "popular",
            manifestURL: "https://example.com/manifest.json",
            manifestShowInHome: true,
            settingsKey: "test.addon_series_popular"
        )

        TVHomeCatalogOrder.writeSnapshotRows([row1, row2])
        TVHomeCatalogOrder.save([row1.id, row2.id])
        TVHomeCatalogOrder.setRowEnabled(row1, isEnabled: true)

        XCTAssertEqual(TVHomeCatalogOrder.snapshotRows().count, 2)
        XCTAssertEqual(TVHomeCatalogOrder.savedOrder(), [TVHomeCatalogOrder.sectionOrderKey(row1.id), TVHomeCatalogOrder.sectionOrderKey(row2.id)])

        // Delete row1
        TVHomeCatalogOrder.deleteRow(row1)

        // Verify deleted key is persisted
        XCTAssertTrue(TVHomeCatalogOrder.deletedCatalogKeys().contains("test.addon_movie_popular"))
        XCTAssertTrue(TVHomeCatalogOrder.deletedCatalogKeys().contains("addon_test.addon_movie_popular"))

        // Verify snapshot no longer contains row1
        let snapshotsAfterDelete: [TVHomeCatalogOrder.SnapshotRow] = TVHomeCatalogOrder.snapshotRows()
        XCTAssertEqual(snapshotsAfterDelete.map { $0.id }, [row2.id])

        // Verify order no longer contains row1
        let orderAfterDelete = TVHomeCatalogOrder.savedOrder()
        XCTAssertEqual(orderAfterDelete, [TVHomeCatalogOrder.sectionOrderKey(row2.id)])

        // Verify row1 is marked disabled
        XCTAssertTrue(TVHomeCatalogOrder.disabledCatalogKeys().contains("test.addon_movie_popular"))

        // Attempting to re-add row1 via replaceSnapshotRows should ignore deleted row
        TVHomeCatalogOrder.replaceSnapshotRows(
            forAddonID: "test.addon",
            addonName: "Test Addon",
            with: [row1, row2]
        )
        let snapshotAfterReplace: [TVHomeCatalogOrder.SnapshotRow] = TVHomeCatalogOrder.snapshotRows()
        XCTAssertEqual(snapshotAfterReplace.map { $0.id }, [row2.id])

        // Attempting to merge snapshot containing row1 should ignore deleted row
        let merged: [TVHomeCatalogOrder.SnapshotRow] = TVHomeCatalogOrder.mergedSnapshotRows(
            current: [row1],
            previous: [row2]
        )
        XCTAssertEqual(merged.map { $0.id }, [row2.id])
    }

    func testDeleteCollectionRowPersistentlyRemovesCollection() throws {
        let profile = activateHomeVisibilityProfile()
        defer { clearHomeVisibilityProfile(profile) }

        let collectionRow = TVHomeCatalogOrder.SnapshotRow(
            id: "collection_custom_folder_1",
            title: "My Folder",
            settingsKey: "collection_custom_folder_1"
        )

        TVHomeCatalogOrder.writeSnapshotRows([collectionRow])
        TVHomeCatalogOrder.save([collectionRow.id])

        XCTAssertEqual(TVHomeCatalogOrder.snapshotRows().count, 1)

        TVHomeCatalogOrder.deleteRow(collectionRow)

        XCTAssertTrue(TVHomeCatalogOrder.deletedCatalogKeys().contains("collection_custom_folder_1"))
        XCTAssertTrue(TVHomeCatalogOrder.disabledCollectionIds().contains("custom_folder_1"))
        XCTAssertTrue(TVHomeCatalogOrder.snapshotRows().isEmpty)
        XCTAssertTrue(TVHomeCatalogOrder.savedOrder().isEmpty)
    }

    func testCatalogAutoRefreshIntervalSetting() {
        XCTAssertEqual(SettingsKey.catalogAutoRefreshInterval, "nuvio.tv.settings.layout.catalogAutoRefreshInterval")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.catalogAutoRefreshInterval))

        let defaults = UserDefaults(suiteName: "CatalogAutoRefreshIntervalTestsDefaults")!
        defaults.removePersistentDomain(forName: "CatalogAutoRefreshIntervalTestsDefaults")

        // Default should be 1800 (30 minutes)
        let defaultInterval = defaults.object(forKey: SettingsKey.catalogAutoRefreshInterval) as? Double ?? 1800
        XCTAssertEqual(defaultInterval, 1800)

        // Can be set to 900 (15 min) or 0 (Always) or -1 (Disabled)
        defaults.set(900.0, forKey: SettingsKey.catalogAutoRefreshInterval)
        XCTAssertEqual(defaults.double(forKey: SettingsKey.catalogAutoRefreshInterval), 900.0)

        defaults.set(0.0, forKey: SettingsKey.catalogAutoRefreshInterval)
        XCTAssertEqual(defaults.double(forKey: SettingsKey.catalogAutoRefreshInterval), 0.0)

        defaults.set(-1.0, forKey: SettingsKey.catalogAutoRefreshInterval)
        XCTAssertEqual(defaults.double(forKey: SettingsKey.catalogAutoRefreshInterval), -1.0)
    }

    func testForceRefreshNotificationDefined() {
        XCTAssertEqual(TVHomeCatalogOrder.forceRefreshNotification.rawValue, "nuvio.tv.homeCatalog.forceRefresh")
    }

    func testTVHomeGridLayoutRowsAndPreviewItemCount() {
        XCTAssertEqual(TVHomeGridLayout.columns, 7)
        XCTAssertEqual(TVHomeGridLayout.defaultRows, 3)
        XCTAssertEqual(TVHomeGridLayout.rows, 3)
        XCTAssertEqual(TVHomeGridLayout.minRows, 1)
        XCTAssertEqual(TVHomeGridLayout.maxRows, 10)

        // Default 3 rows: 7 * 3 - 1 = 20 preview items + 1 See All card = 21 total items
        XCTAssertEqual(TVHomeGridLayout.previewItemCount, 20)
        XCTAssertEqual(TVHomeGridLayout.previewItemCount(rows: 3), 20)

        // 1 row: 7 * 1 - 1 = 6 preview items + 1 See All card = 7 total items
        XCTAssertEqual(TVHomeGridLayout.previewItemCount(rows: 1), 6)

        // 2 rows: 7 * 2 - 1 = 13 preview items + 1 See All card = 14 total items
        XCTAssertEqual(TVHomeGridLayout.previewItemCount(rows: 2), 13)

        // 4 rows: 7 * 4 - 1 = 27 preview items
        XCTAssertEqual(TVHomeGridLayout.previewItemCount(rows: 4), 27)

        // 5 rows: 7 * 5 - 1 = 34 preview items
        XCTAssertEqual(TVHomeGridLayout.previewItemCount(rows: 5), 34)

        // 10 rows: 7 * 10 - 1 = 69 preview items
        XCTAssertEqual(TVHomeGridLayout.previewItemCount(rows: 10), 69)

        // Boundary checks (clamped to minRows...maxRows)
        XCTAssertEqual(TVHomeGridLayout.previewItemCount(rows: 0), 6)
        XCTAssertEqual(TVHomeGridLayout.previewItemCount(rows: -5), 6)
        XCTAssertEqual(TVHomeGridLayout.previewItemCount(rows: 15), 69)
    }

    func testGridRowsSettingKeyAndDefaults() {
        XCTAssertEqual(SettingsKey.gridRows, "nuvio.tv.settings.layout.gridRows")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.gridRows))

        let defaults = UserDefaults(suiteName: "GridRowsSettingsTestsDefaults")!
        defaults.removePersistentDomain(forName: "GridRowsSettingsTestsDefaults")

        let defaultRows = defaults.object(forKey: SettingsKey.gridRows) as? Int ?? TVHomeGridLayout.defaultRows
        XCTAssertEqual(defaultRows, 3)

        defaults.set(1, forKey: SettingsKey.gridRows)
        XCTAssertEqual(defaults.integer(forKey: SettingsKey.gridRows), 1)

        defaults.set(5, forKey: SettingsKey.gridRows)
        XCTAssertEqual(defaults.integer(forKey: SettingsKey.gridRows), 5)
    }

    // MARK: - Details Sections Order and Toggles (Issue #104)

    func testDetailsSectionOrderDefaultValues() {
        let suiteName = "DetailsSectionDefaultsTest_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        XCTAssertEqual(TVDetailsSectionOrder.defaultOrder, [.episodes, .cast, .related, .network, .production, .comments])
        XCTAssertEqual(TVDetailsSectionOrder.currentOrder(in: defaults), TVDetailsSectionOrder.defaultOrder)
        XCTAssertTrue(TVDetailsSectionOrder.disabledSections(in: defaults).isEmpty)
        XCTAssertEqual(TVDetailsSectionOrder.activeSections(in: defaults), TVDetailsSectionOrder.defaultOrder)
        XCTAssertEqual(TVDetailsSectionOrder.activeSectionCount(in: defaults), 6)

        for section in TVDetailsSection.allCases {
            XCTAssertTrue(TVDetailsSectionOrder.isSectionEnabled(section, in: defaults))
        }

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDetailsSectionOrderSaveAndReorder() {
        let suiteName = "DetailsSectionReorderTest_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let newOrder: [TVDetailsSection] = [.cast, .episodes, .comments, .related, .network, .production]

        let expectation = expectation(forNotification: TVDetailsSectionOrder.changedNotification, object: nil)
        TVDetailsSectionOrder.saveOrder(newOrder, in: defaults)
        wait(for: [expectation], timeout: 1.0)

        XCTAssertEqual(TVDetailsSectionOrder.currentOrder(in: defaults), newOrder)
        XCTAssertEqual(TVDetailsSectionOrder.activeSections(in: defaults), newOrder)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDetailsSectionOrderDisableAndEnable() {
        let suiteName = "DetailsSectionDisableTest_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        TVDetailsSectionOrder.setSectionEnabled(.cast, isEnabled: false, in: defaults)
        TVDetailsSectionOrder.setSectionEnabled(.comments, isEnabled: false, in: defaults)

        let disabled = TVDetailsSectionOrder.disabledSections(in: defaults)
        XCTAssertEqual(disabled, [.cast, .comments])
        XCTAssertFalse(TVDetailsSectionOrder.isSectionEnabled(.cast, in: defaults))
        XCTAssertFalse(TVDetailsSectionOrder.isSectionEnabled(.comments, in: defaults))
        XCTAssertTrue(TVDetailsSectionOrder.isSectionEnabled(.episodes, in: defaults))
        XCTAssertTrue(TVDetailsSectionOrder.isSectionEnabled(.related, in: defaults))

        let active = TVDetailsSectionOrder.activeSections(in: defaults)
        XCTAssertEqual(active, [.episodes, .related, .network, .production])
        XCTAssertEqual(TVDetailsSectionOrder.activeSectionCount(in: defaults), 4)

        // Re-enable cast
        TVDetailsSectionOrder.setSectionEnabled(.cast, isEnabled: true, in: defaults)
        XCTAssertTrue(TVDetailsSectionOrder.isSectionEnabled(.cast, in: defaults))
        XCTAssertEqual(TVDetailsSectionOrder.activeSectionCount(in: defaults), 5)
        XCTAssertEqual(TVDetailsSectionOrder.activeSections(in: defaults), [.episodes, .cast, .related, .network, .production])

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDetailsSectionCaseInsensitiveAndAliasDecoding() {
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "episodes"), .episodes)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "EPISODES"), .episodes)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "cast"), .cast)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "CAST"), .cast)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "more_like_this"), .related)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "MORE_LIKE_THIS"), .related)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "morelikethis"), .related)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "related"), .related)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "networks"), .network)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "NETWORKS"), .network)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "network"), .network)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "production"), .production)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "companies"), .production)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "COMPANIES"), .production)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "comments"), .comments)
        XCTAssertEqual(TVDetailsSection(caseInsensitive: "COMMENTS"), .comments)
        XCTAssertNil(TVDetailsSection(caseInsensitive: "unknown_section"))

        let suiteName = "DetailsSectionAliasTest_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        // Simulate Android app JSON payload format
        let androidPayload = ["MORE_LIKE_THIS", "CAST", "EPISODES"]
        let data = try! JSONEncoder().encode(androidPayload)
        defaults.set(data, forKey: SettingsKey.detailsSectionOrder)

        let loaded = TVDetailsSectionOrder.currentOrder(in: defaults)
        // Should decode the android keys in order, then append remaining defaults (network, production, comments)
        XCTAssertEqual(loaded, [.related, .cast, .episodes, .network, .production, .comments])

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDetailsSectionResetToDefaults() {
        let suiteName = "DetailsSectionResetTest_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        TVDetailsSectionOrder.saveOrder([.comments, .cast], in: defaults)
        TVDetailsSectionOrder.setSectionEnabled(.cast, isEnabled: false, in: defaults)
        XCTAssertNotEqual(TVDetailsSectionOrder.currentOrder(in: defaults), TVDetailsSectionOrder.defaultOrder)
        XCTAssertFalse(TVDetailsSectionOrder.disabledSections(in: defaults).isEmpty)

        TVDetailsSectionOrder.resetToDefaults(in: defaults)
        XCTAssertEqual(TVDetailsSectionOrder.currentOrder(in: defaults), TVDetailsSectionOrder.defaultOrder)
        XCTAssertTrue(TVDetailsSectionOrder.disabledSections(in: defaults).isEmpty)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSettingsKeysIncludeDetailsSectionKeys() {
        XCTAssertEqual(SettingsKey.detailsSectionOrder, "nuvio.tv.settings.layout.detailsSectionOrder")
        XCTAssertEqual(SettingsKey.detailsSectionDisabled, "nuvio.tv.settings.layout.detailsSectionDisabled")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.detailsSectionOrder))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.detailsSectionDisabled))
    }

    func testFocusedPosterExpandingToBackdropPrefersBackgroundOverLandscapePoster() {
        let meta = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            posterUrl: "https://example.com/poster.jpg",
            backgroundUrl: "https://example.com/clean-backdrop.jpg",
            logoUrl: "https://example.com/logo.png",
            type: "series",
            landscapePosterUrl: "https://example.com/landscape-poster-with-logo.jpg"
        )

        // When expanding a focused poster to a backdrop card (isEffectivelyAlwaysLandscape == false),
        // the backdrop card must display the clean backdrop (backgroundUrl) rather than the landscape poster.
        let resolvedCardArtwork = PosterCard.resolvedLandscapeArtworkURL(
            meta: meta,
            isEffectivelyAlwaysLandscape: false
        )
        XCTAssertEqual(resolvedCardArtwork, "https://example.com/clean-backdrop.jpg")

        // The Home hero backdrop must also resolve to the clean backdrop.
        let heroBackdrop = TVHomeView.preferredBackdropURL(for: meta)
        XCTAssertEqual(heroBackdrop, "https://example.com/clean-backdrop.jpg")

        // Over the clean backdrop, the logo overlay is displayed.
        let showOverlay = PosterCard.shouldShowLandscapeOverlay(
            meta: meta,
            isEffectivelyAlwaysLandscape: false,
            showsPosterTitle: true
        )
        XCTAssertTrue(showOverlay)
    }

    func testFocusedPosterExpandingToBackdropFallsBackToLandscapePosterWhenBackgroundMissing() {
        let meta = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            posterUrl: "https://example.com/poster.jpg",
            backgroundUrl: nil,
            logoUrl: "https://example.com/logo.png",
            type: "series",
            landscapePosterUrl: "https://example.com/landscape-poster-with-logo.jpg"
        )

        let resolvedCardArtwork = PosterCard.resolvedLandscapeArtworkURL(
            meta: meta,
            isEffectivelyAlwaysLandscape: false
        )
        XCTAssertEqual(resolvedCardArtwork, "https://example.com/landscape-poster-with-logo.jpg")

        let heroBackdrop = TVHomeView.preferredBackdropURL(for: meta)
        XCTAssertEqual(heroBackdrop, "https://example.com/landscape-poster-with-logo.jpg")
    }

    func testLandscapePosterRowUsesLandscapePosterAndSuppressesDuplicateLogoOverlay() {
        let meta = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            posterUrl: "https://example.com/poster.jpg",
            backgroundUrl: "https://example.com/clean-backdrop.jpg",
            logoUrl: "https://example.com/logo.png",
            type: "series",
            landscapePosterUrl: "https://example.com/landscape-poster-with-logo.jpg"
        )

        // In a landscape poster row (isEffectivelyAlwaysLandscape == true),
        // the card displays the landscape poster.
        let resolvedCardArtwork = PosterCard.resolvedLandscapeArtworkURL(
            meta: meta,
            isEffectivelyAlwaysLandscape: true
        )
        XCTAssertEqual(resolvedCardArtwork, "https://example.com/landscape-poster-with-logo.jpg")

        // Because the landscape poster already has the logo/title baked in,
        // the card's logo overlay should be suppressed to avoid duplicate logos.
        let showOverlay = PosterCard.shouldShowLandscapeOverlay(
            meta: meta,
            isEffectivelyAlwaysLandscape: true,
            showsPosterTitle: true
        )
        XCTAssertFalse(showOverlay)

        // The screen's hero backdrop still uses the clean background fanart.
        let heroBackdrop = TVHomeView.preferredBackdropURL(for: meta)
        XCTAssertEqual(heroBackdrop, "https://example.com/clean-backdrop.jpg")
    }
}

