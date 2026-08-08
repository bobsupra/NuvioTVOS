import Foundation
import Testing
@testable import AetherEngine

struct CustomDiscProbePolicyTests {
    @Test("an opted-out custom reader skips ISO and UDF signature offsets")
    func disabledDiscProbeSkipsSignatureReads() {
        let reader = TrackingIOReader(discImageProbeEnabled: false)
        let demuxer = Demuxer()

        #expect(throws: (any Error).self) {
            try demuxer.open(reader: reader, formatHint: "matroska")
        }

        #expect(!reader.seekOffsets.contains(0x8001))
        #expect(!reader.seekOffsets.contains(256 * 2048))
    }

    @Test("custom readers probe disc signatures by default")
    func defaultDiscProbeChecksSignatureOffsets() {
        let reader = TrackingIOReader()
        let demuxer = Demuxer()

        #expect(throws: (any Error).self) {
            try demuxer.open(reader: reader, formatHint: "matroska")
        }

        #expect(reader.seekOffsets.contains(0x8001))
        #expect(reader.seekOffsets.contains(256 * 2048))
    }
}

private final class TrackingIOReader: IOReader, @unchecked Sendable {
    let discImageProbeEnabled: Bool

    private let lock = NSLock()
    private var offset: Int64 = 0
    private var recordedSeekOffsets: [Int64] = []

    init(discImageProbeEnabled: Bool = true) {
        self.discImageProbeEnabled = discImageProbeEnabled
    }

    var seekOffsets: [Int64] {
        lock.withLock { recordedSeekOffsets }
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        let count = min(Int(size), 4096)
        buffer.initialize(repeating: 0, count: count)
        lock.withLock { offset += Int64(count) }
        return Int32(count)
    }

    func seek(offset requestedOffset: Int64, whence: Int32) -> Int64 {
        lock.withLock {
            if whence & 0x10000 != 0 { return 4096 }
            guard whence & ~0x20000 == SEEK_SET else { return -1 }
            offset = requestedOffset
            recordedSeekOffsets.append(requestedOffset)
            return requestedOffset
        }
    }

    func close() {}
}
