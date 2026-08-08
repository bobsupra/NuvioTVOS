import Testing
import Foundation
@testable import AetherEngine

/// #295: a linear read that crosses a bounded-range boundary must not re-fetch what the origin
/// already delivered. The #220 frontier refill exists so the boundary is not a stall: it opens the
/// next range while bytes are still resident ahead of the read position. `startPersistentConnection`
/// then resets `winStart` to that frontier and drops the window, so the very next read sits BELOW
/// the new window start, takes the backward branch, and pulls the bytes it just discarded back over
/// the network one 4 MB detour block at a time, on the demux read thread.
///
/// The shape only appears when the consumer is SLOWER than the transfer, which is playback: the
/// range completes long before the window drains, so the refill fires with up to `winLowWater`
/// bytes still resident ahead of the read position. A test that reads flat out drains the window
/// as fast as it arrives, reaches the boundary with nothing undrained, and sees nothing.
@Suite("Range-boundary refetch (#295)")
struct Issue295RangeBoundaryRefetchTests {

    /// Every byte the data connection asks for, minus the #281 speculative tail probe (which sits
    /// at the very end of the file and is deliberately not range-sized).
    private func dataRanges(_ server: ThrottledOriginServer, fileSize: Int64) -> [(start: Int64, end: Int64?)] {
        server.requestedRanges.filter { $0.start < fileSize - 1 * 1024 * 1024 }
    }

    @Test("a linear read across a range boundary never re-requests a delivered byte")
    func linearReadDoesNotRefetchAcrossBoundary() async throws {
        let total: Int64 = 128 * 1024 * 1024
        let boundary: Int64 = 20 * 1024 * 1024
        // Fast origin, paced consumer: the transfer has to win the race for the refill to fire with
        // bytes still undrained, which is the field shape (media-rate consumption off a LAN source).
        let server = try #require(ThrottledOriginServer(totalSize: total, throttleUs: 1000))
        defer { server.stop() }
        // The boundary sits well past `headSpanMaxBytes`, so the retained file head cannot serve a
        // backward read for free and hide the defect.
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: boundary)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let chunk = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buf.deallocate() }

        var read: Int64 = 0
        while read < boundary + 6 * 1024 * 1024 {
            let n = reader.read(into: buf, size: Int32(chunk))
            #expect(n > 0, "read failed at offset \(read)")
            if n <= 0 { break }
            read += Int64(n)
            try? await Task.sleep(nanoseconds: 6_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        let ranges = dataRanges(server, fileSize: total)
        var overlaps: [String] = []
        var covered: [(Int64, Int64)] = []
        for r in ranges {
            let end = r.end ?? total - 1
            for c in covered where r.start <= c.1 && end >= c.0 {
                overlaps.append("[\(r.start)-\(end)] overlaps [\(c.0)-\(c.1)]")
            }
            covered.append((r.start, end))
        }
        #expect(overlaps.isEmpty,
                "delivered bytes were fetched again: \(overlaps.joined(separator: ", ")); all ranges: \(ranges)")
    }
}
