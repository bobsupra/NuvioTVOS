import XCTest
@testable import NuvioTV

/// Regression cover for the add-on catalog decoder. A Stremio catalog page is
/// decoded as one array of metas, so a single entry with an off-spec field
/// shape used to throw and drop the whole row from Home.
final class CatalogDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

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
}
