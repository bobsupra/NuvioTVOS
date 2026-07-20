import XCTest
@testable import AetherEngine

final class ConcatIOReaderTests: XCTestCase {
    // Base bytes: 0..49. Two extents: [10..20) then [30..40) => virtual 20 bytes.
    private func makeReader() -> ConcatIOReader {
        let base = DataIOReader(data: Data((0..<50).map { UInt8($0) }))
        return ConcatIOReader(base: base, extents: [(offset: 10, length: 10), (offset: 30, length: 10)])
    }

    func test_size() {
        XCTAssertEqual(makeReader().seek(offset: 0, whence: 65536), 20) // AVSEEK_SIZE
    }

    func test_sequentialReadSpansExtentBoundary() {
        let r = makeReader()
        var buf = [UInt8](repeating: 0, count: 20)
        let n = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 20) }
        XCTAssertEqual(n, 20)
        // First extent maps to base 10..19, second to base 30..39.
        XCTAssertEqual(buf, Array(10..<20) + Array(30..<40))
    }

    func test_seekSetThenRead() {
        let r = makeReader()
        XCTAssertEqual(r.seek(offset: 15, whence: SEEK_SET), 15) // 5 into 2nd extent
        var buf = [UInt8](repeating: 0, count: 5)
        let n = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 5) }
        XCTAssertEqual(n, 5)
        XCTAssertEqual(buf, Array(35..<40)) // base 35..39
    }

    func test_readClampsAtEOF() {
        let r = makeReader()
        XCTAssertEqual(r.seek(offset: 18, whence: SEEK_SET), 18)
        var buf = [UInt8](repeating: 0, count: 10)
        let n = buf.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 10) }
        XCTAssertEqual(n, 2) // only 2 bytes left
        XCTAssertEqual(Array(buf.prefix(2)), [38, 39])
    }
}
