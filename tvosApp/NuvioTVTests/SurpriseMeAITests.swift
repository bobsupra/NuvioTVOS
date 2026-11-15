import XCTest
@testable import NuvioTV

final class SurpriseMeAITests: XCTestCase {
    private func movie(_ id: String, _ name: String, year: Int? = nil, genres: [String] = []) -> NuvioMeta {
        NuvioMeta(id: id, name: name, type: "movie", year: year, genres: genres)
    }

    func testOnlyNumbersFromTheListAreAccepted() {
        let candidates = [movie("a", "Arrival"), movie("b", "Dune"), movie("c", "Heat")]
        let answer = """
        Sure! {"picks":[{"number":2,"reason":"Big sci-fi like Interstellar."},{"number":9,"reason":"made up"},{"number":2,"reason":"repeat"},{"number":1}]}
        """
        let picks = SurpriseMeAI.parse(answer, candidates: candidates)
        XCTAssertEqual(picks.map(\.meta.id), ["b", "a"])
        XCTAssertEqual(picks.first?.reason, "Big sci-fi like Interstellar.")
        XCTAssertNil(picks.last?.reason)
    }

    func testUnreadableAnswersGiveNoPicks() {
        let candidates = [movie("a", "Arrival")]
        XCTAssertTrue(SurpriseMeAI.parse("I recommend Arrival", candidates: candidates).isEmpty)
        XCTAssertTrue(SurpriseMeAI.parse("{\"picks\": \"Arrival\"}", candidates: candidates).isEmpty)
    }

    func testPromptGivesTheAIEverythingItLearnsFrom() {
        let interstellar = movie("i", "Interstellar", year: 2014)
        let history = SurpriseMeHistory(
            watched: [interstellar, interstellar],
            library: [movie("d", "Dune", year: 2021)],
            continueWatching: [movie("s", "Severance", year: 2022)]
        )
        let profile = TasteProfile.build(watched: [movie("x", "X", genres: ["Sci-Fi"])], library: [], continueWatching: [])
        let prompt = SurpriseMeAI.prompt(
            context: SurpriseMeAIContext(
                profile: profile,
                history: history,
                opened: [movie("a", "Arrival", year: 2016)],
                skipped: [movie("n", "Notebook", year: 2004)]
            ),
            candidates: [movie("b", "Blade Runner 2049", year: 2017, genres: ["Sci-Fi", "Drama"])],
            language: "Spanish"
        )
        XCTAssertTrue(prompt.contains("Sci-Fi 100%"))
        XCTAssertTrue(prompt.contains("Watched (most recent first): Interstellar (2014)."))
        XCTAssertTrue(prompt.contains("Saved to watch later: Dune (2021)."))
        XCTAssertTrue(prompt.contains("Watching now: Severance (2022)."))
        XCTAssertTrue(prompt.contains("they opened: Arrival (2016)."))
        XCTAssertTrue(prompt.contains("they skipped (avoid similar ones): Notebook (2004)."))
        XCTAssertTrue(prompt.contains("1. Blade Runner 2049 (2017) — Sci-Fi, Drama"))
        XCTAssertTrue(prompt.contains("in Spanish"))
    }

