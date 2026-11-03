import Foundation
import XCTest
@testable import NuvioTV

final class SearchCatalogVisibilityTests: XCTestCase {
    private func catalog(_ json: String) throws -> AddonManifestCatalog {
        try JSONDecoder().decode(AddonManifestCatalog.self, from: Data(json.utf8))
    }

    func testBrowseableCatalogWithOptionalSearchExtraQualifiesForSearch() throws {
        let popular = try catalog(
            #"{"type":"movie","id":"popular","extra":[{"name":"search","isRequired":false}]}"#
        )

        XCTAssertTrue(popular.eligibleForHome)
        XCTAssertTrue(popular.supportsSearch)
    }

    func testSearchOnlyMovieAndSeriesEndpointsQualify() throws {
        let movie = try catalog(
            #"{"type":"movie","id":"search.movie","extra":[{"name":"search","isRequired":true}]}"#
        )
        let series = try catalog(
            #"{"type":"series","id":"search.series","extra":[{"name":"search","isRequired":true}]}"#
        )

        XCTAssertFalse(movie.eligibleForHome)
        XCTAssertFalse(series.eligibleForHome)
        XCTAssertTrue(movie.supportsSearch)
        XCTAssertTrue(series.supportsSearch)
    }

    func testSearchRequiresStructuredExtraAndNoOtherRequiredExtra() throws {
        let legacySupportedOnly = try catalog(
            #"{"type":"movie","id":"legacy","extraSupported":["search"]}"#
        )
        let legacyRequiredOnly = try catalog(
            #"{"type":"movie","id":"legacy-required","extraRequired":["search"]}"#
        )
        let blockedByRequiredGenre = try catalog(
            #"{"type":"movie","id":"genre-search","extra":[{"name":"search"},{"name":"genre","isRequired":true,"options":["Drama"]}]}"#
        )
        let mixedCaseSearchName = try catalog(
            #"{"type":"movie","id":"mixed-case","extra":[{"name":"Search","isRequired":true}]}"#
        )
        let malformedLegacyExtraSupported = try catalog(
            #"{"type":"movie","id":"search","extra":[{"name":"search","isRequired":false}],"extraSupported":{"malformed":true}}"#
        )

        XCTAssertFalse(legacySupportedOnly.supportsSearch)
        XCTAssertFalse(legacyRequiredOnly.supportsSearch)
        XCTAssertFalse(blockedByRequiredGenre.supportsSearch)
        XCTAssertFalse(mixedCaseSearchName.supportsSearch)
        XCTAssertTrue(malformedLegacyExtraSupported.supportsSearch)
    }
}
