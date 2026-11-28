import Foundation
import XCTest
@testable import NuvioTV

#if arch(arm64)

/// An article body as the server sends it: CRLF lines, a leading "." doubled, no "." line.
private enum YEncWire {
    static func body(_ payload: Data, part: Int? = nil, begin: Int? = nil, fileSize: Int? = nil,
                     lineLength: Int = 128, escapeExtra: Bool = false, lineEnd: [UInt8] = [0x0D, 0x0A],
                     withTrailer: Bool = true) -> Data {
        var lines: [[UInt8]] = []
        var head = "=ybegin"
        if let part { head += " part=\(part) total=9" }
        head += " line=\(lineLength) size=\(fileSize ?? payload.count) name=movie.mkv"
        lines.append(Array(head.utf8))
        if let begin {
            lines.append(Array("=ypart begin=\(begin) end=\(begin + payload.count - 1)".utf8))
        }
        // NUL, LF, CR and "=" always; some encoders also escape TAB, space and ".".
        var critical = [Bool](repeating: false, count: 256)
        for byte: UInt8 in escapeExtra ? [0x00, 0x0A, 0x0D, 0x3D, 0x09, 0x20, 0x2E] : [0x00, 0x0A, 0x0D, 0x3D] {
            critical[Int(byte)] = true
        }
        var line: [UInt8] = []
        for byte in payload {
            let encoded = byte &+ 42
            if critical[Int(encoded)] {
                line.append(0x3D)
                line.append(encoded &+ 64)
            } else {
                line.append(encoded)
            }
            if line.count >= lineLength {
                lines.append(line)
                line.removeAll()
            }
        }
        if !line.isEmpty { lines.append(line) }
        if withTrailer {
            let crc = String(format: "%08x", UsenetCRC32.checksum(of: payload))
            let tail = part.map { "=yend size=\(payload.count) part=\($0) pcrc32=\(crc)" }
                ?? "=yend size=\(payload.count) crc32=\(crc)"
            lines.append(Array(tail.utf8))
        }
        var wire = Data()
        for (index, line) in lines.enumerated() {
            if index > 0 { wire.append(contentsOf: lineEnd) }
            if line.first == 0x2E { wire.append(0x2E) }
            wire.append(contentsOf: line)
        }
        return wire
    }

    /// The same bytes every run.
    static func noise(_ count: Int, seed: UInt64) -> Data {
        var state = seed
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            bytes[index] = UInt8(truncatingIfNeeded: state)
        }
        return Data(bytes)
    }
}

/// `UsenetYEnc.decode(body:)` decodes with node-yencode's NEON decoder on ARM64: it must give
/// exactly what the byte-at-a-time decoder gives.
final class UsenetYEncNEONTests: XCTestCase {
    private func assertSameAsPortable(_ body: Data, payload: Data,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let neon = try XCTUnwrap(UsenetYEnc.decodeWithNEON(body), "NEON did not take the body", file: file, line: line)
        let portable = try UsenetYEnc.decodePortable(body: body)
        XCTAssertEqual(neon.data, payload, file: file, line: line)
        XCTAssertEqual(neon.data, portable.data, file: file, line: line)
        XCTAssertEqual(neon.header, portable.header, file: file, line: line)
        XCTAssertEqual(neon.declaredPartSize, portable.declaredPartSize, file: file, line: line)
        XCTAssertEqual(neon.declaredCRC, portable.declaredCRC, file: file, line: line)
        XCTAssertEqual(neon.computedCRC, portable.computedCRC, file: file, line: line)
        XCTAssertEqual(neon.crcMatches, true, file: file, line: line)
        XCTAssertEqual(neon.fileOffset, portable.fileOffset, file: file, line: line)
        XCTAssertEqual(try UsenetYEnc.decode(body: body).data, payload, file: file, line: line)
    }

    func testDecodesWithNEON() {
        XCTAssertTrue(UsenetYEnc.usesNEON)
    }

