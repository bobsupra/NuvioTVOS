import Foundation

/// In-memory `IOReader` over an immutable `Data` blob. Used by the scrub-thumbnail path: engine composes init.mp4 + cached segment into one buffer and demuxes via `FrameExtractor(reader:)`. NSLock makes read/seek safe off the demux thread.
final class DataIOReader: IOReader, @unchecked Sendable {
    private let data: Data
    private var position = 0
    private let lock = NSLock()

    init(data: Data) {
        self.data = data
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        lock.lock()
        defer { lock.unlock() }
        guard position < data.count else { return 0 }  // EOF
        let n = min(Int(size), data.count - position)
        data.copyBytes(
            to: UnsafeMutableBufferPointer(start: buffer, count: n),
            from: position..<(position + n)
        )
        position += n
        return Int32(n)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        // AVSEEK_SIZE (65536): report total length, do not move.
        if whence == 65536 { return Int64(data.count) }
        lock.lock()
        defer { lock.unlock() }
        let target: Int
        switch whence {
        case SEEK_SET: target = Int(offset)
        case SEEK_CUR: target = position + Int(offset)
        case SEEK_END: target = data.count + Int(offset)
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = min(target, data.count)
        return Int64(position)
    }

    func close() {}
}
