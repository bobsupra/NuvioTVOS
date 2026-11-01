import Foundation
import XCTest
@testable import NuvioTV

final class SearchCatalogVisibilityTests: XCTestCase {
    private func catalog(_ json: String) throws -> AddonManifestCatalog {
        try JSONDecoder().decode(AddonManifestCatalog.self, from: Data(json.utf8))
    }

    private func isAllowed(
        _ catalog: AddonManifestCatalog,
        in catalogs: [AddonManifestCatalog],
        disabled: Set<String> = [],
        disabledAddonIDs: Set<String> = [],
        disabledAddonNames: Set<String> = []
    ) -> Bool {
        CinemetaCatalogRepository.shouldSearchCatalog(
            catalog,
            in: catalogs,
            addonID: "fixture.addon",
            addonName: "Fixture Addon",
            disabledKeys: disabled,
            disabledAddonIDs: disabledAddonIDs,
            disabledAddonNames: disabledAddonNames
        )
    }

    func testDisablingOneSearchableHomeCatalogSkipsOnlyThatCatalog() throws {
        let movies = try catalog(#"{"type":"movie","id":"popular"}"#)
        let series = try catalog(#"{"type":"series","id":"popular"}"#)
        let sources = [movies, series]
        let hidden: Set<String> = ["fixture.addon_movie_popular"]

        XCTAssertFalse(isAllowed(movies, in: sources, disabled: hidden))
        XCTAssertTrue(isAllowed(series, in: sources, disabled: hidden))
        XCTAssertTrue(isAllowed(movies, in: sources))
    }

    func testSearchOnlyEndpointRemainsSearchableRegardlessOfHomeCatalogToggles() throws {
        let searchOnly = try catalog(
            #"{"type":"movie","id":"search.movie","extra":[{"name":"search","isRequired":true}]}"#
        )
        let popular = try catalog(#"{"type":"movie","id":"popular"}"#)
        let topRated = try catalog(#"{"type":"movie","id":"top_rated"}"#)
        let sources = [searchOnly, popular, topRated]

        XCTAssertFalse(searchOnly.eligibleForHome)
        // Remains searchable even if all Home rows of the same type are disabled,
        // and even if its own key appears in disabled keys (e.g., from account sync).
        XCTAssertTrue(isAllowed(
            searchOnly, in: sources,
            disabled: [
                "fixture.addon_movie_popular",
                "fixture.addon_movie_top_rated",
                "fixture.addon_movie_search.movie"
            ]
        ))
    }

    func testSearchOnlyAddonWithNoHomeCatalogRemainsSearchable() throws {
        let searchOnly = try catalog(
            #"{"type":"movie","id":"search","extra":[{"name":"search","isRequired":true}]}"#
        )
        XCTAssertTrue(isAllowed(searchOnly, in: [searchOnly]))
    }

    func testHiddenProviderSuppressesEverySearchTarget() throws {
        let popular = try catalog(#"{"type":"movie","id":"popular"}"#)
        XCTAssertFalse(isAllowed(
            popular, in: [popular], disabledAddonIDs: ["fixture.addon"]
        ))
        XCTAssertFalse(isAllowed(
            popular, in: [popular], disabledAddonNames: ["fixtureaddon"]
        ))
        XCTAssertTrue(isAllowed(popular, in: [popular]))
    }

    func testHiddenMovieCatalogDoesNotSuppressSeriesOnlySearch() throws {
        let movie = try catalog(#"{"type":"movie","id":"popular"}"#)
        let seriesSearch = try catalog(
            #"{"type":"series","id":"search","extra":[{"name":"search","isRequired":true}]}"#
        )
        XCTAssertTrue(isAllowed(
            seriesSearch, in: [movie, seriesSearch],
            disabled: ["fixture.addon_movie_popular"]
        ))
    }
}