    func testMatchesPortableOnAFullSizeMultipartArticle() throws {
        let payload = YEncWire.noise(750_000, seed: 0x9E37_79B9_7F4A_7C15)
        let body = YEncWire.body(payload, part: 3, begin: 1_500_001, fileSize: 9_000_000)
        try assertSameAsPortable(body, payload: payload)
        XCTAssertEqual(UsenetYEnc.decodeWithNEON(body)?.fileOffset, 1_500_000)
    }

    func testMatchesPortableOnASinglePartArticle() throws {
        let payload = YEncWire.noise(200_000, seed: 42)
        try assertSameAsPortable(YEncWire.body(payload), payload: payload)
        // Some servers end the body with the =yend line's CRLF.
        try assertSameAsPortable(YEncWire.body(payload) + Data([0x0D, 0x0A]), payload: payload)
    }

    func testMatchesPortableWithDotsAndEscapesAtLineEdges() throws {
        // 4 encodes to "."; 214, 224, 227 and 19 to NUL, LF, CR and "="; 223 and 246 to TAB and
        // space. Short lines put them at line starts (dot stuffing) and line ends.
        let pattern: [UInt8] = [4, 214, 4, 224, 227, 19, 4, 4, 223, 246, 7, 19, 4]
        let payload = Data((0..<60_000).map { pattern[$0 % pattern.count] &+ UInt8($0 / 7_919) })
        for lineLength in [1, 2, 7, 16, 128] {
            try assertSameAsPortable(YEncWire.body(payload, part: 1, begin: 1, lineLength: lineLength), payload: payload)
            try assertSameAsPortable(YEncWire.body(payload, lineLength: lineLength, escapeExtra: true), payload: payload)
        }
    }

    func testMatchesPortableOnTinyAndEmptyParts() throws {
        for count in [0, 1, 2, 3, 31, 64, 65] {
            let payload = YEncWire.noise(count, seed: UInt64(count + 1))
            try assertSameAsPortable(YEncWire.body(payload, part: 2, begin: 101, fileSize: 1_000), payload: payload)
        }
    }

    func testLeavesUnusualBodiesToThePortableDecoder() throws {
        let payload = YEncWire.noise(5_000, seed: 7)
        // LF-only lines and a body without =yend: the byte-at-a-time decoder reads them.
        let lfOnly = YEncWire.body(payload, part: 1, begin: 1, lineEnd: [0x0A])
        XCTAssertNil(UsenetYEnc.decodeWithNEON(lfOnly))
        XCTAssertEqual(try UsenetYEnc.decode(body: lfOnly).data, payload)
        let noTrailer = YEncWire.body(payload, withTrailer: false)
        XCTAssertNil(UsenetYEnc.decodeWithNEON(noTrailer))
        XCTAssertEqual(try UsenetYEnc.decode(body: noTrailer).data, payload)
        XCTAssertNil(try UsenetYEnc.decode(body: noTrailer).declaredPartSize)
        // No =ybegin: the same error as before.
        XCTAssertNil(UsenetYEnc.decodeWithNEON(Data("garbage\r\n=yend size=0".utf8)))
        XCTAssertThrowsError(try UsenetYEnc.decode(body: Data("garbage\r\n=yend size=0".utf8))) { error in
            XCTAssertEqual(error as? UsenetYEncError, .missingBeginHeader)
        }
        XCTAssertThrowsError(try UsenetYEnc.decode(body: Data()))
    }

    func testAnEscapeSplitAcrossLinesStillDecodes() throws {
        // 19 encodes to "=", escaped as "=}". This encoder split the pair across two lines,
        // which NEON reads differently; the CRC fails there, so the portable decoder decides.
        let payload = Data([19])
        let crc = String(format: "%08x", UsenetCRC32.checksum(of: payload))
        let body = Data("=ybegin line=128 size=1 name=a.bin\r\n=\r\n}\r\n=yend size=1 crc32=\(crc)".utf8)
        XCTAssertEqual(UsenetYEnc.decodeWithNEON(body)?.crcMatches, false)
        let segment = try UsenetYEnc.decode(body: body)
        XCTAssertEqual(segment.data, payload)
        XCTAssertEqual(segment.crcMatches, true)
    }
}

#endif
