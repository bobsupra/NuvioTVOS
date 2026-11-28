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
    /// How its bytes are encrypted, when RAR can tell (nil for RAR 2.0 encryption).
    var encryption: UsenetRarEncryption? = nil
}

/// What the headers at the front of one RAR volume say.
struct UsenetRarVolume: Equatable, Sendable {
    enum Format: Sendable { case rar4, rar5 }

    var format: Format
    /// RAR 5 numbers volumes from 0; RAR 4 doesn't store a number up front.
    var volumeNumber: Int?
    /// RAR 4 (3.0 and newer) and RAR 5 both flag the first volume.
    var isFirstVolume: Bool?
    /// The headers are encrypted and couldn't be read: no password, or not the right one.
    var headersEncrypted = false
    /// The password was tried on the encrypted headers and didn't open them.
    var passwordRejected = false
    /// How the rest of the headers are read, once the password opened them.
    var headerCipher: UsenetRarHeaderCipher?
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
    /// `password` opens encrypted headers (RAR's "encrypt file names").
    static func parseVolume(_ data: Data, password: String? = nil) -> UsenetRarVolume? {
        let bytes = [UInt8](data.prefix(4 << 20))
        if bytes.starts(with: rar5Signature) {
            var volume = UsenetRarVolume(format: .rar5)
            parseRar5(bytes, from: rar5Signature.count, base: 0, password: password, into: &volume)
            return volume
        }
        if bytes.starts(with: rar4Signature) {
            var volume = UsenetRarVolume(format: .rar4)
            parseRar4(bytes, from: rar4Signature.count, base: 0, password: password, into: &volume)
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
        case .rar4: parseRar4(b, from: 0, base: offset, password: nil, into: &volume)
        case .rar5: parseRar5(b, from: 0, base: offset, password: nil, into: &volume)
        }
    }

    /// One header's bytes (decrypted when the headers are) and where it ends in the volume.
    private enum HeaderRead {
        case header(bytes: [UInt8], end: Int)
        /// It runs past the bytes read so far.
        case needMore
        /// Not a header: damaged, or decrypted with the wrong password.
        case broken
    }

    /// The headers' password failed: the archive can't be read past here.
    private static func reject(_ volume: inout UsenetRarVolume) {
        volume.headersEncrypted = true
        volume.passwordRejected = true
        volume.headerCipher = nil
    }

    // MARK: RAR 4

    private static func readRar4Header(_ b: [UInt8], at pos: Int, cipher: UsenetRarHeaderCipher?) -> HeaderRead {
        guard case .rar4(let password)? = cipher else {
            guard pos + 7 <= b.count else { return .needMore }
            let headSize = Int(le16(b, pos + 5))
            guard headSize >= 7 else { return .broken }
            guard pos + headSize <= b.count else { return .needMore }
            return .header(bytes: Array(b[pos..<(pos + headSize)]), end: pos + headSize)
        }
        // An 8-byte salt, then the header encrypted with the key that salt gives.
        guard pos + 24 <= b.count else { return .needMore }
        let (key, iv) = UsenetRarCrypto.rar4Key(password: password, salt: Data(b[pos..<(pos + 8)]))
        guard let first = UsenetRarCrypto.decrypt(Data(b[(pos + 8)..<(pos + 24)]), key: key, iv: iv) else { return .broken }
        let firstBytes = [UInt8](first)
        let headSize = Int(le16(firstBytes, 5))
        // A wrong password decrypts to noise: a block type RAR doesn't have, or a size that
        // would only wait for more bytes.
        guard headSize >= 7, (0x73...0x7B).contains(firstBytes[2]) else { return .broken }
        let padded = (headSize + 15) / 16 * 16
        guard pos + 8 + padded <= b.count else { return .needMore }
        guard let plain = UsenetRarCrypto.decrypt(Data(b[(pos + 8)..<(pos + 8 + padded)]), key: key, iv: iv) else { return .broken }
        let header = [UInt8](plain.prefix(headSize))
        let crc = UsenetCRC32.checksum(of: Data(header[2...]))
        guard UInt16(crc & 0xFFFF) == le16(header, 0) else { return .broken }
        return .header(bytes: header, end: pos + 8 + padded)
    }

