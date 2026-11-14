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

    func testPromptListsCandidatesWithNumbersAndYears() {
        let prompt = SurpriseMeAI.prompt(
            profile: TasteProfile(weights: ["scifi": 1], topGenres: ["Sci-Fi"]),
            recentTitles: [movie("i", "Interstellar", year: 2014)],
            candidates: [movie("a", "Arrival", year: 2016, genres: ["Sci-Fi", "Drama"])],
            language: "Spanish"
        )
        XCTAssertTrue(prompt.contains("1. Arrival (2016) — Sci-Fi, Drama"))
        XCTAssertTrue(prompt.contains("Interstellar (2014)"))
        XCTAssertTrue(prompt.contains("in Spanish"))
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

    func testScienceFictionAndSciFiAreTheSameGenre() {
        XCTAssertEqual(TasteProfile.normalized("Science Fiction"), TasteProfile.normalized("Sci-Fi"))
        XCTAssertEqual(TmdbDetailsService.surpriseMeGenreID(for: "Science Fiction"), 878)
    }
}
