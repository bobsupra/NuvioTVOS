import XCTest
@testable import AetherEngine

final class HTTPSubtitleDecodeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var cannedResponses: [String: (status: Int, headers: [String: String], body: Data)] = [:]
    nonisolated(unsafe) static var lastReceivedHeaders: [String: String] = [:]

    static func reset() {
        cannedResponses.removeAll()
        lastReceivedHeaders.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url?.absoluteString else { return false }
        return cannedResponses[url] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let urlStr = request.url?.absoluteString ?? ""
        Self.lastReceivedHeaders = request.allHTTPHeaderFields ?? [:]
        guard let canned = Self.cannedResponses[urlStr] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: canned.status,
            httpVersion: "HTTP/1.1",
            headerFields: canned.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: canned.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HTTPSubtitleDecodeTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        URLProtocol.registerClass(HTTPSubtitleDecodeURLProtocol.self)
    }

    override class func tearDown() {
        URLProtocol.unregisterClass(HTTPSubtitleDecodeURLProtocol.self)
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        HTTPSubtitleDecodeURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPSubtitleDecodeURLProtocol.self]
        SidecarTextFetch.customSession = URLSession(configuration: config)
    }

    override func tearDown() {
        SidecarTextFetch.customSession = nil
        super.tearDown()
    }

    func testHTTPSubtitleDecodeSuccess() async throws {
        let srtContent = """
        1
        00:00:01,000 --> 00:00:04,000
        Hello from HTTP subtitle!

        2
        00:00:05,000 --> 00:00:08,000
        Second subtitle line
        """
        let url = URL(string: "https://subtitles.test/movie.srt")!
        HTTPSubtitleDecodeURLProtocol.cannedResponses[url.absoluteString] = (
            status: 200,
            headers: ["Content-Type": "text/plain"],
            body: srtContent.data(using: .utf8)!
        )

        let result = try await SubtitleDecoder.decodeFile(
            url: url,
            httpHeaders: ["X-Custom-Header": "TestValue"]
        )

        XCTAssertEqual(result.cues.count, 2)
        XCTAssertEqual(result.cues[0].text, "Hello from HTTP subtitle!")
        XCTAssertEqual(result.cues[1].text, "Second subtitle line")

        let headers = HTTPSubtitleDecodeURLProtocol.lastReceivedHeaders
        XCTAssertEqual(headers["X-Custom-Header"], "TestValue")
        XCTAssertNotNil(headers["User-Agent"])
    }

    func testHTTPSubtitleDecodeHTTP404Throws() async throws {
        let url = URL(string: "https://subtitles.test/missing.srt")!
        HTTPSubtitleDecodeURLProtocol.cannedResponses[url.absoluteString] = (
            status: 404,
            headers: [:],
            body: Data()
        )

        do {
            _ = try await SubtitleDecoder.decodeFile(url: url)
            XCTFail("Expected 404 to throw")
        } catch SubtitleDecoderError.httpStatus(let code) {
            XCTAssertEqual(code, 404)
        } catch SubtitleDecoderError.openFailed(let code) {
            XCTAssertEqual(code, 404)
        }
    }
}
