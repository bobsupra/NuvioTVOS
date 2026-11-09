import XCTest
@testable import NuvioTV

final class RemoteBackGuardTests: XCTestCase {
    func testBackIsSwallowedWhileNothingIsFocusedOrRightAfterThePreviousOne() {
        XCTAssertTrue(BackGuardHostView.shouldSwallow(nothingFocused: true, sincePreviousBack: .infinity, sinceLastSwallow: .infinity))
        XCTAssertTrue(BackGuardHostView.shouldSwallow(nothingFocused: false, sincePreviousBack: 0.4, sinceLastSwallow: .infinity),
                      "a menu that took the previous Back is still closing")
        XCTAssertFalse(BackGuardHostView.shouldSwallow(nothingFocused: false, sincePreviousBack: 2, sinceLastSwallow: .infinity))
    }

    func testABackRightAfterASwallowedOneGoesThrough() {
        XCTAssertFalse(BackGuardHostView.shouldSwallow(nothingFocused: true, sincePreviousBack: 0.4, sinceLastSwallow: 0.4))
        XCTAssertTrue(BackGuardHostView.shouldSwallow(nothingFocused: true, sincePreviousBack: 2, sinceLastSwallow: 2))
    }
}
