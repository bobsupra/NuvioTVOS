import Compression
import CoreText
import XCTest
@testable import NuvioTV

/// Custom subtitle fonts: links, ZIPs, font files and the page another device sends them through.
final class SubtitleFontTests: XCTestCase {
    func testLinksBecomeDirectDownloads() {
        XCTAssertEqual(
            SubtitleFontLinks.target(for: "https://github.com/google/fonts/blob/main/ofl/lato/Lato-Regular.ttf"),
            .file(URL(string: "https://raw.githubusercontent.com/google/fonts/main/ofl/lato/Lato-Regular.ttf")!)
        )
        XCTAssertEqual(
            SubtitleFontLinks.target(for: "https://www.dropbox.com/scl/fi/abc/Font.ttf?rlkey=xyz&dl=0"),
            .file(URL(string: "https://www.dropbox.com/scl/fi/abc/Font.ttf?rlkey=xyz&dl=1")!)
        )
        XCTAssertEqual(
            SubtitleFontLinks.target(for: "https://drive.google.com/file/d/1AbC_d/view?usp=sharing"),
            .file(URL(string: "https://drive.usercontent.google.com/download?id=1AbC_d&export=download&confirm=t")!)
        )
        XCTAssertEqual(
            SubtitleFontLinks.target(for: "https://drive.google.com/open?id=XYZ"),
            .file(URL(string: "https://drive.usercontent.google.com/download?id=XYZ&export=download&confirm=t")!)
        )
        XCTAssertEqual(SubtitleFontLinks.target(for: "https://fonts.google.com/specimen/Open+Sans?query=open"), .googleFonts("Open Sans"))
        XCTAssertEqual(
            SubtitleFontLinks.target(for: "  example.com/fonts/pack.zip "),
            .file(URL(string: "https://example.com/fonts/pack.zip")!),
            "a link without its scheme is taken as https"
        )
        XCTAssertNil(SubtitleFontLinks.target(for: "hello"))
        XCTAssertNil(SubtitleFontLinks.target(for: ""))
        XCTAssertNil(SubtitleFontLinks.target(for: "two words.com"))
    }

    func testGoogleFontsStylesheetGivesEachFileOnce() {
        let css = """
        @font-face { font-family: 'Open Sans'; src: url(https://fonts.gstatic.com/s/opensans/v1/a.ttf) format('truetype'); }
        @font-face { font-family: 'Open Sans'; src: url('https://fonts.gstatic.com/s/opensans/v1/b.ttf') format('truetype'); }
        @font-face { src: url(https://fonts.gstatic.com/s/opensans/v1/a.ttf); }
        """
        XCTAssertEqual(SubtitleFontLinks.googleFontsLinks(in: css).map(\.lastPathComponent), ["a.ttf", "b.ttf"])
    }

    func testFilesAreKnownByTheirFirstBytes() {
        XCTAssertEqual(SubtitleFontPayload.kind(of: Data([0x00, 0x01, 0x00, 0x00, 9])), .font(fileExtension: "ttf"))
        XCTAssertEqual(SubtitleFontPayload.kind(of: Data("OTTO....".utf8)), .font(fileExtension: "otf"))
        XCTAssertEqual(SubtitleFontPayload.kind(of: Data("ttcf....".utf8)), .font(fileExtension: "ttc"))
        XCTAssertEqual(SubtitleFontPayload.kind(of: Data("wOF2....".utf8)), .webFont)
        XCTAssertEqual(SubtitleFontPayload.kind(of: Data([0x50, 0x4B, 0x03, 0x04, 0])), .zip)
        XCTAssertEqual(SubtitleFontPayload.kind(of: Data("\u{FEFF}\n  <!doctype html><html>".utf8)), .webPage)
        XCTAssertEqual(SubtitleFontPayload.kind(of: Data("hello".utf8)), .unknown)
    }

