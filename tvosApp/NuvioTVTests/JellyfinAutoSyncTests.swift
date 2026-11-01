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
}
