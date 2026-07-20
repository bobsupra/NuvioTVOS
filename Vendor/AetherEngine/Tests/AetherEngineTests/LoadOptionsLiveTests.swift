// Tests/AetherEngineTests/LoadOptionsLiveTests.swift
import XCTest
@testable import AetherEngine

final class LoadOptionsLiveTests: XCTestCase {
    func testDvrWindowDefaultsNil() { XCTAssertNil(LoadOptions().dvrWindowSeconds) }
    func testDvrWindowSettable() {
        var o = LoadOptions(isLive: true); o.dvrWindowSeconds = 1800
        XCTAssertEqual(o.dvrWindowSeconds, 1800)
    }
    @MainActor func testLiveSurfacesIdleDefaults() throws {
        let e = try AetherEngine()
        XCTAssertFalse(e.isAtLiveEdge)
        XCTAssertNil(e.seekableLiveRange)
        XCTAssertEqual(e.behindLiveSeconds, 0)
        XCTAssertEqual(e.liveEdgeTime, 0)
    }
}