    func testCRC32() {
        XCTAssertEqual(ZipFontArchive.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testAZipGivesItsFonts() throws {
        let regular = Data([0x00, 0x01, 0x00, 0x00]) + Data(repeating: 7, count: 300)
        let bold = Data("OTTO".utf8) + Data(repeating: 1, count: 2_000)
        let zip = makeZip([
            ("Fonts/", Data(), false),
            ("Fonts/Regular.ttf", regular, false),
            ("Fonts/Bold.OTF", bold, true),
            ("readme.txt", Data("hi".utf8), false),
            ("__MACOSX/Fonts/._Regular.ttf", Data("x".utf8), false),
        ])
        let entries = try ZipFontArchive.fontEntries(in: zip, limit: 50, maximumEntryBytes: 1_000_000)
        XCTAssertEqual(entries.map(\.name), ["Regular.ttf", "Bold.OTF"])
        XCTAssertEqual(entries.map(\.data), [regular, bold])
        XCTAssertEqual(try ZipFontArchive.fontEntries(in: zip, limit: 1, maximumEntryBytes: 1_000_000).count, 1)
        XCTAssertEqual(try ZipFontArchive.fontEntries(in: zip, limit: 50, maximumEntryBytes: 1_000).map(\.name), ["Regular.ttf"])
        XCTAssertThrowsError(try ZipFontArchive.fontEntries(in: Data("not a zip at all, not even close".utf8), limit: 50, maximumEntryBytes: 10))
    }

    func testAFontFileIsRead() throws {
        let font = CTFontCreateWithName("Georgia" as CFString, 20, nil)
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
              let data = try? Data(contentsOf: url) else {
            throw XCTSkip("no readable system font file here")
        }
        let family = CTFontCopyFamilyName(font) as String
        let faces = SubtitleFontFaces.faces(in: data)
        XCTAssertTrue(faces.contains { $0.family == family }, faces.map(\.family).description)
        XCTAssertFalse(faces.contains { $0.postScriptName.isEmpty })
        XCTAssertTrue(SubtitleFontFaces.faces(in: Data("not a font".utf8)).isEmpty)
        XCTAssertNotNil(SubtitleFontFaces.regularFaceName(family: family))
        XCTAssertNil(SubtitleFontFaces.regularFaceName(family: "No Such Family 1234"))
    }

    func testStoredNamesAreSafeAndNew() {
        let first = SubtitleFontLibrary.storedName(postScriptName: "My/Font Bold", fileExtension: "ttf")
        let second = SubtitleFontLibrary.storedName(postScriptName: "My/Font Bold", fileExtension: "ttf")
        XCTAssertTrue(first.hasPrefix("MyFontBold-"), first)
        XCTAssertTrue(first.hasSuffix(".ttf"))
        XCTAssertNotEqual(first, second)
    }

    func testThePageRequestsAreRouted() {
        func route(_ text: String, key: String = "abc234") -> SubtitleFontUploadServer.Route? {
            SubtitleFontUploadServer.parseHead(Data(text.utf8)).map { SubtitleFontUploadServer.route($0, key: key) }
        }
        let upload = SubtitleFontUploadServer.parseHead(Data("PUT /fonts/abc234/upload?name=My%20Font.ttf HTTP/1.1\r\nHost: tv\r\nContent-Length: 1234".utf8))
        XCTAssertEqual(upload?.contentLength, 1234)
        XCTAssertEqual(route("PUT /fonts/abc234/upload?name=My%20Font.ttf HTTP/1.1\r\nContent-Length: 4"), .upload(name: "My Font.ttf"))
        XCTAssertEqual(route("PUT /fonts/abc234/upload?name=..%2F..%2Fevil.ttf HTTP/1.1\r\nContent-Length: 4"), .upload(name: "evil.ttf"))
        XCTAssertEqual(route("GET /fonts/abc234 HTTP/1.1\r\nHost: tv"), .page)
        XCTAssertEqual(route("GET /fonts/abc234/ HTTP/1.1"), .page)
        XCTAssertEqual(route("GET /fonts/abc234/list HTTP/1.1"), .list)
        XCTAssertEqual(route("POST /fonts/abc234/link HTTP/1.1\r\nContent-Length: 20"), .link)
        XCTAssertEqual(route("POST /fonts/abc234/delete?id=Lato-x.ttf HTTP/1.1"), .delete(id: "Lato-x.ttf"))
        XCTAssertEqual(route("GET /fonts/abc234 HTTP/1.1", key: "zzzzzz"), .notFound, "another key opens nothing")
        XCTAssertEqual(route("GET /fonts/abc234/../etc HTTP/1.1"), .notFound)
        XCTAssertNil(route("POST /fonts/abc234/link HTTP/1.1\r\nTransfer-Encoding: chunked"))
        XCTAssertNil(route("GARBAGE"))

        let key = SubtitleFontUploadServer.makeKey()
        XCTAssertEqual(key.count, 6)
        XCTAssertTrue(key.allSatisfy { "abcdefghjkmnpqrstuvwxyz23456789".contains($0) })
        XCTAssertTrue(SubtitleFontPageKey.isValid(key))
        XCTAssertFalse(SubtitleFontPageKey.isValid("abc"))
        XCTAssertFalse(SubtitleFontPageKey.isValid("ABC234"))
    }

    // MARK: A ZIP made here: stored and deflated entries

    private func makeZip(_ files: [(String, Data, Bool)]) -> Data {
        var body = Data()
        var central = Data()
        for (name, content, deflate) in files {
            let packed = deflate ? deflated(content) : content
            let method: UInt16 = deflate ? 8 : 0
            let crc = ZipFontArchive.crc32(content)
            let nameData = Data(name.utf8)
            let offset = UInt32(body.count)
            body.append(joined(
                le32(0x0403_4B50), le16(20), le16(0), le16(method), le16(0), le16(0),
                le32(crc), le32(UInt32(packed.count)), le32(UInt32(content.count)),
                le16(UInt16(nameData.count)), le16(0), nameData, packed
            ))
            central.append(joined(
                le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(method), le16(0), le16(0),
                le32(crc), le32(UInt32(packed.count)), le32(UInt32(content.count)),
                le16(UInt16(nameData.count)), le16(0), le16(0), le16(0), le16(0), le32(0), le32(offset), nameData
            ))
        }
        let end = joined(
            le32(0x0605_4B50), le16(0), le16(0), le16(UInt16(files.count)), le16(UInt16(files.count)),
            le32(UInt32(central.count)), le32(UInt32(body.count)), le16(0)
        )
        return joined(body, central, end)
    }

    private func deflated(_ data: Data) -> Data {
        var output = Data(count: data.count + 1_024)
        let count = output.withUnsafeMutableBytes { (out: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int in
                compression_encode_buffer(
                    out.bindMemory(to: UInt8.self).baseAddress!, out.count,
                    input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return output.prefix(count)
    }

    private func joined(_ parts: Data...) -> Data {
        parts.reduce(into: Data()) { $0.append($1) }
    }

    private func le16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func le32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
