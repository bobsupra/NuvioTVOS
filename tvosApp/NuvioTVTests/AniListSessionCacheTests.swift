import XCTest
@testable import NuvioTV

/// AniList titles and their extras kept in memory for the session (Back shows them at once).
final class AniListSessionCacheTests: XCTestCase {
    private func builtTitle(_ id: String, keys: [String]) -> AniListSessionCache.Title {
        AniListSessionCache.Title(
            meta: NuvioMeta(id: id, name: "Kaiju Sentai", type: "series"),
            tabLabels: [1: .init(name: "Season 1", year: 2020)],
            seasonByEntry: [101: 1, 102: 2],
            related: [],
            keys: keys
        )
    }

    func testABuiltTitleIsKeptUnderEveryIDItWasOpenedBy() {
        AniListSessionCache.removeAll()
        defer { AniListSessionCache.removeAll() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        AniListSessionCache.store(builtTitle("anilist:101", keys: ["anilist:101", "anilist:102"]), finished: true, signature: "a", now: now)
        XCTAssertEqual(AniListSessionCache.title("anilist:102", signature: "a", now: now)?.meta.id, "anilist:101")
        XCTAssertEqual(AniListSessionCache.title("ANILIST:101", signature: "a", now: now)?.seasonByEntry[102], 2)
        XCTAssertNil(AniListSessionCache.title("anilist:103", signature: "a", now: now))
        XCTAssertNil(AniListSessionCache.title("anilist:101", signature: "b", now: now), "other settings build it again")
    }

    func testAnAiringTitleIsKeptShorterThanAFinishedOne() {
        AniListSessionCache.removeAll()
        defer { AniListSessionCache.removeAll() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        AniListSessionCache.store(builtTitle("anilist:1", keys: ["anilist:1"]), finished: true, signature: "a", now: now)
        AniListSessionCache.store(builtTitle("anilist:2", keys: ["anilist:2"]), finished: false, signature: "a", now: now)
        let hourLater = now.addingTimeInterval(3600)
        XCTAssertNotNil(AniListSessionCache.title("anilist:1", signature: "a", now: hourLater))
        XCTAssertNil(AniListSessionCache.title("anilist:2", signature: "a", now: hourLater))
        XCTAssertNil(AniListSessionCache.title("anilist:1", signature: "a", now: now.addingTimeInterval(7 * 3600)))
    }

    func testATitleWithoutItsBackgroundIsBuiltAgainSoon() {
        AniListSessionCache.removeAll()
        defer { AniListSessionCache.removeAll() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        AniListSessionCache.store(builtTitle("anilist:3", keys: ["anilist:3"]), finished: true, missingPictures: true, signature: "a", now: now)
        XCTAssertNotNil(AniListSessionCache.title("anilist:3", signature: "a", now: now.addingTimeInterval(60)), "Back still shows it at once")
        XCTAssertNil(AniListSessionCache.title("anilist:3", signature: "a", now: now.addingTimeInterval(10 * 60)))
    }

    func testClearingTheCacheDropsTitlesAndExtras() {
        let now = Date()
        AniListSessionCache.store(builtTitle("anilist:1", keys: ["anilist:1"]), finished: true, signature: "a", now: now)
        AniListSessionCache.storeExtras(([], []), for: "anilist:1", finished: true, signature: "a", now: now)
        XCTAssertNotNil(AniListSessionCache.extras("anilist:1", signature: "a", now: now))
        AniListSessionCache.removeAll()
        XCTAssertNil(AniListSessionCache.title("anilist:1", signature: "a", now: now))
        XCTAssertNil(AniListSessionCache.extras("anilist:1", signature: "a", now: now))
    }
}
