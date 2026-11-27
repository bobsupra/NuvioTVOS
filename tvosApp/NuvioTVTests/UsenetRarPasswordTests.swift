import Foundation
import XCTest
@testable import NuvioTV

final class UsenetRarPasswordTests: XCTestCase {
    private let password = "pa55 wörd"
    private let video = "Movie.2020.1080p.mkv"

    private func parse(_ fixture: [Data], password: String?) throws -> [UsenetRarVolume] {
        try fixture.map { try XCTUnwrap(UsenetRar.parseVolume($0, password: password)) }
    }

    /// The stored bytes of the played file, read through its extents the way the stream session
    /// reads them: never past an extent, nor past a 700-byte article of a volume.
    private func storedReader(_ fixture: [Data], extents: [UsenetExtent], most: Int = .max) -> @Sendable (Int64, Int, Bool) async throws -> Data {
        let starts = UsenetStreamSource(name: "", kind: .rar, volumes: [], extents: extents, firstArticles: []).extentStarts
        return { offset, length, _ in
            guard let place = UsenetStreamSource.locate(offset, extents: extents, starts: starts) else { return Data() }
            let extent = extents[place.extent]
            let articleEnd = (place.volumeOffset / 700 + 1) * 700
            let end = min(place.volumeOffset + Int64(min(length, most)), extent.offset + extent.length, articleEnd)
            return fixture[extent.volume].subdata(in: Int(place.volumeOffset)..<Int(end))
        }
    }

    private func assertPlays(_ fixture: [Data], file: StaticString = #filePath, line: UInt = #line) async throws {
        let volumes = try parse(fixture, password: password)
        let mapping = try UsenetReleaseResolver.rarMapping(volumes, innerName: video, password: password)
        let cipher = try XCTUnwrap(mapping.cipher, file: file, line: line)
        XCTAssertEqual(cipher.plainSize, 4007, file: file, line: line)
        let storedSize = mapping.extents.reduce(0) { $0 + $1.length }
        XCTAssertEqual(storedSize, 4016, "padded to whole blocks", file: file, line: line)
        XCTAssertGreaterThan(Set(mapping.extents.map(\.volume)).count, 2, file: file, line: line)

        for most in [Int.max, 5] {
            let read = storedReader(fixture, extents: mapping.extents, most: most)
            // Front to back, the way the local server asks.
            var whole = Data()
            while whole.count < 4007 {
                let chunk = try await UsenetRarCrypto.plainRead(offset: Int64(whole.count), maxLength: 1000,
                                                                cipher: cipher, storedSize: storedSize, read: read)
                guard !chunk.isEmpty else { return XCTFail("stopped at \(whole.count)", file: file, line: line) }
                whole.append(chunk)
            }
            XCTAssertEqual(whole, RarPasswordFixture.content, file: file, line: line)
            // Seeks: inside a block, across volumes, at the end, past it.
            for (offset, length) in [(5, 10), (1290, 40), (1296, 3), (3000, 2000), (4000, 100)] {
                let chunk = try await UsenetRarCrypto.plainRead(offset: Int64(offset), maxLength: length,
                                                                cipher: cipher, storedSize: storedSize, read: read)
                XCTAssertFalse(chunk.isEmpty, "at \(offset)", file: file, line: line)
                XCTAssertLessThanOrEqual(chunk.count, length, file: file, line: line)
                XCTAssertEqual(chunk, RarPasswordFixture.content.subdata(in: offset..<(offset + chunk.count)), "at \(offset)", file: file, line: line)
            }
            let past = try await UsenetRarCrypto.plainRead(offset: 4007, maxLength: 10, cipher: cipher, storedSize: storedSize, read: read)
            XCTAssertTrue(past.isEmpty, file: file, line: line)
        }
    }

    func testRar5PlaysWithTheNZBPassword() async throws {
        let volumes = try parse(RarPasswordFixture.rar5, password: password)
        guard case .rar5(let count, _, _, let check)? = volumes[0].entries.first?.encryption else {
            return XCTFail("no RAR 5 encryption record")
        }
        XCTAssertEqual(count, 15)
        XCTAssertNotNil(check)
        try await assertPlays(RarPasswordFixture.rar5)
        let mapping = try UsenetReleaseResolver.rarMapping(volumes, innerName: video, password: password)
        XCTAssertEqual(mapping.cipher?.passwordChecked, true)
    }

