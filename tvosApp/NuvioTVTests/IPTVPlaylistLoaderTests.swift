import XCTest
@testable import NuvioTV

final class IPTVPlaylistLoaderTests: XCTestCase {
    private let base = URL(string: "https://example.test/redirected/list.m3u")!

    func testValidPlaylistUsesFinalURLForRelativeStreams() throws {
        let text = "#EXTM3U\n#EXTINF:-1,News\nchannel.m3u8"
        let channels = try IPTVPlaylistLoader.parse(data: Data(text.utf8), sourceID: "fixture", baseURL: base)
        XCTAssertEqual(channels.first?.streamURL.absoluteString, "https://example.test/redirected/channel.m3u8")
    }

    func testInvalidPlaylistAndEncodingAreErrorsRatherThanEmptyResults() {
        XCTAssertThrowsError(try IPTVPlaylistLoader.parse(data: Data("server error".utf8), sourceID: "fixture", baseURL: base))
        XCTAssertThrowsError(try IPTVPlaylistLoader.parse(data: Data([0xff]), sourceID: "fixture", baseURL: base)) {
            XCTAssertEqual($0 as? IPTVPlaylistLoadError, .invalidEncoding)
        }
    }

    func testAValidEmptyPlaylistRemainsValid() throws {
        XCTAssertTrue(try IPTVPlaylistLoader.parse(data: Data("#EXTM3U".utf8), sourceID: "fixture", baseURL: base).isEmpty)
    }

    func testPlaylistGuideURLIsResolvedAndInvalidGuideIsIgnored() throws {
        let input = #"#EXTM3U url-tvg="guide.xml""#
        let result = try IPTVPlaylistLoader.parsePlaylist(data: Data(input.utf8), sourceID: "fixture", baseURL: base)
        XCTAssertEqual(result.guideURL?.absoluteString, "https://example.test/redirected/guide.xml")
        let invalid = #"#EXTM3U url-tvg="file:///tmp/guide.xml""#
        XCTAssertNil(try IPTVPlaylistLoader.parsePlaylist(data: Data(invalid.utf8), sourceID: "fixture", baseURL: base).guideURL)
    }

    func testMissingSourceAndOversizedPayloadAreRejected() {
        XCTAssertThrowsError(try IPTVPlaylistLoader.parse(data: Data("#EXTM3U".utf8), sourceID: " ", baseURL: base)) {
            XCTAssertEqual($0 as? IPTVPlaylistLoadError, .invalidSourceID)
        }
        let tooLarge = Data(count: IPTVPlaylistLoader.maximumBytes + 1)
        XCTAssertThrowsError(try IPTVPlaylistLoader.parse(data: tooLarge, sourceID: "fixture", baseURL: base)) {
            XCTAssertEqual($0 as? IPTVPlaylistLoadError, .tooLarge)
        }
    }
}
