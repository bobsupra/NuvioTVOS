import XCTest
@testable import AetherEngine

/// Mapping from the internal disc-layer model (45 kHz ticks, extent keys) to the public
/// TitleInfo / ChapterInfo the engine publishes (#67).
final class DiscMetadataTests: XCTestCase {
    func test_titleInfoMapsDurationAndName() {
        let title = DiscTitle(id: 0, durationTicks: 4_500_000)  // 100 s at 45 kHz
        let info = title.titleInfo()
        XCTAssertEqual(info.id, 0)
        XCTAssertEqual(info.name, "Title 1")
        XCTAssertEqual(info.durationSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(info.chapterCount, 0)
    }

    func test_chapterInfosComputeDurationsFromNextStart() {
        let title = DiscTitle(
            id: 0,
            durationTicks: 6_750_000,  // 150 s
            chapters: [
                DiscChapter(id: 0, startTicks: 0),
                DiscChapter(id: 1, startTicks: 2_250_000),  // 50 s
                DiscChapter(id: 2, startTicks: 4_500_000),  // 100 s
            ]
        )
        let chapters = [title].chapterInfos(selectedIndex: 0)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].startSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(chapters[0].durationSeconds, 50, accuracy: 0.001)
        XCTAssertEqual(chapters[1].startSeconds, 50, accuracy: 0.001)
        XCTAssertEqual(chapters[1].durationSeconds, 50, accuracy: 0.001)
        XCTAssertEqual(chapters[2].startSeconds, 100, accuracy: 0.001)
        XCTAssertEqual(chapters[2].durationSeconds, 50, accuracy: 0.001)  // last runs to title end (150 s)
        XCTAssertEqual(chapters[2].name, "Chapter 3")
    }

    func test_chapterInfosOutOfRangeIndexIsEmpty() {
        XCTAssertTrue([DiscTitle(id: 0, durationTicks: 100)].chapterInfos(selectedIndex: 5).isEmpty)
    }
}
