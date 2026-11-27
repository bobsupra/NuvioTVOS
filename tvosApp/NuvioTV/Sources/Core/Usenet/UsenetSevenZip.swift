import CryptoKit
import Foundation

// MARK: - 7z

/// Header-only 7z reader: finds where a stored (Copy) file's bytes sit in an archive, so they
/// can be streamed in place, the way stored RAR files are. A multi-volume 7z (`.7z.001`, …) is
/// the archive cut into pieces, so offsets are into the volumes joined. The file list sits at
/// the archive's end, usually LZMA-compressed and, with "encrypt file names", AES-encrypted.
enum UsenetSevenZip {
    static let signature: [UInt8] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]
    /// No archive header is ever this large; a damaged size isn't followed.
    static let maxHeaderSize = 64 << 20

    enum Failure: Error, Equatable {
        case notSevenZip
        case damaged
        /// A coder (or coder layout) only an unpacker could follow.
        case unsupported
        /// The file list is encrypted and there is no password.
        case needsPassword
        case wrongPassword
    }

    /// How a file's bytes are kept.
    enum Method: Equatable, Sendable {
        case stored
        /// Stored, AES-256-CBC: `properties` hold the key rounds, salt and IV.
        case encrypted(properties: Data)
        /// Compressed (LZMA, LZMA2, …): it can't be streamed.
        case compressed
    }

    struct Entry: Equatable, Sendable {
        var name: String
        var size: Int64
        var isDirectory: Bool
        /// Where its folder's packed bytes start in the archive, and how many there are.
        var packStart: Int64
        var packSize: Int64
        /// Where the file starts in its folder's unpacked bytes (stored files of a solid
        /// folder follow each other).
        var offsetInFolder: Int64
        var method: Method
    }

    typealias Reader = (_ offset: Int64, _ length: Int) async throws -> Data

    /// Where the file list sits in the archive, from its first 32 bytes.
    static func nextHeader(_ head: Data) throws -> (offset: Int64, size: Int) {
        let b = [UInt8](head.prefix(32))
        guard b.count == 32, b.starts(with: signature) else { throw Failure.notSevenZip }
        let offset = le64(b, 12)
        let size = le64(b, 20)
        guard offset < UInt64(Int64.max - 32), size > 0, size <= UInt64(maxHeaderSize) else { throw Failure.damaged }
        return (Int64(offset) + 32, Int(size))
    }

    /// The archive's files from its file list (`header`); `read` gives other bytes of the
    /// archive (an encoded file list's packed stream).
    static func entries(header: Data, password: String?, read: Reader) async throws -> [Entry] {
        var reader = ByteReader([UInt8](header))
        var type = try reader.byte()
        var rounds = 0
        while type == Property.encodedHeader {
            rounds += 1
            guard rounds <= 4 else { throw Failure.damaged }
            let info = try streamsInfo(&reader)
            guard let folder = info.folders.first, let packSize = info.packSizes.first,
                  packSize <= UInt64(maxHeaderSize) else { throw Failure.damaged }
            let packed = try await read(Int64(info.packPos) + 32, Int(packSize))
            guard packed.count == Int(packSize) else { throw Failure.damaged }
            reader = ByteReader([UInt8](try decode(folder, packed: packed, password: password)))
            type = try reader.byte()
        }
        guard type == Property.header else { throw Failure.damaged }
        return try parseHeader(&reader)
    }

    /// The AES key and IV for `properties`, and the cipher a stored, encrypted file is
    /// decrypted with.
    static func cipher(properties: Data, password: String, plainSize: Int64) throws -> UsenetRarCipher {
        let (key, iv) = try aesKey(properties: properties, password: password)
        return UsenetRarCipher(key: key, iv: iv, plainSize: plainSize, passwordChecked: false)
    }

    // MARK: Header

    private enum Property {
        static let end: UInt8 = 0x00
        static let header: UInt8 = 0x01
        static let archiveProperties: UInt8 = 0x02
        static let additionalStreamsInfo: UInt8 = 0x03
        static let mainStreamsInfo: UInt8 = 0x04
        static let filesInfo: UInt8 = 0x05
        static let packInfo: UInt8 = 0x06
        static let unpackInfo: UInt8 = 0x07
        static let subStreamsInfo: UInt8 = 0x08
        static let size: UInt8 = 0x09
        static let crc: UInt8 = 0x0A
        static let folder: UInt8 = 0x0B
        static let codersUnpackSize: UInt8 = 0x0C
        static let numUnpackStream: UInt8 = 0x0D
        static let emptyStream: UInt8 = 0x0E
        static let emptyFile: UInt8 = 0x0F
        static let name: UInt8 = 0x11
        static let encodedHeader: UInt8 = 0x17
    }

    private enum CoderID {
        static let copy: [UInt8] = [0x00]
        static let lzma: [UInt8] = [0x03, 0x01, 0x01]
        static let aes: [UInt8] = [0x06, 0xF1, 0x07, 0x01]
    }

    struct Coder: Equatable, Sendable {
        var id: [UInt8]
        var properties: Data
    }

    /// Coders that each take one stream and give one, chained.
    struct Folder: Equatable, Sendable {
        var coders: [Coder]
        /// Bind pairs: coder `input` reads what coder `output` writes.
        var binds: [(input: Int, output: Int)]
        var unpackSizes: [UInt64] = []
        var crcDefined = false

        static func == (a: Folder, b: Folder) -> Bool {
            a.coders == b.coders && a.unpackSizes == b.unpackSizes
                && a.binds.map(\.input) == b.binds.map(\.input) && a.binds.map(\.output) == b.binds.map(\.output)
        }

        /// The coders from the one reading the packed stream to the one giving the result.
        func chain() throws -> [Int] {
            let boundInputs = Set(binds.map(\.input))
            let starts = coders.indices.filter { !boundInputs.contains($0) }
            guard starts.count == 1, var current = starts.first else { throw Failure.unsupported }
            var order = [current]
            while let next = binds.first(where: { $0.output == current })?.input {
                guard !order.contains(next), order.count < coders.count else { throw Failure.damaged }
                order.append(next)
                current = next
            }
            guard order.count == coders.count else { throw Failure.unsupported }
            return order
        }

        /// What the folder gives: the output of the last coder in the chain.
        var unpackSize: UInt64 {
            guard let last = try? chain().last, unpackSizes.indices.contains(last) else { return 0 }
            return unpackSizes[last]
        }

        var method: Method {
            if coders.allSatisfy({ $0.id == CoderID.copy }) { return .stored }
            let aes = coders.filter { $0.id == CoderID.aes }
            if aes.count == 1, coders.allSatisfy({ $0.id == CoderID.aes || $0.id == CoderID.copy }) {
                return .encrypted(properties: aes[0].properties)
            }
            return .compressed
        }
    }

    private struct StreamsInfo {
        var packPos: UInt64 = 0
        var packSizes: [UInt64] = []
        var folders: [Folder] = []
        /// Files per folder, and their sizes.
        var streams: [[UInt64]] = []
    }

    private static func parseHeader(_ r: inout ByteReader) throws -> [Entry] {
        var main = StreamsInfo()
        var names: [String] = []
        var emptyStream: [Bool] = []
        var emptyFile: [Bool] = []
        var fileCount = 0
        while true {
            let type = try r.byte()
            switch type {
            case Property.end:
                return try layout(main, names: names, fileCount: fileCount, emptyStream: emptyStream, emptyFile: emptyFile)
            case Property.archiveProperties:
                while try r.byte() != 0 { _ = try r.bytes(Int(try r.number())) }
            case Property.additionalStreamsInfo:
                _ = try streamsInfo(&r)
            case Property.mainStreamsInfo:
                main = try streamsInfo(&r)
            case Property.filesInfo:
                fileCount = Int(try r.number())
                guard fileCount <= 1_000_000 else { throw Failure.damaged }
                while true {
                    let property = try r.byte()
                    if property == Property.end { break }
                    let size = Int(try r.number())
                    var body = ByteReader(try r.bytes(size))
                    switch property {
                    case Property.emptyStream:
                        emptyStream = try body.bits(fileCount)
                    case Property.emptyFile:
                        emptyFile = try body.bits(emptyStream.filter { $0 }.count)
                    case Property.name:
                        guard try body.byte() == 0 else { throw Failure.unsupported } // names kept elsewhere
                        names = utf16Names(Array(body.rest))
                    default:
                        break
                    }
                }
            default:
                throw Failure.damaged
            }
        }
    }

    private static func layout(_ main: StreamsInfo, names: [String], fileCount: Int,
                               emptyStream: [Bool], emptyFile: [Bool]) throws -> [Entry] {
        var entries: [Entry] = []
        var emptyIndex = 0
        var folder = 0
        var stream = 0
        var offsetInFolder: Int64 = 0
        var packIndex = 0
        var packStart = Int64(main.packPos) + 32
        func folderPackSize(_ f: Int) -> Int64 {
            let count = max(1, main.folders[f].coders.count - main.folders[f].binds.count)
            return main.packSizes.dropFirst(packIndex).prefix(count).reduce(0) { $0 + Int64($1) }
        }
        for index in 0..<fileCount {
            let name = index < names.count ? names[index] : ""
            if index < emptyStream.count, emptyStream[index] {
                let isFile = emptyIndex < emptyFile.count && emptyFile[emptyIndex]
                emptyIndex += 1
                entries.append(Entry(name: name, size: 0, isDirectory: !isFile, packStart: 0, packSize: 0,
                                     offsetInFolder: 0, method: .stored))
                continue
            }
            // Folders without files (rare) are skipped over.
            while folder < main.folders.count, stream >= main.streams[folder].count {
                packStart += folderPackSize(folder)
                packIndex += max(1, main.folders[folder].coders.count - main.folders[folder].binds.count)
                folder += 1
                stream = 0
                offsetInFolder = 0
            }
            guard folder < main.folders.count else { throw Failure.damaged }
            let size = Int64(main.streams[folder][stream])
            entries.append(Entry(name: name, size: size, isDirectory: false, packStart: packStart,
                                 packSize: folderPackSize(folder), offsetInFolder: offsetInFolder,
                                 method: main.folders[folder].method))
            offsetInFolder += size
            stream += 1
        }
        return entries
    }

    private static func streamsInfo(_ r: inout ByteReader) throws -> StreamsInfo {
        var info = StreamsInfo()
        var hasSubStreams = false
        while true {
            let type = try r.byte()
            switch type {
            case Property.end:
                if !hasSubStreams { info.streams = info.folders.map { [$0.unpackSize] } }
                return info
            case Property.packInfo:
                info.packPos = try r.number()
                let count = Int(try r.number())
                guard count <= 1_000_000 else { throw Failure.damaged }
                while true {
                    let property = try r.byte()
                    if property == Property.end { break }
                    if property == Property.size {
                        info.packSizes = try (0..<count).map { _ in try r.number() }
                    } else if property == Property.crc {
                        let defined = try r.defined(count)
                        for isDefined in defined where isDefined { _ = try r.bytes(4) }
                    } else {
                        throw Failure.damaged
                    }
                }
            case Property.unpackInfo:
                guard try r.byte() == Property.folder else { throw Failure.damaged }
                let count = Int(try r.number())
                guard count <= 1_000_000, try r.byte() == 0 else { throw Failure.unsupported }
                info.folders = try (0..<count).map { _ in try folder(&r) }
                guard try r.byte() == Property.codersUnpackSize else { throw Failure.damaged }
                for k in info.folders.indices {
                    info.folders[k].unpackSizes = try info.folders[k].coders.map { _ in try r.number() }
                }
                while true {
                    let property = try r.byte()
                    if property == Property.end { break }
                    guard property == Property.crc else { throw Failure.damaged }
                    let defined = try r.defined(count)
                    for (k, isDefined) in defined.enumerated() where isDefined {
                        info.folders[k].crcDefined = true
                        _ = try r.bytes(4)
                    }
                }
            case Property.subStreamsInfo:
                hasSubStreams = true
                var counts = info.folders.map { _ in 1 }
                var property = try r.byte()
                if property == Property.numUnpackStream {
                    counts = try info.folders.map { _ in Int(try r.number()) }
                    property = try r.byte()
                }
                info.streams = []
                for (k, folder) in info.folders.enumerated() {
                    var sizes: [UInt64] = []
                    guard counts[k] > 0 else {
                        info.streams.append([])
                        continue
                    }
                    var total: UInt64 = 0
                    if property == Property.size {
                        for _ in 0..<(counts[k] - 1) {
                            let size = try r.number()
                            sizes.append(size)
                            total &+= size
                        }
                    }
                    guard total <= folder.unpackSize else { throw Failure.damaged }
                    sizes.append(folder.unpackSize - total)
                    info.streams.append(sizes)
                }
                if property == Property.size { property = try r.byte() }
                while property != Property.end {
                    guard property == Property.crc else { throw Failure.damaged }
                    let digests = zip(info.folders, counts).reduce(0) { $0 + ($1.1 == 1 && $1.0.crcDefined ? 0 : $1.1) }
                    let defined = try r.defined(digests)
                    for isDefined in defined where isDefined { _ = try r.bytes(4) }
                    property = try r.byte()
                }
            default:
                throw Failure.damaged
            }
        }
    }

    private static func folder(_ r: inout ByteReader) throws -> Folder {
        let count = Int(try r.number())
        guard (1...8).contains(count) else { throw Failure.unsupported }
        var coders: [Coder] = []
        for _ in 0..<count {
            let flags = try r.byte()
            let id = try r.bytes(Int(flags & 0x0F))
            // Coders with several streams (BCJ2) and alternative methods: unpacking only.
            if flags & 0x10 != 0 {
                guard try r.number() == 1, try r.number() == 1 else { throw Failure.unsupported }
            }
            let properties = flags & 0x20 != 0 ? Data(try r.bytes(Int(try r.number()))) : Data()
            guard flags & 0x80 == 0 else { throw Failure.unsupported }
            coders.append(Coder(id: id, properties: properties))
        }
        let binds = try (0..<(count - 1)).map { _ in (input: Int(try r.number()), output: Int(try r.number())) }
        // One packed stream: which coder reads it follows from the binds.
        guard binds.allSatisfy({ $0.input < count && $0.output < count }) else { throw Failure.damaged }
        return Folder(coders: coders, binds: binds)
    }

    // MARK: Decoding a file list

    private static func decode(_ folder: Folder, packed: Data, password: String?) throws -> Data {
        var data = packed
        for index in try folder.chain() {
            let coder = folder.coders[index]
            guard folder.unpackSizes.indices.contains(index), folder.unpackSizes[index] <= UInt64(maxHeaderSize) else {
                throw Failure.damaged
            }
            let size = Int(folder.unpackSizes[index])
            switch coder.id {
            case CoderID.copy:
                guard data.count >= size else { throw Failure.damaged }
                data = Data(data.prefix(size))
            case CoderID.lzma:
                do {
                    data = try UsenetLZMA.decode(properties: coder.properties, data: data, size: size)
                } catch {
                    // An encrypted list decrypted with the wrong password is noise.
                    throw folder.coders.contains(where: { $0.id == CoderID.aes }) ? Failure.wrongPassword : Failure.damaged
                }
            case CoderID.aes:
                guard let password, !password.isEmpty else { throw Failure.needsPassword }
                let (key, iv) = try aesKey(properties: coder.properties, password: password)
                guard let plain = UsenetRarCrypto.decrypt(Data(data.prefix(data.count / 16 * 16)), key: key, iv: iv),
                      plain.count >= size else { throw Failure.damaged }
                data = Data(plain.prefix(size))
            default:
                throw Failure.unsupported
            }
        }
        return data
    }

    // MARK: AES

    /// 7-Zip's AES-256 key: SHA-256 over 2^cycles rounds of salt, password (UTF-16LE) and the
    /// round number; the IV and salt come from the coder's properties.
    static func aesKey(properties: Data, password: String) throws -> (key: Data, iv: Data) {
        let p = [UInt8](properties)
        guard let first = p.first else { throw Failure.damaged }
        let cycles = Int(first & 0x3F)
        var salt: [UInt8] = []
        var iv: [UInt8] = []
        if first & 0xC0 != 0 {
            guard p.count >= 2 else { throw Failure.damaged }
            let saltSize = Int((first >> 7) & 1) + Int(p[1] >> 4)
            let ivSize = Int((first >> 6) & 1) + Int(p[1] & 0x0F)
            guard 2 + saltSize + ivSize <= p.count, ivSize <= 16 else { throw Failure.damaged }
            salt = Array(p[2..<(2 + saltSize)])
            iv = Array(p[(2 + saltSize)..<(2 + saltSize + ivSize)])
        }
        iv += [UInt8](repeating: 0, count: 16 - iv.count)
        guard cycles <= 24 || cycles == 0x3F else { throw Failure.unsupported }
        var passwordBytes: [UInt8] = []
        for unit in password.utf16 {
            passwordBytes.append(UInt8(unit & 0xFF))
            passwordBytes.append(UInt8(unit >> 8))
        }
        let cacheKey = Data([UInt8(cycles)] + salt + [0] + passwordBytes)
        if let key = keyCache.value(for: cacheKey) { return (key, Data(iv)) }
        let key: Data
        if cycles == 0x3F {
            key = Data((salt + passwordBytes + [UInt8](repeating: 0, count: 32)).prefix(32))
        } else {
            var buffer = salt + passwordBytes + [UInt8](repeating: 0, count: 8)
            let counterAt = buffer.count - 8
            var hasher = SHA256()
            for round in 0..<(UInt64(1) << UInt64(cycles)) {
                var value = round
                for i in 0..<8 {
                    buffer[counterAt + i] = UInt8(value & 0xFF)
                    value >>= 8
                }
                buffer.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            }
            key = Data(hasher.finalize())
        }
        keyCache.store(key, for: cacheKey)
        return (key, Data(iv))
    }

    private static let keyCache = KeyCache()

    private final class KeyCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Data: Data] = [:]

        func value(for key: Data) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return values[key]
        }

        func store(_ value: Data, for key: Data) {
            lock.lock()
            defer { lock.unlock() }
            if values.count > 32 { values.removeAll() }
            values[key] = value
        }
    }

    // MARK: Bytes

    private static func utf16Names(_ bytes: [UInt8]) -> [String] {
        var names: [String] = []
        var units: [UInt16] = []
        var i = 0
        while i + 1 < bytes.count {
            let unit = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            i += 2
            if unit == 0 {
                names.append(String(decoding: units, as: UTF16.self).replacingOccurrences(of: "\\", with: "/"))
                units = []
            } else {
                units.append(unit)
            }
        }
        return names
    }

    private static func le64(_ b: [UInt8], _ i: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[i + $1]) << (8 * UInt64($1)) }
    }

    private struct ByteReader {
        let bytes: [UInt8]
        var position = 0

        init(_ bytes: [UInt8]) {
            self.bytes = bytes
        }

        var rest: ArraySlice<UInt8> { bytes[min(position, bytes.count)...] }

        mutating func byte() throws -> UInt8 {
            guard position < bytes.count else { throw Failure.damaged }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, position + count <= bytes.count else { throw Failure.damaged }
            defer { position += count }
            return Array(bytes[position..<(position + count)])
        }

        /// 7z's numbers: the first byte's leading one bits say how many bytes follow.
        mutating func number() throws -> UInt64 {
            let first = try byte()
            var mask: UInt8 = 0x80
            var value: UInt64 = 0
            for i in 0..<8 {
                if first & mask == 0 {
                    let high = UInt64(first & (mask &- 1))
                    return value | high << (8 * UInt64(i))
                }
                value |= UInt64(try byte()) << (8 * UInt64(i))
                mask >>= 1
            }
            return value
        }

        mutating func bits(_ count: Int) throws -> [Bool] {
            var result: [Bool] = []
            var mask: UInt8 = 0
            var current: UInt8 = 0
            for _ in 0..<count {
                if mask == 0 {
                    current = try byte()
                    mask = 0x80
                }
                result.append(current & mask != 0)
                mask >>= 1
            }
            return result
        }

        /// A "defined" vector: all defined, or a bit per item.
        mutating func defined(_ count: Int) throws -> [Bool] {
            try byte() != 0 ? Array(repeating: true, count: count) : bits(count)
        }
    }
}
