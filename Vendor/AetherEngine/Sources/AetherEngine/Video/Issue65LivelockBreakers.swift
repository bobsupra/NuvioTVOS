import Foundation

// Decision helpers for the loopback-HLS VOD scrub-burst livelock (issue #65). Both are pure so the
// false-positive guards (the only thing standing between a real wedge and a healthy slow seek) are
// unit-testable without spinning up an AVPlayer or a producer.

/// Stuck-detection for the VOD backpressure park (issue #65, Piece A).
///
/// The producer parks in `awaitBackpressureRelease` until the consumer's fetch high-water
/// (`SegmentCache.targetIndex`) reaches a release target. A genuine wedge is the consumer target
/// frozen for `breakThresholdSeconds` while AVPlayer is stuck and issuing no forward segment request;
/// a slow-but-advancing consumer (cold cache, throttled CDN) keeps nudging the target up and must
/// NEVER trip the breaker. Feed `observe(currentTarget:)` once per ~1 s poll: it resets the stuck
/// timer whenever the target advances, so only a target that is frozen for the whole window trips.
struct BackpressureWedgeDetector {
    let breakThresholdSeconds: Int
    /// #93 retest fast path: trip after this many consecutive polls where the fetch target AND the
    /// rendered clock are both frozen while the consumer wants to play. nil = fast path disabled.
    /// The dual freeze is what makes the short window safe: healthy steady-state playback freezes the
    /// target between segment fetches but advances the clock every poll; a post-seek decode ramp holds
    /// the clock but keeps prefetching (target advances). Only a consumer that neither renders nor
    /// fetches for the whole window is wedged.
    let fastBreakThresholdSeconds: Int?
    private var maxTargetSeen: Int
    private var stuckSeconds: Int = 0
    private var lastRenderedPosition: Double?
    private var flatSeconds: Int = 0
    /// Diagnostic: whether the last `true` from `observe` came from the fast path.
    private(set) var lastTripFast = false

    /// Rendered-clock deltas below this are aliasing/representation jitter, not playback progress
    /// (one poll second of real playback advances the clock by ~1 s).
    static let renderedClockFlatEpsilon: Double = 0.1

    init(breakThresholdSeconds: Int, fastBreakThresholdSeconds: Int? = nil,
         initialTarget: Int, initialRenderedPosition: Double? = nil) {
        self.breakThresholdSeconds = breakThresholdSeconds
        self.fastBreakThresholdSeconds = fastBreakThresholdSeconds
        self.maxTargetSeen = initialTarget
        self.lastRenderedPosition = initialRenderedPosition
    }

