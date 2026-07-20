import XCTest
@testable import AetherEngine

final class DVDTitleSelectorTests: XCTestCase {
    func test_picksLargestTitleSetOrdersPartsExcludesMenu() {
        let files: [DiscFile] = [
            .init(name: "VIDEO_TS.IFO", startSector: 1, length: 12_000),
            .init(name: "VTS_01_0.VOB", startSector: 2, length: 50_000_000),   // menu, excluded
            .init(name: "VTS_01_1.VOB", startSector: 3, length: 100_000_000),  // small title
            .init(name: "VTS_02_0.VOB", startSector: 4, length: 50_000_000),   // menu, excluded
            .init(name: "VTS_02_2.VOB", startSector: 6, length: 900_000_000),  // main, part 2
            .init(name: "VTS_02_1.VOB", startSector: 5, length: 1_000_000_000),// main, part 1
        ]
        let picked = DVDTitleSelector.selectMainTitleVOBs(files)
        XCTAssertEqual(picked.map(\.name), ["VTS_02_1.VOB", "VTS_02_2.VOB"])
    }

    func test_emptyWhenNoContentVOBs() {
        let files: [DiscFile] = [
            .init(name: "VIDEO_TS.IFO", startSector: 1, length: 12_000),
            .init(name: "VTS_01_0.VOB", startSector: 2, length: 50_000_000), // menu only
        ]
        XCTAssertTrue(DVDTitleSelector.selectMainTitleVOBs(files).isEmpty)
    }

    func test_enumerateGroupsByVTSLargestFirstPartsOrdered() {
        let files: [DiscFile] = [
            .init(name: "VTS_01_0.VOB", startSector: 2, length: 50_000_000),   // menu, excluded
            .init(name: "VTS_01_1.VOB", startSector: 3, length: 100_000_000),  // VTS 1: 100M
            .init(name: "VTS_02_2.VOB", startSector: 6, length: 900_000_000),  // VTS 2 part 2
            .init(name: "VTS_02_1.VOB", startSector: 5, length: 1_000_000_000),// VTS 2 part 1 (1.9G total)
        ]
        let groups = DVDTitleSelector.enumerateTitleVOBGroups(files)
        XCTAssertEqual(groups.map(\.vtsn), [2, 1])  // largest total first
        XCTAssertEqual(groups[0].vobs.map(\.name), ["VTS_02_1.VOB", "VTS_02_2.VOB"])  // parts ordered
        XCTAssertEqual(groups[1].vobs.map(\.name), ["VTS_01_1.VOB"])
    }
}
