import XCTest
@testable import NuvioTV

/// One Title's seasons: TV entries joined by prequels and sequels, also past a film, an OVA or
/// a special between two seasons.
final class AniListSeasonChainTests: XCTestCase {
    private func node(_ id: Int, _ format: String, _ year: Int) -> AniListMedia {
        AniListMedia(id: id, type: "ANIME", format: format, startDate: AniListDate(year: year))
    }

    private func entry(
        _ id: Int,
        _ format: String,
        _ year: Int,
        prequels: [AniListMedia] = [],
        sequels: [AniListMedia] = []
    ) -> AniListMedia {
        let edges = prequels.map { AniListRelationEdge(relationType: "PREQUEL", node: $0) }
            + sequels.map { AniListRelationEdge(relationType: "SEQUEL", node: $0) }
        return AniListMedia(
            id: id,
            type: "ANIME",
            format: format,
            startDate: AniListDate(year: year),
            relations: AniListRelationConnection(edges: edges)
        )
    }

    /// Goblin Slayer (TV 2018) → Goblin's Crown (film 2020) → Goblin Slayer II (TV 2023).
    private var goblinSlayer: [Int: AniListMedia] {
        let first = node(1, "TV", 2018), film = node(2, "MOVIE", 2020), second = node(3, "TV", 2023)
        return [
            1: entry(1, "TV", 2018, sequels: [film]),
            2: entry(2, "MOVIE", 2020, prequels: [first], sequels: [second]),
            3: entry(3, "TV", 2023, prequels: [film]),
        ]
    }

    func testAFilmBetweenTwoSeasonsIsPassedThrough() {
        let entries = goblinSlayer
        XCTAssertEqual(AniListMetaBuilder.chain(from: 1, entries: entries).ids, [1, 3])
        XCTAssertEqual(AniListMetaBuilder.chain(from: 3, entries: entries).ids, [1, 3], "back from the second season too")
        XCTAssertTrue(AniListMetaBuilder.chain(from: 1, entries: entries).missing.isEmpty)
    }

    func testAFilmNotFetchedYetIsAskedFor() {
        var entries = goblinSlayer
        entries[2] = nil
        let chain = AniListMetaBuilder.chain(from: 1, entries: entries)
        XCTAssertEqual(chain.ids, [1])
        XCTAssertEqual(chain.missing, [2])
    }

    func testASeasonAfterAFilmComesAfterTheDirectSequel() {
        // KonoSuba: Season 2's sequel is the film Kurenai Densetsu, and Season 3 the film's.
        let second = node(2, "TV", 2017), film = node(3, "MOVIE", 2019), third = node(4, "TV", 2024)
        let entries = [
            1: entry(1, "TV", 2016, sequels: [second]),
            2: entry(2, "TV", 2017, prequels: [node(1, "TV", 2016)], sequels: [film]),
            3: entry(3, "MOVIE", 2019, prequels: [second], sequels: [third]),
            4: entry(4, "TV", 2024, prequels: [film]),
        ]
        XCTAssertEqual(AniListMetaBuilder.chain(from: 1, entries: entries).ids, [1, 2, 4])
        XCTAssertEqual(AniListMetaBuilder.chain(from: 4, entries: entries).ids, [1, 2, 4])
    }

    func testAFilmAfterTheLastSeasonEndsTheSeries() {
        let entries = [
            1: entry(1, "TV", 2016, sequels: [node(2, "MOVIE", 2019)]),
            2: entry(2, "MOVIE", 2019, prequels: [node(1, "TV", 2016)]),
        ]
        XCTAssertEqual(AniListMetaBuilder.chain(from: 1, entries: entries).ids, [1])
        XCTAssertTrue(AniListMetaBuilder.chain(from: 1, entries: entries).missing.isEmpty)
    }

    func testThreeInARowAreNotOneSeries() {
        let entries = [
            1: entry(1, "TV", 2010, sequels: [node(2, "MOVIE", 2011)]),
            2: entry(2, "MOVIE", 2011, sequels: [node(3, "OVA", 2012)]),
            3: entry(3, "OVA", 2012, sequels: [node(4, "SPECIAL", 2013)]),
            4: entry(4, "SPECIAL", 2013, sequels: [node(5, "TV", 2014)]),
            5: entry(5, "TV", 2014),
        ]
        XCTAssertEqual(AniListMetaBuilder.chain(from: 1, entries: entries).ids, [1])
    }

    func testMusicIsNotPassedThrough() {
        let entries = [
            1: entry(1, "TV", 2010, sequels: [node(2, "MUSIC", 2011)]),
            2: entry(2, "MUSIC", 2011, sequels: [node(3, "TV", 2012)]),
            3: entry(3, "TV", 2012),
        ]
        XCTAssertEqual(AniListMetaBuilder.chain(from: 1, entries: entries).ids, [1])
    }
}
