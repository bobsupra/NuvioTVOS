import XCTest
@testable import AetherEngine

final class HLSSegmentDecryptorTests: XCTestCase {

    /// hex string -> Data (even length, lowercase or upper).
    private func hex(_ s: String) -> Data {
        var data = Data(capacity: s.count / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            data.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return data
    }

    // MARK: - AES-128-CBC/PKCS7 decryption

    // Ground-truth vector: openssl enc -aes-128-cbc -K <key> -iv <iv> with PKCS7 padding.
    func testDecryptsKnownAES128CBCVector() throws {
        let key = hex("000102030405060708090a0b0c0d0e0f")
        let iv = hex("101112131415161718191a1b1c1d1e1f")
        let ciphertext = hex(
            "2d67f5a1b5071958406336239ff8cafee6eabc39b3893207e2ed969b8815406"
            + "0727be7f16ffc1af7de5388810514872e0f2ffb31cef63a4c4abab5ffb52a087c"
        )
        let expected = "AetherEngine HLS AES-128 clear-key decrypt test vector!!"

        let plaintext = HLSSegmentDecryptor.decryptAES128CBC(ciphertext, key: key, iv: iv)
        XCTAssertEqual(plaintext.map { String(decoding: $0, as: UTF8.self) }, expected)
    }

    func testRejectsWrongKeyLength() {
        let ct = hex(String(repeating: "00", count: 16))
        XCTAssertNil(HLSSegmentDecryptor.decryptAES128CBC(ct, key: Data(repeating: 0, count: 8),
                                                          iv: Data(repeating: 0, count: 16)))
    }

    func testRejectsWrongIVLength() {
        let ct = hex(String(repeating: "00", count: 16))
        XCTAssertNil(HLSSegmentDecryptor.decryptAES128CBC(ct, key: Data(repeating: 0, count: 16),
                                                          iv: Data(repeating: 0, count: 8)))
    }

    func testRejectsNonBlockAlignedCiphertext() {
        XCTAssertNil(HLSSegmentDecryptor.decryptAES128CBC(Data(repeating: 0, count: 10),
                                                          key: Data(repeating: 0, count: 16),
                                                          iv: Data(repeating: 0, count: 16)))
    }

    // MARK: - EXT-X-KEY parsing

    private func parseMedia(_ text: String) throws -> HLSMediaPlaylist {
        guard case .media(let media) = try HLSPlaylistParser.parse(text) else {
            throw XCTSkip("expected media playlist")
        }
        return media
    }

    func testParsesAES128KeyWithExplicitIV() throws {
        let media = try parseMedia("""
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:5
        #EXT-X-MEDIA-SEQUENCE:5
        #EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example/key.bin",IV=0x000102030405060708090A0B0C0D0E0F
        #EXTINF:5,
        seg5.ts
        """)
        XCTAssertTrue(media.isEncrypted)
        XCTAssertFalse(media.hasUnsupportedEncryption)
        let crypt = try XCTUnwrap(media.segments.first?.crypt)
        XCTAssertEqual(crypt.keyURI, "https://cdn.example/key.bin")
        XCTAssertEqual(crypt.iv, hex("000102030405060708090a0b0c0d0e0f"))
    }

    func testDerivesSequenceIVWhenKeyHasNoIV() throws {
        // RFC 8216: no IV -> 16-byte big-endian media-sequence number (MEDIA-SEQUENCE=5 -> IV ends 0x05).
        let media = try parseMedia("""
        #EXTM3U
        #EXT-X-TARGETDURATION:5
        #EXT-X-MEDIA-SEQUENCE:5
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:5,
        seg5.ts
        #EXTINF:5,
        seg6.ts
        """)
        let first = try XCTUnwrap(media.segments[0].crypt)
        let second = try XCTUnwrap(media.segments[1].crypt)
        XCTAssertEqual(first.iv, hex("00000000000000000000000000000005"))
        XCTAssertEqual(second.iv, hex("00000000000000000000000000000006"))
    }

    func testStickyKeyGovernsFollowingSegmentsUntilNone() throws {
        let media = try parseMedia("""
        #EXTM3U
        #EXT-X-TARGETDURATION:5
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
        #EXTINF:5,
        a.ts
        #EXTINF:5,
        b.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:5,
        c.ts
        """)
        XCTAssertNotNil(media.segments[0].crypt)
        XCTAssertNotNil(media.segments[1].crypt)  // sticky from the tag above
        XCTAssertNil(media.segments[2].crypt)     // cleared by METHOD=NONE
    }

    func testSampleAESMarksUnsupported() throws {
        let media = try parseMedia("""
        #EXTM3U
        #EXT-X-TARGETDURATION:5
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin"
        #EXTINF:5,
        a.ts
        """)
        XCTAssertTrue(media.isEncrypted)
        XCTAssertTrue(media.hasUnsupportedEncryption)
    }

    func testAES128WithoutURIIsUnsupported() throws {
        let media = try parseMedia("""
        #EXTM3U
        #EXT-X-TARGETDURATION:5
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-KEY:METHOD=AES-128
        #EXTINF:5,
        a.ts
        """)
        XCTAssertTrue(media.hasUnsupportedEncryption)
        XCTAssertNil(media.segments[0].crypt)
    }

    func testClearPlaylistHasNoCrypt() throws {
        let media = try parseMedia("""
        #EXTM3U
        #EXT-X-TARGETDURATION:5
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:5,
        a.ts
        """)
        XCTAssertFalse(media.isEncrypted)
        XCTAssertFalse(media.hasUnsupportedEncryption)
        XCTAssertNil(media.segments[0].crypt)
    }
}
