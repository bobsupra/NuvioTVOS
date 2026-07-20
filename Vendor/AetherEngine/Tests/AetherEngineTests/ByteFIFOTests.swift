import XCTest
@testable import AetherEngine

final class ByteFIFOTests: XCTestCase {

    func testWriteThenReadRoundTrip() {
        let fifo = ByteFIFO(capacity: 1024)
        XCTAssertTrue(fifo.write(Data([1, 2, 3, 4])))
        var buffer = [UInt8](repeating: 0, count: 8)
        let n = buffer.withUnsafeMutableBufferPointer {
            fifo.read(into: $0.baseAddress!, maxLength: 8)
        }
        XCTAssertEqual(n, 4)
        XCTAssertEqual(Array(buffer[0..<4]), [1, 2, 3, 4])
    }

    func testReadBlocksUntilWrite() {
        let fifo = ByteFIFO(capacity: 1024)
        let expectation = expectation(description: "read returned")
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 4)
            let n = buffer.withUnsafeMutableBufferPointer {
                fifo.read(into: $0.baseAddress!, maxLength: 4)
            }
            XCTAssertEqual(n, 2)
            expectation.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(fifo.write(Data([9, 9])))
        wait(for: [expectation], timeout: 2)
    }

    func testFinishDrainsThenSignalsEOF() {
        let fifo = ByteFIFO(capacity: 1024)
        _ = fifo.write(Data([7]))
        fifo.finish()
        var buffer = [UInt8](repeating: 0, count: 4)
        let first = buffer.withUnsafeMutableBufferPointer {
            fifo.read(into: $0.baseAddress!, maxLength: 4)
        }
        XCTAssertEqual(first, 1)
        let second = buffer.withUnsafeMutableBufferPointer {
            fifo.read(into: $0.baseAddress!, maxLength: 4)
        }
        XCTAssertEqual(second, 0, "EOF after drain")
    }

    func testCancelUnblocksReaderWithError() {
        let fifo = ByteFIFO(capacity: 1024)
        let expectation = expectation(description: "read returned")
        DispatchQueue.global().async {
            var buffer = [UInt8](repeating: 0, count: 4)
            let n = buffer.withUnsafeMutableBufferPointer {
                fifo.read(into: $0.baseAddress!, maxLength: 4)
            }
            XCTAssertEqual(n, -1, "cancel surfaces as read error")
            expectation.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        fifo.cancel()
        wait(for: [expectation], timeout: 2)
    }

    func testWriteBlocksAtCapacityUntilRead() {
        let fifo = ByteFIFO(capacity: 4)
        XCTAssertTrue(fifo.write(Data([1, 2, 3, 4])))
        let expectation = expectation(description: "second write returned")
        DispatchQueue.global().async {
            XCTAssertTrue(fifo.write(Data([5, 6])))
            expectation.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        var buffer = [UInt8](repeating: 0, count: 4)
        _ = buffer.withUnsafeMutableBufferPointer {
            fifo.read(into: $0.baseAddress!, maxLength: 4)
        }
        wait(for: [expectation], timeout: 2)
    }
}
