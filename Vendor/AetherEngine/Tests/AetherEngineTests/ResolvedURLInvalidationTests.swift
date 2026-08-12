import Testing
import Foundation
@testable import AetherEngine

/// The reader pins the post-redirect URL after the first 200/206 (#12) and previously
/// dropped the pin only for auth-expiry statuses (401/403/404/410). An aggregator whose
/// redirect targets expire per connection answers every later range with a hard 5xx from
/// the pinned URL, and the reader hammered that dead URL forever instead of re-resolving
/// through the source URL for a fresh redirect.
///
/// `.serialized`: the rate-limit case mutates the process-wide backoff-scale test hook.
@Suite("Resolved-URL invalidation on hard server errors", .serialized)
struct ResolvedURLInvalidationTests {

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int64: Int] = [:]
        func next(for offset: Int64) -> Int {
            lock.lock(); defer { lock.unlock() }
            let n = (counts[offset] ?? 0) + 1
            counts[offset] = n
            return n
        }
    }

    @Test("a hard 500 from the pinned URL falls back to the source URL for a fresh redirect",
          .timeLimit(.minutes(2)))
    func hard500FallsBackToSourceURL() async throws {
        let firstRange: Int64 = 256 * 1024
        let attempts = AttemptCounter()
        // CDN: serves everything except the FIRST attempt at the boundary refill, which it
        // refuses with a hard 500 — the expired-redirect-target shape.
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange && attempts.next(for: offset) == 1
                    ? .status(500) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        // Source: redirects every request to the CDN, like an Xtream panel's 302 hop.
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = Int(firstRange) + 256 * 1024
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got == target, "read stopped at \(got) of \(target); the 500 was terminal")

        // The pin sent the refill straight to the CDN (first attempt, 500), and the fix
        // must send the RETRY through the source URL again — visible as a source-server
        // request at the boundary offset, which only exists if the pin was dropped.
        let sourceHitsAtBoundary = source.requestLog.filter { $0.start == firstRange }
        #expect(!sourceHitsAtBoundary.isEmpty,
                "retry never fell back to the source URL: \(source.requestLog)")
        let cdnAttemptsAtBoundary = cdn.requestLog.filter { $0.start == firstRange }.count
        #expect(cdnAttemptsAtBoundary >= 2,
                "the CDN should see the failed attempt plus the redirected retry")
    }

    /// The counterpart: a metered origin (429/503) must KEEP the pin. Dropping it sends the
    /// retry back through the source URL for a fresh redirect, which is a second request
    /// against the origin that is already refusing them, and on a connection-capped panel
    /// (#307) that is the request there is no room for.
    @Test("a rate-limited refill keeps the pin instead of re-resolving through the source",
          .timeLimit(.minutes(2)))
    func rateLimitedRefillKeepsThePin() async throws {
        AetherEngine.reconnectBackoffScaleForTesting = 0.02
        defer { AetherEngine.reconnectBackoffScaleForTesting = 1.0 }

        let firstRange: Int64 = 256 * 1024
        let attempts = AttemptCounter()
        // CDN: meters the first two attempts at the boundary refill, then serves.
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange && attempts.next(for: offset) <= 2
                    ? .status(503) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = Int(firstRange) + 256 * 1024
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got == target, "read stopped at \(got) of \(target); the 503s were terminal")

        let sourceHitsAtBoundary = source.requestLog.filter { $0.start == firstRange }
        #expect(sourceHitsAtBoundary.isEmpty,
                "a metered refill re-resolved through the source: \(source.requestLog)")
    }

    /// 509 "Bandwidth Limit Exceeded" is what a connection-capped panel answers while the
    /// slot the reader is REPLACING has not been torn down server-side yet. The slot frees
    /// in seconds and the pinned target is fine; dropping the pin sent every retry back
    /// through the portal — latency plus the one request there is no room for.
    @Test("a 509 refill keeps the pin instead of re-resolving through the source",
          .timeLimit(.minutes(2)))
    func connectionCappedRefillKeepsThePin() async throws {
        AetherEngine.reconnectBackoffScaleForTesting = 0.02
        defer { AetherEngine.reconnectBackoffScaleForTesting = 1.0 }

        let firstRange: Int64 = 256 * 1024
        let attempts = AttemptCounter()
        // CDN: the lingering-slot shape — 509 for the first two attempts at the boundary
        // refill, then the slot has freed and it serves.
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange && attempts.next(for: offset) <= 2
                    ? .status(509) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        let target = Int(firstRange) + 256 * 1024
        var got = 0
        while got < target {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got == target, "read stopped at \(got) of \(target); the 509s were terminal")

        let sourceHitsAtBoundary = source.requestLog.filter { $0.start == firstRange }
        #expect(sourceHitsAtBoundary.isEmpty,
                "a 509 refill re-resolved through the source: \(source.requestLog)")
    }

    /// An origin that answers 509 forever must get the PACED rate-limit ladder and its
    /// bounded give-up — not the hard-5xx treatment (pin dropped every attempt, retries
    /// through the portal at zero backoff until the unproductive cap).
    @Test("a permanent 509 pays the rate-limit ladder and gives up cleanly",
          .timeLimit(.minutes(2)))
    func permanent509TakesTheRateLimitLadder() async throws {
        AetherEngine.reconnectBackoffScaleForTesting = 0.02
        defer { AetherEngine.reconnectBackoffScaleForTesting = 1.0 }

        let firstRange: Int64 = 256 * 1024
        let cdnMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, offset, _ in
                offset == firstRange ? .status(509) : .serve206
            }
        )
        let cdn = try #require(cdnMaybe)
        defer { cdn.stop() }
        let cdnPort = cdn.port
        let sourceMaybe = ThrottledOriginServer(
            totalSize: 64 * 1024 * 1024,
            respond: { _, _, _ in .redirect(to: "http://127.0.0.1:\(cdnPort)/cdn/movie.bin") }
        )
        let source = try #require(sourceMaybe)
        defer { source.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(source.port)/movie.bin")!,
                                boundedInitialFetch: firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let sliceCap = 128 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        while true {
            let n = reader.read(into: buf, size: Int32(sliceCap))
            if n <= 0 { break }
            got += Int(n)
        }
        #expect(got == Int(firstRange),
                "everything before the metered boundary must still be served (got \(got))")

        let boundaryAttempts = cdn.requestLog.filter { $0.start == firstRange }.count
        #expect(boundaryAttempts >= 2, "the ladder must retry a metered origin")
        #expect(boundaryAttempts <= 7,
                "509 must give up at the bounded rate-limit cap, not grind: \(boundaryAttempts) attempts")
        let sourceHitsAtBoundary = source.requestLog.filter { $0.start == firstRange }
        #expect(sourceHitsAtBoundary.isEmpty,
                "a metered origin must keep the pin throughout: \(source.requestLog)")
    }

    @Test("hard-server-error classification excludes rate limiting")
    func classifierExcludesRateLimiting() {
        #expect(AVIOReader.isResolvedHardServerError(500))
        #expect(AVIOReader.isResolvedHardServerError(502))
        #expect(AVIOReader.isResolvedHardServerError(504))
        #expect(!AVIOReader.isResolvedHardServerError(503), "503 is rate limiting (#71)")
        #expect(!AVIOReader.isResolvedHardServerError(429))
        #expect(!AVIOReader.isResolvedHardServerError(509),
                "509 is a connection-capped panel metering us (#307 follow-up)")
        #expect(!AVIOReader.isResolvedHardServerError(404), "auth expiry is its own class")
        #expect(!AVIOReader.isResolvedHardServerError(200))
        #expect(AVIOReader.isRateLimitStatus(429))
        #expect(AVIOReader.isRateLimitStatus(503))
        #expect(AVIOReader.isRateLimitStatus(509))
        #expect(!AVIOReader.isRateLimitStatus(500))
    }
}
