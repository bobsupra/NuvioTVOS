import XCTest
@testable import NuvioTV

@MainActor
final class MultiServiceScrobbleTests: XCTestCase {
    private var testProfileID: String!
    private var previousSettingsProfileID: String?
    private var previousSettingsProfileIsPrimary = false
    private var previousWatchedProfileID: String?
    private var previousContinueWatchingProfileID: String?
    private var secondaryTestProfileID: String?
    private var checkpointTestMetas: [NuvioMeta] = []

    override func setUp() {
        super.setUp()
        previousSettingsProfileID = ProfileSettings.activeProfileID
        previousSettingsProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousWatchedProfileID = WatchedStore.activeProfileId
        previousContinueWatchingProfileID = ContinueWatchingStore.activeProfileId

        testProfileID = "multi-scrobble-\(UUID().uuidString)"
        activateProfile(testProfileID, isPrimary: true)
    }

    override func tearDown() {
        let profileIDs = [testProfileID, secondaryTestProfileID].compactMap { $0 }
        for profileID in profileIDs {
            for meta in checkpointTestMetas {
                TraktProgressService.forgetLocalPlaybackForCompletion(
                    meta: meta,
                    profileId: profileID,
                    notify: false
                )
            }
        }
        if let testProfileID {
            MdbListKeychainTokenStorage().remove(for: testProfileID)
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(testProfileID)")
        }
        if let secondaryTestProfileID {
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(secondaryTestProfileID)")
        }
        MdbListKeychainTokenStorage().remove(for: ProfileSettings.activeProfileScope)
        WatchedStore.setActiveProfile(previousWatchedProfileID)
        ContinueWatchingStore.setActiveProfile(previousContinueWatchingProfileID)
        if let previousSettingsProfileID {
            ProfileSettings.setActiveProfile(previousSettingsProfileID, isPrimary: previousSettingsProfileIsPrimary)
        } else {
            ProfileSettings.clearActiveProfile()
        }
        testProfileID = nil
        secondaryTestProfileID = nil
        checkpointTestMetas = []
        super.tearDown()
    }

    private func activateProfile(_ profileID: String, isPrimary: Bool = false) {
        ProfileSettings.setActiveProfile(profileID, isPrimary: isPrimary)
        WatchedStore.setActiveProfile(profileID)
        ContinueWatchingStore.setActiveProfile(profileID)
    }

    private func checkpointMeta(_ name: String) -> NuvioMeta {
        let meta = NuvioMeta(
            id: "multi-scrobble-checkpoint-\(UUID().uuidString)",
            name: name,
            type: "series"
        )
        checkpointTestMetas.append(meta)
        return meta
    }

