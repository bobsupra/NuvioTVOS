import Foundation
import XCTest
@testable import NuvioTV

@MainActor
final class PlexPlaybackSyncTests: XCTestCase {
    private let serverID = "test-plex-server"
    private let partPath = "/library/parts/9/1/file.mkv"
    private var sync: PlexPlaybackSync!
    private var sent: [(state: PlexClient.TimelineState, timeMs: Int64)] = []
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    private var storedLink: String { "http://10.0.0.5:32400\(partPath)?X-Plex-Token=old" }

    override func setUp() async throws {
        PlexServerStore.shared.upsert(PlexServerConfig(id: serverID, displayName: "Test", baseURLString: "http://192.168.1.10:32400"))
        let item = PlexIndexedItem(ratingKey: "101", partKey: partPath, container: "mkv", size: 1, durationMs: 600_000, season: 1, episode: 1)
        let title = PlexIndexedTitle(
            contentId: "plex-\(serverID)-50", serverID: serverID, libraryID: "4", libraryName: "TV", ratingKey: "50",
            type: "series", name: "Show", overview: nil, year: nil, genres: nil, rating: nil, contentRating: nil,
            premiereDate: nil, durationMs: nil, imdbId: nil, tmdbId: nil, thumb: nil, art: nil, cast: nil, directors: nil,
            items: [item]
        )
        try PlexLibraryIndex.shared.replace(titles: [title], forServerID: serverID)
        PlexLibraryIndex.shared.setWatchStates(["101": PlexWatchState(viewOffsetMs: 120_000)], forServerID: serverID, merging: false)
        sent = []
        sync = PlexPlaybackSync()
        sync.now = { [unowned self] in self.clock }
        sync.sendTimeline = { [unowned self] _, state, timeMs, _ in self.sent.append((state, timeMs)) }
    }

    override func tearDown() async throws {
        PlexServerStore.shared.remove(serverID)
    }

    func testStoredLinkIsRecognisedAndPointedAtTheCurrentAddressWithoutAToken() {
        let resolved = sync.resolve(url: URL(string: storedLink)!, headers: ["User-Agent": "x"])
        XCTAssertEqual(resolved.url.absoluteString, "http://192.168.1.10:32400\(partPath)")
        XCTAssertEqual(resolved.headers["User-Agent"], "x")
        XCTAssertNotNil(resolved.headers[PlexClient.tokenHeader])
        XCTAssertNil(sync.headersForStorage(url: resolved.url.absoluteString, headers: resolved.headers)[PlexClient.tokenHeader])
    }

    func testExternalPlayersGetTheTokenInTheLink() {
        let external = sync.urlForExternalPlayer(URL(string: storedLink)!)
        let components = URLComponents(url: external, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.path, partPath)
        XCTAssertEqual(components?.host, "192.168.1.10")
        // The token stored for the server, or none when there isn't one.
        let token = PlexCredentialStore.token(forServerID: serverID)
        let sentToken = components?.queryItems?.first { $0.name == PlexClient.tokenHeader }?.value
        XCTAssertEqual(sentToken, token.isEmpty ? nil : token)
        XCTAssertFalse(external.absoluteString.contains("Token=old"))
        let other = URL(string: "https://example.com/video.mkv?t=1")!
        XCTAssertEqual(sync.urlForExternalPlayer(other), other)
    }

    func testOtherStreamsPassThroughUnchanged() {
        let url = URL(string: "https://example.com/video.mkv?t=1")!
        let resolved = sync.resolve(url: url, headers: ["A": "b"])
        XCTAssertEqual(resolved.url, url)
        XCTAssertEqual(resolved.headers, ["A": "b"])
        XCTAssertEqual(sync.resumePosition(for: url, fallback: 42), 42)
    }

