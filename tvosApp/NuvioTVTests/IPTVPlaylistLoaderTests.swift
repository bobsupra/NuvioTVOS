import XCTest
@testable import NuvioTV

final class IPTVPlaylistLoaderTests: XCTestCase {
    private let base = URL(string: "https://example.test/redirected/list.m3u")!

    func testValidPlaylistUsesFinalURLForRelativeStreams() throws {
        let text = "#EXTM3U\n#EXTINF:-1,News\nchannel.m3u8"
        let channels = try IPTVPlaylistLoader.parse(data: Data(text.utf8), sourceID: "fixture", baseURL: base)
        XCTAssertEqual(channels.first?.streamURL.absoluteString, "https://example.test/redirected/channel.m3u8")
    }

    func testInvalidPlaylistAndEncodingAreErrorsRatherThanEmptyResults() {
        XCTAssertThrowsError(try IPTVPlaylistLoader.parse(data: Data("server error".utf8), sourceID: "fixture", baseURL: base))
        XCTAssertThrowsError(try IPTVPlaylistLoader.parse(data: Data([0xff]), sourceID: "fixture", baseURL: base)) {
            XCTAssertEqual($0 as? IPTVPlaylistLoadError, .invalidEncoding)
        }
    }

    func testAValidEmptyPlaylistRemainsValid() throws {
        XCTAssertTrue(try IPTVPlaylistLoader.parse(data: Data("#EXTM3U".utf8), sourceID: "fixture", baseURL: base).isEmpty)
    }

    func testPlaylistGuideURLIsResolvedAndInvalidGuideIsIgnored() throws {
        let input = #"#EXTM3U url-tvg="guide.xml""#
        let result = try IPTVPlaylistLoader.parsePlaylist(data: Data(input.utf8), sourceID: "fixture", baseURL: base)
        XCTAssertEqual(result.guideURL?.absoluteString, "https://example.test/redirected/guide.xml")
        let invalid = #"#EXTM3U url-tvg="file:///tmp/guide.xml""#
        XCTAssertNil(try IPTVPlaylistLoader.parsePlaylist(data: Data(invalid.utf8), sourceID: "fixture", baseURL: base).guideURL)
    }

    func testPlaylistCollectsAndDeduplicatesAllGuideFeedsInHeaderOrder() throws {
        let input = #"#EXTM3U url-tvg="guide.xml, https://feeds.example/a.xml, file:///tmp/no.xml" x-tvg-url="https://feeds.example/a.xml, /second.xml, https://feeds.example/b.xml""#
        let result = try IPTVPlaylistLoader.parsePlaylist(data: Data(input.utf8), sourceID: "fixture", baseURL: base)
        XCTAssertEqual(result.guideURLs.map(\.absoluteString), [
            "https://example.test/redirected/guide.xml",
            "https://feeds.example/a.xml",
            "https://example.test/second.xml",
            "https://feeds.example/b.xml"
        ])
        XCTAssertEqual(result.guideURL, result.guideURLs.first)
    }

    func testMissingSourceAndOversizedPayloadAreRejected() {
        XCTAssertThrowsError(try IPTVPlaylistLoader.parse(data: Data("#EXTM3U".utf8), sourceID: " ", baseURL: base)) {
            XCTAssertEqual($0 as? IPTVPlaylistLoadError, .invalidSourceID)
        }
        let tooLarge = Data(count: IPTVPlaylistLoader.maximumBytes + 1)
        XCTAssertThrowsError(try IPTVPlaylistLoader.parse(data: tooLarge, sourceID: "fixture", baseURL: base)) {
            XCTAssertEqual($0 as? IPTVPlaylistLoadError, .tooLarge)
        }
    }

    func testBoundedDataDownloaderAssemblesChunksEnforcesLimitAndPreservesRedirectGuard() async throws {
        final class MockURLProtocol: URLProtocol, @unchecked Sendable {
            static let lock = NSLock()
            nonisolated(unsafe) static var handler: ((URLRequest, URLProtocolClient, URLProtocol) -> Void)?

            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

            override func startLoading() {
                let handler = Self.lock.withLock { Self.handler }
                guard let client, let handler else { return }
                handler(request, client, self)
            }

            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let origin = try XCTUnwrap(URL(string: "https://example.test/portal"))
        let session = URLSession(configuration: config, delegate: IPTVStalkerRedirectGuard(portal: origin), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        // 1. Multi-chunk successful download
        MockURLProtocol.lock.withLock {
            MockURLProtocol.handler = { request, client, proto in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(proto, didLoad: Data("hello ".utf8))
                client.urlProtocol(proto, didLoad: Data("world".utf8))
                client.urlProtocolDidFinishLoading(proto)
            }
        }
        let ok = try await IPTVBoundedDataDownloader.download(URLRequest(url: origin), in: session, maximumBytes: 64)
        XCTAssertEqual(String(data: ok.data, encoding: .utf8), "hello world")
        XCTAssertEqual(ok.httpResponse.statusCode, 200)

        // 2. Chunked stream exceeding limit throws tooLarge
        MockURLProtocol.lock.withLock {
            MockURLProtocol.handler = { request, client, proto in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                client.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(proto, didLoad: Data(repeating: 0x41, count: 8))
                client.urlProtocol(proto, didLoad: Data(repeating: 0x42, count: 8))
                client.urlProtocolDidFinishLoading(proto)
            }
        }
        do {
            _ = try await IPTVBoundedDataDownloader.download(URLRequest(url: origin), in: session, maximumBytes: 12)
            XCTFail("Expected tooLarge error")
        } catch let error as IPTVBoundedDownloadError {
            XCTAssertEqual(error, .tooLarge)
        }

        // 3. Non-2xx status throws httpStatus
        MockURLProtocol.lock.withLock {
            MockURLProtocol.handler = { request, client, proto in
                let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
                client.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocolDidFinishLoading(proto)
            }
        }
        do {
            _ = try await IPTVBoundedDataDownloader.download(URLRequest(url: origin), in: session, maximumBytes: 64)
            XCTFail("Expected httpStatus(403)")
        } catch let error as IPTVBoundedDownloadError {
            XCTAssertEqual(error, .httpStatus(403))
        }

        // 4. Cross-origin redirect is blocked by session's IPTVStalkerRedirectGuard
        let otherOrigin = try XCTUnwrap(URL(string: "https://other.test/leak"))
        MockURLProtocol.lock.withLock {
            MockURLProtocol.handler = { request, client, proto in
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 302,
                    httpVersion: nil,
                    headerFields: ["Location": otherOrigin.absoluteString]
                )!
                client.urlProtocol(proto, wasRedirectedTo: URLRequest(url: otherOrigin), redirectResponse: response)
                client.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocolDidFinishLoading(proto)
            }
        }
        do {
            _ = try await IPTVBoundedDataDownloader.download(URLRequest(url: origin), in: session, maximumBytes: 64)
            XCTFail("Expected 302 status after blocked redirect")
        } catch let error as IPTVBoundedDownloadError {
            XCTAssertEqual(error, .httpStatus(302))
        }
    }
}
