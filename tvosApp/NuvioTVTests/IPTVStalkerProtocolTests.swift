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

    func testRecognizedClientPathsResolveToLoadEndpointAndOtherPathsStayExplicit() throws {
        let cases = [
            ("https://example.test/stalker_portal/c", "/stalker_portal/server/load.php"),
            ("https://example.test/stalker_portal/c/", "/stalker_portal/server/load.php"),
            ("https://example.test/stalker_portal/c/index.html", "/stalker_portal/server/load.php"),
            ("https://example.test/stalker_portal/server/load.php", "/stalker_portal/server/load.php"),
            ("https://example.test/custom/portal.php", "/custom/portal.php")
        ]

        for (portal, expectedPath) in cases {
            let url = try XCTUnwrap(IPTVStalkerProtocol.requestURL(
                portal: try XCTUnwrap(URL(string: portal)), type: "stb", action: "handshake"))
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.path, expectedPath, portal)
        }

        let clientPortal = try XCTUnwrap(URL(string: "https://example.test/deploy/c/index.html"))
        XCTAssertEqual(IPTVStalkerProtocol.portalEndpoints(for: clientPortal).map(\.path), [
            "/deploy/server/load.php", "/deploy/c/portal.php", "/deploy/portal.php"
        ])
        let explicit = try XCTUnwrap(URL(string: "https://example.test/deploy/custom.php"))
        XCTAssertEqual(IPTVStalkerProtocol.portalEndpoints(for: explicit), [explicit])
        XCTAssertTrue(IPTVStalkerProtocol.shouldTryHandshakeFallback(after: IPTVStalkerError.httpStatus(404)))
        XCTAssertTrue(IPTVStalkerProtocol.shouldTryHandshakeFallback(after: IPTVStalkerError.invalidResponse))
        XCTAssertFalse(IPTVStalkerProtocol.shouldTryHandshakeFallback(after: IPTVStalkerError.httpStatus(401)))
        XCTAssertFalse(IPTVStalkerProtocol.shouldTryHandshakeFallback(after: IPTVStalkerError.httpStatus(403)))
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

    func testPageReadsOptionalPaginationMetadata() throws {
        let row = #"{"id":"1","name":"News","cmd":"ffmpeg channel"}"#
        let tenRowsText = Array(repeating: row, count: 10).joined(separator: ",")
        let underfilledBody = "{\"js\":{\"data\":[\(tenRowsText)],\"total_items\":\"100\",\"max_page_items\":100}}"
        let underfilled = try IPTVStalkerProtocol.page(from: Data(underfilledBody.utf8))
        XCTAssertEqual(underfilled.totalItems, 100)
        XCTAssertNil(underfilled.lastPage)

        var pagination = IPTVStalkerPagination()
        XCTAssertFalse(pagination.didLoad(underfilled, number: 1))
        for pageNumber in 2...9 { XCTAssertFalse(pagination.didLoad(underfilled, number: pageNumber)) }
        XCTAssertTrue(pagination.didLoad(underfilled, number: 10))

        let explicit = try IPTVStalkerProtocol.page(from: Data("{\"js\":{\"data\":[\(row)],\"total_pages\":4}}".utf8))
        XCTAssertEqual(explicit.lastPage, 4)
        var explicitPagination = IPTVStalkerPagination()
        XCTAssertFalse(explicitPagination.didLoad(explicit, number: 3))
        XCTAssertTrue(explicitPagination.didLoad(explicit, number: 4))

        let legacy = try IPTVStalkerProtocol.page(from: Data("{\"js\":{\"data\":[\(row)]}}".utf8))
        XCTAssertNil(legacy.lastPage)
    }

    func testReadsBothCommonCategoryEnvelopes() throws {
        let array = Data(#"{"js":[{"id":"7","title":"News"}]}"#.utf8)
        let wrapped = Data(#"{"js":{"data":[{"id":7,"name":"News"}]}}"#.utf8)
        XCTAssertEqual(try IPTVStalkerProtocol.categoryNames(from: array)["7"], "News")
        XCTAssertEqual(try IPTVStalkerProtocol.categoryNames(from: wrapped)["7"], "News")
        XCTAssertThrowsError(try IPTVStalkerProtocol.categoryNames(from: Data(#"{"js":{}}"#.utf8)))
    }
}
