import Foundation
import XCTest
@testable import NuvioTV

private final class JellyfinMockURLProtocol: URLProtocol {
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

final class JellyfinClientTests: XCTestCase {
    private var session: URLSession!
    private let baseURL = URL(string: "http://192.168.1.100:8096")!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JellyfinMockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        JellyfinMockURLProtocol.requestHandler = nil
        session = nil
        super.tearDown()
    }

    // MARK: - Authentication & Headers

    func testAuthenticateUsesStandardAuthorizationHeader() async throws {
        var capturedRequest: URLRequest?

        JellyfinMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {
                "User": { "Id": "user-abc-123" },
                "AccessToken": "token-xyz-789"
            }
            """
            return (response, Data(json.utf8))
        }

        let result = try await JellyfinClient.authenticate(
            baseURL: baseURL,
            username: "admin",
            password: "password123",
            session: session
        )

        XCTAssertEqual(result.userId, "user-abc-123")
        XCTAssertEqual(result.accessToken, "token-xyz-789")

        let req = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(req.url?.path, "/Users/AuthenticateByName")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let authHeader = try XCTUnwrap(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authHeader.starts(with: "MediaBrowser "))
        XCTAssertTrue(authHeader.contains("Client=\"Nuvio\""))
        XCTAssertTrue(authHeader.contains("Device=\"Apple TV\""))
        XCTAssertTrue(authHeader.contains("DeviceId=\"NuvioTV-AppleTV\""))
        XCTAssertNil(req.value(forHTTPHeaderField: "X-Emby-Authorization"))
    }

    func testCurrentUserIdUsesUsersMeWhenSupported() async throws {
        var capturedRequest: URLRequest?

        JellyfinMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = """
            {
                "Id": "emby-user-456"
            }
            """
            return (response, Data(json.utf8))
        }

        let userId = try await JellyfinClient.currentUserId(
            baseURL: baseURL,
            apiKey: "my-api-key",
            session: session
        )

        XCTAssertEqual(userId, "emby-user-456")

        let req = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(req.url?.path, "/Users/Me")
        let authHeader = try XCTUnwrap(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authHeader.contains("Token=\"my-api-key\""))
        XCTAssertNil(req.value(forHTTPHeaderField: "X-Emby-Token"))
    }

    func testCurrentUserIdFallsBackToUsersWhenMeReturns400() async throws {
        var requestedPaths: [String] = []

        JellyfinMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            requestedPaths.append(path)

            if path == "/Users/Me" {
                // Jellyfin 10.9/12 returns 400 for API keys on /Users/Me
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (response, Data("Cannot authenticate user with an API key".utf8))
            } else if path == "/Users" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                [
                    {
                        "Id": "regular-user-id",
                        "Name": "RegularUser",
                        "Policy": { "IsAdministrator": false }
                    },
                    {
                        "Id": "admin-user-id",
                        "Name": "AdminUser",
                        "Policy": { "IsAdministrator": true }
                    }
                ]
                """
                return (response, Data(json.utf8))
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
        }

        let userId = try await JellyfinClient.currentUserId(
            baseURL: baseURL,
            apiKey: "jellyfin-admin-key",
            session: session
        )

