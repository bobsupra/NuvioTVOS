import Foundation
import XCTest
@testable import NuvioTV

private final class JellyfinAutoSyncMockProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
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

@MainActor
final class JellyfinAutoSyncTests: XCTestCase {
    private var session: URLSession!
    private let baseURL = URL(string: "http://127.0.0.1:8096")!
    private var testProfileID = ""
    private var previousProfileID: String?
    private var previousProfileIsPrimary = false

    override func setUp() {
        super.setUp()
        previousProfileID = ProfileSettings.activeProfileID
        previousProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        testProfileID = "jellyfin-test-\(UUID().uuidString)"
        ProfileSettings.setActiveProfile(testProfileID, isPrimary: false)
        JellyfinServerStore.shared.reload()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JellyfinAutoSyncMockProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        JellyfinAutoSyncMockProtocol.requestHandler = nil
        session = nil
        for server in JellyfinServerStore.shared.servers {
            JellyfinSessionManager.shared.cancelSync(forServerID: server.id)
            JellyfinServerStore.shared.remove(server.id)
        }
        if let previousProfileID {
            ProfileSettings.setActiveProfile(previousProfileID, isPrimary: previousProfileIsPrimary)
        } else {
            ProfileSettings.clearActiveProfile()
        }
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(testProfileID)")
        super.tearDown()
    }

    func testConfigDecodingBackwardCompatibility() throws {
        let legacyJSON = """
        {
            "id": "srv-1",
            "displayName": "Home Server",
            "baseURLString": "http://192.168.1.50:8096",
            "authKind": "apiKey",
            "username": "",
            "userId": "user-123",
            "selectedLibraryIDs": ["lib-movies"]
        }
        """

        let decoded = try JSONDecoder().decode(JellyfinServerConfig.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.id, "srv-1")
        XCTAssertEqual(decoded.displayName, "Home Server")
        XCTAssertEqual(decoded.selectedLibraryIDs, ["lib-movies"])
        XCTAssertTrue(decoded.syncAutomatically, "Old configs missing syncAutomatically must default to true")
    }

    func testConfigDecodingExplicitFalse() throws {
        let json = """
        {
            "id": "srv-2",
            "displayName": "Large Server",
            "baseURLString": "http://192.168.1.50:8096",
            "authKind": "apiKey",
            "username": "",
            "userId": "user-123",
            "selectedLibraryIDs": ["lib-movies"],
            "syncAutomatically": false
        }
        """

        let decoded = try JSONDecoder().decode(JellyfinServerConfig.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.syncAutomatically)
    }

    func testConfigEncodingRoundTrip() throws {
        let config = JellyfinServerConfig(
            id: "srv-3",
            displayName: "Test",
            baseURLString: "http://192.168.1.50:8096",
            selectedLibraryIDs: ["lib-1"],
            syncAutomatically: false
        )

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(JellyfinServerConfig.self, from: data)
        XCTAssertEqual(decoded.id, "srv-3")
        XCTAssertFalse(decoded.syncAutomatically)
    }

    func testAutoSyncSkipsWhenSyncAutomaticallyIsFalse() {
        let server = JellyfinServerConfig(
            id: "server-manual",
            displayName: "Manual Server",
            baseURLString: baseURL.absoluteString,
            userId: "user-1",
            selectedLibraryIDs: ["lib-1"],
            syncAutomatically: false
        )
        JellyfinServerStore.shared.upsert(server)

        let client = JellyfinClient(baseURL: baseURL, accessToken: "token-1", session: session)
        JellyfinSessionManager.shared.setClientForTesting(client, forServerID: server.id)
        JellyfinSessionManager.shared.setConnectionStateForTesting(.connected(libraries: [JellyfinLibrary(id: "lib-1", name: "Movies", collectionType: "movies")]), forServerID: server.id)

        JellyfinSessionManager.shared.autoSyncConnectedServers()

        XCTAssertEqual(JellyfinSessionManager.shared.syncState(for: server.id), .idle)
    }