    private static func parseRar4(_ b: [UInt8], from start: Int, base: Int64, password: String?, into volume: inout UsenetRarVolume) {
        var pos = start
        while true {
            let h: [UInt8]
            let headerEnd: Int
            switch readRar4Header(b, at: pos, cipher: volume.headerCipher) {
            case .needMore:
                volume.pendingHeaderOffset = base + Int64(pos)
                return
            case .broken:
                if volume.headerCipher != nil, volume.entries.isEmpty { reject(&volume) }
                return
            case let .header(bytes, end):
                h = bytes
                headerEnd = end
            }
            let headSize = h.count
            let type = h[2]
            let flags = Int(le16(h, 3))
            var dataSize: Int64 = 0

            switch type {
            case 0x73: // main header
                volume.isFirstVolume = flags & 0x0100 != 0
                if flags & 0x0080 != 0 {
                    // Every header after this one is encrypted.
                    guard let password, !password.isEmpty else {
                        volume.headersEncrypted = true
                        return
                    }
                    volume.headerCipher = .rar4(password: password)
                }
            case 0x74, 0x7A: // file, service
                guard headSize >= 32 else { return }
                var packed = Int64(le32(h, 7))
                var unpacked = Int64(le32(h, 11))
                let version = h[24]
                let method = h[25]
                let nameSize = Int(le16(h, 26))
                var nameStart = 32
                if flags & 0x0100 != 0 {
                    guard headSize >= 40 else { return }
                    packed |= Int64(le32(h, 32)) << 32
                    unpacked |= Int64(le32(h, 36)) << 32
                    nameStart = 40
                }
                dataSize = packed
                if type == 0x74, nameStart + nameSize <= headSize {
                    var nameBytes = Array(h[nameStart..<(nameStart + nameSize)])
                    // Unicode names carry an ASCII copy before a zero byte.
                    if flags & 0x0200 != 0, let zero = nameBytes.firstIndex(of: 0) {
                        nameBytes = Array(nameBytes[..<zero])
                    }
                    let isEncrypted = flags & 0x0004 != 0
                    var encryption: UsenetRarEncryption?
                    if isEncrypted, version >= 29 {
                        // AES (RAR 2.9 and newer), with the salt after the name when there is one.
                        let saltStart = nameStart + nameSize
                        if flags & 0x0400 == 0 {
                            encryption = .rar4(salt: Data())
                        } else if saltStart + 8 <= headSize {
                            encryption = .rar4(salt: Data(h[saltStart..<(saltStart + 8)]))
                        }
                    }
                    volume.entries.append(UsenetRarEntry(
                        name: decodeName(nameBytes),
                        packedSize: packed,
                        unpackedSize: unpacked,
                        dataOffset: base + Int64(headerEnd),
                        isStored: method == 0x30,
                        isEncrypted: isEncrypted,
                        isDirectory: flags & 0x00E0 == 0x00E0,
                        continuesFromPrevious: flags & 0x0001 != 0,
                        continuesInNext: flags & 0x0002 != 0,
                        encryption: encryption
                    ))
                }
            case 0x7B: // end of archive
                volume.reachedEnd = true
                return
            default:
                if flags & 0x8000 != 0, headSize >= 11 { dataSize = Int64(le32(h, 7)) }
            }

            let next = Int64(headerEnd) + dataSize
            guard next > Int64(pos) else { return }
            guard next < Int64(b.count) else {
                volume.pendingHeaderOffset = base + next
                return
            }
            pos = Int(next)
        }
    }

    // MARK: RAR 5

    private static func readRar5Header(_ b: [UInt8], at pos: Int, cipher: UsenetRarHeaderCipher?) -> HeaderRead {
        guard case .rar5(let key)? = cipher else {
            guard pos + 6 <= b.count else { return .needMore }
            var cursor = pos + 4 // header CRC32
            guard let headerSize = vint(b, &cursor) else { return .needMore }
            guard headerSize > 0, headerSize < 2 << 20 else { return .broken }
            let end = cursor + Int(headerSize)
            guard end <= b.count else { return .needMore }
            return .header(bytes: Array(b[pos..<end]), end: end)
        }
        // A 16-byte IV, then the header encrypted, padded to whole blocks.
        guard pos + 32 <= b.count else { return .needMore }
        let iv = Data(b[pos..<(pos + 16)])
        guard let first = UsenetRarCrypto.decrypt(Data(b[(pos + 16)..<(pos + 32)]), key: key, iv: iv) else { return .broken }
        var cursor = 4
        guard let headerSize = vint([UInt8](first), &cursor), headerSize > 0, headerSize < 2 << 20 else { return .broken }
        let length = cursor + Int(headerSize)
        let padded = (length + 15) / 16 * 16
        guard pos + 16 + padded <= b.count else { return .needMore }
        guard let plain = UsenetRarCrypto.decrypt(Data(b[(pos + 16)..<(pos + 16 + padded)]), key: key, iv: iv) else { return .broken }
        let header = [UInt8](plain.prefix(length))
        guard UsenetCRC32.checksum(of: Data(header[4...])) == le32(header, 0) else { return .broken }
        return .header(bytes: header, end: pos + 16 + padded)
    }

