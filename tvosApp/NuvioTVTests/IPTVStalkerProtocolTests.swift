import XCTest
@testable import NuvioTV

final class IPTVStalkerProtocolTests: XCTestCase {
    func testNormalizesMACAndRejectsInvalidCharacters() {
        XCTAssertEqual(IPTVStalkerProtocol.normalizedMAC("00-1a-79-01-02-03"), "00:1A:79:01:02:03")
        XCTAssertNil(IPTVStalkerProtocol.normalizedMAC("00:1A:79:01:02:ZZ"))
        XCTAssertNil(IPTVStalkerProtocol.normalizedMAC("00:1A"))
    }

    func testPortalQueryEncodesCommand() throws {
        let portal = URL(string: "https://example.test/stalker_portal/server/load.php")!
        let url = try XCTUnwrap(IPTVStalkerProtocol.requestURL(portal: portal, type: "itv", action: "create_link", extra: [URLQueryItem(name: "cmd", value: "ffmpeg http://example.test/a?x=1&y=2")]))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "cmd" })?.value, "ffmpeg http://example.test/a?x=1&y=2")
        XCTAssertNil(IPTVStalkerProtocol.requestURL(portal: URL(string: "https://example.test/load.php?existing=1")!, type: "itv", action: "handshake"))
    }

    func testParsesHandshakeAndValidatesResolvedPlaybackURL() throws {
        XCTAssertEqual(try IPTVStalkerProtocol.handshakeToken(from: Data(#"{"js":{"token":"fixture"}}"#.utf8)), "fixture")
        XCTAssertEqual(try IPTVStalkerProtocol.handshakeToken(from: Data(#"{"js":{"Token":"legacy"}}"#.utf8)), "legacy")
        XCTAssertThrowsError(try IPTVStalkerProtocol.handshakeToken(from: Data(#"{"js":{"token":""}}"#.utf8)))
        XCTAssertEqual(try IPTVStalkerProtocol.playbackURL(from: Data(#"{"js":{"cmd":"ffmpeg https://example.test/live"}}"#.utf8)).host, "example.test")
        XCTAssertThrowsError(try IPTVStalkerProtocol.playbackURL(from: Data(#"{"js":{"cmd":"file:///tmp/test"}}"#.utf8)))
    }

    func testParsesChannelsAndSkipsMalformedRows() throws {
        let body = #"{"js":{"data":[{"id":42,"name":"News","cmd":"ffmpeg channel"},{"id":"2","name":"Bad"},{"id":"42","name":"Duplicate","cmd":"other"}]}}"#
        let channels = try IPTVStalkerProtocol.channels(from: Data(body.utf8))
        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first?.id, "42")
        XCTAssertEqual(channels.first?.name, "News")
        XCTAssertThrowsError(try IPTVStalkerProtocol.channels(from: Data(#"{"js":{}}"#.utf8)))
    }

    func testRedirectOriginRequiresSameHostSchemeAndPort() throws {
        let original = try XCTUnwrap(URL(string: "https://example.test/portal"))
        XCTAssertTrue(IPTVStalkerRedirectGuard.sameOrigin(original, URL(string: "https://example.test:443/other")!))
        XCTAssertFalse(IPTVStalkerRedirectGuard.sameOrigin(original, URL(string: "https://other.test/portal")!))
        XCTAssertFalse(IPTVStalkerRedirectGuard.sameOrigin(original, URL(string: "http://example.test/portal")!))
        XCTAssertFalse(IPTVStalkerRedirectGuard.sameOrigin(original, URL(string: "https://example.test:8443/portal")!))
    }

    func testPlaybackCredentialsAreNotPassedToThePlayer() {
        let headers = IPTVStalkerClient.playbackHeaders()
        XCTAssertNil(headers["Authorization"])
        XCTAssertNil(headers["Cookie"])
    }

    func testEmptyPageIsDistinguishableFromMalformedRows() throws {
        let empty = try IPTVStalkerProtocol.page(from: Data(#"{"js":{"data":[]}}"#.utf8))
        XCTAssertEqual(empty.rawCount, 0)
        let malformed = try IPTVStalkerProtocol.page(from: Data(#"{"js":{"data":[{"id":"1"}]}}"#.utf8))
        XCTAssertEqual(malformed.rawCount, 1)
        XCTAssertTrue(malformed.channels.isEmpty)
    }

    func testReadsBothCommonCategoryEnvelopes() throws {
        let array = Data(#"{"js":[{"id":"7","title":"News"}]}"#.utf8)
        let wrapped = Data(#"{"js":{"data":[{"id":7,"name":"News"}]}}"#.utf8)
        XCTAssertEqual(try IPTVStalkerProtocol.categoryNames(from: array)["7"], "News")
        XCTAssertEqual(try IPTVStalkerProtocol.categoryNames(from: wrapped)["7"], "News")
        XCTAssertThrowsError(try IPTVStalkerProtocol.categoryNames(from: Data(#"{"js":{}}"#.utf8)))
    }
}
