import XCTest
@testable import NuvioTV

final class AIHomeCatalogsTests: XCTestCase {
    private func meta(_ id: String, _ name: String, type: String = "movie", year: Int? = nil) -> NuvioMeta {
        NuvioMeta(id: id, name: name, type: type, year: year)
    }

    func testParsesTitlesAndKeepsTheAIsOrderWithoutRepeats() {
        let answer = """
        {"titles":[{"title":"Arrival","year":2016},{"title":"arrival","year":2016},{"title":" "},{"title":"Contact","year":1997}]}
        """
        let titles = AIHomeCatalogs.parse(answer, kind: .movies)
        XCTAssertEqual(titles.map(\.title), ["Arrival", "Contact"])
        XCTAssertTrue(titles.allSatisfy(\.isFilm))
    }

    func testEachKindIsLookedUpAsAFilmOrASeries() {
        let answer = #"{"titles":[{"title":"Spirited Away","year":2001},{"title":"Frieren","year":2023}]}"#
        XCTAssertEqual(AIHomeCatalogs.parse(answer, kind: .animeMovies).map(\.isFilm), [true, true])
        XCTAssertEqual(AIHomeCatalogs.parse(answer, kind: .animeSeries).map(\.isFilm), [false, false])
        XCTAssertEqual(AIHomeCatalogs.parse(answer, kind: .series).map(\.isFilm), [false, false])
        XCTAssertEqual(AIHomeCatalogKind.animeMovies.contentType, "movie")
        XCTAssertEqual(AIHomeCatalogKind.animeSeries.contentType, "series")
    }

    func testAtMost40TitlesAreTakenFromTheAnswer() {
        let titles = (1...60).map { #"{"title":"T\#($0)","year":2000}"# }.joined(separator: ",")
        XCTAssertEqual(AIHomeCatalogs.parse(#"{"titles":[\#(titles)]}"#, kind: .movies).count, AIHomeCatalogs.requestedCount)
    }

    func testRowsAreRebuiltDailyOrWhenTheHistoryMovesOn() {
        let now = Date()
        let cache = AIHomeCatalogCache(
            rows: [.init(kind: .movies, items: [])],
            builtAt: now.addingTimeInterval(-3600),
            historyCount: 100,
            provider: "Gemini"
        )
        XCTAssertFalse(AIHomeCatalogs.needsRebuild(cache: cache, kinds: [.movies], historyCount: 105, provider: "Gemini", now: now))
        XCTAssertTrue(AIHomeCatalogs.needsRebuild(cache: cache, kinds: [.movies], historyCount: 110, provider: "Gemini", now: now))
        XCTAssertTrue(AIHomeCatalogs.needsRebuild(cache: cache, kinds: [.movies, .animeSeries], historyCount: 100, provider: "Gemini", now: now))
        XCTAssertTrue(AIHomeCatalogs.needsRebuild(cache: cache, kinds: [.movies], historyCount: 100, provider: "DeepSeek", now: now))
        XCTAssertTrue(AIHomeCatalogs.needsRebuild(
            cache: cache, kinds: [.movies], historyCount: 100, provider: "Gemini", now: now.addingTimeInterval(24 * 3600)
        ))
        XCTAssertTrue(AIHomeCatalogs.needsRebuild(cache: nil, kinds: [.movies], historyCount: 0, provider: "Gemini", now: now))
        XCTAssertFalse(AIHomeCatalogs.needsRebuild(cache: nil, kinds: [], historyCount: 0, provider: "Gemini", now: now))
    }

    func testSectionsFollowTheKindsTurnedOnAndDropWatchedTitles() {
        let cache = AIHomeCatalogCache(
            rows: [
                .init(kind: .animeSeries, items: [meta("tmdb:1", "Frieren", type: "series")]),
                .init(kind: .movies, items: [meta("tmdb:2", "Arrival"), meta("tmdb:3", "Contact")]),
            ],
            builtAt: Date(),
            historyCount: 0,
            provider: "Gemini"
        )
        let sections = AIHomeCatalogs.sections(from: cache, kinds: [.movies, .animeSeries]) { $0.id == "tmdb:3" }
        XCTAssertEqual(sections.map(\.id), ["ai_for_you_movies", "ai_for_you_animeSeries"])
        XCTAssertEqual(sections.first?.items.map(\.id), ["tmdb:2"])
        XCTAssertTrue(sections.allSatisfy { AIHomeCatalogs.isSectionID($0.id) })
        XCTAssertTrue(AIHomeCatalogs.sections(from: cache, kinds: [.series]) { _ in false }.isEmpty)
    }

    func testPromptAsksForTheRightKindFromTheWholeHistory() {
        let history = SurpriseMeHistory(watched: [meta("tt1", "Akira", year: 1988)], library: [], continueWatching: [])
        let context = SurpriseMeAIContext(profile: .empty, history: history)
        let prompt = AIHomeCatalogs.prompt(kind: .animeMovies, context: context, excludedTitles: [], language: "Spanish")
        XCTAssertTrue(prompt.contains("Watched (most recent first): Akira (1988)."))
        XCTAssertTrue(prompt.contains("40 anime films (no series)"))
        XCTAssertFalse(prompt.contains("Choose the 5 movies"))
    }
}
