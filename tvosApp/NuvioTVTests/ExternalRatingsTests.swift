//
//  ExternalRatingsTests.swift
//  NuvioTVTests
//
//  Unit tests for MDBList MAL & TVDB providers and Stremio add-on ratings.
//

import XCTest
@testable import NuvioTV

final class ExternalRatingsTests: XCTestCase {

    // MARK: - MDBList MAL & TVDB Provider Tests

    func testMdbListProviderPriorityOrderIncludesMyAnimeListAndTVDB() {
        let order = MdbListDetailsService.providerPriorityOrder
        XCTAssertTrue(order.contains(MdbListDetailsService.providerMyAnimeList))
        XCTAssertTrue(order.contains(MdbListDetailsService.providerTVDB))
        XCTAssertEqual(MdbListDetailsService.providerMyAnimeList, "myanimelist")
        XCTAssertEqual(MdbListDetailsService.providerTVDB, "tvdb")
    }

    func testMdbListApiProviderMappingMapsMyAnimeListToMal() {
        XCTAssertEqual(MdbListDetailsService.apiProvider(for: MdbListDetailsService.providerMyAnimeList), "mal")
        XCTAssertEqual(MdbListDetailsService.apiProvider(for: MdbListDetailsService.providerTVDB), "tvdb")
        XCTAssertEqual(MdbListDetailsService.apiProvider(for: MdbListDetailsService.providerIMDb), "imdb")
    }

    func testMdbListSyncMapperHandlesMyAnimeListAndTvdb() {
        let remoteToLocal = Dictionary(uniqueKeysWithValues: MdbListSyncMapper.remoteToLocalKeyMappings)
        XCTAssertEqual(remoteToLocal["mdblist_use_myanimelist"], SettingsKey.mdbListUseMyAnimeList)
        XCTAssertEqual(remoteToLocal["mdblist_use_mal"], SettingsKey.mdbListUseMyAnimeList)
        XCTAssertEqual(remoteToLocal["mdblist_use_tvdb"], SettingsKey.mdbListUseTvdb)

        let localToRemote = Dictionary(uniqueKeysWithValues: MdbListSyncMapper.localToRemoteKeyMappings)
        XCTAssertEqual(localToRemote[SettingsKey.mdbListUseMyAnimeList], "mdblist_use_myanimelist")
        XCTAssertEqual(localToRemote[SettingsKey.mdbListUseTvdb], "mdblist_use_tvdb")
    }

    // MARK: - Addon Rating Manifest & Resource Tests

