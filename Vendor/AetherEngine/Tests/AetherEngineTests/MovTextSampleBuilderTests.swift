import XCTest
@testable import AetherEngine

final class MovTextSampleBuilderTests: XCTestCase {
    func test_sanitize_plainPassesThrough() {
        XCTAssertEqual(MovTextSampleBuilder.sanitize("plain"), "plain")
    }

    func test_sanitize_stripsASSOverrideTagsAndConvertsBreaks() {
        XCTAssertEqual(MovTextSampleBuilder.sanitize("{\\an8}{\\b1}Top{\\b0}\\Nline"), "Top\nline")
    }

    func test_sanitize_convertsLowercaseBreakAndHardSpace() {
        XCTAssertEqual(MovTextSampleBuilder.sanitize("a\\nb\\hc"), "a\nb c")
    }

    func test_sanitize_trimsSurroundingWhitespace() {
        XCTAssertEqual(MovTextSampleBuilder.sanitize("  hello  "), "hello")
    }
}
