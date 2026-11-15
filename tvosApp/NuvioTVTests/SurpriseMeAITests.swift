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
        let arrival = movie("a", "Arrival", year: 2016)
        let history = SurpriseMeHistory(
            watched: [interstellar, interstellar, arrival],
            library: [movie("d", "Dune", year: 2021)],
            continueWatching: [movie("s", "Severance", year: 2022)]
        )
        var feedback = SurpriseMeFeedback()
        feedback.record(movie("n", "Notebook", year: 2004), .skipped)
        feedback.record(arrival, .liked)
        let profile = TasteProfile.build(watched: [movie("x", "X", genres: ["Sci-Fi"])], library: [], continueWatching: [])
        let prompt = SurpriseMeAI.prompt(
            context: SurpriseMeAIContext(profile: profile, history: history, feedback: feedback),
            candidates: [movie("b", "Blade Runner 2049", year: 2017, genres: ["Sci-Fi", "Drama"])],
            language: "Spanish"
        )
        XCTAssertTrue(prompt.contains("Sci-Fi 100%"))
        XCTAssertTrue(prompt.contains("Watched (most recent first): Interstellar (2014); Arrival (2016)."))
        XCTAssertTrue(prompt.contains("Saved to watch later: Dune (2021)."))
        XCTAssertTrue(prompt.contains("Watching now: Severance (2022)."))
        XCTAssertTrue(prompt.contains("then watched (loved): Arrival (2016)."))
        XCTAssertTrue(prompt.contains("they opened (liked): Arrival (2016)."))
        XCTAssertTrue(prompt.contains("they skipped (avoid similar ones): Notebook (2004)."))
        XCTAssertTrue(prompt.contains("1. Blade Runner 2049 (2017) [movie] — Sci-Fi, Drama"))
        XCTAssertTrue(prompt.contains("in Spanish"))
        // The AI suggests first; the list comes second.
        let own = try? XCTUnwrap(prompt.range(of: "1. Suggest the 10 real titles"))
        let list = try? XCTUnwrap(prompt.range(of: "2. Then choose up to 3"))
        XCTAssertNotNil(own)
        XCTAssertNotNil(list)
        if let own, let list { XCTAssertLessThan(own.lowerBound, list.lowerBound) }
    }

    func testTheAIsOwnPicksComeFirstWithAListPickAfterEveryFour() {
        let own = (1...6).map { SurpriseMeAIPick(meta: movie("o\($0)", "Own \($0)"), reason: nil) }
        let list = (1...3).map { SurpriseMeAIPick(meta: movie("l\($0)", "List \($0)"), reason: nil) }
        XCTAssertEqual(
            SurpriseMeAI.merge(own: own, list: list).map(\.meta.id),
            ["o1", "o2", "o3", "o4", "l1", "o5", "o6", "l2", "l3"]
        )
        let repeated = SurpriseMeAIPick(meta: movie("o1", "Own 1"), reason: nil)
        XCTAssertEqual(SurpriseMeAI.merge(own: [own[0]], list: [repeated]).map(\.meta.id), ["o1"])
    }

    func testFeedbackKeepsTheLatestVerdictPerTitle() {
        var feedback = SurpriseMeFeedback()
        let arrival = movie("a", "Arrival", year: 2016, genres: ["Sci-Fi"])
        feedback.record(arrival, .skipped)
        feedback.record(arrival, .liked)
        XCTAssertEqual(feedback.entries.count, 1)
        XCTAssertEqual(feedback.verdict(for: arrival), .liked)
        for index in 0..<(SurpriseMeFeedback.maxEntries + 10) {
            feedback.record(movie("m\(index)", "M\(index)"), .skipped)
        }
        XCTAssertEqual(feedback.entries.count, SurpriseMeFeedback.maxEntries)
    }

    func testTheTasteProfileLearnsFromReactions() {
        let watched = [movie("w1", "W1", genres: ["Comedy"]), movie("w2", "W2", genres: ["Horror"])]
        var feedback = SurpriseMeFeedback()
        feedback.record(movie("l", "Liked", genres: ["Comedy"]), .liked)
        feedback.record(movie("s", "Skipped", genres: ["Horror"]), .skipped)
        let before = TasteProfile.build(watched: watched, library: [], continueWatching: [])
        let after = TasteProfile.build(watched: watched, library: [], continueWatching: [], feedback: feedback)
        XCTAssertEqual(before.weights["comedy"], before.weights["horror"])
        XCTAssertGreaterThan(after.weights["comedy"] ?? 0, after.weights["horror"] ?? 0)
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

    func testTheAIsSuggestionsKeepTheirKindAndUnwantedKindsAreDropped() {
        let answer = """
        {"others":[{"title":"Severance","year":2022,"type":"series"},{"title":"Contact","year":1997,"type":"movie"},{"title":"Heat","year":1995}]}
        """
        XCTAssertEqual(SurpriseMeAI.parseOthers(answer).map(\.isSeries), [true, false, false])
        XCTAssertEqual(SurpriseMeAI.parseOthers(answer, content: .movies).map(\.title), ["Contact", "Heat"])
        // Without a type, a series-only request counts it as a series.
        XCTAssertEqual(SurpriseMeAI.parseOthers(answer, content: .series).map(\.title), ["Severance", "Heat"])
    }

    func testThePromptAsksForTheMixTheViewerWatches() {
        let show = NuvioMeta(id: "s", name: "Severance", type: "series", genres: ["Drama"])
        let profile = TasteProfile.build(
            watched: [show, NuvioMeta(id: "s2", name: "Lost", type: "series", genres: ["Drama"]),
                      NuvioMeta(id: "s3", name: "Dark", type: "series", genres: ["Drama"]), movie("m", "Heat", genres: ["Drama"])],
            library: [],
            continueWatching: []
        )
        let history = SurpriseMeHistory(watched: [show], library: [], continueWatching: [])
        let both = SurpriseMeAI.prompt(
            context: SurpriseMeAIContext(profile: profile, history: history), candidates: [show], language: "English"
        )
        XCTAssertTrue(both.contains("You recommend movies and series"))
        XCTAssertTrue(both.contains("Series are 75% of what they watch"))
        XCTAssertTrue(both.contains("1. Severance [series] — Drama"))
        let moviesOnly = SurpriseMeAI.prompt(
            context: SurpriseMeAIContext(profile: profile, history: history, content: .movies), candidates: [], language: "English"
        )
        XCTAssertTrue(moviesOnly.contains("Only movies, no series."))
    }

    func testOldFeedbackWithoutATypeReadsAsMovies() throws {
        let json = #"[{"id":"a","title":"Arrival","year":2016,"genres":["Sci-Fi"],"verdict":"liked","date":0}]"#
        let entries = try JSONDecoder().decode([SurpriseMeFeedbackEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.first?.meta.type, "movie")
        var feedback = SurpriseMeFeedback()
        feedback.record(NuvioMeta(id: "s", name: "Severance", type: "series"), .liked)
        XCTAssertEqual(feedback.liked.first?.type, "series")
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

    func testOnlyListedModelsAreUsed() {
        XCTAssertEqual(SurpriseMeAIConfiguration.normalizedModel("gemini-3.8-flash", for: .gemini), "gemini-3.8-flash")
        XCTAssertEqual(SurpriseMeAIConfiguration.normalizedModel("deepseek-chat", for: .deepSeek), "deepseek-flash")
        XCTAssertEqual(SurpriseMeAIConfiguration.normalizedModel(nil, for: .openRouter), "qwen/qwen3.7-flash")
        XCTAssertEqual(SurpriseMeAIConfiguration.normalizedModel(" ", for: .gemini), "gemini-3.6-flash")
        for provider in SurpriseMeAIProvider.allCases where provider != .off {
            XCTAssertEqual(provider.defaultModel, provider.suggestedModels.first?.id)
        }
    }
}
