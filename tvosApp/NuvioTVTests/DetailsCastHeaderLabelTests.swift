import XCTest
@testable import NuvioTV

final class DetailsCastHeaderLabelTests: XCTestCase {
    func testMovieAndSeriesUseTheirRespectiveLabels() {
        XCTAssertEqual(DetailsCastHeaderLabel.localizationKey(for: " Movie "), "details_director_and_cast")
        XCTAssertEqual(DetailsCastHeaderLabel.localizationKey(for: "FILM"), "details_director_and_cast")
        XCTAssertEqual(DetailsCastHeaderLabel.localizationKey(for: "series"), "details_creator_and_cast")
        XCTAssertEqual(DetailsCastHeaderLabel.localizationKey(for: "tv_show"), "details_creator_and_cast")
    }

    func testUnknownTypeUsesNeutralLabel() {
        XCTAssertEqual(DetailsCastHeaderLabel.localizationKey(for: "channel"), "details_cast_and_crew")
        XCTAssertEqual(DetailsCastHeaderLabel.localizationKey(for: ""), "details_cast_and_crew")
    }
}
