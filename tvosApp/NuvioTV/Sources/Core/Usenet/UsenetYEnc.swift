//
//  Ported from SwiftNZB (https://github.com/valentinlehmann/swiftnzb), MIT License,
//  Copyright (c) 2026 Valentin Lehmann. Adapted for streaming in Nuvio: renamed with a
//  Usenet prefix, rate limiting removed.
//

import Foundation

struct UsenetCRC32: Sendable {
    // Precomputed lookup table (256 entries), built once.
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private var state: UInt32 = 0xFFFF_FFFF

    init() {}

    /// Feed more bytes into the running checksum.
    mutating func update<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        var c = state
        let table = Self.table
        for b in bytes {
            c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
        }
        state = c
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            Self.table.withUnsafeBufferPointer { table in
                var c = state
                for b in raw {
                    c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8)
                }
                state = c
            }
        }
    }

    /// The current checksum value.
    var checksum: UInt32 { state ^ 0xFFFF_FFFF }

    /// One-shot convenience.
    static func checksum(of data: Data) -> UInt32 {
        var c = UsenetCRC32()
        c.update(data)
        return c.checksum
    }
}

struct UsenetYEncHeader: Equatable, Sendable {
    var name: String?
    var lineLength: Int?
    /// `size=` from =ybegin (the whole-file size for multipart, or the file size for single).
    var size: Int?
    /// `part=` from =ybegin (1-based part number); nil for single-part.
    var part: Int?
    var total: Int?
    /// `begin=`/`end=` from =ypart — 1-based, inclusive byte offsets into the assembled file.
    var partBegin: Int?
    var partEnd: Int?

    var isMultipart: Bool { part != nil || partBegin != nil }
}

struct UsenetYEncSegment: Sendable {
    var data: Data
    var header: UsenetYEncHeader
    /// `size=` from =yend (the size of THIS part's decoded data).
    var declaredPartSize: Int?
    /// The CRC the article claims for this part: `pcrc32` if present, else whole-file `crc32`.
    var declaredCRC: UInt32?
    var computedCRC: UInt32
    /// nil when the article declared no CRC for this part.
    var crcMatches: Bool?
    /// 0-based byte offset where this segment's decoded bytes belong in the assembled file.
    var fileOffset: Int
}

enum UsenetYEncError: Error, Equatable, Sendable {
    case missingBeginHeader
    case emptyBody
}

enum UsenetYEnc {
    private static let escape: UInt8 = 0x3D  // '='

    /// Decode one article body given as content lines (already dot-unstuffed).
    static func decode(bodyLines: [Data]) throws -> UsenetYEncSegment {
        var joined = Data()
        joined.reserveCapacity(bodyLines.reduce(0) { $0 + $1.count + 2 })
        for (index, line) in bodyLines.enumerated() {
            if index > 0 { joined.append(contentsOf: [0x0D, 0x0A]) }
            joined.append(line)
        }
        return try decode(body: joined, unstuffDots: false)
    }

    /// Decode one article body as it came off the wire (CRLF lines, dot-stuffed,
    /// without the terminating "." line) in a single pass: no per-line objects.
    static func decode(body: Data, unstuffDots: Bool = true) throws -> UsenetYEncSegment {
        var header = UsenetYEncHeader()
        var sawBegin = false
        var declaredPartSize: Int?
        var pcrc: UInt32?
        var fileCRC: UInt32?

        let out: [UInt8] = body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [UInt8] in
            guard let rawBase = raw.baseAddress, raw.count > 0 else { return [] }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            let n = raw.count
            return [UInt8](unsafeUninitializedCapacity: n) { dst, initialized in
                var o = 0
                var i = 0
                var escapePending = false
                lines: while i < n {
                    var end = n
                    if let newline = memchr(rawBase + i, 0x0A, n - i) {
                        end = rawBase.distance(to: UnsafeRawPointer(newline))
                    }
                    var contentEnd = end
                    if contentEnd > i, base[contentEnd - 1] == 0x0D { contentEnd -= 1 }
                    var start = i
                    i = end + 1
                    // RFC 3977: a line starting with "." got one extra "." on the wire.
                    if unstuffDots, start < contentEnd, base[start] == 0x2E { start += 1 }

                    if contentEnd - start >= 2, base[start] == 0x3D, base[start + 1] == 0x79 {
                        let line = Data(bytes: base + start, count: contentEnd - start)
                        if isKeyword(line, "=ybegin") {
                            parseBegin(line, into: &header)
                            sawBegin = true
                            continue lines
                        }
                        if isKeyword(line, "=ypart") {
                            parsePart(line, into: &header)
                            continue lines
                        }
                        if isKeyword(line, "=yend") {
                            let attrs = attributes(of: line, keyword: "=yend")
                            declaredPartSize = attrs["size"].flatMap { Int($0) }
                            pcrc = attrs["pcrc32"].flatMap { UInt32($0, radix: 16) }
                            fileCRC = attrs["crc32"].flatMap { UInt32($0, radix: 16) }
                            break lines
                        }
                    }

                    var j = start
                    while j < contentEnd {
                        let b = base[j]
                        if escapePending {
                            dst[o] = b &- 106
                            o += 1
                            escapePending = false
                        } else if b == escape {
                            escapePending = true
                        } else {
                            dst[o] = b &- 42
                            o += 1
                        }
                        j += 1
                    }
                }
                initialized = o
            }
        }

