import Compression
import Foundation

/// The fonts in a ZIP: font sites and font packs mostly come zipped. Reads stored and deflated
/// entries from the central directory, checks each CRC, and skips folders, macOS metadata,
/// encrypted and ZIP64 entries and anything that isn't a TTF, OTF or TTC.
enum ZipFontArchive {
    struct Entry: Equatable {
        let name: String
        let data: Data
    }

    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]

    static func fontEntries(in data: Data, limit: Int, maximumEntryBytes: Int) throws -> [Entry] {
        guard let end = endOfCentralDirectory(in: data),
              let count = u16(data, end + 10),
              let directoryOffset = u32(data, end + 16), directoryOffset != 0xFFFF_FFFF else {
            throw SubtitleFontError.unsupportedArchive
        }
        var offset = Int(directoryOffset)
        var entries: [Entry] = []
        for _ in 0..<Int(count) {
            guard u32(data, offset) == 0x0201_4B50,
                  let flags = u16(data, offset + 8),
                  let method = u16(data, offset + 10),
                  let crc = u32(data, offset + 16),
                  let compressed = u32(data, offset + 20),
                  let size = u32(data, offset + 24),
                  let nameLength = u16(data, offset + 28),
                  let extraLength = u16(data, offset + 30),
                  let commentLength = u16(data, offset + 32),
                  let localOffset = u32(data, offset + 42),
                  let nameData = slice(data, offset + 46, Int(nameLength)) else {
                throw SubtitleFontError.unsupportedArchive
            }
            offset += 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)

            let path = String(decoding: nameData, as: UTF8.self)
            guard isFontPath(path),
                  flags & 1 == 0,
                  method == 0 || method == 8,
                  size != 0xFFFF_FFFF, compressed != 0xFFFF_FFFF,
                  Int(size) <= maximumEntryBytes,
                  let content = entryData(
                    data,
                    localOffset: Int(localOffset),
                    method: method,
                    compressed: Int(compressed),
                    size: Int(size)
                  ),
                  crc32(content) == crc else { continue }
            entries.append(Entry(name: (path as NSString).lastPathComponent, data: content))
            if entries.count >= limit { break }
        }
        return entries
    }

    static func isFontPath(_ path: String) -> Bool {
        guard !path.hasSuffix("/"), !path.hasPrefix("__MACOSX/"), !path.contains("/__MACOSX/") else { return false }
        let name = (path as NSString).lastPathComponent
        guard !name.hasPrefix("._") else { return false }
        return fontExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 65_535)
        var offset = data.count - 22
        while offset >= lowest {
            if u32(data, offset) == 0x0605_4B50 { return offset }
            offset -= 1
        }
        return nil
    }

    private static func entryData(_ data: Data, localOffset: Int, method: UInt16, compressed: Int, size: Int) -> Data? {
        guard u32(data, localOffset) == 0x0403_4B50,
              let nameLength = u16(data, localOffset + 26),
              let extraLength = u16(data, localOffset + 28),
              let packed = slice(data, localOffset + 30 + Int(nameLength) + Int(extraLength), compressed) else {
            return nil
        }
        if method == 0 { return packed.count == size ? packed : nil }
        return inflate(packed, size: size)
    }

    /// Raw DEFLATE (what a ZIP holds; Apple's ZLIB is raw DEFLATE without a header).
    private static func inflate(_ input: Data, size: Int) -> Data? {
        if size == 0 { return Data() }
        guard !input.isEmpty else { return nil }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            input.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let destination = out.bindMemory(to: UInt8.self).baseAddress,
                      let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(destination, size, base, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? output : nil
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        let table = crcTable
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: Little-endian reads, bounds-checked

    private static func slice(_ data: Data, _ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset <= data.count - length else { return nil }
        let start = data.startIndex + offset
        return data.subdata(in: start..<(start + length))
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let start = data.startIndex + offset
        return UInt16(data[start]) | UInt16(data[start + 1]) << 8
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let start = data.startIndex + offset
        return UInt32(data[start]) | UInt32(data[start + 1]) << 8 | UInt32(data[start + 2]) << 16 | UInt32(data[start + 3]) << 24
    }
}
