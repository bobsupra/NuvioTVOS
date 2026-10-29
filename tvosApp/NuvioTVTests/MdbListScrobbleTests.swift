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
        ProfileSettings.clearActiveProfile()
        WatchedStore.setActiveProfile(nil)
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
        ProfileSettings.clearActiveProfile()
        WatchedStore.setActiveProfile(nil)
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

    func testLibrarySortIsStableAcrossShuffledResponsesAndKeepsNewestDuplicate() async throws {
        let watchlistRows: [[String: Any]] = [
            ["title": "Tie C", "ids": ["imdb": "tt1000009"], "listed_at": "2026-09-08T01:00:00Z"],
            ["title": "Missing D", "ids": ["imdb": "tt1000004"]],
            ["title": "Fractional Earlier", "ids": ["imdb": "tt1000006"], "added_at": "2026-09-10T03:00:00.125Z"],
            ["title": "Missing C", "ids": ["imdb": "tt1000003"]],
            ["title": "Numeric Newest", "ids": ["imdb": "tt1000010"], "added_at": 1_800_000_000_000],
            ["title": "Tie B", "ids": ["imdb": "tt1000001"], "listed_at": "2026-09-08T01:00:00Z"],
            ["title": "Fractional Later", "ids": ["imdb": "tt1000005"], "added_at": "2026-09-10T03:00:00.250Z"],
            ["title": "Whole Second", "ids": ["imdb": "tt1000007"], "added_at": "2026-09-10T03:00:00Z"],
            ["title": "Older Duplicate", "ids": ["imdb": "tt1000002"], "listed_at": "2026-09-06T01:00:00Z"]
        ]
        let collectionRows: [[String: Any]] = [
            ["title": "Newer Duplicate", "ids": ["imdb": "tt1000002"], "collected_at": "2026-09-11T01:00:00Z"],
            ["title": "Tie A", "ids": ["imdb": "tt1000000"], "collected_at": "2026-09-08T01:00:00Z"]
        ]
        let watchlistResponses = try [
            watchlistRows,
            Array(watchlistRows.reversed())
        ].map { try Self.jsonString(["movies": $0]) }
        let collectionResponses = try [
            collectionRows,
            Array(collectionRows.reversed())
        ].map { try Self.jsonString(["movies": $0]) }
        var watchlistRequestCount = 0
        var collectionRequestCount = 0
        MdbListURLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/watchlist/items":
                let index = min(watchlistRequestCount, watchlistResponses.count - 1)
                watchlistRequestCount += 1
                return Self.response(for: request, json: watchlistResponses[index])
            case "/sync/collection":
                let index = min(collectionRequestCount, collectionResponses.count - 1)
                collectionRequestCount += 1
                return Self.response(for: request, json: collectionResponses[index])
            default:
                XCTFail("Unexpected MDBList request: \(request.url?.absoluteString ?? "nil")")
                return Self.response(for: request, status: 404, json: #"{"error":"not_found"}"#)
            }
        }

        let repository = MdbListCatalogRepository()
        let firstFetchedItems = await MdbListLibraryService.fetchLibrary(
            repository: repository,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        let firstItems = try XCTUnwrap(firstFetchedItems)
        let secondFetchedItems = await MdbListLibraryService.fetchLibrary(
            repository: repository,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        let secondItems = try XCTUnwrap(secondFetchedItems)
        let expectedIDs = [
            "tt1000010", "tt1000005", "tt1000006", "tt1000007", "tt1000000",
            "tt1000001", "tt1000009", "tt1000002", "tt1000003", "tt1000004"
        ]
        XCTAssertEqual(firstItems.map(\.meta.id), expectedIDs)
        XCTAssertEqual(secondItems.map(\.meta.id), expectedIDs)
        XCTAssertEqual(firstItems.map(\.addedAt), secondItems.map(\.addedAt))
        XCTAssertEqual(watchlistRequestCount, 2)
        XCTAssertEqual(collectionRequestCount, 2)

        let itemsByID = Dictionary(uniqueKeysWithValues: firstItems.map { ($0.meta.id, $0) })
        XCTAssertEqual(itemsByID["tt1000010"]?.addedAt, Date(timeIntervalSince1970: 1_800_000_000))
        let duplicateDate = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-06T01:00:00Z"))
        XCTAssertEqual(itemsByID["tt1000002"]?.addedAt, duplicateDate)
        let laterFractionalItem = try XCTUnwrap(itemsByID["tt1000005"])
        let earlierFractionalItem = try XCTUnwrap(itemsByID["tt1000006"])
        XCTAssertEqual(
            laterFractionalItem.addedAt.timeIntervalSince(earlierFractionalItem.addedAt),
            0.125,
            accuracy: 0.0001
        )
    }

    func testLibraryUsesMdbListWatchlistTimestampsAndDocumentedSort() async throws {
        let movieRows: [[String: Any]] = [
            ["title": "Fractional Earlier", "imdb_id": "tt1000002", "mediatype": "movie", "watchlist_at": "2025-02-21 12:59:56.824123"],
            ["title": "Older Duplicate", "imdb_id": "tt1000003", "mediatype": "movie", "watchlist_at": "2025-02-20 10:00:00.000000"],
            ["title": "Fractional Later", "imdb_id": "tt1000001", "mediatype": "movie", "watchlist_at": "2025-02-21 12:59:56.824522"],
            ["title": "Newer Watchlist Duplicate", "imdb_id": "tt1000003", "mediatype": "movie", "watchlist_at": "2025-02-21 12:59:56.900000"],
            ["title": "Undated Watchlist Duplicate", "imdb_id": "tt1000006", "mediatype": "movie"]
        ]
        let showRows: [[String: Any]] = [
            ["title": "Show Camel Timestamp", "imdb_id": "tt1000004", "mediatype": "show", "watchlistAt": "2025-02-21 12:59:57"],
            ["title": "Show Fractional Timestamp", "imdb_id": "tt1000005", "mediatype": "show", "watchlist_at": "2025-02-20 09:00:00.1"]
        ]
        let collectionRows: [[String: Any]] = [
            ["title": "Newer Duplicate", "imdb_id": "tt1000003", "mediatype": "movie", "collected_at": "2025-02-22T01:00:00Z"],
            ["title": "Dated Collection Fallback", "imdb_id": "tt1000006", "mediatype": "movie", "collected_at": "2025-02-23T01:00:00Z"]
        ]
        let watchlistResponses = try [
            ["movies": movieRows, "shows": showRows],
            ["movies": Array(movieRows.reversed()), "shows": Array(showRows.reversed())]
        ].map { try Self.jsonString($0) }
        let collectionResponses = try [
            ["movies": collectionRows],
            ["movies": Array(collectionRows.reversed())]
        ].map { try Self.jsonString($0) }
        var watchlistRequestCount = 0
        var collectionRequestCount = 0
        MdbListURLProtocolStub.handler = { request in
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            switch request.url?.path {
            case "/watchlist/items":
                XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "sort" })?.value, "added")
                XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "order" })?.value, "asc")
                let index = min(watchlistRequestCount, watchlistResponses.count - 1)
                watchlistRequestCount += 1
                return Self.response(for: request, json: watchlistResponses[index])
            case "/sync/collection":
                XCTAssertNil(components?.queryItems?.first(where: { $0.name == "sort" }))
                XCTAssertNil(components?.queryItems?.first(where: { $0.name == "order" }))
                let index = min(collectionRequestCount, collectionResponses.count - 1)
                collectionRequestCount += 1
                return Self.response(for: request, json: collectionResponses[index])
            default:
                XCTFail("Unexpected MDBList request: \(request.url?.absoluteString ?? "nil")")
                return Self.response(for: request, status: 404, json: #"{"error":"not_found"}"#)
            }
        }

        let repository = MdbListCatalogRepository()
        let firstFetchedItems = await MdbListLibraryService.fetchLibrary(
            repository: repository,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        let firstItems = try XCTUnwrap(firstFetchedItems)
        let secondFetchedItems = await MdbListLibraryService.fetchLibrary(
            repository: repository,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        let secondItems = try XCTUnwrap(secondFetchedItems)
        let expectedIDs = ["tt1000006", "tt1000004", "tt1000003", "tt1000001", "tt1000002", "tt1000005"]
        XCTAssertEqual(firstItems.map(\.meta.id), expectedIDs)
        XCTAssertEqual(secondItems.map(\.meta.id), expectedIDs)
        XCTAssertEqual(watchlistRequestCount, 2)
        XCTAssertEqual(collectionRequestCount, 2)

        let itemsByID = Dictionary(uniqueKeysWithValues: firstItems.map { ($0.meta.id, $0) })
        let utcBase = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-02-21T12:59:56Z"))
        XCTAssertEqual(
            try XCTUnwrap(itemsByID["tt1000001"]).addedAt.timeIntervalSince(utcBase),
            0.824522,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            try XCTUnwrap(itemsByID["tt1000002"]).addedAt.timeIntervalSince(utcBase),
            0.824123,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            try XCTUnwrap(itemsByID["tt1000001"]).addedAt.timeIntervalSince(itemsByID["tt1000002"]!.addedAt),
            0.000399,
            accuracy: 0.000001
        )
        let camelCaseBase = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-02-21T12:59:57Z"))
        XCTAssertEqual(itemsByID["tt1000004"]?.addedAt, camelCaseBase)
        let duplicateBase = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-02-21T12:59:56Z"))
        let duplicateItem = try XCTUnwrap(itemsByID["tt1000003"])
        XCTAssertEqual(
            duplicateItem.addedAt.timeIntervalSince(duplicateBase),
            0.9,
            accuracy: 0.000001
        )
        let datedCollection = try XCTUnwrap(ISO8601DateFormatter().date(from: "2025-02-23T01:00:00Z"))
        XCTAssertEqual(itemsByID["tt1000006"]?.addedAt, datedCollection)
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

    func testPreservingEnrichmentRetainsRatingsAndCredits() {
        let ratings = [
            NuvioExternalRating(source: "imdb", value: 8.4),
            NuvioExternalRating(source: "tomatoes", value: 92.0)
        ]
        let enriched = NuvioMeta(
            id: "tt1234567",
            name: "Test Movie",
            description: "Initial description",
            posterUrl: "https://example.com/poster.jpg",
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt1234567",
            tmdbId: 100,
            type: "movie",
            year: 2024,
            genres: ["Action"],
            rating: 8.4,
            releaseInfo: "2024",
            runtime: "120 min",
            cast: ["Actor A", "Actor B"],
            director: ["Director A"],
            writer: ["Writer A"],
            certification: "PG-13",
            country: "US",
            language: "en",
            released: "2024-01-01",
            status: "Released",
            videos: nil,
            trailerYtIds: nil,
            externalRatings: ratings
        )

        let freshRaw = NuvioMeta(
            id: "tt1234567",
            name: "Test Movie Full",
            description: "Full description",
            posterUrl: "https://example.com/poster.jpg",
            backgroundUrl: "https://example.com/bg.jpg",
            logoUrl: "https://example.com/logo.png",
            imdbId: "tt1234567",
            tmdbId: 100,
            type: "movie",
            year: 2024,
            genres: ["Action", "Adventure"],
            rating: 8.4,
            releaseInfo: "2024",
            runtime: "120 min",
            cast: nil,
            director: nil,
            writer: nil,
            certification: "PG-13",
            country: "US",
            language: "en",
            released: "2024-01-01",
            status: "Released",
            videos: nil,
            trailerYtIds: nil,
            externalRatings: nil
        )

        let resolved = freshRaw.preservingEnrichment(from: enriched)
        XCTAssertEqual(resolved.id, "tt1234567")
        XCTAssertEqual(resolved.name, "Test Movie Full")
        XCTAssertEqual(resolved.description, "Full description")
        XCTAssertEqual(resolved.externalRatings, ratings, "MDBList external ratings must be preserved")
        XCTAssertEqual(resolved.cast, ["Actor A", "Actor B"], "Cast credits must be preserved when raw has nil")
        XCTAssertEqual(resolved.director, ["Director A"], "Director credits must be preserved when raw has nil")
        XCTAssertEqual(resolved.writer, ["Writer A"], "Writer credits must be preserved when raw has nil")
    }

    func testPreservingEnrichmentIgnoresDifferentID() {
        let ratings = [NuvioExternalRating(source: "imdb", value: 8.4)]
        let itemA = NuvioMeta(
            id: "tt0000001",
            name: "Movie A",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt0000001",
            tmdbId: 1,
            type: "movie",
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: ["Actor A"],
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            language: nil,
            released: nil,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: ratings
        )

        let itemB = NuvioMeta(
            id: "tt0000002",
            name: "Movie B",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt0000002",
            tmdbId: 2,
            type: "movie",
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            language: nil,
            released: nil,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: nil
        )

        let resolved = itemB.preservingEnrichment(from: itemA)
        XCTAssertNil(resolved.externalRatings)
        XCTAssertNil(resolved.cast)
    }

    func testDetailsViewModelPreservesMdbListRatingsDuringMetadataLoad() async {
        let repository = MdbListControlledDetailsRepo()
        let ratings = [
            NuvioExternalRating(source: "imdb", value: 7.9),
            NuvioExternalRating(source: "tomatoes", value: 88.0)
        ]

        let viewModel = DetailsViewModel(
            repository: repository,
            streamDiscoveryMode: .repository,
            deferredPreparationDelay: { },
            enrichmentStarter: { meta, gen in }
        )

        // Seed initial cached metadata
        let initialMeta = NuvioMeta(
            id: "tt9999999",
            name: "Initial Cached Title",
            description: "Cached description",
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt9999999",
            tmdbId: 999,
            type: "movie",
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            language: nil,
            released: nil,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: nil
        )
        repository.cacheCatalogMetadata(initialMeta)

        let waiter = expectation(description: "metadata waiter")
        repository.metadataWaiterEntered = { _ in waiter.fulfill() }

        let loadTask = viewModel.loadDetails(id: "tt9999999", type: "movie")
        await fulfillment(of: [waiter], timeout: 2)

        // Simulate MDBList rating enrichment finishing while getMetadata is still in-flight
        if let currentMeta = viewModel.uiState.meta {
            viewModel.applyMdbRatingsForTesting(ratings, for: "tt9999999")
        }
        XCTAssertEqual(viewModel.uiState.meta?.externalRatings, ratings, "Ratings should appear in UI state")

        // Now full metadata finishes loading and returns raw metadata without externalRatings
        repository.release(id: "tt9999999")
        await loadTask.value

        // External ratings must NOT have disappeared
        XCTAssertEqual(viewModel.uiState.meta?.externalRatings, ratings, "MDBList ratings must NOT disappear after getMetadata finishes")
        XCTAssertEqual(viewModel.uiState.meta?.name, "tt9999999-full", "Full metadata name should update")
    }

    func testSyncWatchedHistoryQueriesAllMediaTypesAndPopulatesWatchedStore() async throws {
        var requestedMediaTypes: [String] = []
        MdbListURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/sync/watched")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
            if let mediatype = components?.queryItems?.first(where: { $0.name == "mediatype" })?.value {
                requestedMediaTypes.append(mediatype)
                switch mediatype {
                case "movie":
                    return Self.response(
                        for: request,
                        json: """
                        {
                          "movies": [
                            {"movie": {"title": "Inception", "year": 2010, "ids": {"imdb": "tt1375666"}}, "watched_at": "2026-09-01T12:00:00Z"}
                          ]
                        }
                        """
                    )
                case "show":
                    return Self.response(
                        for: request,
                        json: """
                        {
                          "shows": [
                            {
                              "show": {"title": "Breaking Bad", "year": 2008, "ids": {"imdb": "tt0903747"}},
                              "watched_at": "2026-09-02T12:00:00Z",
                              "seasons": [
                                {
                                  "number": 1,
                                  "episodes": [
                                    {"number": 1, "watched_at": "2026-09-02T12:30:00Z"}
                                  ]
                                }
                              ]
                            }
                          ]
                        }
                        """
                    )
                case "episode":
                    return Self.response(
                        for: request,
                        json: """
                        {
                          "episodes": [
                            {
                              "show": {"title": "Better Call Saul", "year": 2015, "ids": {"imdb": "tt3032476"}},
                              "episode": {"season": 1, "number": 1, "watched_at": "2026-09-03T12:00:00Z"}
                            }
                          ]
                        }
                        """
                    )
                case "season":
                    return Self.response(
                        for: request,
                        json: """
                        {
                          "seasons": []
                        }
                        """
                    )
                default:
                    return Self.response(for: request, json: "{}")
                }
            }
            return Self.response(for: request, json: "{}")
        }

        let synced = await MdbListProgressService.syncWatchedHistory(
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        XCTAssertTrue(synced)
        XCTAssertEqual(requestedMediaTypes, ["movie", "show", "episode", "season"])

        let items = WatchedStore.items().filter { $0.isVisible(under: .mdblist) }
        XCTAssertTrue(items.contains(where: { $0.meta.id == "tt1375666" && $0.meta.isMovie }))
        XCTAssertTrue(items.contains(where: { $0.meta.id == "tt0903747" && $0.season == 1 && $0.episode == 1 }))
        XCTAssertTrue(items.contains(where: { $0.meta.id == "tt3032476" && $0.season == 1 && $0.episode == 1 }))
    }

    func testContinueWatchingGeneratesUpNextFromWatchedSeriesHistory() async throws {
        let showMeta = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt0903747",
            tmdbId: nil,
            type: "series",
            year: 2008,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: "47 min",
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: [
                NuvioVideo(id: "tt0903747:1:1", title: "Pilot", season: 1, episode: 1, thumbnail: nil, overview: nil, released: "2008-01-20", rating: nil),
                NuvioVideo(id: "tt0903747:1:2", title: "Cat's in the Bag...", season: 1, episode: 2, thumbnail: nil, overview: nil, released: "2008-01-27", rating: nil)
            ]
        )
        let watchedItem = WatchedStoreItem(
            meta: showMeta,
            watchedAt: Date(timeIntervalSince1970: 10000),
            season: 1,
            episode: 1,
            sources: [TraktWatchProgressSource.mdblist.rawValue]
        )
        WatchedStore.replaceAll([watchedItem])

        MdbListURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/sync/playback")
            return Self.response(for: request, json: "[]")
        }

        let repo = MdbListCatalogRepository()
        repo.customMeta["tt0903747"] = showMeta

        let cw = await MdbListProgressService.fetchContinueWatching(
            repository: repo,
            store: defaults,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: "profile-1"
        )
        let items = try XCTUnwrap(cw)
        XCTAssertEqual(items.count, 1)
        let upNext = items[0]
        XCTAssertEqual(upNext.isUpNext, true)
        XCTAssertEqual(upNext.season, 1)
        XCTAssertEqual(upNext.episode, 2)
        XCTAssertEqual(upNext.episodeDisplayTitle, "Cat's in the Bag...")
    }

    func testMdbListWatchStatsFallbackAndCaching() {
        let movieItem = WatchedStoreItem(
            meta: NuvioMeta(id: "tt1", name: "Movie 1", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: "tt1", tmdbId: nil, type: "movie", year: 2020, genres: nil, rating: nil, releaseInfo: nil, runtime: "120 min", cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil),
            watchedAt: Date(),
            season: nil,
            episode: nil,
            sources: [TraktWatchProgressSource.mdblist.rawValue]
        )
        let episodeItem = WatchedStoreItem(
            meta: NuvioMeta(id: "tt2", name: "Show 1", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: "tt2", tmdbId: nil, type: "series", year: 2021, genres: nil, rating: nil, releaseInfo: nil, runtime: "60 min", cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil),
            watchedAt: Date(),
            season: 1,
            episode: 1,
            sources: [TraktWatchProgressSource.mdblist.rawValue]
        )

        let localStats = MdbListWatchStats(watchedItems: [movieItem, episodeItem])
        XCTAssertEqual(localStats.moviesWatched, 1)
        XCTAssertEqual(localStats.showsWatched, 1)
        XCTAssertEqual(localStats.episodesWatched, 1)
        XCTAssertEqual(localStats.totalWatchedHours, 3) // 120min + 60min = 180min = 3 hours

        let remoteStats = MdbListWatchStats(moviesWatched: 5, showsWatched: nil, episodesWatched: 10, totalWatchedHours: nil)
        let merged = remoteStats.merging(fallback: localStats)
        XCTAssertEqual(merged.moviesWatched, 5)
        XCTAssertEqual(merged.showsWatched, 1)
        XCTAssertEqual(merged.episodesWatched, 10)
        XCTAssertEqual(merged.totalWatchedHours, 3)

        MdbListAuthStore.saveCachedStats(merged, store: defaults)
        let cached = MdbListAuthStore.cachedStats(in: defaults)
        XCTAssertEqual(cached, merged)
    }

    func testUserWatchStatsFallsBackToWatchedStoreWhenApiOmitsFields() async throws {
        let movieItem = WatchedStoreItem(
            meta: NuvioMeta(id: "tt1", name: "Movie 1", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: "tt1", tmdbId: nil, type: "movie", year: 2020, genres: nil, rating: nil, releaseInfo: nil, runtime: "120 min", cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil),
            watchedAt: Date(),
            season: nil,
            episode: nil,
            sources: [TraktWatchProgressSource.mdblist.rawValue]
        )
        WatchedStore.replaceAll([movieItem])

        MdbListURLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/user/stats")
            return Self.response(for: request, json: #"{"shows_watched": 12}"#)
        }

        let service = MdbListAuthService(
            client: client,
            store: defaults,
            profileScope: "profile-1",
            tokenStorage: tokenStorage
        )
        let stats = await service.fetchUserStats()
        let unwrapped = try XCTUnwrap(stats)
        XCTAssertEqual(unwrapped.showsWatched, 12)
        XCTAssertEqual(unwrapped.moviesWatched, 1)
        XCTAssertEqual(unwrapped.totalWatchedHours, 2)
    }

    func testLibraryMutationDrainsForCapturedMdbListAccountAndAcknowledgesOnlySuccess() async throws {
        let profileId = "mdblist-library-mutation-\(UUID().uuidString)"
        let previousSettingsProfileId = ProfileSettings.activeProfileID
        let previousSettingsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        let previousWatchedProfileId = WatchedStore.activeProfileId
        ProfileSettings.setActiveProfile(profileId, isPrimary: false)
        WatchedStore.setActiveProfile(profileId)
        let store = ProfileSettings.current
        defer {
            WatchedStore.eraseProfile(profileId)
            WatchedStore.setActiveProfile(previousWatchedProfileId)
            if let previousSettingsProfileId {
                ProfileSettings.setActiveProfile(previousSettingsProfileId, isPrimary: previousSettingsPrimary)
            } else {
                ProfileSettings.clearActiveProfile()
            }
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileId)")
            tokenStorage.remove(for: profileId)
        }

        store.set(TraktLibrarySourceMode.mdblist.rawValue, forKey: SettingsKey.traktLibrarySourceMode)
        let tokens = MdbListStoredTokens(
            accessToken: "library-access",
            refreshToken: "library-refresh",
            expiresAtMillis: Date().timeIntervalSince1970 * 1_000 + 3_600_000
        )
        XCTAssertTrue(MdbListAuthStore.saveTokens(
            tokens,
            user: MdbListUser(accountID: "library-user", username: "library-user", displayName: "Library User"),
            profileScope: profileId,
            store: store,
            tokenStorage: tokenStorage
        ))
        let accountID = MdbListAuthStore.accountBindingID(in: store)
        let meta = Self.meta(id: "tt8877665", type: "movie")
        let mutation = WatchedLibraryMutationUpload(
            provider: .mdblist,
            accountID: accountID,
            profileID: profileId,
            meta: meta,
            season: nil,
            episode: nil,
            isWatched: true,
            isPrimaryTarget: true
        )
        WatchedStore.replaceAll([
            WatchedStoreItem(
                meta: meta,
                watchedAt: mutation.changedAt,
                pendingLibraryMutations: [mutation],
                legacyUnattributed: false
            )
        ])

        var captured: [URLRequest] = []
        MdbListURLProtocolStub.handler = { request in
            captured.append(request)
            XCTAssertEqual(request.url?.path, "/sync/watched")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer library-access")
            let body = Self.jsonBody(request)
            XCTAssertNotNil(body["movies"])
            XCTAssertNil(body["shows"])
            return Self.response(for: request, status: 200, json: #"{"added":{"movies":[{"ids":{"imdb":"tt8877665"}}]}}"#)
        }

        let marked = await MdbListProgressService.flushPendingLibraryMutations(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileId
        )
        XCTAssertTrue(marked)
        XCTAssertEqual(captured.count, 1)
        XCTAssertTrue(WatchedStore.pendingLibraryMutations(provider: .mdblist, profileId: profileId).isEmpty)
        let saved = try XCTUnwrap(WatchedStore.items(profileId: profileId).first { $0.meta.id == meta.id })
        XCTAssertTrue(saved.isLibraryVisible(under: .mdblist))
        XCTAssertEqual(saved.watchCountsBySource[TraktWatchProgressSource.mdblist.rawValue], 1)

        let removeMutation = WatchedLibraryMutationUpload(
            provider: .mdblist,
            accountID: accountID,
            profileID: profileId,
            meta: meta,
            season: nil,
            episode: nil,
            isWatched: false,
            isPrimaryTarget: true
        )
        WatchedStore.replaceAll([
            WatchedStoreItem(
                meta: meta,
                watchedAt: mutation.changedAt,
                pendingLibraryMutations: [removeMutation],
                legacyUnattributed: false
            )
        ])
        MdbListURLProtocolStub.handler = { request in
            captured.append(request)
            return Self.response(for: request, status: 503, json: #"{"error":"offline"}"#)
        }
        let removalFailed = await MdbListProgressService.flushPendingLibraryMutations(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileId
        )
        XCTAssertFalse(removalFailed)
        let pendingAfterFailure = try XCTUnwrap(
            WatchedStore.pendingLibraryMutations(provider: .mdblist, profileId: profileId).first
        )
        XCTAssertEqual(pendingAfterFailure.attemptCount, 1)
        XCTAssertGreaterThan(pendingAfterFailure.nextAttemptAt ?? .distantPast, Date())
        XCTAssertFalse(WatchedStore.isWatchedForLibrary(meta: meta, source: .mdblist, profileId: profileId))

        XCTAssertTrue(MdbListAuthStore.saveTokens(
            MdbListStoredTokens(
                accessToken: "new-account-access",
                refreshToken: "new-account-refresh",
                expiresAtMillis: Date().timeIntervalSince1970 * 1_000 + 3_600_000
            ),
            user: MdbListUser(accountID: "different-user", username: "different-user", displayName: "Different User"),
            profileScope: profileId,
            store: store,
            tokenStorage: tokenStorage
        ))
        let newAccountFlush = await MdbListProgressService.flushPendingLibraryMutations(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileId
        )
        XCTAssertTrue(newAccountFlush)
        XCTAssertEqual(captured.count, 2, "An old account's pending delete must never be sent to a newly linked MDBList account.")
        XCTAssertEqual(
            WatchedStore.pendingLibraryMutations(provider: .mdblist, profileId: profileId).first?.accountID,
            accountID
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

    private static func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
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

private func mdbListTestMetadata(id: String, type: String, runtime: String?, videos: [NuvioVideo]? = nil) -> NuvioMeta {
    let baseId = id.split(separator: ":").first.map(String.init) ?? id
    let imdbId = baseId.hasPrefix("tt") ? baseId : nil
    return NuvioMeta(
        id: id,
        name: type == "movie" ? "Movie" : "Show",
        description: nil,
        posterUrl: nil,
        backgroundUrl: nil,
        logoUrl: nil,
        imdbId: imdbId,
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
        released: nil,
        videos: videos
    )
}

private final class MdbListCatalogRepository: MockCatalogRepository {
    var customMeta: [String: NuvioMeta] = [:]

    override func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        if let custom = customMeta[id] {
            return custom
        }
        return mdbListTestMetadata(
            id: id,
            type: type,
            runtime: id == "tmdb:1399" ? "45 min" : "100 min"
        )
    }
}

private final class MdbListControlledDetailsRepo: MockCatalogRepository {
    var metadataWaiterEntered: ((String) -> Void)?
    private let waiterLock = NSLock()
    private var waiters: [String: [CheckedContinuation<NuvioMeta, Never>]] = [:]

    override func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        await withCheckedContinuation { (continuation: CheckedContinuation<NuvioMeta, Never>) in
            waiterLock.lock()
            waiters[id, default: []].append(continuation)
            waiterLock.unlock()
            metadataWaiterEntered?(id)
        }
    }

    override func getStreams(id: String, type: String) async throws -> [NuvioStream] {
        []
    }

    func release(id: String, type: String = "movie") {
        waiterLock.lock()
        let waiter = waiters[id]?.popLast()
        waiterLock.unlock()
        waiter?.resume(returning: NuvioMeta(
            id: id,
            name: "\(id)-full",
            description: "Full metadata",
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: id,
            tmdbId: 100,
            type: type,
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            language: nil,
            released: nil,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: nil
        ))
    }
}

private final class MdbListURLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return host.contains("mdblist.com")
    }

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
