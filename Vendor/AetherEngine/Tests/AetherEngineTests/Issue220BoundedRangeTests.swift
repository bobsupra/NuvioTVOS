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
        // The claim is about the DATA connection, the one that streams playback bytes from the
        // read position. Since #281 an open also issues a small speculative tail fetch, which is
        // bounded too but deliberately not range-sized, so it is identified by its offset rather
        // than by being the first bounded request to arrive.
        let bounded = try #require(ranges.first(where: { $0.start == 0 && $0.end != nil }),
                                   "the data connection was open-ended: \(ranges)")
        #expect(bounded.end! - bounded.start + 1 == AVIOReader.persistentRangeBytes)
    }

    /// A range that has been delivered IN FULL clears `activeTask` exactly as a dropped one does,
    /// and the no-connection branch used to reconnect at the READ position regardless, which
    /// resets `winStart` and drops everything still resident. A consumer slower than the transfer
    /// therefore re-fetched what it had just been handed. Measured with aetherctl against a
    /// Range-logging origin: a 764450 B trailing `moov` cost three connections and 1.97x its own
    /// size in delivered bytes, one 256 KB AVIO buffer at a time.
    @Test("a completed range is read out of the window, not fetched again")
    func completedRangeIsNotRefetched() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        // A small first range so it completes long before the reader has consumed it, which is the
        // parse-pass shape: the transfer wins the race against the consumer.
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: 512 * 1024)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }
        _ = reader.read(into: buf, size: 64 * 1024)
        // Let the bounded range finish and its completion callback clear activeTask.
        for _ in 0..<100 where reader.hasLiveConnectionForTesting {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let requestsBefore = server.rangeRequestCount

        // Still inside the delivered range, so nothing here needs the network.
        #expect(reader.read(into: buf, size: 64 * 1024) == 64 * 1024)

        #expect(server.rangeRequestCount == requestsBefore,
                "a completed range was re-fetched instead of read: \(server.requestedRanges)")
    }

    /// A position at or past the last byte has nothing to connect for. The EOF decision used to sit
    /// below the reconnect, so this opened `bytes=<fileSize>-` first and took an empty 206 whose
    /// reconnect reset `winStart` past the end, dropping a window the parse was still reading.
    @Test("a read at the end of the file does not open a connection for it")
    func readAtEOFDoesNotConnect() async throws {
        let size: Int64 = 512 * 1024 * 1024
        let server = try #require(ThrottledOriginServer(totalSize: size))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        _ = reader.read(into: buf, size: 4096)
        let requestsBefore = server.rangeRequestCount

        #expect(reader.seek(offset: size, whence: SEEK_SET) == size)
        #expect(reader.read(into: buf, size: 4096) == FFmpegErr.eof)
        #expect(server.rangeRequestCount == requestsBefore,
                "a read at EOF opened a connection: \(server.requestedRanges)")
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
