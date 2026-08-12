import Foundation

/// Process-wide monotonic allocator for the discriminators a frame-time consumer orders by (#314).
///
/// `NativeVideoFrameTime.epoch` and `SoftwareVideoFrameTime.generation` both carry the same rule: a
/// higher value retires every entry a consumer recorded under a lower one. A per-instance counter
/// satisfies that only inside one session. `load()` builds a fresh session (and, on the software path,
/// a fresh renderer), so the counter restarted at zero and the rule inverted across the seam: a
/// straggling report from the outgoing session outranked everything the incoming one would ever emit,
/// and a host that ordered by it dropped the whole new item rather than the stale entries.
///
/// Drawing the values process-wide restores the rule end to end. A superseded producer's last report
/// is always lower than the next session's first, so "higher retires, lower is stale" holds across a
/// load exactly as it does across a producer restart. It is an ordering guarantee, not a session
/// fence: a straggler can still land in a freshly reset table and be retired a moment later by the new
/// session's first report, which for a consumer whose lookup miss already means "not known yet, retry"
/// is a transient rather than a wrong mapping.
final class FrameTimeSequence: @unchecked Sendable {

    private let lock = NSLock()
    private var value: UInt64 = 0

    /// The next value. Strictly increasing, never zero, and shared by every caller of this instance.
    func next() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }
}