        guard sawBegin else { throw UsenetYEncError.missingBeginHeader }

        let outData = Data(out)
        var crc = UsenetCRC32()
        crc.update(outData)
        let computed = crc.checksum
        // The whole-file `crc32` only describes THIS part when the article is single-part. For a
        // multipart segment we can only verify against the part-level `pcrc32`; if the poster
        // omitted it, accept the part (checking it against the whole-file CRC would falsely fail
        // every segment and mark it missing).
        let declared = pcrc ?? (header.isMultipart ? nil : fileCRC)
        let matches = declared.map { $0 == computed }

        let fileOffset = (header.partBegin.map { $0 - 1 }) ?? 0

        return UsenetYEncSegment(
            data: outData,
            header: header,
            declaredPartSize: declaredPartSize,
            declaredCRC: declared,
            computedCRC: computed,
            crcMatches: matches,
            fileOffset: max(0, fileOffset)
        )
    }

    // MARK: - Header parsing

    private static func parseBegin(_ line: Data, into header: inout UsenetYEncHeader) {
        let attrs = attributes(of: line, keyword: "=ybegin")
        header.lineLength = attrs["line"].flatMap { Int($0) }
        header.size = attrs["size"].flatMap { Int($0) }
        header.part = attrs["part"].flatMap { Int($0) }
        header.total = attrs["total"].flatMap { Int($0) }
        if let name = attrs["name"], !name.isEmpty { header.name = name }
    }

    private static func parsePart(_ line: Data, into header: inout UsenetYEncHeader) {
        let attrs = attributes(of: line, keyword: "=ypart")
        header.partBegin = attrs["begin"].flatMap { Int($0) }
        header.partEnd = attrs["end"].flatMap { Int($0) }
    }

    /// True if `line` begins with the given keyword (ASCII compare on the raw bytes).
    private static func isKeyword(_ line: Data, _ keyword: String) -> Bool {
        let kw = Array(keyword.utf8)
        guard line.count >= kw.count else { return false }
        for (i, byte) in kw.enumerated() where line[line.index(line.startIndex, offsetBy: i)] != byte {
            return false
        }
        return true
    }

    /// Parse `key=value` attributes from a yEnc header line. `name=` (when present) is always
    /// last and captures the remainder of the line, so it is extracted first.
    private static func attributes(of line: Data, keyword: String) -> [String: String] {
        // Latin-1 never fails and round-trips bytes 1:1 (filenames may be non-UTF8).
        guard var s = String(data: line, encoding: .isoLatin1) else { return [:] }
        if s.hasPrefix(keyword) { s.removeFirst(keyword.count) }

        var result: [String: String] = [:]

        if let r = s.range(of: " name=") {
            let name = String(s[r.upperBound...])
            result["name"] = name
            s = String(s[..<r.lowerBound])
        }

        for token in s.split(separator: " ") where token.contains("=") {
            let parts = token.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                result[String(parts[0])] = String(parts[1])
            }
        }
        return result
    }
}
