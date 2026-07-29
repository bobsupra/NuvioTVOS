import Testing
import Foundation
@testable import AetherEngine

/// #220: the reader used to ask for `bytes=X-`, the whole rest of the file, and then regulate
/// the resulting flow by suspending the URLSession task. `suspend()` is advisory, so on a link
/// that never saturates the socket the transport keeps delivering and the window grows without
/// bound. Asking for a fixed amount at a time makes the overshoot impossible rather than caught:
/// the origin cannot send more than was requested.
@Suite("Bounded persistent ranges (#220)")
struct Issue220BoundedRangeTests {

    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
    }

    @Test("a VOD read asks for a bounded range, not the rest of the file")
    func vodRequestsBoundedRange() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256 * 1024)
        defer { buf.deallocate() }
        _ = reader.read(into: buf, size: 256 * 1024)

        let ranges = server.requestedRanges
        let bounded = try #require(ranges.first(where: { $0.end != nil }),
                                   "every VOD request was open-ended: \(ranges)")
        #expect(bounded.end! - bounded.start + 1 == AVIOReader.persistentRangeBytes)
    }

    /// The point of the whole change: a sequential read has to cross range boundaries without
    /// the window ever running dry, and without ever holding more than low water plus one range.
    @Test("a long sequential read crosses range boundaries without emptying the window")
    func refillKeepsWindowFed() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }

        let target = Int(AVIOReader.persistentRangeBytes) * 3
        var got = 0
        var peakWindow = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
            peakWindow = max(peakWindow, reader.windowDiagnostics.windowBytes)
        }

        #expect(got == target, "sequential read stopped early at \(got) of \(target)")
        #expect(server.rangeRequestCount >= 3, "expected one request per range")
        let ceiling = Int(AVIOReader.persistentRangeBytes) + 8 * 1024 * 1024
        let peakMB = peakWindow / (1024 * 1024)
        let ceilingMB = ceiling / (1024 * 1024)
        #expect(peakWindow <= ceiling, "window peaked at \(peakMB) MB against \(ceilingMB) MB")
    }

    /// A planned end is not a failure. The unproductive-reconnect streak exists to detect a dead
    /// source, and spending it on range boundaries would have `recordReconnectAndShouldGiveUp`
    /// kill the reader on a perfectly healthy link.
    @Test("a planned range end is not charged to the unproductive-reconnect streak")
    func plannedEndIsNotAFailure() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        let target = Int(AVIOReader.persistentRangeBytes) * 3
        while got < target {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(reader.unproductiveReconnectsForTesting == 0)
    }
}
