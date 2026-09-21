import XCTest
@testable import NuvioTV

/// Regression cover for the add-on catalog decoder. A Stremio catalog page is
/// decoded as one array of metas, so a single entry with an off-spec field
/// shape used to throw and drop the whole row from Home.
final class CatalogDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testCanonicalEpisodeStreamIdUsesSeriesImdbNamespace() {
        let meta = NuvioMeta(
            id: "tmdb:123",
            name: "Test Series",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt456",
            tmdbId: 123,
            type: "series",
            year: 2024,
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
            videos: nil
        )
        let episode = NuvioVideo(
            id: "tmdb:123:1:2",
            title: "Episode 2",
            season: 1,
            episode: 2,
            thumbnail: nil,
            overview: nil,
            released: nil,
            rating: nil
        )

        XCTAssertEqual(meta.canonicalEpisodeStreamId(for: episode), "tt456:1:2")
    }

    func testCanonicalEpisodeStreamIdPreservesMatchingImdbEpisodeId() {
        let meta = NuvioMeta(
            id: "tt456",
            name: "Test Series",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt456",
            tmdbId: nil,
            type: "series",
            year: 2024,
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
            videos: nil
        )
        let episode = NuvioVideo(
            id: "tt456:1:2",
            title: "Episode 2",
            season: 1,
            episode: 2,
            thumbnail: nil,
            overview: nil,
            released: nil,
            rating: nil
        )

        XCTAssertEqual(meta.canonicalEpisodeStreamId(for: episode), "tt456:1:2")
    }

    func testCatalogDisplayTitleTypeSuffixes() {
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "movie", showType: true), "Popular - Movies")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "series", showType: true), "Popular - Series")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "show", showType: true), "Popular - Series")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "anime", showType: true), "Popular - Anime")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Live", contentType: "channel", showType: true), "Live - Channels")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "podcast", showType: true), "Popular - Podcast")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular - Movies", contentType: "movie", showType: true), "Popular - Movies")
        XCTAssertEqual(TVHomeCatalogOrder.catalogDisplayTitle("Popular", contentType: "movie", showType: false), "Popular")
    }

    func testCatalogDisplayTitleWithCustomTitleAndAddonNamePrefixCleaning() {
        // Cleaning redundant prefix
        XCTAssertEqual(
            TVHomeCatalogOrder.cleanCatalogTitle("AIOMetadata - Top 20 TV Shows of the Week", addonName: "AIOMetadata"),
            "Top 20 TV Shows of the Week"
        )
        XCTAssertEqual(
            TVHomeCatalogOrder.cleanCatalogTitle("[AIOMetadata] Top 20 TV Shows of the Week", addonName: "AIOMetadata"),
            "Top 20 TV Shows of the Week"
        )
        XCTAssertEqual(
            TVHomeCatalogOrder.cleanCatalogTitle("AIOMetadata: Top 20 TV Shows of the Week", addonName: "AIOMetadata"),
            "Top 20 TV Shows of the Week"
        )
        XCTAssertEqual(
            TVHomeCatalogOrder.cleanCatalogTitle("AIOMetadata • Top 20 TV Shows of the Week", addonName: "AIOMetadata"),
            "Top 20 TV Shows of the Week"
        )

        // catalogDisplayTitle with addonName cleaning
        XCTAssertEqual(
            TVHomeCatalogOrder.catalogDisplayTitle(
                "AIOMetadata - Top 20 TV Shows of the Week",
                contentType: "series",
                showType: false,
                addonName: "AIOMetadata"
            ),
            "Top 20 TV Shows of the Week"
        )

        // customTitle override takes precedence
        XCTAssertEqual(
            TVHomeCatalogOrder.catalogDisplayTitle(
                "AIOMetadata - Top 20 TV Shows of the Week",
                contentType: "series",
                showType: true,
                addonName: "AIOMetadata",
                customTitle: "My Favorite Shows"
            ),
            "My Favorite Shows"
        )
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

    func testCatalogHomeVisibilityResolverIncludesCollectionSourcesMatchingAndroid() throws {
        let manifestURL = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        let source = CatalogHomeVisibilityResolver.Source(
            addonIdentifier: "https://example.com",
            contentType: "movie",
            catalogID: "popular"
        )
        // Matching Android TV: direct collection sources remain included in layout and home
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
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

    func testCollectionBackedAddonIncludesAllCatalogsMatchingAndroid() throws {
        let manifestURL = try XCTUnwrap(URL(string: "https://example.com/manifest.json"))
        let source = CatalogHomeVisibilityResolver.Source(
            addonIdentifier: "example.addon", contentType: "movie", catalogID: "collection", collectionID: "xperience"
        )
        let collectionOnlyKey = "collection_xperience"
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
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
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "movie", catalogID: "collection",
            collectionSources: [source], manifestURL: manifestURL, explicitHomeKeys: []
        ))
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "movie", catalogID: "collection",
            collectionSources: [source], manifestURL: manifestURL,
            explicitHomeKeys: [collectionOnlyKey, "example.addon_movie_collection"]
        ))
    }

    func testCatalogHomeVisibilityResolverMatchesCompositeIdentifier() throws {
        let manifestURL = try XCTUnwrap(URL(string: "https://example.com/path/manifest.json"))
        let source = CatalogHomeVisibilityResolver.Source(
            addonIdentifier: "addon:example.addon:https://example.com/path",
            contentType: "movie", catalogID: "popular"
        )
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "example.addon", contentType: "movie", catalogID: "popular",
            collectionSources: [source], manifestURL: manifestURL, explicitHomeKeys: []
        ))
    }

    func testCatalogHomeVisibilityResolverCinemetaIdentifierMatching() throws {
        let manifestURL = try XCTUnwrap(URL(string: "https://v3-cinemeta.strem.io/manifest.json"))
        let source = CatalogHomeVisibilityResolver.Source(
            addonIdentifier: "com.linvo.cinemeta",
            contentType: "movie",
            catalogID: "top"
        )
        XCTAssertTrue(CatalogHomeVisibilityResolver.shouldInclude(
            addonID: "cinemeta", contentType: "movie", catalogID: "top",
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
        XCTAssertTrue(PosterArtworkCachePolicy.isVolatile(URL(string: "https://ratingposterdb.com/poster.jpg")!))
        XCTAssertTrue(PosterArtworkCachePolicy.isVolatile(URL(string: "https://api.ratingposterdb.com/poster.jpg")!))
        XCTAssertTrue(PosterArtworkCachePolicy.isVolatile(URL(string: "https://top-posters.com/poster.jpg")!))
        XCTAssertTrue(PosterArtworkCachePolicy.isVolatile(URL(string: "https://postersplus.elfhosted.com/poster.jpg")!))
        XCTAssertFalse(PosterArtworkCachePolicy.isVolatile(URL(string: "https://xperience-app.com.evil.test/a.jpg")!))
        XCTAssertFalse(PosterArtworkCachePolicy.isVolatile(URL(string: "https://image.tmdb.org/t/p/w500/poster.jpg")!))
        XCTAssertFalse(PosterArtworkCachePolicy.isVolatile(URL(string: "https://artworks.thetvdb.com/banners/poster.jpg")!))
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

    func testAsianFilmAndSeriesCollectionTemplateDecoding() throws {
        let json = """
        {
          "id": "asian-collection-1",
          "title": "Asian Film & Series",
          "templateID": "asian-film-series",
          "templateVersion": 1,
          "viewMode": "ROWS",
          "folders": [
            {
              "id": "kisskh-folder",
              "title": "KissKH",
              "coverEmoji": "💋",
              "sources": [
                {
                  "provider": "addon",
                  "addonId": "kisskh",
                  "type": "series",
                  "catalogId": "kisskh-drama",
                  "title": "KissKH • Asian Dramas"
                },
                {
                  "provider": "tmdb",
                  "tmdbSourceType": "DISCOVER",
                  "title": "K-Drama • Popular",
                  "mediaType": "tv",
                  "sortBy": "popularity.desc",
                  "filters": {
                    "withOriginalLanguage": "ko"
                  }
                }
              ]
            },
            {
              "id": "mkv-folder",
              "title": "MKV Asian Hub",
              "coverEmoji": "🎬",
              "sources": [
                {
                  "provider": "addon",
                  "addonId": "mkv",
                  "type": "movie",
                  "catalogId": "mkv-movies",
                  "title": "MKV • Movies"
                }
              ]
            },
            {
              "id": "ott-folder",
              "title": "Asian OTT & Streaming",
              "coverEmoji": "📺",
              "sources": [
                {
                  "provider": "tmdb",
                  "tmdbSourceType": "DISCOVER",
                  "title": "Viki • Popular Series",
                  "mediaType": "tv",
                  "sortBy": "popularity.desc",
                  "filters": {
                    "withWatchProviders": "344",
                    "watchRegion": "US"
                  }
                }
              ]
            }
          ]
        }
        """

        let collection = try decoder.decode(NuvioCollection.self, from: Data(json.utf8))
        XCTAssertEqual(collection.title, "Asian Film & Series")
        XCTAssertEqual(collection.folders.count, 3)

        let kisskhSources = collection.folders[0].resolvedSources
        XCTAssertEqual(kisskhSources.count, 2)
        XCTAssertEqual(kisskhSources[0].normalizedProvider, "addon")
        XCTAssertEqual(kisskhSources[0].addonId, "kisskh")
        XCTAssertEqual(kisskhSources[1].normalizedProvider, "tmdb")
        XCTAssertEqual(kisskhSources[1].filters?.withOriginalLanguage, "ko")

        let mkvSources = collection.folders[1].resolvedSources
        XCTAssertEqual(mkvSources.first?.addonId, "mkv")

        let ottSources = collection.folders[2].resolvedSources
        XCTAssertEqual(ottSources.first?.filters?.withWatchProviders, "344")
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

    func testCollectionFolderViewModeUsesCatalogRows() {
        XCTAssertFalse(CollectionFolderViewMode.tabbedGrid.usesCatalogRows(homeLayout: "Modern"))
        XCTAssertFalse(CollectionFolderViewMode.tabbedGrid.usesCatalogRows(homeLayout: "Grid View"))
        XCTAssertTrue(CollectionFolderViewMode.rows.usesCatalogRows(homeLayout: "Modern"))
        XCTAssertTrue(CollectionFolderViewMode.rows.usesCatalogRows(homeLayout: "Grid View"))

        // Follow layout honors homeLayout setting
        XCTAssertTrue(CollectionFolderViewMode.followLayout.usesCatalogRows(homeLayout: "Modern"))
        XCTAssertTrue(CollectionFolderViewMode.followLayout.usesCatalogRows(homeLayout: "Compact"))
        XCTAssertFalse(CollectionFolderViewMode.followLayout.usesCatalogRows(homeLayout: "Grid View"))
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

    func testAddonManifestCatalogSearchAndDiscoverCapabilities() throws {
        // Cinemeta / BetterPosters style catalog with search and genre extras
        let searchAndDiscoverJSON = """
        {
            "type": "movie",
            "id": "top",
            "name": "Popular",
            "extra": [
                {"name": "search", "isRequired": false},
                {"name": "genre", "isRequired": false, "options": ["Action", "Comedy"]},
                {"name": "skip", "isRequired": false}
            ]
        }
        """
        let catalog1 = try JSONDecoder().decode(AddonManifestCatalog.self, from: Data(searchAndDiscoverJSON.utf8))
        XCTAssertTrue(catalog1.supportsSearch)
        XCTAssertTrue(catalog1.supportsDiscover)
        XCTAssertTrue(catalog1.eligibleForHome)

        // Search-only catalog (e.g. requires search)
        let searchOnlyJSON = """
        {
            "type": "movie",
            "id": "search_catalog",
            "name": "Search",
            "extra": [
                {"name": "search", "isRequired": true}
            ]
        }
        """
        let catalog2 = try JSONDecoder().decode(AddonManifestCatalog.self, from: Data(searchOnlyJSON.utf8))
        XCTAssertTrue(catalog2.supportsSearch)
        XCTAssertFalse(catalog2.supportsDiscover)
        XCTAssertFalse(catalog2.eligibleForHome)

        // Catalog with unfulfillable required extra (e.g. requires actor)
        let actorRequiredJSON = """
        {
            "type": "movie",
            "id": "by_actor",
            "name": "By Actor",
            "extra": [
                {"name": "search", "isRequired": false},
                {"name": "actor", "isRequired": true}
            ]
        }
        """
        let catalog3 = try JSONDecoder().decode(AddonManifestCatalog.self, from: Data(actorRequiredJSON.utf8))
        XCTAssertFalse(catalog3.supportsSearch)
        XCTAssertFalse(catalog3.supportsDiscover)
        XCTAssertFalse(catalog3.eligibleForHome)
    }

    func testSearchDeduplicatesCanonicalAliasesAndPreservesDistinctTitles() {
        func meta(
            id: String,
            type: String,
            name: String,
            year: Int,
            imdbId: String? = nil,
            tmdbId: Int? = nil
        ) -> NuvioMeta {
            NuvioMeta(
                id: id,
                name: name,
                description: nil,
                posterUrl: nil,
                backgroundUrl: nil,
                logoUrl: nil,
                imdbId: imdbId,
                tmdbId: tmdbId,
                type: type,
                year: year,
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
                status: nil,
                videos: nil,
                trailerYtIds: nil,
                externalRatings: nil
            )
        }

        let results = [
            meta(id: "tt1234567", type: "movie", name: "Spider-Man", year: 2002, tmdbId: 123),
            meta(id: "tmdb:123", type: "movie", name: "Spider Man", year: 2002, tmdbId: 123),
            meta(id: "tmdb:456", type: "movie", name: "Spider-Man", year: 2002, tmdbId: 456),
            meta(id: "tmdb:789", type: "series", name: "Spider-Man", year: 2002, tmdbId: 789),
            meta(id: "addon:a:1", type: "movie", name: "Spider Man", year: 2020),
            meta(id: "addon:b:2", type: "movie", name: "Spider-Man", year: 2020)
        ]

        let deduplicated = CinemetaCatalogRepository.deduplicatedSearchResults(results)

        XCTAssertEqual(
            deduplicated.map(\.id),
            ["tt1234567", "tmdb:456", "tmdb:789", "addon:a:1"]
        )
    }

    @MainActor
    func testDiscoverCatalogOptionsAndViewModelStateTransitions() async throws {
        let repo = MockCatalogRepository()
        let sources = await repo.getDiscoverSources()
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].type, "movie")
        XCTAssertEqual(sources[0].catalogName, "Popular Movies")
        XCTAssertEqual(sources[1].type, "series")
        XCTAssertEqual(sources[1].catalogName, "Popular Series")

        let viewModel = DiscoverViewModel(repository: repo)
        // Allow initial sources task to resolve
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(viewModel.typeOptions, ["movie", "series"])
        XCTAssertEqual(viewModel.selectedType, "movie")
        XCTAssertEqual(viewModel.selectedCatalog?.catalogName, "Popular Movies")
        XCTAssertFalse(viewModel.genreOptions.isEmpty)

        // Switch to series
        viewModel.setType("series")
        XCTAssertEqual(viewModel.selectedType, "series")
        XCTAssertEqual(viewModel.selectedCatalog?.catalogName, "Popular Series")

        // Switch genre
        viewModel.setGenre("Action")
        XCTAssertEqual(viewModel.selectedGenre, "Action")
    }

    func testCinemetaMetaDecodesPosterShapeAndMapsTileShape() throws {
        let json = """
        {
            "metas": [
                {
                    "id": "sport:1",
                    "name": "Sky Sports Premier League",
                    "type": "channel",
                    "poster": "https://example.com/poster.jpg",
                    "posterShape": "landscape"
                },
                {
                    "id": "sport:2",
                    "name": "BT Sport",
                    "type": "channel",
                    "poster": "https://example.com/poster2.jpg",
                    "poster_shape": "landscape"
                },
                {
                    "id": "music:1",
                    "name": "Album Art",
                    "type": "music",
                    "poster": "https://example.com/square.jpg",
                    "posterShape": "square"
                },
                {
                    "id": "movie:1",
                    "name": "Standard Movie",
                    "type": "movie",
                    "poster": "https://example.com/movie.jpg"
                }
            ]
        }
        """

        let page = try decoder.decode(CinemetaCatalogResponse.self, from: Data(json.utf8))
        let metas = page.metas.map { $0.toMeta(fallbackType: "channel") }

        XCTAssertEqual(metas[0].posterShape, "landscape")
        XCTAssertEqual(metas[0].tileShape, .landscape)

        XCTAssertEqual(metas[1].posterShape, "landscape")
        XCTAssertEqual(metas[1].tileShape, .landscape)

        XCTAssertEqual(metas[2].posterShape, "square")
        XCTAssertEqual(metas[2].tileShape, .square)

        XCTAssertNil(metas[3].posterShape)
        XCTAssertEqual(metas[3].tileShape, .poster)
    }

    func testAddonManifestCatalogDecodesPosterShape() throws {
        let json = """
        {
            "type": "channel",
            "id": "live_sports",
            "name": "Live Now - Sport",
            "posterShape": "landscape"
        }
        """

        let catalog = try decoder.decode(AddonManifestCatalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.posterShape, "landscape")

        let nuvioCatalog = NuvioCatalog(
            id: catalog.id,
            name: catalog.name,
            type: catalog.type,
            addonIdentifier: "https://example.com/manifest.json",
            posterShape: catalog.posterShape
        )
        XCTAssertEqual(nuvioCatalog.tileShape, .landscape)
    }
}

