import XCTest
@testable import NuvioTV

private final class WeTrakrFixtureURLProtocol: URLProtocol {
    typealias Response = (status: Int, headers: [String: String], body: Data)

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var handler: ((URLRequest) -> Response)?
        var requests: [URLRequest] = []
    }

    private static let state = State()

    static func install(_ handler: @escaping (URLRequest) -> Response) {
        state.lock.lock()
        state.handler = handler
        state.requests = []
        state.lock.unlock()
    }

    static func capturedRequests() -> [URLRequest] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.requests
    }

    static func reset() {
        state.lock.lock()
        state.handler = nil
        state.requests = []
        state.lock.unlock()
    }

    private static func normalizedRequest(_ request: URLRequest) -> URLRequest {
        var normalized = request
        guard normalized.httpBody == nil, let stream = request.httpBodyStream else { return normalized }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let readCount = buffer.withUnsafeMutableBufferPointer { bufferPointer in
                stream.read(bufferPointer.baseAddress!, maxLength: bufferPointer.count)
            }
            guard readCount > 0 else { break }
            data.append(buffer, count: readCount)
        }
        normalized.httpBodyStream = nil
        normalized.httpBody = data
        return normalized
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let normalizedRequest = Self.normalizedRequest(request)
        Self.state.lock.lock()
        let handler = Self.state.handler
        Self.state.requests.append(normalizedRequest)
        Self.state.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let fixture = handler(normalizedRequest)
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: fixture.status,
                httpVersion: "HTTP/1.1",
                headerFields: fixture.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class WeTrakrAuthServiceTests: XCTestCase {
    private var suiteName: String!
    private var store: UserDefaults!
    private var memoryStorage: WeTrakrMemoryTokenStorage!
    private var originalProfileID: String?
    private var isolatedProfileID: String?
    private var originalWatchSource: TraktWatchProgressSource!
    private var originalProgressClient: WeTrakrAPIClient!
    private var originalProgressTokenStorage: WeTrakrTokenStorage!
    private var fixtureSession: URLSession?

    override func setUp() {
        super.setUp()
        suiteName = "WeTrakrAuthServiceTests.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)!
        memoryStorage = WeTrakrMemoryTokenStorage()
        originalProfileID = ProfileSettings.activeProfileID
        originalWatchSource = TraktSettingsStore.watchProgressSource
        originalProgressClient = WeTrakrProgressService.client
        originalProgressTokenStorage = WeTrakrProgressService.tokenStorage
        WeTrakrFixtureURLProtocol.reset()
    }

    override func tearDown() {
        fixtureSession?.invalidateAndCancel()
        fixtureSession = nil
        WeTrakrFixtureURLProtocol.reset()
        if let isolatedProfileID {
            WatchedStore.setActiveProfile(nil)
            let profileStore = ProfileSettings.store(for: isolatedProfileID)
            for key in profileStore.dictionaryRepresentation().keys {
                profileStore.removeObject(forKey: key)
            }
        }
        if let originalProfileID {
            ProfileSettings.setActiveProfile(originalProfileID)
            WatchedStore.setActiveProfile(originalProfileID)
        } else {
            ProfileSettings.clearActiveProfile()
            WatchedStore.setActiveProfile(nil)
        }
        TraktSettingsStore.watchProgressSource = originalWatchSource
        WeTrakrProgressService.client = originalProgressClient
        WeTrakrProgressService.tokenStorage = originalProgressTokenStorage
        if let suiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        store = nil
        memoryStorage = nil
        isolatedProfileID = nil
        super.tearDown()
    }

    private func prepareWeTrakrProfile(accountID: String? = "account-1") -> String {
        let profileID = "wetrakr-test-\(UUID().uuidString)"
        isolatedProfileID = profileID
        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        WatchedStore.setActiveProfile(profileID)
        store = ProfileSettings.current
        store.set("test-client", forKey: SettingsKey.wetrakrClientID)
        WeTrakrProgressService.tokenStorage = memoryStorage
        WeTrakrAuthStore.saveToken(
            "test-access-token",
            clientID: "test-client",
            profileScope: profileID,
            store: store,
            tokenStorage: memoryStorage
        )
        WeTrakrAuthStore.saveUser(
            username: "test-user",
            displayName: "Test User",
            accountID: accountID,
            accountPlan: "vip",
            avatarURL: nil,
            store: store
        )
        TraktSettingsStore.watchProgressSource = .wetrakr

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeTrakrFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        fixtureSession = session
        WeTrakrProgressService.client = WeTrakrAPIClient(session: session)
        return profileID
    }

    private func fixtureResponse(
        _ object: Any,
        status: Int = 200,
        headers: [String: String] = [:]
    ) -> WeTrakrFixtureURLProtocol.Response {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed])) ?? Data()
        return (status: status, headers: headers, body: data)
    }

    private func requestJSON(_ request: URLRequest) -> [String: Any]? {
        guard let body = request.httpBody else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private func historyPageHeaders(page: Int, pageCount: Int, limit: Int = 100) -> [String: String] {
        [
            "X-Pagination-Page": String(page),
            "X-Pagination-Page-Count": String(pageCount),
            "X-Pagination-Limit": String(limit)
        ]
    }

    private func completionMeta() -> NuvioMeta {
        NuvioMeta(id: "tt13624718", name: "Arrival", type: "movie", year: 2016)
    }

    func testConfigAndCredentials() {
        XCTAssertFalse(WeTrakrConfig.isConfigured(in: store))
        XCTAssertEqual(WeTrakrConfig.clientID(in: store), "")

        store.set("wetrakr_client_123", forKey: SettingsKey.wetrakrClientID)
        store.set("wetrakr_secret_456", forKey: SettingsKey.wetrakrClientSecret)

        XCTAssertTrue(WeTrakrConfig.isConfigured(in: store))
        XCTAssertEqual(WeTrakrConfig.clientID(in: store), "wetrakr_client_123")
        XCTAssertEqual(WeTrakrConfig.clientSecret(in: store), "wetrakr_secret_456")
    }

    func testDeviceFlowSavingAndActiveCheck() {
        let clientID = "client_abc"
        store.set(clientID, forKey: SettingsKey.wetrakrClientID)

        let deviceResponse = WeTrakrDeviceCodeResponse(
            deviceCode: "dev_code_xyz",
            userCode: "K7PX4M",
            verificationUrl: "https://wetrakr.com/activate",
            expiresIn: 600,
            interval: 5
        )

        WeTrakrAuthStore.saveDeviceFlow(deviceResponse, clientID: clientID, store: store)

        let state = WeTrakrAuthStore.state(in: store, profileScope: "default", tokenStorage: memoryStorage)
        XCTAssertEqual(state.userCode, "K7PX4M")
        XCTAssertEqual(state.deviceCode, "dev_code_xyz")
        XCTAssertEqual(state.verificationURI, "https://wetrakr.com/activate")
        XCTAssertEqual(state.pollInterval, 5)
        XCTAssertTrue(state.hasActivePINFlow(in: store))
        XCTAssertFalse(state.isAuthenticated(in: store))

        WeTrakrAuthStore.clearDeviceFlow(store: store)
        let clearedState = WeTrakrAuthStore.state(in: store, profileScope: "default", tokenStorage: memoryStorage)
        XCTAssertNil(clearedState.userCode)
        XCTAssertFalse(clearedState.hasActivePINFlow(in: store))
    }

    func testTokenStorageAndAuthentication() {
        let clientID = "client_abc"
        store.set(clientID, forKey: SettingsKey.wetrakrClientID)

        WeTrakrAuthStore.saveToken(
            "access_token_123",
            refreshToken: "refresh_token_456",
            expiresIn: 604800,
            clientID: clientID,
            profileScope: "default",
            store: store,
            tokenStorage: memoryStorage
        )

        let state = WeTrakrAuthStore.state(in: store, profileScope: "default", tokenStorage: memoryStorage)
        XCTAssertTrue(state.isAuthenticated(in: store))
        XCTAssertEqual(state.accessToken, "access_token_123")
        XCTAssertEqual(state.refreshToken, "refresh_token_456")

        WeTrakrAuthStore.saveUser(
            username: "moviebuff",
            displayName: "Movie Buff",
            accountID: "1140",
            accountPlan: "vip",
            avatarURL: "https://media.wetrakr.com/avatars/test.webp",
            store: store
        )

        let userState = WeTrakrAuthStore.state(in: store, profileScope: "default", tokenStorage: memoryStorage)
        XCTAssertEqual(userState.username, "moviebuff")
        XCTAssertEqual(userState.displayName, "Movie Buff")
        XCTAssertEqual(userState.accountPlan, "vip")
        XCTAssertEqual(userState.accountID, "1140")

        WeTrakrAuthStore.clearAuth(profileScope: "default", store: store, tokenStorage: memoryStorage)
        let unauthState = WeTrakrAuthStore.state(in: store, profileScope: "default", tokenStorage: memoryStorage)
        XCTAssertFalse(unauthState.isAuthenticated(in: store))
        XCTAssertNil(unauthState.accessToken)
        XCTAssertNil(unauthState.username)
    }

    func testScrobblePayloadEncodability() throws {
        let moviePayload = WeTrakrScrobblePayload(
            movie: WeTrakrMediaPayload(
                title: "Inception",
                year: 2010,
                ids: WeTrakrSyncIDs(wetrakr: nil, imdb: "tt1375666", tmdb: 27205, tvdb: nil)
            ),
            show: nil,
            episode: nil,
            progress: 45.5,
            appVersion: "3.4.1"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(moviePayload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(json?["movie"])
        XCTAssertNil(json?["show"])
        XCTAssertEqual(json?["progress"] as? Double, 45.5)
        XCTAssertEqual(json?["app_version"] as? String, "3.4.1")

        let showPayload = WeTrakrScrobblePayload(
            movie: nil,
            show: WeTrakrMediaPayload(
                title: "Breaking Bad",
                year: 2008,
                ids: WeTrakrSyncIDs(wetrakr: nil, imdb: "tt0903747", tmdb: 1396, tvdb: 81189)
            ),
            episode: WeTrakrEpisodePayload(season: 1, number: 1),
            progress: 85.0,
            appVersion: "3.4.1"
        )

        let showData = try encoder.encode(showPayload)
        let showJson = try JSONSerialization.jsonObject(with: showData) as? [String: Any]

        XCTAssertNotNil(showJson?["show"])
        XCTAssertNotNil(showJson?["episode"])
        XCTAssertEqual(showJson?["progress"] as? Double, 85.0)
    }

    func testRemoteTrackingStateWithWeTrakr() {
        store.set(TraktWatchProgressSource.wetrakr.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        store.set(TraktLibrarySourceMode.wetrakr.rawValue, forKey: SettingsKey.traktLibrarySourceMode)

        // When not authenticated, isProgressSourceAuthenticated should be false
        XCTAssertFalse(RemoteTrackingState.isProgressSourceAuthenticated(.wetrakr, in: store))
        XCTAssertFalse(RemoteTrackingState.isLibrarySourceAuthenticated(.wetrakr, in: store))

        // Save valid token
        let clientID = "client_xyz"
        store.set(clientID, forKey: SettingsKey.wetrakrClientID)
        WeTrakrAuthStore.saveToken(
            "token_live",
            clientID: clientID,
            profileScope: "default",
            store: store,
            tokenStorage: memoryStorage
        )

        // WeTrakrRuntimeSession will check ProfileSettings / store
        let authState = WeTrakrRuntimeSession.authenticatedState(store: store, tokenStorage: memoryStorage, profileScope: "default")
        XCTAssertNotNil(authState)
    }

    func testWeTrakrIDsExtraction() {
        let imdbMeta = NuvioMeta(id: "tt0903747", name: "Breaking Bad", type: "series")
        let imdbIds = WeTrakrProgressService.wetrakrIDs(for: imdbMeta)
        XCTAssertEqual(imdbIds.imdb, "tt0903747")
        XCTAssertNil(imdbIds.tmdb)

        let tmdbEpisodeMeta = NuvioMeta(id: "tmdb:1396:1:1", name: "Breaking Bad", type: "series")
        let tmdbIds = WeTrakrProgressService.wetrakrIDs(for: tmdbEpisodeMeta)
        XCTAssertEqual(tmdbIds.tmdb, 1396)
        XCTAssertNil(tmdbIds.imdb)

        let tvdbMeta = NuvioMeta(id: "tvdb:81189", name: "Breaking Bad", type: "series")
        let tvdbIds = WeTrakrProgressService.wetrakrIDs(for: tvdbMeta)
        XCTAssertEqual(tvdbIds.tvdb, 81189)

        let wetrakrMeta = NuvioMeta(id: "wetrakr:126", name: "The Dark Knight", type: "movie")
        let wetrakrIds = WeTrakrProgressService.wetrakrIDs(for: wetrakrMeta)
        XCTAssertEqual(wetrakrIds.wetrakr, 126)
    }

    func testMoviePlayingItemDecoding() throws {
        let json = """
        {
            "id": 126,
            "type": "movie",
            "title": "The Dark Knight",
            "year": 2008,
            "ids": {
                "wetrakr": 126,
                "tmdb": 155,
                "imdb": "tt0468569"
            },
            "poster_path": "/qJ2tW6WMUDux911r6m7haRef0WH.jpg",
            "backdrop_path": "/nMKdUUepR0i5zn0y1T4CsSB5chy.jpg",
            "runtime": 152,
            "playback": {
                "status": "paused",
                "progress_percent": 45.2,
                "runtime_seconds": 9120,
                "tracked_at": "2026-08-15T21:31:34.956Z"
            }
        }
        """

        let decoder = JSONDecoder()
        let item = try decoder.decode(WeTrakrTrackingPlayingItemDTO.self, from: Data(json.utf8))

        XCTAssertFalse(item.resolvedIsSeries)
        XCTAssertEqual(item.resolvedMedia.title, "The Dark Knight")
        XCTAssertEqual(item.resolvedMedia.ids?.imdb, "tt0468569")
        XCTAssertEqual(item.resolvedMedia.ids?.tmdb, 155)
        XCTAssertEqual(item.resolvedProgressPercent, 45.2)
        XCTAssertEqual(item.resolvedRuntimeSeconds, 9120)
        XCTAssertNil(item.resolvedSeasonNumber)
        XCTAssertNil(item.resolvedEpisodeNumber)
    }

    func testEpisodePlayingItemDecoding() throws {
        let json = """
        {
            "id": 174658,
            "type": "episode",
            "title": "Pilot",
            "season_number": 1,
            "number": 1,
            "season_poster_path": "/1yeVJox3rjo2jBKrrihIMj7uoS9.jpg",
            "show": {
                "id": 1391953,
                "type": "show",
                "title": "Breaking Bad",
                "year": 2008,
                "ids": {
                    "wetrakr": 1391953,
                    "tmdb": 1396,
                    "imdb": "tt0903747",
                    "tvdb": 81189
                },
                "poster_path": "/ggFHVNu6YYI5L9pCfOacjizRGt.jpg"
            },
            "playback": {
                "status": "paused",
                "progress_percent": 35.0,
                "runtime_seconds": 3480,
                "tracked_at": "2026-08-15T21:31:34.956Z"
            }
        }
        """

        let decoder = JSONDecoder()
        let item = try decoder.decode(WeTrakrTrackingPlayingItemDTO.self, from: Data(json.utf8))

        XCTAssertTrue(item.resolvedIsSeries)
        XCTAssertEqual(item.resolvedMedia.title, "Breaking Bad")
        XCTAssertEqual(item.resolvedMedia.ids?.imdb, "tt0903747")
        XCTAssertEqual(item.resolvedMedia.ids?.tmdb, 1396)
        XCTAssertEqual(item.resolvedSeasonNumber, 1)
        XCTAssertEqual(item.resolvedEpisodeNumber, 1)
        XCTAssertEqual(item.resolvedEpisodeTitle, "Pilot")
        XCTAssertEqual(item.resolvedProgressPercent, 35.0)
        XCTAssertEqual(item.resolvedRuntimeSeconds, 3480)
    }

    func testScrobblePlayingNowDecoding() throws {
        let json = """
        {
            "status": "paused",
            "target": "movie",
            "progress_percent": 7.0,
            "runtime_seconds": 5880,
            "tracked_at": "2026-08-15T21:31:34.956Z",
            "media": {
                "id": 1053809,
                "type": "movie",
                "title": "Pizza Movie",
                "poster_path": "/3rovbwvxJ5eQrWrQnF1VfJoPcMD.jpg",
                "runtime": 98,
                "ids": {
                    "tmdb": 9999
                }
            }
        }
        """

        let decoder = JSONDecoder()
        let item = try decoder.decode(WeTrakrTrackingPlayingItemDTO.self, from: Data(json.utf8))

        XCTAssertFalse(item.resolvedIsSeries)
        XCTAssertEqual(item.resolvedMedia.title, "Pizza Movie")
        XCTAssertEqual(item.resolvedMedia.ids?.tmdb, 9999)
        XCTAssertEqual(item.resolvedProgressPercent, 7.0)
        XCTAssertEqual(item.resolvedRuntimeSeconds, 5880)
    }

    func testWatchedStoreSameContentMatchesSeriesTitleFallback() {
        let meta1 = NuvioMeta(
            id: "tt21097264",
            name: "East of Eden",
            description: nil,
            posterUrl: "https://image.tmdb.org/t/p/w500/test.jpg",
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt21097264",
            tmdbId: 245318,
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
            language: nil,
            released: nil,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: nil,
            posterShape: nil
        )

        let meta2 = NuvioMeta(
            id: "wetrakr:1172533",
            name: "East of Eden",
            description: nil,
            posterUrl: "https://image.tmdb.org/t/p/w500/test.jpg",
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
            language: nil,
            released: nil,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: nil,
            posterShape: nil
        )

        XCTAssertTrue(WatchedStore.sameContent(meta1, meta2), "Items with matching normalized series title and year should be treated as same content")
    }

    func testTrackingPayloadEncodability() throws {
        let movieAdd = WeTrakrTrackingAddPayload(
            movies: [
                WeTrakrMediaPayload(
                    title: "Inception",
                    year: 2010,
                    ids: WeTrakrSyncIDs(imdb: "tt1375666", tmdb: 27205),
                    status: "watched"
                )
            ],
            shows: nil,
            allowRewatch: true
        )

        let encoder = JSONEncoder()
        let movieData = try encoder.encode(movieAdd)
        let movieJson = try JSONSerialization.jsonObject(with: movieData) as? [String: Any]

        XCTAssertEqual(movieJson?["allow_rewatch"] as? Bool, true)
        let moviesArray = movieJson?["movies"] as? [[String: Any]]
        XCTAssertEqual(moviesArray?.count, 1)
        XCTAssertEqual(moviesArray?.first?["status"] as? String, "watched")
        XCTAssertEqual(moviesArray?.first?["title"] as? String, "Inception")

        let showAdd = WeTrakrTrackingAddPayload(
            movies: nil,
            shows: [
                WeTrakrShowTrackingPayload(
                    title: "Severance",
                    year: 2022,
                    ids: WeTrakrSyncIDs(imdb: "tt11280740"),
                    status: "watched",
                    seasons: [
                        WeTrakrSeasonTrackingPayload(
                            number: 1,
                            status: "watched",
                            episodes: [
                                WeTrakrEpisodeTrackingPayload(number: 1, status: "watched")
                            ]
                        )
                    ]
                )
            ],
            allowRewatch: true
        )

        let showData = try encoder.encode(showAdd)
        let showJson = try JSONSerialization.jsonObject(with: showData) as? [String: Any]
        let showsArray = showJson?["shows"] as? [[String: Any]]
        XCTAssertEqual(showsArray?.count, 1)
        XCTAssertEqual(showsArray?.first?["status"] as? String, "watched")
        let seasonsArray = showsArray?.first?["seasons"] as? [[String: Any]]
        XCTAssertEqual(seasonsArray?.first?["number"] as? Int, 1)
        XCTAssertEqual(seasonsArray?.first?["status"] as? String, "watched")
        let episodesArray = seasonsArray?.first?["episodes"] as? [[String: Any]]
        XCTAssertEqual(episodesArray?.first?["number"] as? Int, 1)
        XCTAssertEqual(episodesArray?.first?["status"] as? String, "watched")

        let watchlistPlanning = WeTrakrTrackingAddPayload(
            movies: [
                WeTrakrMediaPayload(
                    title: "Dune",
                    year: 2021,
                    ids: WeTrakrSyncIDs(imdb: "tt1160419"),
                    status: "planning"
                )
            ],
            shows: nil,
            allowRewatch: nil
        )
        let planningData = try encoder.encode(watchlistPlanning)
        let planningJson = try JSONSerialization.jsonObject(with: planningData) as? [String: Any]
        let planningMovies = planningJson?["movies"] as? [[String: Any]]
        XCTAssertEqual(planningMovies?.first?["status"] as? String, "planning")
    }

    func testWeTrakrHistoryDTODecoding() throws {
        let jsonStr = """
        [
            {
                "id": "6aa9d0450aa463e732ebd373",
                "watched_at": "2026-09-15T21:09:53.772Z",
                "episode": {
                    "id": 5092071,
                    "season_number": 1,
                    "number": 1,
                    "show": {
                        "id": 1333953,
                        "title": "Margo's Got Money Troubles",
                        "ids": {
                            "tmdb": 245318,
                            "imdb": "tt31137273"
                        }
                    }
                }
            },
            {
                "id": "6aa9d0450aa463e732ebd374",
                "watched_at": "2026-09-16T12:00:00.000Z",
                "movie": {
                    "id": 12345,
                    "title": "Inception",
                    "year": 2010,
                    "ids": {
                        "imdb": "tt1375666",
                        "tmdb": 27205
                    }
                }
            }
        ]
        """

        let data = jsonStr.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([WeTrakrTrackingHistoryItemDTO].self, from: data)

        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].id, "6aa9d0450aa463e732ebd373")
        XCTAssertEqual(decoded[0].episode?.seasonNumber, 1)
        XCTAssertEqual(decoded[0].episode?.number, 1)
        XCTAssertEqual(decoded[0].episode?.show?.title, "Margo's Got Money Troubles")
        XCTAssertEqual(decoded[0].episode?.show?.ids?.imdb, "tt31137273")

        XCTAssertEqual(decoded[1].id, "6aa9d0450aa463e732ebd374")
        XCTAssertEqual(decoded[1].movie?.title, "Inception")
        XCTAssertEqual(decoded[1].movie?.ids?.tmdb, 27205)
    }

    func testReconcileWeTrakrSnapshot() {
        let originalSource = TraktSettingsStore.watchProgressSource
        TraktSettingsStore.watchProgressSource = .wetrakr
        defer {
            TraktSettingsStore.watchProgressSource = originalSource
        }

        let meta = NuvioMeta(
            id: "tt1375666",
            name: "Inception",
            type: "movie",
            year: 2010
        )
        let item = WatchedStoreItem(
            meta: meta,
            watchedAt: Date(),
            sources: [TraktWatchProgressSource.wetrakr.rawValue]
        )

        let success = WatchedStore.reconcileWeTrakrSnapshot(
            [item],
            previousRemoteItems: [],
            syncStartedAt: Date()
        )
        XCTAssertTrue(success)
        XCTAssertTrue(WatchedStore.contains(meta: meta))
    }

    func testCancelPlaybackPayloadEncoding() throws {
        let movieCancel = WeTrakrCancelPlaybackPayload(
            movie: WeTrakrMediaPayload(
                title: "Inception",
                year: 2010,
                ids: WeTrakrSyncIDs(imdb: "tt1375666", tmdb: 27205)
            ),
            show: nil,
            episode: nil
        )
        let encoder = JSONEncoder()
        let movieData = try encoder.encode(movieCancel)
        let movieJson = try JSONSerialization.jsonObject(with: movieData) as? [String: Any]
        XCTAssertNotNil(movieJson?["movie"])
        XCTAssertNil(movieJson?["show"])
        XCTAssertNil(movieJson?["episode"])
        XCTAssertNil(movieJson?["progress"])

        let showCancel = WeTrakrCancelPlaybackPayload(
            movie: nil,
            show: WeTrakrMediaPayload(
                title: "Breaking Bad",
                year: 2008,
                ids: WeTrakrSyncIDs(imdb: "tt0903747")
            ),
            episode: WeTrakrEpisodePayload(season: 1, number: 1)
        )
        let showData = try encoder.encode(showCancel)
        let showJson = try JSONSerialization.jsonObject(with: showData) as? [String: Any]
        XCTAssertNil(showJson?["movie"])
        XCTAssertNotNil(showJson?["show"])
        let epJson = showJson?["episode"] as? [String: Any]
        XCTAssertEqual(epJson?["season"] as? Int, 1)
        XCTAssertEqual(epJson?["number"] as? Int, 1)
    }

    func testRemovePlaybackTrackingPayloadEncoding() throws {
        let payload = WeTrakrTrackingRemovePayload(
            movies: [
                WeTrakrMediaPayload(
                    title: "Inception",
                    year: 2010,
                    ids: WeTrakrSyncIDs(imdb: "tt1375666"),
                    status: "playing"
                )
            ],
            shows: [
                WeTrakrShowTrackingPayload(
                    title: "Severance",
                    year: 2022,
                    ids: WeTrakrSyncIDs(imdb: "tt11280740"),
                    status: "playing",
                    seasons: [
                        WeTrakrSeasonTrackingPayload(
                            number: 1,
                            status: "playing",
                            episodes: [
                                WeTrakrEpisodeTrackingPayload(number: 1, status: "playing")
                            ]
                        )
                    ]
                )
            ]
        )
        let data = try JSONEncoder().encode(payload)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let movies = json?["movies"] as? [[String: Any]]
        XCTAssertEqual(movies?.first?["status"] as? String, "playing")
        let shows = json?["shows"] as? [[String: Any]]
        XCTAssertEqual(shows?.first?["status"] as? String, "playing")
        let seasons = shows?.first?["seasons"] as? [[String: Any]]
        XCTAssertEqual(seasons?.first?["status"] as? String, "playing")
        let episodes = seasons?.first?["episodes"] as? [[String: Any]]
        XCTAssertEqual(episodes?.first?["status"] as? String, "playing")
    }

    func testFinalizerCancelsOwnedSessionThenAddsDatedHistoryWithoutScrobbleStop() async throws {
        let profileID = prepareWeTrakrProfile()
        let completionID = UUID().uuidString
        let meta = completionMeta()
        XCTAssertTrue(WatchedStore.recordPlaybackCompletion(
            meta,
            completionID: completionID,
            source: .wetrakr,
            completionAccounts: [TraktWatchProgressSource.wetrakr.rawValue: "account-1"]
        ))

        WeTrakrFixtureURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if path == "/sync/tracking", request.httpMethod == "POST" {
                let requestBody = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let movie = (requestBody["movies"] as? [[String: Any]])?.first ?? [:]
                let trackedAt = movie["tracked_at"] as? String ?? "2026-10-11T12:00:00.000Z"
                let response: [String: Any] = [
                    "added": ["plays": [[
                        "type": "movie",
                        "play_id": "wetrakr-play-1",
                        "watched_at": trackedAt
                    ]]]
                ]
                return (
                    status: 200,
                    headers: [:],
                    body: (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
                )
            }
            return (status: 200, headers: [:], body: Data("{}".utf8))
        }

        let started = await WeTrakrProgressService.reportPlayback(
            meta: meta,
            position: 10,
            duration: 100,
            season: nil,
            episode: nil,
            action: .start,
            expectedAccountID: "account-1",
            playbackID: completionID,
            profileId: profileID,
            store: store
        )
        XCTAssertTrue(started)

        let finished = await WeTrakrProgressService.finishPlaybackForHistory(
            meta: meta,
            position: 100,
            duration: 100,
            season: nil,
            episode: nil,
            store: store,
            profileId: profileID,
            completionID: completionID,
            accountID: "account-1"
        )
        XCTAssertTrue(finished)

        let requests = WeTrakrFixtureURLProtocol.capturedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/scrobble/start", "/scrobble/playing", "/sync/tracking"])
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[1].httpMethod, "DELETE")
        XCTAssertFalse(requests.contains { $0.url?.path == "/scrobble/stop" })
        XCTAssertNotEqual(requests[1].value(forHTTPHeaderField: "Idempotency-Key"), completionID)

        let addRequest = requests[2]
        XCTAssertEqual(addRequest.value(forHTTPHeaderField: "Idempotency-Key"), completionID)
        let addBody = requestJSON(addRequest)
        XCTAssertEqual(addBody?["allow_rewatch"] as? Bool, true)
        let movie = (addBody?["movies"] as? [[String: Any]])?.first
        XCTAssertNotNil(movie?["tracked_at"] as? String)
        XCTAssertNil(movie?["watched_at"])
        XCTAssertTrue(WatchedStore.pendingPlaybackCompletions(provider: .wetrakr, profileId: profileID).isEmpty)
    }

    func testNormalSyncCancelsMatchingLiveOwnerBeforeUploadingHistory() async throws {
        let profileID = prepareWeTrakrProfile()
        let completionID = UUID().uuidString
        let meta = completionMeta()
        XCTAssertTrue(WatchedStore.recordPlaybackCompletion(
            meta,
            completionID: completionID,
            source: .wetrakr,
            completionAccounts: [TraktWatchProgressSource.wetrakr.rawValue: "account-1"]
        ))

        WeTrakrFixtureURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/sync/tracking" {
                let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let movie = (body["movies"] as? [[String: Any]])?.first ?? [:]
                let trackedAt = movie["tracked_at"] as? String ?? "2026-10-11T12:00:00.000Z"
                let response: [String: Any] = [
                    "added": ["plays": [["type": "movie", "play_id": "live-play", "watched_at": trackedAt]]]
                ]
                return (status: 200, headers: [:], body: (try? JSONSerialization.data(withJSONObject: response)) ?? Data())
            }
            if request.httpMethod == "GET", path == "/sync/tracking/watched/history/movies" {
                let history: [[String: Any]] = [[
                    "id": "live-play",
                    "watched_at": "2026-10-11T12:00:00.000Z",
                    "movie": ["id": 13624718, "title": "Arrival", "year": 2016, "ids": ["imdb": "tt13624718"]]
                ]]
                return (
                    status: 200,
                    headers: ["X-Pagination-Page": "1", "X-Pagination-Page-Count": "1", "X-Pagination-Limit": "100"],
                    body: (try? JSONSerialization.data(withJSONObject: history)) ?? Data()
                )
            }
            if request.httpMethod == "GET" {
                return (
                    status: 200,
                    headers: ["X-Pagination-Page": "1", "X-Pagination-Page-Count": "1", "X-Pagination-Limit": "100"],
                    body: Data("[]".utf8)
                )
            }
            return (status: 200, headers: [:], body: Data("{}".utf8))
        }

        let started = await WeTrakrProgressService.reportPlayback(
            meta: meta,
            position: 10,
            duration: 100,
            season: nil,
            episode: nil,
            action: .start,
            expectedAccountID: "account-1",
            playbackID: completionID,
            profileId: profileID,
            store: store
        )
        XCTAssertTrue(started)

        // Exercise history sync when WeTrakr owns only the library, while the
        // live playback session was started before switching watch progress.
        store.set(TraktLibrarySourceMode.wetrakr.rawValue, forKey: SettingsKey.traktLibrarySourceMode)
        TraktSettingsStore.watchProgressSource = .trakt
        XCTAssertEqual(TraktSettingsStore.watchProgressSource(in: store), .trakt)
        XCTAssertEqual(TraktSettingsStore.librarySourceMode(in: store), .wetrakr)

        let synced = await WeTrakrProgressService.syncWatchedHistory(store: store)
        XCTAssertTrue(synced)
        let requests = WeTrakrFixtureURLProtocol.capturedRequests()
        XCTAssertEqual(requests.prefix(3).map { $0.url?.path }, ["/scrobble/start", "/scrobble/playing", "/sync/tracking"])
        XCTAssertFalse(requests.contains { $0.url?.path == "/scrobble/stop" })
        XCTAssertEqual(requests[1].httpMethod, "DELETE")
        XCTAssertTrue(WatchedStore.pendingPlaybackCompletions(provider: .wetrakr, profileId: profileID).isEmpty)
    }

    func testCompletionRetryUsesStableTrackedAtAndTerminalDuplicateRefreshesCount() async throws {
        let profileID = prepareWeTrakrProfile()
        let meta = completionMeta()
        let oldItem = WatchedStoreItem(
            meta: meta,
            watchedAt: Date().addingTimeInterval(-120),
            sources: [TraktWatchProgressSource.wetrakr.rawValue],
            watchCountsBySource: [TraktWatchProgressSource.wetrakr.rawValue: 1]
        )
        XCTAssertTrue(WatchedStore.mergeRemote(
            [oldItem],
            confirmsTombstoneDeletions: false,
            profileId: profileID
        ))

        let completionID = UUID().uuidString
        XCTAssertTrue(WatchedStore.recordPlaybackCompletion(
            meta,
            completionID: completionID,
            source: .wetrakr,
            completionAccounts: [TraktWatchProgressSource.wetrakr.rawValue: "account-1"]
        ))
        let optimisticCount = WatchedStore.items(profileId: profileID)
            .first(where: { WatchedStore.sameContent($0.meta, meta) })?
            .watchCountsBySource[TraktWatchProgressSource.wetrakr.rawValue]
        XCTAssertEqual(optimisticCount, 2)

        var addCount = 0
        var retryTrackedAt = ""
        WeTrakrFixtureURLProtocol.install { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "POST", path == "/sync/tracking" {
                addCount += 1
                if addCount == 1 {
                    return (status: 503, headers: [:], body: Data("{\"error\":\"temporarily unavailable\"}".utf8))
                }
                let requestBody = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let movie = (requestBody["movies"] as? [[String: Any]])?.first ?? [:]
                retryTrackedAt = movie["tracked_at"] as? String ?? ""
                let response: [String: Any] = [
                    "errored": ["movies": [[
                        "ids": ["imdb": "tt13624718"],
                        "tracked_at": retryTrackedAt,
                        "error": "Already added! A play within the hour counts as the same watch"
                    ]]]
                ]
                return (
                    status: 200,
                    headers: [:],
                    body: (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
                )
            }

            if request.httpMethod == "GET", path == "/sync/tracking/watched/history/movies" {
                let history: [[String: Any]] = [[
                    "id": "existing-play",
                    "watched_at": retryTrackedAt,
                    "movie": [
                        "id": 13624718,
                        "title": "Arrival",
                        "year": 2016,
                        "ids": ["imdb": "tt13624718"]
                    ]
                ]]
                return (
                    status: 200,
                    headers: self.historyPageHeaders(page: 1, pageCount: 1),
                    body: (try? JSONSerialization.data(withJSONObject: history)) ?? Data()
                )
            }
            if request.httpMethod == "GET" {
                return (
                    status: 200,
                    headers: self.historyPageHeaders(page: 1, pageCount: 1),
                    body: Data("[]".utf8)
                )
            }
            return (status: 500, headers: [:], body: Data())
        }

        let firstFlush = await WeTrakrProgressService.flushPendingPlaybackCompletions(
            store: store,
            profileId: profileID
        )
        XCTAssertFalse(firstFlush)
        XCTAssertEqual(WatchedStore.pendingPlaybackCompletions(provider: .wetrakr, profileId: profileID).count, 1)

        // A normal provider sync retries the durable event before reading the snapshot.
        let syncSucceeded = await WeTrakrProgressService.syncWatchedHistory(store: store)
        XCTAssertTrue(syncSucceeded)
        XCTAssertEqual(WatchedStore.pendingPlaybackCompletions(provider: .wetrakr, profileId: profileID).count, 0)

        let addRequests = WeTrakrFixtureURLProtocol.capturedRequests().filter {
            $0.httpMethod == "POST" && $0.url?.path == "/sync/tracking"
        }
        XCTAssertEqual(addRequests.count, 2)
        XCTAssertEqual(addRequests[0].httpBody, addRequests[1].httpBody)
        XCTAssertEqual(addRequests[0].value(forHTTPHeaderField: "Idempotency-Key"), completionID)
        XCTAssertEqual(addRequests[1].value(forHTTPHeaderField: "Idempotency-Key"), completionID)
        XCTAssertFalse(retryTrackedAt.isEmpty)
        let body = requestJSON(addRequests[1])
        XCTAssertEqual(body?["allow_rewatch"] as? Bool, true)
        let movie = (body?["movies"] as? [[String: Any]])?.first
        XCTAssertEqual(movie?["tracked_at"] as? String, retryTrackedAt)
        XCTAssertNil(movie?["watched_at"])

        let correctedCount = WatchedStore.items(profileId: profileID)
            .first(where: { WatchedStore.sameContent($0.meta, meta) })?
            .watchCountsBySource[TraktWatchProgressSource.wetrakr.rawValue]
        XCTAssertEqual(correctedCount, 1)
    }

    func testHistoryPaginationCountsUniquePlayIDsAndSkipsPartialReconcile() async throws {
        let profileID = prepareWeTrakrProfile()
        var partialMode = false
        let watchedAt = "2026-10-01T00:00:00.000Z"
        let makeMoviePlay: (Int) -> [String: Any] = { index in
            [
                "id": "movie-play-\(index)",
                "watched_at": watchedAt,
                "movie": [
                    "id": 10_000 + index,
                    "title": "Catalog Movie \(index)",
                    "year": 2020,
                    "ids": ["tmdb": 10_000 + index]
                ]
            ]
        }
        let makeEpisodePlay: (Int) -> [String: Any] = { index in
            [
                "id": "episode-play-\(index)",
                "watched_at": watchedAt,
                "episode": [
                    "id": 20_000 + index,
                    "season_number": 1,
                    "number": 1,
                    "show": [
                        "id": 7_777,
                        "title": "Long Series",
                        "year": 2021,
                        "ids": ["imdb": "tt07654321", "tmdb": 7_777]
                    ]
                ]
            ]
        }

        WeTrakrFixtureURLProtocol.install { request in
            let path = request.url?.path ?? ""
            let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            let page = Int(components?.queryItems?.first(where: { $0.name == "page" })?.value ?? "1") ?? 1
            let pageHeaders: (Int, Int, Int) -> [String: String] = { current, count, limit in
                [
                    "X-Pagination-Page": String(current),
                    "X-Pagination-Page-Count": String(count),
                    "X-Pagination-Limit": String(limit)
                ]
            }

            if path == "/sync/tracking/watched/history/movies" {
                if partialMode, page == 2 {
                    return (status: 500, headers: [:], body: Data("{\"error\":\"later page failed\"}".utf8))
                }
                if partialMode {
                    let rows = (0..<100).map(makeMoviePlay)
                    return (
                        status: 200,
                        headers: pageHeaders(1, 2, 100),
                        body: (try? JSONSerialization.data(withJSONObject: rows)) ?? Data()
                    )
                }
                let pageCount = 6
                let start = (page - 1) * 100
                let end = min(start + 100, 501)
                let rows = (start..<end).map(makeMoviePlay)
                return (
                    status: 200,
                    headers: pageHeaders(page, pageCount, 100),
                    body: (try? JSONSerialization.data(withJSONObject: rows)) ?? Data()
                )
            }

            if path == "/sync/tracking/watched/movies" {
                return (
                    status: 200,
                    headers: pageHeaders(page, 1, 100),
                    body: Data("[]".utf8)
                )
            }

            if path == "/sync/tracking/watched/history/episodes" {
                if partialMode {
                    return (
                        status: 200,
                        headers: pageHeaders(1, 1, 100),
                        body: Data("[]".utf8)
                    )
                }
                let indices: [Int]
                switch page {
                case 1:
                    indices = Array(0..<100)
                case 2:
                    indices = [99] + Array(100..<199)
                case 3...10:
                    let start = 199 + (page - 3) * 100
                    indices = Array(start..<(start + 100))
                case 11:
                    indices = [999, 1000]
                default:
                    indices = []
                }
                let rows = indices.map(makeEpisodePlay)
                return (
                    status: 200,
                    headers: pageHeaders(page, 11, 100),
                    body: (try? JSONSerialization.data(withJSONObject: rows)) ?? Data()
                )
            }
            return (status: 500, headers: [:], body: Data())
        }

        let firstSync = await WeTrakrProgressService.syncWatchedHistory(store: store)
        XCTAssertTrue(firstSync)
        let fullSnapshot = WatchedStore.items(profileId: profileID)
        let lastMovie = fullSnapshot.first(where: { $0.meta.tmdbId == 10_500 })
        XCTAssertEqual(lastMovie?.watchCountsBySource[TraktWatchProgressSource.wetrakr.rawValue], 1)
        let episode = fullSnapshot.first(where: {
            $0.meta.imdbId == "tt07654321" && $0.season == 1 && $0.episode == 1
        })
        XCTAssertEqual(episode?.watchCountsBySource[TraktWatchProgressSource.wetrakr.rawValue], 1_001)

        partialMode = true
        let partialSync = await WeTrakrProgressService.syncWatchedHistory(store: store)
        XCTAssertFalse(partialSync)
        let retained = WatchedStore.items(profileId: profileID)
        XCTAssertEqual(
            retained.first(where: { $0.meta.tmdbId == 10_500 })?
                .watchCountsBySource[TraktWatchProgressSource.wetrakr.rawValue],
            1
        )
        XCTAssertEqual(
            retained.first(where: { $0.meta.imdbId == "tt07654321" && $0.season == 1 && $0.episode == 1 })?
                .watchCountsBySource[TraktWatchProgressSource.wetrakr.rawValue],
            1_001
        )
    }

    func testPartialPlaybackReportsPauseWithoutHistoryCompletion() async throws {
        let profileID = prepareWeTrakrProfile()
        let playbackID = UUID().uuidString
        WeTrakrFixtureURLProtocol.install { _ in
            (status: 200, headers: [:], body: Data("{}".utf8))
        }

        let paused = await WeTrakrProgressService.reportPlayback(
            meta: completionMeta(),
            position: 40,
            duration: 100,
            season: nil,
            episode: nil,
            action: .pause,
            expectedAccountID: "account-1",
            playbackID: playbackID,
            profileId: profileID,
            store: store
        )
        XCTAssertTrue(paused)
        let requests = WeTrakrFixtureURLProtocol.capturedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/scrobble/pause"])
        XCTAssertFalse(requests.contains { $0.url?.path == "/scrobble/stop" })
        XCTAssertFalse(requests.contains { $0.url?.path == "/sync/tracking" })
    }

    func testSecondaryScrobbleReportsStartAndPauseWhenTraktIsPrimary() async throws {
        let profileID = prepareWeTrakrProfile()
        store.set(TraktWatchProgressSource.trakt.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        RemoteTrackingState.setScrobbleEnabled(true, for: .wetrakr, in: store)
        WeTrakrFixtureURLProtocol.install { _ in
            (status: 200, headers: [:], body: Data("{}".utf8))
        }

        let started = await WeTrakrProgressService.reportPlayback(
            meta: completionMeta(),
            position: 20,
            duration: 100,
            season: nil,
            episode: nil,
            action: .start,
            expectedAccountID: "account-1",
            profileId: profileID,
            store: store
        )
        let paused = await WeTrakrProgressService.reportPlayback(
            meta: completionMeta(),
            position: 40,
            duration: 100,
            season: nil,
            episode: nil,
            action: .pause,
            expectedAccountID: "account-1",
            profileId: profileID,
            store: store
        )

        XCTAssertTrue(started)
        XCTAssertTrue(paused)
        XCTAssertEqual(WeTrakrFixtureURLProtocol.capturedRequests().map { $0.url?.path }, [
            "/scrobble/start",
            "/scrobble/pause"
        ])
    }

    func testDisabledSecondaryScrobbleDoesNotReportWhenTraktIsPrimary() async throws {
        let profileID = prepareWeTrakrProfile()
        store.set(TraktWatchProgressSource.trakt.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        WeTrakrFixtureURLProtocol.install { _ in
            (status: 200, headers: [:], body: Data("{}".utf8))
        }

        let reported = await WeTrakrProgressService.reportPlayback(
            meta: completionMeta(),
            position: 20,
            duration: 100,
            season: nil,
            episode: nil,
            action: .start,
            expectedAccountID: "account-1",
            profileId: profileID,
            store: store
        )

        XCTAssertFalse(reported)
        XCTAssertTrue(WeTrakrFixtureURLProtocol.capturedRequests().isEmpty)
    }

    func testAccountSwitchDuringCompletionRequestLeavesOriginalEventQueued() async throws {
        let profileID = prepareWeTrakrProfile()
        let meta = completionMeta()
        let completionID = UUID().uuidString
        XCTAssertTrue(WatchedStore.recordPlaybackCompletion(
            meta,
            completionID: completionID,
            source: .wetrakr,
            completionAccounts: [TraktWatchProgressSource.wetrakr.rawValue: "account-1"]
        ))

        WeTrakrFixtureURLProtocol.install { request in
            let requestBody = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let movie = (requestBody["movies"] as? [[String: Any]])?.first ?? [:]
            let trackedAt = movie["tracked_at"] as? String ?? "2026-10-11T12:00:00.000Z"
            WeTrakrAuthStore.saveUser(
                username: "new-user",
                displayName: "New User",
                accountID: "account-2",
                accountPlan: "vip",
                avatarURL: nil,
                store: self.store
            )
            let response: [String: Any] = [
                "added": ["plays": [["type": "movie", "play_id": "server-play", "watched_at": trackedAt]]]
            ]
            return (
                status: 200,
                headers: [:],
                body: (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
            )
        }

        let flushed = await WeTrakrProgressService.flushPendingPlaybackCompletions(
            store: store,
            profileId: profileID
        )
        XCTAssertFalse(flushed)
        XCTAssertEqual(
            WeTrakrProgressService.completionAccountID(
                in: store,
                profileId: profileID,
                tokenStorage: memoryStorage
            ),
            "account-2"
        )
        let pending = WatchedStore.pendingPlaybackCompletions(provider: .wetrakr, profileId: profileID)
        XCTAssertEqual(pending.map(\.completionID), [completionID])
        XCTAssertEqual(pending.first?.accountID, "account-1")
        XCTAssertEqual(WeTrakrFixtureURLProtocol.capturedRequests().count, 1)
    }

    func testUnboundResetDoesNotBlockVerifiedCompletionUpload() async throws {
        let profileID = prepareWeTrakrProfile(accountID: nil)
        let show = NuvioMeta(id: "tt0903747", name: "Breaking Bad", type: "series", year: 2008)
        XCTAssertTrue(WatchedStore.setSeasonWatched(meta: show, season: 1, episodes: [1], isWatched: true))
        let unboundResets = WatchedStore.pendingProviderMutations(provider: .wetrakr, profileId: profileID)
        XCTAssertEqual(unboundResets.count, 1)
        XCTAssertNil(unboundResets.first?.accountID)

        WeTrakrAuthStore.saveUser(
            username: "test-user",
            displayName: "Test User",
            accountID: "account-1",
            accountPlan: "vip",
            avatarURL: nil,
            store: store
        )
        let completionID = UUID().uuidString
        let meta = completionMeta()
        XCTAssertTrue(WatchedStore.recordPlaybackCompletion(
            meta,
            completionID: completionID,
            source: .wetrakr,
            completionAccounts: [TraktWatchProgressSource.wetrakr.rawValue: "account-1"]
        ))

        WeTrakrFixtureURLProtocol.install { request in
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let movie = (body["movies"] as? [[String: Any]])?.first ?? [:]
            let trackedAt = movie["tracked_at"] as? String ?? "2026-10-11T12:00:00.000Z"
            let response: [String: Any] = [
                "added": ["plays": [["type": "movie", "play_id": "server-play", "watched_at": trackedAt]]]
            ]
            return (
                status: 200,
                headers: [:],
                body: (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
            )
        }

        let flushed = await WeTrakrProgressService.flushPendingPlaybackCompletions(
            store: store,
            profileId: profileID
        )
        XCTAssertTrue(flushed)
        let requests = WeTrakrFixtureURLProtocol.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/sync/tracking")
        let uploaded = requestJSON(requests[0])
        XCTAssertEqual(uploaded?["allow_rewatch"] as? Bool, true)
        XCTAssertNotNil((uploaded?["movies"] as? [[String: Any]])?.first)
        XCTAssertNil(uploaded?["shows"])
        XCTAssertEqual(WatchedStore.pendingProviderMutations(provider: .wetrakr, profileId: profileID).count, 1)
        XCTAssertTrue(WatchedStore.pendingPlaybackCompletions(provider: .wetrakr, profileId: profileID).isEmpty)
    }
}

