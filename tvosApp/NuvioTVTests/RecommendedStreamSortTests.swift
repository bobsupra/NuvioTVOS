import XCTest
@testable import NuvioTV

final class RecommendedStreamSortTests: XCTestCase {
    func testRecommendedSortPrioritizesResolutionThenDynamicRange() {
        let hd = NuvioStream(url: "https://example.test/hd", name: "1080p SDR", description: nil, addonName: "B")
        let ultraHD = NuvioStream(url: "https://example.test/uhd", name: "2160p SDR", description: nil, addonName: "A")
        let hdr = NuvioStream(url: "https://example.test/hdr", name: "2160p HDR", description: nil, addonName: "B")
        let sorted = StreamPickerListBuilder.sorted([hd, ultraHD, hdr], by: .recommended)
        XCTAssertEqual(sorted.map(\.id), [hdr.id, ultraHD.id, hd.id])
    }

    func testRecommendedSortKeepsInputOrderForEquivalentFacts() {
        let first = NuvioStream(url: "https://example.test/one", name: "1080p", description: nil, addonName: "A")
        let second = NuvioStream(url: "https://example.test/two", name: "1080p", description: nil, addonName: "B")
        let sorted = StreamPickerListBuilder.sorted([first, second], by: .recommended)
        XCTAssertEqual(sorted.map(\.id), [first.id, second.id])
    }
}
