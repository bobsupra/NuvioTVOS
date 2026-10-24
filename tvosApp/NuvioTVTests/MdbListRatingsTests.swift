import Foundation
import XCTest
@testable import NuvioTV

/// MDBList ratings: one title request for every provider, a day on disk,
/// one request per title at a time, and a pause after the daily limit.
final class MdbListRatingsTests: XCTestCase {
    private actor Counter {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mdblist-ratings-test-\(UUID().uuidString).json")
    }

    func testTitleResponseMapsEverySourceToItsBadgeScale() {
        let json = """
        {"title":"X","description":"No limit to this one","ratings":[
          {"source":"imdb","value":7.4,"score":74,"votes":1000,"url":"tt1"},
          {"source":"metacritic","value":0,"score":null},
          {"source":"trakt","value":76,"score":76},
          {"source":"tomatoes","value":85,"score":85},
          {"source":"popcorn","value":90,"score":90},
          {"source":"tmdb","value":74,"score":74,"url":550},
          {"source":"letterboxd","value":3.9,"score":78},
          {"source":"rogerebert","value":3.5,"score":70},
          {"source":"myanimelist","value":8.71,"score":87},
          {"source":"tvdb","value":null},
          {"source":"imdb","value":1.0}
        ]}
        """
        let result = MdbListDetailsService.titleResult(status: 200, data: Data(json.utf8))
        XCTAssertEqual(result, .ratings([
            MdbListDetailsService.providerIMDb: 7.4,
            MdbListDetailsService.providerTrakt: 76,
            MdbListDetailsService.providerTomatoes: 85,
            MdbListDetailsService.providerAudience: 90,
            MdbListDetailsService.providerTMDB: 74,
            MdbListDetailsService.providerLetterboxd: 3.9,
            MdbListDetailsService.providerMyAnimeList: 8.71,
        ]))
    }

    func testTitleResponseValuesOffTheScaleAreDropped() {
        let json = #"{"ratings":[{"source":"imdb","value":74},{"source":"letterboxd","value":4.2},{"source":"tomatoes","value":120}]}"#
        XCTAssertEqual(
            MdbListDetailsService.titleResult(status: 200, data: Data(json.utf8)),
            .ratings([MdbListDetailsService.providerLetterboxd: 4.2])
        )
    }

    func testTitleResponseStatuses() {
        func result(_ status: Int, _ body: String) -> MdbListDetailsService.TitleResult {
            MdbListDetailsService.titleResult(status: status, data: Data(body.utf8))
        }
        XCTAssertEqual(result(429, ""), .limitReached)
        XCTAssertEqual(result(403, #"{"error":"API Limit Reached!"}"#), .limitReached)
        XCTAssertEqual(result(200, #"{"error":"API limit reached"}"#), .limitReached)
        XCTAssertEqual(result(404, #"{"error":"Item not found"}"#), .notFound)
        XCTAssertEqual(result(200, #"{"error":"Item not found"}"#), .notFound)
        XCTAssertEqual(result(401, #"{"error":"Invalid API key"}"#), .failed)
        XCTAssertEqual(result(200, #"{"error":"Invalid API key"}"#), .failed)
        XCTAssertEqual(result(500, "oops"), .failed)
        XCTAssertEqual(result(200, "<html>"), .failed)
        XCTAssertEqual(result(200, #"{"title":"X"}"#), .ratings([:]))
    }

    func testFreshness() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let rated = ["imdb": 7.0]
        XCTAssertTrue(MdbListRatingsStore.isFresh(.init(storedAt: now - 23 * 3600, ratings: rated), now: now))
        XCTAssertFalse(MdbListRatingsStore.isFresh(.init(storedAt: now - 25 * 3600, ratings: rated), now: now))
        XCTAssertTrue(MdbListRatingsStore.isFresh(.init(storedAt: now - 5 * 3600, ratings: [:]), now: now))
        XCTAssertFalse(MdbListRatingsStore.isFresh(.init(storedAt: now - 7 * 3600, ratings: [:]), now: now))
        XCTAssertFalse(MdbListRatingsStore.isFresh(.init(storedAt: now + 60, ratings: rated), now: now))
    }

    func testOneRequestPerTitleThenFromTheStore() async {
        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let counter = Counter()
        let store = MdbListRatingsStore(fileURL: url)
        let request: @Sendable () async -> MdbListDetailsService.TitleResult = {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(100))
            return .ratings(["imdb": 7.4, "myanimelist": 8.7])
        }
        // The hero and Details asking at once share one request.
        async let first = store.ratings(imdbID: "tt1", mediaType: "show", apiKey: "k", request: request)
        async let second = store.ratings(imdbID: "tt1", mediaType: "show", apiKey: "k", request: request)
        let (a, b) = await (first, second)
        XCTAssertEqual(a, ["imdb": 7.4, "myanimelist": 8.7])
        XCTAssertEqual(b, a)
        let third = await store.ratings(imdbID: "tt1", mediaType: "show", apiKey: "k", request: request)
        XCTAssertEqual(third, a)
        let count = await counter.count
        XCTAssertEqual(count, 1)

        // Kept on disk: a new store (the next app start) doesn't ask again.
        await store.flushToDisk()
        let reopened = MdbListRatingsStore(fileURL: url)
        let fromDisk = await reopened.ratings(imdbID: "tt1", mediaType: "show", apiKey: "k", request: request)
        XCTAssertEqual(fromDisk, a)
        let countAfterReopen = await counter.count
        XCTAssertEqual(countAfterReopen, 1)
    }

    func testUnknownTitleIsRememberedAsEmpty() async {
        let counter = Counter()
        let store = MdbListRatingsStore(fileURL: nil)
        let request: @Sendable () async -> MdbListDetailsService.TitleResult = {
            await counter.increment()
            return .notFound
        }
        let first = await store.ratings(imdbID: "tt2", mediaType: "movie", apiKey: "k", request: request)
        let second = await store.ratings(imdbID: "tt2", mediaType: "movie", apiKey: "k", request: request)
        XCTAssertEqual(first, [:])
        XCTAssertEqual(second, [:])
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testDailyLimitPausesRequests() async {
        let counter = Counter()
        let store = MdbListRatingsStore(fileURL: nil)
        let limited: @Sendable () async -> MdbListDetailsService.TitleResult = {
            await counter.increment()
            return .limitReached
        }
        let first = await store.ratings(imdbID: "tt3", mediaType: "movie", apiKey: "k", request: limited)
        XCTAssertNil(first)
        // Other titles aren't requested either while paused.
        let other = await store.ratings(imdbID: "tt4", mediaType: "movie", apiKey: "k", request: limited)
        XCTAssertNil(other)
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }

    func testFailureIsNotRemembered() async {
        let counter = Counter()
        let store = MdbListRatingsStore(fileURL: nil)
        let failing: @Sendable () async -> MdbListDetailsService.TitleResult = {
            await counter.increment()
            return .failed
        }
        _ = await store.ratings(imdbID: "tt5", mediaType: "movie", apiKey: "k", request: failing)
        _ = await store.ratings(imdbID: "tt5", mediaType: "movie", apiKey: "k", request: failing)
        let count = await counter.count
        XCTAssertEqual(count, 2)
        let entry = await store.entry(for: "tt5", mediaType: "movie")
        XCTAssertNil(entry)
    }
}
