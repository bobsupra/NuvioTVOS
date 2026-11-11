import XCTest
@testable import NuvioTV

final class IPTVXtreamClientTests: XCTestCase {
    func testAPIURLPreservesServerPathPortAndEscapesCredentials() throws {
        let credentials = IPTVXtreamCredentials(server: URL(string: "https://example.test:8443/provider")!, username: "user&one", password: "p=a/ss")
        let url = try XCTUnwrap(IPTVXtreamClient.apiURL(credentials: credentials, action: "get_live_streams"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.port, 8443)
        XCTAssertEqual(parts.path, "/provider/player_api.php")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "username" })?.value, "user&one")
        XCTAssertEqual(parts.queryItems?.first(where: { $0.name == "password" })?.value, "p=a/ss")
        let guide = try XCTUnwrap(IPTVXtreamClient.guideURL(credentials: credentials))
        let guideParts = try XCTUnwrap(URLComponents(url: guide, resolvingAgainstBaseURL: false))
        XCTAssertEqual(guideParts.path, "/provider/xmltv.php")
        XCTAssertEqual(guideParts.queryItems?.first(where: { $0.name == "password" })?.value, "p=a/ss")
    }

    func testLiveURLKeepsCredentialsInsidePathComponents() throws {
        let credentials = IPTVXtreamCredentials(server: URL(string: "https://example.test/base")!, username: "user/name", password: "p?word")
        let url = try XCTUnwrap(IPTVXtreamClient.liveURL(credentials: credentials, streamID: "42"))
        XCTAssertEqual(url.absoluteString, "https://example.test/base/live/user%2Fname/p%3Fword/42.ts")
        XCTAssertNil(IPTVXtreamClient.liveURL(credentials: credentials, streamID: "../other"))
        let hls = IPTVXtreamCredentials(server: credentials.server, username: credentials.username, password: credentials.password, output: .hls)
        XCTAssertEqual(IPTVXtreamClient.liveURL(credentials: hls, streamID: "42")?.pathExtension, "m3u8")
    }

    func testRejectsInvalidServerOrMissingCredentials() {
        let server = URL(string: "https://example.test/?token=abc")!
        let credentials = IPTVXtreamCredentials(server: server, username: "user", password: "password")
        XCTAssertNil(IPTVXtreamClient.apiURL(credentials: credentials, action: nil))
        XCTAssertNil(IPTVXtreamClient.liveURL(credentials: credentials, streamID: "1"))
    }

    func testAccountRedirectRejectsAnotherOrigin() throws {
        let source = try XCTUnwrap(URL(string: "https://example.test/player_api.php?username=fixture"))
        let destination = try XCTUnwrap(URL(string: "https://other.test/player_api.php"))
        let task = URLSession.shared.dataTask(with: source)
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil))
        var returned: URLRequest?
        IPTVAuthenticatedSession.RedirectGuard().urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: destination)) { returned = $0 }
        XCTAssertNil(returned)
    }
}
