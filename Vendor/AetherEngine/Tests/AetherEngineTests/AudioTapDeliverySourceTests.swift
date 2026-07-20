import XCTest
@testable import AetherEngine

@MainActor
final class AudioTapDeliverySourceTests: XCTestCase {
    func testNoDeliverySourceWithoutSession() throws {
        let engine = try AetherEngine()
        XCTAssertFalse(engine.audioTapHasDeliverySource)     // nothing loaded
        let stream = engine.installAudioTap()                // backend .none -> finishes immediately
        XCTAssertFalse(engine.audioTapHasDeliverySource)
        _ = stream
    }
}
