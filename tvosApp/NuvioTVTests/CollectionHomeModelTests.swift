import XCTest
@testable import NuvioTV

@MainActor
final class CollectionHomeModelTests: XCTestCase {

    func testCollectionSidebarPreferencesProfileIsolation() {
        let profileA = "profile-a-\(UUID().uuidString)"
        let profileB = "profile-b-\(UUID().uuidString)"
        let col1 = "collection-1"
        let col2 = "collection-2"

        CollectionSidebarPreferences.setEnabled(true, collectionID: col1, profileID: profileA)
        CollectionSidebarPreferences.setEnabled(true, collectionID: col2, profileID: profileB)

        let aIDs = CollectionSidebarPreferences.collectionIDs(profileID: profileA)
        let bIDs = CollectionSidebarPreferences.collectionIDs(profileID: profileB)

        XCTAssertTrue(aIDs.contains(col1))
        XCTAssertFalse(aIDs.contains(col2))

        XCTAssertTrue(bIDs.contains(col2))
        XCTAssertFalse(bIDs.contains(col1))

        CollectionSidebarPreferences.setEnabled(false, collectionID: col1, profileID: profileA)
        XCTAssertFalse(CollectionSidebarPreferences.collectionIDs(profileID: profileA).contains(col1))
    }

    func testCollectionHomeIDKeyConsistency() {
        let id1 = CollectionHomeID(profileID: "prof1", collectionID: "col1", folderID: "fold1")
        let id2 = CollectionHomeID(profileID: "prof1", collectionID: "col1", folderID: "fold1")
        let id3 = CollectionHomeID(profileID: "prof1", collectionID: "col2", folderID: "fold1")

        XCTAssertEqual(id1, id2)
        XCTAssertEqual(id1.key, id2.key)
        XCTAssertNotEqual(id1, id3)
        XCTAssertNotEqual(id1.key, id3.key)
    }

    func testCollectionHomeModelLifecycle() {
        let profileID = "test-profile-\(UUID().uuidString)"
        let folderJSON = """
        {"id": "fold1", "title": "Folder 1"}
        """.data(using: .utf8)!
        let folder = try! JSONDecoder().decode(NuvioCollectionFolder.self, from: folderJSON)
        let destination = CollectionHomeDestination(
            id: CollectionHomeID(profileID: profileID, collectionID: "col1", folderID: "fold1"),
            collectionTitle: "Test Collection",
            folder: TVCollectionFolderItem(
                collectionId: "col1",
                folder: folder,
                sources: [],
                viewMode: .followLayout,
                showAllTab: false
            )
        )
        let repository = CinemetaCatalogRepository()
        let model = CollectionHomeModel(destination: destination, repository: repository)

        XCTAssertTrue(model.failures.isEmpty)
        XCTAssertTrue(model.retryingRows.isEmpty)
        XCTAssertNil(model.store.hero)
        XCTAssertTrue(model.store.sections.isEmpty)

        model.releaseCatalogs()
        XCTAssertTrue(model.failures.isEmpty)
        XCTAssertTrue(model.store.sections.isEmpty)
    }

