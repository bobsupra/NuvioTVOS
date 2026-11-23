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

    func testBatchResultParsesIDFormatsFiltersInvalidAndDetectsRateLimits() {
        let json = """
        [
          {"imdb_id":"tt100","ratings":[{"source":"imdb","value":8.1},{"source":"tomatoes","value":92}]},
          {"imdbid":"tt101","ratings":[{"source":"popcorn","value":88}]},
          {"ids":{"imdb":"tt102","tmdb":550},"ratings":[{"source":"letterboxd","value":4.1},{"source":"imdb","value":99}]},
          {"imdb_id":"tt103","error":"Item not found"}
        ]
        """
        XCTAssertEqual(
            MdbListDetailsService.batchResult(status: 200, data: Data(json.utf8)),
            .items([
                "tt100": [MdbListDetailsService.providerIMDb: 8.1, MdbListDetailsService.providerTomatoes: 92],
                "tt101": [MdbListDetailsService.providerAudience: 88],
                "tt102": [MdbListDetailsService.providerLetterboxd: 4.1]
            ])
        )
        XCTAssertEqual(MdbListDetailsService.batchResult(status: 429, data: Data()), .limitReached)
        XCTAssertEqual(
            MdbListDetailsService.batchResult(status: 200, data: Data(#"{"error":"API Limit Reached!"}"#.utf8)),
            .limitReached
        )
        XCTAssertEqual(
            MdbListDetailsService.batchResult(status: 200, data: Data(#"{"error":"Invalid API key"}"#.utf8)),
            .failed
        )
        let transientErrorJson = """
        [
          {"imdb_id":"tt100","ratings":[{"source":"imdb","value":8.1}]},
          {"imdb_id":"tt104","error":"Internal server error"}
        ]
        """
        XCTAssertEqual(
            MdbListDetailsService.batchResult(status: 200, data: Data(transientErrorJson.utf8)),
            .failed
        )
        XCTAssertEqual(MdbListDetailsService.batchResult(status: 500, data: Data("err".utf8)), .failed)
    }

    func testPrefetchBatchGroupsByTypeChunksAt200SharesInflightAndPersists() async {
        actor BatchRecorder {
            var batches: [(mediaType: String, ids: [String])] = []
            var singleCalls = 0
            func recordBatch(ids: [String], mediaType: String) {
                batches.append((mediaType, ids))
            }
            func recordSingle() { singleCalls += 1 }
        }

        let url = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = BatchRecorder()
        let store = MdbListRatingsStore(
            fileURL: url,
            batchWindowNanoseconds: 20_000_000,
            singleRequest: { id, _, _ in
                await recorder.recordSingle()
                return .ratings(["imdb": id == "tt900" ? 7.9 : 6.0])
            },
            batchRequest: { ids, mediaType, _ in
                await recorder.recordBatch(ids: ids, mediaType: mediaType)
                try? await Task.sleep(for: .milliseconds(30))
                var items: [String: [String: Double]] = [:]
                for id in ids where id != "ttMissing" {
                    items[id] = ["imdb": 7.5]
                }
                return .items(items)
            }
        )

        var targets: [(imdbID: String, mediaType: String)] = (1...205).map { ("ttM\($0)", "movie") }
        targets.append(("ttMissing", "movie"))
        targets.append(("ttS1", "show"))
        targets.append(("ttS2", "show"))
        // Duplicate entries must be deduplicated cleanly.
        targets.append(("ttM1", "movie"))

        // Concurrent ratings lookup shares the in-flight batch chunk cleanly.
        async let batchDone: Void = store.prefetchBatch(titles: targets, apiKey: "k")
        try? await Task.sleep(for: .milliseconds(10))
        async let sharedLookup = store.ratings(imdbID: "ttM1", mediaType: "movie", apiKey: "k")
        _ = await batchDone
        let lookupResult = await sharedLookup
        XCTAssertEqual(lookupResult, ["imdb": 7.5])

        let recordedBatches = await recorder.batches
        let recordedSingles = await recorder.singleCalls
        XCTAssertEqual(recordedSingles, 0)
        // 206 unique movies -> chunks of 200 + 6; 2 shows -> 1 chunk of 2.
        XCTAssertEqual(recordedBatches.map { ($0.mediaType, $0.ids.count) }.map { "\($0.0):\($0.1)" }, [
            "movie:200",
            "movie:6",
            "show:2"
        ])

        // Missing item in a 200 batch is remembered as empty (`notFound`).
        let missing = await store.ratings(imdbID: "ttMissing", mediaType: "movie", apiKey: "k")
        XCTAssertEqual(missing, [:])
        let batchCountAfterCachedChecks = await recorder.batches.count
        XCTAssertEqual(batchCountAfterCachedChecks, 3)

        // Persisted across reopen.
        await store.flushToDisk()
        let reopened = MdbListRatingsStore(fileURL: url)
        let persisted = await reopened.ratings(imdbID: "ttM205", mediaType: "movie", apiKey: "k")
        XCTAssertEqual(persisted, ["imdb": 7.5])
    }

    func testConcurrentSingleLookupsCoalesceIntoOneBatchRequest() async {
        actor BatchRecorder {
            var batchSizes: [Int] = []
            var singles = 0
            func addBatch(_ count: Int) { batchSizes.append(count) }
            func addSingle() { singles += 1 }
        }

        let recorder = BatchRecorder()
        let store = MdbListRatingsStore(
            fileURL: nil,
            batchWindowNanoseconds: 40_000_000,
            singleRequest: { _, _, _ in
                await recorder.addSingle()
                return .ratings(["imdb": 6.5])
            },
            batchRequest: { ids, _, _ in
                await recorder.addBatch(ids.count)
                var result: [String: [String: Double]] = [:]
                for id in ids { result[id] = ["imdb": 8.0] }
                return .items(result)
            }
        )

        async let first = store.ratings(imdbID: "tt10", mediaType: "movie", apiKey: "k")
        async let second = store.ratings(imdbID: "tt11", mediaType: "movie", apiKey: "k")
        async let third = store.ratings(imdbID: "tt12", mediaType: "movie", apiKey: "k")
        let (r1, r2, r3) = await (first, second, third)

        XCTAssertEqual(r1, ["imdb": 8.0])
        XCTAssertEqual(r2, ["imdb": 8.0])
        XCTAssertEqual(r3, ["imdb": 8.0])
        let batches = await recorder.batchSizes
        let singles = await recorder.singles
        XCTAssertEqual(batches, [3])
        XCTAssertEqual(singles, 0)
    }

    func testPrefetchBatchStopsRemainingChunksAfterDailyLimit() async {
        actor LimitCounter {
            var count = 0
            func increment() { count += 1 }
        }

        let counter = LimitCounter()
        let store = MdbListRatingsStore(
            fileURL: nil,
            batchRequest: { _, _, _ in
                await counter.increment()
                return .limitReached
            }
        )

        // 205 movies would normally take 2 chunks, plus 1 show chunk.
        // Hitting `.limitReached` on the first chunk must halt remaining chunks.
        let targets = (1...205).map { ("ttL\($0)", "movie") } + [("ttLS1", "show")]
        await store.prefetchBatch(titles: targets, apiKey: "k")
        let calls = await counter.count
        XCTAssertEqual(calls, 1)

        // Subsequent lookup while paused returns nil without calling network.
        let subsequent = await store.ratings(imdbID: "ttL205", mediaType: "movie", apiKey: "k")
        XCTAssertNil(subsequent)
        let callsAfter = await counter.count
        XCTAssertEqual(callsAfter, 1)
    }
}
