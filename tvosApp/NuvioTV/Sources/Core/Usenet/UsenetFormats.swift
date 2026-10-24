import Foundation
import CryptoKit

// MARK: - RAR

/// One file entry from a RAR volume header.
struct UsenetRarEntry: Equatable, Sendable {
    var name: String
    /// Bytes of this entry held by this volume.
    var packedSize: Int64
    /// Size of the whole file once joined; -1 when the archive doesn't say.
    var unpackedSize: Int64
    /// Where this volume's bytes of the entry start, from the start of the volume.
    var dataOffset: Int64
    var isStored: Bool
    var isEncrypted: Bool
    var isDirectory: Bool
    var continuesFromPrevious: Bool
    var continuesInNext: Bool
}

/// What the headers at the front of one RAR volume say.
struct UsenetRarVolume: Equatable, Sendable {
    enum Format: Sendable { case rar4, rar5 }

    var format: Format
    /// RAR 5 numbers volumes from 0; RAR 4 doesn't store a number up front.
    var volumeNumber: Int?
    /// RAR 4 (3.0 and newer) and RAR 5 both flag the first volume.
    var isFirstVolume: Bool?
    var headersEncrypted = false
    var entries: [UsenetRarEntry] = []
    /// Where the next header starts (from the start of the volume) when it lies
    /// beyond the bytes read so far; nil once the headers are exhausted.
    var pendingHeaderOffset: Int64?
    /// The end-of-archive block was reached.
    var reachedEnd = false
}

