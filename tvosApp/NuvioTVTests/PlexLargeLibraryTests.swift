import Foundation
import XCTest
@testable import NuvioTV

private final class PlexLargeLibraryMockURLProtocol: URLProtocol {
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

/// A library too large to sync: the sync skips it after one request, keeps
/// the libraries that did sync, and stream lists find its titles one at a time.
final class PlexLargeLibraryTests: XCTestCase {
    private var session: URLSession!
    private let baseURL = URL(string: "http://192.168.1.10:32400")!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlexLargeLibraryMockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        PlexLargeLibraryMockURLProtocol.requestHandler = nil
        session = nil
        super.tearDown()
    }

    private var client: PlexClient { PlexClient(baseURL: baseURL, token: "token", session: session) }

    private func respond(_ request: URLRequest, json: String, status: Int = 200) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    /// A movie, show or episode as a section listing returns it.
    private func item(
        _ key: String,
        type: String,
        title: String,
        year: Int? = nil,
        imdb: String? = nil,
        tmdb: Int? = nil,
        show: String? = nil,
        season: Int? = nil,
        episode: Int? = nil,
        viewOffset: Int? = nil,
        withFile: Bool = true
    ) -> [String: Any] {
        var item: [String: Any] = ["ratingKey": key, "type": type, "title": title]
        if let year { item["year"] = year }
        var guids: [[String: Any]] = []
        if let imdb { guids.append(["id": "imdb://\(imdb)"]) }
        if let tmdb { guids.append(["id": "tmdb://\(tmdb)"]) }
        if !guids.isEmpty { item["Guid"] = guids }
        if let show { item["grandparentRatingKey"] = show }
        if let season { item["parentIndex"] = season }
        if let episode { item["index"] = episode }
        if let viewOffset { item["viewOffset"] = viewOffset }
        if withFile {
            item["Media"] = [["container": "mkv", "Part": [["key": "/library/parts/\(key)/1/file.mkv", "size": 1000]]]]
        }
        return item
    }

    private func container(_ items: [[String: Any]], totalSize: Int? = nil) -> String {
        var container: [String: Any] = ["Metadata": items]
        if let totalSize { container["totalSize"] = totalSize }
        let data = try! JSONSerialization.data(withJSONObject: ["MediaContainer": container])
        return String(decoding: data, as: UTF8.self)
    }

    private func media(_ title: String, year: Int?, imdb: String? = nil, tmdb: Int? = nil) -> PlexMediaItem {
        PlexMediaItem(
            ratingKey: "1", type: "movie", title: title, summary: nil, year: year, originallyAvailableAt: nil,
            rating: nil, contentRating: nil, durationMs: nil, thumb: nil, art: nil, genres: nil, cast: nil,
            directors: nil, imdbId: imdb, tmdbId: tmdb, showRatingKey: nil, seasonNumber: nil, episodeNumber: nil,
            partKey: "/p/1", container: nil, sizeBytes: nil
        )
    }

    /// The search a request sends, as "title|exact or contains|year or any".
    private func describeSearch(_ request: URLRequest) -> String {
        let q = query(request)
        let kind = q["title="] != nil ? "exact" : "contains"
        return "\(q["title="] ?? q["title"] ?? "")|\(kind)|\(q["year"] ?? "any")"
    }

    // MARK: - Listing

    func testLibraryPastTheLimitIsReportedAfterOneRequest() async {
        var requests = 0
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            requests += 1
            return self.respond(request, json: self.container([self.item("1", type: "episode", title: "Pilot")], totalSize: 1_523_401))
        }
        do {
            _ = try await client.items(libraryID: "2", type: .episode)
            XCTFail("The library should be too large to sync")
        } catch let error as PlexClient.ClientError {
            XCTAssertTrue(error.isLibraryTooLarge)
            XCTAssertEqual(error.itemCount, 1_523_401)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertEqual(requests, 1)
    }

