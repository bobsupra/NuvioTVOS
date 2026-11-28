import Foundation
import XCTest
@testable import NuvioTV

final class UsenetSevenZipTests: XCTestCase {
    private let video = "Movie.2021.mkv"

    private func archive(_ volumes: [Data]) -> Data {
        volumes.reduce(Data(), +)
    }

    private func entries(_ volumes: [Data], password: String?) async throws -> [UsenetSevenZip.Entry] {
        let blob = archive(volumes)
        let next = try UsenetSevenZip.nextHeader(volumes[0])
        let read: UsenetSevenZip.Reader = { offset, length in
            guard offset >= 0, Int(offset) + length <= blob.count else { throw UsenetError.releaseIncomplete }
            return blob.subdata(in: Int(offset)..<(Int(offset) + length))
        }
        return try await UsenetSevenZip.entries(header: try await read(next.offset, next.size), password: password, read: read)
    }

    func testLZMADecodes() throws {
        XCTAssertEqual(try UsenetLZMA.decode(properties: SevenZipFixture.lzmaProperties, data: SevenZipFixture.lzmaData,
                                             size: SevenZipFixture.lzmaPlain.count), SevenZipFixture.lzmaPlain)
        XCTAssertEqual(try UsenetLZMA.decode(properties: SevenZipFixture.lzmaMixedProperties, data: SevenZipFixture.lzmaMixedData,
                                             size: SevenZipFixture.lzmaMixedPlain.count), SevenZipFixture.lzmaMixedPlain)
        // A prefix of the output needs only the start of the stream.
        XCTAssertEqual(try UsenetLZMA.decode(properties: SevenZipFixture.lzmaMixedProperties, data: SevenZipFixture.lzmaMixedData,
                                             size: 700), SevenZipFixture.lzmaMixedPlain.prefix(700))
        XCTAssertThrowsError(try UsenetLZMA.decode(properties: SevenZipFixture.lzmaMixedProperties,
                                                   data: SevenZipFixture.lzmaMixedData.prefix(40),
                                                   size: SevenZipFixture.lzmaMixedPlain.count))
        XCTAssertThrowsError(try UsenetLZMA.decode(properties: Data([0xFF, 0, 0, 1, 0]), data: SevenZipFixture.lzmaData, size: 10))
    }

    func testStoredFilesAreFoundInTheVolumes() async throws {
        let list = try await entries(SevenZipFixture.stored, password: nil)
        XCTAssertEqual(list.map(\.name), [video, "Movie.2021.nfo"])
        let movie = try XCTUnwrap(list.first)
        XCTAssertEqual(movie.method, .stored)
        XCTAssertEqual(movie.size, 4007)
        XCTAssertFalse(movie.isDirectory)
        let start = Int(movie.packStart + movie.offsetInFolder)
        XCTAssertEqual(archive(SevenZipFixture.stored).subdata(in: start..<(start + 4007)), SevenZipFixture.content)

        // Mapped onto the volumes the way the resolver maps it.
        let volumes = SevenZipFixture.stored.enumerated().map {
            UsenetExtent(volume: $0.offset, offset: 0, length: Int64($0.element.count))
        }
        let extents = UsenetStreamSource.compose([Int64(start)..<Int64(start + 4007)], through: volumes)
        XCTAssertEqual(extents.map(\.volume), [0, 1, 2])
        let bytes = extents.reduce(Data()) {
            $0 + SevenZipFixture.stored[$1.volume].subdata(in: Int($1.offset)..<Int($1.offset + $1.length))
        }
        XCTAssertEqual(bytes, SevenZipFixture.content)
    }

    func testAnEncryptedArchivePlaysWithThePassword() async throws {
        let list = try await entries(SevenZipFixture.encrypted, password: "secret")
        let movie = try XCTUnwrap(list.first { $0.name == video })
        guard case .encrypted(let properties) = movie.method else { return XCTFail("not encrypted: \(movie.method)") }
        XCTAssertEqual(movie.offsetInFolder, 0)
        XCTAssertEqual(movie.packSize, 4016, "padded to whole blocks")
        let cipher = try UsenetSevenZip.cipher(properties: properties, password: "secret", plainSize: movie.size)
        let start = Int(movie.packStart)
        let stored = archive(SevenZipFixture.encrypted).subdata(in: start..<(start + Int(movie.packSize)))
        let read: @Sendable (Int64, Int, Bool) async throws -> Data = { offset, length, _ in
            let end = min(Int(offset) + length, stored.count, Int(offset) / 500 * 500 + 500)
            return stored.subdata(in: Int(offset)..<end)
        }
        var whole = Data()
        while whole.count < 4007 {
            let chunk = try await UsenetRarCrypto.plainRead(offset: Int64(whole.count), maxLength: 900, cipher: cipher,
                                                            storedSize: movie.packSize, read: read)
            guard !chunk.isEmpty else { return XCTFail("stopped at \(whole.count)") }
            whole.append(chunk)
        }
        XCTAssertEqual(whole, SevenZipFixture.content)
    }

    func testAnEncryptedFileListNeedsTheRightPassword() async throws {
        do {
            _ = try await entries(SevenZipFixture.encrypted, password: nil)
            XCTFail("read without a password")
        } catch {
            XCTAssertEqual(error as? UsenetSevenZip.Failure, .needsPassword)
        }
        do {
            _ = try await entries(SevenZipFixture.encrypted, password: "Secret")
            XCTFail("read with the wrong password")
        } catch {
            XCTAssertEqual(error as? UsenetSevenZip.Failure, .wrongPassword)
        }
    }

    func testOnlySevenZipStartsLikeOne() {
        XCTAssertThrowsError(try UsenetSevenZip.nextHeader(Data("Rar!".utf8) + Data(count: 40))) {
            XCTAssertEqual($0 as? UsenetSevenZip.Failure, .notSevenZip)
        }
        XCTAssertEqual(UsenetSniff.kind(of: SevenZipFixture.stored[0]), .sevenZip)
    }

    func testArchivesAreGroupedByName() {
        let role = UsenetReleaseResolver.role(ofName:)
        XCTAssertEqual(role("Movie.7z"), .sevenZip)
        XCTAssertEqual(role("Movie.7z.001"), .sevenZip)
        XCTAssertEqual(role("Movie.zip"), .unsupportedArchive)
        let names = ["Movie.7z.002", "Movie.nfo", "Movie.7z.001", "Other.7z", "Movie.7z.003", "a8f3e1c9"]
        var roles = names.map(role)
        roles[5] = .sevenZip // recognised by its bytes
        XCTAssertEqual(UsenetReleaseResolver.sevenZipSets(names: names, roles: roles), [[2, 0, 4], [3], [5]])
    }
}