/// Header-only RAR 4 / RAR 5 reader: finds where a stored (uncompressed)
/// file's bytes sit inside each volume, so they can be streamed in place.
enum UsenetRar {
    static let rar4Signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00]
    static let rar5Signature: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00]

    static func isRar(_ data: Data) -> Bool {
        data.starts(with: rar4Signature) || data.starts(with: rar5Signature)
    }

    /// Reads the headers in the first bytes of a volume (its first article is plenty).
    static func parseVolume(_ data: Data) -> UsenetRarVolume? {
        let bytes = [UInt8](data.prefix(4 << 20))
        if bytes.starts(with: rar5Signature) {
            var volume = UsenetRarVolume(format: .rar5)
            parseRar5(bytes, from: rar5Signature.count, base: 0, into: &volume)
            return volume
        }
        if bytes.starts(with: rar4Signature) {
            var volume = UsenetRarVolume(format: .rar4)
            parseRar4(bytes, from: rar4Signature.count, base: 0, into: &volume)
            return volume
        }
        return nil
    }

    /// Continues reading headers from `bytes`, which start at `offset` in the
    /// volume (a later file's header, past the previous file's data).
    static func continueVolume(_ volume: inout UsenetRarVolume, bytes: Data, at offset: Int64) {
        volume.pendingHeaderOffset = nil
        let b = [UInt8](bytes)
        switch volume.format {
        case .rar4: parseRar4(b, from: 0, base: offset, into: &volume)
        case .rar5: parseRar5(b, from: 0, base: offset, into: &volume)
        }
    }

    private static func parseRar4(_ b: [UInt8], from start: Int, base: Int64, into volume: inout UsenetRarVolume) {
        var pos = start
        while true {
            guard pos + 7 <= b.count else {
                volume.pendingHeaderOffset = base + Int64(pos)
                return
            }
            let type = b[pos + 2]
            let flags = Int(le16(b, pos + 3))
            let headSize = Int(le16(b, pos + 5))
            guard headSize >= 7 else { return }
            guard pos + headSize <= b.count else {
                volume.pendingHeaderOffset = base + Int64(pos)
                return
            }
            var dataSize: Int64 = 0

            switch type {
            case 0x73: // main header
                volume.isFirstVolume = flags & 0x0100 != 0
                if flags & 0x0080 != 0 {
                    volume.headersEncrypted = true
                    return
                }
            case 0x74, 0x7A: // file, service
                guard headSize >= 32 else { return }
                var packed = Int64(le32(b, pos + 7))
                var unpacked = Int64(le32(b, pos + 11))
                let method = b[pos + 25]
                let nameSize = Int(le16(b, pos + 26))
                var nameStart = pos + 32
                if flags & 0x0100 != 0 {
                    guard headSize >= 40 else { return }
                    packed |= Int64(le32(b, pos + 32)) << 32
                    unpacked |= Int64(le32(b, pos + 36)) << 32
                    nameStart = pos + 40
                }
                dataSize = packed
                if type == 0x74, nameStart + nameSize <= pos + headSize {
                    var nameBytes = Array(b[nameStart..<(nameStart + nameSize)])
                    // Unicode names carry an ASCII copy before a zero byte.
                    if flags & 0x0200 != 0, let zero = nameBytes.firstIndex(of: 0) {
                        nameBytes = Array(nameBytes[..<zero])
                    }
                    volume.entries.append(UsenetRarEntry(
                        name: decodeName(nameBytes),
                        packedSize: packed,
                        unpackedSize: unpacked,
                        dataOffset: base + Int64(pos + headSize),
                        isStored: method == 0x30,
                        isEncrypted: flags & 0x0004 != 0,
                        isDirectory: flags & 0x00E0 == 0x00E0,
                        continuesFromPrevious: flags & 0x0001 != 0,
                        continuesInNext: flags & 0x0002 != 0
                    ))
                }
            case 0x7B: // end of archive
                volume.reachedEnd = true
                return
            default:
                if flags & 0x8000 != 0, headSize >= 11 { dataSize = Int64(le32(b, pos + 7)) }
            }

            let next = Int64(pos) + Int64(headSize) + dataSize
            guard next > Int64(pos) else { return }
            guard next < Int64(b.count) else {
                volume.pendingHeaderOffset = base + next
                return
            }
            pos = Int(next)
        }
    }

    private static func parseRar5(_ b: [UInt8], from start: Int, base: Int64, into volume: inout UsenetRarVolume) {
        var pos = start
        while true {
            guard pos + 6 <= b.count else {
                volume.pendingHeaderOffset = base + Int64(pos)
                return
            }
            var cursor = pos + 4 // header CRC32
            guard let headerSize = vint(b, &cursor) else {
                volume.pendingHeaderOffset = base + Int64(pos)
                return
            }
            guard headerSize > 0, headerSize < 2 << 20 else { return }
            let headerEnd = cursor + Int(headerSize)
            guard headerEnd <= b.count else {
                volume.pendingHeaderOffset = base + Int64(pos)
                return
            }
            guard let type = vint(b, &cursor), let flags = vint(b, &cursor) else { return }
            var extraSize: UInt64 = 0
            var dataSize: UInt64 = 0
            if flags & 0x0001 != 0 {
                guard let value = vint(b, &cursor) else { return }
                extraSize = value
            }
            if flags & 0x0002 != 0 {
                guard let value = vint(b, &cursor) else { return }
                dataSize = value
            }

            switch type {
            case 1: // main archive header
                guard let archiveFlags = vint(b, &cursor) else { return }
                if archiveFlags & 0x0002 != 0, let number = vint(b, &cursor) {
                    volume.volumeNumber = Int(number)
                    volume.isFirstVolume = false
                } else {
                    volume.volumeNumber = 0
                    volume.isFirstVolume = true
                }
            case 2: // file header
                guard let fileFlags = vint(b, &cursor),
                      let unpacked = vint(b, &cursor),
                      vint(b, &cursor) != nil else { return } // attributes
                if fileFlags & 0x0002 != 0 { cursor += 4 } // mtime
                if fileFlags & 0x0004 != 0 { cursor += 4 } // CRC32
                guard let compression = vint(b, &cursor),
                      vint(b, &cursor) != nil, // host OS
                      let nameLength = vint(b, &cursor),
                      cursor + Int(nameLength) <= headerEnd else { return }
                let name = decodeName(Array(b[cursor..<(cursor + Int(nameLength))]))
                var encrypted = false
                if extraSize > 0, extraSize <= headerSize {
                    var record = headerEnd - Int(extraSize)
                    while record < headerEnd {
                        var c = record
                        guard let size = vint(b, &c), size > 0 else { break }
                        let recordEnd = c + Int(size)
                        guard recordEnd <= headerEnd, let recordType = vint(b, &c) else { break }
                        if recordType == 0x01 { encrypted = true }
                        record = recordEnd
                    }
                }
                volume.entries.append(UsenetRarEntry(
                    name: name,
                    packedSize: Int64(dataSize),
                    unpackedSize: fileFlags & 0x0008 != 0 ? -1 : Int64(unpacked),
                    dataOffset: base + Int64(headerEnd),
                    isStored: (compression >> 7) & 0x07 == 0,
                    isEncrypted: encrypted,
                    isDirectory: fileFlags & 0x0001 != 0,
                    continuesFromPrevious: flags & 0x0008 != 0,
                    continuesInNext: flags & 0x0010 != 0
                ))
            case 4: // archive encryption header: everything after it is encrypted
                volume.headersEncrypted = true
                return
            case 5: // end of archive
                volume.reachedEnd = true
                return
            default:
                break
            }

            let next = UInt64(headerEnd) + dataSize
            guard next < UInt64(b.count) else {
                volume.pendingHeaderOffset = base + Int64(clamping: next)
                return
            }
            pos = Int(next)
        }
    }

    /// RAR 5 variable-length integer: 7 bits per byte, high bit = more.
    static func vint(_ b: [UInt8], _ index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < b.count, shift < 64 {
            let byte = b[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }

    private static func decodeName(_ bytes: [UInt8]) -> String {
        let name = String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        return name.replacingOccurrences(of: "\\", with: "/")
    }
}

// MARK: - PAR2

/// PAR2 "file description" packets carry each file's real name and the MD5
/// of its first 16 KiB, which is how obfuscated releases get their names back.
enum UsenetPar2 {
    struct FileDescription: Equatable, Sendable {
        var name: String
        var hash16k: Data
        var length: Int64
    }

    static let magic: [UInt8] = Array("PAR2\0PKT".utf8)
    static let fileDescriptionType: [UInt8] = Array("PAR 2.0\0FileDesc".utf8)

    static func isPar2(_ data: Data) -> Bool { data.starts(with: magic) }

    static func fileDescriptions(in data: Data) -> [FileDescription] {
        let b = [UInt8](data)
        var result: [FileDescription] = []
        var seen = Set<Data>()
        var pos = 0
        while pos + 64 <= b.count {
            guard Array(b[pos..<(pos + 8)]) == magic else {
                // Damaged or foreign bytes: resync on the next packet.
                guard let next = firstIndex(of: magic, in: b, from: pos + 1) else { break }
                pos = next
                continue
            }
            let length = le64(b, pos + 8)
            guard length >= 64, length % 4 == 0, length <= UInt64(b.count - pos) else { break }
            let packetEnd = pos + Int(length)
            if Array(b[(pos + 48)..<(pos + 64)]) == fileDescriptionType, packetEnd - pos >= 64 + 56 {
                let body = pos + 64
                let hash = Data(b[(body + 32)..<(body + 48)])
                var nameBytes = Array(b[(body + 56)..<packetEnd])
                while nameBytes.last == 0 { nameBytes.removeLast() }
                let name = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
                if !name.isEmpty, seen.insert(hash).inserted {
                    result.append(FileDescription(name: name, hash16k: hash, length: Int64(clamping: le64(b, body + 48))))
                }
            }
            pos = packetEnd
        }
        return result
    }

    /// The MD5 PAR2 stores for a file: of its first 16 KiB (or all of it, if shorter).
    static func hash16k(_ head: Data) -> Data {
        Data(Insecure.MD5.hash(data: head.prefix(16 * 1024)))
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard needle.count <= haystack.count, start <= haystack.count - needle.count else { return nil }
        var i = start
        while i <= haystack.count - needle.count {
            if haystack[i] == needle[0], Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - Content sniffing

/// What a file is, judged by its first bytes rather than its (possibly obfuscated) name.
enum UsenetSniff {
    enum Kind: Equatable, Sendable {
        case video(String)
        case rar
        case par2
        case sevenZip
        case zip
        case unknown
    }

    static func kind(of data: Data) -> Kind {
        let b = [UInt8](data.prefix(1024))
        if b.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return .video("mkv") }
        if b.count >= 12, Array(b[4..<8]) == Array("ftyp".utf8) { return .video("mp4") }
        if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("AVI ".utf8) { return .video("avi") }
        if b.count > 376, b[0] == 0x47, b[188] == 0x47, b[376] == 0x47 { return .video("ts") }
        if b.count > 388, b[4] == 0x47, b[196] == 0x47, b[388] == 0x47 { return .video("m2ts") }
        if UsenetRar.isRar(data) { return .rar }
        if UsenetPar2.isPar2(data) { return .par2 }
        if b.starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if b.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        return .unknown
    }
}

// MARK: - Little-endian helpers

private func le16(_ b: [UInt8], _ i: Int) -> UInt16 {
    UInt16(b[i]) | UInt16(b[i + 1]) << 8
}

private func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}

private func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
    UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32
}
