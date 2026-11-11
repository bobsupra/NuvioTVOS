import XCTest
@testable import NuvioTV

final class IPTVChannelImporterTests: XCTestCase {
    func testResolvesRelativeURLsAndDoesNotExposeCredentialsInID() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 tvg-id="news" tvg-logo="logo.png" group-title="News",Channel
        live.m3u8?token=fixture-secret
        """
        let parsed = try IPTVPlaylistParser(string: input).parse()
        let channels = IPTVChannelImporter.channels(from: parsed, sourceID: "source-1", baseURL: URL(string: "https://example.test/list.m3u"))
        let channel = try XCTUnwrap(channels.first)
        XCTAssertEqual(channel.streamURL.absoluteString, "https://example.test/live.m3u8?token=fixture-secret")
        XCTAssertEqual(channel.logoURL?.absoluteString, "https://example.test/logo.png")
        XCTAssertEqual(channel.guideID, "news")
        XCTAssertFalse(channel.id.contains("fixture-secret"))
        XCTAssertEqual(channels, IPTVChannelImporter.channels(from: parsed, sourceID: "source-1", baseURL: URL(string: "https://example.test/list.m3u")))
        XCTAssertNotEqual(channel.id, IPTVChannelImporter.channels(from: parsed, sourceID: "source-2", baseURL: URL(string: "https://example.test/list.m3u")).first?.id)
    }

    func testIgnoresInvalidLinksAndDeduplicatesWithinSource() throws {
        let input = """
        #EXTM3U
        #EXTINF:-1 tvg-name="Fallback",
        https://example.test/one
        #EXTINF:-1,Fallback
        https://example.test/one
        #EXTINF:-1,Invalid
        file:///tmp/file
        #EXTINF:-1,Missing Base
        relative.m3u8
        """
        let parsed = try IPTVPlaylistParser(string: input).parse()
        let channels = IPTVChannelImporter.channels(from: parsed, sourceID: "a", baseURL: nil)
        XCTAssertEqual(channels.map(\.name), ["Fallback"])
        XCTAssertTrue(IPTVChannelImporter.channels(from: parsed, sourceID: " ", baseURL: nil).isEmpty)
    }

    func testProviderIdentitySurvivesCredentialAndMetadataChanges() throws {
        var first = IPTVPlaylistParser.Stream(title: "News", url: "https://example.test/live/user/old/42.ts", tvgLogo: nil, tvgID: nil, tvgName: nil, groupTitle: "Old")
        first.providerID = "42"
        var second = IPTVPlaylistParser.Stream(title: "News HD", url: "https://example.test/live/user/new/42.ts", tvgLogo: nil, tvgID: nil, tvgName: nil, groupTitle: "New")
        second.providerID = "42"
        func list(_ stream: IPTVPlaylistParser.Stream) -> [IPTVPlaylistParser.Playlist] {
            [IPTVPlaylistParser.Playlist(tvgURL: nil, imageURL: nil, xTvgURL: nil, tvgLogo: nil, streams: [stream])]
        }
        let old = try XCTUnwrap(IPTVChannelImporter.channels(from: list(first), sourceID: "source", baseURL: nil).first)
        let updated = try XCTUnwrap(IPTVChannelImporter.channels(from: list(second), sourceID: "source", baseURL: nil).first)
        XCTAssertEqual(old.id, updated.id)
    }
}