    func testPlexPositionWinsOncePerPlayIncludingForStoredLinks() {
        let url = URL(string: storedLink)!
        XCTAssertEqual(sync.resumePosition(for: url, fallback: 30), 120)
        // A reload within the same play keeps the caller's position.
        XCTAssertEqual(sync.resumePosition(for: url, fallback: 300), 300)
        // After a stop, the next play reads Plex's position again.
        sync.report(.playing, url: storedLink, currentTime: 200, duration: 600)
        sync.report(.stopped, url: storedLink, currentTime: 210, duration: 600)
        XCTAssertEqual(sync.resumePosition(for: url, fallback: 30), 210)
    }

    func testNoReportAtZeroAndHeartbeatsEveryTenSeconds() {
        sync.report(.playing, url: storedLink, currentTime: 0, duration: 600)
        XCTAssertTrue(sent.isEmpty)
        sync.report(.playing, url: storedLink, currentTime: 120, duration: 600)
        clock += 5
        sync.report(.playing, url: storedLink, currentTime: 125, duration: 600)
        clock += 5
        sync.report(.playing, url: storedLink, currentTime: 130, duration: 600)
        sync.report(.paused, url: storedLink, currentTime: 131, duration: 600)
        sync.report(.stopped, url: storedLink, currentTime: 131, duration: 600)
        sync.report(.stopped, url: storedLink, currentTime: 131, duration: 600)
        XCTAssertEqual(sent.map(\.state), [.playing, .playing, .paused, .stopped])
        XCTAssertEqual(sent.map(\.timeMs), [120_000, 130_000, 131_000, 131_000])
    }

    func testStopBeforeAnyReportLeavesPlexAlone() {
        sync.report(.stopped, url: storedLink, currentTime: 0, duration: 600)
        XCTAssertTrue(sent.isEmpty)
    }

    func testInProgressTakesEachTitlesLatestEpisodeWithinSixteenWeeks() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func episode(_ key: String, _ number: Int) -> PlexIndexedItem {
            PlexIndexedItem(ratingKey: key, partKey: "/library/parts/\(key)/1/file.mkv", container: nil, size: nil, durationMs: 600_000, season: 1, episode: number)
        }
        func show(_ key: String, _ items: [PlexIndexedItem]) -> PlexIndexedTitle {
            PlexIndexedTitle(
                contentId: "plex-\(serverID)-\(key)", serverID: serverID, libraryID: "4", libraryName: "TV", ratingKey: key,
                type: "series", name: key, overview: nil, year: nil, genres: nil, rating: nil, contentRating: nil,
                premiereDate: nil, durationMs: nil, imdbId: nil, tmdbId: nil, thumb: nil, art: nil, cast: nil, directors: nil,
                items: items
            )
        }
        try PlexLibraryIndex.shared.replace(titles: [
            show("A", [episode("a1", 1), episode("a2", 2)]),
            show("B", [episode("b1", 1)]),
            show("C", [episode("c1", 1)])
        ], forServerID: serverID)
        let recent = Int64(now.timeIntervalSince1970) - 3600
        PlexLibraryIndex.shared.setWatchStates([
            "a1": PlexWatchState(viewOffsetMs: 60_000, lastViewedAt: recent - 100),
            "a2": PlexWatchState(viewOffsetMs: 30_000, lastViewedAt: recent),          // A's latest
            "b1": PlexWatchState(viewOffsetMs: 0, viewCount: 1, lastViewedAt: recent), // finished
            "c1": PlexWatchState(viewOffsetMs: 90_000, lastViewedAt: recent - 17 * 7 * 24 * 3600) // too old
        ], forServerID: serverID, merging: false)
        let found = PlexLibraryIndex.shared.inProgress(now: now)
        XCTAssertEqual(found.map(\.title.ratingKey), ["A"])
        XCTAssertEqual(found.first?.item.ratingKey, "a2")
    }

    func testFinishingMarksWatchedLocallyAndClearsThePosition() {
        sync.report(.playing, url: storedLink, currentTime: 100, duration: 600)
        sync.report(.stopped, url: storedLink, currentTime: 590, duration: 600)
        let state = PlexLibraryIndex.shared.watchState(serverID: serverID, ratingKey: "101")
        XCTAssertEqual(state?.viewOffsetMs, 0)
        XCTAssertEqual(state?.isWatched, true)
    }
}
