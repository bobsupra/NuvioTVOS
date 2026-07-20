import Testing
import Foundation
@testable import AetherEngine

/// Issue #70 (Sodalite): AVIOReader.open() used to fire a dedicated probeFileSize()
/// round-trip (Range: bytes=0-0, falling back to HEAD) before opening the real data
/// connection, even though that connection's own 206 Content-Range already carries the
/// total. The redundant probe (and its HEAD fallback, the request that some origins 429)
/// is gone for the playback path: the size is derived from the first data-connection
/// response. These cover that derivation in isolation (no network).
struct AVIOReaderSizeProbeTests {

    private func response(_ status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.test/a.mkv")!,
                        statusCode: status, httpVersion: "HTTP/1.1",
                        headerFields: headers)!
    }

    @Test("206 Content-Range total is the size")
    func contentRange206() {
        let r = response(206, headers: ["Content-Range": "bytes 0-3/34960244736"])
        #expect(AVIOReader.sizeFromResponse(r, requestedOffset: 0) == 34_960_244_736)
    }

    @Test("206 with an unknown total (*) yields no size")
    func contentRangeStar() {
        let r = response(206, headers: ["Content-Range": "bytes 0-3/*"])
        #expect(AVIOReader.sizeFromResponse(r, requestedOffset: 0) == nil)
    }

    @Test("200 from offset 0 with Content-Length is the size (origin ignored Range)")
    func contentLength200FromZero() {
        let r = response(200, headers: ["Content-Length": "12345"])
        #expect(AVIOReader.sizeFromResponse(r, requestedOffset: 0) == 12345)
    }

    @Test("200 at a non-zero offset is not a usable size (server ignored Range, body from 0)")
    func contentLength200NonZeroOffset() {
        let r = response(200, headers: ["Content-Length": "12345"])
        #expect(AVIOReader.sizeFromResponse(r, requestedOffset: 4096) == nil)
    }

    @Test("206 Content-Range total wins over a partial Content-Length")
    func contentRangeBeatsContentLength() {
        let r = response(206, headers: ["Content-Range": "bytes 0-1048575/9999999999",
                                        "Content-Length": "1048576"])
        #expect(AVIOReader.sizeFromResponse(r, requestedOffset: 0) == 9_999_999_999)
    }

    @Test("A response with no length yields no size (chunked / streaming origin)")
    func noLength() {
        let r = response(200, headers: [:])
        #expect(AVIOReader.sizeFromResponse(r, requestedOffset: 0) == nil)
    }

    @Test("206 with an unknown (*) total never falls through to a partial Content-Length")
    func contentRangeStarWithPartialContentLength() {
        // The Content-Length here is the partial span (1 MB), NOT the file total. A 206 must
        // report no size rather than truncate fileSize to the span (issue #70 review #6).
        let r = response(206, headers: ["Content-Range": "bytes 0-1048575/*",
                                        "Content-Length": "1048576"])
        #expect(AVIOReader.sizeFromResponse(r, requestedOffset: 0) == nil)
    }

    @Test("206 with a malformed Content-Range reports no size, not the partial length")
    func contentRangeMalformedWithContentLength() {
        let r = response(206, headers: ["Content-Range": "garbage",
                                        "Content-Length": "1048576"])
        #expect(AVIOReader.sizeFromResponse(r, requestedOffset: 0) == nil)
    }
}
