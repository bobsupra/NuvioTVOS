import Foundation
import UIKit
import Combine
import XCTest
@testable import NuvioTV

@MainActor
final class CatalogWatchedMemoryTests: XCTestCase {
    private func meta(_ name: String, videos: [NuvioVideo]? = nil) -> NuvioMeta {
        NuvioMeta(id: "tt1234567", name: name, type: "series", videos: videos)
    }

    func testMemoryWarningReleasesMetadataAndDecisions() async {
        let center = NotificationCenter()
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: center) { _, _ in
            fetchCount += 1
            return self.meta("Guide")
        }
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        cache.setDecision(2, for: "decision")
        XCTAssertEqual(fetchCount, 1)

        center.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertNil(cache.cachedDecision(for: "decision"))
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(fetchCount, 2)
    }

    func testManualCacheClearAlsoReleasesAuxiliaryMetadata() async {
        let center = NotificationCenter()
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: center) { _, _ in
            fetchCount += 1
            return self.meta("Guide")
        }
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        cache.setDecision(1, for: "decision")
        center.post(name: AppCacheManager.didClearCacheNotification, object: nil)
        XCTAssertNil(cache.cachedDecision(for: "decision"))
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(fetchCount, 2)
    }

    func testTransientPurgeDoesNotInvalidatePendingBadgeRefresh() {
        let cache = CatalogWatchedMetadataCache(notificationCenter: NotificationCenter())
        let pendingRefreshGeneration = cache.decisionGenerationToken()
        cache.setDecision(1, for: "decision")

        cache.purgeTransientValues()

        XCTAssertNil(cache.cachedDecision(for: "decision"))
        XCTAssertEqual(cache.decisionGenerationToken(), pendingRefreshGeneration)
        cache.setDecision(2, for: "decision", ifGenerationMatches: pendingRefreshGeneration)
        XCTAssertEqual(cache.cachedDecision(for: "decision"), 2)
    }

    func testWatchedChangeKeepsGuideButInvalidatesCalculatedCount() async {
        let center = NotificationCenter()
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: center) { _, _ in
            fetchCount += 1
            return self.meta("Guide")
        }
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        cache.setDecision(3, for: "decision")
        center.post(name: WatchedStore.changedNotification, object: nil)
        XCTAssertNil(cache.cachedDecision(for: "decision"))
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(fetchCount, 1)
    }

    func testContinueWatchingChangeInvalidatesDecisionButKeepsGuide() async {
        let center = NotificationCenter()
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: center) { _, _ in
            fetchCount += 1
            return self.meta("Guide")
        }
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        cache.setDecision(2, for: "decision")

        center.post(name: TraktSettingsStore.continueWatchingChangedNotification, object: nil)

        XCTAssertNil(cache.cachedDecision(for: "decision"))
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(fetchCount, 1)
    }

    func testProviderAuthChangesInvalidateDecisionButKeepGuide() async {
        let center = NotificationCenter()
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: center) { _, _ in
            fetchCount += 1
            return self.meta("Guide")
        }
        _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        let authNotifications = [
            TraktAuthStore.changedNotification,
            SimklAuthStore.changedNotification,
            MdbListAuthStore.changedNotification,
            WeTrakrAuthStore.changedNotification
        ]

        for notification in authNotifications {
            cache.setDecision(2, for: "decision")
            center.post(name: notification, object: nil)
            XCTAssertNil(cache.cachedDecision(for: "decision"), "\(notification) should invalidate watched decisions")
            _ = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        }

        XCTAssertEqual(fetchCount, 1)
    }

    func testOldDecisionComputationCannotRepublishAfterContinueWatchingChange() {
        let center = NotificationCenter()
        let cache = CatalogWatchedMetadataCache(notificationCenter: center)
        let oldGeneration = cache.decisionGenerationToken()

        center.post(name: TraktSettingsStore.continueWatchingChangedNotification, object: nil)
        cache.setDecision(1, for: "decision", ifGenerationMatches: oldGeneration)

        XCTAssertNil(cache.cachedDecision(for: "decision"))
        let currentGeneration = cache.decisionGenerationToken()
        cache.setDecision(2, for: "decision", ifGenerationMatches: currentGeneration)
        XCTAssertEqual(cache.cachedDecision(for: "decision"), 2)
    }

    func testPendingResultStillReachesConsumerButDoesNotRefillPurgedCache() async {
        let started = expectation(description: "old request started")
        let gate = WatchedMetadataGate { started.fulfill() }
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: NotificationCenter()) { _, _ in
            fetchCount += 1
            if fetchCount == 1 { return await gate.fetch() }
            return self.meta("Fresh")
        }
        let pending = Task { await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil) }
        await fulfillment(of: [started], timeout: 2)
        cache.purgeTransientValues()
        gate.finish(meta("Old"))
        let oldResult = await pending.value
        XCTAssertEqual(oldResult?.name, "Old")
        let fresh = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(fresh?.name, "Fresh")
        XCTAssertEqual(fetchCount, 2)
    }

    func testIncompleteSeriesPreviewIsRetriedWhenLibraryActionNeedsGuide() async {
        let preview = meta("Compact")
        var fetchCount = 0
        let center = NotificationCenter()
        let guideResolved = expectation(description: "full series guide resolved")
        let observer = center.addObserver(
            forName: CatalogWatchedMetadataCache.fullSeriesGuideResolvedNotification,
            object: nil,
            queue: nil
        ) { _ in guideResolved.fulfill() }
        defer { center.removeObserver(observer) }
        let cache = CatalogWatchedMetadataCache(notificationCenter: center) { _, _ in
            fetchCount += 1
            guard fetchCount > 1 else { return nil }
            return self.meta(
                "Complete",
                videos: [NuvioVideo(id: "tt1234567:1:1", title: "Pilot", season: 1, episode: 1)]
            )
        }

        let firstLookup = await cache.fullSeriesMetadata(
            metaId: preview.id,
            type: preview.type,
            preview: preview
        )
        let decisionToken = cache.decisionGenerationToken(for: "library-badge")
        cache.setDecision(
            0,
            for: "library-badge",
            ifTokenMatches: decisionToken,
            profileId: WatchedStore.activeProfileId,
            titleIdentityKeys: CatalogWatchedBadgeIdentity.titleIdentityKeys(for: preview)
        )
        let recoveredGuide = await cache.fullSeriesMetadata(
            metaId: preview.id,
            type: preview.type,
            preview: preview
        )

        XCTAssertNil(firstLookup)
        XCTAssertEqual(recoveredGuide?.videos?.count, 1)
        XCTAssertEqual(fetchCount, 2)
        XCTAssertNil(cache.cachedDecision(for: "library-badge"))
        await fulfillment(of: [guideResolved], timeout: 1)
    }

    func testWatchedMenuRejectsResultsFromAnOlderScopeAndKeepsPendingGuideDisabled() {
        let oldIdentity = "TRAKT\u{1f}profile-a\u{1f}title"
        let currentIdentity = "SIMKL\u{1f}profile-a\u{1f}title"

        XCTAssertNil(
            LibraryWatchedMenuStatePolicy.resolvedState(
                true,
                identity: oldIdentity,
                currentIdentity: currentIdentity
            )
        )
        XCTAssertTrue(LibraryWatchedMenuStatePolicy.isGuideResolutionPending(
            isSeries: true,
            hasFullGuide: false,
            resolvedIdentity: oldIdentity,
            currentIdentity: currentIdentity
        ))
        XCTAssertFalse(LibraryWatchedMenuStatePolicy.isGuideResolutionPending(
            isSeries: true,
            hasFullGuide: true,
            resolvedIdentity: nil,
            currentIdentity: currentIdentity
        ))
    }

    func testDelayedWatchedMenuIntentDoesNotInvertIfSyncAlreadyReachedDesiredState() {
        XCTAssertFalse(WatchedMenuIntentPolicy.needsMutation(
            currentlyWatched: true,
            desiredIsWatched: true
        ))
        XCTAssertTrue(WatchedMenuIntentPolicy.needsMutation(
            currentlyWatched: true,
            desiredIsWatched: false
        ))
    }

    func testGuideResolutionInvalidatesOnlyMatchingBadgeProfileAndTitleAliases() {
        let cache = CatalogWatchedMetadataCache(notificationCenter: NotificationCenter())
        let cardMeta = NuvioMeta(
            id: "provider:show-1",
            name: "Alias Show",
            imdbId: "tt7654321",
            type: "series",
            year: 2022
        )
        let resolvedMeta = NuvioMeta(
            id: "tt7654321",
            name: "Alias Show",
            imdbId: "tt7654321",
            type: "series",
            year: 2022,
            videos: [NuvioVideo(id: "tt7654321:1:1", title: "Pilot", season: 1, episode: 1)]
        )
        let unrelatedMeta = NuvioMeta(id: "tt0000001", name: "Other Show", type: "series", year: 2021)
        let sameTitleOtherProfileKey = "SIMKL\u{1f}profile-b\u{1f}series\u{1f}other-id"
        let matchingKey = "TRAKT\u{1f}profile-a\u{1f}series\u{1f}provider-id"
        let unrelatedKey = "TRAKT\u{1f}profile-a\u{1f}series\u{1f}other-id"

        let fixtures: [(key: String, profileId: String?, meta: NuvioMeta)] = [
            (matchingKey, "profile-a", cardMeta),
            (unrelatedKey, "profile-a", unrelatedMeta),
            (sameTitleOtherProfileKey, "profile-b", resolvedMeta)
        ]
        for (key, profileId, meta) in fixtures {
            let token = cache.decisionGenerationToken(for: key)
            cache.setDecision(
                0,
                for: key,
                ifTokenMatches: token,
                profileId: profileId,
                titleIdentityKeys: CatalogWatchedBadgeIdentity.titleIdentityKeys(for: meta)
            )
        }

        cache.invalidateDecisions(
            matching: CatalogWatchedGuideResolution(profileId: "profile-a", meta: resolvedMeta)
        )

        XCTAssertNil(cache.cachedDecision(for: matchingKey), "IMDb aliases should invalidate the matching card decision")
        XCTAssertEqual(cache.cachedDecision(for: unrelatedKey), 0)
        XCTAssertEqual(cache.cachedDecision(for: sameTitleOtherProfileKey), 0)
    }

    func testDetailsContextAllowsScrobbleTargetChangesButRejectsPrimaryRelink() {
        let original = WatchedLibraryMutationContext(
            librarySource: .local,
            profileID: "profile-a",
            targets: [
                WatchedLibraryMutationTarget(provider: .nuvioSync, accountID: "primary-account"),
                WatchedLibraryMutationTarget(provider: .trakt, accountID: "scrobble-account-a")
            ]
        )
        let changedScrobbleTarget = WatchedLibraryMutationContext(
            librarySource: .local,
            profileID: "profile-a",
            targets: [
                WatchedLibraryMutationTarget(provider: .nuvioSync, accountID: "primary-account"),
                WatchedLibraryMutationTarget(provider: .simkl, accountID: "scrobble-account-b")
            ]
        )
        let relinkedPrimary = WatchedLibraryMutationContext(
            librarySource: .local,
            profileID: "profile-a",
            targets: [
                WatchedLibraryMutationTarget(provider: .nuvioSync, accountID: "new-primary-account"),
                WatchedLibraryMutationTarget(provider: .trakt, accountID: "scrobble-account-a")
            ]
        )

        XCTAssertTrue(LibraryWatchedContext.hasSamePrimaryTarget(original, changedScrobbleTarget))
        XCTAssertFalse(LibraryWatchedContext.hasSamePrimaryTarget(original, relinkedPrimary))
    }

    func testLibrarySnapshotIsStrictlyScopedByProviderAndProfile() {
        let profileID = "library-watched-scope-\(UUID().uuidString)"
        let otherProfileID = "library-watched-other-\(UUID().uuidString)"
        let previousSettingsProfileID = ProfileSettings.activeProfileID
        let previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        let previousWatchedProfileID = WatchedStore.activeProfileId
        let previousLibraryProfileID = LibraryStore.activeProfileId
        defer {
            WatchedStore.eraseProfile(profileID)
            WatchedStore.eraseProfile(otherProfileID)
            LibraryStore.eraseProfile(profileID)
            LibraryStore.eraseProfile(otherProfileID)
            WatchedStore.setActiveProfile(previousWatchedProfileID)
            LibraryStore.setActiveProfile(previousLibraryProfileID)
            if let previousSettingsProfileID {
                ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
            } else {
                ProfileSettings.clearActiveProfile()
            }
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(otherProfileID)")
        }

        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        WatchedStore.setActiveProfile(profileID)
        LibraryStore.setActiveProfile(profileID)
        TraktSettingsStore.librarySourceMode = .local

        let traktTitle = NuvioMeta(id: "tt-library-trakt-\(UUID().uuidString)", name: "Trakt title", type: "movie")
        let syncTitle = NuvioMeta(id: "tt-library-sync-\(UUID().uuidString)", name: "Sync title", type: "movie")
        WatchedStore.replaceAll([
            WatchedStoreItem(
                meta: traktTitle,
                watchedAt: Date(),
                sources: [TraktWatchProgressSource.trakt.rawValue],
                legacyUnattributed: false
            ),
            WatchedStoreItem(
                meta: syncTitle,
                watchedAt: Date(),
                sources: [TraktWatchProgressSource.nuvioSync.rawValue],
                legacyUnattributed: false
            )
        ], profileId: profileID)

        let traktSnapshot = WatchedStore.librarySnapshot(for: .trakt, profileId: profileID)
        let localSnapshot = WatchedStore.librarySnapshot(for: .local, profileId: profileID)
        let otherProfileSnapshot = WatchedStore.librarySnapshot(for: .trakt, profileId: otherProfileID)

        XCTAssertTrue(traktSnapshot.contains(meta: traktTitle))
        XCTAssertFalse(traktSnapshot.contains(meta: syncTitle))
        XCTAssertTrue(localSnapshot.contains(meta: syncTitle))
        XCTAssertFalse(localSnapshot.contains(meta: traktTitle))
        XCTAssertFalse(otherProfileSnapshot.contains(meta: traktTitle))
    }

    func testLibraryHistorySyncUsesSelectedProviderWhenProgressUsesAnotherSource() async throws {
        let profileID = "library-history-sync-\(UUID().uuidString)"
        let previousSettingsProfileID = ProfileSettings.activeProfileID
        let previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        let previousWatchedProfileID = WatchedStore.activeProfileId
        let previousLibraryProfileID = LibraryStore.activeProfileId
        let previousLibrarySource = TraktSettingsStore.librarySourceMode
        let previousProgressSource = TraktSettingsStore.watchProgressSource
        defer {
            WatchedStore.eraseProfile(profileID)
            LibraryStore.eraseProfile(profileID)
            WatchedStore.setActiveProfile(previousWatchedProfileID)
            LibraryStore.setActiveProfile(previousLibraryProfileID)
            if let previousSettingsProfileID {
                ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
            } else {
                ProfileSettings.clearActiveProfile()
            }
            TraktSettingsStore.librarySourceMode = previousLibrarySource
            TraktSettingsStore.watchProgressSource = previousProgressSource
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
        }

        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        WatchedStore.setActiveProfile(profileID)
        LibraryStore.setActiveProfile(profileID)
        let store = ProfileSettings.current
        store.set("test-trakt-client", forKey: SettingsKey.traktClientID)
        TraktAuthStore.saveToken(
            TraktTokenResponse(
                accessToken: "test-access",
                tokenType: "Bearer",
                expiresIn: 3600,
                refreshToken: "test-refresh",
                createdAt: Int(Date().timeIntervalSince1970)
            ),
            clientID: "test-trakt-client",
            store: store
        )
        TraktSettingsStore.librarySourceMode = .trakt
        TraktSettingsStore.watchProgressSource = .nuvioSync

        let syncStarted = expectation(description: "selected Library provider history sync started")
        var requestedScopes: [(TraktLibrarySourceMode, String?)] = []
        let viewModel = LibraryViewModel { source, requestedProfileID in
            requestedScopes.append((source, requestedProfileID))
            syncStarted.fulfill()
            return true
        }
        let libraryContext = LibraryWatchedContext.capture(source: .trakt, profileId: profileID)
        XCTAssertTrue(libraryContext.isCurrentScope)

        viewModel.scheduleLibraryHistorySync(for: libraryContext)
        await fulfillment(of: [syncStarted], timeout: 1)
        viewModel.scheduleLibraryHistorySync(for: libraryContext)
        await Task.yield()

        XCTAssertEqual(TraktSettingsStore.watchProgressSource, .nuvioSync)
        XCTAssertEqual(requestedScopes.count, 1)
        XCTAssertEqual(requestedScopes.first?.0, .trakt)
        XCTAssertEqual(requestedScopes.first?.1, profileID)
    }

    func testLibraryNavigationEntryCarriesLibraryContextAndHomeEntryStaysUnscoped() {
        let profileID = "library-navigation-\(UUID().uuidString)"
        let previousSettingsProfileID = ProfileSettings.activeProfileID
        let previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        let previousWatchedProfileID = WatchedStore.activeProfileId
        let previousLibraryProfileID = LibraryStore.activeProfileId
        defer {
            WatchedStore.eraseProfile(profileID)
            LibraryStore.eraseProfile(profileID)
            WatchedStore.setActiveProfile(previousWatchedProfileID)
            LibraryStore.setActiveProfile(previousLibraryProfileID)
            if let previousSettingsProfileID {
                ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
            } else {
                ProfileSettings.clearActiveProfile()
            }
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
        }

        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        WatchedStore.setActiveProfile(profileID)
        LibraryStore.setActiveProfile(profileID)
        TraktSettingsStore.librarySourceMode = .local
        let libraryContext = LibraryWatchedContext.captureCurrent()
        let rootTransition = DetailsNavigationContextTransition.pushingCurrentDetails(
            id: "tt-library-navigation",
            type: "movie",
            libraryWatchedContext: libraryContext
        )
        var backStack: [DetailsNavigationEntry] = []
        backStack.append(rootTransition.backStackEntry)
        XCTAssertNil(rootTransition.activeLibraryWatchedContext)

        let relatedTransition = DetailsNavigationContextTransition.openingRelatedTitle(from: rootTransition.backStackEntry)
        XCTAssertNil(relatedTransition.activeLibraryWatchedContext)
        backStack.append(relatedTransition.backStackEntry)

        _ = backStack.popLast()
        let restoredContext = backStack.popLast().flatMap(DetailsNavigationContextTransition.restoring)
        XCTAssertEqual(
            restoredContext?.cacheIdentity,
            libraryContext.cacheIdentity
        )
        XCTAssertEqual(restoredContext?.profileId, profileID)

        let homeEntry = DetailsNavigationEntry(id: "tt-home-navigation", type: "movie", libraryWatchedContext: nil)
        XCTAssertNil(homeEntry.libraryWatchedContext)
        XCTAssertEqual(
            DetailsNavigationContextTransition.playbackContext(
                origin: .details,
                currentLibraryWatchedContext: libraryContext
            )?.cacheIdentity,
            libraryContext.cacheIdentity
        )
        XCTAssertNil(DetailsNavigationContextTransition.playbackContext(origin: .main, currentLibraryWatchedContext: libraryContext))
        XCTAssertNil(DetailsNavigationContextTransition.playbackContext(origin: .cloudLibrary, currentLibraryWatchedContext: libraryContext))
    }

    func testSameProfileNuvioSyncRelinkInvalidatesCapturedLibraryMutation() {
        let profileID = "library-relink-\(UUID().uuidString)"
        let previousSettingsProfileID = ProfileSettings.activeProfileID
        let previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        let previousWatchedProfileID = WatchedStore.activeProfileId
        let previousLibraryProfileID = LibraryStore.activeProfileId
        let previousSyncBinding = WatchedStore.nuvioSyncAccountBinding(profileId: profileID)
        defer {
            WatchedStore.eraseProfile(profileID)
            LibraryStore.eraseProfile(profileID)
            WatchedStore.setNuvioSyncAccountBinding(previousSyncBinding, profileId: profileID)
            WatchedStore.setActiveProfile(previousWatchedProfileID)
            LibraryStore.setActiveProfile(previousLibraryProfileID)
            if let previousSettingsProfileID {
                ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
            } else {
                ProfileSettings.clearActiveProfile()
            }
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
        }

        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        WatchedStore.setActiveProfile(profileID)
        LibraryStore.setActiveProfile(profileID)
        TraktSettingsStore.librarySourceMode = .local
        WatchedStore.setNuvioSyncAccountBinding("sync-account-before-relink", profileId: profileID)
        let capturedContext = LibraryWatchedContext.captureCurrent()
        let meta = NuvioMeta(id: "tt-stale-library-write-\(UUID().uuidString)", name: "Relink guard", type: "movie")

        XCTAssertTrue(capturedContext.isCurrent)
        WatchedStore.setNuvioSyncAccountBinding("sync-account-after-relink", profileId: profileID)

        XCTAssertFalse(capturedContext.isCurrent)
        XCTAssertFalse(capturedContext.setWatched(meta, isWatched: true))
        XCTAssertFalse(WatchedStore.isWatchedForLibrary(meta: meta, source: .local, profileId: profileID))
    }

    func testDelayedLibraryResponseFromSameProviderRelinkIsDiscarded() async throws {
        let profileID = "library-delayed-relink-\(UUID().uuidString)"
        let previousSettingsProfileID = ProfileSettings.activeProfileID
        let previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        let previousWatchedProfileID = WatchedStore.activeProfileId
        let previousLibraryProfileID = LibraryStore.activeProfileId
        defer {
            WatchedStore.eraseProfile(profileID)
            LibraryStore.eraseProfile(profileID)
            WatchedStore.setActiveProfile(previousWatchedProfileID)
            LibraryStore.setActiveProfile(previousLibraryProfileID)
            if let previousSettingsProfileID {
                ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
            } else {
                ProfileSettings.clearActiveProfile()
            }
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
        }

        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        WatchedStore.setActiveProfile(profileID)
        LibraryStore.setActiveProfile(profileID)
        TraktSettingsStore.librarySourceMode = .local
        WatchedStore.setNuvioSyncAccountBinding("library-account-before", profileId: profileID)
        let viewModel = LibraryViewModel()
        let capturedContext = try XCTUnwrap(viewModel.displayedWatchedContext)
        let started = expectation(description: "remote library response is delayed")
        let gate = LibraryItemsResponseGate { started.fulfill() }
        let staleTitle = StremioMeta(id: "tt-delayed-library", name: "Old account title", contentType: "movie")
        let delayedResponse = Task { @MainActor in
            await gate.wait()
            return viewModel.applyFetchedLibraryItems(
                [staleTitle],
                source: .local,
                watchedContext: capturedContext
            )
        }

        await fulfillment(of: [started], timeout: 1)
        WatchedStore.setNuvioSyncAccountBinding("library-account-after", profileId: profileID)
        gate.release()

        let responseWasApplied = await delayedResponse.value
        XCTAssertFalse(responseWasApplied)
        XCTAssertTrue(viewModel.items.isEmpty)
        XCTAssertNil(viewModel.displayedWatchedContext)
    }

    func testNuvioSyncBindingChangeRebindsLocalLibraryWithoutClearingItems() async {
        let profileID = "library-owner-rebind-\(UUID().uuidString)"
        let previousSettingsProfileID = ProfileSettings.activeProfileID
        let previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        let previousWatchedProfileID = WatchedStore.activeProfileId
        let previousLibraryProfileID = LibraryStore.activeProfileId
        let previousSyncBinding = WatchedStore.nuvioSyncAccountBinding(profileId: profileID)
        defer {
            WatchedStore.eraseProfile(profileID)
            LibraryStore.eraseProfile(profileID)
            WatchedStore.setNuvioSyncAccountBinding(previousSyncBinding, profileId: profileID)
            WatchedStore.setActiveProfile(previousWatchedProfileID)
            LibraryStore.setActiveProfile(previousLibraryProfileID)
            if let previousSettingsProfileID {
                ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
            } else {
                ProfileSettings.clearActiveProfile()
            }
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
        }

        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        WatchedStore.setActiveProfile(profileID)
        LibraryStore.setActiveProfile(profileID)
        TraktSettingsStore.librarySourceMode = .local
        WatchedStore.setNuvioSyncAccountBinding("sync-account-before", profileId: profileID)
        let savedMeta = NuvioMeta(id: "tt-library-owner-preserved", name: "Saved title", type: "movie")
        LibraryStore.add(savedMeta)
        let viewModel = LibraryViewModel()
        let ownerRebound = expectation(description: "display owner follows the new sync binding")
        var didFulfill = false
        let subscription = viewModel.$displayedWatchedContext
            .dropFirst()
            .sink { context in
                let accountID = context?.mutationContext?.targets.first(where: { $0.provider == .nuvioSync })?.accountID
                guard !didFulfill, accountID == "sync-account-after" else { return }
                didFulfill = true
                ownerRebound.fulfill()
            }

        WatchedStore.setNuvioSyncAccountBinding("sync-account-after", profileId: profileID)
        await fulfillment(of: [ownerRebound], timeout: 1)

        XCTAssertEqual(viewModel.items.map(\.id), [savedMeta.id])
        XCTAssertEqual(
            viewModel.displayedWatchedContext?.mutationContext?.targets.first(where: { $0.provider == .nuvioSync })?.accountID,
            "sync-account-after"
        )
        withExtendedLifetime(subscription) {}
    }

    func testOlderCompletionCannotOverwritePostPurgeResponse() async {
        let started = expectation(description: "old request started")
        let gate = WatchedMetadataGate { started.fulfill() }
        var fetchCount = 0
        let cache = CatalogWatchedMetadataCache(notificationCenter: NotificationCenter()) { _, _ in
            fetchCount += 1
            if fetchCount == 1 { return await gate.fetch() }
            return self.meta("Fresh")
        }
        let pending = Task { await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil) }
        await fulfillment(of: [started], timeout: 2)
        cache.purgeTransientValues()
        let fresh = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(fresh?.name, "Fresh")
        gate.finish(meta("Old"))
        _ = await pending.value
        let cached = await cache.fullMetadata(metaId: "tt1234567", type: "series", preview: nil)
        XCTAssertEqual(cached?.name, "Fresh")
        XCTAssertEqual(fetchCount, 2)
    }
}

@MainActor
private final class WatchedMetadataGate {
    private let onStarted: () -> Void
    private var continuation: CheckedContinuation<NuvioMeta?, Never>?

    init(onStarted: @escaping () -> Void) { self.onStarted = onStarted }

    func fetch() async -> NuvioMeta? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onStarted()
        }
    }

    func finish(_ meta: NuvioMeta) {
        continuation?.resume(returning: meta)
        continuation = nil
    }
}

@MainActor
private final class LibraryItemsResponseGate {
    private let onStarted: () -> Void
    private var continuation: CheckedContinuation<Void, Never>?

    init(onStarted: @escaping () -> Void) { self.onStarted = onStarted }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            onStarted()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
