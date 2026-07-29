// #243: an IOReader is driven from FFmpeg's read callback, which runs on a demux pump thread that
// stays inside one dispatch block for the whole session and therefore never drains its autorelease
// pool. Any response/read body the reader bridges out on that thread is stranded until the session
// ends, at the source's read rate (~30 MB/s on the reported remote UHD ISO, with three reader forks).
//
// The regression is measured, not asserted structurally: the reads run inside a pool the test owns,
// and the drop in malloc in-use across that pool's drain is what the caller's pool was holding. A
// reader that drains per read frees ~nothing there; the pre-fix readers freed the full byte count
// (verified by reverting the fix: 134.4 MB and 135.1 MB freed at the drain for 128 MB read).
// Measuring the drain rather than the loop keeps the check immune to allocations from tests running
// in parallel: concurrent allocation can only shrink the observed drop, never inflate it.
import Foundation
import Testing
@testable import AetherEngine

/// Serves byte ranges from its own static store. Deliberately not `MockRangeURLProtocol`: that one is
/// shared with the #64 suite, which resets it, and these tests must not race it.
final class RetentionRangeURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var bytesByURL: [String: Data] = [:]

    override class func canInit(with request: URLRequest) -> Bool {
        request.url.map { bytesByURL[$0.absoluteString] != nil } ?? false
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let data = Self.bytesByURL[url.absoluteString] else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let total = data.count
        var lower = 0, upper = total - 1, status = 200
        var headers = ["Content-Type": "application/octet-stream"]
        if let rv = request.value(forHTTPHeaderField: "Range"), rv.hasPrefix("bytes=") {
            let parts = rv.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            lower = Int(parts.first ?? "0") ?? 0
            upper = min((parts.count > 1 ? Int(parts[1]) : nil) ?? (total - 1), total - 1)
            status = 206
            headers["Content-Range"] = "bytes \(lower)-\(upper)/\(total)"
        }
        guard lower <= upper else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let body = data.subdata(in: lower..<(upper + 1))
        headers["Content-Length"] = String(body.count)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("#243 IOReader buffers do not strand in the caller's autorelease pool", .serialized)
struct Issue243ReaderRetentionTests {

    private static func mallocInUseBytes() -> Int64 {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int64(stats.size_in_use)
    }

    /// Bytes released when the pool the reads ran in is drained.
    private static func bytesHeldByCallerPool(bytesRead: inout Int64, _ readLoop: () -> Int64) -> Int64 {
        var beforeDrain: Int64 = 0
        var moved: Int64 = 0
        autoreleasepool {
            moved = readLoop()
            beforeDrain = mallocInUseBytes()
        }
        bytesRead = moved
        return max(0, beforeDrain - mallocInUseBytes())
    }

    /// A tenth of the bytes moved: far above the fixed-size noise of a pool drain, far below the
    /// one-leaked-byte-per-byte-read the defect produced.
    private static func assertDrained(held: Int64, moved: Int64, _ what: String) {
        #expect(held < moved / 10,
                "\(what): draining the caller's pool freed \(held / 1024 / 1024) MB after \(moved / 1024 / 1024) MB read; the reader is stranding its buffers there")
    }

    @Test("FileIOReader drains each read")
    func fileReaderDrainsPerRead() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("issue243-\(UUID().uuidString).bin")
        let chunk = 32 * 1024
        try Data(count: 8 * 1024 * 1024).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try #require(FileIOReader(url: url))
        defer { reader.close() }
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }

        var moved: Int64 = 0
        let held = Self.bytesHeldByCallerPool(bytesRead: &moved) {
            var total: Int64 = 0
            for i in 0..<4096 {                        // 4096 x 32 KB = 128 MB
                if i % 256 == 0 { _ = reader.seek(offset: 0, whence: SEEK_SET) }
                let n = reader.read(out, size: Int32(chunk))
                if n <= 0 { break }
                total += Int64(n)
            }
            return total
        }
        #expect(moved == 128 * 1024 * 1024)
        Self.assertDrained(held: held, moved: moved, "FileIOReader")
    }

    @Test("HTTPDiscIOReader drains each range request")
    func httpDiscReaderDrainsPerRequest() throws {
        let url = URL(string: "http://retention243.test/leak.iso")!
        let fixture = 4 * 1024 * 1024
        RetentionRangeURLProtocol.bytesByURL[url.absoluteString] = Data(count: fixture)
        defer { RetentionRangeURLProtocol.bytesByURL[url.absoluteString] = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetentionRangeURLProtocol.self]
        let reader = try #require(HTTPDiscIOReader(
            url: url, baseChunkSize: 1024 * 1024, maxChunkSize: 1024 * 1024,
            requestTimeout: 5, sessionConfiguration: config))
        defer { reader.close() }

        let chunk = 1024 * 1024
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { out.deallocate() }

        var moved: Int64 = 0
        let held = Self.bytesHeldByCallerPool(bytesRead: &moved) {
            var total: Int64 = 0
            for i in 0..<128 {                         // 128 x 1 MB fetched, 4 MB fixture cycled
                if i % 4 == 0 { _ = reader.seek(offset: 0, whence: SEEK_SET) }
                let n = reader.read(out, size: Int32(chunk))
                if n <= 0 { break }
                total += Int64(n)
            }
            return total
        }
        #expect(moved == 128 * 1024 * 1024)
        Self.assertDrained(held: held, moved: moved, "HTTPDiscIOReader")
    }

    @Test("The disc reader's fetch tally is session-scoped and counts every served range")
    func fetchTallyTracksServedBytes() throws {
        let url = URL(string: "http://retention243-tally.test/leak.iso")!
        RetentionRangeURLProtocol.bytesByURL[url.absoluteString] = Data(count: 1024 * 1024)
        defer { RetentionRangeURLProtocol.bytesByURL[url.absoluteString] = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RetentionRangeURLProtocol.self]
        HTTPDiscIOReader.resetLifetimeFetchedBytes()
        // Deltas, not absolutes: the tally is process-wide, and a reader in another suite may be
        // fetching in parallel. Concurrent fetches can only add to it.
        let atStart = HTTPDiscIOReader.lifetimeFetchedBytes
        let reader = try #require(HTTPDiscIOReader(
            url: url, baseChunkSize: 256 * 1024, maxChunkSize: 256 * 1024,
            requestTimeout: 5, sessionConfiguration: config))
        defer { reader.close() }

        // The size probe fetches one byte; four refills of 256 KB follow.
        let out = UnsafeMutablePointer<UInt8>.allocate(capacity: 256 * 1024)
        defer { out.deallocate() }
        var read = 0
        while read < 1024 * 1024 {
            let n = reader.read(out, size: Int32(256 * 1024))
            if n <= 0 { break }
            read += Int(n)
        }
        #expect(read == 1024 * 1024)
        // Four 256 KB refills plus the one-byte size probe from init.
        #expect(HTTPDiscIOReader.lifetimeFetchedBytes - atStart >= Int64(1024 * 1024 + 1))

        HTTPDiscIOReader.resetLifetimeFetchedBytes()
        #expect(HTTPDiscIOReader.lifetimeFetchedBytes < Int64(1024 * 1024))
    }
}