    func testAddonRatingsManifestParsesRatingSources() throws {
        let json = """
        {
            "id": "org.csfd.ratings",
            "name": "ČSFD Ratings",
            "version": "1.0.0",
            "resources": [
                {
                    "name": "ratings",
                    "types": ["movie", "series"],
                    "idPrefixes": ["tt"]
                }
            ],
            "ratingSources": [
                {
                    "source": "csfd",
                    "name": "ČSFD",
                    "icon": "https://example.com/csfd.png",
                    "max": 100
                }
            ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(AddonRatingsManifest.self, from: json)
        XCTAssertEqual(manifest.id, "org.csfd.ratings")
        XCTAssertEqual(manifest.displayName, "ČSFD Ratings")
        XCTAssertEqual(manifest.ratingSources?.count, 1)

        let source = try XCTUnwrap(manifest.ratingSources?.first)
        XCTAssertEqual(source.source, "csfd")
        XCTAssertEqual(source.name, "ČSFD")
        XCTAssertEqual(source.icon, "https://example.com/csfd.png")
        XCTAssertEqual(source.max, 100)

        XCTAssertTrue(manifest.supportsRatings(type: "movie", id: "tt0388629"))
        XCTAssertTrue(manifest.supportsRatings(type: "series", id: "tt0388629"))
        XCTAssertFalse(manifest.supportsRatings(type: "other", id: "tt0388629"))
        XCTAssertFalse(manifest.supportsRatings(type: "movie", id: "kitsu:123"))
    }

    func testAddonRatingsManifestStringResourceShorthand() throws {
        let json = """
        {
            "id": "org.simple.ratings",
            "resources": ["ratings"],
            "types": ["movie"],
            "ratingSources": [
                {
                    "source": "filmaffinity",
                    "name": "FilmAffinity",
                    "max": 10
                }
            ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(AddonRatingsManifest.self, from: json)
        XCTAssertTrue(manifest.supportsRatings(type: "movie", id: "any:id"))
        XCTAssertFalse(manifest.supportsRatings(type: "series", id: "any:id"))
    }

    // MARK: - Addon Rating Response & Decoding Tests

    func testAddonRatingsResponseDecodesNumbersAndStrings() throws {
        let json = """
        {
            "ratings": [
                {
                    "source": "csfd",
                    "value": 84,
                    "url": "https://www.csfd.cz/film/12345"
                },
                {
                    "source": "douban",
                    "value": "9.1",
                    "url": "https://movie.douban.com/subject/12345"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(AddonRatingsResponse.self, from: json)
        let ratings = try XCTUnwrap(response.ratings)
        XCTAssertEqual(ratings.count, 2)

        XCTAssertEqual(ratings[0].source, "csfd")
        XCTAssertEqual(ratings[0].value, 84.0)
        XCTAssertEqual(ratings[0].url, "https://www.csfd.cz/film/12345")

        XCTAssertEqual(ratings[1].source, "douban")
        XCTAssertEqual(ratings[1].value, 9.1)
        XCTAssertEqual(ratings[1].url, "https://movie.douban.com/subject/12345")
    }

    // MARK: - Anti-Spoofing and Filter Tests

    func testAntiSpoofingRejectsBuiltInProviders() {
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("imdb"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("tmdb"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("tomatoes"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("metacritic"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("trakt"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("letterboxd"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("audience"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("myanimelist"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("mal"))
        XCTAssertTrue(AddonRatingsService.builtInProviders.contains("tvdb"))

        XCTAssertFalse(AddonRatingsService.builtInProviders.contains("csfd"))
        XCTAssertFalse(AddonRatingsService.builtInProviders.contains("kinopoisk"))
    }

    func testAddonRatingAggregationDeduplicatesCaseInsensitiveSources() {
        let ratings = [
            NuvioExternalRating(source: "csfd", value: 15, name: "First", max: 20),
            NuvioExternalRating(source: "CSFD", value: 16, name: "Duplicate", max: 20),
            NuvioExternalRating(source: "IMDb", value: 8.2, name: "Built-in spoof"),
            NuvioExternalRating(source: "douban", value: 8.4, name: "Douban")
        ]

        let result = AddonRatingsService.deduplicatedRatings(ratings)
        XCTAssertEqual(result.map(\.source), ["csfd", "douban"])
        XCTAssertEqual(result.first?.value, 15)
        XCTAssertEqual(result.first?.name, "First")
    }

    func testAddonRatingFormattingUsesDeclaredScale() {
        XCTAssertEqual(AddonRatingsService.formatRating(value: 15, max: 20), "75%")
        XCTAssertEqual(AddonRatingsService.formatRating(value: 150, max: 200), "75%")
        XCTAssertEqual(AddonRatingsService.formatRating(value: 84, max: 100), "84%")
        XCTAssertEqual(AddonRatingsService.formatRating(value: 8.4, max: 10), "8.4")
        XCTAssertEqual(AddonRatingsService.formatRating(value: 84, max: nil), "84%")
        XCTAssertEqual(AddonRatingsService.formatRating(value: 8, max: 0), "8.0")
        XCTAssertEqual(AddonRatingsService.formatRating(value: 8, max: -10), "8.0")
        XCTAssertEqual(AddonRatingsService.formatRating(value: 8, max: .infinity), "8.0")
        XCTAssertEqual(AddonRatingsService.formatRating(value: 8, max: .nan), "8.0")
        XCTAssertEqual(AddonRatingsService.formatRating(value: .nan, max: 20), "—")
        XCTAssertEqual(AddonRatingsService.formatRating(value: .infinity, max: 20), "—")
        XCTAssertEqual(AddonRatingsService.formatRating(value: -.infinity, max: 20), "—")

        let extreme = AddonRatingsService.formatRating(value: 2e18, max: 20)
        XCTAssertFalse(extreme.isEmpty)
        XCTAssertTrue(extreme.hasSuffix("%") || extreme.contains("/"))
    }

    // MARK: - User Settings and Icon Overrides

    func testUserCanEnableDisableAndOverrideIconForAddonRatingSource() {
        let suiteName = "test.ratings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Default is enabled
        XCTAssertTrue(AddonRatingsService.isSourceEnabled("csfd", defaults: defaults))

        // Disable source
        AddonRatingsService.setSourceEnabled("csfd", enabled: false, defaults: defaults)
        XCTAssertFalse(AddonRatingsService.isSourceEnabled("csfd", defaults: defaults))

        // Re-enable source
        AddonRatingsService.setSourceEnabled("csfd", enabled: true, defaults: defaults)
        XCTAssertTrue(AddonRatingsService.isSourceEnabled("csfd", defaults: defaults))

        // Icon override
        XCTAssertNil(AddonRatingsService.iconOverride(for: "csfd", defaults: defaults))
        let overrideUrl = "https://raw.githubusercontent.com/icons/csfd.png"
        AddonRatingsService.setIconOverride(for: "csfd", urlString: overrideUrl, defaults: defaults)
        XCTAssertEqual(AddonRatingsService.iconOverride(for: "csfd", defaults: defaults), overrideUrl)

        // Clear icon override
        AddonRatingsService.setIconOverride(for: "csfd", urlString: nil, defaults: defaults)
        XCTAssertNil(AddonRatingsService.iconOverride(for: "csfd", defaults: defaults))
    }

    // MARK: - NuvioExternalRating Codable Roundtrip

    func testNuvioExternalRatingRoundtrip() throws {
        let rating = NuvioExternalRating(
            source: "csfd",
            value: 84.0,
            url: "https://www.csfd.cz/film/123",
            name: "ČSFD",
            iconUrl: "https://example.com/icon.png",
            max: 100.0
        )

        let data = try JSONEncoder().encode(rating)
        let decoded = try JSONDecoder().decode(NuvioExternalRating.self, from: data)

        XCTAssertEqual(decoded.source, "csfd")
        XCTAssertEqual(decoded.value, 84.0)
        XCTAssertEqual(decoded.url, "https://www.csfd.cz/film/123")
        XCTAssertEqual(decoded.name, "ČSFD")
        XCTAssertEqual(decoded.iconUrl, "https://example.com/icon.png")
        XCTAssertEqual(decoded.max, 100.0)
    }

    func testNuvioExternalRatingDecodesLegacyJsonWithoutOptionalFields() throws {
        let legacyJson = """
        {
            "source": "imdb",
            "value": 8.4
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(NuvioExternalRating.self, from: legacyJson)
        XCTAssertEqual(decoded.source, "imdb")
        XCTAssertEqual(decoded.value, 8.4)
        XCTAssertNil(decoded.url)
        XCTAssertNil(decoded.name)
        XCTAssertNil(decoded.iconUrl)
        XCTAssertNil(decoded.max)
    }

    // MARK: - Episode Ratings & Ordering Tests

    func testAddonRatingSourceParsesEpisodesFlag() throws {
        let jsonWithEpisodesTrue = """
        {
            "id": "org.csfd.ratings",
            "name": "ČSFD Ratings",
            "resources": ["ratings"],
            "ratingSources": [
                {
                    "source": "csfd",
                    "name": "ČSFD",
                    "max": 100,
                    "episodes": true
                }
            ]
        }
        """.data(using: .utf8)!

        let manifest1 = try JSONDecoder().decode(AddonRatingsManifest.self, from: jsonWithEpisodesTrue)
        let source1 = try XCTUnwrap(manifest1.ratingSources?.first)
        XCTAssertEqual(source1.episodes, true)

        let jsonWithEpisodesFalse = """
        {
            "id": "org.csfd.ratings",
            "name": "ČSFD Ratings",
            "resources": ["ratings"],
            "ratingSources": [
                {
                    "source": "csfd",
                    "name": "ČSFD",
                    "episodes": false
                }
            ]
        }
        """.data(using: .utf8)!

        let manifest2 = try JSONDecoder().decode(AddonRatingsManifest.self, from: jsonWithEpisodesFalse)
        let source2 = try XCTUnwrap(manifest2.ratingSources?.first)
        XCTAssertEqual(source2.episodes, false)

        let jsonWithoutEpisodes = """
        {
            "id": "org.csfd.ratings",
            "name": "ČSFD Ratings",
            "resources": ["ratings"],
            "ratingSources": [
                {
                    "source": "csfd",
                    "name": "ČSFD"
                }
            ]
        }
        """.data(using: .utf8)!

        let manifest3 = try JSONDecoder().decode(AddonRatingsManifest.self, from: jsonWithoutEpisodes)
        let source3 = try XCTUnwrap(manifest3.ratingSources?.first)
        XCTAssertNil(source3.episodes)
    }

    func testRatingOrderPersistenceAndSorting() {
        let suiteName = "test.ratings.order.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Default order contains built-in providers
        let defaultOrder = AddonRatingsService.savedRatingOrder(defaults: defaults)
        XCTAssertFalse(defaultOrder.isEmpty)
        XCTAssertTrue(defaultOrder.contains("imdb"))
        XCTAssertTrue(defaultOrder.contains("tomatoes"))

        // Set custom order and verify notification
        var notificationReceived = false
        let observer = NotificationCenter.default.addObserver(
            forName: AddonRatingsService.ratingOrderChangedNotification,
            object: nil,
            queue: .main
        ) { _ in
            notificationReceived = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let customOrder = ["csfd", "letterboxd", "imdb", "tomatoes"]
        AddonRatingsService.setRatingOrder(customOrder, defaults: defaults)

        XCTAssertEqual(AddonRatingsService.savedRatingOrder(defaults: defaults), customOrder)
        XCTAssertTrue(notificationReceived)

        // Sort items using custom order
        let sampleItems = [
            (source: "tomatoes", name: "Rotten Tomatoes"),
            (source: "douban", name: "Douban"),
            (source: "imdb", name: "IMDb"),
            (source: "csfd", name: "ČSFD"),
            (source: "letterboxd", name: "Letterboxd")
        ]

        let sorted = AddonRatingsService.sortRatings(sampleItems, by: { $0.source }, defaults: defaults)
        let sortedSources = sorted.map(\.source)

        // "csfd", "letterboxd", "imdb", "tomatoes" first, then undeclared "douban"
        XCTAssertEqual(sortedSources, ["csfd", "letterboxd", "imdb", "tomatoes", "douban"])
    }

    func testEpisodeRatingsCacheOperations() async {
        let cache = AddonEpisodeRatingsCache.shared
        await cache.clear()

        let episodeId = "tt0903747:1:5"
        let initialCached = await cache.cachedRatings(for: episodeId)
        XCTAssertNil(initialCached)

        let rating = NuvioExternalRating(
            source: "csfd",
            value: 92.0,
            url: "https://www.csfd.cz/film/episode-5",
            name: "ČSFD",
            iconUrl: nil,
            max: 100.0
        )

        await cache.setRatings([rating], for: episodeId)
        let cached = await cache.cachedRatings(for: episodeId)
        XCTAssertEqual(cached?.count, 1)
        XCTAssertEqual(cached?.first?.source, "csfd")
        XCTAssertEqual(cached?.first?.value, 92.0)

        // Case insensitivity
        let cachedUpper = await cache.cachedRatings(for: "TT0903747:1:5")
        XCTAssertEqual(cachedUpper?.count, 1)

        // Empty ratings cached
        let emptyEpisodeId = "tt0903747:1:6"
        await cache.setRatings([], for: emptyEpisodeId)
        let cachedEmpty = await cache.cachedRatings(for: emptyEpisodeId)
        XCTAssertNotNil(cachedEmpty)
        XCTAssertTrue(cachedEmpty?.isEmpty == true)

        await cache.clear()
        let clearedCached = await cache.cachedRatings(for: episodeId)
        XCTAssertNil(clearedCached)
    }

    func testEpisodeRatingsFilteringExcludesNonEpisodeSources() async throws {
        let manifestJson = """
        {
            "id": "org.test.ratings",
            "name": "Test Ratings",
            "resources": ["ratings"],
            "ratingSources": [
                {
                    "source": "csfd",
                    "name": "ČSFD",
                    "max": 100,
                    "episodes": true
                },
                {
                    "source": "filmaffinity",
                    "name": "FilmAffinity",
                    "max": 10,
                    "episodes": false
                }
            ]
        }
        """.data(using: .utf8)!
        let manifest = try JSONDecoder().decode(AddonRatingsManifest.self, from: manifestJson)

        let responseData = """
        {
            "ratings": [
                { "source": "csfd", "value": 88 },
                { "source": "filmaffinity", "value": 7.5 }
            ]
        }
        """.data(using: .utf8)!

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRatingsTestURLProtocol.self]
        let session = URLSession(configuration: config)

        let manifestURL = URL(string: "https://test.addon/manifest.json")!
        MockRatingsTestURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, responseData)
        }

        // When episodesOnly is false (series/movie level), both sources should be included
        let fullRatings = await AddonRatingsService.fetchRatingsFromAddon(
            manifestURL: manifestURL,
            manifest: manifest,
            type: "series",
            id: "tt0903747",
            session: session,
            episodesOnly: false
        )
        XCTAssertEqual(fullRatings.count, 2)
        XCTAssertTrue(fullRatings.contains { $0.source == "csfd" })
        XCTAssertTrue(fullRatings.contains { $0.source == "filmaffinity" })

        // When episodesOnly is true (episode level), only the source with episodes == true must be included
        let episodeRatings = await AddonRatingsService.fetchRatingsFromAddon(
            manifestURL: manifestURL,
            manifest: manifest,
            type: "series",
            id: "tt0903747:1:5",
            session: session,
            episodesOnly: true
        )
        XCTAssertEqual(episodeRatings.count, 1)
        XCTAssertEqual(episodeRatings.first?.source, "csfd")
        XCTAssertEqual(episodeRatings.first?.value, 88.0)
    }

    // MARK: - Home Hero Rating Source Tests

    func testAvailableHeroRatingSourcesIncludesBuiltIns() async {
        let sources = await AddonRatingsService.availableHeroRatingSources(defaults: .standard)
        let ids = sources.map(\.id)

        XCTAssertTrue(ids.contains("imdb"))
        XCTAssertTrue(ids.contains("tmdb"))
        XCTAssertTrue(ids.contains("tomatoes"))
        XCTAssertTrue(ids.contains("metacritic"))
        XCTAssertTrue(ids.contains("trakt"))
        XCTAssertTrue(ids.contains("letterboxd"))
        XCTAssertTrue(ids.contains("audience"))
        XCTAssertTrue(ids.contains("myanimelist"))
        XCTAssertTrue(ids.contains("tvdb"))

        let imdbOption = sources.first { $0.id == "imdb" }
        XCTAssertEqual(imdbOption?.displayName, "IMDb")
    }

    func testAvailableHeroRatingSourcesDiscoversAddonsFromManifestStates() async {
        let suiteName = "test.hero.ratings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let addonManifest = """
        {
            "id": "org.csfd.ratings",
            "name": "ČSFD Addon",
            "ratingSources": [
                {
                    "source": "csfd",
                    "name": "ČSFD",
                    "max": 100
                }
            ]
        }
        """

        let prefs = [StreamAddonPreference(url: "https://ratings.csfd.cz/manifest.json", enabled: true)]
        let prefsData = try! JSONEncoder().encode(prefs)
        let prefsJson = String(data: prefsData, encoding: .utf8)!
        defaults.set(prefsJson, forKey: SettingsKey.streamAddonManifestStates)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRatingsTestURLProtocol.self]
        let session = URLSession(configuration: config)
        await StremioManifestDataCache.shared.setSessionForTesting(session)
        defer {
            Task {
                await StremioManifestDataCache.shared.setSessionForTesting(nil)
            }
        }

        MockRatingsTestURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, addonManifest.data(using: .utf8)!)
        }

        let sources = await AddonRatingsService.availableHeroRatingSources(defaults: defaults)
        let csfdOption = sources.first { $0.id == "csfd" }
        XCTAssertNotNil(csfdOption)
        XCTAssertEqual(csfdOption?.displayName, "ČSFD")
    }

    func testHeroRatingStringFormattingAndFallback() {
        let metaWithImdb = NuvioMeta(
            id: "tt123",
            name: "Dune",
            type: "movie",
            rating: 8.6
        )

        // 1. IMDb source
        let imdbStr = AddonRatingsService.heroRatingString(for: metaWithImdb, source: "imdb", ratings: nil)
        XCTAssertEqual(imdbStr, "IMDb 8.6")

        // 2. TMDB source from external ratings
        let externalRatings = [
            NuvioExternalRating(source: "tmdb", value: 8.3),
            NuvioExternalRating(source: "tomatoes", value: 93),
            NuvioExternalRating(source: "csfd", value: 88, name: "ČSFD")
        ]
        let tmdbStr = AddonRatingsService.heroRatingString(for: metaWithImdb, source: "tmdb", ratings: externalRatings)
        XCTAssertEqual(tmdbStr, "TMDB 8.3")

        // 3. Rotten Tomatoes with percentage
        let rtStr = AddonRatingsService.heroRatingString(for: metaWithImdb, source: "tomatoes", ratings: externalRatings)
        XCTAssertEqual(rtStr, "Rotten Tomatoes 93%")

        // 4. Custom add-on source (ČSFD)
        let csfdStr = AddonRatingsService.heroRatingString(for: metaWithImdb, source: "csfd", ratings: externalRatings)
        XCTAssertEqual(csfdStr, "ČSFD 88%")

        // 5. Fallback to IMDb when requested source is not in external ratings
        let fallbackStr = AddonRatingsService.heroRatingString(for: metaWithImdb, source: "letterboxd", ratings: externalRatings)
        XCTAssertEqual(fallbackStr, "IMDb 8.6")

        // 6. Fallback to IMDb when external ratings are nil
        let fallbackNilStr = AddonRatingsService.heroRatingString(for: metaWithImdb, source: "csfd", ratings: nil)
        XCTAssertEqual(fallbackNilStr, "IMDb 8.6")

        // 7. When neither source nor IMDb rating is available, return nil
        let metaNoRating = NuvioMeta(id: "tt999", name: "No Rating", type: "movie", rating: nil)
        let nilResult = AddonRatingsService.heroRatingString(for: metaNoRating, source: "csfd", ratings: nil)
        XCTAssertNil(nilResult)
    }

    func testSampleRatingString() {
        XCTAssertEqual(AddonRatingsService.sampleRatingString(for: "imdb"), "IMDb 8.6")
        XCTAssertEqual(AddonRatingsService.sampleRatingString(for: "tomatoes"), "Rotten Tomatoes 92%")
        XCTAssertEqual(AddonRatingsService.sampleRatingString(for: "trakt"), "Trakt 8.4")
        XCTAssertEqual(AddonRatingsService.sampleRatingString(for: "metacritic"), "Metacritic 79")
        XCTAssertFalse(AddonRatingsService.sampleRatingString(for: "custom_source").isEmpty)
    }

    func testCatalogModelsFillingMissingHeroMetadataPreservesExternalRatings() {
        let initialCard = NuvioMeta(
            id: "tt123",
            name: "Dune",
            type: "movie",
            rating: 8.6,
            externalRatings: nil
        )
        let fullMeta = NuvioMeta(
            id: "tt123",
            name: "Dune",
            type: "movie",
            rating: 8.6,
            externalRatings: [
                NuvioExternalRating(source: "tmdb", value: 8.3)
            ]
        )

        let merged = initialCard.fillingMissingHeroMetadata(from: fullMeta)
        XCTAssertEqual(merged.externalRatings?.count, 1)
        XCTAssertEqual(merged.externalRatings?.first?.source, "tmdb")
    }

    func testHeroEpisodeRatingStringFormattingAndFallback() {
        let seriesMeta = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            type: "series",
            rating: 9.5
        )
        let episodeVideo = NuvioVideo(
            id: "tt0903747:5:14",
            title: "Ozymandias",
            season: 5,
            episode: 14,
            rating: "10.0"
        )
        let externalRatings = [
            NuvioExternalRating(source: "tmdb", value: 9.8),
            NuvioExternalRating(source: "tomatoes", value: 100)
        ]

        // 1. Episode rating formatted for IMDb
        let imdbStr = AddonRatingsService.heroEpisodeRatingString(
            for: seriesMeta,
            video: episodeVideo,
            source: "imdb",
            ratings: nil
        )
        XCTAssertEqual(imdbStr, "IMDb 10.0")

        // 2. Episode external rating formatted for requested source
        let rtStr = AddonRatingsService.heroEpisodeRatingString(
            for: seriesMeta,
            video: episodeVideo,
            source: "tomatoes",
            ratings: externalRatings
        )
        XCTAssertEqual(rtStr, "Rotten Tomatoes 100%")

        // 3. Fallback to episode rating when requested source is not in external ratings
        let fallbackStr = AddonRatingsService.heroEpisodeRatingString(
            for: seriesMeta,
            video: episodeVideo,
            source: "letterboxd",
            ratings: externalRatings
        )
        XCTAssertEqual(fallbackStr, "IMDb 10.0")

        // 4. Fallback to series rating when episode has no rating
        let unratedEpisode = NuvioVideo(
            id: "tt0903747:1:1",
            title: "Pilot",
            season: 1,
            episode: 1,
            rating: nil
        )
        let seriesFallbackStr = AddonRatingsService.heroEpisodeRatingString(
            for: seriesMeta,
            video: unratedEpisode,
            source: "imdb",
            ratings: nil
        )
        XCTAssertEqual(seriesFallbackStr, "IMDb 9.5")
    }

    func testHeroEpisodeDisplayRatings() {
        let seriesMeta = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            type: "series",
            rating: 9.5
        )
        let episodeVideo = NuvioVideo(
            id: "tt0903747:5:14",
            title: "Ozymandias",
            season: 5,
            episode: 14,
            rating: "10.0"
        )
        let epFetched = [
            NuvioExternalRating(source: "tmdb", value: 9.8)
        ]

        let displayRatings = AddonRatingsService.heroEpisodeDisplayRatings(
            for: seriesMeta,
            video: episodeVideo,
            fetched: epFetched
        )
        XCTAssertEqual(displayRatings.count, 2)
        XCTAssertTrue(displayRatings.contains(where: { $0.source == "tmdb" && $0.value == 9.8 }))
        XCTAssertTrue(displayRatings.contains(where: { $0.source == "imdb" && $0.value == 10.0 }))

        // Fallback to series display ratings when episode has no ratings
        let emptyEpisode = NuvioVideo(
            id: "tt0903747:1:1",
            title: "Pilot",
            season: 1,
            episode: 1,
            rating: nil
        )
        let fallbackRatings = AddonRatingsService.heroEpisodeDisplayRatings(
            for: seriesMeta,
            video: emptyEpisode,
            fetched: nil
        )
        XCTAssertEqual(fallbackRatings.count, 1)
        XCTAssertEqual(fallbackRatings.first?.value, 9.5)
    }

    // MARK: - SeriesGraph Tests

    func testSeriesGraphRatingsServiceParsesAndResolvesRatings() async throws {
        let seriesGraph = SeriesGraphRatingsService()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRatingsTestURLProtocol.self]
        let session = URLSession(configuration: config)

        let sampleJson = """
        [
          {
            "season_number": 1,
            "episodes": [
              {
                "vote_average": 7.8,
                "num_votes": 8111,
                "episode_number": 1,
                "name": "No Strings",
                "season_number": 1,
                "tconst": "tt23134204"
              },
              {
                "episode_number": 2,
                "name": "Unaired Episode",
                "season_number": 1,
                "vote_average": null
              }
            ]
          }
        ]
        """.data(using: .utf8)!

        let cinemetaJson = """
        {
          "meta": {
            "id": "tt23112594",
            "moviedb_id": 213375
          }
        }
        """.data(using: .utf8)!

        MockRatingsTestURLProtocol.requestHandler = { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("cinemeta.strem.io") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, cinemetaJson)
            } else if urlStr.contains("seriesgraph.com") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, sampleJson)
            }
            throw URLError(.badURL)
        }

        // Test resolving TMDB ID from IMDb parent ID
        let resolvedTmdbId = await seriesGraph.resolveTmdbId(forParentId: "tt23112594", session: session)
        XCTAssertEqual(resolvedTmdbId, 213375)

        // Test fetching ratings
        let ratings = await seriesGraph.fetchRatings(forTmdbId: 213375, session: session)
        XCTAssertEqual(ratings.count, 1)
        XCTAssertEqual(ratings["1:1"]?.rating, 7.8)
        XCTAssertEqual(ratings["1:1"]?.voteCount, 8111)
        XCTAssertEqual(ratings["1:1"]?.imdbEpisodeId, "tt23134204")
        XCTAssertEqual(ratings["1:1"]?.title, "No Strings")

        // Unaired episode 2 with null rating should be omitted
        XCTAssertNil(ratings["1:2"])

        // Test direct episode identifier lookup
        let episodeRating = await seriesGraph.rating(forEpisodeIdentifier: "tt23112594:1:1", session: session)
        XCTAssertNotNil(episodeRating)
        XCTAssertEqual(episodeRating?.rating, 7.8)
        XCTAssertEqual(episodeRating?.voteCount, 8111)

        // Test direct IMDb ID lookup
        let imdbLookup = await seriesGraph.rating(forEpisodeIdentifier: "tt23134204", session: session)
        XCTAssertNotNil(imdbLookup)
        XCTAssertEqual(imdbLookup?.rating, 7.8)
    }

    func testAddonRatingsServiceEnrichesWithSeriesGraph() async throws {
        await AddonEpisodeRatingsCache.shared.clear()
        await SeriesGraphRatingsService.shared.clear()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRatingsTestURLProtocol.self]
        let session = URLSession(configuration: config)

        let sampleJson = """
        [
          {
            "season_number": 2,
            "episodes": [
              {
                "vote_average": 7.8,
                "num_votes": 2289,
                "episode_number": 10,
                "name": "Reconstruction",
                "season_number": 2,
                "tconst": "tt31187589"
              }
            ]
          }
        ]
        """.data(using: .utf8)!

        let cinemetaJson = """
        {
          "meta": {
            "id": "tt16358384",
            "moviedb_id": 153312
          }
        }
        """.data(using: .utf8)!

        MockRatingsTestURLProtocol.requestHandler = { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("cinemeta.strem.io") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, cinemetaJson)
            } else if urlStr.contains("seriesgraph.com") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, sampleJson)
            }
            throw URLError(.badURL)
        }

        // Test fetchRatingsForEpisode with SeriesGraph fallback
        let episodeRatings = await AddonRatingsService.fetchRatingsForEpisode(
            episodeId: "tt16358384:2:10",
            manifestURLs: [],
            session: session
        )
        XCTAssertEqual(episodeRatings.count, 1)
        XCTAssertEqual(episodeRatings.first?.source, "imdb")
        XCTAssertEqual(episodeRatings.first?.value, 7.8)

        // Test batch fetchRatingsForEpisodes
        let batchRatings = await AddonRatingsService.fetchRatingsForEpisodes(
            episodeIds: ["tt16358384:2:10"],
            manifestURLs: [],
            session: session
        )
        XCTAssertEqual(batchRatings["tt16358384:2:10"]?.count, 1)
        XCTAssertEqual(batchRatings["tt16358384:2:10"]?.first?.value, 7.8)
    }

    func testAddonRatingsServiceEnrichesWithTmdbEpisodeRating() async throws {
        await AddonEpisodeRatingsCache.shared.clear()
        await SeriesGraphRatingsService.shared.clear()
        await TmdbEpisodeRatingsStore.shared.clear()

        // Seed TMDB episode rating
        await TmdbEpisodeRatingsStore.shared.setRating(
            tmdbId: 213375,
            season: 1,
            episode: 1,
            voteAverage: 7.3
        )

        let sampleJson = """
        [
          {
            "season_number": 1,
            "episodes": [
              {
                "vote_average": 7.8,
                "num_votes": 8111,
                "episode_number": 1,
                "name": "No Strings",
                "season_number": 1,
                "tconst": "tt23134204"
              }
            ]
          }
        ]
        """.data(using: .utf8)!

        let cinemetaJson = """
        {
          "meta": {
            "id": "tt23112594",
            "moviedb_id": 213375
          }
        }
        """.data(using: .utf8)!

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockRatingsTestURLProtocol.self]
        let session = URLSession(configuration: config)

        MockRatingsTestURLProtocol.requestHandler = { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("cinemeta.strem.io") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, cinemetaJson)
            } else if urlStr.contains("seriesgraph.com") {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, sampleJson)
            }
            throw URLError(.badURL)
        }

        let episodeRatings = await AddonRatingsService.fetchRatingsForEpisode(
            episodeId: "tt23112594:1:1",
            manifestURLs: [],
            session: session
        )

        XCTAssertEqual(episodeRatings.count, 2)
        XCTAssertTrue(episodeRatings.contains(where: { $0.source == "imdb" && $0.value == 7.8 }))
        XCTAssertTrue(episodeRatings.contains(where: { $0.source == "tmdb" && $0.value == 7.3 }))

        // Test visual lookup for badges
        let imdbVisual = TvRatingVisual.visual(for: "imdb")
        XCTAssertEqual(imdbVisual?.assetName, "rating_imdb")
        let tmdbVisual = TvRatingVisual.visual(for: "tmdb")
        XCTAssertEqual(tmdbVisual?.assetName, "rating_tmdb")
    }

    @MainActor
    func testDetailsViewModelMergeEpisodesPreservesExistingRatings() {
        let existing = [
            NuvioVideo(
                id: "tt23112594:1:1",
                title: "No Strings",
                season: 1,
                episode: 1,
                rating: "7.8"
            )
        ]
        let tmdb = [
            NuvioVideo(
                id: "tmdb:213375:1:1",
                title: "No Strings",
                season: 1,
                episode: 1,
                rating: "7.3"
            )
        ]

        let merged = DetailsViewModel.mergeEpisodes(
            existing: existing,
            fromTmdb: tmdb,
            parentId: "tt23112594"
        )
        XCTAssertEqual(merged?.count, 1)
        // Existing IMDb rating (7.8) should be preserved over TMDB rating (7.3)
        XCTAssertEqual(merged?.first?.rating, "7.8")
    }

    func testSettingsKeyIncludesEpisodeRatings() {
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.continueWatchingEpisodeRatings))
    }
}

private class MockRatingsTestURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockRatingsTestURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

