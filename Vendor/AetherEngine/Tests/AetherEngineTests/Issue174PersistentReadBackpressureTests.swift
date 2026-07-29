import Testing
import Foundation
@testable import AetherEngine

/// #174: the persistent reader applied backpressure by BLOCKING the URLSession delegate
/// callback until the consumer drained below winHighWater. Blocking the delegate has no
/// flow-control contract: whether the connection stops reading from the socket is a
/// transport implementation detail. Plain HTTP/1.1 happens to park after a few MB of
/// internal buffering, but the field crash (HTTPS origin, boringssl in the crashing
/// stack, iPadOS) shows the TLS/H2 path keeps pulling at line rate and buffers the
/// undelivered body in unbounded internal allocations (cold pages compress, then
/// EXC_RESOURCE at the jetsam limit). Real, contractual flow control is task
/// suspend/resume ("a task, while suspended, produces no network traffic"), the same
/// mechanism the streaming path already uses (streamHighWater / streamLowWater).
///
/// These tests run a loopback HTTP/1.1 origin that counts every body byte it manages to
/// write. The load-bearing assertion is the suspend state itself (the transport-agnostic
/// mechanism); the origin byte bound is the regression guard that catches a backpressure
/// removal without a replacement.
@Suite("AVIOReader persistent backpressure (#174)")
struct Issue174PersistentReadBackpressureTests {


    // MARK: - Tests

    @Test("stalled consumer parks the origin connection instead of buffering at line rate")
    func stalledConsumerParksOrigin() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Nobody consumes: the demux side is deliberately parked, the exact #174 shape
        // (muxer backpressured on SegmentCache high water, no read ever advances position).
        try await Task.sleep(for: .seconds(3))

        // Origin line rate here is ~50 MB/s. Without real flow control the origin keeps
        // serving (~150 MB in 3 s) into URLSession's internal buffering. With task-suspend
        // backpressure it parks at winHighWater plus socket/transport buffer slack.
        #expect(server.bytesWritten < 64 * 1024 * 1024,
                "origin served \(server.bytesWritten / (1024 * 1024)) MB into a stalled consumer")
        #expect(reader.persistentTaskIsSuspendedForTesting,
                "the persistent task must be suspended once the window exceeds winHighWater")
    }

    @Test("resuming consumption after a stall delivers fresh bytes (resume liveness)")
    func drainAfterStallResumesDelivery() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 256 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Stall long enough for the suspend to engage, then consume far more than the
        // window: delivery must keep flowing, which proves the task was resumed.
        try await Task.sleep(for: .seconds(2))

        let sliceCap = 256 * 1024
        let target = 48 * 1024 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        let deadline = Date().addingTimeInterval(30)
        while got < target && Date() < deadline {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got >= target, "only \(got / (1024 * 1024)) MB delivered after the stall")
    }

    @Test("teardown while suspended releases the task and does not hang")
    func teardownWhileSuspended() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        try reader.open()

        try await Task.sleep(for: .seconds(2))

        // Completing without a hang is the assertion; the suspended flag must be cleared
        // so the balanced resume-before-cancel actually happened.
        reader.markClosed()
        reader.close()
        #expect(!reader.persistentTaskIsSuspendedForTesting)
    }

    /// #220: bounded ranges cannot be exercised against an origin that ignores the range end.
    /// It would stream to EOF whatever was asked for, and every later assertion about window
    /// size or request count would be measuring the server's behaviour instead of the reader's.
    @Test("the test origin serves exactly the requested range and no more")
    func originHonoursFiniteRange() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: 512 * 1024 * 1024))
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
        request.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(data.count == 1024 * 1024)
        #expect(server.requestedRanges.first?.end == 1_048_575)
    }
}
