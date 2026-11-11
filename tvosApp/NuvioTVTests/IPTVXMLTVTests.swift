import XCTest
@testable import NuvioTV

final class IPTVXMLTVTests: XCTestCase {
    func testMatchesChannelsAndConvertsOffsets() throws {
        let xml = """
        <tv><programme channel="news" start="20261110120000 +0200" stop="20261110130000 +0200"><title>News &amp; Weather</title></programme><programme channel="other" start="20261110120000 +0200" stop="20261110130000 +0200"><title>Other</title></programme></tv>
        """
        let iso = ISO8601DateFormatter()
        let start = try XCTUnwrap(iso.date(from: "2026-11-10T09:00:00Z"))
        let end = try XCTUnwrap(iso.date(from: "2026-11-10T11:00:00Z"))
        let programmes = try IPTVXMLTV.parse(Data(xml.utf8), channelIDs: ["news"], window: start..<end)
        XCTAssertEqual(programmes.count, 1)
        XCTAssertEqual(programmes[0].title, "News & Weather")
        XCTAssertEqual(programmes[0].start, iso.date(from: "2026-11-10T10:00:00Z"))
    }

    func testRejectsMalformedXMLAndIgnoresInvalidProgrammes() throws {
        let window = Date(timeIntervalSince1970: 0)..<Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertThrowsError(try IPTVXMLTV.parse(Data("<tv>".utf8), channelIDs: ["a"], window: window))
        let xml = #"<tv><programme channel="a" start="bad" stop="bad"><title>Bad</title></programme></tv>"#
        XCTAssertTrue(try IPTVXMLTV.parse(Data(xml.utf8), channelIDs: ["a"], window: window).isEmpty)
    }
}
