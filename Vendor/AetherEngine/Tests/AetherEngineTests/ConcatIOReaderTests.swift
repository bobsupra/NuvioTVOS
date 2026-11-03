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

    func test_partialBaseErrorAdvancesConcatPosition() {
        let base = PartialThenErrorReader(bytes: Array(0..<10).map(UInt8.init), partialCount: 3)
        let r = ConcatIOReader(base: base, extents: [(offset: 0, length: 10)])

        var first = [UInt8](repeating: 0, count: 6)
        let firstCount = first.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 6) }
        XCTAssertEqual(firstCount, 3)
        XCTAssertEqual(Array(first.prefix(3)), [0, 1, 2])

        var second = [UInt8](repeating: 0, count: 3)
        let secondCount = second.withUnsafeMutableBufferPointer { r.read($0.baseAddress, size: 3) }
        XCTAssertEqual(secondCount, 3)
        XCTAssertEqual(second, [3, 4, 5])
    }

    func test_closingIndependentConcatClosesOnlyItsOwnedBase() {
        let original = LifecycleReader(isFork: false)
        let concat = ConcatIOReader(base: original, extents: [(offset: 0, length: 10)])
        let fork = concat.makeIndependentReader() as? ConcatIOReader

        XCTAssertNotNil(fork)
        fork?.close()
        XCTAssertEqual(original.closeCount, 0)
        XCTAssertEqual(original.tracker.forkCloseCount, 1)
    }

    private final class LifecycleReader: IOReader, @unchecked Sendable {
        final class Tracker: @unchecked Sendable {
            private let lock = NSLock()
            private var forksClosed = 0
            var forkCloseCount: Int { lock.lock(); defer { lock.unlock() }; return forksClosed }
            func noteForkClosed() { lock.lock(); forksClosed += 1; lock.unlock() }
        }

        let tracker: Tracker
        let isFork: Bool
        private let lock = NSLock()
        private var closes = 0
        var closeCount: Int { lock.lock(); defer { lock.unlock() }; return closes }

        init(isFork: Bool, tracker: Tracker = Tracker()) {
            self.isFork = isFork
            self.tracker = tracker
        }

        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { 0 }
        func seek(offset: Int64, whence: Int32) -> Int64 { offset }
        func close() {
            lock.lock(); closes += 1; lock.unlock()
            if isFork { tracker.noteForkClosed() }
        }
        func makeIndependentReader() -> IOReader? { LifecycleReader(isFork: true, tracker: tracker) }
    }
}

private final class PartialThenErrorReader: IOReader, @unchecked Sendable {
    private let bytes: [UInt8]
    private let partialCount: Int
    private var position = 0
    private var shouldFailOnce = true

    init(bytes: [UInt8], partialCount: Int) {
        self.bytes = bytes
        self.partialCount = partialCount
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        if shouldFailOnce, position >= partialCount {
            shouldFailOnce = false
            return -1
        }
        let limit = shouldFailOnce ? partialCount : bytes.count
        let count = min(Int(size), limit - position)
        guard count > 0 else { return 0 }
        for index in 0..<count { buffer[index] = bytes[position + index] }
        position += count
        return Int32(count)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return Int64(bytes.count) }
        let target: Int64
        switch whence {
        case SEEK_SET: target = offset
        case SEEK_CUR: target = Int64(position) + offset
        case SEEK_END: target = Int64(bytes.count) + offset
        default: return -1
        }
        guard target >= 0, target <= Int64(bytes.count) else { return -1 }
        position = Int(target)
        return target
    }

    func close() {}
}