    private static func parseRar5(_ b: [UInt8], from start: Int, base: Int64, password: String?, into volume: inout UsenetRarVolume) {
        var pos = start
        while true {
            let h: [UInt8]
            let headerEnd: Int
            switch readRar5Header(b, at: pos, cipher: volume.headerCipher) {
            case .needMore:
                volume.pendingHeaderOffset = base + Int64(pos)
                return
            case .broken:
                if volume.headerCipher != nil, volume.entries.isEmpty { reject(&volume) }
                return
            case let .header(bytes, end):
                h = bytes
                headerEnd = end
            }
            let fieldsEnd = h.count
            var cursor = 4
            guard vint(h, &cursor) != nil, // header size
                  let type = vint(h, &cursor), let flags = vint(h, &cursor) else { return }
            var extraSize: UInt64 = 0
            var dataSize: UInt64 = 0
            if flags & 0x0001 != 0 {
                guard let value = vint(h, &cursor) else { return }
                extraSize = value
            }
            if flags & 0x0002 != 0 {
                guard let value = vint(h, &cursor) else { return }
                dataSize = value
            }

            switch type {
            case 1: // main archive header
                guard let archiveFlags = vint(h, &cursor) else { return }
                if archiveFlags & 0x0002 != 0, let number = vint(h, &cursor) {
                    volume.volumeNumber = Int(number)
                    volume.isFirstVolume = false
                } else {
                    volume.volumeNumber = 0
                    volume.isFirstVolume = true
                }
            case 2: // file header
                guard let fileFlags = vint(h, &cursor),
                      let unpacked = vint(h, &cursor),
                      vint(h, &cursor) != nil else { return } // attributes
                if fileFlags & 0x0002 != 0 { cursor += 4 } // mtime
                if fileFlags & 0x0004 != 0 { cursor += 4 } // CRC32
                guard let compression = vint(h, &cursor),
                      vint(h, &cursor) != nil, // host OS
                      let nameLength = vint(h, &cursor),
                      cursor + Int(nameLength) <= fieldsEnd else { return }
                let name = decodeName(Array(h[cursor..<(cursor + Int(nameLength))]))
                var encrypted = false
                var encryption: UsenetRarEncryption?
                if extraSize > 0, extraSize <= UInt64(fieldsEnd) {
                    var record = fieldsEnd - Int(extraSize)
                    while record < fieldsEnd {
                        var c = record
                        guard let size = vint(h, &c), size > 0 else { break }
                        let recordEnd = c + Int(size)
                        guard recordEnd <= fieldsEnd, let recordType = vint(h, &c) else { break }
                        if recordType == 0x01 {
                            encrypted = true
                            encryption = rar5Encryption(h, from: c, to: recordEnd)
                        }
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
                    continuesInNext: flags & 0x0010 != 0,
                    encryption: encryption
                ))
            case 4: // archive encryption header: every header after it is encrypted
                guard let password, !password.isEmpty,
                      vint(h, &cursor) != nil, // version
                      let cryptFlags = vint(h, &cursor),
                      cursor + 17 <= fieldsEnd else {
                    volume.headersEncrypted = true
                    return
                }
                let count = Int(h[cursor])
                let salt = Data(h[(cursor + 1)..<(cursor + 17)])
                cursor += 17
                let check: Data? = cryptFlags & 0x0001 != 0 && cursor + 12 <= fieldsEnd ? Data(h[cursor..<(cursor + 12)]) : nil
                if let check, UsenetRarCrypto.isUsableCheck(check),
                   !UsenetRarCrypto.rar5PasswordMatches(check: check, password: password, salt: salt, count: count) {
                    reject(&volume)
                    return
                }
                guard count <= UsenetRarCrypto.maxRar5Count,
                      let key = UsenetRarCrypto.rar5Key(password: password, salt: salt, count: count) else {
                    volume.headersEncrypted = true
                    return
                }
                volume.headerCipher = .rar5(key: key)
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

    /// A file's encryption record: version, flags, KDF count, salt, IV, and the password check
    /// value when flag 1 says there is one.
    private static func rar5Encryption(_ h: [UInt8], from start: Int, to end: Int) -> UsenetRarEncryption? {
        var cursor = start
        guard let version = vint(h, &cursor), version == 0,
              let flags = vint(h, &cursor), cursor + 33 <= end else { return nil }
        let count = Int(h[cursor])
        let salt = Data(h[(cursor + 1)..<(cursor + 17)])
        let iv = Data(h[(cursor + 17)..<(cursor + 33)])
        cursor += 33
        let check: Data? = flags & 0x0001 != 0 && cursor + 12 <= end ? Data(h[cursor..<(cursor + 12)]) : nil
        return .rar5(count: count, salt: salt, iv: iv, check: check)
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
