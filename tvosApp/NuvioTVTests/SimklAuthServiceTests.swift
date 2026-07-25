import Foundation
import XCTest
@testable import NuvioTV

final class SimklAuthServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tokenStorage: SimklMemoryTokenStorage!

    override func setUp() {
        super.setUp()
        suiteName = "SimklAuthServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("client-id", forKey: SettingsKey.simklClientID)
        tokenStorage = SimklMemoryTokenStorage()
    }

    override func tearDown() {
        SimklURLProtocolStub.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        tokenStorage = nil
        super.tearDown()
    }

    func testStartPINAuthPersistsFlowAndRequiredRequestMetadata() async throws {
        SimklURLProtocolStub.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query: [String: String] = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
                    guard let value = $0.value else { return nil }
                    return ($0.name, value)
                }
            )

            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(components.path, "/oauth/pin")
            XCTAssertEqual(query["client_id"], "client-id")
            XCTAssertEqual(query["app-name"], SimklConfig.appName)
            XCTAssertEqual(query["app-version"], SimklConfig.appVersion)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), SimklConfig.userAgent)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Cache-Control"),
                "no-cache, no-store"
            )

            return Self.response(
                for: request,
                json: """
                {
                  "result": "OK",
                  "device_code": "DEVICE_CODE",
                  "user_code": "ABC123",
                  "verification_uri": "https://simkl.com/pin",
                  "expires_in": 900,
                  "interval": 5
                }
                """
            )
        }

        let service = makeService()
        let response = try await service.startPINAuth()
        let state = service.currentState()

        XCTAssertEqual(response.userCode, "ABC123")
        XCTAssertEqual(state.userCode, "ABC123")
        XCTAssertEqual(state.verificationURI, "https://simkl.com/pin")
        XCTAssertEqual(state.pollInterval, 5)
        XCTAssertEqual(state.credentialClientID, "client-id")
        XCTAssertTrue(state.hasActivePINFlow(in: defaults))
    }

    func testPollPendingKeepsPINFlow() async throws {
        SimklURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/oauth/pin":
                return Self.pinResponse(for: request)
            case "/oauth/pin/ABC123":
                return Self.response(
                    for: request,
                    json: #"{"result":"KO","message":"Authorization pending"}"#
                )
            default:
                XCTFail("Unexpected Simkl request: \(request.url?.absoluteString ?? "nil")")
                return Self.response(for: request, status: 404, json: #"{"error":"not_found"}"#)
            }
        }

        let service = makeService()
        _ = try await service.startPINAuth()
        let result = await service.pollPINToken()

        guard case .pending = result else {
            return XCTFail("Expected pending result")
        }
        XCTAssertTrue(service.currentState().hasActivePINFlow(in: defaults))
    }

    func testApprovedPINStoresTokenAndLoadsAccount() async throws {
        SimklURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/oauth/pin":
                return Self.pinResponse(for: request)
            case "/oauth/pin/ABC123":
                return Self.response(
                    for: request,
                    json: #"{"result":"OK","access_token":"simkl-token"}"#
                )
            case "/users/settings":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer simkl-token"
                )
                return Self.response(
                    for: request,
                    json: """
                    {
                      "user": {"name": "nuvio-user", "avatar": "https://example.com/avatar.jpg"},
                      "account": {"id": 42, "type": "vip"}
                    }
                    """
                )
            default:
                XCTFail("Unexpected Simkl request: \(request.url?.absoluteString ?? "nil")")
                return Self.response(for: request, status: 404, json: #"{"error":"not_found"}"#)
            }
        }

        let service = makeService()
        _ = try await service.startPINAuth()
        let result = await service.pollPINToken()

        guard case .approved(let username) = result else {
            return XCTFail("Expected approved result")
        }
        XCTAssertEqual(username, "nuvio-user")

        let state = service.currentState()
        XCTAssertTrue(state.isAuthenticated(in: defaults))
        XCTAssertEqual(state.accessToken, "simkl-token")
        XCTAssertEqual(state.username, "nuvio-user")
        XCTAssertEqual(state.accountID, "42")
        XCTAssertEqual(state.accountPlan, "vip")
        XCTAssertNil(state.userCode)
    }

    func testFreshPINResponseWhilePollingInvalidatesOriginalFlow() async throws {
        SimklURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/oauth/pin":
                return Self.pinResponse(for: request)
            case "/oauth/pin/ABC123":
                return Self.response(
                    for: request,
                    json: """
                    {
                      "result": "OK",
                      "device_code": "DEVICE_CODE",
                      "user_code": "NEW456",
                      "verification_uri": "https://simkl.com/pin",
                      "expires_in": 900,
                      "interval": 5
                    }
                    """
                )
            default:
                XCTFail("Unexpected Simkl request: \(request.url?.absoluteString ?? "nil")")
                return Self.response(for: request, status: 404, json: #"{"error":"not_found"}"#)
            }
        }

        let service = makeService()
        _ = try await service.startPINAuth()
        let result = await service.pollPINToken()

        guard case .originalCodeGone = result else {
            return XCTFail("Expected originalCodeGone result")
        }
        XCTAssertFalse(service.currentState().hasActivePINFlow(in: defaults))
    }

    func testChangingClientIDClearsBoundToken() {
        SimklAuthStore.saveToken(
            "simkl-token",
            clientID: "client-id",
            profileScope: "profile-1",
            store: defaults,
            tokenStorage: tokenStorage
        )
        defaults.set("replacement-client", forKey: SettingsKey.simklClientID)

        let service = makeService()

        XCTAssertTrue(service.invalidateIfCredentialsChanged())
        XCTAssertNil(service.currentState().accessToken)
        XCTAssertFalse(service.currentState().isAuthenticated(in: defaults))
    }

    /// `skip_auto_watching` only does anything when the same request sets an
    /// explicit `status` on the show, which this integration never does — and it
    /// is meaningless once the body names the episodes outright. Sending it
    /// looked like it suppressed something; it never did.
    func testHistoryWriteUsesEpisodePayloadWithoutDeadQueryParam() async throws {
        authorize()
        SimklURLProtocolStub.handler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(components.path, "/sync/history")
            XCTAssertNil(components.queryItems?.first { $0.name == "skip_auto_watching" })
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer simkl-token")

            let json = try Self.jsonBody(request)
            let shows = try XCTUnwrap(json["shows"] as? [[String: Any]])
            let show = try XCTUnwrap(shows.first)
            XCTAssertEqual(show["title"] as? String, "Example Show")
            let seasons = try XCTUnwrap(show["seasons"] as? [[String: Any]])
            XCTAssertEqual(seasons.first?["number"] as? Int, 2)
            let episodes = try XCTUnwrap(seasons.first?["episodes"] as? [[String: Any]])
            XCTAssertEqual(episodes.first?["number"] as? Int, 4)
            XCTAssertNotNil(episodes.first?["watched_at"] as? String)

            return Self.response(for: request, status: 201, json: "{}")
        }

        let result = await SimklHistoryService.setWatched(
            makeMeta(type: "series"),
            season: 2,
            episode: 4,
            isWatched: true,
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )

        XCTAssertTrue(result)
    }

    func testPlanToWatchWriteEncodesPerItemDestination() async throws {
        authorize()
        defaults.set(
            TraktLibrarySourceMode.simkl.rawValue,
            forKey: SettingsKey.traktLibrarySourceMode
        )
        SimklURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/sync/add-to-list")
            let json = try Self.jsonBody(request)
            let movies = try XCTUnwrap(json["movies"] as? [[String: Any]])
            XCTAssertEqual(movies.first?["to"] as? String, "plantowatch")
            XCTAssertEqual(
                (movies.first?["ids"] as? [String: Any])?["imdb"] as? String,
                "tt1234567"
            )
            return Self.response(for: request, json: "{}")
        }

        let result = await SimklLibraryService.setWatchlist(
            makeMeta(type: "movie"),
            isInWatchlist: true,
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )

        XCTAssertTrue(result)
    }

    func testStopScrobbleTreatsRecentlyWatchedConflictAsSuccess() async throws {
        authorize()
        defaults.set(
            TraktWatchProgressSource.simkl.rawValue,
            forKey: SettingsKey.traktWatchProgressSource
        )
        SimklURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/scrobble/stop")
            let json = try Self.jsonBody(request)
            XCTAssertEqual(json["progress"] as? Double, 90)
            let movie = try XCTUnwrap(json["movie"] as? [String: Any])
            XCTAssertEqual(movie["title"] as? String, "Example Movie")
            XCTAssertNil(json["show"])
            return Self.response(
                for: request,
                status: 409,
                json: #"{"error":"already_watched"}"#
            )
        }

        let result = await SimklProgressService.reportPlayback(
            meta: makeMeta(type: "movie"),
            position: 90,
            duration: 100,
            season: nil,
            episode: nil,
            action: .stop,
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )

        XCTAssertTrue(result)
    }

    func testHistoryTransferGroupsEpisodesAndReachesOneHundredPercent() async throws {
        authorize()
        SimklURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/sync/history")
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            XCTAssertNil(components.queryItems?.first { $0.name == "skip_auto_watching" })

            let json = try Self.jsonBody(request)
            XCTAssertEqual((json["movies"] as? [[String: Any]])?.count, 1)
            let shows = try XCTUnwrap(json["shows"] as? [[String: Any]])
            XCTAssertEqual(shows.count, 1)
            let seasons = try XCTUnwrap(shows.first?["seasons"] as? [[String: Any]])
            XCTAssertEqual(seasons.count, 1)
            let episodes = try XCTUnwrap(seasons.first?["episodes"] as? [[String: Any]])
            XCTAssertEqual(episodes.compactMap { $0["number"] as? Int }.sorted(), [1, 2])
            return Self.response(for: request, json: "{}")
        }

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let show = makeMeta(type: "series")
        let items = [
            WatchedStoreItem(meta: makeMeta(type: "movie"), watchedAt: timestamp),
            WatchedStoreItem(meta: show, watchedAt: timestamp, season: 1, episode: 1),
            WatchedStoreItem(meta: show, watchedAt: timestamp, season: 1, episode: 2)
        ]
        let progress = SimklIntegerRecorder()

        let result = await SimklHistoryTransferService.transfer(
            items,
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        ) { value in
            await progress.append(value)
        }
        let recordedProgress = await progress.values()

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.transferred, 3)
        XCTAssertEqual(recordedProgress.first, 1)
        XCTAssertEqual(recordedProgress.last, 100)
    }

    func testLibraryTransferAddsMoviesAndShowsToPlanToWatchAndReachesOneHundredPercent() async throws {
        authorize()
        SimklURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/sync/add-to-list")

            let json = try Self.jsonBody(request)
            let movies = try XCTUnwrap(json["movies"] as? [[String: Any]])
            let shows = try XCTUnwrap(json["shows"] as? [[String: Any]])
            XCTAssertEqual(movies.count, 1)
            XCTAssertEqual(shows.count, 1)
            XCTAssertEqual(movies.first?["to"] as? String, "plantowatch")
            XCTAssertEqual(shows.first?["to"] as? String, "plantowatch")
            return Self.response(for: request, status: 201, json: "{}")
        }

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            LibraryStoreItem(meta: makeMeta(type: "movie"), addedAt: timestamp),
            LibraryStoreItem(meta: makeMeta(type: "series"), addedAt: timestamp)
        ]
        let progress = SimklIntegerRecorder()

        let result = await SimklLibraryTransferService.transfer(
            items,
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        ) { value in
            await progress.append(value)
        }
        let recordedProgress = await progress.values()

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.transferred, 2)
        XCTAssertEqual(recordedProgress.first, 1)
        XCTAssertEqual(recordedProgress.last, 100)
    }

    func testProgressTransferPausesMoviesAndEpisodesAndReachesOneHundredPercent() async throws {
        authorize()
        // A successful transfer calls through to `recordLocalPlayback`, which
        // writes a genuine resume row to the file-backed progress stores keyed
        // by the *active* profile — no `store:` parameter reaches it. Unscoped,
        // this test's fake "Example Show S2E4" lands in a real install's
        // Continue Watching row and stays there.
        let profileId = "progress-transfer-tests"
        ContinueWatchingStore.setActiveProfile(profileId)
        WatchedStore.setActiveProfile(profileId)
        defer {
            ContinueWatchingStore.eraseProfile(profileId)
            WatchedStore.eraseProfile(profileId)
        }

        let submittedTitlesLock = NSLock()
        var submittedTitles: [String] = []
        SimklURLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/scrobble/pause")

            let json = try Self.jsonBody(request)
            XCTAssertEqual(json["progress"] as? Double, 25)
            if let show = json["show"] as? [String: Any] {
                XCTAssertEqual(show["title"] as? String, "Example Show")
                submittedTitlesLock.withLock {
                    submittedTitles.append("Example Show")
                }
                let episode = try XCTUnwrap(json["episode"] as? [String: Any])
                XCTAssertEqual(episode["season"] as? Int, 2)
                XCTAssertEqual(episode["number"] as? Int, 4)
            } else {
                let movie = try XCTUnwrap(json["movie"] as? [String: Any])
                XCTAssertEqual(movie["title"] as? String, "Example Movie")
                submittedTitlesLock.withLock {
                    submittedTitles.append("Example Movie")
                }
            }
            return Self.response(for: request, status: 201, json: "{}")
        }

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let items = [
            ContinueWatchingItem(
                meta: makeMeta(type: "series"),
                streamUrl: "",
                position: 50,
                duration: 200,
                lastWatchedAt: timestamp.addingTimeInterval(60),
                season: 2,
                episode: 4
            ),
            ContinueWatchingItem(
                meta: makeMeta(type: "movie"),
                streamUrl: "",
                position: 25,
                duration: 100,
                lastWatchedAt: timestamp
            )
        ]
        let progress = SimklIntegerRecorder()

        let result = await SimklProgressTransferService.transfer(
            items,
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        ) { value in
            await progress.append(value)
        }
        let recordedProgress = await progress.values()

        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.transferred, 2)
        let recordedTitles = submittedTitlesLock.withLock { submittedTitles }
        XCTAssertEqual(recordedTitles, ["Example Movie", "Example Show"])
        XCTAssertEqual(recordedProgress.first, 1)
        XCTAssertEqual(recordedProgress.last, 100)

        let simklItem = await TraktProgressService.currentContinueWatchingItem(
            for: makeMeta(type: "movie"),
            source: .simkl
        )
        let traktItem = await TraktProgressService.currentContinueWatchingItem(
            for: makeMeta(type: "movie"),
            source: .trakt
        )
        XCTAssertNotNil(simklItem)
        XCTAssertNil(traktItem)
    }

    func testNuvioSyncDoesNotRouteWatchedHistoryIntoConnectedTrackers() {
        XCTAssertFalse(
            RemoteTrackingState.routesWatchedHistory(
                to: .trakt,
                selectedSource: .nuvioSync
            )
        )
        XCTAssertFalse(
            RemoteTrackingState.routesWatchedHistory(
                to: .simkl,
                selectedSource: .nuvioSync
            )
        )
        XCTAssertTrue(
            RemoteTrackingState.routesWatchedHistory(
                to: .trakt,
                selectedSource: .trakt
            )
        )
        XCTAssertTrue(
            RemoteTrackingState.routesWatchedHistory(
                to: .simkl,
                selectedSource: .simkl
            )
        )
    }

    func testTraktPausedPlaybackIsPrioritizedAheadOfGeneratedNextUp() {
        let olderPause = Date(timeIntervalSince1970: 1_700_000_000)
        let newerNextUp = olderPause.addingTimeInterval(3_600)

        XCTAssertTrue(
            TraktProgressService.ordersBefore(
                isUpNext: false,
                updatedAt: olderPause,
                otherIsUpNext: true,
                otherUpdatedAt: newerNextUp
            )
        )
        XCTAssertFalse(
            TraktProgressService.ordersBefore(
                isUpNext: true,
                updatedAt: newerNextUp,
                otherIsUpNext: false,
                otherUpdatedAt: olderPause
            )
        )
    }

    func testFetchUserStatsCachesMoviesShowsEpisodesAndHours() async throws {
        authorize()
        SimklAuthStore.saveUser(
            username: "nuvio-user",
            accountID: "42",
            accountPlan: "vip",
            avatarURL: nil,
            store: defaults
        )
        SimklURLProtocolStub.handler = { request in
            // Simkl serves this read as POST with no body, same as
            // /users/settings; a GET does not answer.
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/users/42/stats")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer simkl-token")
            return Self.response(
                for: request,
                json: """
                {
                  "total_mins": 600,
                  "movies": {
                    "completed": {"count": 4, "watched_episodes_count": 0}
                  },
                  "tv": {
                    "watching": {"count": 2, "watched_episodes_count": 10},
                    "hold": {"count": 1, "watched_episodes_count": 2},
                    "completed": {"count": 1, "watched_episodes_count": 20}
                  },
                  "anime": {
                    "completed": {"count": 1, "watched_episodes_count": 5}
                  }
                }
                """
            )
        }

        let stats = await makeService().fetchUserStats()

        XCTAssertEqual(stats?.moviesWatched, 4)
        XCTAssertEqual(stats?.showsWatched, 5)
        XCTAssertEqual(stats?.episodesWatched, 37)
        XCTAssertEqual(stats?.totalWatchedHours, 10)
        XCTAssertEqual(SimklAuthStore.cachedStats(in: defaults), stats)
    }

    private func makeService() -> SimklAuthService {
        SimklAuthService(
            client: makeClient(),
            store: defaults,
            profileScope: "profile-1",
            tokenStorage: tokenStorage
        )
    }

    private func makeClient() -> SimklAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SimklURLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        return SimklAPIClient(session: session)
    }

    /// Connecting Simkl must be enough to make scrobbling happen. Every Simkl
    /// write is gated on the watch progress source, so when the default named a
    /// provider the user had not connected, nothing was ever sent.
    func testConnectingSimklSelectsItAsTheWatchProgressSource() {
        XCTAssertNil(defaults.string(forKey: SettingsKey.traktWatchProgressSource))

        TraktSettingsStore.selectWatchProgressSourceOnConnect(.simkl, in: defaults)

        XCTAssertEqual(TraktSettingsStore.watchProgressSource(in: defaults), .simkl)
    }

    func testConnectDoesNotOverrideAnExplicitUserChoice() {
        TraktSettingsStore.markWatchProgressSourceChosenByUser(in: defaults)
        defaults.set(
            TraktWatchProgressSource.nuvioSync.rawValue,
            forKey: SettingsKey.traktWatchProgressSource
        )

        TraktSettingsStore.selectWatchProgressSourceOnConnect(.simkl, in: defaults)

        XCTAssertEqual(TraktSettingsStore.watchProgressSource(in: defaults), .nuvioSync)
    }

    /// The default changed from `.trakt` to `.nuvioSync`; an existing Trakt user
    /// who never opened the picker must not silently lose scrobbling.
    func testMigrationKeepsSimklForAConnectedSimklAccount() {
        authorize()

        TraktSettingsStore.migrateWatchProgressSourceIfNeeded(
            in: defaults,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )

        XCTAssertEqual(TraktSettingsStore.watchProgressSource(in: defaults), .simkl)
    }

    func testMigrationFallsBackToNuvioSyncWithNoTrackerConnected() {
        TraktSettingsStore.migrateWatchProgressSourceIfNeeded(in: defaults)

        XCTAssertEqual(TraktSettingsStore.watchProgressSource(in: defaults), .nuvioSync)
    }

    func testMigrationLeavesAnExistingStoredSourceAlone() {
        defaults.set(
            TraktWatchProgressSource.trakt.rawValue,
            forKey: SettingsKey.traktWatchProgressSource
        )

        TraktSettingsStore.migrateWatchProgressSourceIfNeeded(in: defaults)

        XCTAssertEqual(TraktSettingsStore.watchProgressSource(in: defaults), .trakt)
    }

    /// The Continue Watching list is cached against Simkl's account watermark,
    /// which lags a scrobble we just sent. Leaving the watermark in place served
    /// the pre-session list back to Home, so closing the player mid-episode made
    /// the show disappear.
    func testSuccessfulScrobbleInvalidatesThePlaybackCache() async throws {
        authorize()
        defaults.set(
            TraktWatchProgressSource.simkl.rawValue,
            forKey: SettingsKey.traktWatchProgressSource
        )
        SimklSyncCache.savePlaybacks([], watermark: "stale-watermark", store: defaults)
        XCTAssertEqual(SimklSyncCache.playbackWatermark(in: defaults), "stale-watermark")

        SimklURLProtocolStub.handler = { request in
            Self.response(for: request, status: 201, json: "{}")
        }

        let result = await SimklProgressService.reportPlayback(
            meta: makeMeta(type: "movie"),
            position: 600,
            duration: 3_000,
            season: nil,
            episode: nil,
            action: .pause,
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )

        XCTAssertTrue(result)
        XCTAssertNil(
            SimklSyncCache.playbackWatermark(in: defaults),
            "the next read must re-fetch sync/playback instead of trusting the cache"
        )
    }

    /// A rejected scrobble leaves the account unchanged, so the cache is still
    /// valid — dropping it there would just cost a needless round trip.
    func testFailedScrobbleLeavesThePlaybackCacheAlone() async throws {
        authorize()
        defaults.set(
            TraktWatchProgressSource.simkl.rawValue,
            forKey: SettingsKey.traktWatchProgressSource
        )
        SimklSyncCache.savePlaybacks([], watermark: "stale-watermark", store: defaults)

        SimklURLProtocolStub.handler = { request in
            Self.response(for: request, status: 500, json: #"{"error":"boom"}"#)
        }

        let result = await SimklProgressService.reportPlayback(
            meta: makeMeta(type: "movie"),
            position: 600,
            duration: 3_000,
            season: nil,
            episode: nil,
            action: .pause,
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )

        XCTAssertFalse(result)
        XCTAssertEqual(SimklSyncCache.playbackWatermark(in: defaults), "stale-watermark")
    }

    /// Simkl answers 201 on `/sync/history` even when it resolved nothing,
    /// listing the rejects under `not_found`. Trusting the status code made the
    /// transfer report "Transferred all N" while the account stayed empty.
    func testTransferDoesNotCountItemsSimklPutInNotFound() async throws {
        authorize()
        WatchedStore.setActiveProfile("transfer-tests")
        defer { WatchedStore.eraseProfile("transfer-tests") }
        WatchedStore.markWatched(makeMeta(type: "movie"))

        SimklURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/sync/history")
            return Self.response(
                for: request,
                status: 201,
                json: #"{"added":{"movies":0},"not_found":{"movies":[{"ids":{"imdb":"tt1234567"}}]}}"#
            )
        }

        let result = await SimklHistoryTransferService.transfer(
            WatchedStore.items(),
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1",
            progress: { _ in }
        )

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.transferred, 0, "a not_found item has not been transferred")
        XCTAssertFalse(result.isComplete)
    }

    func testTransferCountsItemsSimklAccepted() async throws {
        authorize()
        WatchedStore.setActiveProfile("transfer-tests")
        defer { WatchedStore.eraseProfile("transfer-tests") }
        WatchedStore.markWatched(makeMeta(type: "movie"))

        SimklURLProtocolStub.handler = { request in
            Self.response(
                for: request,
                status: 201,
                json: #"{"added":{"movies":1},"not_found":{"movies":[],"shows":[]}}"#
            )
        }

        let result = await SimklHistoryTransferService.transfer(
            WatchedStore.items(),
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1",
            progress: { _ in }
        )

        XCTAssertEqual(result.transferred, 1)
        XCTAssertTrue(result.isComplete)
    }

    /// Simkl matches on anime id spaces too, so a `kitsu:`-only title must be
    /// syncable rather than silently skipped — and it has to travel under the
    /// scrobble body's `anime` key, the only container whose schema carries
    /// `kitsu` / `mal` / `anidb` / `anilist`. Under `show` those ids ride along
    /// as properties the matcher never reads, so nothing resolves.
    func testAnimeOnlyIdentifiersAreSentToSimkl() async throws {
        authorize()
        defaults.set(
            TraktWatchProgressSource.simkl.rawValue,
            forKey: SettingsKey.traktWatchProgressSource
        )
        var seenIDs: [String: Any]?
        SimklURLProtocolStub.handler = { request in
            let json = try Self.jsonBody(request)
            XCTAssertNil(json["show"], "anime-only ids must not be sent under `show`")
            let anime = try XCTUnwrap(json["anime"] as? [String: Any])
            XCTAssertNotNil(json["episode"], "`anime` is only valid paired with an episode")
            seenIDs = anime["ids"] as? [String: Any]
            return Self.response(for: request, status: 201, json: "{}")
        }

        let kitsuMeta = NuvioMeta(
            id: "kitsu:1376",
            name: "Example Anime",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: "series",
            year: 2026,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )

        let result = await SimklProgressService.reportPlayback(
            meta: kitsuMeta,
            position: 600,
            duration: 1_400,
            season: 1,
            episode: 3,
            action: .pause,
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )

        XCTAssertTrue(result, "a kitsu id is a valid Simkl identifier")
        XCTAssertEqual(seenIDs?["kitsu"] as? Int, 1376)
    }

    /// Simkl accepts at most two decimals on `progress`.
    func testScrobbleRoundsProgressToTwoDecimals() async throws {
        authorize()
        defaults.set(
            TraktWatchProgressSource.simkl.rawValue,
            forKey: SettingsKey.traktWatchProgressSource
        )
        SimklURLProtocolStub.handler = { request in
            let json = try Self.jsonBody(request)
            let progress = try XCTUnwrap(json["progress"] as? Double)
            XCTAssertEqual(progress, 33.33, accuracy: 0.0001)
            return Self.response(for: request, status: 201, json: "{}")
        }

        let result = await SimklProgressService.reportPlayback(
            meta: makeMeta(type: "movie"),
            position: 1_000,
            duration: 3_000,
            season: nil,
            episode: nil,
            action: .start,
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )

        XCTAssertTrue(result)
    }

    /// A show sent to `/sync/history/remove` with no `seasons` means "delete
    /// this title from the library entirely" — every episode plus the watchlist
    /// row. Un-ticking the whole-title mark locally does not mean that, so the
    /// removal has to name the seasons Simkl actually holds episodes in.
    func testWholeSeriesUnwatchScopesToSeasonsInsteadOfWipingTheLibraryEntry() async throws {
        authorize()
        SimklSyncCache.saveHistory(
            [
                SimklHistoryRecord(
                    key: "series:imdb:tt1234567",
                    items: [
                        WatchedStoreItem(
                            meta: makeMeta(type: "series"),
                            watchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            season: 1,
                            episode: 1
                        ),
                        WatchedStoreItem(
                            meta: makeMeta(type: "series"),
                            watchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            season: 2,
                            episode: 5
                        )
                    ]
                )
            ],
            watermark: nil,
            activities: nil,
            store: defaults
        )

        SimklURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/sync/history/remove")
            let json = try Self.jsonBody(request)
            let show = try XCTUnwrap((json["shows"] as? [[String: Any]])?.first)
            let seasons = try XCTUnwrap(show["seasons"] as? [[String: Any]])
            XCTAssertEqual(seasons.compactMap { $0["number"] as? Int }.sorted(), [1, 2])
            // Omitted, not empty: a season without `episodes` means "all of
            // them", while `[]` is not the same instruction.
            XCTAssertNil(seasons.first?["episodes"])
            return Self.response(for: request, status: 201, json: "{}")
        }

        let result = await SimklHistoryService.setWatched(
            makeMeta(type: "series"),
            isWatched: false,
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )

        XCTAssertTrue(result)
    }

    /// `/sync/history` reports unmatched episodes in their own `not_found`
    /// array, and a show that resolved fine never appears under
    /// `not_found.shows`. Reading only movies and shows counted those episodes
    /// as transferred and reported a clean run over an account that got nothing.
    func testTransferCountsEpisodesSimklPutInNotFound() async throws {
        authorize()
        WatchedStore.setActiveProfile("not-found-episode-tests")
        defer { WatchedStore.eraseProfile("not-found-episode-tests") }
        WatchedStore.markWatched(makeMeta(type: "series"), season: 1, episode: 1)

        SimklURLProtocolStub.handler = { request in
            Self.response(
                for: request,
                status: 201,
                json: """
                {
                  "added": {"movies": 0, "shows": 0, "episodes": 0},
                  "not_found": {
                    "movies": [],
                    "shows": [],
                    "episodes": [{"ids": {"imdb": "tt1234567"}, "season": 1, "number": 1}]
                  }
                }
                """
            )
        }

        let result = await SimklHistoryTransferService.transfer(
            WatchedStore.items(),
            store: defaults,
            client: makeClient(),
            tokenStorage: tokenStorage,
            profileScope: "profile-1",
            progress: { _ in }
        )

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.transferred, 0)
        XCTAssertFalse(result.isComplete)
    }

    /// `/sync/all-items` nests the title under `movie` / `show` while keeping
    /// watch state at the top level. Decoding `title` / `year` / `ids` flat
    /// returns nil for every row, which collapses everything to the identity
    /// `title::0` with no resolvable content id — the whole read path goes
    /// silently empty, so nothing marked watched on simkl.com ever arrives.
    func testAllItemsRowsDecodeTheNestedWireShape() throws {
        let json = """
        {
          "movies": [
            {
              "added_to_watchlist_at": "2026-05-14T06:49:56Z",
              "last_watched_at": "2026-07-25T18:00:00Z",
              "status": "completed",
              "movie": {
                "title": "Pulp Fiction",
                "year": 1994,
                "ids": {"simkl": 54130, "imdb": "tt0110912"}
              }
            }
          ],
          "shows": [
            {
              "added_to_watchlist_at": "2018-02-24T23:55:13Z",
              "last_watched_at": "2026-05-15T00:32:21Z",
              "status": "watching",
              "show": {
                "title": "The Walking Dead",
                "year": 2010,
                "ids": {"simkl": 2090, "imdb": "tt1520211"}
              },
              "seasons": [
                {"number": 1, "episodes": [{"number": 2, "watched_at": "2026-05-15T00:32:20Z"}]}
              ]
            }
          ]
        }
        """
        let response = try JSONDecoder().decode(
            SimklAllItemsResponse.self,
            from: Data(json.utf8)
        )

        let movie = try XCTUnwrap(response.movies?.first)
        XCTAssertEqual(movie.title, "Pulp Fiction")
        XCTAssertEqual(movie.year, 1994)
        XCTAssertEqual(movie.ids?.imdb, "tt0110912")
        XCTAssertEqual(movie.status, "completed")
        XCTAssertEqual(movie.lastWatchedAt, "2026-07-25T18:00:00Z")
        XCTAssertEqual(SimklAllItemsResponse.identity(movie), "simkl:54130")

        let show = try XCTUnwrap(response.shows?.first)
        XCTAssertEqual(show.title, "The Walking Dead")
        XCTAssertEqual(show.ids?.imdb, "tt1520211")
        // `seasons` is a sibling of `show`, not nested inside it.
        XCTAssertEqual(show.seasons?.first?.episodes?.first?.resolvedNumber, 2)
        XCTAssertNotEqual(SimklAllItemsResponse.identity(show), "title::0")
    }

    /// The same type is re-read from its own cache, which it writes flat.
    func testAllItemsRowSurvivesACacheRoundTrip() throws {
        let item = SimklSyncItem(
            title: "Pulp Fiction",
            year: 1994,
            ids: SimklSyncIDs(simkl: 54130, imdb: "tt0110912"),
            status: "completed",
            addedToWatchlistAt: nil,
            lastWatchedAt: "2026-07-25T18:00:00Z",
            seasons: nil
        )

        let restored = try JSONDecoder().decode(
            SimklSyncItem.self,
            from: try JSONEncoder().encode(item)
        )

        XCTAssertEqual(restored.title, "Pulp Fiction")
        XCTAssertEqual(restored.ids?.simkl, 54130)
        XCTAssertEqual(restored.lastWatchedAt, "2026-07-25T18:00:00Z")
        XCTAssertEqual(SimklAllItemsResponse.identity(restored), "simkl:54130")
    }

    private func authorize() {
        SimklAuthStore.saveToken(
            "simkl-token",
            clientID: "client-id",
            profileScope: "profile-1",
            store: defaults,
            tokenStorage: tokenStorage
        )
    }

    private func makeMeta(type: String) -> NuvioMeta {
        NuvioMeta(
            id: "tt1234567",
            name: type == "series" ? "Example Show" : "Example Movie",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt1234567",
            tmdbId: 123,
            type: type,
            year: 2026,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }

    private static func jsonBody(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count >= 0 else {
                    throw stream.streamError ?? URLError(.cannotDecodeContentData)
                }
                if count == 0 { break }
                result.append(buffer, count: count)
            }
            data = result
        }
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private static func pinResponse(for request: URLRequest) -> (HTTPURLResponse, Data) {
        response(
            for: request,
            json: """
            {
              "result": "OK",
              "device_code": "DEVICE_CODE",
              "user_code": "ABC123",
              "verification_uri": "https://simkl.com/pin",
              "expires_in": 900,
              "interval": 5
            }
            """
        )
    }

    private static func response(
        for request: URLRequest,
        status: Int = 200,
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private actor SimklIntegerRecorder {
    private var recordedValues: [Int] = []

    func append(_ value: Int) {
        recordedValues.append(value)
    }

    func values() -> [Int] {
        recordedValues
    }
}

private final class SimklURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
