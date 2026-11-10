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
        let defaults = isolatedDefaults()
        AddonRatingsService.setRatingOrder(["tmdb", "csfd", "imdb"], defaults: defaults)
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

        let ratings = AddonRatingsService.heroDisplayRatings(for: meta, fetched: fetched, defaults: defaults)

        XCTAssertEqual(ratings.map(\.source), ["tmdb", "csfd", "imdb"])
        XCTAssertEqual(ratings.first?.value, 81, "fetched scores win over the catalog's")
        XCTAssertEqual(ratings.last?.value, 7.4, "catalog IMDb score fills in")
    }

    func testDisplayRatingsWithoutAnythingIsEmpty() {
        let meta = NuvioMeta(id: "tt0003-\(UUID().uuidString)", name: "C", type: "movie", rating: nil)
        XCTAssertTrue(AddonRatingsService.heroDisplayRatings(for: meta, fetched: nil).isEmpty)
    }

    func testEnabledProvidersAndSavedOrderFilterAllHeroRatingSources() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: SettingsKey.mdbListEnabled)
        defaults.set(false, forKey: SettingsKey.mdbListUseTmdb)
        defaults.set(false, forKey: SettingsKey.mdbListUseMyAnimeList)
        defaults.set(true, forKey: SettingsKey.aniListEnabled)
        defaults.set(true, forKey: SettingsKey.aniListScore)
        AddonRatingsService.setSourceEnabled("csfd", enabled: false, defaults: defaults)
        AddonRatingsService.setSourceEnabled("anilist", enabled: false, defaults: defaults)
        AddonRatingsService.setRatingOrder(["csfd", "tmdb", "imdb", "anilist", "myanimelist"], defaults: defaults)

        let meta = NuvioMeta(
            id: "tt0005-\(UUID().uuidString)",
            name: "E",
            type: "movie",
            rating: 7.4,
            externalRatings: [
                NuvioExternalRating(source: "tmdb", value: 8.1),
                NuvioExternalRating(source: "mal", value: 8.0),
                NuvioExternalRating(source: "csfd", value: 86, max: 100),
                NuvioExternalRating(source: "anilist", value: 84)
            ]
        )

        let ratings = AddonRatingsService.heroDisplayRatings(for: meta, fetched: nil, defaults: defaults)
        XCTAssertEqual(ratings.map(\.source), ["imdb"], "IMDb catalog data remains independent of MDBList being off")

        defaults.set(true, forKey: SettingsKey.mdbListUseMyAnimeList)
        AddonRatingsService.setSourceEnabled("anilist", enabled: true, defaults: defaults)
        let enabled = AddonRatingsService.heroDisplayRatings(for: meta, fetched: nil, defaults: defaults)
        XCTAssertEqual(enabled.map { AddonRatingsService.normalizedSourceKey($0.source) }, ["imdb", "anilist", "myanimelist"])
    }

    func testEpisodeRatingAliasesUseProviderSwitches() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: SettingsKey.malEnabled)
        defaults.set(true, forKey: SettingsKey.malEpisodeRatings)
        defaults.set(false, forKey: SettingsKey.mdbListUseMyAnimeList)
        let meta = NuvioMeta(id: "tt0006", name: "F", type: "series", rating: 7.0)

        let hidden = AddonRatingsService.heroEpisodeDisplayRatings(
            for: meta,
            video: nil,
            fetched: [MALEpisodeRatings.rating(4.5)],
            defaults: defaults
        )
        XCTAssertEqual(hidden.map(\.source), ["imdb"])

        defaults.set(true, forKey: SettingsKey.mdbListUseMyAnimeList)
        let shown = AddonRatingsService.heroEpisodeDisplayRatings(
            for: meta,
            video: nil,
            fetched: [MALEpisodeRatings.rating(4.5)],
            defaults: defaults
        )
        XCTAssertTrue(shown.contains { AddonRatingsService.normalizedSourceKey($0.source) == "myanimelist" })

        defaults.set(false, forKey: SettingsKey.malEpisodeRatings)
        let episodeSourceOff = AddonRatingsService.heroEpisodeDisplayRatings(
            for: meta,
            video: nil,
            fetched: [MALEpisodeRatings.rating(4.5)],
            defaults: defaults
        )
        XCTAssertFalse(episodeSourceOff.contains { $0.source == MALEpisodeRatings.source })
    }

    func testEpisodeRatingsFallBackToScopedTitleProvidersWhenNoEpisodeScoreIsEnabled() {
        let defaults = isolatedDefaults()
        AddonRatingsService.setRatingOrder(["tmdb", "imdb"], defaults: defaults)
        defaults.set(false, forKey: SettingsKey.mdbListUseMyAnimeList)
        defaults.set(false, forKey: SettingsKey.mdbListUseImdb)
        let meta = NuvioMeta(id: "tt0008", name: "H", type: "series", rating: 7.0)
        let titleRatings = [NuvioExternalRating(source: "tmdb", value: 76, max: 100)]

        let shown = AddonRatingsService.heroEpisodeDisplayRatings(
            for: meta,
            video: nil,
            fetched: [MALEpisodeRatings.rating(4.5)],
            fallbackRatings: titleRatings,
            defaults: defaults
        )

        XCTAssertEqual(shown.map(\.source), ["tmdb"])
    }

    func testEpisodeTmdbRatingKeepsRawServiceScaleAndNormalizesForHeroBadges() {
        let defaults = isolatedDefaults()
        let rawEpisodeRating = NuvioExternalRating(source: "tmdb", value: 7.6, max: 10)
        let meta = NuvioMeta(id: "tt0009", name: "I", type: "series")
        let heroRatings = AddonRatingsService.heroEpisodeDisplayRatings(
            for: meta,
            video: nil,
            fetched: [rawEpisodeRating],
            defaults: defaults
        )

        XCTAssertEqual(rawEpisodeRating.value, 7.6, "episode fetch consumers keep TMDB's /10 scale")
        XCTAssertEqual(heroRatings.first?.value, 76)
        XCTAssertEqual(heroRatings.first?.max, 100)
        XCTAssertEqual(TvRatingBadge.badges(from: heroRatings).first?.formattedValue, "76")
    }

    func testAddonsCannotSpoofTheBuiltInMaleEpisodeSource() {
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains(MALEpisodeRatings.source))
        XCTAssertTrue(AddonRatingsService.deduplicatedRatings([
            NuvioExternalRating(source: "\(MALEpisodeRatings.source) ", value: 4.8, max: 5),
            NuvioExternalRating(source: "imdb ", value: 9.9)
        ]).isEmpty)
    }

    func testHeroFetchRejectsAStalePrefetchProfileBeforeLoading() async {
        let defaults = isolatedDefaults()
        let meta = NuvioMeta(id: "tt0010", name: "J", type: "movie")
        let staleProfileID = "\(ProfileSettings.activeProfileID ?? "default")-stale"

        let ratings = await AddonRatingsService.fetchHeroRatings(
            for: meta,
            defaults: defaults,
            expectedProfileID: staleProfileID
        )

        XCTAssertTrue(ratings.isEmpty)
        XCTAssertNil(AddonRatingsService.cachedHeroRatings(for: meta, defaults: defaults))
    }

    func testHeroCacheIdentityChangesWithRatingConfigurationWithoutExposingApiKey() {
        let defaults = isolatedDefaults()
        let meta = NuvioMeta(id: "tt0007", name: "G", type: "movie")
        let secret = "hero-ratings-secret-\(UUID().uuidString)"
        defaults.set(secret, forKey: SettingsKey.mdbListApiKey)
        let first = AddonRatingsService.heroRatingsCacheKey(for: meta, defaults: defaults)
        XCTAssertFalse(first.contains(secret))

        defaults.set("changed-\(UUID().uuidString)", forKey: SettingsKey.mdbListApiKey)
        let changedCredential = AddonRatingsService.heroRatingsCacheKey(for: meta, defaults: defaults)
        XCTAssertNotEqual(first, changedCredential)

        AddonRatingsService.setSourceEnabled("csfd", enabled: false, defaults: defaults)
        let changedProvider = AddonRatingsService.heroRatingsCacheKey(for: meta, defaults: defaults)
        XCTAssertNotEqual(changedCredential, changedProvider)

        AddonRatingsService.setRatingOrder(["imdb", "csfd"], defaults: defaults)
        let changedOrder = AddonRatingsService.heroRatingsCacheKey(for: meta, defaults: defaults)
        XCTAssertNotEqual(changedProvider, changedOrder)
        XCTAssertFalse(changedOrder.contains("changed-"))
        XCTAssertNotEqual(
            AddonRatingsService.heroEpisodeRatingsCacheKey(for: "tt0007:1:1", defaults: defaults),
            AddonRatingsService.heroEpisodeRatingsCacheKey(for: "tt0007:1:1", defaults: UserDefaults(suiteName: "HeroRatingsTests-empty-\(UUID().uuidString)")!)
        )
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

    func testEpisodeRatingsChoiceCompatibilityAndDefaults() {
        let defaults = isolatedDefaults()
        XCTAssertEqual(AddonRatingsService.episodeRatingsChoice(defaults: defaults), "All")

        defaults.set(true, forKey: SettingsKey.continueWatchingEpisodeRatings)
        XCTAssertEqual(AddonRatingsService.episodeRatingsChoice(defaults: defaults), "All")

        defaults.set(false, forKey: SettingsKey.continueWatchingEpisodeRatings)
        XCTAssertEqual(AddonRatingsService.episodeRatingsChoice(defaults: defaults), "None")

        AddonRatingsService.setEpisodeRatingsChoice("tmdb", defaults: defaults)
        XCTAssertEqual(AddonRatingsService.episodeRatingsChoice(defaults: defaults), "TMDB")

        AddonRatingsService.setEpisodeRatingsChoice("IMDb", defaults: defaults)
        XCTAssertEqual(AddonRatingsService.episodeRatingsChoice(defaults: defaults), "IMDb")

        AddonRatingsService.setEpisodeRatingsChoice("none", defaults: defaults)
        XCTAssertEqual(AddonRatingsService.episodeRatingsChoice(defaults: defaults), "None")

        AddonRatingsService.setEpisodeRatingsChoice("invalid", defaults: defaults)
        XCTAssertEqual(AddonRatingsService.episodeRatingsChoice(defaults: defaults), "All")
    }

    func testEpisodeRatingsChoiceFiltersToSelectedSourceOrTitleSettings() {
        let defaults = isolatedDefaults()
        AddonRatingsService.setRatingOrder(["tmdb", "imdb"], defaults: defaults)
        let meta = NuvioMeta(id: "tt0011", name: "K", type: "series", rating: 7.0)
        let episodeRatings = [
            NuvioExternalRating(source: "imdb", value: 8.5, max: 10),
            NuvioExternalRating(source: "tmdb", value: 8.0, max: 10)
        ]
        let titleRatings = [
            NuvioExternalRating(source: "tmdb", value: 75, max: 100),
            NuvioExternalRating(source: "imdb", value: 7.2, max: 10)
        ]

        // Choice: All
        AddonRatingsService.setEpisodeRatingsChoice("All", defaults: defaults)
        let allRatings = AddonRatingsService.heroEpisodeDisplayRatings(
            for: meta,
            video: nil,
            fetched: episodeRatings,
            fallbackRatings: titleRatings,
            defaults: defaults
        )
        XCTAssertEqual(allRatings.map(\.source), ["tmdb", "imdb"])

        // Choice: TMDB
        AddonRatingsService.setEpisodeRatingsChoice("TMDB", defaults: defaults)
        let tmdbOnly = AddonRatingsService.heroEpisodeDisplayRatings(
            for: meta,
            video: nil,
            fetched: episodeRatings,
            fallbackRatings: titleRatings,
            defaults: defaults
        )
        XCTAssertEqual(tmdbOnly.map(\.source), ["tmdb"])
        XCTAssertEqual(tmdbOnly.first?.value, 80)

        // Choice: IMDb
        AddonRatingsService.setEpisodeRatingsChoice("IMDb", defaults: defaults)
        let imdbOnly = AddonRatingsService.heroEpisodeDisplayRatings(
            for: meta,
            video: nil,
            fetched: episodeRatings,
            fallbackRatings: titleRatings,
            defaults: defaults
        )
        XCTAssertEqual(imdbOnly.map(\.source), ["imdb"])
        XCTAssertEqual(imdbOnly.first?.value, 8.5)

        // Choice: None -> uses title ratings path
        AddonRatingsService.setEpisodeRatingsChoice("None", defaults: defaults)
        let noneRatings = AddonRatingsService.heroEpisodeDisplayRatings(
            for: meta,
            video: nil,
            fetched: episodeRatings,
            fallbackRatings: titleRatings,
            defaults: defaults
        )
        XCTAssertEqual(noneRatings.map(\.source), ["tmdb", "imdb"])
        XCTAssertEqual(noneRatings.first?.value, 75, "uses title rating score")

        // Choice TMDB when episode has only IMDb rating -> falls back to title ratings
        AddonRatingsService.setEpisodeRatingsChoice("TMDB", defaults: defaults)
        let fallbackWhenMissing = AddonRatingsService.heroEpisodeDisplayRatings(
            for: meta,
            video: nil,
            fetched: [NuvioExternalRating(source: "imdb", value: 8.5, max: 10)],
            fallbackRatings: titleRatings,
            defaults: defaults
        )
        XCTAssertEqual(fallbackWhenMissing.map(\.source), ["tmdb", "imdb"], "falls back to title ratings")
    }

    func testEpisodeIdentifierParsingSupportsTmdbOnlyTitles() {
        let imdbEpisode = AddonRatingsService.parseEpisodeIdentifier("tt23112594:1:2")
        XCTAssertEqual(imdbEpisode?.parentId, "tt23112594")
        XCTAssertNil(imdbEpisode?.tmdbId)
        XCTAssertEqual(imdbEpisode?.season, 1)
        XCTAssertEqual(imdbEpisode?.episode, 2)

        let tmdbEpisode = AddonRatingsService.parseEpisodeIdentifier("tmdb:213375:3:4")
        XCTAssertEqual(tmdbEpisode?.parentId, "tmdb:213375")
        XCTAssertEqual(tmdbEpisode?.tmdbId, 213375)
        XCTAssertEqual(tmdbEpisode?.season, 3)
        XCTAssertEqual(tmdbEpisode?.episode, 4)

        let rawNumeric = AddonRatingsService.parseEpisodeIdentifier("213375:1:5")
        XCTAssertEqual(rawNumeric?.parentId, "213375")
        XCTAssertEqual(rawNumeric?.tmdbId, 213375)
        XCTAssertEqual(rawNumeric?.season, 1)
        XCTAssertEqual(rawNumeric?.episode, 5)
    }
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "HeroRatingsTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private actor FetchCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
