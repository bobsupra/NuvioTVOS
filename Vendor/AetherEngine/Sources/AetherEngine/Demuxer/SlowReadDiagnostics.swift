import Foundation

/// One-shot localization of a pathologically slow `AVIOReader.read()` call (#93 restart latency).
///
/// rrgomes' LAN trace: a producer's first post-restart read waits 19-46 s while a side reader's
/// read issued 19 s later completes in 300 ms, against a source that answers range requests in
/// milliseconds. The wait is client-side, but which branch of the persistent read loop eats the
/// time (detour fetch queueing, connStallTimeout waits, reconnect backoff, stale-generation data
/// drops) is invisible in the standard log. The read loop accumulates counters into this struct
/// and emits ONE summary line when the whole read exceeded the threshold, so a single device
/// trace answers where the time went. A slow read with all-zero counters is itself a finding:
/// the wait was upstream of the loop (seek, scheduling), not inside it.
struct SlowReadDiagnostics {
    let thresholdMs: Double

    private(set) var detourServes = 0
    private(set) var detourFetches = 0
    private(set) var detourMs: Double = 0
    private(set) var stallWaits = 0
    private(set) var stallWaitMs: Double = 0
    private(set) var stallWaitsSignaled = 0
    private(set) var tailWaits = 0
    private(set) var tailWaitMs: Double = 0
    private(set) var reconnects = 0
    private(set) var backoffMs: Double = 0
    private(set) var staleGenDroppedBytes: Int64 = 0
    private(set) var iterations = 0
    // #93/#96 residual: the two branches the "empty counters" case pointed at but that were never
    // timed. lockWaitMs = time the loop head spent ACQUIRING winCond (a delegate thread holding it
    // across a copy/backpressure window blocks the read here, invisibly). connectMs = time inside the
    // synchronous reconnect/connect path on the demux thread (seekReconnect + startPersistentConnection,
    // incl. the old session's invalidateAndCancel). Whichever eats the ~15-35s finally lands on a name.
    private(set) var lockWaitMs: Double = 0
    private(set) var connectMs: Double = 0

    init(thresholdMs: Double = 2000) {
        self.thresholdMs = thresholdMs
    }

    /// One pass of the read loop. Separates a single blocked call (few iterations, large
    /// unaccounted time) from a spin (many iterations) when the recorded counters are near zero.
    mutating func recordIteration() {
        iterations += 1
    }

    mutating func recordDetourServe(ms: Double, fetched: Bool) {
        detourServes += 1
        if fetched { detourFetches += 1 }
        detourMs += ms
    }

    /// A detour block fetch that did NOT serve (a cache miss or a rate-limited attempt) still spent
    /// time crossing the network. #93/#96 root cause hid here: only `recordDetourServe` timed the
    /// detour path, so a starved backward-scrub fetch that rode its 15-35s budget and then MISSED
    /// left that time in `unaccounted`, reading as an unlocalized wait. Recording the attempt keeps
    /// the time out of `unaccounted` and renders it as a fetch with zero serves (e.g. `detour=0(15000ms,1fetch)`).
    mutating func recordDetourFetchAttempt(ms: Double) {
        detourFetches += 1
        detourMs += ms
    }

    /// #281 retest: time spent waiting for the speculative tail fetch to land instead of opening a
    /// connection past it. Its own counter rather than a stall wait: a stall is the source failing to
    /// deliver, this is the reader declining to duplicate a request that is already outstanding, and
    /// a trace that cannot tell them apart reads the second as the first.
    mutating func recordTailWait(ms: Double) {
        tailWaits += 1
        tailWaitMs += ms
    }

    mutating func recordStallWait(ms: Double, signaled: Bool) {
        stallWaits += 1
        stallWaitMs += ms
        if signaled { stallWaitsSignaled += 1 }
    }

    mutating func recordReconnect() {
        reconnects += 1
    }

    mutating func recordBackoff(ms: Double) {
        backoffMs += ms
    }

    mutating func recordStaleGenerationDrop(bytes: Int64) {
        staleGenDroppedBytes += bytes
    }

    mutating func recordLockWait(ms: Double) {
        lockWaitMs += ms
    }

    mutating func recordConnect(ms: Double) {
        connectMs += ms
    }

    /// #377: how the origin's shared request budget stood when this read finished. A slow read is
    /// exactly when the question "how many requests were we holding against this origin" matters,
    /// and it was unanswerable from outside the engine: the four URLSession pools each report their
    /// own cap and none reports the sum. `peak` is the highest concurrency this origin has been
    /// given all session, which is the number a metered origin was reacting to.
    ///
    /// `refusals` is session-cumulative for the origin, and now says so in the field. Every other
    /// number on a slow-read line belongs to that one read, so a bare `refusals=28` reads as this
    /// read's: the #377 reporter read three windows of 7, 14 and 28 as a meter tightening rather
    /// than as increments of 7, 7 and 14, which is three whole ladders hitting their give-up cap.
    /// Same numbers, opposite diagnosis. The suffix costs five characters.
    struct OriginBudgetLine {
        let inflight: Int
        let peak: Int
        let limit: Int?
        let refusals: Int

        var text: String {
            "origin=\(inflight)inflight/\(peak)peak"
                + " limit=\(limit.map(String.init) ?? "none")"
                + (refusals > 0 ? " refusals=\(refusals)total" : "")
        }
    }

    /// The summary line for a completed read, or nil while under the threshold.
    func line(elapsedMs: Double, offset: Int64, generationSpan: (Int, Int),
              origin: OriginBudgetLine? = nil) -> String? {
        guard elapsedMs >= thresholdMs else { return nil }
        // Time not attributable to any recorded branch: the read was blocked upstream of the loop
        // (fresh-connection first byte, a starved detour fetch not yet timed out, scheduling). This
        // is the #93/#96 residual's signature, so surfacing it turns "empty counters" into a number.
        let unaccounted = max(0, elapsedMs - stallWaitMs - detourMs - backoffMs - lockWaitMs
                              - connectMs - tailWaitMs)
        return "[AVIOReader] slow read: \(Int(elapsedMs))ms at offset=\(offset) "
            + "detour=\(detourServes)(\(Int(detourMs))ms,\(detourFetches)fetch) "
            + "stallWaits=\(stallWaits)(\(Int(stallWaitMs))ms,\(stallWaitsSignaled)signaled) "
            + "tailWaits=\(tailWaits)(\(Int(tailWaitMs))ms) "
            + "reconnects=\(reconnects) backoff=\(Int(backoffMs))ms "
            + "lockWait=\(Int(lockWaitMs))ms connect=\(Int(connectMs))ms "
            + "staleGenDropped=\(staleGenDroppedBytes)b "
            + "iters=\(iterations) unaccounted=\(Int(unaccounted))ms "
            + "gen=\(generationSpan.0)->\(generationSpan.1)"
            + (origin.map { " \($0.text)" } ?? "")
    }
}
