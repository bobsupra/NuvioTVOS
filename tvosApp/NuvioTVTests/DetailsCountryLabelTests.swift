import XCTest
@testable import NuvioTV

final class DetailsCountryLabelTests: XCTestCase {
    private let english = Locale(identifier: "en_US")

    func testATwoLetterCodeIsShownAsTheCountrysName() {
        XCTAssertEqual(DetailsCountryLabel.text(for: "US", locale: english), "United States")
        XCTAssertEqual(DetailsCountryLabel.text(for: "br", locale: english), "Brazil")
    }

    func testAThreeLetterCodeIsShownAsTheCountrysName() {
        XCTAssertEqual(DetailsCountryLabel.text(for: "usa", locale: english), "United States")
        XCTAssertEqual(DetailsCountryLabel.text(for: "bra", locale: english), "Brazil")
        XCTAssertEqual(DetailsCountryLabel.text(for: "GBR", locale: english), "United Kingdom")
    }

    func testTheNameFollowsTheLocale() {
        XCTAssertEqual(DetailsCountryLabel.text(for: "usa", locale: Locale(identifier: "pt_PT")), "Estados Unidos")
    }

    func testOnlyTheFirstCountryIsShown() {
        XCTAssertEqual(DetailsCountryLabel.text(for: "usa, gbr", locale: english), "United States")
        XCTAssertEqual(DetailsCountryLabel.text(for: " United States , Canada", locale: english), "United States")
    }

    func testANameIsShownAsItIs() {
        XCTAssertEqual(DetailsCountryLabel.text(for: "South Korea", locale: english), "South Korea")
    }

    func testAnUnknownCodeIsShownInCapitals() {
        XCTAssertEqual(DetailsCountryLabel.text(for: "xyz", locale: english), "XYZ")
    }

    func testNothingIsShownWithoutACountry() {
        XCTAssertNil(DetailsCountryLabel.text(for: nil, locale: english))
        XCTAssertNil(DetailsCountryLabel.text(for: "  ", locale: english))
        XCTAssertNil(DetailsCountryLabel.text(for: " , ", locale: english))
    }
}