    func testMdbListCollectionSourceDecodingAndRouteKey() throws {
        // CamelCase decoding
        let camelJSON = """
        {
            "provider": "mdblist",
            "title": "Top Sci-Fi",
            "mdblistId": 12345,
            "mdblistSlug": "linaspurinis/top-sci-fi",
            "mdblistUrl": "https://mdblist.com/lists/linaspurinis/top-sci-fi",
            "mediaType": "movie",
            "sortBy": "score"
        }
        """.data(using: .utf8)!
        let camelSource = try JSONDecoder().decode(NuvioCollectionSource.self, from: camelJSON)
        XCTAssertEqual(camelSource.provider, "mdblist")
        XCTAssertEqual(camelSource.title, "Top Sci-Fi")
        XCTAssertEqual(camelSource.mdblistId, 12345)
        XCTAssertEqual(camelSource.mdblistSlug, "linaspurinis/top-sci-fi")
        XCTAssertEqual(camelSource.mdblistUrl, "https://mdblist.com/lists/linaspurinis/top-sci-fi")
        XCTAssertEqual(camelSource.mediaType, "movie")
        XCTAssertEqual(camelSource.sortBy, "score")
        XCTAssertEqual(camelSource.routeKey, "mdblist_12345_movie_score_")

        // Snake_case decoding (Android parity)
        let snakeJSON = """
        {
            "provider": "mdblist",
            "title": "Staff Picks",
            "mdblist_id": 98765,
            "mdblist_slug": "staff/picks",
            "mdblist_url": "https://mdblist.com/lists/staff/picks",
            "media_type": "series"
        }
        """.data(using: .utf8)!
        let snakeSource = try JSONDecoder().decode(NuvioCollectionSource.self, from: snakeJSON)
        XCTAssertEqual(snakeSource.provider, "mdblist")
        XCTAssertEqual(snakeSource.title, "Staff Picks")
        XCTAssertEqual(snakeSource.mdblistId, 98765)
        XCTAssertEqual(snakeSource.mdblistSlug, "staff/picks")
        XCTAssertEqual(snakeSource.mdblistUrl, "https://mdblist.com/lists/staff/picks")
        XCTAssertEqual(snakeSource.mediaType, "series")

        // Route key with slug fallback when url is absent
        let slugOnlySource = NuvioCollectionSource(
            provider: "mdblist",
            mdblistSlug: "curator/hidden-gems"
        )
        XCTAssertEqual(slugOnlySource.routeKey, "mdblist_curator/hidden-gems___")

        // Route key with id fallback when url and slug are absent
        let idOnlySource = NuvioCollectionSource(
            provider: "mdblist",
            mdblistId: 4421
        )
        XCTAssertEqual(idOnlySource.routeKey, "mdblist_4421___")
    }

    func testTmdbCollectionCustomFiltersDecodingAndEncoding() throws {
        // CamelCase decoding with custom inclusions/exclusions
        let camelJSON = """
        {
            "withGenres": "28,878",
            "withoutGenres": "27,53",
            "withOriginalLanguage": "en",
            "withoutOriginalLanguage": "es",
            "withOriginCountry": "US",
            "withoutOriginCountry": "CN",
            "withKeywords": "123,456",
            "withoutKeywords": "789",
            "withCompanies": "33",
            "withoutCompanies": "420",
            "voteAverageGte": 7.5,
            "voteAverageLte": 9.5,
            "voteCountGte": 1000,
            "voteCountLte": 50000,
            "releaseDateGte": "2020-01-01",
            "releaseDateLte": "2024-12-31",
            "year": 2023,
            "withWatchProviders": "8",
            "withoutWatchProviders": "9",
            "watchRegion": "US"
        }
        """.data(using: .utf8)!
        let filters = try JSONDecoder().decode(NuvioTmdbCollectionFilters.self, from: camelJSON)
        XCTAssertEqual(filters.withGenres, "28,878")
        XCTAssertEqual(filters.withoutGenres, "27,53")
        XCTAssertEqual(filters.withOriginalLanguage, "en")
        XCTAssertEqual(filters.withoutOriginalLanguage, "es")
        XCTAssertEqual(filters.withOriginCountry, "US")
        XCTAssertEqual(filters.withoutOriginCountry, "CN")
        XCTAssertEqual(filters.withKeywords, "123,456")
        XCTAssertEqual(filters.withoutKeywords, "789")
        XCTAssertEqual(filters.withCompanies, "33")
        XCTAssertEqual(filters.withoutCompanies, "420")
        XCTAssertEqual(filters.voteAverageGte, 7.5)
        XCTAssertEqual(filters.voteAverageLte, 9.5)
        XCTAssertEqual(filters.voteCountGte, 1000)
        XCTAssertEqual(filters.voteCountLte, 50000)
        XCTAssertEqual(filters.releaseDateGte, "2020-01-01")
        XCTAssertEqual(filters.releaseDateLte, "2024-12-31")
        XCTAssertEqual(filters.year, 2023)
        XCTAssertEqual(filters.withWatchProviders, "8")
        XCTAssertEqual(filters.withoutWatchProviders, "9")
        XCTAssertEqual(filters.watchRegion, "US")

        // Snake_case decoding (Android parity)
        let snakeJSON = """
        {
            "with_genres": "35",
            "without_genres": "18",
            "with_original_language": "ko",
            "without_original_language": "ja",
            "with_origin_country": "KR",
            "without_origin_country": "JP",
            "with_keywords": "99",
            "without_keywords": "88",
            "with_companies": "10",
            "without_companies": "20",
            "vote_average.gte": 8.0,
            "vote_average.lte": 10.0,
            "vote_count.gte": 500,
            "vote_count.lte": 10000,
            "primary_release_date.gte": "2022-01-01",
            "primary_release_date.lte": "2023-12-31",
            "with_watch_providers": "8",
            "without_watch_providers": "15"
        }
        """.data(using: .utf8)!
        let snakeFilters = try JSONDecoder().decode(NuvioTmdbCollectionFilters.self, from: snakeJSON)
        XCTAssertEqual(snakeFilters.withGenres, "35")
        XCTAssertEqual(snakeFilters.withoutGenres, "18")
        XCTAssertEqual(snakeFilters.withOriginalLanguage, "ko")
        XCTAssertEqual(snakeFilters.withoutOriginalLanguage, "ja")
        XCTAssertEqual(snakeFilters.withOriginCountry, "KR")
        XCTAssertEqual(snakeFilters.withoutOriginCountry, "JP")
        XCTAssertEqual(snakeFilters.withKeywords, "99")
        XCTAssertEqual(snakeFilters.withoutKeywords, "88")
        XCTAssertEqual(snakeFilters.withCompanies, "10")
        XCTAssertEqual(snakeFilters.withoutCompanies, "20")
        XCTAssertEqual(snakeFilters.voteAverageGte, 8.0)
        XCTAssertEqual(snakeFilters.voteAverageLte, 10.0)
        XCTAssertEqual(snakeFilters.voteCountGte, 500)
        XCTAssertEqual(snakeFilters.voteCountLte, 10000)
        XCTAssertEqual(snakeFilters.releaseDateGte, "2022-01-01")
        XCTAssertEqual(snakeFilters.releaseDateLte, "2023-12-31")
        XCTAssertEqual(snakeFilters.withWatchProviders, "8")
        XCTAssertEqual(snakeFilters.withoutWatchProviders, "15")

        // Roundtrip encoding and decoding
        let encodedData = try JSONEncoder().encode(filters)
        let roundtripFilters = try JSONDecoder().decode(NuvioTmdbCollectionFilters.self, from: encodedData)
        XCTAssertEqual(roundtripFilters, filters)

        // Route key distinctiveness for TMDB source
        let sourceA = NuvioCollectionSource(
            provider: "tmdb",
            tmdbSourceType: "DISCOVER",
            filters: NuvioTmdbCollectionFilters(withGenres: "28", withoutGenres: "27")
        )
        let sourceB = NuvioCollectionSource(
            provider: "tmdb",
            tmdbSourceType: "DISCOVER",
            filters: NuvioTmdbCollectionFilters(withGenres: "28", withoutGenres: "35")
        )
        XCTAssertNotEqual(sourceA.routeKey, sourceB.routeKey)
    }

