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

    func testEPGShareStationAliasIsOptInAndCountrySpecific() throws {
        let start = Date(timeIntervalSince1970: 1_794_312_000)
        let window = start..<start.addingTimeInterval(7_200)
        let xml = """
        <tv><programme channel="NRK1.Norway.(NO,nb-NO).no" start="20261110120000 +0000" stop="20261110130000 +0000"><title>NRK</title></programme><programme channel="NRK.Super.Norway.(NO,nb-NO).no" start="20261110130000 +0000" stop="20261110140000 +0000"><title>NRK Super</title></programme><programme channel="NRK1.Sweden.(SE,sv-SE).se" start="20261110120000 +0000" stop="20261110130000 +0000"><title>NRK Sweden</title></programme><programme channel="NRK1.Sweden.(SE,sv-SE).no" start="20261110120000 +0000" stop="20261110130000 +0000"><title>Wrong country suffix</title></programme></tv>
        """
        let ids: Set<String> = ["NRK1.no", "NRKSuper.no", "NRK1.se"]
        XCTAssertTrue(try IPTVXMLTV.parse(Data(xml.utf8), channelIDs: ids, window: window).isEmpty)
        let aliased = try IPTVXMLTV.parse(Data(xml.utf8), channelIDs: ids, window: window, allowEPGShareAliases: true)
        XCTAssertEqual(aliased.map(\.title), ["NRK", "NRK Sweden", "NRK Super"])
        XCTAssertEqual(aliased.map(\.channelID), ["NRK1.no", "NRK1.se", "NRKSuper.no"])
        let ambiguousIDs: Set<String> = ["NRK1.no", "nrk1.NO"]
        XCTAssertTrue(try IPTVXMLTV.parse(Data(xml.utf8), channelIDs: ambiguousIDs, window: window, allowEPGShareAliases: true).isEmpty)
    }
}
