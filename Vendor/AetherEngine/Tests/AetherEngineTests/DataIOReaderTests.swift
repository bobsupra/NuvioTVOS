import Foundation
import Testing
@testable import AetherEngine

@Suite("DataIOReader")
struct DataIOReaderTests {

    private func makeReader(_ bytes: [UInt8]) -> DataIOReader {
        DataIOReader(data: Data(bytes))
    }

    @Test("Sequential reads return the data then EOF")
    func sequentialRead() {
        let reader = makeReader([1, 2, 3, 4, 5])
        var buf = [UInt8](repeating: 0, count: 3)
        let n1 = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 3) }
        #expect(n1 == 3)
        #expect(Array(buf[0..<3]) == [1, 2, 3])
        let n2 = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 3) }
        #expect(n2 == 2)
        let n3 = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 3) }
        #expect(n3 == 0)  // EOF
    }

    @Test("SEEK_SET / SEEK_CUR / SEEK_END reposition the cursor")
    func seekWhence() {
        let reader = makeReader([10, 20, 30, 40])
        #expect(reader.seek(offset: 2, whence: SEEK_SET) == 2)
        var buf = [UInt8](repeating: 0, count: 1)
        _ = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 1) }
        #expect(buf[0] == 30)
        #expect(reader.seek(offset: -1, whence: SEEK_CUR) == 2)
        #expect(reader.seek(offset: -1, whence: SEEK_END) == 3)
    }

    @Test("AVSEEK_SIZE returns the total length without moving")
    func avseekSize() {
        let reader = makeReader([1, 2, 3])
        #expect(reader.seek(offset: 0, whence: 65536) == 3)
        var buf = [UInt8](repeating: 0, count: 1)
        let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 1) }
        #expect(n == 1)
        #expect(buf[0] == 1)  // cursor still at 0
    }

    @Test("Empty data: EOF on first read, size 0, seek to 0 succeeds")
    func emptyData() {
        let reader = DataIOReader(data: Data())
        var buf = [UInt8](repeating: 0, count: 4)
        let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 4) }
        #expect(n == 0)
        #expect(reader.seek(offset: 0, whence: 65536) == 0)   // AVSEEK_SIZE = 0
        #expect(reader.seek(offset: 0, whence: SEEK_SET) == 0)
    }

    @Test("Seek beyond end clamps to the length")
    func seekBeyondEnd() {
        let reader = makeReader([1, 2, 3])
        #expect(reader.seek(offset: 10, whence: SEEK_SET) == 3)  // clamped to length
        var buf = [UInt8](repeating: 0, count: 1)
        let n = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 1) }
        #expect(n == 0)
    }

    @Test("Negative seek is rejected and leaves the cursor unchanged")
    func negativeSeek() {
        let reader = makeReader([1, 2, 3])
        #expect(reader.seek(offset: -5, whence: SEEK_SET) < 0)
        var buf = [UInt8](repeating: 0, count: 1)
        _ = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 1) }
        #expect(buf[0] == 1)  // cursor still at 0
    }
}
