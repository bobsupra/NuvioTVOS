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

    func testAudioRankingUsesDeclaredMetadataOnly() {
        func stream(_ name: String) -> NuvioStream {
            NuvioStream(url: "https://example.test/movie", name: name, description: nil, addonName: "A")
        }
        XCTAssertGreaterThan(StreamPickerListBuilder.recommendedAudioRank(for: stream("1080p Atmos")),
                             StreamPickerListBuilder.recommendedAudioRank(for: stream("1080p DD+")))
        XCTAssertGreaterThan(StreamPickerListBuilder.recommendedAudioRank(for: stream("1080p DTS-HD MA 5.1")),
                             StreamPickerListBuilder.recommendedAudioRank(for: stream("1080p AAC")))
        XCTAssertEqual(StreamPickerListBuilder.recommendedAudioRank(for: stream("1080p")), 0)
    }

    func testBestPerResolutionKeepsLowerResolutionsAvailable() {
        let high = NuvioStream(url: "https://example.test/4k", name: "2160p", description: nil, addonName: "A")
        let standard = NuvioStream(url: "https://example.test/1080", name: "1080p", description: nil, addonName: "B")
        let low = NuvioStream(url: "https://example.test/480", name: "480p", description: nil, addonName: "B")
        let sorted = StreamPickerListBuilder.displayedStreams(
            streams: [low, standard, high], groups: [], selectedAddonId: nil,
            sortOption: .recommended, includeDebrid: false
        )
        let picks = StreamPickerListBuilder.recommendedByResolution(from: sorted)
        XCTAssertEqual(picks.map { $0.resolution }, [2160, 1080, 480])
        XCTAssertEqual(picks.map { $0.stream.id }, [high.id, standard.id, low.id])
    }
}
