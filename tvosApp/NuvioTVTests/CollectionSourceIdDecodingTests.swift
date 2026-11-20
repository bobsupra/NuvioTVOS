import Foundation
import XCTest
@testable import NuvioTV

final class CollectionSourceIdDecodingTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testCollectionWithIdsSavedAsTextStillLoads() throws {
        // Another client saved this collection with its ids in quotes. Reading them
        // only as numbers made the whole collection fail, so its Home row never showed.
        let json = """
        {
          "id": "collection-SPOTLIGHTS",
          "title": "Spotlight",
          "folders": [{
            "id": "headliner",
            "title": "The Headliner",
            "catalogSources": [],
            "focusGlowEnabled": true,
            "sources": [
              {
                "provider": "tmdb",
                "tmdbSourceType": "LIST",
                "title": "The Headliner",
                "tmdbId": "8687275",
                "mediaType": "MOVIE",
                "sortBy": "vote_average.desc",
                "filters": {}
              },
              {
                "provider": "trakt",
                "title": "Watchlist",
                "traktListId": "123456"
              },
              {
                "provider": "mdblist",
                "title": "Top Rated",
                "mdblistId": " 42 "
              }
            ]
          }]
        }
        """

        let collection = try decoder.decode(NuvioCollection.self, from: Data(json.utf8))
        let sources = try XCTUnwrap(collection.folders.first?.resolvedSources)

        XCTAssertEqual(collection.title, "Spotlight")
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources[0].tmdbSourceType, "LIST")
        XCTAssertEqual(sources[0].tmdbId, 8687275)
        XCTAssertEqual(sources[1].traktListId, 123456)
        XCTAssertEqual(sources[2].mdblistId, 42)
    }

    func testIdsSavedAsNumbersStillLoad() throws {
        let json = """
        {"provider": "tmdb", "tmdbSourceType": "COMPANY", "title": "Pixar", "tmdbId": 3, "traktListId": 77}
        """

        let source = try decoder.decode(NuvioCollectionSource.self, from: Data(json.utf8))

        XCTAssertEqual(source.tmdbId, 3)
        XCTAssertEqual(source.traktListId, 77)
    }

    func testIdThatIsNotANumberIsLeftEmpty() throws {
        let json = """
        {"provider": "tmdb", "tmdbSourceType": "LIST", "title": "Broken", "tmdbId": "not-a-number"}
        """

        let source = try decoder.decode(NuvioCollectionSource.self, from: Data(json.utf8))

        XCTAssertNil(source.tmdbId)
        XCTAssertEqual(source.title, "Broken")
    }
}
