import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class MdbListScrobbleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var tokenStorage: MdbListMemoryTokenStorage!
    private var client: MdbListAPIClient!

    override func setUp() {
        super.setUp()
        suiteName = "MdbListScrobbleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(TraktWatchProgressSource.mdblist.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        defaults.set("test-api-key", forKey: SettingsKey.mdbListApiKey)
        tokenStorage = MdbListMemoryTokenStorage()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MdbListURLProtocolStub.self]
        client = MdbListAPIClient(session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        MdbListURLProtocolStub.handler = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        tokenStorage = nil
        client = nil
        super.tearDown()
    }

    func testDeviceAuthorizationStoresRenewableAccountCredentials() async throws {
        MdbListURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/oauth/device-authorization", MdbListConfig.deviceAuthorizationPath:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
                let form = Self.formBody(request)
                XCTAssertEqual(form["client_id"], MdbListConfig.clientID)
                XCTAssertEqual(form["scope"], "write")
                return Self.response(
                    for: request,
                    json: """
                    {
                      "device_code": "device-secret",
                      "user_code": "ABCD-EFGH",
                      "verification_uri": "https://mdblist.com/oauth/device/",
                      "verification_uri_complete": "https://mdblist.com/oauth/device/?user_code=ABCD-EFGH",
                      "expires_in": 600,
                      "interval": 1
                    }
                    """
                )
            case "/oauth/token", MdbListConfig.tokenPath:
                XCTAssertEqual(Self.formBody(request)["device_code"], "device-secret")
                return Self.response(
                    for: request,
                    json: #"{"access_token":"access-one","refresh_token":"refresh-one","token_type":"Bearer","expires_in":3600,"scope":"write"}"#
                )
            case "/user":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-one")
                return Self.response(for: request, json: #"{"user_id":42,"username":"suprabob9","name":"Supra Bob"}"#)
            default:
                XCTFail("Unexpected MDBList request: \(request.url?.absoluteString ?? "nil")")
                return Self.response(for: request, status: 404, json: #"{"error":"not_found"}"#)
            }
        }

        let service = MdbListAuthService(
            client: client,
            store: defaults,
            profileScope: "profile-1",
            tokenStorage: tokenStorage
        )
        let device = try await service.startDeviceAuthorization()
        let result = await service.pollDeviceAuthorization()

        XCTAssertEqual(device.userCode, "ABCD-EFGH")
        XCTAssertEqual(result, .approved)
        let state = service.currentState()
        XCTAssertTrue(state.hasOAuthTokens)
        XCTAssertEqual(state.username, "suprabob9")
        XCTAssertEqual(state.displayName, "Supra Bob")
        XCTAssertEqual(state.accountID, "42")
        XCTAssertEqual(tokenStorage.tokens(for: "profile-1")?.accessToken, "access-one")
        XCTAssertEqual(
            defaults.string(forKey: SettingsKey.traktWatchProgressSource),
            TraktWatchProgressSource.mdblist.rawValue
        )
    }

    func testScrobbleUsesDocumentedMovieAndEpisodeBodiesWithApiKeyFallback() async throws {
        var requests: [URLRequest] = []
        MdbListURLProtocolStub.handler = { request in
            requests.append(request)
            return Self.response(for: request, json: #"{"action":"pause","progress":42.5}"#)
        }

        let movieResult = await MdbListProgressService.reportPlayback(
            meta: Self.meta(id: "tt1234567", type: "movie"),
            position: 42.5,
            duration: 100,
            season: nil,
            episode: nil,
            action: .pause,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        let episodeResult = await MdbListProgressService.reportPlayback(
            meta: Self.meta(id: "tt7654321:2:4", type: "series"),
            position: 80,
            duration: 200,
            season: 2,
            episode: 4,
            action: .stop,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        let heartbeatResult = await MdbListProgressService.reportPlayback(
            meta: Self.meta(id: "tt1234567", type: "movie"),
            position: 43,
            duration: 100,
            season: nil,
            episode: nil,
            action: .start,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )

        XCTAssertTrue(movieResult)
        XCTAssertTrue(episodeResult)
        XCTAssertTrue(heartbeatResult)
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.path, "/scrobble/pause")
        XCTAssertEqual(requests[1].url?.path, "/scrobble/stop")
        XCTAssertEqual(requests[2].url?.path, "/scrobble/start")

        let movie = try XCTUnwrap(Self.jsonBody(requests[0])["movie"] as? [String: Any])
        XCTAssertEqual(movie["ids"] as? [String: Any] as? [String: String], ["imdb": "tt1234567"])
        XCTAssertNil(Self.jsonBody(requests[0])["show"])
        XCTAssertEqual(Self.jsonBody(requests[0])["progress"] as? Double, 42.5)

        let show = try XCTUnwrap(Self.jsonBody(requests[1])["show"] as? [String: Any])
        XCTAssertEqual(show["season"] as? Int, 2)
        XCTAssertEqual(show["episode"] as? Int, 4)
        XCTAssertEqual(show["ids"] as? [String: Any] as? [String: String], ["imdb": "tt7654321"])
        XCTAssertEqual(Self.jsonBody(requests[1])["progress"] as? Double, 40.0)

        for request in requests {
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems?.first(where: { $0.name == "apikey" })?.value, "test-api-key")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testPlaybackSnapshotMapsMovieAndEpisodeAndUsesRuntime() async throws {
        MdbListURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/sync/playback")
            return Self.response(
                for: request,
                json: """
                [
                  {
                    "id": 1,
                    "type": "movie",
                    "progress": 25,
                    "paused_at": "2026-09-06T01:00:00Z",
                    "runtime": 100,
                    "movie": {"title":"Movie","year":2020,"ids":{"imdb":"tt1234567"}}
                  },
                  {
                    "id": 2,
                    "type": "episode",
                    "progress": 50,
                    "updated_at": "2026-09-06T02:00:00Z",
                    "runtime": 45,
                    "show": {"title":"Show","year":2021,"ids":{"tmdb":1399}},
                    "episode": {"season":2,"number":4,"title":"Episode title"}
                  }
                ]
                """
            )
        }

        let fetched = await MdbListProgressService.fetchContinueWatching(
                repository: MdbListCatalogRepository(),
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        let items = try XCTUnwrap(fetched)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.episodeNumbers?.season, 2)
        XCTAssertEqual(items.first?.episodeNumbers?.episode, 4)
        XCTAssertEqual(items.first?.episodeDisplayTitle, "Episode title")
        XCTAssertEqual(items.first?.duration ?? 0, 45 * 60, accuracy: 0.001)
        XCTAssertEqual(items.last?.duration ?? 0, 100 * 60, accuracy: 0.001)
    }

    func testHistoryWriteUsesMdbListShowEpisodeShape() async throws {
        var captured: URLRequest?
        MdbListURLProtocolStub.handler = { request in
            captured = request
            return Self.response(for: request, json: #"{"updated":{"episodes":1}}"#)
        }

        let result = await MdbListProgressService.setWatched(
            Self.meta(id: "tmdb:1399", type: "series"),
            season: 2,
            episode: 4,
            isWatched: true,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )

        XCTAssertTrue(result)
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.path, "/sync/watched")
        let shows = try XCTUnwrap(Self.jsonBody(request)["shows"] as? [[String: Any]])
        let show = try XCTUnwrap(shows.first)
        XCTAssertEqual(show["ids"] as? [String: Any] as? [String: Int], ["tmdb": 1399])
        let seasons = try XCTUnwrap(show["seasons"] as? [[String: Any]])
        XCTAssertEqual(seasons.first?["number"] as? Int, 2)
        let episodes = try XCTUnwrap(seasons.first?["episodes"] as? [[String: Any]])
        XCTAssertEqual(episodes.first?["number"] as? Int, 4)
        XCTAssertNotNil(episodes.first?["watched_at"] as? String)
    }

    func testLibraryCombinesWatchlistAndCollectionAndMutatesWatchlist() async throws {
        var requests: [URLRequest] = []
        MdbListURLProtocolStub.handler = { request in
            requests.append(request)
            switch request.url?.path {
            case "/watchlist/items":
                return Self.response(
                    for: request,
                    json: #"{"movies":[{"title":"Movie","ids":{"imdb":"tt1234567"},"listed_at":"2026-09-08T01:00:00Z"}]}"#
                )
            case "/sync/collection":
                return Self.response(
                    for: request,
                    json: #"{"shows":[{"title":"Show","ids":{"tmdb":1399},"collected_at":"2026-09-07T01:00:00Z"}]}"#
                )
            case "/watchlist/items/add":
                return Self.response(for: request, json: #"{"added":1}"#)
            default:
                XCTFail("Unexpected MDBList request: \(request.url?.absoluteString ?? "nil")")
                return Self.response(for: request, status: 404, json: #"{"error":"not_found"}"#)
            }
        }

        let fetchedItems = await MdbListLibraryService.fetchLibrary(
            repository: MdbListCatalogRepository(),
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        let items = try XCTUnwrap(fetchedItems)
        XCTAssertEqual(items.map(\.meta.name), ["Movie", "Show"])

        let membership = await MdbListLibraryService.isInWatchlist(
            Self.meta(id: "tt1234567", type: "movie"),
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        XCTAssertEqual(membership, true)

        let mutation = await MdbListLibraryService.setWatchlist(
            Self.meta(id: "tt1234567", type: "movie"),
            isInWatchlist: true,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        XCTAssertTrue(mutation)
        XCTAssertEqual(requests.last?.url?.path, "/watchlist/items/add")
        let body = try XCTUnwrap(requests.last.map(Self.jsonBody))
        let movies = try XCTUnwrap(body["movies"] as? [[String: Any]])
        let movie = try XCTUnwrap(movies.first)
        XCTAssertEqual(movie["ids"] as? [String: Any] as? [String: String], ["imdb": "tt1234567"])
    }

    func testPersonalListDiscoveryLoadsItems() async throws {
        MdbListURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/lists/user":
                return Self.response(
                    for: request,
                    json: #"{"lists":[{"id":7,"name":"Favorites","slug":"favorites","items":1}]}"#
                )
            case "/lists/7/items":
                return Self.response(
                    for: request,
                    json: #"{"movies":[{"ids":{"imdb":"tt1234567"},"added_at":"2026-09-08T01:00:00Z"}]}"#
                )
            default:
                return Self.response(for: request, status: 404, json: #"{"error":"not_found"}"#)
            }
        }

        let fetchedLists = await MdbListListService.fetchUserLists(
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        let lists = try XCTUnwrap(fetchedLists)
        XCTAssertEqual(lists, [MdbListUserList(id: 7, name: "Favorites", slug: "favorites", itemCount: 1)])

        let fetchedItems = await MdbListListService.fetchItems(
            listID: 7,
            repository: MdbListCatalogRepository(),
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        let items = try XCTUnwrap(fetchedItems)
        XCTAssertEqual(items.first?.meta.id, "tt1234567")
    }

    func testPersonalRatingsReadWriteAndRemove() async throws {
        var requests: [URLRequest] = []
        MdbListURLProtocolStub.handler = { request in
            requests.append(request)
            switch request.url?.path {
            case "/sync/ratings":
                if request.httpMethod == "GET" {
                    return Self.response(
                        for: request,
                        json: #"{"movies":[{"ids":{"imdb":"tt1234567"},"rating":8,"rated_at":"2026-09-08T01:00:00Z"}]}"#
                    )
                }
                return Self.response(for: request, json: #"{"updated":{"movies":1}}"#)
            case "/sync/ratings/remove":
                return Self.response(for: request, json: "{}")
            default:
                return Self.response(for: request, status: 404, json: #"{"error":"not_found"}"#)
            }
        }

        let meta = Self.meta(id: "tt1234567", type: "movie")
        let fetchedRating = await MdbListRatingsService.fetchRating(
            for: meta,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        XCTAssertEqual(fetchedRating, 8)
        let setResult = await MdbListRatingsService.setRating(
            meta,
            rating: 9,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        XCTAssertTrue(setResult)
        let removeResult = await MdbListRatingsService.setRating(
            meta,
            rating: nil,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        XCTAssertTrue(removeResult)
        XCTAssertEqual(requests.map { $0.url?.path }, ["/sync/ratings", "/sync/ratings", "/sync/ratings/remove"])
        let movies = try XCTUnwrap(Self.jsonBody(requests[1])["movies"] as? [[String: Any]])
        let movie = try XCTUnwrap(movies.first)
        XCTAssertEqual(movie["ids"] as? [String: Any] as? [String: String], ["imdb": "tt1234567"])
        XCTAssertEqual(movie["rating"] as? Int, 9)
    }

    func testUserWatchStatsUsesDedicatedStatsEndpoint() async throws {
        MdbListURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/user/stats")
            return Self.response(
                for: request,
                json: #"{"movies_watched":7,"shows_watched":105,"episodes_watched":683,"watch_time_minutes":30360}"#
            )
        }

        let service = MdbListAuthService(
            client: client,
            store: defaults,
            profileScope: "profile-1",
            tokenStorage: tokenStorage
        )
        let stats = await service.fetchUserStats()

        XCTAssertEqual(
            stats,
            MdbListWatchStats(
                moviesWatched: 7,
                showsWatched: 105,
                episodesWatched: 683,
                totalWatchedHours: 506
            )
        )
    }

    private static func meta(id: String, type: String) -> NuvioMeta {
        mdbListTestMetadata(id: id, type: type, runtime: nil)
    }

    private static func formBody(_ request: URLRequest) -> [String: String] {
        guard let data = requestBody(request),
              let value = String(data: data, encoding: .utf8),
              let components = URLComponents(string: "?\(value)") else { return [:] }
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    private static func jsonBody(_ request: URLRequest) -> [String: Any] {
        guard let data = requestBody(request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: 4096)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    private static func response(
        for request: URLRequest,
        status: Int = 200,
        json: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.mdblist.com")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(json.utf8))
    }
}

private func mdbListTestMetadata(id: String, type: String, runtime: String?) -> NuvioMeta {
    NuvioMeta(
        id: id,
        name: type == "movie" ? "Movie" : "Show",
        description: nil,
        posterUrl: nil,
        backgroundUrl: nil,
        logoUrl: nil,
        imdbId: nil,
        tmdbId: nil,
        type: type,
        year: 2020,
        genres: nil,
        rating: nil,
        releaseInfo: nil,
        runtime: runtime,
        cast: nil,
        director: nil,
        writer: nil,
        certification: nil,
        country: nil,
        released: nil
    )
}

private final class MdbListCatalogRepository: MockCatalogRepository {
    override func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        mdbListTestMetadata(
            id: id,
            type: type,
            runtime: id == "tmdb:1399" ? "45 min" : "100 min"
        )
    }
}

private final class MdbListURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