    func testReadsTheAIsOwnSuggestions() {
        let answer = """
        {"picks":[],"others":[{"title":"Contact","year":1997,"reason":"Like Arrival."},{"title":" "},{"title":"contact","year":1997}]}
        """
        XCTAssertEqual(
            SurpriseMeAI.parseOthers(answer),
            [SurpriseMeAISuggestion(title: "Contact", year: 1997, reason: "Like Arrival.")]
        )
        XCTAssertTrue(SurpriseMeAI.parseOthers(#"{"picks":[]}"#).isEmpty)
    }

    func testRequestsUseEachProvidersFormat() throws {
        let gemini = try XCTUnwrap(SurpriseMeAI.request(
            for: "hi", configuration: SurpriseMeAIConfiguration(provider: .gemini, apiKey: "k", model: "gemini-3.6-flash")
        ))
        XCTAssertEqual(gemini.url?.host, "generativelanguage.googleapis.com")
        XCTAssertEqual(gemini.value(forHTTPHeaderField: "x-goog-api-key"), "k")

        let deepSeek = try XCTUnwrap(SurpriseMeAI.request(
            for: "hi", configuration: SurpriseMeAIConfiguration(provider: .deepSeek, apiKey: "k", model: "deepseek-chat")
        ))
        XCTAssertEqual(deepSeek.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(deepSeek.value(forHTTPHeaderField: "Authorization"), "Bearer k")

        XCTAssertNil(SurpriseMeAI.request(
            for: "hi", configuration: SurpriseMeAIConfiguration(provider: .off, apiKey: "", model: "")
        ))
    }

    func testReadsTheAnswerTextFromEachProvider() {
        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"{\"picks\":[]}"}]}}]}"#
        XCTAssertEqual(SurpriseMeAI.responseText(from: Data(gemini.utf8), provider: .gemini), #"{"picks":[]}"#)
        let chat = #"{"choices":[{"message":{"content":"{\"picks\":[]}"}}]}"#
        XCTAssertEqual(SurpriseMeAI.responseText(from: Data(chat.utf8), provider: .deepSeek), #"{"picks":[]}"#)
    }

    func testHistoryMatchesATitleUnderAnotherId() {
        let watched = NuvioMeta(id: "tt1375666", name: "Inception", imdbId: "tt1375666", tmdbId: 27205, type: "movie", year: 2010)
        let history = SurpriseMeHistory(watched: [watched], library: [], continueWatching: [])
        XCTAssertTrue(history.contains(NuvioMeta(id: "tmdb:27205", name: "Inception", tmdbId: 27205, type: "movie")))
        XCTAssertTrue(history.contains(NuvioMeta(id: "tmdb:1", name: "Inception", type: "movie", year: 2010)))
        XCTAssertFalse(history.contains(NuvioMeta(id: "tmdb:2", name: "Inception", type: "movie", year: 1990)))
    }

    func testLibrariesFromSeveralServicesCountEachTitleOnce() {
        let trakt = NuvioMeta(id: "tt1375666", name: "Inception", imdbId: "tt1375666", type: "movie", year: 2010)
        let simkl = NuvioMeta(id: "tmdb:27205", name: "Inception", imdbId: "tt1375666", tmdbId: 27205, type: "movie", year: 2010)
        let mdblist = NuvioMeta(id: "tmdb:27205", name: "Inception", tmdbId: 27205, type: "movie")
        let other = NuvioMeta(id: "tt0816692", name: "Interstellar", type: "movie", year: 2014)
        let unique = SurpriseMeHistory.unique([trakt, simkl, mdblist, other])
        XCTAssertEqual(unique.map(\.id), ["tt1375666", "tt0816692"])

        let history = SurpriseMeHistory(watched: [], library: [trakt, simkl, mdblist, other], continueWatching: [])
        XCTAssertEqual(history.titleCount, 2)
    }

    func testAnEntryWithBothIdsJoinsTwoEarlierEntries() {
        // Different names (a localized title), so only the ids link them.
        let fromTrakt = NuvioMeta(id: "tt1375666", name: "Inception", imdbId: "tt1375666", type: "movie", year: 2010)
        let fromSimkl = NuvioMeta(id: "tmdb:27205", name: "El origen", tmdbId: 27205, type: "movie", year: 2010)
        let both = NuvioMeta(id: "x", name: "Origen", imdbId: "tt1375666", tmdbId: 27205, type: "movie")
        let other = NuvioMeta(id: "tt0816692", name: "Interstellar", type: "movie", year: 2014)
        XCTAssertEqual(SurpriseMeHistory.unique([fromTrakt, fromSimkl, other, both]).map(\.id), ["tt1375666", "tt0816692"])
        XCTAssertEqual(SurpriseMeHistory(watched: [fromTrakt, fromSimkl, other, both], library: [], continueWatching: []).titleCount, 2)
    }

    func testScienceFictionAndSciFiAreTheSameGenre() {
        XCTAssertEqual(TasteProfile.normalized("Science Fiction"), TasteProfile.normalized("Sci-Fi"))
        XCTAssertEqual(TmdbDetailsService.surpriseMeGenreID(for: "Science Fiction"), 878)
    }
}
