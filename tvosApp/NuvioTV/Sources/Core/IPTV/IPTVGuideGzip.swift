import Foundation
import Compression

/// Gzip decoding with bounded input and output buffers, checksum, and size validation.
enum IPTVGuideGzip {
    enum Failure: Error { case invalid, tooLarge }

    private static let ioChunkSize = 64 * 1024
    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1 == 1) ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }

    static func isGzip(_ body: IPTVGuidePayload.Body) throws -> Bool {
        let source = try Source(body: body)
        guard source.length >= 2 else { return false }
        let prefix = try source.read(at: 0, count: 2)
        return prefix.count == 2 && prefix[0] == 0x1f && prefix[1] == 0x8b
    }

    static func decompress(
        _ body: IPTVGuidePayload.Body,
        maximumBytes: Int
    ) throws -> (file: IPTVGuideTemporaryFile, byteCount: Int) {
        let source = try Source(body: body)
        guard maximumBytes > 0, source.length >= 18 else { throw Failure.invalid }

        let header = try source.readExactly(at: 0, count: 10)
        guard header[0] == 0x1f, header[1] == 0x8b,
              header[2] == 8, header[3] & 0xe0 == 0 else { throw Failure.invalid }
        let trailerOffset = source.length - 8
        let flags = header[3]
        var offset = 10
        var headerCRC = updateCRC(0xffff_ffff, with: header)

        if flags & 0x04 != 0 {
            let lengthBytes = try source.readExactly(at: offset, count: 2)
            headerCRC = updateCRC(headerCRC, with: lengthBytes)
            let extraLength = Int(lengthBytes[0]) | (Int(lengthBytes[1]) << 8)
            offset += 2
            guard extraLength <= trailerOffset - offset else { throw Failure.invalid }
            let extra = try source.readExactly(at: offset, count: extraLength)
            headerCRC = updateCRC(headerCRC, with: extra)
            offset += extraLength
        }

        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {
            let result = try skipZeroTerminatedField(in: source, offset: offset, limit: trailerOffset, crc: headerCRC)
            offset = result.offset
            headerCRC = result.crc
        }

        if flags & 0x02 != 0 {
            let expectedHeaderCRC = try source.readExactly(at: offset, count: 2)
            let actual = UInt16(truncatingIfNeeded: headerCRC ^ 0xffff_ffff)
            let expected = UInt16(expectedHeaderCRC[0]) | (UInt16(expectedHeaderCRC[1]) << 8)
            guard actual == expected else { throw Failure.invalid }
            offset += 2
        }
        guard offset < trailerOffset else { throw Failure.invalid }

        let trailer = try source.readExactly(at: trailerOffset, count: 8)
        let expectedCRC = littleEndian32(in: trailer, at: 0)
        let expectedSizeValue = littleEndian32(in: trailer, at: 4)
        guard expectedSizeValue > 0 else { throw Failure.invalid }
        let expectedSize = Int(expectedSizeValue)
        guard expectedSize <= maximumBytes else { throw Failure.tooLarge }

        let outputFile = try IPTVGuideTemporaryFile()
        let output = try FileHandle(forWritingTo: outputFile.url)
        var outputClosed = false
        defer {
            if !outputClosed { try? output.close() }
        }

        let initializationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { initializationBuffer.deallocate() }
        var stream = compression_stream(
            dst_ptr: initializationBuffer,
            dst_size: 0,
            src_ptr: UnsafePointer(initializationBuffer),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Failure.invalid
        }
        defer { compression_stream_destroy(&stream) }

        let deflateEnd = trailerOffset
        var inputOffset = offset
        var outputByteCount = 0
        var crc: UInt32 = 0xffff_ffff
        var reachedEnd = false

        while inputOffset < deflateEnd, !reachedEnd {
            try Task.checkCancellation()
            let chunkCount = min(ioChunkSize, deflateEnd - inputOffset)
            let input = try source.readExactly(at: inputOffset, count: chunkCount)
            inputOffset += input.count
            let isFinalInput = inputOffset == deflateEnd

            try input.withUnsafeBytes { (rawInput: UnsafeRawBufferPointer) in
                guard let inputBase = rawInput.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    throw Failure.invalid
                }
                stream.src_ptr = inputBase
                stream.src_size = rawInput.count

                while true {
                    try Task.checkCancellation()
                    var outputBuffer = [UInt8](repeating: 0, count: ioChunkSize)
                    let (status, produced) = outputBuffer.withUnsafeMutableBufferPointer { rawOutput in
                        stream.dst_ptr = rawOutput.baseAddress!
                        stream.dst_size = rawOutput.count
                        let flags = isFinalInput ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                        let status = compression_stream_process(&stream, flags)
                        let count = rawOutput.count - stream.dst_size
                        let bytes = count > 0 ? Data(bytes: rawOutput.baseAddress!, count: count) : Data()
                        return (status, bytes)
                    }

                    if !produced.isEmpty {
                        guard produced.count <= maximumBytes - outputByteCount else { throw Failure.tooLarge }
                        guard produced.count <= expectedSize - outputByteCount else { throw Failure.invalid }
                        crc = updateCRC(crc, with: produced)
                        try output.write(contentsOf: produced)
                        outputByteCount += produced.count
                    }

                    if status == COMPRESSION_STATUS_END {
                        guard stream.src_size == 0, isFinalInput else { throw Failure.invalid }
                        reachedEnd = true
                        break
                    }
                    guard status == COMPRESSION_STATUS_OK else { throw Failure.invalid }
                    if stream.src_size == 0, produced.count < ioChunkSize {
                        if isFinalInput {
                            if produced.isEmpty { throw Failure.invalid }
                        } else {
                            break
                        }
                    }
                }
            }
        }

        guard reachedEnd, inputOffset == deflateEnd,
              outputByteCount == expectedSize,
              (crc ^ 0xffff_ffff) == expectedCRC else { throw Failure.invalid }
        try output.close()
        outputClosed = true
        return (outputFile, outputByteCount)
    }

    /// Compatibility helper for small in-memory callers and focused tests.
    static func decompress(_ data: Data, maximumBytes: Int) throws -> Data {
        let (outputFile, _) = try decompress(.data(data), maximumBytes: maximumBytes)
        return try withExtendedLifetime(outputFile) {
            try Data(contentsOf: outputFile.url, options: .mappedIfSafe)
        }
    }

    private static func skipZeroTerminatedField(
        in source: Source,
        offset initialOffset: Int,
        limit: Int,
        crc initialCRC: UInt32
    ) throws -> (offset: Int, crc: UInt32) {
        var offset = initialOffset
        var crc = initialCRC
        while offset < limit {
            try Task.checkCancellation()
            let chunk = try source.read(at: offset, count: min(ioChunkSize, limit - offset))
            guard !chunk.isEmpty else { throw Failure.invalid }
            if let terminator = chunk.firstIndex(of: 0) {
                let field = chunk.prefix(through: terminator)
                crc = updateCRC(crc, with: Data(field))
                return (offset + field.count, crc)
            }
            crc = updateCRC(crc, with: chunk)
            offset += chunk.count
        }
        throw Failure.invalid
    }

    private static func littleEndian32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func updateCRC(_ crc: UInt32, with data: Data) -> UInt32 {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let bytes = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return crc }
            var result = crc
            for index in 0..<raw.count {
                result = (result >> 8) ^ crcTable[Int((result ^ UInt32(bytes[index])) & 0xff)]
            }
            return result
        }
    }

    private final class Source {
        private let data: Data?
        private let handle: FileHandle?
        let length: Int

        init(body: IPTVGuidePayload.Body) throws {
            switch body {
            case .data(let data):
                self.data = data
                handle = nil
                length = data.count
            case .file(let file):
                self.data = nil
                handle = try FileHandle(forReadingFrom: file.url)
                length = Int(try handle?.seekToEnd() ?? 0)
            }
        }

        deinit {
            try? handle?.close()
        }

        func read(at offset: Int, count: Int) throws -> Data {
            guard offset >= 0, count >= 0, offset <= length, count <= length - offset else { throw Failure.invalid }
            if let data {
                return data.subdata(in: offset..<(offset + count))
            }
            guard let handle else { throw Failure.invalid }
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }

        func readExactly(at offset: Int, count: Int) throws -> Data {
            let result = try read(at: offset, count: count)
            guard result.count == count else { throw Failure.invalid }
            return result
        }
    }
}