    func testTmdbDateNormalizerFormatsAndRanges() {
        // Direct ISO date format
        XCTAssertEqual(TmdbDateNormalizer.normalize("2000-01-01"), "2000-01-01")
        XCTAssertEqual(TmdbDateNormalizer.normalize("2010-12-31", isEndDate: true), "2010-12-31")

        // Human-readable dates (user issue #391: e.g. from 01 January 2000 to 31 December 2010)
        XCTAssertEqual(TmdbDateNormalizer.normalize("01 January 2000"), "2000-01-01")
        XCTAssertEqual(TmdbDateNormalizer.normalize("31 December 2010", isEndDate: true), "2010-12-31")
        XCTAssertEqual(TmdbDateNormalizer.normalize("January 1, 2000"), "2000-01-01")
        XCTAssertEqual(TmdbDateNormalizer.normalize("December 31, 2010", isEndDate: true), "2010-12-31")

        // Compound date range strings
        let compound = "01 January 2000 to 31 December 2010"
        XCTAssertEqual(TmdbDateNormalizer.normalize(compound, isEndDate: false), "2000-01-01")
        XCTAssertEqual(TmdbDateNormalizer.normalize(compound, isEndDate: true), "2010-12-31")

        // Hyphenated range
        let hyphenated = "2000-01-01 - 2010-12-31"
        XCTAssertEqual(TmdbDateNormalizer.normalize(hyphenated, isEndDate: false), "2000-01-01")
        XCTAssertEqual(TmdbDateNormalizer.normalize(hyphenated, isEndDate: true), "2010-12-31")

        // Year only
        XCTAssertEqual(TmdbDateNormalizer.normalize("2000", isEndDate: false), "2000-01-01")
        XCTAssertEqual(TmdbDateNormalizer.normalize("2010", isEndDate: true), "2010-12-31")

        // Blank input
        XCTAssertNil(TmdbDateNormalizer.normalize(""))
        XCTAssertNil(TmdbDateNormalizer.normalize("   "))
    }

