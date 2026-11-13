import XCTest
@testable import NuvioTV

final class IPTVChannelFilterTests: XCTestCase {
    func testSearchAndGroupAreAppliedTogether() {
        XCTAssertTrue(IPTVChannelFilter.matches(name: "News World", group: "News", query: "world", selectedGroup: "News"))
        XCTAssertFalse(IPTVChannelFilter.matches(name: "News World", group: "News", query: "world", selectedGroup: "Sports"))
        XCTAssertFalse(IPTVChannelFilter.matches(name: "News World", group: "News", query: "sports", selectedGroup: nil))
        XCTAssertTrue(IPTVChannelFilter.matches(name: "News World", group: nil, query: "  ", selectedGroup: nil))
    }
}
