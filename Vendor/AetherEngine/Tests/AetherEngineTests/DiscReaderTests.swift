import XCTest
@testable import AetherEngine

final class DiscReaderTests: XCTestCase {
    func test_wrapReturnsConcatReaderOverMainTitle() throws {
        let data = ISO9660Fixture.make(files: [
            .init(name: "VIDEO_TS.IFO", length: 12_000),
            .init(name: "VTS_01_0.VOB", length: 10_000),        // menu
            .init(name: "VTS_01_1.VOB", length: 2048),          // main title, 1 sector filled
        ])
        let wrapped = try DiscReader.wrap(DataIOReader(data: data))
        let info = try XCTUnwrap(wrapped)
        let reader = info.reader
        XCTAssertEqual(info.formatHint, "mpeg")
        XCTAssertEqual(info.titles.count, 1)  // DVD: one title until IFO enumeration lands
        // First bytes must be the MPEG-PS pack-start code 00 00 01 BA written by the fixture.
        var buf = [UInt8](repeating: 0, count: 4)
        let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 4) }
        XCTAssertEqual(n, 4)
        XCTAssertEqual(buf, [0x00, 0x00, 0x01, 0xBA])
    }

    func test_wrapReturnsNilForNonDiscSource() throws {
        let mp4 = Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6F, 0x6D])
        XCTAssertNil(try DiscReader.wrap(DataIOReader(data: mp4)))
    }

    func test_wrapReturnsNilWhenNoMainTitle() throws {
        // Valid ISO with VIDEO_TS but only a menu VOB -> no playable title.
        let data = ISO9660Fixture.make(files: [.init(name: "VTS_01_0.VOB", length: 2048)])
        XCTAssertNil(try DiscReader.wrap(DataIOReader(data: data)))
    }
}
