import Foundation
import Compression

/// Single-member gzip decoding with a strict output limit and checksum check.
enum IPTVGuideGzip {
    enum Failure: Error { case invalid, tooLarge }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1 == 1) ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        return crc
    }

    static func decompress(_ data: Data, maximumBytes: Int) throws -> Data {
        let bytes = [UInt8](data)
        guard maximumBytes > 0, bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b,
              bytes[2] == 8, bytes[3] & 0xe0 == 0 else { throw Failure.invalid }
        let trailer = bytes.count - 8
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard offset + 2 <= trailer else { throw Failure.invalid }
            let length = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2
            guard length <= trailer - offset else { throw Failure.invalid }
            offset += length
        }
        for flag in [UInt8(0x08), UInt8(0x10)] where flags & flag != 0 {
            while offset < trailer && bytes[offset] != 0 { offset += 1 }
            guard offset < trailer else { throw Failure.invalid }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < trailer else { throw Failure.invalid }
        func littleEndian32(_ index: Int) -> UInt32 {
            UInt32(bytes[index]) | (UInt32(bytes[index + 1]) << 8) |
            (UInt32(bytes[index + 2]) << 16) | (UInt32(bytes[index + 3]) << 24)
        }
        let expectedSize = Int(littleEndian32(trailer + 4))
        guard expectedSize <= maximumBytes else { throw Failure.tooLarge }
        guard expectedSize > 0 else { throw Failure.invalid }
        let deflate = Array(bytes[offset..<trailer])
        let capacity = expectedSize + 1
        var output = [UInt8](repeating: 0, count: capacity)
        let written = deflate.withUnsafeBufferPointer { input in
            compression_decode_buffer(&output, capacity, input.baseAddress!, input.count, nil, COMPRESSION_ZLIB)
        }
        guard written == expectedSize else { throw Failure.invalid }
        var crc: UInt32 = 0xffffffff
        for byte in output.prefix(written) { crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)] }
        guard (crc ^ 0xffffffff) == littleEndian32(trailer) else { throw Failure.invalid }
        return Data(output.prefix(written))
    }
}
