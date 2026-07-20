import XCTest
@testable import AetherEngineSMB

final class ScaffoldTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertTrue(AetherEngineSMB.isAvailable)
    }
}