    func testListingWithoutATotalStopsPastTheLimit() async {
        var requests = 0
        let page = container((0..<500).map { item("\($0)", type: "movie", title: "Movie \($0)") })
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            requests += 1
            return self.respond(request, json: page)
        }
        do {
            _ = try await client.items(libraryID: "1", type: .movie, maxItems: 1_000)
            XCTFail("The library should be too large to sync")
        } catch let error as PlexClient.ClientError {
            XCTAssertTrue(error.isLibraryTooLarge)
            XCTAssertNil(error.itemCount)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        // Two full pages reach the limit; the third shows there is more.
        XCTAssertEqual(requests, 3)
    }

    func testListingWithoutATotalAcceptsALibraryOfExactlyTheLimit() async throws {
        let page = container((0..<500).map { item("\($0)", type: "movie", title: "Movie \($0)") })
        var requests = 0
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            requests += 1
            return self.respond(request, json: requests <= 2 ? page : self.container([]))
        }
        let items = try await client.items(libraryID: "1", type: .movie, maxItems: 1_000)
        XCTAssertEqual(items.count, 1_000)
        XCTAssertEqual(requests, 3)
    }

    // MARK: - Sync

    func testALibraryThatFailsKeepsItsTitlesAndTheOthersStillSync() async throws {
        let kids = PlexLibrary(id: "2", name: "Kids", type: "movie", changeMarker: "k2")
        let kept = PlexLibraryResolver.resolve(movies: [media("Old", year: 2000)], shows: [], episodes: [], serverID: "srv", library: kids)
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/library/sections/1/all":
                return self.respond(request, json: self.container(
                    [self.item("9", type: "movie", title: "Up", year: 2009, imdb: "tt1049413")], totalSize: 1
                ))
            case "/library/sections/2/all":
                return self.respond(request, json: "{}", status: 500)
            default:
                return self.respond(request, json: self.container(
                    [self.item("1", type: "episode", title: "Pilot")], totalSize: 900_000
                ))
            }
        }
        let outcome = try await PlexSessionManager.syncLibraries(
            [
                PlexLibrary(id: "1", name: "Movies", type: "movie", changeMarker: "m1"),
                kids,
                PlexLibrary(id: "3", name: "TV", type: "show", changeMarker: "t1")
            ],
            client: client,
            serverID: "srv",
            previousTitles: kept,
            previousMarkers: ["2": "k1"],
            knownOversized: [:],
            force: false
        )
        XCTAssertEqual(outcome.titles.map(\.contentId), ["plex-srv-9", "plex-srv-1"])
        // The failed library keeps its old marker, so the next sync lists it again.
        XCTAssertEqual(outcome.markers, ["1": "m1", "2": "k1"])
        XCTAssertEqual(outcome.oversized, ["3": 900_000])
        XCTAssertEqual(outcome.oversizedLibraries, [PlexSyncReport.OversizedLibrary(name: "TV", itemCount: 900_000)])
        XCTAssertEqual(outcome.failures.map(\.name), ["Kids"])
        XCTAssertNotNil(outcome.firstFailure)
        XCTAssertEqual(outcome.syncedLibraries, 1)
        XCTAssertFalse(outcome.listedEverything)
        XCTAssertFalse(outcome.replacesWatchStates)
    }

    func testALibraryKnownToBeTooLargeIsAskedAgainOnlyByTheSyncButton() async throws {
        var requests = 0
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            requests += 1
            return self.respond(request, json: self.container([self.item("1", type: "episode", title: "Pilot")], totalSize: 900_000))
        }
        let library = PlexLibrary(id: "3", name: "TV", type: "show", changeMarker: "t2")
        let automatic = try await PlexSessionManager.syncLibraries(
            [library], client: client, serverID: "srv",
            previousTitles: [], previousMarkers: [:], knownOversized: ["3": 900_000], force: false
        )
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(automatic.oversized, ["3": 900_000])
        XCTAssertTrue(automatic.listedEverything)
        // Watch states read for titles looked up in it must survive the sync.
        XCTAssertFalse(automatic.replacesWatchStates)

        let forced = try await PlexSessionManager.syncLibraries(
            [library], client: client, serverID: "srv",
            previousTitles: [], previousMarkers: [:], knownOversized: ["3": 900_000], force: true
        )
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(forced.oversized, ["3": 900_000])
    }

    func testAKnownOversizedLibraryStaysOversizedWhenTheSyncButtonCantCheckIt() async throws {
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            self.respond(request, json: "{}", status: 500)
        }
        let outcome = try await PlexSessionManager.syncLibraries(
            [PlexLibrary(id: "3", name: "TV", type: "show", changeMarker: "t2")], client: client, serverID: "srv",
            previousTitles: [], previousMarkers: [:], knownOversized: ["3": 900_000], force: true
        )
        XCTAssertEqual(outcome.oversized, ["3": 900_000])
        XCTAssertEqual(outcome.oversizedLibraries, [PlexSyncReport.OversizedLibrary(name: "TV", itemCount: 900_000)])
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertNil(outcome.firstFailure)
    }

    func testAFullSyncOfOrdinaryLibrariesReplacesWatchStates() async throws {
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            self.respond(request, json: self.container(
                [self.item("9", type: "movie", title: "Up", year: 2009, imdb: "tt1049413", viewOffset: 60_000)], totalSize: 1
            ))
        }
        let outcome = try await PlexSessionManager.syncLibraries(
            [PlexLibrary(id: "1", name: "Movies", type: "movie", changeMarker: "m1")], client: client, serverID: "srv",
            previousTitles: [], previousMarkers: [:], knownOversized: [:], force: false
        )
        XCTAssertTrue(outcome.replacesWatchStates)
        XCTAssertEqual(outcome.states["9"]?.viewOffsetMs, 60_000)
    }

    func testServerSavedBeforeTheseFieldsStillLoads() throws {
        let json = #"{"id":"a","displayName":"Friend","baseURLString":"","isOwned":false,"selectedLibraryIDs":["1"],"syncAutomatically":true}"#
        let server = try JSONDecoder().decode(PlexServerConfig.self, from: Data(json.utf8))
        XCTAssertNil(server.lastSyncAttemptDate)
        XCTAssertNil(server.oversizedLibraries)

        var updated = server
        updated.oversizedLibraries = ["3": 900_000]
        updated.lastSyncAttemptDate = Date(timeIntervalSince1970: 1_800_000_000)
        let decoded = try JSONDecoder().decode(PlexServerConfig.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(decoded, updated)
    }

    // MARK: - Looking a title up

    func testSearchAsksForNamesContainingTheTitleInItsYearAndKeepsAPlusSign() async throws {
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            let q = self.query(request)
            XCTAssertEqual(request.url?.path, "/library/sections/1/all")
            XCTAssertEqual(q["type"], "1")
            XCTAssertEqual(q["title"], "Romeo + Juliet")
            XCTAssertNil(q["title="])
            XCTAssertEqual(q["includeGuids"], "1")
            XCTAssertEqual(q["year"], "1996")
            XCTAssertEqual(q["X-Plex-Container-Size"], "50")
            XCTAssertTrue(request.url?.absoluteString.contains("title=Romeo%20%2B%20Juliet") == true, request.url?.absoluteString ?? "")
            return self.respond(request, json: self.container(
                [self.item("7", type: "movie", title: "Romeo + Juliet", year: 1996, imdb: "tt0117509")]
            ))
        }
        let found = try await client.search(libraryID: "1", type: .movie, title: "Romeo + Juliet", year: 1996)
        XCTAssertEqual(found.map(\.imdbId), ["tt0117509"])
    }

    func testAnExactSearchAsksForTheNameItself() async throws {
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            let q = self.query(request)
            // `title==Up`: the key `title=` with the value `Up`.
            XCTAssertEqual(q["title="], "Up")
            XCTAssertNil(q["title"])
            XCTAssertNil(q["year"])
            return self.respond(request, json: self.container([]))
        }
        let found = try await client.search(libraryID: "1", type: .movie, title: "Up", exact: true)
        XCTAssertTrue(found.isEmpty)
    }

    func testEpisodesListsEveryEpisodeOfAShow() async throws {
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/library/metadata/50/allLeaves")
            XCTAssertEqual(self.query(request)["includeGuids"], "1")
            return self.respond(request, json: self.container([
                self.item("101", type: "episode", title: "Pilot", show: "50", season: 1, episode: 1),
                self.item("102", type: "episode", title: "Two", show: "50", season: 1, episode: 2)
            ]))
        }
        let episodes = try await client.episodes(showRatingKey: "50")
        XCTAssertEqual(episodes.map(\.episodeNumber), [1, 2])
        XCTAssertEqual(episodes.first?.showRatingKey, "50")
    }

    func testAnIdBothSidesHaveDecides() {
        let target = PlexLargeLibraryLookup.Target(name: "Up", year: 2009, imdbId: "tt1049413", tmdbId: 14160)
        XCTAssertTrue(PlexLargeLibraryLookup.matches(media("Up", year: 2009, imdb: "tt1049413"), target))
        // Same name and year, another film.
        XCTAssertFalse(PlexLargeLibraryLookup.matches(media("Up", year: 2009, imdb: "tt0000001"), target))
        // No IMDb id on the server: TMDB decides.
        XCTAssertTrue(PlexLargeLibraryLookup.matches(media("Up!", year: 2010, tmdb: 14160), target))
        XCTAssertFalse(PlexLargeLibraryLookup.matches(media("Up", year: 2009, tmdb: 1), target))
    }

    func testWithoutAnIdToCompareTheNameAndYearDecide() {
        let target = PlexLargeLibraryLookup.Target(name: "Amélie", year: 2001, imdbId: "tt0211915", tmdbId: nil)
        XCTAssertTrue(PlexLargeLibraryLookup.matches(media("amelie", year: 2002), target))
        XCTAssertTrue(PlexLargeLibraryLookup.matches(media("Amélie", year: 2001, tmdb: 194), target))
        XCTAssertFalse(PlexLargeLibraryLookup.matches(media("Amelie", year: 2004), target))
        XCTAssertFalse(PlexLargeLibraryLookup.matches(media("Amelie", year: nil), target))
        XCTAssertFalse(PlexLargeLibraryLookup.matches(media("Amelie 2", year: 2001), target))
    }

    func testSearchesTryTheExactNameThenNamesContainingItThenTheNameBeforeASubtitle() {
        typealias Search = PlexLargeLibraryLookup.Search
        XCTAssertEqual(PlexLargeLibraryLookup.searches(name: "Mission: Impossible - Fallout", year: 2018), [
            Search(title: "Mission: Impossible - Fallout", exact: true),
            Search(title: "Mission: Impossible - Fallout", year: 2018),
            Search(title: "Mission: Impossible - Fallout"),
            Search(title: "Mission", year: 2018)
        ])
        XCTAssertEqual(PlexLargeLibraryLookup.searches(name: "Up", year: nil), [
            Search(title: "Up", exact: true),
            Search(title: "Up")
        ])
    }

    func testTargetTakesTheIdsInTheContentId() {
        let meta = NuvioMeta(
            id: "tmdb:14160", name: "Up", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil,
            imdbId: "tt1049413", tmdbId: 1, type: "movie", year: nil, genres: nil, rating: nil, releaseInfo: "2009",
            runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil,
            status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil
        )
        let target = PlexLargeLibraryLookup.Target(contentId: "tmdb:14160", meta: meta)
        XCTAssertEqual(target, PlexLargeLibraryLookup.Target(name: "Up", year: 2009, imdbId: "tt1049413", tmdbId: 14160))
    }

    func testFindKeepsTheMovieWhoseIdMatchesWithItsWatchState() async throws {
        var searches: [String] = []
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            searches.append(self.describeSearch(request))
            let q = self.query(request)
            let upInTheAir = self.item("8", type: "movie", title: "Up in the Air", year: 2009, imdb: "tt1193138")
            if q["title="] != nil { return self.respond(request, json: self.container([])) }
            if q["year"] != nil { return self.respond(request, json: self.container([upInTheAir])) }
            return self.respond(request, json: self.container([
                upInTheAir,
                self.item("9", type: "movie", title: "Up", year: 2009, imdb: "tt1049413", viewOffset: 2_700_000)
            ]))
        }
        let found = try await PlexLargeLibraryLookup.find(
            PlexLargeLibraryLookup.Target(name: "Up", year: 2009, imdbId: "tt1049413", tmdbId: nil),
            in: PlexLibrary(id: "1", name: "Movies", type: "movie"),
            serverID: "srv",
            client: client
        )
        XCTAssertEqual(searches, ["Up|exact|any", "Up|contains|2009", "Up|contains|any"])
        XCTAssertEqual(found.titles.map(\.contentId), ["plex-srv-9"])
        XCTAssertEqual(found.titles.first?.items.first?.partKey, "/library/parts/9/1/file.mkv")
        XCTAssertEqual(found.states, ["9": PlexWatchState(viewOffsetMs: 2_700_000)])
    }

    func testASearchTheServerRefusesIsFollowedByTheNext() async throws {
        let target = PlexLargeLibraryLookup.Target(name: "Up", year: 2009, imdbId: "tt1049413", tmdbId: nil)
        let movies = PlexLibrary(id: "1", name: "Movies", type: "movie")
        var inTheYear: [[String: Any]] = [item("9", type: "movie", title: "Up", year: 2009, imdb: "tt1049413")]
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            let q = self.query(request)
            if q["title="] != nil { return self.respond(request, json: "{}", status: 400) }
            return self.respond(request, json: self.container(q["year"] != nil ? inTheYear : []))
        }
        let found = try await PlexLargeLibraryLookup.find(target, in: movies, serverID: "srv", client: client)
        XCTAssertEqual(found.titles.map(\.contentId), ["plex-srv-9"])

        // Not found after a refused search: an error, so the title is asked again later.
        inTheYear = []
        do {
            _ = try await PlexLargeLibraryLookup.find(target, in: movies, serverID: "srv", client: client)
            XCTFail("The lookup should fail when a search was refused and nothing was found")
        } catch let error as PlexClient.ClientError {
            XCTAssertFalse(error.isUnauthorized)
        }
    }

    func testFindReadsTheEpisodesOfTheShowThatMatchesWithTheirWatchState() async throws {
        PlexLargeLibraryMockURLProtocol.requestHandler = { request in
            if request.url?.path == "/library/metadata/50/allLeaves" {
                return self.respond(request, json: self.container([
                    self.item("101", type: "episode", title: "Good News About Hell", show: "50", season: 1, episode: 1),
                    self.item("102", type: "episode", title: "Half Loop", show: "50", season: 1, episode: 2, viewOffset: 900_000)
                ]))
            }
            XCTAssertEqual(self.query(request)["type"], "2")
            return self.respond(request, json: self.container([
                self.item("50", type: "show", title: "Severance", year: 2022, imdb: "tt11280740", withFile: false)
            ]))
        }
        let found = try await PlexLargeLibraryLookup.find(
            PlexLargeLibraryLookup.Target(name: "Severance", year: 2022, imdbId: "tt11280740", tmdbId: nil),
            in: PlexLibrary(id: "2", name: "TV", type: "show"),
            serverID: "srv",
            client: client
        )
        XCTAssertEqual(found.titles.map(\.type), ["series"])
        XCTAssertEqual(found.titles.first?.items.map(\.episode), [1, 2])
        XCTAssertEqual(found.states["102"]?.viewOffsetMs, 900_000)
        XCTAssertEqual(found.states["101"], PlexWatchState())
    }

    // MARK: - Index

    @MainActor
    func testLookedUpTitlesAndTheirLookupTimeGoWithTheServer() {
        let index = PlexLibraryIndex.shared
        let serverID = "lookup-test-server"
        let found = PlexLibraryResolver.resolve(
            movies: [media("Up", year: 2009, imdb: "tt1049413")], shows: [], episodes: [],
            serverID: serverID, library: PlexLibrary(id: "1", name: "Movies", type: "movie")
        )
        index.recordLookup(contentId: "imdb:tt9999901", libraries: [(serverID: serverID, libraryID: "1")], found: found)
        XCTAssertEqual(index.titles(matching: "tt9999901").map(\.contentId), ["plex-\(serverID)-1"])
        XCTAssertTrue(index.wasLookedUp(contentId: "tt9999901", serverID: serverID, libraryID: "1", within: 60))
        XCTAssertFalse(index.wasLookedUp(contentId: "tt9999901", serverID: serverID, libraryID: "2", within: 60))

        index.removeAll(forServerID: serverID)
        XCTAssertTrue(index.titles(matching: "tt9999901").isEmpty)
        // Asked again on the next stream list, rather than skipped as recent.
        XCTAssertFalse(index.wasLookedUp(contentId: "tt9999901", serverID: serverID, libraryID: "1", within: 60))
    }

    @MainActor
    func testALookupThatFoundNothingIsRememberedForItsInterval() {
        let index = PlexLibraryIndex.shared
        let serverID = "lookup-miss-test-server"
        let now = Date()
        index.recordLookup(contentId: "tt9999902", libraries: [(serverID: serverID, libraryID: "1")], found: [], at: now)
        XCTAssertTrue(index.titles(matching: "tt9999902").isEmpty)
        XCTAssertTrue(index.wasLookedUp(contentId: "tt9999902", serverID: serverID, libraryID: "1", within: 900, now: now.addingTimeInterval(899)))
        XCTAssertFalse(index.wasLookedUp(contentId: "tt9999902", serverID: serverID, libraryID: "1", within: 900, now: now.addingTimeInterval(900)))
        index.removeAll(forServerID: serverID)
    }

    @MainActor
    func testOnlyTheLatestLookupsAreKept() {
        let index = PlexLibraryIndex.shared
        let serverID = "lookup-limit-test-server"
        let found = PlexLibraryResolver.resolve(
            movies: [media("Up", year: 2009)], shows: [], episodes: [],
            serverID: serverID, library: PlexLibrary(id: "1", name: "Movies", type: "movie")
        )
        let ids = (0...PlexLibraryIndex.lookedUpLimit).map { "tt88880\($0)" }
        for id in ids { index.recordLookup(contentId: id, libraries: [(serverID: serverID, libraryID: "1")], found: found) }
        XCTAssertTrue(index.titles(matching: ids[0]).isEmpty)
        XCTAssertFalse(index.wasLookedUp(contentId: ids[0], serverID: serverID, libraryID: "1", within: 60))
        XCTAssertFalse(index.titles(matching: ids[ids.count - 1]).isEmpty)
        index.removeAll(forServerID: serverID)
    }

    @MainActor
    func testALookupInOneLibraryKeepsWhatAnotherLibraryFound() {
        let index = PlexLibraryIndex.shared
        let serverID = "lookup-merge-test-server"
        let movies = PlexLibrary(id: "1", name: "Movies", type: "movie")
        let uhd = PlexLibrary(id: "2", name: "Movies 4K", type: "movie")
        let inMovies = PlexLibraryResolver.resolve(movies: [media("Up", year: 2009)], shows: [], episodes: [], serverID: serverID, library: movies)
        let inUHD = PlexLibraryResolver.resolve(movies: [media("Up", year: 2009)], shows: [], episodes: [], serverID: serverID, library: uhd)
        index.recordLookup(contentId: "tt9999903", libraries: [(serverID: serverID, libraryID: "1"), (serverID: serverID, libraryID: "2")], found: inMovies + inUHD)
        index.recordLookup(contentId: "tt9999903", libraries: [(serverID: serverID, libraryID: "1")], found: [])
        XCTAssertEqual(index.titles(matching: "tt9999903").map(\.libraryID), ["2"])
        index.removeAll(forServerID: serverID)
    }
}