    /// Returns `true` once the consumer fetch target has been frozen for `breakThresholdSeconds`, or
    /// (fast path) once target and rendered clock have both been frozen for `fastBreakThresholdSeconds`.
    ///
    /// `wantsToPlay` is the play-intent guard (issue #65 pause false-positive). A paused or backgrounded
    /// consumer issues no forward segment request by design, so its frozen fetch target is NOT a wedge: when
    /// `wantsToPlay` is false the detector re-baselines to the current target and holds the stuck timer at
    /// zero, so a pause of any length never trips and the window after resume starts fresh. The legit wedge
    /// (AVPlayer wants to play but is starved, `timeControlStatus == .waitingToPlay`) keeps `wantsToPlay`
    /// true and still trips. Defaults to true so existing callers and live keep their prior behaviour.
    ///
    /// `renderedPosition` feeds the fast path; nil (not wired: tests, live) keeps it inert. Any move
    /// beyond the flat epsilon, forward or backward (a new seek landing), restarts the flat window.
    ///
    /// `hasStartedRendering` is the cold-startup guard: before AVPlayer has ever presented a frame
    /// (`timeControlStatus` never reached `.playing`), a flat rendered clock is normal pre-roll, NOT a
    /// wedge, and the producer parks the instant it fills its forward window ahead of a consumer still
    /// evaluating buffering rate. A high-bitrate DV master over a slow link pre-rolls past the fast
    /// window, so tripping here re-anchors and nudge-flushes AVPlayer's forward buffer, restarting the
    /// pre-roll from zero forever ("loads forever"). Cold startup belongs to the #35 StartupReadinessGate;
    /// this detector is a mid-stream recovery tool (#93 backward-seek), so it suspends (re-baselines,
    /// like the paused case) until the first frame lands. Defaults true for existing callers, live, tests.
    mutating func observe(currentTarget: Int, wantsToPlay: Bool = true,
                          renderedPosition: Double? = nil, hasStartedRendering: Bool = true) -> Bool {
        guard wantsToPlay, hasStartedRendering else {
            if currentTarget > maxTargetSeen { maxTargetSeen = currentTarget }
            stuckSeconds = 0
            flatSeconds = 0
            if let rendered = renderedPosition { lastRenderedPosition = rendered }
            return false
        }
        let targetAdvanced = currentTarget > maxTargetSeen
        if targetAdvanced {
            maxTargetSeen = currentTarget
            stuckSeconds = 0
        } else {
            stuckSeconds += 1
        }
        var clockFlat = false
        if let rendered = renderedPosition {
            if let last = lastRenderedPosition {
                clockFlat = abs(rendered - last) < Self.renderedClockFlatEpsilon
            }
            lastRenderedPosition = rendered
        }
        if targetAdvanced || !clockFlat {
            flatSeconds = 0
        } else {
            flatSeconds += 1
        }
        if let fast = fastBreakThresholdSeconds, flatSeconds >= fast {
            lastTripFast = true
            return true
        }
        if stuckSeconds >= breakThresholdSeconds {
            lastTripFast = false
            return true
        }
        return false
    }
}

/// Starvation predicate for a seek that did not land within its deadline (issue #65, Piece B).
///
/// During a pending zero-tolerance loopback seek AVPlayer holds the old frame, so `renderedTime` is
/// flat whether the seek is healthy-but-slow or wedged; it cannot distinguish them. What does: a
/// healthy seek refills AVPlayer's forward buffer (`bufferedEnd` climbs past `renderedTime`), while a
/// wedged seek is starved (the producer is parked, so `bufferedEnd` stays at the rendered position,
/// matching the reporter's `loaded=[]`). Returns `true` only when there is effectively no forward
/// buffer, i.e. AVPlayer is starved rather than slow.
func seekIsWedged(renderedTime: Double, bufferedEnd: Double, forwardBufferFloor: Double = 1.0) -> Bool {
    return (bufferedEnd - renderedTime) < forwardBufferFloor
}

/// Single-resume latch for the deadline-bounded seek (issue #65). The AVPlayer landing and the deadline
/// race to resume one continuation; whichever calls `claim()` first wins, the loser is a no-op. MainActor
/// isolated (so it is Sendable and capturable in the @Sendable seek completion) and only touched there.
@MainActor
final class SeekResumeGuard {
    private var claimed = false
    /// Returns `true` exactly once, to the first caller.
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Thread-safe Double mirror so an off-main consumer (the producer pump re-anchoring on a wedge) can read
/// AVPlayer's last rendered position, which the engine updates on the main actor (issue #65).
final class AtomicDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ initial: Double) { value = initial }
    func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Double) { lock.lock(); value = newValue; lock.unlock() }
}

/// Thread-safe Double? mirror so the off-main wedge re-anchor can read the engine's pending recovery
/// seek target (#93 retest), which the engine sets/retires on the main actor. nil = no unlanded user
/// seek pending; the wedge re-anchor then falls back to AVPlayer's frozen position.
final class AtomicOptionalDouble: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double?
    init(_ initial: Double? = nil) { value = initial }
    func get() -> Double? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Double?) { lock.lock(); value = newValue; lock.unlock() }
}

/// Thread-safe Bool mirror so the off-main producer pump can read whether AVPlayer currently wants to play
/// (`timeControlStatus != .paused`), which the engine updates on the main actor. Lets the VOD backpressure
/// wedge detector suspend while the consumer is paused (issue #65 pause false-positive).
final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ initial: Bool) { value = initial }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}