        // Should prefer admin user
        XCTAssertEqual(userId, "admin-user-id")
        XCTAssertEqual(requestedPaths, ["/Users/Me", "/Users"])
    }

    func testCurrentUserIdMatchesSpecifiedUsernameOnFallback() async throws {
        JellyfinMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            if path == "/Users/Me" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!
                return (response, Data("Bad Request".utf8))
            } else if path == "/Users" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let json = """
                [
                    {
                        "Id": "admin-id",
                        "Name": "Admin",
                        "Policy": { "IsAdministrator": true }
                    },
                    {
                        "Id": "target-user-id",
                        "Name": "TargetUser",
                        "Policy": { "IsAdministrator": false }
                    }
                ]
                """
                return (response, Data(json.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let userId = try await JellyfinClient.currentUserId(
            baseURL: baseURL,
            apiKey: "some-key",
            username: "targetuser",
            session: session
        )

        XCTAssertEqual(userId, "target-user-id")
    }

    func testCurrentUserIdThrowsUnauthorizedOn401() async {
        JellyfinMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        do {
            _ = try await JellyfinClient.currentUserId(baseURL: self.baseURL, apiKey: "invalid-key", session: self.session)
            XCTFail("Expected unauthorized error to be thrown")
        } catch let error as JellyfinClient.ClientError {
            XCTAssertEqual(error.message, L10n.string("jellyfin_error_unauthorized", fallback: "Invalid API key or credentials"))
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testPingSendsStandardAuthorizationHeader() async throws {
        var capturedRequest: URLRequest?

        JellyfinMockURLProtocol.requestHandler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"ServerName":"Jellyfin"}"#.utf8))
        }

        let client = JellyfinClient(baseURL: baseURL, accessToken: "test-token-123", session: session)
        try await client.ping()

        let req = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(req.url?.path, "/System/Info")
        let authHeader = try XCTUnwrap(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(authHeader.contains("Token=\"test-token-123\""))
        XCTAssertNil(req.value(forHTTPHeaderField: "X-Emby-Token"))
    }

    func testLibrariesAndItemsParsing() async throws {
        JellyfinMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!

            if path == "/Users/user-1/Views" {
                let json = """
                {
                    "Items": [
                        { "Id": "lib-1", "Name": "Movies", "CollectionType": "movies" },
                        { "Id": "lib-2", "Name": "TV Shows", "CollectionType": "tvshows" }
                    ]
                }
                """
                return (response, Data(json.utf8))
            } else if path == "/Users/user-1/Items" {
                let startIndex = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
                    .first(where: { $0.name == "StartIndex" })?.value ?? "0"
                guard startIndex == "0" else {
                    return (response, Data(#"{"Items":[]}"#.utf8))
                }
                let json = """
                {
                    "Items": [
                        {
                            "Id": "movie-1",
                            "Name": "Sample Movie",
                            "Type": "Movie",
                            "Overview": "Movie overview",
                            "ProductionYear": 2024,
                            "CommunityRating": 8.5
                        }
                    ]
                }
                """
                return (response, Data(json.utf8))
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = JellyfinClient(baseURL: baseURL, accessToken: "test-token", session: session)
        let libraries = try await client.libraries(userId: "user-1")
        XCTAssertEqual(libraries.count, 2)
        XCTAssertEqual(libraries[0].name, "Movies")
        XCTAssertEqual(libraries[1].name, "TV Shows")

        let items = try await client.items(userId: "user-1", libraryId: "lib-1")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Sample Movie")
        XCTAssertEqual(items[0].type, "Movie")
        XCTAssertEqual(items[0].productionYear, 2024)
        XCTAssertEqual(items[0].communityRating, 8.5)
    }

    func testItemsPaginatesWhenTotalRecordCountExceedsPageSize() async throws {
        var requestedStartIndices: [String] = []

        JellyfinMockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                return (HTTPURLResponse(url: URL(string: "http://error")!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let startIndex = components?.queryItems?.first(where: { $0.name == "StartIndex" })?.value ?? "0"
            requestedStartIndices.append(startIndex)

            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!

            if startIndex == "0" {
                // First page returns 24 items with TotalRecordCount: 50 (matching Silo server behavior)
                var itemsJson = ""
                for i in 0..<24 {
                    itemsJson += """
                    {
                        "Id": "item-\(i)",
                        "Name": "Movie \(i)",
                        "Type": "Movie",
                        "ProductionYear": \(2020 + i)
                    }\(i < 23 ? "," : "")
                    """
                }
                let json = """
                {
                    "Items": [\(itemsJson)],
                    "TotalRecordCount": 50,
                    "StartIndex": 0
                }
                """
                return (response, Data(json.utf8))
            } else if startIndex == "24" {
                // Second page returns next 24 items
                var itemsJson = ""
                for i in 24..<48 {
                    itemsJson += """
                    {
                        "Id": "item-\(i)",
                        "Name": "Movie \(i)",
                        "Type": "Movie",
                        "ProductionYear": \(2020 + i)
                    }\(i < 47 ? "," : "")
                    """
                }
                let json = """
                {
                    "Items": [\(itemsJson)],
                    "TotalRecordCount": 50,
                    "StartIndex": 24
                }
                """
                return (response, Data(json.utf8))
            } else if startIndex == "48" {
                // Third page returns final 2 items
                let json = """
                {
                    "Items": [
                        { "Id": "item-48", "Name": "Movie 48", "Type": "Movie" },
                        { "Id": "item-49", "Name": "Movie 49", "Type": "Movie" }
                    ],
                    "TotalRecordCount": 50,
                    "StartIndex": 48
                }
                """
                return (response, Data(json.utf8))
            }

            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = JellyfinClient(baseURL: baseURL, accessToken: "test-token", session: session)
        var progressUpdates: [Int] = []
        let items = try await client.items(userId: "user-1", libraryId: "lib-movies") { countSoFar in
            progressUpdates.append(countSoFar)
        }

        XCTAssertEqual(items.count, 50, "All 50 items should be paginated and imported")
        XCTAssertEqual(requestedStartIndices, ["0", "24", "48"])
        XCTAssertEqual(progressUpdates, [24, 48, 50])
        XCTAssertEqual(items.first?.id, "item-0")
        XCTAssertEqual(items.last?.id, "item-49")
    }

    func testBareArrayPaginationContinuesUntilAnEmptyPage() async throws {
        var requestedStartIndices: [String] = []
        JellyfinMockURLProtocol.requestHandler = { request in
            let url = request.url!
            let startIndex = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "StartIndex" })?.value ?? "0"
            requestedStartIndices.append(startIndex)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let start = Int(startIndex) ?? 0
            let items = (start..<min(start + 24, 50)).map { index in
                ["Id": "movie-\(index)", "Name": "Movie \(index)", "Type": "Movie"]
            }
            return (response, try JSONSerialization.data(withJSONObject: items))
        }

        let client = JellyfinClient(baseURL: baseURL, accessToken: "test-token", session: session)
        let items = try await client.items(userId: "user-1", libraryId: "lib-1")

        XCTAssertEqual(items.count, 50)
        XCTAssertEqual(requestedStartIndices, ["0", "24", "48", "50"], "Short bare-array pages may be server-capped")
    }

    func testItemsRejectMalformedItemsArray() async throws {
        JellyfinMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"Items":"not-an-array"}"#.utf8))
        }

        let client = JellyfinClient(baseURL: baseURL, accessToken: "test-token", session: session)
        do {
            _ = try await client.items(userId: "user-1", libraryId: "lib-1")
            XCTFail("Malformed Items must fail instead of looking like an empty library")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testItemsRejectRepeatedPageWithoutForwardProgress() async throws {
        var requestedStartIndices: [String] = []
        JellyfinMockURLProtocol.requestHandler = { request in
            let url = request.url!
            let startIndex = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "StartIndex" })?.value ?? "0"
            requestedStartIndices.append(startIndex)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"Items":[{"Id":"same","Name":"Same","Type":"Movie"}]}"#.utf8))
        }

        let client = JellyfinClient(baseURL: baseURL, accessToken: "test-token", session: session)
        do {
            _ = try await client.items(userId: "user-1", libraryId: "lib-1")
            XCTFail("A repeated page should stop the pagination loop")
        } catch let error as JellyfinClient.ClientError {
            XCTAssertTrue(error.message.contains("repeated"))
        }
        XCTAssertEqual(requestedStartIndices, ["0", "1"])
    }

    func testEpisodesFetchesAndPaginatesShowsEpisodes() async throws {
        var requestedPath: String?
        var capturedUserId: String?

        JellyfinMockURLProtocol.requestHandler = { request in
            guard let url = request.url else {
                return (HTTPURLResponse(url: URL(string: "http://error")!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            requestedPath = url.path
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            capturedUserId = components?.queryItems?.first(where: { $0.name == "userId" })?.value

            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            // Notice: Silo/Jellyfin shows episode response might omit SeriesId because it's in the path
            let json = """
            {
                "Items": [
                    {
                        "Id": "ep-1",
                        "Name": "Pilot",
                        "Type": "Episode",
                        "IndexNumber": 1,
                        "ParentIndexNumber": 1,
                        "MediaSources": [{ "Container": "mkv", "Size": 1048576 }]
                    },
                    {
                        "Id": "ep-2",
                        "Name": "Episode 2",
                        "Type": "Episode",
                        "IndexNumber": 2,
                        "ParentIndexNumber": 1,
                        "MediaSources": [{ "Container": "mkv", "Size": 1048576 }]
                    }
                ],
                "TotalRecordCount": 2,
                "StartIndex": 0
            }
            """
            return (response, Data(json.utf8))
        }

        let client = JellyfinClient(baseURL: baseURL, accessToken: "test-token", session: session)
        let episodes = try await client.episodes(seriesId: "series-abc", userId: "user-1")

        XCTAssertEqual(episodes.count, 2)
        XCTAssertEqual(requestedPath, "/Shows/series-abc/Episodes")
        XCTAssertEqual(capturedUserId, "user-1")
        XCTAssertEqual(episodes[0].id, "ep-1")
        XCTAssertEqual(episodes[0].seriesId, "series-abc", "Should fall back to seriesId parameter when omitted in payload")
        XCTAssertEqual(episodes[0].indexNumber, 1)
        XCTAssertEqual(episodes[0].parentIndexNumber, 1)
        XCTAssertEqual(episodes[1].id, "ep-2")
        XCTAssertEqual(episodes[1].seriesId, "series-abc")
    }
}
