import Foundation
import XCTest
@testable import NuvioTV

private final class PlexMockURLProtocol: URLProtocol {
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

final class PlexClientTests: XCTestCase {
    private var session: URLSession!
    private let baseURL = URL(string: "http://192.168.1.10:32400")!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlexMockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        PlexMockURLProtocol.requestHandler = nil
        session = nil
        super.tearDown()
    }

    private func respond(_ request: URLRequest, json: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    // MARK: - Connection selection

    func testLocalPlexDirectAddressIsFollowedByPlainHTTPOnTheLANIP() {
        let resource = PlexResource(
            name: "Mac",
            clientIdentifier: "abc",
            accessToken: "t",
            isOwned: true,
            connections: [
                .init(uri: "https://1-2-3-4.x.plex.direct:5000", address: "1.2.3.4", port: 5000, protocolName: "https", isLocal: false, isRelay: true),
                .init(uri: "https://79-1-1-1.x.plex.direct:32400", address: "79.1.1.1", port: 32400, protocolName: "https", isLocal: false, isRelay: false),
                .init(uri: "https://192-168-1-10.x.plex.direct:32400", address: "192.168.1.10", port: 32400, protocolName: "https", isLocal: true, isRelay: false)
            ]
        )
        XCTAssertEqual(PlexClient.candidateBaseURLs(for: resource).map(\.absoluteString), [
            "https://192-168-1-10.x.plex.direct:32400",
            "http://192.168.1.10:32400",
            "https://79-1-1-1.x.plex.direct:32400",
            "https://1-2-3-4.x.plex.direct:5000"
        ])
    }

    func testIdentityMustMatchTheMachineIdentifier() async {
        PlexMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/identity")
            return self.respond(request, json: #"{"MediaContainer":{"machineIdentifier":"other"}}"#)
        }
        let matches = await PlexClient.isServer(baseURL, machineIdentifier: "abc", session: session)
        XCTAssertFalse(matches)
    }

    // MARK: - Library listing

    func testItemsPagesUntilTotalSizeAndReadsGuidsAndParts() async throws {
        var starts: [String] = []
        PlexMockURLProtocol.requestHandler = { request in
            let q = self.query(request)
            XCTAssertEqual(request.url?.path, "/library/sections/4/all")
            XCTAssertEqual(q["type"], "4")
            XCTAssertEqual(q["includeGuids"], "1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plex-Token"), "token")
            starts.append(q["X-Plex-Container-Start"] ?? "")
            let start = Int(q["X-Plex-Container-Start"] ?? "0") ?? 0
            let ratingKey = start == 0 ? "101" : "102"
            return self.respond(request, json: """
            {"MediaContainer":{"totalSize":2,"Metadata":[{
              "ratingKey":"\(ratingKey)","type":"episode","title":"Pilot","grandparentRatingKey":"50",
              "parentIndex":1,"index":\(start + 1),"duration":3600000,
              "Guid":[{"id":"imdb://tt0000001"},{"id":"tmdb://42"}],
              "Media":[{"container":"mkv","Part":[{"key":"/library/parts/9/1/file.mkv","size":1234}]}]
            }]}}
            """)
        }
        let client = PlexClient(baseURL: baseURL, token: "token", session: session)
        let items = try await client.items(libraryID: "4", type: .episode)
        XCTAssertEqual(starts, ["0", "1"])
        XCTAssertEqual(items.map(\.ratingKey), ["101", "102"])
        XCTAssertEqual(items.first?.imdbId, "tt0000001")
        XCTAssertEqual(items.first?.tmdbId, 42)
        XCTAssertEqual(items.first?.showRatingKey, "50")
        XCTAssertEqual(items.first?.partKey, "/library/parts/9/1/file.mkv")
        XCTAssertEqual(items.last?.episodeNumber, 2)
    }

    func testTimelineReportsMillisecondsAndState() async throws {
        PlexMockURLProtocol.requestHandler = { request in
            let q = self.query(request)
            XCTAssertEqual(request.url?.path, "/:/timeline")
            XCTAssertEqual(q["ratingKey"], "101")
            XCTAssertEqual(q["key"], "/library/metadata/101")
            XCTAssertEqual(q["state"], "paused")
            XCTAssertEqual(q["time"], "61500")
            XCTAssertEqual(q["duration"], "3600000")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-Plex-Client-Identifier"))
            return self.respond(request, json: "{}")
        }
        let client = PlexClient(baseURL: baseURL, token: "token", session: session)
        try await client.reportTimeline(ratingKey: "101", state: .paused, timeMs: 61_500, durationMs: 3_600_000)
    }

    func testStreamURLKeepsThePartPathAndCarriesNoToken() {
        let url = PlexClient.streamURL(baseURL: baseURL, partKey: "/library/parts/9/1/file.mkv")
        XCTAssertEqual(url?.absoluteString, "http://192.168.1.10:32400/library/parts/9/1/file.mkv")
    }

    func testViewedSinceUsesPlexFilterAndReadsWatchState() async throws {
        PlexMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(self.query(request)["lastViewedAt>"], "1700000000")
            return self.respond(request, json: """
            {"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"7","type":"episode","title":"x",
              "viewOffset":150068,"viewCount":2,"lastViewedAt":1700000500}]}}
            """)
        }
        let client = PlexClient(baseURL: baseURL, token: "token", session: session)
        let items = try await client.items(libraryID: "4", type: .episode, viewedSince: 1_700_000_000)
        XCTAssertEqual(PlexWatchState(items[0]), PlexWatchState(viewOffsetMs: 150_068, viewCount: 2, lastViewedAt: 1_700_000_500))
    }

    func testSetWatchedScrobblesAndUnscrobbles() async throws {
        var paths: [String] = []
        PlexMockURLProtocol.requestHandler = { request in
            paths.append(request.url!.path)
            XCTAssertEqual(self.query(request)["key"], "7")
            return self.respond(request, json: "{}")
        }
        let client = PlexClient(baseURL: baseURL, token: "token", session: session)
        try await client.setWatched(true, ratingKey: "7")
        try await client.setWatched(false, ratingKey: "7")
        XCTAssertEqual(paths, ["/:/scrobble", "/:/unscrobble"])
    }

    // MARK: - Grouping

    func testEpisodesAttachToTheirShowAndShowsWithoutFilesAreDropped() {
        func item(_ key: String, _ type: String, show: String? = nil, part: String? = nil, s: Int? = nil, e: Int? = nil) -> PlexMediaItem {
            PlexMediaItem(
                ratingKey: key, type: type, title: key, summary: nil, year: nil, originallyAvailableAt: nil,
                rating: nil, contentRating: nil, durationMs: nil, thumb: nil, art: nil, genres: nil, cast: nil,
                directors: nil, imdbId: nil, tmdbId: nil, showRatingKey: show, seasonNumber: s, episodeNumber: e,
                partKey: part, container: nil, sizeBytes: nil
            )
        }
        let titles = PlexLibraryResolver.resolve(
            movies: [],
            shows: [item("50", "show"), item("60", "show")],
            episodes: [item("101", "episode", show: "50", part: "/p/1", s: 1, e: 1)],
            serverID: "srv",
            library: PlexLibrary(id: "4", name: "TV", type: "show")
        )
        XCTAssertEqual(titles.map(\.contentId), ["plex-srv-50"])
        XCTAssertEqual(titles.first?.items.first?.ratingKey, "101")
        XCTAssertEqual(titles.first?.libraryName, "TV")
    }
}
