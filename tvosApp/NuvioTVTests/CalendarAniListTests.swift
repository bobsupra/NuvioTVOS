import Foundation
import XCTest
@testable import NuvioTV

/// The calendar's "Anime from AniList" option (`CalendarAniList`).
final class CalendarAniListTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let first = CalendarDay(year: 2026, month: 11, day: 1)
    private let last = CalendarDay(year: 2026, month: 11, day: 30)

    // 100 (S1, finished) → 101 (S2, airing): followed in Nuvio through S1.
    // 200: on the Watching list, but in the library as a Cinemeta title.
    // 300: on the Planning list, premiering this month.
    // 400: on the Watching list, a new season of a Cinemeta title (its prequel 399).
    private static let media: [Int: String] = [
        100: mediaJSON(100, status: "FINISHED", episodes: 12, relations: [("SEQUEL", 101, "TV")]),
        101: mediaJSON(101, status: "RELEASING", episodes: 12, relations: [("PREQUEL", 100, "TV")]),
        200: mediaJSON(200, status: "RELEASING", episodes: 24),
        300: mediaJSON(300, status: "RELEASING", episodes: 13),
        400: mediaJSON(400, status: "RELEASING", episodes: 12, relations: [("PREQUEL", 399, "TV")]),
    ]

    private static let airings: [(mediaId: Int, episode: Int, at: Int)] = [
        (101, 5, 1_794_322_800),   // 2026-11-10 15:00 UTC
        (101, 12, 1_794_927_600),  // 2026-11-17 15:00 UTC, the last
        (200, 3, 1_794_493_800),
        (300, 1, 1_794_585_600),   // 2026-11-13, the premiere
        (300, 2, 1_795_190_400),
        (400, 1, 1_794_657_600),
        (101, 6, 1_798_632_000),   // 2026-12-30, after the period
    ]

    func testLaterSeasonsListAndPlanningPremieresButNotCinemetaTitles() async {
        let source = aniList(list: [200: "CURRENT", 300: "PLANNING", 400: "CURRENT"], planning: true)
        let followed = [CalendarItem(id: "anilist:100", kind: .series, type: "series", name: "Show 100")]

        let found = await source.load(followed: followed, covered: [200, 399], first: first, last: last)

        XCTAssertFalse(found.failed)
        let shown = found.entries.map { "\($0.itemId) \($0.episodeCode ?? "-") \($0.date.iso) \($0.releaseKind.rawValue)" }
        XCTAssertEqual(Set(shown), [
            "anilist:101 E5 2026-11-10 episode",
            "anilist:101 E12 2026-11-17 seasonFinale",
            "anilist:300 E1 2026-11-13 seriesPremiere",
        ])
        XCTAssertEqual(found.followKeys["anilist:100"], "series:-101")
    }

    func testPlanningStaysOutWithItsSwitchOff() async {
        let source = aniList(list: [300: "PLANNING"], planning: false)
        let found = await source.load(followed: [], covered: [], first: first, last: last)
        XCTAssertTrue(found.entries.isEmpty)
    }

    func testEntriesKeepAniListsTitleTimeAndNumbering() async throws {
        let source = aniList(list: [101: "CURRENT"], planning: true)
        let found = await source.load(followed: [], covered: [], first: first, last: last)
        let entry = try XCTUnwrap(found.entries.first { $0.episodeNumber == 5 })

        XCTAssertEqual(entry.title, "Show 101")
        XCTAssertEqual(entry.tmdbId, -101)
        XCTAssertTrue(entry.isFromAniList)
        XCTAssertTrue(entry.isAnime)
        XCTAssertEqual(entry.airTime, Date(timeIntervalSince1970: 1_794_322_800))
        XCTAssertEqual(entry.airTimeSource, .anilist)
        XCTAssertEqual(entry.posterURL?.absoluteString, "https://img.example/101.jpg")
        XCTAssertEqual(entry.episodeCode, "E5")
        XCTAssertNotEqual(entry.id, found.entries.first { $0.episodeNumber == 12 }?.id)
    }

    func testAniListNotAnsweringAddsNothing() async {
        let source = CalendarAniList(
            query: { _, _, _ in throw URLError(.timedOut) },
            listIDs: { [101: "CURRENT"] },
            includesPlanning: true,
            language: .romaji,
            timeZone: utc
        )
        let found = await source.load(followed: [], covered: [], first: first, last: last)
        XCTAssertTrue(found.failed)
        XCTAssertTrue(found.entries.isEmpty)
    }

    func testTMDBEntriesKeepTheirSeasonNumbers() {
        let entry = CalendarEntry(
            itemId: "tt1", kind: .series, tmdbId: 5, title: "Show", date: first,
            releaseKind: .episode, seasonNumber: 2, episodeNumber: 6
        )
        XCTAssertFalse(entry.isFromAniList)
        XCTAssertEqual(entry.episodeCode, "S2E6")
    }

    func testTheServiceLeavesAniListTitlesToAniList() async throws {
        let resolved = ResolvedIDs()
        var service = CalendarService(client: CalendarTmdb.Client(apiKey: "k", http: NoTMDB()), region: "CZ") { item in
            await resolved.add(item.id)
            return nil
        }
        service.aniList = aniList(list: [:], planning: true)
        let item = CalendarItem(id: "anilist:100", kind: .series, type: "series", name: "Show 100")

        let result = try await service.load(
            items: [item], first: first, last: last,
            manualFollowItemIDs: [], automaticFollowItemIDs: [item.sourceIdentityKey]
        )

        let asked = await resolved.ids
        XCTAssertEqual(asked, [])
        XCTAssertEqual(result.allEntries.count, 2)
        XCTAssertEqual(result.automaticFollowItems["series:-101"]?.id, "anilist:100")
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testCoveredIncludesTheSeasonBefore() {
        let decoder = JSONDecoder()
        let newSeason = try? decoder.decode(AniListMedia.self, from: Data(Self.media[400]!.utf8))
        XCTAssertEqual(newSeason.map { CalendarAniList.isCovered($0, by: [399]) }, true)
        XCTAssertEqual(newSeason.map { CalendarAniList.isCovered($0, by: [5]) }, false)
    }

    // MARK: Helpers

    private func aniList(list: [Int: String], planning: Bool) -> CalendarAniList {
        CalendarAniList(
            query: { query, variables, _ in
                let raw: Any? = variables["ids"] ?? nil
                let ids = (raw as? [Int]) ?? []
                if query.contains("airingSchedules") {
                    let items = Self.airings.filter { ids.contains($0.mediaId) }.map {
                        #"{"airingAt":\#($0.at),"episode":\#($0.episode),"mediaId":\#($0.mediaId)}"#
                    }
                    return Data(#"{"data":{"Page":{"pageInfo":{"hasNextPage":false},"airingSchedules":[\#(items.joined(separator: ","))]}}}"#.utf8)
                }
                let items = ids.compactMap { Self.media[$0] }
                return Data(#"{"data":{"Page":{"pageInfo":{"hasNextPage":false},"media":[\#(items.joined(separator: ","))]}}}"#.utf8)
            },
            listIDs: { list },
            includesPlanning: planning,
            language: .romaji,
            timeZone: utc
        )
    }

    private static func mediaJSON(_ id: Int, status: String, episodes: Int, relations: [(String, Int, String)] = []) -> String {
        let edges = relations.map { type, node, format in
            #"{"relationType":"\#(type)","node":{"id":\#(node),"type":"ANIME","format":"\#(format)","status":"FINISHED","startDate":{"year":2020}}}"#
        }
        return #"{"id":\#(id),"type":"ANIME","format":"TV","status":"\#(status)","episodes":\#(episodes),"title":{"romaji":"Show \#(id)"},"coverImage":{"large":"https://img.example/\#(id).jpg"},"relations":{"edges":[\#(edges.joined(separator: ","))]}}"#
    }
}

private actor ResolvedIDs {
    var ids: [String] = []
    func add(_ id: String) { ids.append(id) }
}

private struct NoTMDB: CalendarHTTPClient {
    func get(_ url: URL) async throws -> (Data, Int) { (Data("{}".utf8), 404) }
}
