import XCTest
@testable import NuvioTV

@MainActor
final class CollectionGenreGroupingTests: XCTestCase {
    func testRenamingGenreDoesNotChangeItsGroup() throws {
        let sources = [discover(mediaType: "movie", filters: ["withGenres": "28|12"])]
        XCTAssertTrue(try destination(title: "Action & Adventure", sources: sources).isGenreDestination)
        XCTAssertTrue(try destination(title: "Mis favoritas de acción", sources: sources).isGenreDestination)
    }

    func testServiceGenreFilterDoesNotTurnServiceIntoGenreGroup() throws {
        let sources = [discover(mediaType: "movie", filters: [
            "withGenres": "28", "withWatchProviders": "8"
        ])]
        XCTAssertFalse(try destination(title: "Netflix", sources: sources).isGenreDestination)
    }

    func testServicePresentationRemainsDirect() throws {
        let sources = [discover(mediaType: "movie", filters: ["withGenres": "28"])]
        XCTAssertFalse(try destination(sources: sources, style: "STREAMING_SERVICE").isGenreDestination)
    }

    func testHorrorTemplateIncludesItsKeywordBasedSeriesRow() throws {
        let sources = [
            discover(mediaType: "movie", filters: ["withGenres": "27"]),
            discover(mediaType: "tv", filters: ["withKeywords": "315058"])
        ]
        XCTAssertTrue(try destination(sources: sources).isGenreDestination)
    }

    func testMixedAndUnclassifiedFoldersStayDirect() throws {
        let sources: [[String: Any]] = [
            discover(mediaType: "movie", filters: ["withGenres": "35"]),
            ["provider": "addon", "addonId": "example", "type": "movie", "catalogId": "all"]
        ]
        XCTAssertFalse(try destination(sources: sources).isGenreDestination)
        XCTAssertFalse(try destination(sources: []).isGenreDestination)
    }

    func testCustomAddonGenreFolderIsGrouped() throws {
        let sources: [[String: Any]] = [[
            "provider": "addon", "addonId": "example", "type": "movie",
            "catalogId": "movies", "genre": "Comedy"
        ]]
        XCTAssertTrue(try destination(sources: sources).isGenreDestination)
    }

    private func discover(mediaType: String, filters: [String: String]) -> [String: Any] {
        ["provider": "tmdb", "tmdbSourceType": "DISCOVER", "mediaType": mediaType, "filters": filters]
    }

    private func destination(
        title: String = "Renamed collection",
        sources: [[String: Any]],
        style: String? = nil
    ) throws -> CollectionHomeDestination {
        var json: [String: Any] = ["id": "folder", "title": title, "sources": sources]
        if let style { json["presentationStyle"] = style }
        let data = try JSONSerialization.data(withJSONObject: json)
        let folder = try JSONDecoder().decode(NuvioCollectionFolder.self, from: data)
        return CollectionHomeDestination(
            id: CollectionHomeID(profileID: "profile", collectionID: "collection", folderID: folder.id),
            collectionTitle: "Collection",
            folder: TVCollectionFolderItem(collectionId: "collection", folder: folder, sources: folder.resolvedSources)
        )
    }
}
