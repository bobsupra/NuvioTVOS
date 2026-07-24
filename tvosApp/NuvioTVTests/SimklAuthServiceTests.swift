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

    func testHistoryWriteUsesEpisodePayloadAndSkipAutoWatching() async throws {
        authorize()
        SimklURLProtocolStub.handler = { request in
            let components = try XCTUnwrap(
                URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            )
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(components.path, "/sync/history")
            XCTAssertEqual(
                components.queryItems?.first { $0.name == "skip_auto_watching" }?.value,
                "yes"
            )
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
            XCTAssertEqual(
                components.queryItems?.first { $0.name == "skip_auto_watching" }?.value,
                "yes"
            )

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
            XCTAssertEqual(request.httpMethod, "GET")
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
