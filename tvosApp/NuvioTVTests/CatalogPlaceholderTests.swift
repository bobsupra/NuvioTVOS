import Foundation
import XCTest
@testable import NuvioTV

final class CatalogPlaceholderTests: XCTestCase {
    private func catalog() throws -> [String: [String: String]] {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "AppLanguageCatalog", withExtension: "json")
                ?? Bundle.main.url(forResource: "AppLanguageCatalog", withExtension: "json", subdirectory: "Resources")
        )
        return try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: url))
    }

    func testNoCatalogStringContainsSwiftInterpolation() throws {
        // A catalog value wins over the code's fallback, so Swift code such as
        // "\(release.displayVersion)" copied into the catalog shows up on screen.
        var leaks: [String] = []
        for (language, table) in try catalog() {
            for (key, value) in table where value.contains("\\(") {
                leaks.append("\(language)/\(key)")
            }
        }
        XCTAssertEqual(leaks.sorted(), [])
    }

    func testReleaseUpdateStringsTakeTheVersionInEveryLanguage() throws {
        let keys = [
            "release_update_available_title",
            "release_update_available_subtitle",
            "release_update_install_title",
            "release_update_details_subtitle"
        ]
        for (language, table) in try catalog() {
            for key in keys {
                guard let value = table[key] else { continue }
                XCTAssertEqual(value.components(separatedBy: "%@").count, 2, "\(language)/\(key) needs one %@: \(value)")
            }
        }
    }

    func testReleaseUpdateTitleShowsTheVersion() {
        L10n.reload(languageTag: "en")
        defer { L10n.reload(languageTag: nil) }
        let title = L10n.format("release_update_available_title", fallback: "NuvioTV %@ is available", "3.6.0")
        XCTAssertEqual(title, "NuvioTV 3.6.0 is available")
        let details = L10n.format("release_update_details_subtitle", fallback: "View version %@ release notes and QR code", "3.6.0")
        XCTAssertEqual(details, "View version 3.6.0 release notes and QR code")
    }
}
