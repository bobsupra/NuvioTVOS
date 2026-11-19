import Foundation
import XCTest
@testable import NuvioTV

final class CatalogTruncationTests: XCTestCase {
    private func catalog() throws -> [String: [String: String]] {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "AppLanguageCatalog", withExtension: "json")
                ?? Bundle.main.url(forResource: "AppLanguageCatalog", withExtension: "json", subdirectory: "Resources")
        )
        return try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
    }

    func testNoCatalogStringIsCutOffAtAQuote() throws {
        // The import stopped at the first escaped quote and left a lone
        // backslash, so a title showed only "\".
        var cutOff: [String] = []
        for (language, table) in try catalog() {
            for (key, value) in table where value.hasSuffix("\\") {
                cutOff.append("\(language)/\(key)")
            }
        }
        XCTAssertEqual(cutOff.sorted(), [])
    }

    func testAniListAndMyAnimeListTextIsWhole() {
        L10n.reload(languageTag: "en")
        defer { L10n.reload(languageTag: nil) }
        XCTAssertEqual(
            L10n.string("settings_anilist_plus_status", fallback: "\"+\" in Details Adds as"),
            "\"+\" in Details Adds as"
        )
        XCTAssertEqual(
            L10n.string("settings_mal_section_account_subtitle", fallback: ""),
            "Your MAL lists on Home, \"+\" in details, and what you watch written to MAL"
        )
    }
}
