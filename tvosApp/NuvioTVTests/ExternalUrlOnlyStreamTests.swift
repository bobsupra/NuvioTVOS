import XCTest
@testable import NuvioTV

final class ExternalUrlOnlyStreamTests: XCTestCase {
    private func stream(_ json: String) throws -> NuvioStream? {
        let raw = try JSONDecoder().decode(StreamAddonStreamDTO.self, from: Data(json.utf8))
        return raw.toNuvioStream(addonName: "AIOStreams")
    }

    func testExternalUrlOnlyEntryIsNotPlayable() throws {
        let info = try XCTUnwrap(stream(#"{"name": "[AIOStreams] No streams found", "externalUrl": "https://github.com/Viren070/AIOStreams"}"#))
        XCTAssertTrue(info.isNotPlayable)
    }

    func testDirectUrlStaysPlayable() throws {
        let direct = try XCTUnwrap(stream(#"{"name": "1080p", "url": "https://cdn.example/a.mkv", "externalUrl": "https://example.com/info"}"#))
        XCTAssertFalse(direct.isNotPlayable)
        let torrent = try XCTUnwrap(stream(#"{"name": "4K", "infoHash": "0123456789abcdef0123456789abcdef01234567"}"#))
        XCTAssertFalse(torrent.isNotPlayable)
    }
}