    func testRar5WithEncryptedHeadersPlays() async throws {
        let locked = try parse(RarPasswordFixture.rar5Headers, password: nil)
        XCTAssertTrue(locked[0].headersEncrypted)
        XCTAssertTrue(locked[0].entries.isEmpty)
        let open = try parse(RarPasswordFixture.rar5Headers, password: password)
        XCTAssertFalse(open[0].headersEncrypted)
        XCTAssertEqual(open[0].entries.map(\.name), [video])
        XCTAssertEqual(open[0].isFirstVolume, true)
        XCTAssertEqual(open.map(\.volumeNumber), [0, 1, 2, 3])
        try await assertPlays(RarPasswordFixture.rar5Headers)
    }

    func testRar4PlaysWithTheNZBPassword() async throws {
        let volumes = try parse(RarPasswordFixture.rar4, password: password)
        XCTAssertEqual(volumes[0].entries.first?.encryption, .rar4(salt: Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF])))
        try await assertPlays(RarPasswordFixture.rar4)
    }

    func testRar4WithEncryptedHeadersPlays() async throws {
        let locked = try parse(RarPasswordFixture.rar4Headers, password: nil)
        XCTAssertTrue(locked[0].headersEncrypted)
        let open = try parse(RarPasswordFixture.rar4Headers, password: password)
        XCTAssertEqual(open.map { $0.entries.map(\.name) }, [[video], [video], [video]])
        XCTAssertEqual(open.map { $0.entries.first?.continuesInNext }, [true, true, false])
        XCTAssertTrue(open.allSatisfy(\.reachedEnd))
        try await assertPlays(RarPasswordFixture.rar4Headers)
    }

    func testWithoutAPasswordTheReleaseIsLocked() throws {
        for fixture in [RarPasswordFixture.rar5, RarPasswordFixture.rar5Headers, RarPasswordFixture.rar4, RarPasswordFixture.rar4Headers] {
            let volumes = try parse(fixture, password: nil)
            XCTAssertThrowsError(try UsenetReleaseResolver.rarMapping(volumes, innerName: video, password: nil)) {
                XCTAssertEqual($0 as? UsenetError, .archiveEncrypted)
            }
        }
        // An empty password in the NZB is none.
        let volumes = try parse(RarPasswordFixture.rar5, password: "")
        XCTAssertThrowsError(try UsenetReleaseResolver.rarMapping(volumes, innerName: video, password: "")) {
            XCTAssertEqual($0 as? UsenetError, .archiveEncrypted)
        }
    }

    func testAWrongPasswordIsTold() throws {
        // RAR 5 checks it; encrypted RAR 4 headers fail their checksum.
        for fixture in [RarPasswordFixture.rar5, RarPasswordFixture.rar5Headers, RarPasswordFixture.rar4Headers] {
            let volumes = try parse(fixture, password: "pa55 word")
            XCTAssertThrowsError(try UsenetReleaseResolver.rarMapping(volumes, innerName: video, password: "pa55 word")) {
                XCTAssertEqual($0 as? UsenetError, .wrongPassword)
            }
        }
    }

    func testAWrongRar4PasswordShowsInTheFirstBytes() async throws {
        let volumes = try parse(RarPasswordFixture.rar4, password: "pa55 word")
        let mapping = try UsenetReleaseResolver.rarMapping(volumes, innerName: video, password: "pa55 word")
        let wrong = try XCTUnwrap(mapping.cipher)
        XCTAssertFalse(wrong.passwordChecked)
        let first = try XCTUnwrap(mapping.extents.first)
        let stored = RarPasswordFixture.rar4[first.volume].subdata(in: Int(first.offset)..<Int(first.offset + 1024))
        let noise = try XCTUnwrap(UsenetRarCrypto.plain(stored, storedStart: 0, previous: nil, cipher: wrong, offset: 0, length: 1024))
        XCTAssertTrue(UsenetReleaseResolver.passwordLooksWrong(name: video, plainHead: noise))

        let right = try XCTUnwrap(UsenetReleaseResolver.rarMapping(try parse(RarPasswordFixture.rar4, password: password),
                                                                    innerName: video, password: password).cipher)
        let head = try XCTUnwrap(UsenetRarCrypto.plain(stored, storedStart: 0, previous: nil, cipher: right, offset: 0, length: 1024))
        XCTAssertEqual(head, RarPasswordFixture.content.prefix(1024))
        XCTAssertFalse(UsenetReleaseResolver.passwordLooksWrong(name: video, plainHead: head))
        // Kinds that can't be told from their first bytes are never judged.
        XCTAssertFalse(UsenetReleaseResolver.passwordLooksWrong(name: "Movie.wmv", plainHead: noise))

        // From a volume's first article, as the resolver reads it.
        let article = UsenetYEncSegment(data: RarPasswordFixture.rar4[first.volume], header: UsenetYEncHeader(),
                                        computedCRC: 0, fileOffset: 0)
        XCTAssertEqual(UsenetReleaseResolver.plainHead(of: article, from: first, cipher: right)?.prefix(4),
                       Data([0x1A, 0x45, 0xDF, 0xA3]))
    }

    func testRar4KeysMatchRar() {
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        func unhex(_ text: String) -> Data {
            Data(stride(from: 0, to: text.count, by: 2).map {
                UInt8(text[text.index(text.startIndex, offsetBy: $0)..<text.index(text.startIndex, offsetBy: $0 + 2)], radix: 16)!
            })
        }
        // Vectors from rarfile's tests; 29 and 127 characters go through RAR's SHA-1 quirk.
        let cases: [(String, String, String, String)] = [
            ("password", "00ff00", "a160cb31cb262e9231c0b6fc984fbb0d", "aa54a659fb0c359b30f353a6343fb11d"),
            (String(repeating: "p", count: 28), "1122334455667788", "ffff33ffaf31987c899ccc2f965a8927", "bdff6873721b247afa4f978448a5aeef"),
            (String(repeating: "p", count: 29), "1122334455667788", "306cafde28f1ea78c9427c3ec642c0db", "173ecdf574c0bfe9e7c23bdfd96fa435"),
            (String(repeating: "p", count: 127), "1122334455667788", "b1bc223609af7d4f3b70e5a254ac2501", "302c97945530d7ffa7c551eb2dd21a90"),
        ]
        for (password, salt, key, iv) in cases {
            let derived = UsenetRarCrypto.rar4Key(password: password, salt: unhex(salt))
            XCTAssertEqual(hex(derived.key), key, "\(password.count) characters")
            XCTAssertEqual(hex(derived.iv), iv, "\(password.count) characters")
        }
    }

    func testRar5PasswordsAreCutWhereRarCutsThem() {
        XCTAssertEqual(UsenetRarCrypto.rar5Password("pa55 wörd"), Data("pa55 wörd".utf8))
        XCTAssertEqual(UsenetRarCrypto.rar5Password(String(repeating: "x", count: 200)).count, 127)
    }

    func testPlainBytesStopAtTheFileEnd() throws {
        let cipher = UsenetRarCipher(key: Data(count: 16), iv: Data(count: 16), plainSize: 20, passwordChecked: false)
        let stored = Data(count: 32)
        XCTAssertEqual(UsenetRarCrypto.plain(stored, storedStart: 0, previous: nil, cipher: cipher, offset: 0, length: 100)?.count, 20)
        XCTAssertEqual(UsenetRarCrypto.plain(stored, storedStart: 0, previous: nil, cipher: cipher, offset: 18, length: 100)?.count, 2)
        // Not whole blocks, or no chain before a later block: nothing.
        XCTAssertNil(UsenetRarCrypto.plain(Data(count: 15), storedStart: 0, previous: nil, cipher: cipher, offset: 0, length: 10))
        XCTAssertNil(UsenetRarCrypto.plain(stored, storedStart: 16, previous: nil, cipher: cipher, offset: 16, length: 10))
        XCTAssertNil(UsenetRarCrypto.decrypt(Data(count: 17), key: Data(count: 16), iv: Data(count: 16)))
    }
}
