import XCTest
@testable import NuvioTV

@MainActor
final class AmbientModeTests: XCTestCase {
    func testSlidesSkipTitlesWithoutBackdropsAndRepeats() {
        let metas = [
            NuvioMeta(id: "tt1", name: "One", type: "movie"),
            NuvioMeta(id: "tt2", name: "Two", type: "movie"),
            NuvioMeta(id: "tt1", name: "One again", type: "movie"),
            NuvioMeta(id: "tt3", name: "Three", type: "movie"),
        ]
        let slides = AmbientModeOverlay.slides(from: metas) { meta in
            meta.id == "tt2" ? nil : "https://img.example.com/\(meta.id).jpg"
        }
        XCTAssertEqual(slides.map(\.id), ["tt1", "tt3"])
        XCTAssertEqual(slides.first?.title, "One")
    }

    func testSlidesAreLimitedTo40() {
        let metas = (1...60).map { NuvioMeta(id: "tt\($0)", name: "T\($0)", type: "movie") }
        let slides = AmbientModeOverlay.slides(from: metas) { "https://img.example.com/\($0.id).jpg" }
        XCTAssertEqual(slides.count, 40)
    }
}
