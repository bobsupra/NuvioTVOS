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
        XCTAssertThrowsError(try IPTVPlaylistParser(string: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000\nvariant.m3u8").parse()) {
            XCTAssertEqual($0 as? IPTVPlaylistParser.ParserError, .hlsPlaylist)
        }
        XCTAssertThrowsError(try IPTVPlaylistParser(string: "#EXTM3U\n#ext-x-endlist").parse()) {
            XCTAssertEqual($0 as? IPTVPlaylistParser.ParserError, .hlsPlaylist)
        }
        XCTAssertThrowsError(try IPTVPlaylistParser(string: "not a playlist").parse())
    }

    func testIgnoresCustomExtXMetadataTagsSuchAsEPGeniusCredentials() throws {
        let input = """
        #EXTM3U url-tvg="https://example.test/epg.xml.gz"
        #EXT-X-CREDENTIALS:[{"provider": "strong", "dns": "example.test", "username": "u", "password": "p"}]
        #EXT-X-SESSION-DATA:DATA-ID="com.example.meta",VALUE="curated"
        #EXTINF:0 CUID="0" tvg-name="BBC One" tvg-id="bbcone.uk" group-title="UK",BBC One
        https://example.test/live/u/p/1.ts
        """
        let playlist = try XCTUnwrap(IPTVPlaylistParser(string: input).parse().first)
        XCTAssertEqual(playlist.tvgURL, "https://example.test/epg.xml.gz")
        XCTAssertEqual(playlist.streams.count, 1)
        XCTAssertEqual(playlist.streams[0].title, "BBC One")
        XCTAssertEqual(playlist.streams[0].tvgID, "bbcone.uk")
        XCTAssertEqual(playlist.streams[0].groupTitle, "UK")
        XCTAssertEqual(playlist.streams[0].url, "https://example.test/live/u/p/1.ts")
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

    func testEnforcesStreamAndPlaylistBlockBudgets() {
        let tooManyStreams = "#EXTM3U\n#EXTINF:-1,One\nhttps://example.test/1\n#EXTINF:-1,Two\nhttps://example.test/2"
        XCTAssertThrowsError(try IPTVPlaylistParser(string: tooManyStreams).parse(maximumItems: 1)) {
            XCTAssertEqual($0 as? IPTVPlaylistParser.ParserError, .tooLarge)
        }

        XCTAssertThrowsError(try IPTVPlaylistParser(string: "#EXTM3U\n#EXTM3U\n").parse(maximumItems: 1)) {
            XCTAssertEqual($0 as? IPTVPlaylistParser.ParserError, .tooLarge)
        }
    }
}