    func testAutoSyncSkipsWhenNoLibrariesSelected() {
        let server = JellyfinServerConfig(
            id: "server-empty",
            displayName: "Empty Server",
            baseURLString: baseURL.absoluteString,
            userId: "user-1",
            selectedLibraryIDs: [],
            syncAutomatically: true
        )
        JellyfinServerStore.shared.upsert(server)

        let client = JellyfinClient(baseURL: baseURL, accessToken: "token-1", session: session)
        JellyfinSessionManager.shared.setClientForTesting(client, forServerID: server.id)
        JellyfinSessionManager.shared.setConnectionStateForTesting(.connected(libraries: []), forServerID: server.id)

        JellyfinSessionManager.shared.autoSyncConnectedServers()

        XCTAssertEqual(JellyfinSessionManager.shared.syncState(for: server.id), .idle)
    }

    func testAutoSyncSkipsWhenDisconnected() {
        let server = JellyfinServerConfig(
            id: "server-disconnected",
            displayName: "Disconnected Server",
            baseURLString: baseURL.absoluteString,
            userId: "user-1",
            selectedLibraryIDs: ["lib-1"],
            syncAutomatically: true
        )
        JellyfinServerStore.shared.upsert(server)

        JellyfinSessionManager.shared.setConnectionStateForTesting(.disconnected, forServerID: server.id)

        JellyfinSessionManager.shared.autoSyncConnectedServers()

        XCTAssertEqual(JellyfinSessionManager.shared.syncState(for: server.id), .idle)
    }

    func testAutoSyncSkipsWhenLastSyncDateIsRecent() {
        let recentSyncDate = Date().addingTimeInterval(-100) // 100 seconds ago
        let server = JellyfinServerConfig(
            id: "server-recent",
            displayName: "Recent Server",
            baseURLString: baseURL.absoluteString,
            userId: "user-1",
            selectedLibraryIDs: ["lib-1"],
            lastSyncDate: recentSyncDate,
            syncAutomatically: true
        )
        JellyfinServerStore.shared.upsert(server)

        let client = JellyfinClient(baseURL: baseURL, accessToken: "token-1", session: session)
        JellyfinSessionManager.shared.setClientForTesting(client, forServerID: server.id)
        JellyfinSessionManager.shared.setConnectionStateForTesting(.connected(libraries: [JellyfinLibrary(id: "lib-1", name: "Movies", collectionType: "movies")]), forServerID: server.id)

        // Minimum interval of 6 hours (21600 seconds)
        JellyfinSessionManager.shared.autoSyncConnectedServers(minimumInterval: 6 * 3600)

        XCTAssertEqual(JellyfinSessionManager.shared.syncState(for: server.id), .idle)
    }

