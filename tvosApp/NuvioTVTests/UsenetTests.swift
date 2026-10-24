import Foundation
import XCTest
@testable import NuvioTV

// MARK: - Helpers

private enum UsenetFixture {
    /// Minimal yEnc encoder, enough to round-trip through `UsenetYEnc.decode`.
    static func yEncLines(_ payload: Data, name: String, part: Int? = nil, total: Int? = nil,
                          begin: Int? = nil, fileSize: Int? = nil, lineLength: Int = 128) -> [Data] {
        var lines: [Data] = []
        var head = "=ybegin"
        if let part { head += " part=\(part)" }
        if let total { head += " total=\(total)" }
        head += " line=\(lineLength) size=\(fileSize ?? payload.count) name=\(name)"
        lines.append(Data(head.utf8))
        if let begin {
            lines.append(Data("=ypart begin=\(begin) end=\(begin + payload.count - 1)".utf8))
        }
        var line = [UInt8]()
        for byte in payload {
            let encoded = byte &+ 42
            if [0x00, 0x0A, 0x0D, 0x3D].contains(encoded) {
                line.append(0x3D)
                line.append(encoded &+ 64)
            } else {
                line.append(encoded)
            }
            if line.count >= lineLength {
                lines.append(Data(line))
                line.removeAll()
            }
        }
        if !line.isEmpty { lines.append(Data(line)) }
        let crc = String(format: "%08x", UsenetCRC32.checksum(of: payload))
        let tail = part != nil ? "=yend size=\(payload.count) part=\(part!) pcrc32=\(crc)" : "=yend size=\(payload.count) crc32=\(crc)"
        lines.append(Data(tail.utf8))
        return lines
    }

    static func nzb(_ files: [(subject: String, segments: [(id: String, bytes: Int, number: Int)])]) -> Data {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?><nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">"#
        xml += #"<head><meta type="title">Test Release</meta><meta type="password">secret</meta></head>"#
        for file in files {
            let subject = file.subject
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            xml += #"<file poster="a@b" date="0" subject="\#(subject)"><groups><group>alt.binaries.test</group></groups><segments>"#
            for segment in file.segments {
                let id = segment.id
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                xml += #"<segment bytes="\#(segment.bytes)" number="\#(segment.number)">\#(id)</segment>"#
            }
            xml += "</segments></file>"
        }
        xml += "</nzb>"
        return Data(xml.utf8)
    }

    static func segments(_ sizes: [Int]) -> [UsenetSegment] {
        sizes.enumerated().map { UsenetSegment(messageID: "p\($0.offset)@test", bytes: $0.element, number: $0.offset + 1) }
    }
}

// MARK: - yEnc / CRC / NNTP framing

