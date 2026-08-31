import XCTest
@testable import NuvioTV

/// Regression cover for the add-on catalog decoder. A Stremio catalog page is
/// decoded as one array of metas, so a single entry with an off-spec field
/// shape used to throw and drop the whole row from Home.
final class CatalogDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testCatalogDisplayTitleTypeSuffixes() {
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "movie", showType: true), "Popular - Movies")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "series", showType: true), "Popular - TV Shows")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "show", showType: true), "Popular - TV Shows")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "anime", showType: true), "Popular - Anime")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Live", contentType: "channel", showType: true), "Live - Channels")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "podcast", showType: true), "Popular - Podcast")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular - Movies", contentType: "movie", showType: true), "Popular - Movies")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "movie", showType: false), "Popular")
    }

    func testHomeCatalogSyncPayloadShowCatalogTypeDefaultsAndParses() {
        let item: [String: Any] = ["addon_id": "a", "type": "movie", "catalog_id": "c"]
        XCTAssertTrue(HomeCatalogSyncPayload(dictionary: ["items": [item], "show_catalog_type": true]).showCatalogType)
        XCTAssertFalse(HomeCatalogSyncPayload(dictionary: ["items": [item], "show_catalog_type": false]).showCatalogType)
        XCTAssertTrue(HomeCatalogSyncPayload(dictionary: ["items": [item]]).showCatalogType)
    }

    func testCinemetaRatingAcceptsMixedNumericAndStringValues() throws {
        let json = #"{"metas":[{"id":"tt1","name":"One","type":"movie","imdbRating":7.8},{"id":"tt2","name":"Two","type":"movie","imdbRating":"8.1"}]}"#
        let page = try decoder.decode(CinemetaCatalogResponse.self, from: Data(json.utf8))
        let metas = page.metas.map { $0.toMeta(fallbackType: "movie") }
        XCTAssertEqual(metas.map(\.rating), [7.8, 8.1])
    }

    func testCatalogHomeVisibilityResolverHidesCollectionOnlySources() throws {
        let manifestURL = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        let source = CatalogHomeVisibilityResolver.Source(
            addonIdentifier: "https://example.com",
            contentType: "movie",
            catalogID: "popular"
        )
        XCTAssertFalse(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "movie", catalogID: "popular",
            collectionSources: [source], manifestURL: manifestURL, explicitHomeKeys: []
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "movie", catalogID: "popular",
            collectionSources: [source], manifestURL: manifestURL,
            explicitHomeKeys: ["example.addon_movie_popular"]
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "series", catalogID: "popular",
            collectionSources: [source], manifestURL: manifestURL, explicitHomeKeys: []
        ))
    }

    func testCollectionBackedAddonRequiresSyncedGenericCatalogKeys() throws {
        let manifestURL = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        let source = CatalogHomeVisibilityResolver.Source(
            addonIdentifier: "example.addon", contentType: "movie", catalogID: "collection", collectionID: "xperience"
        )
        let collectionOnlyKey = "collection_xperience"
        XCTAssertFalse(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "movie", catalogID: "generic",
            collectionSources: [source], manifestURL: manifestURL,
            explicitHomeKeys: [collectionOnlyKey]
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "movie", catalogID: "generic",
            collectionSources: [source], manifestURL: manifestURL,
            explicitHomeKeys: [collectionOnlyKey, "example.addon_movie_generic"]
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "movie", catalogID: "generic",
            collectionSources: [source], manifestURL: manifestURL,
            explicitHomeKeys: ["other.addon_movie_other", "collection_other"]
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "movie", catalogID: "generic",
            collectionSources: [source], manifestURL: manifestURL, explicitHomeKeys: []
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "unrelated.addon", contentType: "movie", catalogID: "generic",
            collectionSources: [source], manifestURL: manifestURL,
            explicitHomeKeys: [collectionOnlyKey]
        ))
        XCTAssertFalse(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "movie", catalogID: "collection",
            collectionSources: [source], manifestURL: manifestURL, explicitHomeKeys: []
        ))
    }

    func testCatalogHomeVisibilityResolverMatchesCompositeIdentifier() throws {
        let manifestURL = try XCTUnwrap(URL(string: "https://example.com/path/manifest.json"))
        let source = CatalogHomeVisibilityResolver.Source(
            addonIdentifier: "addon:example.addon:https://example.com/path",
            contentType: "movie", catalogID: "popular"
        )
        XCTAssertFalse(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "movie", catalogID: "popular",
            collectionSources: [source], manifestURL: manifestURL, explicitHomeKeys: []
        ))
    }

    func testCatalogHomeVisibilityResolverPreservesURLPathAndQueryCase() throws {
        let manifestURL = try XCTUnwrap(URL(string: "https://example.com/path/manifest.json?token=AbC"))
        for identifier in [
            "https://example.com/Path/manifest.json?token=AbC",
            "https://example.com/path/manifest.json?token=abc"
        ] {
            let source = CatalogHomeVisibilityResolver.Source(
                addonIdentifier: identifier, contentType: "movie", catalogID: "popular"
            )
            XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
                addonID: "example.addon", contentType: "movie", catalogID: "popular",
                collectionSources: [source], manifestURL: manifestURL, explicitHomeKeys: []
            ))
        }
    }

    func testPosterCacheFreshnessBoundaries() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(PosterDiskCacheFreshness.isFresh(modified: now.addingTimeInterval(-86400), now: now, ttl: 86400))
        XCTAssertFalse(PosterDiskCacheFreshness.isFresh(modified: now.addingTimeInterval(-86400.1), now: now, ttl: 86400))
    }

    func testPosterArtworkCachePolicyVolatileHosts() {
        XCTAssertTrue(PosterArtworkCachePolicy.isVolatile(URL(string: "https://xperience-app.com/a.jpg")!))
        XCTAssertTrue(PosterArtworkCachePolicy.isVolatile(URL(string: "https://cdn.xperience-app.com/a.jpg")!))
        XCTAssertTrue(PosterArtworkCachePolicy.isVolatile(URL(string: "https://btttr.cc/a.jpg")!))
        XCTAssertFalse(PosterArtworkCachePolicy.isVolatile(URL(string: "https://xperience-app.com.evil.test/a.jpg")!))
        XCTAssertFalse(PosterArtworkCachePolicy.isVolatile(URL(string: "https://example.com/a.jpg")!))
    }

    func testCollectionFolderPreservesTmdbAndTraktSources() throws {
        let json = """
        {
          "id": "collection",
          "title": "My collection",
          "folders": [{
            "id": "mixed",
            "title": "Mixed sources",
            "sources": [
              {
                "provider": "tmdb",
                "tmdbSourceType": "COMPANY",
                "title": "Pixar",
                "tmdbId": 3,
                "mediaType": "movie",
                "sortBy": "popularity.desc"
              },
              {
                "provider": "trakt",
                "title": "Watchlist",
                "traktListId": 123456,
                "mediaType": "tv",
                "sortBy": "added",
                "sortHow": "desc"
              }
            ]
          }]
        }
        """

        let collection = try decoder.decode(
            NuvioCollection.self,
            from: Data(json.utf8)
        )
        let sources = try XCTUnwrap(collection.folders.first?.resolvedSources)

        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].normalizedProvider, "tmdb")
        XCTAssertEqual(sources[0].tmdbSourceType, "COMPANY")
        XCTAssertEqual(sources[0].tmdbId, 3)
        XCTAssertEqual(sources[1].normalizedProvider, "trakt")
        XCTAssertEqual(sources[1].traktListId, 123456)
        XCTAssertEqual(sources[1].mediaType, "tv")
    }

    func testCollectionFolderPromotesLegacyAddonCatalogSources() throws {
        let json = """
        {
          "id": "collection",
          "title": "Legacy collection",
          "folders": [{
            "id": "legacy",
            "title": "Legacy folder",
            "catalogSources": [{
              "addonId": "https://example.com/manifest.json",
              "type": "movie",
              "catalogId": "popular",
              "genre": "Science Fiction"
            }]
          }]
        }
        """

        let collection = try decoder.decode(
            NuvioCollection.self,
            from: Data(json.utf8)
        )
        let source = try XCTUnwrap(collection.folders.first?.resolvedSources.first)

        XCTAssertEqual(source.normalizedProvider, "addon")
        XCTAssertEqual(source.catalogId, "popular")
        XCTAssertEqual(source.genre, "Science Fiction")
    }

    func testStremioCatalogURLDoesNotDoubleEncodeGenre() throws {
        let url = try StremioCatalogURLBuilder.url(
            baseURL: try XCTUnwrap(URL(string: "https://example.com/config")),
            type: "movie",
            catalogId: "top",
            skip: 100,
            genre: "Crime & Mystery"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.com/config/catalog/movie/top/genre=Crime%20%26%20Mystery&skip=100.json"
        )
        XCTAssertFalse(url.absoluteString.contains("%2520"))
    }

    func testStremioCatalogURLPreservesConfiguredManifestQuery() throws {
        let manifest = try XCTUnwrap(URL(string: "https://example.com/config/abc/manifest.json?token=secret"))
        let url = try StremioCatalogURLBuilder.url(
            baseURL: manifest.deletingLastPathComponent(),
            type: "movie",
            catalogId: "top"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.com/config/abc/catalog/movie/top.json?token=secret"
        )
    }

    func testStremioCatalogURLHandlesManifestURLDirectly() throws {
        let manifest = try XCTUnwrap(URL(string: "https://example.com/config/abc/manifest.json?token=secret"))
        let url = try StremioCatalogURLBuilder.url(
            baseURL: manifest,
            type: "series",
            catalogId: "recs_recent_1_series"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.com/config/abc/catalog/series/recs_recent_1_series.json?token=secret"
        )
    }

    func testStremioCatalogURLHandlesSpacesInCatalogId() throws {
        let manifest = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        let url = try StremioCatalogURLBuilder.url(
            baseURL: manifest,
            type: "series",
            catalogId: "recs recent 1 series"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.com/catalog/series/recs%20recent%201%20series.json"
        )
        XCTAssertFalse(url.absoluteString.contains("%2520"))
    }

    func testAcceptsSpecCompliantStringArray() throws {
        let people = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#"["Lana Wachowski","Lilly Wachowski"]"#.utf8)
        )
        XCTAssertEqual(people.values, ["Lana Wachowski", "Lilly Wachowski"])
    }

    /// Add-ons that already worked must be unaffected by this type. Entries
    /// pass through verbatim — no trimming, no dropping — because
    /// CastCrewSection identifies rows by the name string, so normalising
    /// here could merge two rows that render distinctly today.
    func testArrayEntriesArePassedThroughVerbatim() throws {
        let people = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#"["Nolan","Nolan ",""," Martin Luther King, Jr."]"#.utf8)
        )
        XCTAssertEqual(
            people.values,
            ["Nolan", "Nolan ", "", " Martin Luther King, Jr."]
        )
    }

    func testAcceptsSingleScalarString() throws {
        let people = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#""Christopher Nolan""#.utf8)
        )
        XCTAssertEqual(people.values, ["Christopher Nolan"])
    }

    /// AIO Metadata joins the list into one string; splitting it back apart
    /// keeps the cast row from rendering as a single run-on entry.
    func testSplitsCommaJoinedScalarAndTrimsPadding() throws {
        let people = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#""Lana Wachowski,  Lilly Wachowski , Keanu Reeves""#.utf8)
        )
        XCTAssertEqual(
            people.values,
            ["Lana Wachowski", "Lilly Wachowski", "Keanu Reeves"]
        )
    }

    func testDropsEmptyAndUnsupportedShapesWithoutThrowing() throws {
        let blank = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#""   ""#.utf8)
        )
        XCTAssertEqual(blank.values, [])

        // An object or number must degrade to "no people", never to a throw
        // that would cost the caller the entire catalog page.
        let unsupported = try decoder.decode(
            FlexibleStringArray.self,
            from: Data(#"{"name":"Christopher Nolan"}"#.utf8)
        )
        XCTAssertEqual(unsupported.values, [])
    }

    func testCustomAvatarLinkResolvesOutsideTheCatalog() async {
        let link = " https://images.example.test/avatar.png?size=512 "
        let resolved = await MainActor.run {
            AvatarCatalogStore.shared.imageURL(for: link)
        }

        XCTAssertEqual(
            resolved?.absoluteString,
            "https://images.example.test/avatar.png?size=512"
        )
        let unsupported = await MainActor.run {
            AvatarCatalogStore.shared.imageURL(for: "file:///tmp/avatar.png")
        }
        XCTAssertNil(unsupported)
    }

    /// The actual bug: one off-spec `director` inside a catalog page.
    func testCatalogPageSurvivesOffSpecPeopleField() throws {
        let json = Data("""
        {"metas":[
          {"id":"tt0133093","type":"movie","name":"The Matrix",
           "director":["Lana Wachowski"]},
          {"id":"tt1375666","type":"movie","name":"Inception",
           "director":"Christopher Nolan","cast":"Leonardo DiCaprio, Elliot Page"}
        ]}
        """.utf8)

        struct Page: Decodable {
            struct Entry: Decodable {
                let name: String
                let director: FlexibleStringArray?
                let cast: FlexibleStringArray?
            }
            let metas: [Entry]
        }

        let page = try decoder.decode(Page.self, from: json)
        XCTAssertEqual(page.metas.count, 2, "off-spec entry must not drop the page")
        XCTAssertEqual(page.metas[0].director?.values, ["Lana Wachowski"])
        XCTAssertEqual(page.metas[1].director?.values, ["Christopher Nolan"])
        XCTAssertEqual(
            page.metas[1].cast?.values,
            ["Leonardo DiCaprio", "Elliot Page"]
        )
    }

    // MARK: - WatchedStore Caching & Snapshot Indexing Tests

    func testWatchedSnapshotIndexedLookups() {
        let movieMeta = NuvioMeta(
            id: "tt0133093",
            name: "The Matrix",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt0133093",
            tmdbId: 603,
            type: "movie",
            year: 1999,
            genres: ["Action", "Sci-Fi"],
            rating: 8.7,
            releaseInfo: "1999",
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )

        let seriesMeta = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt0903747",
            tmdbId: 1396,
            type: "series",
            year: 2008,
            genres: ["Crime", "Drama"],
            rating: 9.5,
            releaseInfo: "2008-2013",
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )

        let items = [
            WatchedStoreItem(meta: movieMeta, watchedAt: Date(), sources: [TraktWatchProgressSource.nuvioSync.rawValue]),
            WatchedStoreItem(meta: seriesMeta, watchedAt: Date(), season: 1, episode: 1, sources: [TraktWatchProgressSource.nuvioSync.rawValue]),
            WatchedStoreItem(meta: seriesMeta, watchedAt: Date(), season: 1, episode: 2, sources: [TraktWatchProgressSource.nuvioSync.rawValue]),
            WatchedStoreItem(meta: seriesMeta, watchedAt: Date(), season: 2, episode: 1, sources: [TraktWatchProgressSource.nuvioSync.rawValue])
        ]

        let snapshot = WatchedSnapshot(items: items, source: .nuvioSync)

        // Movie whole-title lookups
        XCTAssertTrue(snapshot.contains(metaId: "tt0133093", type: "movie"))
        XCTAssertTrue(snapshot.contains(metaId: "TT0133093", type: "movie"))
        XCTAssertTrue(snapshot.contains(meta: movieMeta))
        XCTAssertFalse(snapshot.contains(metaId: "tt9999999", type: "movie"))

        // Series title does not have whole-title mark
        XCTAssertFalse(snapshot.contains(metaId: "tt0903747", type: "series"))
        XCTAssertFalse(snapshot.contains(meta: seriesMeta))

        // Episode lookups
        XCTAssertTrue(snapshot.containsEpisode(metaId: "tt0903747", season: 1, episode: 1))
        XCTAssertTrue(snapshot.containsEpisode(metaId: "tt0903747", season: 1, episode: 2))
        XCTAssertTrue(snapshot.containsEpisode(metaId: "tt0903747", season: 2, episode: 1))
        XCTAssertFalse(snapshot.containsEpisode(metaId: "tt0903747", season: 1, episode: 3))

        XCTAssertTrue(snapshot.containsEpisode(meta: seriesMeta, season: 1, episode: 1))
        XCTAssertFalse(snapshot.containsEpisode(meta: seriesMeta, season: 3, episode: 1))

        // Episode keys
        let episodeKeys = snapshot.watchedEpisodeKeys(metaId: "tt0903747")
        XCTAssertEqual(episodeKeys, ["1:1", "1:2", "2:1"])

        let metaEpisodeKeys = snapshot.watchedEpisodeKeys(meta: seriesMeta)
        XCTAssertEqual(metaEpisodeKeys, ["1:1", "1:2", "2:1"])

        let movieTypedSeriesMeta = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt0903747",
            tmdbId: 1396,
            type: "movie",
            year: 2008,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: [NuvioVideo(
                id: "tt0903747:1:1", title: "Pilot", season: 1, episode: 1,
                thumbnail: nil, overview: nil, released: nil, rating: nil
            )]
        )
        XCTAssertEqual(movieTypedSeriesMeta.persistenceSnapshot.type, "series")
        XCTAssertTrue(snapshot.containsEpisode(meta: movieTypedSeriesMeta, season: 1, episode: 1))
        XCTAssertEqual(snapshot.watchedEpisodeKeys(meta: movieTypedSeriesMeta), ["1:1", "1:2", "2:1"])

        let legacyEpisodeMeta = NuvioMeta(
            id: "tt-legacy-series", name: "Legacy Series", description: nil,
            posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil,
            tmdbId: nil, type: "movie", year: 2020, genres: nil, rating: nil,
            releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil,
            certification: nil, country: nil, released: nil
        )
        let currentSeriesMeta = NuvioMeta(
            id: "tt-legacy-series", name: "Legacy Series", description: nil,
            posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil,
            tmdbId: nil, type: "movie", year: 2020, genres: nil, rating: nil,
            releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil,
            certification: nil, country: nil, released: nil,
            videos: [NuvioVideo(id: "tt-legacy-series:1:1", title: "Pilot",
                                season: 1, episode: 1, thumbnail: nil,
                                overview: nil, released: nil, rating: nil)]
        )
        let legacySnapshot = WatchedSnapshot(
            items: [WatchedStoreItem(meta: legacyEpisodeMeta, watchedAt: Date(), season: 1, episode: 1)],
            source: .nuvioSync
        )
        XCTAssertTrue(legacySnapshot.containsEpisode(meta: currentSeriesMeta, season: 1, episode: 1))
        XCTAssertEqual(legacySnapshot.watchedEpisodeKeys(meta: currentSeriesMeta), ["1:1"])

        // Catalog series title fallback match
        let localSeriesMeta = NuvioMeta(
            id: "cinemeta:series:custom123",
            name: "Breaking Bad",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: "series",
            year: 2008,
            genres: nil,
            rating: nil,
            releaseInfo: "2008",
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
        let catalogEpisodeKeys = snapshot.catalogWatchedEpisodeKeys(meta: localSeriesMeta)
        XCTAssertEqual(catalogEpisodeKeys, ["1:1", "1:2", "2:1"])
    }

    func testWatchedStoreCachingAndInvalidation() {
        let testProfile = "test_profile_\(UUID().uuidString)"
        WatchedStore.setActiveProfile(testProfile)
        WatchedStore.invalidateCache()

        let meta = NuvioMeta(
            id: "tt0088763",
            name: "Back to the Future",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt0088763",
            tmdbId: 105,
            type: "movie",
            year: 1985,
            genres: ["Adventure", "Comedy", "Sci-Fi"],
            rating: 8.5,
            releaseInfo: "1985",
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )

        // Initially empty
        XCTAssertFalse(WatchedStore.contains(meta: meta))
        XCTAssertEqual(WatchedStore.items().count, 0)

        // Mark watched
        let marked = WatchedStore.markWatched(meta)
        XCTAssertTrue(marked)

        // Cached lookup should be immediate and true
        XCTAssertTrue(WatchedStore.contains(meta: meta))
        XCTAssertTrue(WatchedStore.contains(metaId: "tt0088763", type: "movie"))
        XCTAssertEqual(WatchedStore.items().count, 1)

        // Snapshot lookup
        let snapshot = WatchedStore.currentSnapshot()
        XCTAssertTrue(snapshot.contains(meta: meta))

        // Cleanup
        WatchedStore.eraseProfile(testProfile)
        XCTAssertFalse(WatchedStore.contains(meta: meta))
        XCTAssertEqual(WatchedStore.items().count, 0)
    }
}