    private func continueWatchingItem(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        lastWatchedAt: Date,
        season: Int?,
        episode: Int?
    ) -> ContinueWatchingItem {
        ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: position,
            duration: duration,
            lastWatchedAt: lastWatchedAt,
            season: season,
            episode: episode
        )
    }

    private func publishRemoteProgress(
        _ remote: ContinueWatchingItem,
        source: TraktWatchProgressSource
    ) -> ContinueWatchingItem? {
        ProfileSettings.current.set(source.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        let context = TraktProgressService.ContinueWatchingFetchContext(
            source: source,
            updateDisplayedSnapshot: true
        )
        return TraktProgressService.finalizeContinueWatchingFetch([remote], context: context)?.first {
            WatchedStore.sameContent($0.meta, remote.meta)
                && $0.season == remote.season
                && $0.episode == remote.episode
        }
    }

    private func authenticateTrakt(in store: UserDefaults, slug: String = "test-trakt-user") {
        let clientID = "test-client-id"
        store.set(clientID, forKey: SettingsKey.traktClientID)
        store.set(true, forKey: SettingsKey.traktConnected)
        let tokenResponse = TraktTokenResponse(
            accessToken: "test-trakt-access",
            tokenType: "Bearer",
            expiresIn: 3600,
            refreshToken: "test-trakt-refresh",
            createdAt: 0
        )
        TraktAuthStore.saveToken(tokenResponse, clientID: clientID, store: store)
        TraktAuthStore.saveUser(username: "Test", slug: slug, store: store)
    }

    private func authenticateMdbList(in store: UserDefaults, tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage()) {
        let tokens = MdbListStoredTokens(
            accessToken: "test-mdblist-access",
            refreshToken: "test-mdblist-refresh",
            expiresAtMillis: Date().timeIntervalSince1970 * 1_000 + 3_600_000
        )
        let scope = MdbListRuntimeSession.profileScope()
        _ = MdbListAuthStore.saveTokens(
            tokens,
            user: MdbListUser(accountID: "1", username: "testuser", displayName: "Test User"),
            profileScope: scope,
            store: store,
            tokenStorage: tokenStorage
        )
    }

    func testNuvioSyncMirrorDefaultsOffAndIsProfileScoped() {
        let store = ProfileSettings.current
        store.set(TraktWatchProgressSource.trakt.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        XCTAssertFalse(RemoteTrackingState.isNuvioSyncScrobbleEnabled(in: store))
        XCTAssertFalse(RemoteTrackingState.shouldSaveNuvioSyncPlayback(usesRemoteProgress: true, in: store))
        XCTAssertTrue(RemoteTrackingState.shouldSaveNuvioSyncPlayback(usesRemoteProgress: false, in: store))

        store.set(true, forKey: SettingsKey.nuvioSyncScrobbleEnabled)
        XCTAssertTrue(RemoteTrackingState.shouldSaveNuvioSyncPlayback(usesRemoteProgress: true, in: store))
        XCTAssertEqual(TraktSettingsStore.watchProgressSource(in: store), .trakt)
        XCTAssertFalse(RemoteTrackingState.activeScrobbleSources(in: store).contains(.nuvioSync))

        secondaryTestProfileID = "nuvio-mirror-isolation-\(UUID().uuidString)"
        let otherStore = ProfileSettings.store(for: secondaryTestProfileID!)
        XCTAssertFalse(RemoteTrackingState.isNuvioSyncScrobbleEnabled(in: otherStore))
        XCTAssertFalse(RemoteTrackingState.shouldSaveNuvioSyncPlayback(usesRemoteProgress: true, in: otherStore))
    }

    func testNuvioSyncMirrorOwnershipDoesNotEnableAccountSyncMaster() {
        let store = ProfileSettings.current
        authenticateTrakt(in: store)
        store.set(TraktWatchProgressSource.trakt.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        XCTAssertFalse(NuvioSyncManager.ownsWatchState(for: testProfileID))

        store.set(true, forKey: SettingsKey.nuvioSyncScrobbleEnabled)
        XCTAssertTrue(NuvioSyncManager.ownsWatchState(for: testProfileID))
        store.set(false, forKey: SettingsKey.accountSyncWatchState)
        XCTAssertFalse(NuvioSyncManager.watchStateSyncEnabled(for: testProfileID))
        XCTAssertEqual(store.object(forKey: SettingsKey.accountSyncWatchState) as? Bool, false)
    }

    func testRemotePlaybackSavesMeasuredNuvioProgressOnlyWhenMirrorIsEnabled() throws {
        let store = ProfileSettings.current
        authenticateTrakt(in: store)
        store.set(TraktWatchProgressSource.trakt.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        let meta = checkpointMeta("Nuvio mirror playback")
        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil }, engineSettingProvider: { "MPVKit" }, loadDispatcher: { _, _, _ in }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator)
        defer {
            model.shutdown()
            coordinator.stopAll()
            ContinueWatchingStore.eraseProfile(testProfileID)
            WatchedStore.eraseProfile(testProfileID)
        }
        model.load(url: URL(fileURLWithPath: "/tmp/nuvio-mirror-playback.mkv"), meta: meta, subtitle: "S1 · E1", resumeFrom: 6)
        model.status = .playing
        model.time = PlayerTime(current: 1449, duration: 2469)
        XCTAssertEqual(coordinator.playbackCompletionTracker?.source, .trakt)
        model.saveProgress(force: true, eventAction: .pause)
        XCTAssertFalse(WatchProgressLedger.records(profileId: testProfileID).contains { $0.contentId == meta.id })

        store.set(true, forKey: SettingsKey.nuvioSyncScrobbleEnabled)
        model.saveProgress(force: true, eventAction: .pause)
        let record = try XCTUnwrap(WatchProgressLedger.records(profileId: testProfileID).first { $0.contentId == meta.id })
        XCTAssertEqual(record.position, 1449)
        XCTAssertEqual(record.duration, 2469)
        XCTAssertEqual(record.season, 1)
        XCTAssertEqual(record.episode, 1)
        XCTAssertTrue(record.isPendingPush)
        XCTAssertEqual(TraktSettingsStore.watchProgressSource(in: store), .trakt)
    }

    func testOldRemotePlaybackCannotWriteIntoUnauthenticatedNewProfile() {
        let store = ProfileSettings.current
        authenticateTrakt(in: store)
        store.set(TraktWatchProgressSource.trakt.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        store.set(true, forKey: SettingsKey.nuvioSyncScrobbleEnabled)
        let meta = checkpointMeta("Profile-isolated Nuvio mirror")
        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil }, engineSettingProvider: { "MPVKit" }, loadDispatcher: { _, _, _ in }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator)
        defer {
            model.shutdown()
            coordinator.stopAll()
            ContinueWatchingStore.eraseProfile(testProfileID)
            WatchedStore.eraseProfile(testProfileID)
            if let secondaryTestProfileID {
                ContinueWatchingStore.eraseProfile(secondaryTestProfileID)
                WatchedStore.eraseProfile(secondaryTestProfileID)
            }
        }
        model.load(url: URL(fileURLWithPath: "/tmp/nuvio-mirror-profile-switch.mkv"), meta: meta, subtitle: "S1 · E1", resumeFrom: 6)
        model.status = .playing
        model.time = PlayerTime(current: 1449, duration: 2469)
        XCTAssertEqual(coordinator.playbackCompletionTracker?.profileID, testProfileID)
        XCTAssertEqual(coordinator.playbackCompletionTracker?.source, .trakt)
        secondaryTestProfileID = "nuvio-mirror-player-profile-\(UUID().uuidString)"
        activateProfile(secondaryTestProfileID!)
        XCTAssertFalse(TraktAuthStore.isAuthenticated(in: ProfileSettings.current))
        model.saveProgress(force: true, eventAction: .pause)
        XCTAssertTrue(WatchProgressLedger.records(profileId: secondaryTestProfileID).isEmpty)
        XCTAssertTrue(WatchProgressLedger.records(profileId: testProfileID).isEmpty)
    }

    func testNuvioSyncMirrorCompletionAttributionAndDeduplication() throws {
        defer {
            ContinueWatchingStore.eraseProfile(testProfileID)
            WatchedStore.eraseProfile(testProfileID)
        }
        let store = ProfileSettings.current
        authenticateTrakt(in: store)
        store.set(TraktWatchProgressSource.trakt.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        let accountID = try XCTUnwrap(TraktHistoryService.completionAccountID(in: store, profileId: testProfileID))
        let accounts = [TraktWatchProgressSource.trakt.rawValue: accountID]
        let meta = NuvioMeta(id: "tt1234567", name: "Mirrored episode", imdbId: "tt1234567", type: "series")
        XCTAssertTrue(WatchedStore.recordPlaybackCompletion(
            meta, season: 1, episode: 1, completionID: "mirror-off", source: .trakt, completionAccounts: accounts
        ))
        let off = try XCTUnwrap(WatchedStore.items().first { $0.meta.id == meta.id && $0.episode == 1 })
        XCTAssertFalse(off.isVisible(under: .nuvioSync))

        store.set(true, forKey: SettingsKey.nuvioSyncScrobbleEnabled)
        for _ in 0..<2 {
            XCTAssertTrue(WatchedStore.recordPlaybackCompletion(
                meta, season: 1, episode: 2, completionID: "mirror-on", source: .trakt, completionAccounts: accounts
            ))
        }
        let on = try XCTUnwrap(WatchedStore.items().first { $0.meta.id == meta.id && $0.episode == 2 })
        XCTAssertTrue(on.isVisible(under: .nuvioSync))
        XCTAssertTrue(on.isVisible(under: .trakt))
        XCTAssertEqual(on.watchCountsBySource[TraktWatchProgressSource.nuvioSync.rawValue], 1)
        XCTAssertEqual(on.watchCountsBySource[TraktWatchProgressSource.trakt.rawValue], 1)
        XCTAssertEqual(Set(WatchedStore.pendingPlaybackCompletions(provider: .trakt, profileId: testProfileID).map(\.completionID)), ["mirror-off", "mirror-on"])
        XCTAssertTrue(WatchedStore.pendingPlaybackCompletions(provider: .nuvioSync, profileId: testProfileID).isEmpty)
    }

    // MARK: - Scrobble Enabled Defaults and Toggles

    func testScrobbleEnabledDefaultsToFalseUntilUserToggles() {
        let store = ProfileSettings.current

        authenticateTrakt(in: store)

        // Should be authenticated
        XCTAssertTrue(RemoteTrackingState.isProgressSourceAuthenticated(.trakt, in: store))

        // Off by default until the user explicitly toggles it on
        XCTAssertFalse(RemoteTrackingState.isScrobbleEnabled(for: .trakt, in: store))

        // Toggle to true
        RemoteTrackingState.setScrobbleEnabled(true, for: .trakt, in: store)
        XCTAssertTrue(RemoteTrackingState.isScrobbleEnabled(for: .trakt, in: store))

        // Toggle back to false
        RemoteTrackingState.setScrobbleEnabled(false, for: .trakt, in: store)
        XCTAssertFalse(RemoteTrackingState.isScrobbleEnabled(for: .trakt, in: store))
    }

    func testScrobbleDisabledWhenUnauthenticated() {
        let store = ProfileSettings.current
        // No tokens saved -> not authenticated
        XCTAssertFalse(RemoteTrackingState.isProgressSourceAuthenticated(.trakt, in: store))
        XCTAssertFalse(RemoteTrackingState.isScrobbleEnabled(for: .trakt, in: store))

        // Nuvio Sync is never a scrobble target
        XCTAssertFalse(RemoteTrackingState.isScrobbleEnabled(for: .nuvioSync, in: store))
    }

    func testActiveScrobbleSourcesReflectsOnlyAuthenticatedAndEnabledServices() {
        let store = ProfileSettings.current

        authenticateTrakt(in: store)
        authenticateMdbList(in: store)

        // Initially both are authenticated but scrobble is off by default
        XCTAssertTrue(RemoteTrackingState.activeScrobbleSources(in: store).isEmpty)

        // Explicitly enable scrobble for Trakt and MDBList
        RemoteTrackingState.setScrobbleEnabled(true, for: .trakt, in: store)
        RemoteTrackingState.setScrobbleEnabled(true, for: .mdblist, in: store)

        let active = RemoteTrackingState.activeScrobbleSources(in: store)
        XCTAssertTrue(active.contains(.trakt))
        XCTAssertTrue(active.contains(.mdblist))
        XCTAssertFalse(active.contains(.simkl))
        XCTAssertFalse(active.contains(.nuvioSync))

        // Disable MDBList scrobble
        RemoteTrackingState.setScrobbleEnabled(false, for: .mdblist, in: store)
        let activeAfterDisable = RemoteTrackingState.activeScrobbleSources(in: store)
        XCTAssertTrue(activeAfterDisable.contains(.trakt))
        XCTAssertFalse(activeAfterDisable.contains(.mdblist))
    }

    func testMdbListWithApiKeyOnlyEnablesLibraryAndProgressWithoutOAuthSession() {
        let store = ProfileSettings.current
        store.set("ratings-api-key", forKey: SettingsKey.mdbListApiKey)
        store.set(true, forKey: SettingsKey.mdbListEnabled)

        // The API key enables library/progress access, but is not an OAuth session and does not enable scrobbling by default.
        XCTAssertFalse(MdbListRuntimeSession.isAuthenticated(in: store))
        XCTAssertTrue(RemoteTrackingState.isProgressSourceAuthenticated(.mdblist, in: store))
        XCTAssertTrue(RemoteTrackingState.isLibrarySourceAuthenticated(.mdblist, in: store))
        XCTAssertTrue(RemoteTrackingState.availableProgressSources(in: store).contains(.mdblist))
        XCTAssertTrue(RemoteTrackingState.availableLibrarySources(in: store).contains(.mdblist))
        XCTAssertFalse(RemoteTrackingState.isScrobbleEnabled(for: .mdblist, in: store))
    }

    // MARK: - Continue Watching Source Independence

    func testContinueWatchingSourceCanBeNuvioSyncWhileScrobbleRemainsActive() {
        let store = ProfileSettings.current

        authenticateTrakt(in: store)
        authenticateMdbList(in: store)

        // Enable scrobble for Trakt and MDBList
        RemoteTrackingState.setScrobbleEnabled(true, for: .trakt, in: store)
        RemoteTrackingState.setScrobbleEnabled(true, for: .mdblist, in: store)

        // Set Continue Watching source to Nuvio Sync
        store.set(TraktWatchProgressSource.nuvioSync.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        XCTAssertEqual(TraktSettingsStore.watchProgressSource(in: store), .nuvioSync)

        // Both Trakt and MDBList are still active scrobble targets
        let active = RemoteTrackingState.activeScrobbleSources(in: store)
        XCTAssertTrue(active.contains(.trakt))
        XCTAssertTrue(active.contains(.mdblist))
    }

    // MARK: - Watched History Routing

    func testRoutesWatchedHistoryWhenScrobbleIsEnabled() {
        let store = ProfileSettings.current

        authenticateTrakt(in: store)
        authenticateMdbList(in: store)

        // Enable scrobble for Trakt and MDBList
        RemoteTrackingState.setScrobbleEnabled(true, for: .trakt, in: store)
        RemoteTrackingState.setScrobbleEnabled(true, for: .mdblist, in: store)

        // Even when source is Nuvio Sync, scrobble-enabled services receive watched history
        store.set(TraktWatchProgressSource.nuvioSync.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        XCTAssertTrue(RemoteTrackingState.shouldSyncWatchedHistory(to: .trakt, in: store))
        XCTAssertTrue(RemoteTrackingState.shouldSyncWatchedHistory(to: .mdblist, in: store))
        XCTAssertTrue(RemoteTrackingState.routesWatchedHistory(to: .trakt, selectedSource: .nuvioSync, in: store))

        // When scrobble is explicitly disabled, it stops routing
        RemoteTrackingState.setScrobbleEnabled(false, for: .mdblist, in: store)
        XCTAssertFalse(RemoteTrackingState.shouldSyncWatchedHistory(to: .mdblist, in: store))
    }

    // MARK: - Periodic Scrobble Policy

    func testInitialPeriodicReportStartsWithoutHeartbeatFlag() {
        let policy = PlayerViewModel.scrobbleReportPolicy(
            action: nil,
            primarySource: .trakt,
            didStartTraktScrobble: false,
            isPeriodicHeartbeat: true
        )

        XCTAssertEqual(policy.action, .start)
        XCTAssertFalse(policy.isPeriodicHeartbeat)
    }

    func testLaterPeriodicReportKeepsStartAndUsesHeartbeatFlag() {
        let policy = PlayerViewModel.scrobbleReportPolicy(
            action: nil,
            primarySource: .trakt,
            didStartTraktScrobble: true,
            isPeriodicHeartbeat: true
        )

        XCTAssertEqual(policy.action, .start)
        XCTAssertTrue(policy.isPeriodicHeartbeat)
    }

    func testExplicitStartAndPauseAreNotPeriodicHeartbeats() {
        for action in [TraktScrobbleAction.start, .pause] {
            let policy = PlayerViewModel.scrobbleReportPolicy(
                action: action,
                primarySource: .trakt,
                didStartTraktScrobble: true,
                isPeriodicHeartbeat: true
            )

            XCTAssertEqual(policy.action, action)
            XCTAssertFalse(policy.isPeriodicHeartbeat)
        }
    }

    func testStopPolicyStillMapsOnlyTraktAndWeTrakrPrimaryToPause() {
        for source in [TraktWatchProgressSource.trakt, .wetrakr] {
            let policy = PlayerViewModel.scrobbleReportPolicy(
                action: .stop,
                primarySource: source,
                didStartTraktScrobble: true,
                isPeriodicHeartbeat: true
            )

            XCTAssertEqual(policy.action, .pause)
            XCTAssertFalse(policy.isPeriodicHeartbeat)
        }

        let simklPolicy = PlayerViewModel.scrobbleReportPolicy(
            action: .stop,
            primarySource: .simkl,
            didStartTraktScrobble: true,
            isPeriodicHeartbeat: true
        )
        XCTAssertEqual(simklPolicy.action, .stop)
        XCTAssertFalse(simklPolicy.isPeriodicHeartbeat)
    }

    // MARK: - Multi-Service Resume Checkpoints

    func testNuvioSyncPrimaryCheckpointOverridesStaleProviderRuntimeEstimates() {
        let meta = checkpointMeta("Measured episode")
        let measuredPosition = 1_449.0
        let measuredDuration = 2_469.0
        let season = 1
        let episode = 2

        TraktProgressService.recordLocalPlaybackForScrobbleSources(
            meta: meta,
            position: measuredPosition,
            duration: measuredDuration,
            season: season,
            episode: episode,
            primarySource: .nuvioSync,
            scrobbleSources: [.simkl, .mdblist, .wetrakr, .mdblist],
            notify: false
        )

        let staleRows: [(TraktWatchProgressSource, Double, Double)] = [
            (.simkl, 2_700, 1_350),
            (.mdblist, 3_000, 1_620),
            (.wetrakr, 3_600, 2_000)
        ]
        for (source, estimatedDuration, stalePosition) in staleRows {
            XCTAssertNotEqual(stalePosition, measuredPosition)
            let remote = continueWatchingItem(
                meta: meta,
                position: stalePosition,
                duration: estimatedDuration,
                lastWatchedAt: Date().addingTimeInterval(2),
                season: season,
                episode: episode
            )

            let merged = publishRemoteProgress(remote, source: source)
            XCTAssertEqual(merged?.position, measuredPosition, "\(source.rawValue) should keep the measured stream position")
            XCTAssertEqual(merged?.duration, measuredDuration, "\(source.rawValue) should keep the measured stream duration")
            XCTAssertEqual(
                TraktProgressService.currentContinueWatchingItem(for: meta, source: source)?.position,
                measuredPosition
            )
        }
    }

    func testLaterRemoteAcknowledgementAdvancesProgressAndKeepsNewerEpisode() {
        let progressMeta = checkpointMeta("Remote progress acknowledgement")
        let nextEpisodeMeta = checkpointMeta("Remote next episode")
        let measuredPosition = 1_449.0
        let measuredDuration = 2_469.0

        for meta in [progressMeta, nextEpisodeMeta] {
            TraktProgressService.recordLocalPlaybackForScrobbleSources(
                meta: meta,
                position: measuredPosition,
                duration: measuredDuration,
                season: 1,
                episode: 2,
                primarySource: .nuvioSync,
                scrobbleSources: [.simkl],
                notify: false
            )
        }

        let remoteDate = Date().addingTimeInterval(60)
        let remoteProgress = continueWatchingItem(
            meta: progressMeta,
            position: 2_700 * 0.78,
            duration: 2_700,
            lastWatchedAt: remoteDate,
            season: 1,
            episode: 2
        )
        let remoteNextEpisode = continueWatchingItem(
            meta: nextEpisodeMeta,
            position: 1_800 * 0.35,
            duration: 1_800,
            lastWatchedAt: remoteDate,
            season: 1,
            episode: 3
        )

        let merged = TraktProgressService.mergingLocalPlaybackCheckpoints(
            into: [remoteProgress, remoteNextEpisode],
            source: .simkl,
            profileId: testProfileID
        )

        let advancedItem = merged.first { WatchedStore.sameContent($0.meta, progressMeta) }
        XCTAssertEqual(advancedItem?.position ?? 0, measuredDuration * 0.78, accuracy: 0.01)
        XCTAssertEqual(advancedItem?.duration, measuredDuration)
        XCTAssertEqual(advancedItem?.lastWatchedAt, remoteDate)

        let nextEpisodeItem = merged.first { WatchedStore.sameContent($0.meta, nextEpisodeMeta) }
        XCTAssertEqual(nextEpisodeItem?.season, 1)
        XCTAssertEqual(nextEpisodeItem?.episode, 3)
        XCTAssertNil(TraktProgressService.currentContinueWatchingItem(for: progressMeta, source: .simkl))
        XCTAssertNil(TraktProgressService.currentContinueWatchingItem(for: nextEpisodeMeta, source: .simkl))
    }

    func testCompletionCleanupUsesCapturedProfileEpisodeAndCutoff() async throws {
        let meta = checkpointMeta("Completion cleanup")
        let priorSources: [TraktWatchProgressSource] = [.simkl, .mdblist, .wetrakr]

        for source in priorSources {
            TraktProgressService.recordLocalPlaybackForScrobbleSources(
                meta: meta,
                position: 120,
                duration: 1_000,
                season: 1,
                episode: 2,
                primarySource: .nuvioSync,
                scrobbleSources: [source],
                notify: false
            )
            let remote = continueWatchingItem(
                meta: meta,
                position: 220,
                duration: 1_000,
                lastWatchedAt: Date(),
                season: 1,
                episode: 2
            )
            XCTAssertNotNil(publishRemoteProgress(remote, source: source))
        }

        let otherProfileID = "multi-scrobble-other-\(UUID().uuidString)"
        secondaryTestProfileID = otherProfileID
        activateProfile(otherProfileID)
        TraktProgressService.recordLocalPlaybackForScrobbleSources(
            meta: meta,
            position: 640,
            duration: 1_000,
            season: 1,
            episode: 2,
            primarySource: .nuvioSync,
            scrobbleSources: [.simkl],
            notify: false
        )
        activateProfile(testProfileID, isPrimary: true)

        let completionCutoff = Date().addingTimeInterval(0.05)
        try await Task.sleep(nanoseconds: 100_000_000)
        TraktProgressService.recordLocalPlayback(
            meta: meta,
            position: 260,
            duration: 1_000,
            season: 1,
            episode: 2,
            source: .trakt,
            notify: false
        )
        TraktProgressService.recordLocalPlayback(
            meta: meta,
            position: 360,
            duration: 1_000,
            season: 1,
            episode: 3,
            source: .mdblist,
            notify: false
        )

        TraktProgressService.forgetLocalPlaybackForCompletion(
            meta: meta,
            season: 1,
            episode: 2,
            profileId: testProfileID,
            recordedNoLaterThan: completionCutoff,
            notify: false
        )

        XCTAssertNil(TraktProgressService.currentContinueWatchingItem(for: meta, source: .simkl))
        XCTAssertNil(TraktProgressService.currentContinueWatchingItem(for: meta, source: .wetrakr))
        let newerEpisode = TraktProgressService.currentContinueWatchingItem(for: meta, source: .mdblist)
        XCTAssertEqual(newerEpisode?.episode, 3)
        XCTAssertEqual(newerEpisode?.position, 360)
        let laterPlayback = TraktProgressService.currentContinueWatchingItem(for: meta, source: .trakt)
        XCTAssertEqual(laterPlayback?.episode, 2)
        XCTAssertEqual(laterPlayback?.position, 260)
        XCTAssertGreaterThan(laterPlayback?.lastWatchedAt ?? .distantPast, completionCutoff)

        activateProfile(otherProfileID)
        let otherProfileCheckpoint = TraktProgressService.currentContinueWatchingItem(for: meta, source: .simkl)
        XCTAssertEqual(otherProfileCheckpoint?.episode, 2)
        XCTAssertEqual(otherProfileCheckpoint?.position, 640)
        activateProfile(testProfileID, isPrimary: true)

        TraktProgressService.forgetLocalPlaybackForCompletion(
            meta: meta,
            season: 1,
            episode: 3,
            profileId: testProfileID,
            recordedNoLaterThan: Date().addingTimeInterval(10),
            notify: false
        )
        XCTAssertNil(TraktProgressService.currentContinueWatchingItem(for: meta, source: .mdblist))
        XCTAssertEqual(
            TraktProgressService.currentContinueWatchingItem(for: meta, source: .trakt)?.position,
            260
        )
    }

    func testSelectedSourceRemovalLeavesOtherSourceCheckpoint() {
        let meta = checkpointMeta("Selected provider removal")
        TraktProgressService.recordLocalPlaybackForScrobbleSources(
            meta: meta,
            position: 700,
            duration: 2_000,
            season: 1,
            episode: 2,
            primarySource: .trakt,
            scrobbleSources: [.simkl, .trakt, .simkl],
            notify: false
        )
        ProfileSettings.current.set(TraktWatchProgressSource.trakt.rawValue, forKey: SettingsKey.traktWatchProgressSource)

        TraktProgressService.forgetLocalPlayback(
            meta: meta,
            season: 1,
            episode: 2,
            notify: false
        )

        XCTAssertNil(TraktProgressService.currentContinueWatchingItem(for: meta, source: .trakt))
        XCTAssertEqual(
            TraktProgressService.currentContinueWatchingItem(for: meta, source: .simkl)?.position,
            700
        )
    }

    // MARK: - WatchedStore Snapshot Visibility

    func testWatchedStoreSnapshotIncludesActiveScrobbleSources() {
        let store = ProfileSettings.current

        authenticateTrakt(in: store)
        authenticateMdbList(in: store)
        store.set(TraktWatchProgressSource.nuvioSync.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        RemoteTrackingState.setScrobbleEnabled(true, for: .trakt, in: store)
        RemoteTrackingState.setScrobbleEnabled(true, for: .mdblist, in: store)

        let movie = NuvioMeta(
            id: "tt7654321",
            name: "Trakt Only Movie",
            imdbId: "tt7654321",
            type: "movie",
            year: 2024
        )
        let traktItem = WatchedStoreItem(
            meta: movie,
            watchedAt: Date(),
            season: nil,
            episode: nil,
            sources: [TraktWatchProgressSource.trakt.rawValue]
        )
        WatchedStore.replaceAll([traktItem])

        let snapshot = WatchedStore.currentSnapshot()
        XCTAssertEqual(snapshot.source, .nuvioSync)
        XCTAssertTrue(snapshot.contains(metaId: movie.id, type: movie.canonicalType))
    }
}