final class UsenetCoreTests: XCTestCase {
    func testCRC32KnownValue() {
        XCTAssertEqual(UsenetCRC32.checksum(of: Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testYEncRoundTripSinglePart() throws {
        let payload = Data((0..<1000).map { UInt8($0 % 256) })
        let segment = try UsenetYEnc.decode(bodyLines: UsenetFixture.yEncLines(payload, name: "movie.mkv"))
        XCTAssertEqual(segment.data, payload)
        XCTAssertEqual(segment.header.name, "movie.mkv")
        XCTAssertEqual(segment.header.size, 1000)
        XCTAssertEqual(segment.crcMatches, true)
        XCTAssertEqual(segment.fileOffset, 0)
    }

    func testYEncMultipartOffsetAndPartCRC() throws {
        let payload = Data((0..<500).map { UInt8(($0 * 7) % 256) })
        let lines = UsenetFixture.yEncLines(payload, name: "movie name.mkv", part: 3, total: 10, begin: 1001, fileSize: 5000)
        let segment = try UsenetYEnc.decode(bodyLines: lines)
        XCTAssertEqual(segment.data, payload)
        XCTAssertEqual(segment.fileOffset, 1000)
        XCTAssertEqual(segment.header.part, 3)
        XCTAssertEqual(segment.header.size, 5000)
        XCTAssertEqual(segment.header.name, "movie name.mkv")
        XCTAssertEqual(segment.crcMatches, true)
    }

    func testYEncDetectsCorruption() throws {
        var lines = UsenetFixture.yEncLines(Data(repeating: 0x41, count: 300), name: "a.mkv", part: 1, total: 1, begin: 1)
        var corrupted = [UInt8](lines[2])
        corrupted[0] = corrupted[0] &+ 1
        lines[2] = Data(corrupted)
        XCTAssertEqual(try UsenetYEnc.decode(bodyLines: lines).crcMatches, false)
    }

    func testYEncRequiresBegin() {
        XCTAssertThrowsError(try UsenetYEnc.decode(bodyLines: [Data("garbage".utf8)])) { error in
            XCTAssertEqual(error as? UsenetYEncError, .missingBeginHeader)
        }
    }

    func testRawBodyDecodesLikeLines() throws {
        let payload = Data((0..<5000).map { UInt8(($0 * 31 + 7) % 256) })
        let lines = UsenetFixture.yEncLines(payload, name: "movie.mkv", part: 2, total: 9, begin: 7001, fileSize: 90_000)
        // On the wire: lines starting with "." get a second dot, joined by CRLF.
        var wire = Data()
        for (index, line) in lines.enumerated() {
            if index > 0 { wire.append(contentsOf: [0x0D, 0x0A]) }
            if line.first == 0x2E { wire.append(0x2E) }
            wire.append(line)
        }
        let fromLines = try UsenetYEnc.decode(bodyLines: lines)
        let fromWire = try UsenetYEnc.decode(body: wire)
        XCTAssertEqual(fromWire.data, payload)
        XCTAssertEqual(fromWire.data, fromLines.data)
        XCTAssertEqual(fromWire.fileOffset, 7000)
        XCTAssertEqual(fromWire.crcMatches, true)
        XCTAssertEqual(fromWire.header, fromLines.header)
    }

    func testRawBodyUnstuffsLeadingDots() throws {
        // Bytes 4, 46, 47 encode to ".XY"; the server sends that line as "..XY".
        let payload = Data([4, 46, 47])
        let crc = String(format: "%08x", UsenetCRC32.checksum(of: payload))
        let wire = Data("=ybegin line=128 size=3 name=a.bin\r\n..XY\r\n=yend size=3 crc32=\(crc)".utf8)
        let segment = try UsenetYEnc.decode(body: wire)
        XCTAssertEqual(segment.data, payload)
        XCTAssertEqual(segment.crcMatches, true)
        XCTAssertThrowsError(try UsenetYEnc.decode(body: Data()))
    }

    func testBodyTerminator() {
        let full = Data("line1\r\nline2\r\n.\r\n222 next".utf8)
        let end = UsenetNNTP.bodyTerminator(in: full, from: 0)
        XCTAssertEqual(end?.bodyEnd, 12)
        XCTAssertEqual(end?.restStart, 17)
        XCTAssertEqual(UsenetNNTP.bodyTerminator(in: Data(".\r\n".utf8), from: 0)?.restStart, 3)
        XCTAssertNil(UsenetNNTP.bodyTerminator(in: Data("a\r\n..b\r\n".utf8), from: 0))
        XCTAssertNil(UsenetNNTP.bodyTerminator(in: Data("a\r\n.".utf8), from: 0))
        // Found again when the search resumes a few bytes back.
        XCTAssertEqual(UsenetNNTP.bodyTerminator(in: full, from: 10)?.bodyEnd, 12)
        var framer = UsenetLineFramer()
        _ = framer.append(Data("partial".utf8))
        XCTAssertEqual(framer.takePending(), Data("partial".utf8))
        XCTAssertEqual(framer.pendingCount, 0)
    }

    func testStatusParsing() {
        let status = UsenetNNTPStatus(string: "281 Authentication accepted")
        XCTAssertEqual(status?.code, 281)
        XCTAssertEqual(status?.text, "Authentication accepted")
        XCTAssertTrue(status?.isSuccess == true)
        XCTAssertTrue(UsenetNNTPStatus(string: "381 more")?.isContinue == true)
        XCTAssertTrue(UsenetNNTPStatus(string: "430 No such article")?.isError == true)
        XCTAssertNil(UsenetNNTPStatus(string: "ok"))
    }

    func testDotUnstuffingAndTerminator() {
        XCTAssertEqual(UsenetNNTP.processBodyLine(Data(".".utf8)), .terminator)
        XCTAssertEqual(UsenetNNTP.processBodyLine(Data("..abc".utf8)), .content(Data(".abc".utf8)))
        XCTAssertEqual(UsenetNNTP.processBodyLine(Data("abc".utf8)), .content(Data("abc".utf8)))
        XCTAssertEqual(UsenetNNTP.command("BODY <a@b>"), Data("BODY <a@b>\r\n".utf8))
    }

    func testLineFramerKeepsPartialLines() {
        var framer = UsenetLineFramer()
        XCTAssertEqual(framer.append(Data("222 0 <a@b>\r\nfir".utf8)), [Data("222 0 <a@b>".utf8)])
        XCTAssertEqual(framer.pendingCount, 3)
        XCTAssertEqual(framer.append(Data("st\r\n.\r\n".utf8)), [Data("first".utf8), Data(".".utf8)])
        XCTAssertEqual(framer.pendingCount, 0)
    }

    func testTransientErrors() {
        XCTAssertTrue(UsenetNNTPError.timeout.isTransient)
        XCTAssertTrue(UsenetNNTPError.connectionClosed.isTransient)
        XCTAssertFalse(UsenetNNTPError.articleUnavailable(code: 430).isTransient)
        XCTAssertFalse(UsenetNNTPError.authenticationFailed(481).isTransient)
    }
}

// MARK: - NZB parsing and file choice

final class UsenetNZBTests: XCTestCase {
    private func sampleNZB() throws -> UsenetNZB {
        try UsenetNZB.parse(UsenetFixture.nzb([
            (#"[1/4] - "Show.S01E01.1080p.mkv" yEnc (1/3)"#, [("<a3@x>", 300, 3), ("a1@x", 300, 1), ("a2@x", 300, 2), ("dup@x", 300, 2)]),
            (#"[2/4] - "Show.S01E01.1080p.par2" yEnc (1/1)"#, [("p@x", 10, 1)]),
            (#"[3/4] - "Show.S01E01.sample.mkv" yEnc (1/1)"#, [("s@x", 50, 1)]),
            (#"[4/4] - "Show.S01E01.nfo" yEnc (1/1)"#, [("n@x", 5, 1)]),
        ]))
    }

    func testParseOrdersAndDedupesSegments() throws {
        let nzb = try sampleNZB()
        XCTAssertEqual(nzb.title, "Test Release")
        XCTAssertEqual(nzb.password, "secret")
        XCTAssertEqual(nzb.files.count, 4)
        let main = nzb.files[0]
        XCTAssertEqual(main.name, "Show.S01E01.1080p.mkv")
        XCTAssertEqual(main.segments.map(\.number), [1, 2, 3])
        XCTAssertEqual(main.segments.map(\.messageID), ["a1@x", "a2@x", "a3@x"])
        XCTAssertEqual(main.encodedBytes, 900)
    }

    private func entries(_ nzb: UsenetNZB) -> [UsenetPlayableEntry] {
        let names = nzb.files.map(\.name)
        let roles = names.map(UsenetReleaseResolver.role(ofName:))
        return UsenetReleaseResolver.plainAndSplitEntries(files: nzb.files, names: names, roles: roles)
            .sorted { $0.order < $1.order }
    }

    func testPicksLargestVideoByDefault() throws {
        let chosen = UsenetReleaseResolver.choose(entries(try sampleNZB()), mustInclude: nil, fileIdx: nil)
        XCTAssertEqual(chosen?.name, "Show.S01E01.1080p.mkv")
    }

    func testFileMustIncludeRegexWins() throws {
        let chosen = UsenetReleaseResolver.choose(entries(try sampleNZB()), mustInclude: "(?:sample)|(?:trailer)", fileIdx: nil)
        XCTAssertEqual(chosen?.name, "Show.S01E01.sample.mkv")
    }

    func testFileIdxAmongVideos() throws {
        let list = entries(try sampleNZB())
        XCTAssertEqual(UsenetReleaseResolver.choose(list, mustInclude: nil, fileIdx: 1)?.name, "Show.S01E01.sample.mkv")
        XCTAssertEqual(UsenetReleaseResolver.choose(list, mustInclude: nil, fileIdx: 9)?.name, "Show.S01E01.1080p.mkv")
    }

    func testPackWithoutTheEpisodeIsNotPlayed() throws {
        let pack = entries(try UsenetNZB.parse(UsenetFixture.nzb([
            (#""Show.S01E01.mkv" yEnc (1/1)"#, [("e1@x", 500, 1)]),
            (#""Show.S01E02.mkv" yEnc (1/1)"#, [("e2@x", 520, 1)]),
            (#""Show.S01E03.mkv" yEnc (1/1)"#, [("e3@x", 510, 1)]),
        ])))
        XCTAssertEqual(UsenetReleaseResolver.choose(pack, mustInclude: "S01E02", fileIdx: nil)?.name, "Show.S01E02.mkv")
        XCTAssertNil(UsenetReleaseResolver.choose(pack, mustInclude: "S01E09", fileIdx: nil))
        // One episode plus its sample is a single release: still played.
        XCTAssertEqual(UsenetReleaseResolver.choose(entries(try sampleNZB()), mustInclude: "S01E09", fileIdx: nil)?.name,
                       "Show.S01E01.1080p.mkv")
        // A single file is played even when the pattern doesn't fit it.
        let single = [UsenetPlayableEntry(name: "Movie.mp4", source: .plain(0), size: 10, order: 0)]
        XCTAssertEqual(UsenetReleaseResolver.choose(single, mustInclude: "\\.mkv$", fileIdx: nil)?.name, "Movie.mp4")
    }

    func testJavaScriptStylePatterns() {
        let normalized = UsenetReleaseResolver.normalizedPattern
        XCTAssertEqual(normalized("/E05|- 05/i"), "E05|- 05")
        XCTAssertEqual(normalized(" /.mkv$|.mp4$/i "), ".mkv$|.mp4$")
        XCTAssertEqual(normalized("/S01E05/"), "S01E05")
        XCTAssertEqual(normalized("S01E05"), "S01E05")
        XCTAssertEqual(normalized("/path/to"), "/path/to")
        XCTAssertEqual(normalized("//"), "//")
    }

    func testRolesFromNames() {
        let role = UsenetReleaseResolver.role(ofName:)
        XCTAssertEqual(role("Show.S01E01.mkv"), .video)
        XCTAssertEqual(role("Movie.part01.rar"), .rar)
        XCTAssertEqual(role("Movie.r07"), .rar)
        XCTAssertEqual(role("Movie.vol03+04.par2"), .par2)
        XCTAssertEqual(role("Movie.nfo"), .sidecar)
        XCTAssertEqual(role("Movie.7z"), .unsupportedArchive)
        XCTAssertEqual(role("Movie.mkv.001"), .split)
        XCTAssertEqual(role("a8f3e1c9b2d47e6f"), .unknown)
        XCTAssertEqual(role("Show.S01E01.1080p"), .unknown)
    }

    func testRarVolumesGroupIntoOrderedSets() {
        let names = ["Movie.part02.rar", "Movie.part01.rar", "Movie.par2", "Other.rar", "Other.r01", "Other.r00"]
        let roles = names.map(UsenetReleaseResolver.role(ofName:))
        let sets = UsenetReleaseResolver.rarSets(names: names, roles: roles, obfuscated: [])
        XCTAssertEqual(sets, [[1, 0], [3, 5, 4]])
        XCTAssertEqual(UsenetReleaseResolver.rarVolumeKey("Movie.part10.rar")?.number, 10)
        XCTAssertEqual(UsenetReleaseResolver.rarVolumeKey("Other.r00")?.number, 1)
        XCTAssertEqual(UsenetReleaseResolver.rarVolumeKey("Other.rar")?.number, 0)
    }

    func testSplitPartsBecomeOneEntry() throws {
        let nzb = try UsenetNZB.parse(UsenetFixture.nzb([
            (#""Movie.mkv.002" yEnc (1/1)"#, [("b@x", 400, 1)]),
            (#""Movie.mkv.001" yEnc (1/1)"#, [("a@x", 500, 1)]),
        ]))
        let list = entries(nzb)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.name, "Movie.mkv")
        XCTAssertEqual(list.first?.source, .split([1, 0]))
        XCTAssertEqual(list.first?.size, 900)
    }

    func testGzipNZB() throws {
        let gz = Data(base64Encoded: "H4sIAAAAAAAC/z1OSw7CIBS8CmFhdMMD3SmlLuoNvIA0T0ULaKHF9vQ+o3E1n8xkRtcv37ER++RiqLgSktdGh9ky8kOq+DXnxxaglCICltm6INrooTk2sJZyAxTlRp9dhywN9oZtrvjiOcS883F0KPx9/Eo2HULLlgrUigoJLx5DTn/G7JSR9pSUnIXBW+xJcHPaWw2/jPkz6sFnk4AOmDc90bFHxgAAAA==")!
        XCTAssertTrue(UsenetGzip.isGzip(gz))
        let nzb = try UsenetNZB.parse(gz)
        XCTAssertEqual(nzb.files.first?.name, "movie.mkv")
        XCTAssertEqual(nzb.files.first?.segments.first?.messageID, "a@b")
    }

    func testGarbageIsUnreadable() {
        XCTAssertThrowsError(try UsenetNZB.parse(Data("<html><body>login</body".utf8)))
    }
}

// MARK: - RAR, PAR2, sniffing

private enum FormatFixture {
    static func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    static func le32(_ v: Int) -> [UInt8] {
        let low: [UInt8] = le16(v & 0xFFFF)
        return low + le16((v >> 16) & 0xFFFF)
    }
    static func le64(_ v: Int) -> [UInt8] {
        let low: [UInt8] = le32(v & 0xFFFF_FFFF)
        return low + le32(v >> 32)
    }

    static func vint(_ value: Int) -> [UInt8] {
        var v = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v > 0 { byte |= 0x80 }
            out.append(byte)
        } while v > 0
        return out
    }

    /// A RAR 4 volume holding `dataBytes` bytes of one entry.
    static func rar4(name: String, packed: Int, unpacked: Int, method: UInt8 = 0x30, fileFlags: Int = 0,
                     firstVolume: Bool, dataBytes: Int) -> (data: Data, dataOffset: Int) {
        let nameBytes = Array(name.utf8)
        var b: [UInt8] = UsenetRar.rar4Signature
        // Main header: CRC, type, flags, size, 6 reserved bytes.
        b.append(contentsOf: [0, 0, 0x73])
        b.append(contentsOf: le16(0x0001 | (firstVolume ? 0x0100 : 0)))
        b.append(contentsOf: le16(13))
        b.append(contentsOf: [UInt8](repeating: 0, count: 6))
        // File header.
        b.append(contentsOf: [0, 0, 0x74])
        b.append(contentsOf: le16(0x8000 | fileFlags))
        b.append(contentsOf: le16(32 + nameBytes.count))
        b.append(contentsOf: le32(packed))
        b.append(contentsOf: le32(unpacked))
        b.append(2)                          // host OS
        b.append(contentsOf: le32(0))        // CRC
        b.append(contentsOf: le32(0))        // time
        b.append(29)                         // version
        b.append(method)
        b.append(contentsOf: le16(nameBytes.count))
        b.append(contentsOf: le32(0x20))     // attributes
        b.append(contentsOf: nameBytes)
        let offset = b.count
        b.append(contentsOf: [UInt8](repeating: 0xAB, count: dataBytes))
        return (Data(b), offset)
    }

    /// A RAR 5 volume (number `volume`) holding `dataBytes` bytes of one entry.
    static func rar5(name: String, unpacked: Int, volume: Int, continuesFromPrevious: Bool, continuesInNext: Bool,
                     method: Int = 0, encrypted: Bool = false, dataBytes: Int) -> (data: Data, dataOffset: Int) {
        var b: [UInt8] = UsenetRar.rar5Signature

        var main: [UInt8] = vint(1)
        main.append(contentsOf: vint(0))
        main.append(contentsOf: vint(0x0001 | (volume > 0 ? 0x0002 : 0)))
        if volume > 0 { main.append(contentsOf: vint(volume)) }
        b.append(contentsOf: [0, 0, 0, 0])
        b.append(contentsOf: vint(main.count))
        b.append(contentsOf: main)

        var flags = 0x0002
        if continuesFromPrevious { flags |= 0x0008 }
        if continuesInNext { flags |= 0x0010 }
        var extra: [UInt8] = []
        if encrypted {
            extra.append(contentsOf: vint(1))
            extra.append(contentsOf: vint(0x01))
            flags |= 0x0001
        }
        let nameBytes = Array(name.utf8)
        var file: [UInt8] = vint(2)
        file.append(contentsOf: vint(flags))
        if !extra.isEmpty { file.append(contentsOf: vint(extra.count)) }
        file.append(contentsOf: vint(dataBytes))
        file.append(contentsOf: vint(0))           // file flags
        file.append(contentsOf: vint(unpacked))
        file.append(contentsOf: vint(0))           // attributes
        file.append(contentsOf: vint(method << 7)) // compression
        file.append(contentsOf: vint(0))           // host OS
        file.append(contentsOf: vint(nameBytes.count))
        file.append(contentsOf: nameBytes)
        file.append(contentsOf: extra)
        b.append(contentsOf: [0, 0, 0, 0])
        b.append(contentsOf: vint(file.count))
        b.append(contentsOf: file)
        let offset = b.count
        b.append(contentsOf: [UInt8](repeating: 0xCD, count: dataBytes))
        return (Data(b), offset)
    }

    /// One RAR 4 file block (header + stored data) to append after a volume's headers.
    static func rar4FileBlock(name: String, packed: Int, unpacked: Int, fileFlags: Int = 0) -> [UInt8] {
        let nameBytes = Array(name.utf8)
        var b: [UInt8] = [0, 0, 0x74]
        b.append(contentsOf: le16(0x8000 | fileFlags))
        b.append(contentsOf: le16(32 + nameBytes.count))
        b.append(contentsOf: le32(packed))
        b.append(contentsOf: le32(unpacked))
        b.append(2)
        b.append(contentsOf: le32(0))
        b.append(contentsOf: le32(0))
        b.append(29)
        b.append(0x30)
        b.append(contentsOf: le16(nameBytes.count))
        b.append(contentsOf: le32(0x20))
        b.append(contentsOf: nameBytes)
        b.append(contentsOf: [UInt8](repeating: 0xEE, count: packed))
        return b
    }

    static func par2FileDescription(name: String, head: Data) -> Data {
        var body: [UInt8] = [UInt8](repeating: 1, count: 16)    // file ID
        body.append(contentsOf: [UInt8](repeating: 2, count: 16)) // full MD5
        body.append(contentsOf: [UInt8](UsenetPar2.hash16k(head)))
        body.append(contentsOf: le64(head.count))
        var nameBytes = Array(name.utf8)
        while nameBytes.count % 4 != 0 { nameBytes.append(0) }
        body.append(contentsOf: nameBytes)
        var packet: [UInt8] = UsenetPar2.magic
        packet.append(contentsOf: le64(64 + body.count))
        packet.append(contentsOf: [UInt8](repeating: 0, count: 32)) // packet MD5 + set ID
        packet.append(contentsOf: UsenetPar2.fileDescriptionType)
        packet.append(contentsOf: body)
        return Data(packet)
    }
}

final class UsenetFormatTests: XCTestCase {
    func testRar4StoredVolumesMapToExtents() throws {
        let first = FormatFixture.rar4(name: "Movie.mkv", packed: 100, unpacked: 180, fileFlags: 0x02, firstVolume: true, dataBytes: 100)
        let second = FormatFixture.rar4(name: "Movie.mkv", packed: 80, unpacked: 180, fileFlags: 0x01, firstVolume: false, dataBytes: 80)
        let v1 = try XCTUnwrap(UsenetRar.parseVolume(first.data))
        let v2 = try XCTUnwrap(UsenetRar.parseVolume(second.data))
        XCTAssertEqual(v1.format, .rar4)
        XCTAssertEqual(v1.isFirstVolume, true)
        XCTAssertEqual(v1.entries.first?.name, "Movie.mkv")
        XCTAssertEqual(v1.entries.first?.dataOffset, Int64(first.dataOffset))
        XCTAssertEqual(v1.entries.first?.isStored, true)
        XCTAssertEqual(v2.entries.first?.continuesFromPrevious, true)

        let extents = try UsenetReleaseResolver.rarExtents([v1, v2], innerName: "Movie.mkv")
        XCTAssertEqual(extents, [
            UsenetExtent(volume: 0, offset: Int64(first.dataOffset), length: 100),
            UsenetExtent(volume: 1, offset: Int64(second.dataOffset), length: 80),
        ])
    }

    func testRar4CompressedEncryptedAndIncomplete() throws {
        let compressed = try XCTUnwrap(UsenetRar.parseVolume(
            FormatFixture.rar4(name: "Movie.mkv", packed: 50, unpacked: 90, method: 0x33, firstVolume: true, dataBytes: 50).data))
        XCTAssertThrowsError(try UsenetReleaseResolver.rarExtents([compressed], innerName: "Movie.mkv")) {
            XCTAssertEqual($0 as? UsenetError, .archiveCompressed("Movie.mkv"))
        }
        let locked = try XCTUnwrap(UsenetRar.parseVolume(
            FormatFixture.rar4(name: "Movie.mkv", packed: 50, unpacked: 50, fileFlags: 0x04, firstVolume: true, dataBytes: 50).data))
        XCTAssertThrowsError(try UsenetReleaseResolver.rarExtents([locked], innerName: "Movie.mkv")) {
            XCTAssertEqual($0 as? UsenetError, .archiveEncrypted)
        }
        let partial = try XCTUnwrap(UsenetRar.parseVolume(
            FormatFixture.rar4(name: "Movie.mkv", packed: 100, unpacked: 180, fileFlags: 0x02, firstVolume: true, dataBytes: 100).data))
        XCTAssertThrowsError(try UsenetReleaseResolver.rarExtents([partial], innerName: "Movie.mkv")) {
            XCTAssertEqual($0 as? UsenetError, .releaseIncomplete)
        }
    }

    func testRar5VolumesNumbersAndExtents() throws {
        let first = FormatFixture.rar5(name: "Show/E01.mkv", unpacked: 300, volume: 0, continuesFromPrevious: false, continuesInNext: true, dataBytes: 200)
        let second = FormatFixture.rar5(name: "Show/E01.mkv", unpacked: 300, volume: 1, continuesFromPrevious: true, continuesInNext: false, dataBytes: 100)
        let v1 = try XCTUnwrap(UsenetRar.parseVolume(first.data))
        let v2 = try XCTUnwrap(UsenetRar.parseVolume(second.data))
        XCTAssertEqual(v1.format, .rar5)
        XCTAssertEqual(v1.volumeNumber, 0)
        XCTAssertEqual(v2.volumeNumber, 1)
        XCTAssertEqual(v1.entries.first?.packedSize, 200)
        XCTAssertEqual(v1.entries.first?.unpackedSize, 300)
        XCTAssertEqual(v1.entries.first?.dataOffset, Int64(first.dataOffset))

        // Obfuscated volumes arrive in any order; RAR 5 numbers put them right.
        let ordered = UsenetReleaseResolver.orderObfuscated([(index: 7, head: "b", volume: v2), (index: 3, head: "a", volume: v1)])
        XCTAssertEqual(ordered.map { $0.index }, [3, 7])

        let extents = try UsenetReleaseResolver.rarExtents([v1, v2], innerName: "Show/E01.mkv")
        XCTAssertEqual(extents.map(\.length), [200, 100])
        XCTAssertEqual(extents.map(\.offset), [Int64(first.dataOffset), Int64(second.dataOffset)])
    }

    func testMultiFileRarHeadersAcrossTheBuffer() throws {
        // Volume: E01 (100 bytes) then E02's header and data.
        var bytes = [UInt8](FormatFixture.rar4(name: "E01.mkv", packed: 100, unpacked: 100, firstVolume: true, dataBytes: 100).data)
        let secondHeaderAt = bytes.count
        bytes += FormatFixture.rar4FileBlock(name: "E02.mkv", packed: 60, unpacked: 60)

        let whole = try XCTUnwrap(UsenetRar.parseVolume(Data(bytes)))
        XCTAssertEqual(whole.entries.map(\.name), ["E01.mkv", "E02.mkv"])

        // Only the first article's worth: stops at E01's data, points at E02's header.
        var partial = try XCTUnwrap(UsenetRar.parseVolume(Data(bytes.prefix(secondHeaderAt - 40))))
        XCTAssertEqual(partial.entries.map(\.name), ["E01.mkv"])
        XCTAssertEqual(partial.pendingHeaderOffset, Int64(secondHeaderAt))
        UsenetRar.continueVolume(&partial, bytes: Data(bytes[secondHeaderAt...]), at: Int64(secondHeaderAt))
        XCTAssertEqual(partial.entries.map(\.name), ["E01.mkv", "E02.mkv"])
        XCTAssertEqual(partial.entries.last?.dataOffset, whole.entries.last?.dataOffset)
    }

    func testRarExtentsForAFileStartingInALaterVolume() throws {
        // Volume 0: E01 whole, then E02's first 30 bytes; volume 1: the other 50.
        var first = [UInt8](FormatFixture.rar4(name: "E01.mkv", packed: 100, unpacked: 100, firstVolume: true, dataBytes: 100).data)
        first += FormatFixture.rar4FileBlock(name: "E02.mkv", packed: 30, unpacked: 80, fileFlags: 0x02)
        let second = FormatFixture.rar4(name: "E02.mkv", packed: 50, unpacked: 80, fileFlags: 0x01, firstVolume: false, dataBytes: 50)
        // Volume 2: E03 on its own.
        let third = FormatFixture.rar4(name: "E03.mkv", packed: 70, unpacked: 70, firstVolume: false, dataBytes: 70)
        let volumes = try [Data(first), second.data, third.data].map { try XCTUnwrap(UsenetRar.parseVolume($0)) }

        let e02 = try UsenetReleaseResolver.rarExtents(volumes, innerName: "E02.mkv")
        XCTAssertEqual(e02.map(\.volume), [0, 1])
        XCTAssertEqual(e02.map(\.length), [30, 50])
        XCTAssertEqual(e02.last?.offset, Int64(second.dataOffset))

        let e03 = try UsenetReleaseResolver.rarExtents(volumes, innerName: "E03.mkv")
        XCTAssertEqual(e03, [UsenetExtent(volume: 2, offset: Int64(third.dataOffset), length: 70)])
        XCTAssertThrowsError(try UsenetReleaseResolver.rarExtents(volumes, innerName: "E09.mkv"))
    }

    func testMultiFileSetHeuristic() {
        XCTAssertFalse(UsenetReleaseResolver.isMultiFileSet(listedBytes: 900, encodedSetBytes: 1000))
        XCTAssertTrue(UsenetReleaseResolver.isMultiFileSet(listedBytes: 300, encodedSetBytes: 1000))
        XCTAssertFalse(UsenetReleaseResolver.isMultiFileSet(listedBytes: 0, encodedSetBytes: 0))
    }

    func testRar5CompressedAndEncrypted() throws {
        let compressed = try XCTUnwrap(UsenetRar.parseVolume(FormatFixture.rar5(
            name: "a.mkv", unpacked: 10, volume: 0, continuesFromPrevious: false, continuesInNext: false, method: 3, dataBytes: 10).data))
        XCTAssertEqual(compressed.entries.first?.isStored, false)
        let locked = try XCTUnwrap(UsenetRar.parseVolume(FormatFixture.rar5(
            name: "a.mkv", unpacked: 10, volume: 0, continuesFromPrevious: false, continuesInNext: false, encrypted: true, dataBytes: 10).data))
        XCTAssertEqual(locked.entries.first?.isEncrypted, true)
        XCTAssertEqual(locked.entries.first?.name, "a.mkv")
    }

    func testPar2RestoresNames() {
        let head = Data((0..<40_000).map { UInt8($0 % 251) })
        var data = Data("junk before the first packet".utf8)
        data.append(FormatFixture.par2FileDescription(name: "Movie.2024.1080p.mkv", head: head))
        data.append(FormatFixture.par2FileDescription(name: "Movie.2024.1080p.nfo", head: Data("nfo".utf8)))
        let descriptions = UsenetPar2.fileDescriptions(in: data)
        XCTAssertEqual(descriptions.count, 2)
        XCTAssertEqual(descriptions.first?.name, "Movie.2024.1080p.mkv")
        XCTAssertEqual(descriptions.first?.length, 40_000)
        // Only the first 16 KiB count.
        XCTAssertEqual(descriptions.first?.hash16k, UsenetPar2.hash16k(head.prefix(20_000)))
        XCTAssertTrue(UsenetPar2.isPar2(FormatFixture.par2FileDescription(name: "x", head: head)))
    }

    func testSniffing() {
        XCTAssertEqual(UsenetSniff.kind(of: Data([0x1A, 0x45, 0xDF, 0xA3, 0x01])), .video("mkv"))
        var mp4 = Data([0, 0, 0, 0x20])
        mp4.append(Data("ftypisom".utf8))
        XCTAssertEqual(UsenetSniff.kind(of: mp4), .video("mp4"))
        XCTAssertEqual(UsenetSniff.kind(of: Data(UsenetRar.rar5Signature) + Data([1, 2, 3])), .rar)
        XCTAssertEqual(UsenetSniff.kind(of: Data(UsenetRar.rar4Signature) + Data([1, 2, 3])), .rar)
        XCTAssertEqual(UsenetSniff.kind(of: Data(UsenetPar2.magic) + Data([0, 0])), .par2)
        XCTAssertEqual(UsenetSniff.kind(of: Data([0x50, 0x4B, 0x03, 0x04, 0])), .zip)
        var ts = Data(count: 600)
        ts[0] = 0x47; ts[188] = 0x47; ts[376] = 0x47
        XCTAssertEqual(UsenetSniff.kind(of: ts), .video("ts"))
        XCTAssertEqual(UsenetSniff.kind(of: Data("hello world".utf8)), .unknown)
    }
}

// MARK: - Sources, health check, stats

final class UsenetSourceTests: XCTestCase {
    func testLocateAcrossExtents() {
        let extents = [UsenetExtent(volume: 0, offset: 10, length: 100), UsenetExtent(volume: 1, offset: 5, length: 50)]
        let starts: [Int64] = [0, 100]
        XCTAssertEqual(UsenetStreamSource.locate(0, extents: extents, starts: starts)?.volumeOffset, 10)
        XCTAssertEqual(UsenetStreamSource.locate(99, extents: extents, starts: starts)?.volumeOffset, 109)
        XCTAssertEqual(UsenetStreamSource.locate(100, extents: extents, starts: starts)?.extent, 1)
        XCTAssertEqual(UsenetStreamSource.locate(100, extents: extents, starts: starts)?.volumeOffset, 5)
        XCTAssertEqual(UsenetStreamSource.locate(149, extents: extents, starts: starts)?.volumeOffset, 54)
        XCTAssertNil(UsenetStreamSource.locate(150, extents: extents, starts: starts))
        XCTAssertNil(UsenetStreamSource.locate(-1, extents: extents, starts: starts))
    }

    private func source(segmentCounts: [Int]) throws -> UsenetStreamSource {
        let head = try UsenetYEnc.decode(bodyLines: UsenetFixture.yEncLines(Data(count: 10), name: "a.mkv"))
        let volumes = segmentCounts.enumerated().map { volume, count in
            UsenetFile(subject: "v\(volume)", name: "v\(volume)", segments: (0..<count).map {
                UsenetSegment(messageID: "v\(volume)-\($0)@x", bytes: 100, number: $0 + 1)
            })
        }
        return UsenetStreamSource(
            name: "a.mkv", kind: .rar, volumes: volumes,
            extents: volumes.indices.map { UsenetExtent(volume: $0, offset: 0, length: 10) },
            firstArticles: volumes.map { _ in head }
        )
    }

    func testHealthSamplesSkipFirstArticlesAndIncludeTail() throws {
        let small = UsenetHealthCheck.samples(for: try source(segmentCounts: [5, 5]))
        XCTAssertEqual(small.count, 8)
        XCTAssertFalse(small.contains("v0-0@x"))
        XCTAssertFalse(small.contains("v1-0@x"))
        XCTAssertEqual(small.last, "v1-4@x")

        let large = UsenetHealthCheck.samples(for: try source(segmentCounts: [30]))
        XCTAssertEqual(large.count, UsenetHealthCheck.sampleCount)
        XCTAssertEqual(large.first, "v0-1@x")
        XCTAssertEqual(large.last, "v0-29@x")
        XCTAssertEqual(Set(large).count, large.count)
        XCTAssertEqual(try source(segmentCounts: [5, 5]).totalSize, 20)
    }

    func testHealthVerdict() {
        XCTAssertTrue(UsenetHealthCheck.isPlayable(.init(checked: 12, missing: 0, tailMissing: false)))
        XCTAssertTrue(UsenetHealthCheck.isPlayable(.init(checked: 12, missing: 1, tailMissing: false)))
        XCTAssertFalse(UsenetHealthCheck.isPlayable(.init(checked: 12, missing: 2, tailMissing: false)))
        XCTAssertFalse(UsenetHealthCheck.isPlayable(.init(checked: 12, missing: 1, tailMissing: true)))
    }

    func testReleaseProblemsAllowFallback() {
        XCTAssertTrue(UsenetEngineManager.isReleaseProblem(UsenetError.releaseIncomplete))
        XCTAssertTrue(UsenetEngineManager.isReleaseProblem(UsenetError.archiveCompressed("a.mkv")))
        XCTAssertTrue(UsenetEngineManager.isReleaseProblem(URLError(.timedOut)))
        XCTAssertFalse(UsenetEngineManager.isReleaseProblem(UsenetError.noServers))
        XCTAssertFalse(UsenetEngineManager.isReleaseProblem(UsenetError.serverRejected("no")))
        XCTAssertFalse(UsenetEngineManager.isReleaseProblem(CancellationError()))
    }

    func testDamageNeedsARunOrManyHoles() {
        XCTAssertFalse(UsenetStreamSession.isDamaged(consecutiveMissing: 2, recent: [true, true]))
        XCTAssertTrue(UsenetStreamSession.isDamaged(consecutiveMissing: 3, recent: [true, true, true]))
        let scattered = (0..<50).map { $0 % 6 == 0 }   // 9 holes, never two in a row
        XCTAssertTrue(UsenetStreamSession.isDamaged(consecutiveMissing: 0, recent: scattered))
        let sparse = (0..<50).map { $0 % 10 == 0 }     // 5 holes
        XCTAssertFalse(UsenetStreamSession.isDamaged(consecutiveMissing: 0, recent: sparse))
    }

    func testFailedPlaybackURLsExcludeTheirAddonStream() {
        let spec = UsenetStreamSpec(nzbURL: URL(string: "https://i.example/get?id=\(UUID().uuidString)")!)
        let source = spec.url.absoluteString
        let playback = "http://127.0.0.1:50123/usenet/\(UUID().uuidString)/video.mkv"
        XCTAssertFalse(UsenetEngineManager.isExcluded(sourceURL: source, excludedPlaybackURLs: [playback]))
        UsenetEngineManager.remember(source: source, playback: playback)
        XCTAssertTrue(UsenetEngineManager.isExcluded(sourceURL: source, excludedPlaybackURLs: [playback]))
        XCTAssertTrue(UsenetEngineManager.isExcluded(sourceURL: source, excludedPlaybackURLs: [source]))
        XCTAssertFalse(UsenetEngineManager.isExcluded(sourceURL: "https://cdn.example/a.mkv", excludedPlaybackURLs: [playback]))
        XCTAssertNil(UsenetEngineManager.canonicalSource("https://cdn.example/a.mkv"))
    }

    func testTokenBucketPacesToTheCap() {
        let start = ContinuousClock.Instant.now
        var bucket = UsenetTokenBucket(megabitsPerSecond: 8, now: start) // 1 MB/s, 1 MiB burst
        XCTAssertEqual(bucket.take(1_048_576, now: start), .zero)
        XCTAssertEqual(bucket.take(1_000_000, now: start), .seconds(1))
        // Requests made together queue up behind each other.
        XCTAssertEqual(bucket.take(1_000_000, now: start), .seconds(2))
        // Time refills the bucket.
        var later = UsenetTokenBucket(megabitsPerSecond: 8, now: start)
        _ = later.take(1_048_576, now: start)
        XCTAssertEqual(later.take(500_000, now: start + .seconds(1)), .zero)
        XCTAssertEqual(later.take(1_000_000, now: start + .seconds(1)), .seconds(0.5))
    }

    func testTokenBucketRefundsCancelledReadAhead() {
        let start = ContinuousClock.Instant.now
        var bucket = UsenetTokenBucket(megabitsPerSecond: 8, now: start) // 1 MB/s, 1 MiB burst
        _ = bucket.take(1_048_576, now: start)
        XCTAssertEqual(bucket.take(1_000_000, now: start), .seconds(1))
        // The read-ahead was cancelled by a seek: the next request doesn't queue behind it.
        bucket.refund(1_000_000)
        XCTAssertEqual(bucket.take(1_000_000, now: start), .seconds(1))
        // A refund never fills the bucket beyond its burst.
        bucket.refund(10_000_000)
        XCTAssertEqual(bucket.tokens, bucket.capacity)
    }

    func testWaitQueuePutsPlaybackFirst() {
        var queue = UsenetWaitQueue<Int>()
        XCTAssertTrue(queue.isEmpty)
        queue.append(1, urgent: false)
        queue.append(2, urgent: true)
        queue.append(3, urgent: false)
        queue.append(4, urgent: true)
        XCTAssertEqual(queue.popFirst(), 2)
        XCTAssertEqual(queue.popFirst(), 4)
        XCTAssertEqual(queue.popFirst(), 1)
        queue.append(5, urgent: true)
        XCTAssertEqual(queue.removeAll(), [5, 3])
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.popFirst())
    }

    func testReadAheadNextToThePlayheadIsNotPaced() {
        XCTAssertEqual(UsenetStreamSession.priority(of: 11, playhead: 10), .next)
        XCTAssertEqual(UsenetStreamSession.priority(of: 10 + UsenetStreamSession.nextArticles, playhead: 10), .next)
        XCTAssertEqual(UsenetStreamSession.priority(of: 11 + UsenetStreamSession.nextArticles, playhead: 10), .readAhead)
        XCTAssertEqual(UsenetStreamSession.priority(of: 10, playhead: 10), .readAhead)
        XCTAssertEqual(UsenetStreamSession.priority(of: 5, playhead: 10), .readAhead)
    }

    func testSpeedLimitSetting() {
        let store = UserDefaults(suiteName: "usenet-speed-\(UUID().uuidString)")!
        XCTAssertEqual(UsenetSettings.speedLimitMbps(store: store), 0)
        UsenetSettings.setSpeedLimitMbps(50, store: store)
        XCTAssertEqual(UsenetSettings.speedLimitMbps(store: store), 50)
        UsenetSettings.setSpeedLimitMbps(37, store: store)
        XCTAssertEqual(UsenetSettings.speedLimitMbps(store: store), 0)
        var stats = UsenetStreamStats()
        stats.speedLimitMbps = 50
        XCTAssertTrue(stats.connectionLine.contains("max 50 Mbit/s"))
    }

    func testStatsSummary() {
        var stats = UsenetStreamStats()
        stats.server = "news.example.com"
        stats.serverCount = 2
        stats.busyConnections = 3
        stats.totalConnections = 10
        stats.missingArticles = 2
        stats.cacheHitRate = 0.9
        let summary = stats.summary
        XCTAssertTrue(summary.contains("news.example.com +1"))
        XCTAssertTrue(summary.contains("3/10 conn"))
        XCTAssertTrue(summary.contains("hit 90%"))
        XCTAssertTrue(summary.contains("missing 2"))
        XCTAssertFalse(summary.contains("backup"))
    }

    func testNZBCacheRoundTrip() throws {
        let url = URL(string: "https://indexer.example/get/\(UUID().uuidString).nzb")!
        XCTAssertNil(UsenetNZBCache.cached(url))
        UsenetNZBCache.store(Data("nzb".utf8), for: url)
        XCTAssertEqual(UsenetNZBCache.cached(url), Data("nzb".utf8))
        UsenetNZBCache.remove(url)
        XCTAssertNil(UsenetNZBCache.cached(url))
    }
}

// MARK: - Byte layout

final class UsenetLayoutTests: XCTestCase {
    func testRegularLayoutIsArithmetic() {
        let layout = UsenetFileLayout(totalSize: 1000, firstPart: 0..<400, segments: UsenetFixture.segments([410, 410, 210]))
        XCTAssertTrue(layout.isRegular)
        XCTAssertEqual(layout.range(of: 1), 400..<800)
        XCTAssertEqual(layout.range(of: 2), 800..<1000)
        XCTAssertNil(layout.range(of: 3))
        XCTAssertEqual(layout.index(for: 0).index, 0)
        XCTAssertEqual(layout.index(for: 799).index, 1)
        XCTAssertEqual(layout.index(for: 999).index, 2)
        XCTAssertTrue(layout.index(for: 999).certain)
    }

    func testIrregularLayoutEstimatesThenLearns() {
        var layout = UsenetFileLayout(totalSize: 1000, firstPart: 0..<300, segments: UsenetFixture.segments([310, 310, 420]))
        XCTAssertFalse(layout.isRegular)
        XCTAssertEqual(layout.index(for: 50).index, 0)
        XCTAssertTrue(layout.index(for: 50).certain)
        XCTAssertNil(layout.range(of: 1))

        let guess = layout.index(for: 700)
        XCTAssertFalse(guess.certain)
        XCTAssertEqual(guess.index, 2)

        layout.learn(1, range: 300..<600)
        layout.learn(2, range: 600..<1000)
        XCTAssertEqual(layout.index(for: 650).index, 2)
        XCTAssertTrue(layout.index(for: 650).certain)
        XCTAssertEqual(layout.index(for: 450).index, 1)
    }

    func testIrregularGuessRespectsKnownNeighbours() {
        var layout = UsenetFileLayout(totalSize: 1000, firstPart: 0..<100, segments: UsenetFixture.segments([100, 100, 100, 100, 100]))
        layout.learn(3, range: 500..<700)
        // Offset 450 must lie before article 3, whatever the encoded sizes suggest.
        XCTAssertLessThanOrEqual(layout.index(for: 450).index, 2)
        // Offset 800 must lie after it.
        XCTAssertGreaterThanOrEqual(layout.index(for: 800).index, 4)
    }

    func testMemoryProfiles() {
        XCTAssertEqual(UsenetMemoryProfile.lowMemory.cacheBytes, 32 * 1024 * 1024)
        XCTAssertEqual(UsenetMemoryProfile.balanced.cacheBytes, 64 * 1024 * 1024)
        XCTAssertEqual(UsenetMemoryProfile.highThroughput.cacheBytes, 128 * 1024 * 1024)
        for profile in UsenetMemoryProfile.allCases {
            XCTAssertLessThan(profile.readAheadBytes, profile.cacheBytes)
        }
    }
}

// MARK: - Server URLs, stream specs, HTTP ranges

final class UsenetServerTests: XCTestCase {
    func testServerURLParsing() throws {
        let server = try XCTUnwrap(UsenetServerConfig(url: "nntps://user%40mail:p%40ss@news.example.com:443/8"))
        XCTAssertEqual(server.host, "news.example.com")
        XCTAssertEqual(server.port, 443)
        XCTAssertTrue(server.useSSL)
        XCTAssertEqual(server.username, "user@mail")
        XCTAssertEqual(server.password, "p@ss")
        XCTAssertEqual(server.maxConnections, 8)
    }

    func testServerURLDefaults() throws {
        let plain = try XCTUnwrap(UsenetServerConfig(url: "nntp://news.example.com"))
        XCTAssertEqual(plain.port, 119)
        XCTAssertFalse(plain.useSSL)
        XCTAssertEqual(plain.maxConnections, UsenetServerConfig.defaultConnections)
        XCTAssertEqual(UsenetServerConfig(url: "snews://news.example.com")?.port, 563)
        XCTAssertNil(UsenetServerConfig(url: "https://news.example.com"))
        XCTAssertEqual(UsenetServerConfig(url: "nntps://h.example/500")?.maxConnections, 50)
    }

    func testServerURLRoundTrip() throws {
        let server = UsenetServerConfig(host: "news.example.com", port: 563, useSSL: true,
                                        username: "a:b@c", password: "p/ss w?rd", maxConnections: 12)
        XCTAssertEqual(UsenetServerConfig(url: server.urlString), server)
    }

    func testStreamSpecRoundTrip() throws {
        let spec = UsenetStreamSpec(
            nzbURL: URL(string: "https://indexer.example/api?t=get&id=abc&apikey=x%2By")!,
            servers: [UsenetServerConfig(host: "a.example", port: 563, useSSL: true, username: "u", password: "p", maxConnections: 4)],
            fileMustInclude: "(?:S01E02)|(?:1x02)",
            fileIdx: 2
        )
        XCTAssertTrue(UsenetStreamSpec.isUsenetURL(spec.url.absoluteString))
        XCTAssertEqual(UsenetStreamSpec(url: spec.url), spec)
        XCTAssertNil(UsenetStreamSpec(url: URL(string: "https://example.com/video.mkv")!))
        XCTAssertFalse(UsenetStreamSpec.isUsenetURL("https://example.com"))
    }

    func testRangeParsing() {
        func parse(_ header: String?) -> ClosedRange<Int64>?? {
            UsenetStreamServer.parseRange(header, fileLength: 1000)
        }
        func range(_ header: String) -> ClosedRange<Int64>? {
            parse(header) ?? nil
        }
        // No header: a valid whole-file request.
        let whole = parse(nil)
        XCTAssertTrue(whole != nil)
        XCTAssertTrue((whole ?? nil) == nil)
        XCTAssertEqual(range("bytes=0-"), 0...999)
        XCTAssertEqual(range("bytes=100-199"), 100...199)
        XCTAssertEqual(range(" bytes=900-5000"), 900...999)
        XCTAssertEqual(range("bytes=-100"), 900...999)
        // Unsatisfiable or malformed: the outer optional is nil (→ 416).
        XCTAssertTrue(parse("bytes=1000-") == nil)
        XCTAssertTrue(parse("bytes=abc") == nil)
    }

    func testSafeNameAndMime() {
        XCTAssertEqual(UsenetStreamServer.safeName("Show S01E01 [1080p].MKV"), "video.mkv")
        XCTAssertEqual(UsenetStreamServer.safeName("noext"), "video.bin")
    }

    func testAddonServersComeFirstThenOwn() {
        let store = UserDefaults(suiteName: "usenet-tests-\(UUID().uuidString)")!
        let own = UsenetSavedServer(name: "Mine", host: "mine.example", port: 563, useSSL: true, username: "me", connections: 6)
        store.set(try? JSONEncoder().encode([own]), forKey: UsenetSettings.serversKey)
        let addon = UsenetServerConfig(host: "addon.example", port: 563, useSSL: true, username: "x", password: "y", maxConnections: 3)
        let spec = UsenetStreamSpec(nzbURL: URL(string: "https://i.example/a.nzb")!, servers: [addon])

        XCTAssertEqual(UsenetSettings.servers(for: spec, store: store).map(\.host), ["addon.example", "mine.example"])
        store.set(true, forKey: UsenetSettings.preferOwnServersKey)
        XCTAssertEqual(UsenetSettings.servers(for: spec, store: store).map(\.host), ["mine.example"])
    }
}
