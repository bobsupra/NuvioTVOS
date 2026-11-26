import XCTest
@testable import NuvioTV

/// The IMDb id some add-ons put after their own prefix, which Simkl and MDBList requests
/// are sent with.
final class AddonPrefixedIMDbIDTests: XCTestCase {
    func testAnIMDbIDAfterAnAddonPrefixIsFound() {
        XCTAssertEqual(NuvioMeta.imdbIDAfterAddonPrefix(in: "cotonet:tt16418808"), "tt16418808")
        XCTAssertEqual(NuvioMeta.imdbIDAfterAddonPrefix(in: "ptgdrive:tt12853970"), "tt12853970")
        XCTAssertEqual(NuvioMeta.imdbIDAfterAddonPrefix(in: "cotonet:tt16418808:1:3"), "tt16418808")
    }

    /// Only a whole segment after the first counts; a leading IMDb id is read by the
    /// caller's own rules, and an id is never picked out of free text.
    func testOnlyAWholeSegmentAfterThePrefixCounts() {
        XCTAssertNil(NuvioMeta.imdbIDAfterAddonPrefix(in: "tt0944947"))
        XCTAssertNil(NuvioMeta.imdbIDAfterAddonPrefix(in: "tt0944947:1:2"))
        XCTAssertNil(NuvioMeta.imdbIDAfterAddonPrefix(in: "tmdb:1399"))
        XCTAssertNil(NuvioMeta.imdbIDAfterAddonPrefix(in: "addon:ttx12"))
        XCTAssertNil(NuvioMeta.imdbIDAfterAddonPrefix(in: "addon:see tt0944947"))
    }
}
