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

        // #310 changed what "no re-fetch" looks like on the wire. A connection can now be
        // ENDED at winHighWater with the tail of its range undelivered, and the refill then
        // legitimately re-requests that undelivered tail — so REQUESTED spans may overlap a
        // cancelled predecessor's. What pins the #295 defect is direction: the refill and
        // every request after it start at the delivered frontier, which only moves forward,
        // while the defect's detour re-fetches fired at the READ position, below the refill
        // it had just issued. Strictly increasing request starts therefore hold exactly
        // when no delivered byte is asked for again.
        let starts = dataRanges(server, fileSize: total).map(\.start)
        #expect(starts.count >= 2, "the read never crossed a range boundary: \(starts)")
        var regressions: [String] = []
        for (a, b) in zip(starts, starts.dropFirst()) where b <= a {
            regressions.append("\(b) after \(a)")
        }
        #expect(regressions.isEmpty,
                "a request started at or below its predecessor, i.e. re-requested delivered bytes: \(regressions.joined(separator: ", ")); all starts: \(starts)")

        // Direction alone cannot price a re-fetch, and the defect was priced: 1506918 bytes
        // delivered for a 764450 byte object, 1.97x what was read. Count it on the READER
        // side, not the origin's: bytes the origin wrote into a socket we then cancelled were
        // never delivered, so `bytesWritten` would make a healthy high-water end look like a
        // re-fetch. What the reader accepted, minus what the consumer read, is exactly the
        // resident window plus whatever is in flight. Measured margin on this fixture is the 64 KB
        // tail probe; the 2 MB slack is set so one 4 MB detour block, the defect's unit of
        // re-fetch, still fails it.
        let overRead = reader.cumulativeBytesFetched - read
        let resident = Int64(reader.windowDiagnostics.aheadBytes)
        #expect(overRead <= resident + 2 * 1024 * 1024,
                "the reader accepted \(overRead / (1024 * 1024)) MB beyond the \(read / (1024 * 1024)) MB consumed, with only \(resident / (1024 * 1024)) MB resident: bytes were fetched twice")
    }
}
