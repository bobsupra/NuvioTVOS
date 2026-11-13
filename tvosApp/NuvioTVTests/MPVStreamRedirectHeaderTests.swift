import XCTest
@testable import NuvioTV

/// MPV's URLSession bridge must apply the same redirect policy as the Aether cache:
/// add-on headers stay on the source's origin and are dropped for another host.
final class MPVStreamRedirectHeaderTests: XCTestCase {
    private let sourceURL = URL(string: "https://addon.example/stream/video.mkv")!
    private let headers = ["Authorization": "Bearer addon-token", "X-Addon-Key": "secret"]

    private final class RefusingURLProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
        override func stopLoading() {}
    }

    private func redirect(to destination: URL) throws -> URLRequest? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RefusingURLProtocol.self]
        let session = try XCTUnwrap(MPVStreamSession(url: sourceURL, headers: headers, sessionConfiguration: configuration))
        defer { session.close() }

        var original = URLRequest(url: sourceURL)
        original.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        headers.forEach { original.setValue($1, forHTTPHeaderField: $0) }
        let task = URLSession(configuration: configuration).dataTask(with: original)

        var followed = original
        followed.url = destination
        let response = try XCTUnwrap(HTTPURLResponse(url: sourceURL, statusCode: 302, httpVersion: nil, headerFields: ["Location": destination.absoluteString]))

        var result: URLRequest?
        session.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: followed) { result = $0 }
        return result
    }

    func testCrossOriginRedirectDropsAddonHeadersAndKeepsRange() throws {
        let request = try XCTUnwrap(redirect(to: URL(string: "https://cdn.example/file.mkv")!))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Addon-Key"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-1023")
    }

    func testSameOriginRedirectKeepsAddonHeaders() throws {
        let request = try XCTUnwrap(redirect(to: URL(string: "https://addon.example/other/video.mkv")!))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer addon-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Addon-Key"), "secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-1023")
    }
}