    func testAutoSyncRunsWhenLastSyncDateIsOlderThanInterval() {
        let oldSyncDate = Date().addingTimeInterval(-7 * 3600) // 7 hours ago
        let server = JellyfinServerConfig(
            id: "server-old",
            displayName: "Old Server",
            baseURLString: baseURL.absoluteString,
            userId: "user-1",
            selectedLibraryIDs: ["lib-1"],
            lastSyncDate: oldSyncDate,
            syncAutomatically: true
        )
        JellyfinServerStore.shared.upsert(server)

        JellyfinAutoSyncMockProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"Items":[]}"#
            return (response, Data(json.utf8))
        }

        let client = JellyfinClient(baseURL: baseURL, accessToken: "token-1", session: session)
        JellyfinSessionManager.shared.setClientForTesting(client, forServerID: server.id)
        JellyfinSessionManager.shared.setConnectionStateForTesting(.connected(libraries: [JellyfinLibrary(id: "lib-1", name: "Movies", collectionType: "movies")]), forServerID: server.id)

        // Minimum interval of 6 hours
        JellyfinSessionManager.shared.autoSyncConnectedServers(minimumInterval: 6 * 3600)

        // Sync should have transitioned to syncing
        if case .syncing = JellyfinSessionManager.shared.syncState(for: server.id) {
            // Expected
        } else if case .done = JellyfinSessionManager.shared.syncState(for: server.id) {
            // Also fine if synchronous mock completed
        } else {
            XCTFail("Expected syncing or done state, got \(JellyfinSessionManager.shared.syncState(for: server.id))")
        }
    }

    func testSyncFetchesEpisodesSeparatelyWhenLibraryOmittedThemAndCalculatesMatchedEpisodes() async throws {
        let serverID = "silo-\(UUID().uuidString)"
        let server = JellyfinServerConfig(
            id: serverID,
            displayName: "Silo Server",
            baseURLString: baseURL.absoluteString,
            authKind: .apiKey,
            userId: "user-silo",
            selectedLibraryIDs: ["lib-silo"],
            syncAutomatically: false
        )
        JellyfinServerStore.shared.upsert(server)

        var requestedShowsEpisodesPath: String?

        JellyfinAutoSyncMockProtocol.requestHandler = { request in
            guard let url = request.url else {
                return (HTTPURLResponse(url: URL(string: "http://error")!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            let path = url.path
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!

            if path == "/Users/user-silo/Items" {
                // Returns 1 Movie and 1 Series, but NO episodes (typical Silo TV library behavior)
                let json = """
                {
                    "Items": [
                        {
                            "Id": "movie-blade-runner",
                            "Name": "Blade Runner 2049",
                            "Type": "Movie",
                            "ProductionYear": 2017,
                            "ProviderIds": { "Imdb": "tt1856101" },
                            "MediaSources": [{ "Container": "mkv", "Size": 5000000000 }]
                        },
                        {
                            "Id": "series-breaking-bad",
                            "Name": "Breaking Bad",
                            "Type": "Series",
                            "ProductionYear": 2008,
                            "ProviderIds": { "Imdb": "tt0903747" }
                        }
                    ],
                    "TotalRecordCount": 2,
                    "StartIndex": 0
                }
                """
                return (response, Data(json.utf8))
            } else if path == "/Shows/series-breaking-bad/Episodes" {
                requestedShowsEpisodesPath = path
                let json = """
                {
                    "Items": [
                        {
                            "Id": "ep-bb-s1e1",
                            "Name": "Pilot",
                            "Type": "Episode",
                            "ParentIndexNumber": 1,
                            "IndexNumber": 1,
                            "MediaSources": [{ "Container": "mp4", "Size": 1000000000 }]
                        },
                        {
                            "Id": "ep-bb-s1e2",
                            "Name": "Cat's in the Bag...",
                            "Type": "Episode",
                            "ParentIndexNumber": 1,
                            "IndexNumber": 2,
                            "MediaSources": [{ "Container": "mp4", "Size": 1100000000 }]
                        }
                    ],
                    "TotalRecordCount": 2,
                    "StartIndex": 0
                }
                """
                return (response, Data(json.utf8))
            }

            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = JellyfinClient(baseURL: baseURL, accessToken: "token-silo", session: session)
        JellyfinSessionManager.shared.setClientForTesting(client, forServerID: serverID)
        JellyfinSessionManager.shared.setConnectionStateForTesting(
            .connected(libraries: [JellyfinLibrary(id: "lib-silo", name: "Silo Library", collectionType: "tvshows")]),
            forServerID: serverID
        )

        JellyfinSessionManager.shared.sync(server)

        // Wait for sync to complete
        var report: JellyfinSyncReport?
        for _ in 0..<40 {
            if case .done(let r) = JellyfinSessionManager.shared.syncState(for: serverID) {
                report = r
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let finalReport = try XCTUnwrap(report, "Sync should finish with .done state")
        XCTAssertEqual(requestedShowsEpisodesPath, "/Shows/series-breaking-bad/Episodes", "Should fetch episodes for series lacking them")
        XCTAssertEqual(finalReport.matchedTitles, 2, "Should index both movie and series")
        XCTAssertEqual(finalReport.matchedEpisodes, 2, "Matched episodes should only count series episodes (2), not movie files")
        XCTAssertTrue(finalReport.unmatched.isEmpty)

        // Check index
        let titles = JellyfinLibraryIndex.shared.titles().filter { $0.serverID == serverID }
        XCTAssertEqual(titles.count, 2)

        let movie = titles.first(where: { $0.type == "movie" })
        XCTAssertNotNil(movie)
        XCTAssertEqual(movie?.name, "Blade Runner 2049")
        XCTAssertEqual(movie?.items.count, 1)

        let series = titles.first(where: { $0.type == "series" })
        XCTAssertNotNil(series)
        XCTAssertEqual(series?.name, "Breaking Bad")
        XCTAssertEqual(series?.items.count, 2, "Series must retain both fetched episodes")
        XCTAssertEqual(series?.items.first?.episodeName, "Pilot")
    }

    func testSyncResumesSavedPagesAfterFailureAndKeepsPreviousIndexUntilCommit() async throws {
        let serverID = "resume-\(UUID().uuidString)"
        let server = JellyfinServerConfig(
            id: serverID,
            displayName: "Resume Server",
            baseURLString: baseURL.absoluteString,
            userId: "user-resume",
            selectedLibraryIDs: ["lib-resume"],
            syncAutomatically: false
        )
        JellyfinServerStore.shared.upsert(server)
        let oldTitles = JellyfinLibraryResolver.resolve(
            [movieItem(id: "old-movie", name: "Old Index")],
            serverID: serverID,
            libraryID: "lib-resume",
            libraryName: "Movies"
        ).titles
        try JellyfinLibraryIndex.shared.replace(titles: oldTitles, forServerID: serverID)

        var requestedStartIndices: [String] = []
        var failSecondPageOnce = true
        JellyfinAutoSyncMockProtocol.requestHandler = { request in
            let url = request.url!
            let startIndex = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "StartIndex" })?.value ?? "0"
            requestedStartIndices.append(startIndex)
            if startIndex == "1", failSecondPageOnce {
                failSecondPageOnce = false
                return (HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data("temporary failure".utf8))
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = startIndex == "0"
                ? #"{"Items":[{"Id":"new-1","Name":"New One","Type":"Movie"}],"TotalRecordCount":2}"#
                : #"{"Items":[{"Id":"new-2","Name":"New Two","Type":"Movie"}],"TotalRecordCount":2}"#
            return (response, Data(body.utf8))
        }

        let client = JellyfinClient(baseURL: baseURL, accessToken: "token-resume", session: session)
        JellyfinSessionManager.shared.setClientForTesting(client, forServerID: serverID)
        JellyfinSessionManager.shared.setConnectionStateForTesting(
            .connected(libraries: [JellyfinLibrary(id: "lib-resume", name: "Movies", collectionType: "movies")]),
            forServerID: serverID
        )

        JellyfinSessionManager.shared.sync(server)
        for _ in 0..<100 {
            if case .failed = JellyfinSessionManager.shared.syncState(for: serverID) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .failed = JellyfinSessionManager.shared.syncState(for: serverID) else {
            XCTFail("First sync should fail at its second page")
            return
        }
        XCTAssertEqual(JellyfinLibraryIndex.shared.titles().filter { $0.serverID == serverID }.map(\.name), ["Old Index"])

        JellyfinSessionManager.shared.sync(server)
        var completed = false
        for _ in 0..<100 {
            if case .done = JellyfinSessionManager.shared.syncState(for: serverID) {
                completed = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(completed, "Second sync should resume and commit")
        XCTAssertEqual(requestedStartIndices, ["0", "1", "1"], "The saved first page should not be fetched again")
        XCTAssertEqual(
            Set(JellyfinLibraryIndex.shared.titles().filter { $0.serverID == serverID }.map(\.name)),
            Set(["New One", "New Two"])
        )
    }

    private func movieItem(id: String, name: String) -> JellyfinMediaItem {
        JellyfinMediaItem(
            id: id,
            name: name,
            type: "Movie",
            overview: nil,
            productionYear: nil,
            premiereDate: nil,
            communityRating: nil,
            officialRating: nil,
            genres: nil,
            runTimeTicks: nil,
            imdbId: nil,
            tmdbId: nil,
            primaryImageTag: nil,
            backdropImageTag: nil,
            cast: nil,
            directors: nil,
            seriesId: nil,
            parentIndexNumber: nil,
            indexNumber: nil,
            container: nil,
            sizeBytes: nil
        )
    }
}
