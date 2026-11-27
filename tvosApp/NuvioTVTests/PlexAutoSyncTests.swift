import XCTest
@testable import NuvioTV

final class PlexAutoSyncTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNeverSyncedServerIsDue() {
        XCTAssertTrue(PlexSessionManager.isSyncDue(lastSyncDate: nil, minimumInterval: 300, now: now))
    }

    func testSyncIsDueOnceTheIntervalHasPassed() {
        let interval = PlexSessionManager.streamListAutoSyncInterval
        XCTAssertFalse(PlexSessionManager.isSyncDue(
            lastSyncDate: now.addingTimeInterval(-(interval - 1)), minimumInterval: interval, now: now))
        XCTAssertTrue(PlexSessionManager.isSyncDue(
            lastSyncDate: now.addingTimeInterval(-interval), minimumInterval: interval, now: now))
    }

    func testReturningToTheAppLooksForNewTitlesWithinMinutes() {
        XCTAssertEqual(PlexSessionManager.foregroundAutoSyncInterval, 15 * 60)
        XCTAssertTrue(PlexSessionManager.isSyncDue(
            lastSyncDate: now.addingTimeInterval(-16 * 60),
            minimumInterval: PlexSessionManager.foregroundAutoSyncInterval,
            now: now))
    }

    func testAFailedSyncWaitsAsLongAsAFinishedOne() {
        let interval = PlexSessionManager.streamListAutoSyncInterval
        // Last finished a day ago, but an attempt failed a minute ago.
        XCTAssertFalse(PlexSessionManager.isSyncDue(
            lastSyncDate: now.addingTimeInterval(-86_400),
            lastAttemptDate: now.addingTimeInterval(-60),
            minimumInterval: interval,
            now: now))
        // Never finished: still waits after an attempt.
        XCTAssertFalse(PlexSessionManager.isSyncDue(
            lastSyncDate: nil, lastAttemptDate: now.addingTimeInterval(-60), minimumInterval: interval, now: now))
        XCTAssertTrue(PlexSessionManager.isSyncDue(
            lastSyncDate: nil, lastAttemptDate: now.addingTimeInterval(-interval), minimumInterval: interval, now: now))
    }

    func testStreamListWaitStaysShort() {
        XCTAssertLessThanOrEqual(PlexSessionManager.streamListSyncWait, 2)
        XCTAssertLessThan(PlexSessionManager.streamListAutoSyncInterval, PlexSessionManager.foregroundAutoSyncInterval)
    }

    /// A server just added picks its movie and TV libraries; one unpicked after
    /// a sync keeps its choice.
    func testANewServerPicksItsVideoLibraries() {
        let fresh = PlexServerConfig(id: "s1", displayName: "Plex")
        XCTAssertTrue(PlexSessionManager.picksVideoLibrariesOnFirstSync(fresh))
        var unpicked = fresh
        unpicked.lastSyncDate = now
        XCTAssertFalse(PlexSessionManager.picksVideoLibrariesOnFirstSync(unpicked))
        let libraries = [
            PlexLibrary(id: "1", name: "Movies", type: "movie"),
            PlexLibrary(id: "2", name: "TV Shows", type: "show"),
            PlexLibrary(id: "3", name: "Music", type: "artist"),
            PlexLibrary(id: "4", name: "Photos", type: "photo"),
        ]
        XCTAssertEqual(PlexSessionManager.videoLibraryIDs(libraries), ["1", "2"])
    }

    /// Nothing indexed here: a restored server that had titles syncs again; one
    /// whose last sync found none, such as only oversized libraries, waits.
    func testAnEmptyIndexHereSyncsAServerThatHadTitles() {
        let restored = PlexServerConfig(
            id: "s1", displayName: "Plex", selectedLibraryIDs: ["1"], lastSyncDate: now, lastSyncTitleCount: 250
        )
        XCTAssertTrue(PlexSessionManager.needsFirstSyncHere(restored, indexedTitles: 0))
        XCTAssertFalse(PlexSessionManager.needsFirstSyncHere(restored, indexedTitles: 250))
        let foundNone = PlexServerConfig(
            id: "s2", displayName: "Plex", selectedLibraryIDs: ["1"], lastSyncDate: now, lastSyncTitleCount: 0
        )
        XCTAssertFalse(PlexSessionManager.needsFirstSyncHere(foundNone, indexedTitles: 0))
        let neverSynced = PlexServerConfig(id: "s3", displayName: "Plex", selectedLibraryIDs: ["1"])
        XCTAssertTrue(PlexSessionManager.needsFirstSyncHere(neverSynced, indexedTitles: 0))
    }
}
