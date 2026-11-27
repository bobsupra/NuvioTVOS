import Foundation
import XCTest
@testable import NuvioTV

final class UsenetNestedRarTests: XCTestCase {
    /// Bytes of the volumes at `extents`, in order.
    private func read(_ extents: [UsenetExtent], from volumes: [Data], length: Int = .max) -> Data {
        var out = Data()
        for extent in extents where out.count < length {
            let take = Int(min(Int64(length - out.count), extent.length))
            out.append(volumes[extent.volume].subdata(in: Int(extent.offset)..<(Int(extent.offset) + take)))
        }
        return out
    }

    /// Lists the outer set, reads each inner volume's headers out of it, and plays the video
    /// through both sets.
    private func assertPlays(_ fixture: [Data], innerNames: [String], video: String, password: String?,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let outer = try fixture.map { try XCTUnwrap(UsenetRar.parseVolume($0, password: password), file: file, line: line) }
        let stored = outer.flatMap(\.entries).filter { !$0.isDirectory && !$0.continuesFromPrevious }.map(\.name)
        let sets = UsenetReleaseResolver.innerRarSets(stored)
        XCTAssertEqual(sets, [innerNames], file: file, line: line)

        let inner = try innerNames.map { name -> UsenetRarVolume in
            let extents = try UsenetReleaseResolver.rarMapping(outer, innerName: name, password: password).extents
            let head = read(extents, from: fixture, length: UsenetReleaseResolver.innerHeaderBytes)
            return try XCTUnwrap(UsenetRar.parseVolume(head, password: password), file: file, line: line)
        }
        XCTAssertEqual(inner[0].entries.first?.name, video, file: file, line: line)

        let mapping = try UsenetReleaseResolver.nestedMapping(outer: outer, innerNames: innerNames, inner: inner,
                                                              innerName: video, password: password)
        XCTAssertGreaterThan(mapping.extents.count, 1, file: file, line: line)
        let bytes = read(mapping.extents, from: fixture)
        if let cipher = mapping.cipher {
            let plain = try XCTUnwrap(UsenetRarCrypto.plain(bytes, storedStart: 0, previous: nil, cipher: cipher,
                                                            offset: 0, length: bytes.count), file: file, line: line)
            XCTAssertEqual(plain, NestedRarFixture.content, file: file, line: line)
        } else {
            XCTAssertEqual(bytes, NestedRarFixture.content, file: file, line: line)
        }
    }

    func testASceneReleaseInsideARarSetPlays() throws {
        try assertPlays(NestedRarFixture.scene, innerNames: ["movie.rar", "movie.r00", "movie.r01"],
                        video: "Movie.2021.mkv", password: nil)
    }

    func testAPasswordProtectedSetInsideARarSetPlays() throws {
        try assertPlays(NestedRarFixture.encrypted,
                        innerNames: ["Movie.2021.part1.rar", "Movie.2021.part2.rar", "Movie.2021.part3.rar", "Movie.2021.part4.rar"],
                        video: "Movie.2021.mkv", password: "secret")
        let outer = NestedRarFixture.encrypted.compactMap { UsenetRar.parseVolume($0, password: nil) }
        let names = ["Movie.2021.part1.rar", "Movie.2021.part2.rar", "Movie.2021.part3.rar", "Movie.2021.part4.rar"]
        let inner = try names.map { name -> UsenetRarVolume in
            let extents = try UsenetReleaseResolver.rarMapping(outer, innerName: name, password: nil).extents
            return try XCTUnwrap(UsenetRar.parseVolume(read(extents, from: NestedRarFixture.encrypted, length: 4096)))
        }
        XCTAssertThrowsError(try UsenetReleaseResolver.nestedMapping(outer: outer, innerNames: names, inner: inner,
                                                                     innerName: "Movie.2021.mkv", password: nil)) {
            XCTAssertEqual($0 as? UsenetError, .archiveEncrypted)
        }
    }

    func testAMissingInnerVolumeIsIncomplete() throws {
        let outer = NestedRarFixture.scene.compactMap { UsenetRar.parseVolume($0) }
        let names = ["movie.rar", "movie.r00", "movie.r01"]
        let inner = try names.prefix(2).map { name -> UsenetRarVolume in
            let extents = try UsenetReleaseResolver.rarMapping(outer, innerName: name, password: nil).extents
            return try XCTUnwrap(UsenetRar.parseVolume(read(extents, from: NestedRarFixture.scene, length: 4096)))
        }
        XCTAssertThrowsError(try UsenetReleaseResolver.nestedMapping(outer: outer, innerNames: Array(names.prefix(2)), inner: inner,
                                                                     innerName: "Movie.2021.mkv", password: nil)) {
            XCTAssertEqual($0 as? UsenetError, .releaseIncomplete)
        }
    }

    func testInnerSetsAreFoundByName() {
        let names = ["Release/release.nfo", "Release/release.r00", "Release/release.rar", "Release/release.sfv",
                     "Release/Sample/release-sample.mkv", "Release/Subs/release.subs.rar", "Release/release.r01"]
        XCTAssertEqual(UsenetReleaseResolver.innerRarSets(names), [
            ["Release/release.rar", "Release/release.r00", "Release/release.r01"],
            ["Release/Subs/release.subs.rar"],
        ])
        XCTAssertEqual(UsenetReleaseResolver.innerRarSets(["a.part02.rar", "a.part01.rar"]), [["a.part01.rar", "a.part02.rar"]])
        XCTAssertEqual(UsenetReleaseResolver.innerRarSets(["movie.mkv", "movie.nfo"]), [])
    }

    func testRangesMapThroughVolumes() {
        // A file stored as 1000 bytes in volume 0 from 100, then 1000 in volume 1 from 50.
        let file = [UsenetExtent(volume: 0, offset: 100, length: 1000), UsenetExtent(volume: 1, offset: 50, length: 1000)]
        XCTAssertEqual(UsenetStreamSource.compose([900..<1100, 1500..<1600], through: file), [
            UsenetExtent(volume: 0, offset: 1000, length: 100),
            UsenetExtent(volume: 1, offset: 50, length: 100),
            UsenetExtent(volume: 1, offset: 550, length: 100),
        ])
        XCTAssertEqual(UsenetStreamSource.compose([0..<10, 10..<20], through: file), [UsenetExtent(volume: 0, offset: 100, length: 20)])
        XCTAssertEqual(UsenetStreamSource.compose([1990..<2100], through: file), [UsenetExtent(volume: 1, offset: 1040, length: 10)])
    }
}
