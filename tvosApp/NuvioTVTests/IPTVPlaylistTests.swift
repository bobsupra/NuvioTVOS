import XCTest
@testable import NuvioTV

final class IPTVPlaylistTests: XCTestCase {
    func testPlaylistAndChannelAttributes() throws {
        let input = """
        #EXTM3U url-tvg="https://example.test/guide.xml"
        #EXTINF:-1 tvg-id=news.id group-title="News, World" tvg-name="News",News One
        https://example.test/channel.m3u8?token=fixture
        """
        let playlist = try XCTUnwrap(IPTVPlaylistParser(string: input).parse().first)
        XCTAssertEqual(playlist.tvgURL, "https://example.test/guide.xml")
        XCTAssertEqual(playlist.streams.count, 1)
        XCTAssertEqual(playlist.streams[0].title, "News One")
        XCTAssertEqual(playlist.streams[0].groupTitle, "News, World")
        XCTAssertEqual(playlist.streams[0].tvgID, "news.id")
        XCTAssertEqual(playlist.streams[0].url, "https://example.test/channel.m3u8?token=fixture")
    }

    func testRejectsHLSAndInvalidHeader() {
        XCTAssertThrowsError(try IPTVPlaylistParser(string: "#EXTM3U\n#EXT-X-TARGETDURATION:10\nsegment.ts").parse()) {
            XCTAssertEqual($0 as? IPTVPlaylistParser.ParserError, .hlsPlaylist)
        }
        XCTAssertThrowsError(try IPTVPlaylistParser(string: "not a playlist").parse())
    }

    func testSkipsUnpairedEntriesAndPreservesPlaylistOrder() throws {
        let input = """
        \u{FEFF}#EXTM3U
        #EXTINF:-1,First
        https://example.test/one
        #EXTINF:-1,Orphaned
        #EXTINF:-1,Second
        https://example.test/two
        """
        let playlist = try XCTUnwrap(IPTVPlaylistParser(string: input).parse().first)
        XCTAssertEqual(playlist.streams.map(\.title), ["First", "Second"])
    }

    func testAttributesAllowWhitespaceAndDoNotStripInteriorUnicode() throws {
        let input = "#EXTM3U\n#EXTINF:-1 TVG-ID = \"guide\",Canal\u{feff} Uno\nhttps://example.test/live"
        let stream = try XCTUnwrap(IPTVPlaylistParser(string: input).parse().first?.streams.first)
        XCTAssertEqual(stream.tvgID, "guide")
        XCTAssertEqual(stream.title, "Canal\u{feff} Uno")
    }

    func testLargePlaylistKeepsEveryChannelInOrder() throws {
        let lines = (0..<5_000).map { "#EXTINF:-1,Channel \($0)\nhttps://example.test/\($0)" }
        let playlist = try XCTUnwrap(IPTVPlaylistParser(string: "#EXTM3U\n" + lines.joined(separator: "\n")).parse().first)
        XCTAssertEqual(playlist.streams.count, 5_000)
        XCTAssertEqual(playlist.streams.first?.title, "Channel 0")
        XCTAssertEqual(playlist.streams.last?.title, "Channel 4999")
    }
}
