//
//  HeroRatingsTests.swift
//  NuvioTVTests
//
//  The Home hero "All" ratings row and its shared ratings cache.
//

import XCTest
@testable import NuvioTV

final class HeroRatingsTests: XCTestCase {

    func testAllSourceAlwaysNeedsFetchedRatings() {
        let meta = NuvioMeta(id: "tt0001", name: "A", type: "movie", rating: 7.1)
        XCTAssertTrue(AddonRatingsService.heroShowsAllRatings("all"))
        XCTAssertTrue(AddonRatingsService.heroShowsAllRatings(" ALL "))
        XCTAssertFalse(AddonRatingsService.heroShowsAllRatings("imdb"))
        XCTAssertTrue(AddonRatingsService.heroNeedsFetchedRatings(source: "all", meta: meta))
        XCTAssertFalse(AddonRatingsService.heroNeedsFetchedRatings(source: "imdb", meta: meta))
        XCTAssertTrue(AddonRatingsService.heroNeedsFetchedRatings(source: "tmdb", meta: meta))
    }

    func testDisplayRatingsMergeFetchedCatalogAndImdbFallback() {
        let meta = NuvioMeta(
            id: "tt0002-\(UUID().uuidString)",
            name: "B",
            type: "movie",
            rating: 7.4,
            externalRatings: [NuvioExternalRating(source: "tmdb", value: 70)]
        )
        let fetched = [
            NuvioExternalRating(source: "tmdb", value: 81),
            NuvioExternalRating(source: "csfd", value: 86, name: "ČSFD", max: 100)
        ]

        let ratings = AddonRatingsService.heroDisplayRatings(for: meta, fetched: fetched)

        XCTAssertEqual(ratings.map(\.source), ["tmdb", "csfd", "imdb"])
        XCTAssertEqual(ratings.first?.value, 81, "fetched scores win over the catalog's")
        XCTAssertEqual(ratings.last?.value, 7.4, "catalog IMDb score fills in")
    }

    func testDisplayRatingsWithoutAnythingIsEmpty() {
        let meta = NuvioMeta(id: "tt0003-\(UUID().uuidString)", name: "C", type: "movie", rating: nil)
        XCTAssertTrue(AddonRatingsService.heroDisplayRatings(for: meta, fetched: nil).isEmpty)
    }

    func testBadgesKeepBuiltInsAndAddonSources() {
        let badges = TvRatingBadge.badges(from: [
            NuvioExternalRating(source: "csfd", value: 86, name: "ČSFD", max: 100),
            NuvioExternalRating(source: "imdb", value: 7.4),
            NuvioExternalRating(source: "mal", value: 8.1)
        ])
        let sources = badges.map(\.visual.source)
        XCTAssertTrue(sources.contains("imdb"))
        XCTAssertTrue(sources.contains("myanimelist"), "MAL maps onto the MyAnimeList badge")
        XCTAssertTrue(sources.contains("csfd"))
        XCTAssertEqual(badges.first { $0.visual.source == "imdb" }?.formattedValue, "7.4")
        XCTAssertEqual(badges.first { $0.visual.source == "csfd" }?.formattedValue, "86%")
    }

    func testCacheStoresAndReadsSynchronously() {
        let meta = NuvioMeta(id: "tt0004-\(UUID().uuidString)", name: "D", type: "movie", rating: 6.0)
        XCTAssertNil(AddonRatingsService.cachedHomeHeroRatings(for: meta))
        AddonRatingsService.storeHomeHeroRatings(
            [NuvioExternalRating(source: "imdb", value: 6.0), NuvioExternalRating(source: "IMDB", value: 9.9)],
            for: meta
        )
        let cached = AddonRatingsService.cachedHomeHeroRatings(for: meta)
        XCTAssertEqual(cached?.count, 1, "duplicate sources are dropped")
        XCTAssertEqual(cached?.first?.value, 6.0)
    }

    func testConcurrentLoadsShareOneFetch() async {
        let cache = HomeHeroRatingsCache.shared
        let key = "load-\(UUID().uuidString)"
        let counter = FetchCounter()

        let fetch: @Sendable () async -> [NuvioExternalRating] = {
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(400))
            return [NuvioExternalRating(source: "imdb", value: 8.0)]
        }
        let first = Task { await cache.load(key: key, fetch: fetch) }
        // Let the first request register before the second one asks.
        try? await Task.sleep(for: .milliseconds(100))
        let second = Task { await cache.load(key: key, fetch: fetch) }
        let a = await first.value
        let b = await second.value

        let calls = await counter.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(a, b)
        XCTAssertEqual(cache.cachedRatings(for: key), a)
    }
}

private actor FetchCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