    func testTmdbCollectionFiltersDateNormalization() throws {
        let json = """
        {
            "releaseDateGte": "01 January 2000",
            "releaseDateLte": "31 December 2010"
        }
        """.data(using: .utf8)!
        let filters = try JSONDecoder().decode(NuvioTmdbCollectionFilters.self, from: json)
        XCTAssertEqual(filters.releaseDateGte, "2000-01-01")
        XCTAssertEqual(filters.releaseDateLte, "2010-12-31")

        let programmatic = NuvioTmdbCollectionFilters(
            releaseDateGte: "01 January 2000",
            releaseDateLte: "31 December 2010"
        )
        XCTAssertEqual(programmatic.releaseDateGte, "2000-01-01")
        XCTAssertEqual(programmatic.releaseDateLte, "2010-12-31")
    }

    func testCollectionSourceResolverMdbListLabels() {
        // Title precedence
        let withTitle = NuvioCollectionSource(
            provider: "mdblist",
            title: "My Custom Sci-Fi",
            mdblistSlug: "user/cyberpunk"
        )
        XCTAssertEqual(CollectionSourceResolver.label(for: withTitle), "My Custom Sci-Fi")

        // Slug fallback formatted
        let withSlug = NuvioCollectionSource(
            provider: "mdblist",
            mdblistSlug: "user/space-western"
        )
        XCTAssertEqual(CollectionSourceResolver.label(for: withSlug), "Space Western")

        // ID fallback
        let withId = NuvioCollectionSource(
            provider: "mdblist",
            mdblistId: 9912
        )
        XCTAssertEqual(CollectionSourceResolver.label(for: withId), "MDBList #9912")

        // Fallback
        let generic = NuvioCollectionSource(provider: "mdblist")
        XCTAssertEqual(CollectionSourceResolver.label(for: generic), "MDBList")
    }

    func testCollectionFolderWithMdbListAndCustomTmdbSourcesDecoding() throws {
        let folderJSON = """
        {
            "id": "folder_mixed",
            "title": "Mixed Catalogs",
            "sources": [
                {
                    "provider": "mdblist",
                    "title": "Top Anime",
                    "mdblistSlug": "animelist/top-50",
                    "mdblistUrl": "https://mdblist.com/lists/animelist/top-50",
                    "mediaType": "series"
                },
                {
                    "provider": "tmdb",
                    "tmdbSourceType": "DISCOVER",
                    "title": "Filtered Sci-Fi",
                    "mediaType": "movie",
                    "filters": {
                        "withGenres": "878",
                        "withoutGenres": "27",
                        "voteAverageGte": 7.0,
                        "withoutOriginalLanguage": "fr"
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let decodedFolder = try JSONDecoder().decode(NuvioCollectionFolder.self, from: folderJSON)

        XCTAssertEqual(decodedFolder.id, "folder_mixed")
        XCTAssertEqual(decodedFolder.title, "Mixed Catalogs")
        XCTAssertEqual(decodedFolder.resolvedSources.count, 2)

        let mdbSource = decodedFolder.resolvedSources[0]
        XCTAssertEqual(mdbSource.provider, "mdblist")
        XCTAssertEqual(mdbSource.title, "Top Anime")
        XCTAssertEqual(mdbSource.mdblistSlug, "animelist/top-50")
        XCTAssertEqual(mdbSource.mdblistUrl, "https://mdblist.com/lists/animelist/top-50")
        XCTAssertEqual(mdbSource.mediaType, "series")

        let tmdbSource = decodedFolder.resolvedSources[1]
        XCTAssertEqual(tmdbSource.provider, "tmdb")
        XCTAssertEqual(tmdbSource.title, "Filtered Sci-Fi")
        XCTAssertEqual(tmdbSource.filters?.withGenres, "878")
        XCTAssertEqual(tmdbSource.filters?.withoutGenres, "27")
        XCTAssertEqual(tmdbSource.filters?.withoutOriginalLanguage, "fr")
        XCTAssertEqual(tmdbSource.filters?.voteAverageGte, 7.0)
    }
}
