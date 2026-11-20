import Foundation
import AetherLibavformat

/// Abstraction over a custom-AVIO byte source attached to `AVFormatContext.pb`.
/// `AVIOReader` (HTTP) and `CustomIOReaderBridge` (custom `IOReader`) both conform.
protocol AVIOProvider: AnyObject {
    /// Allocated `AVIOContext`, valid between `open()` and `close()`.
    var context: UnsafeMutablePointer<AVIOContext>? { get }

    /// Bytes fetched since open (memory-probe use). Custom readers that do not
    /// track network I/O report 0.
    var cumulativeBytesFetched: Int64 { get }

    /// Forward-only sources report false; keeps them off the native seek path.
    var isSeekable: Bool { get }

    func open() throws

    /// Fast, allocation-free: unblock a suspended read so the demuxer's access
    /// lock can be acquired during teardown. Call before `close()`.
    func markClosed()

    /// #112 round 9: wall-clock deadline for reads, armed around a bounded positioning seek so an
    /// index-less container's read_timestamp binary search aborts instead of parking for minutes on a
    /// starved source. Checked between read callbacks (demux-thread-only, same contract as AVIOReader's
    /// #27 deadline); one in-flight blocking read can overshoot by its own transport timeout.
    func beginReadDeadline(secondsFromNow seconds: TimeInterval)

    /// Disarm the deadline armed by `beginReadDeadline`.
    func endReadDeadline()

    /// True when a read aborted because the deadline passed. Authoritative over the seek's return
    /// value: matroska can report success on a partial index after a deadline abort.
    var readDeadlineFired: Bool { get }

    /// #112 round 9: total byte size of the stream the demuxer sees (Content-Length for HTTP, the
    /// virtual concat length for a disc adapter), nil until/unless known. Backs the byte-estimate
    /// seek fallback when a timestamp seek times out on an index-less container.
    var resolvedByteSize: Int64? { get }

    /// Ceiling on the bytes this provider hands libavformat until `endReadByteBudget`, for a pass whose
    /// packet caps cannot see what the demuxer reads and drops inside one `av_read_frame` (the blocks of
    /// AVDISCARD_ALL streams). A read past it fails like a deadline abort. Demux-thread-only, same
    /// contract as the read deadline.
    func beginReadByteBudget(_ bytes: Int64)

    /// Disarm the budget armed by `beginReadByteBudget`.
    func endReadByteBudget()

    /// True when a read was refused because the byte budget was spent.
    var readByteBudgetExhausted: Bool { get }

    /// AE#460 follow-up: whether the byte source behind this provider outlives the provider, so a
    /// rebuild reopens onto a source that is already positioned. True only for the custom-reader
    /// bridge, which does not own its reader; a provider that opens its own transport per session
    /// starts at the beginning because there is nothing older to be at.
    var sourceSurvivesReopen: Bool { get }

    /// AE#460 follow-up: where the underlying source's cursor sits, or nil when it will not say.
    /// Only meaningful together with `sourceSurvivesReopen`. See `openWithProvider`.
    var currentSourceOffset: Int64? { get }

    /// Free the `AVIOContext` and release the underlying source. Idempotent.
    func close()

    /// #281: the demuxer's header + stream-info pass is done, so any further seek is playback, not
    /// parsing. A provider that keeps cold-start state (AVIOReader parks a discarded window for the
    /// parse seek's return trip) releases it here. Default no-op: a provider without that state,
    /// like the custom-reader bridge, ignores it.
    func markOpenPhaseFinished()

    /// AE#585: the host is about to run a bounded index pass (the cue prewarm), which is index work
    /// rather than playback, and it returns the cursor to where it started. A provider that releases
    /// cold-start state on a read that moved away holds it across this. Default no-op.
    func beginIndexPass()

    /// AE#585: the index pass is over, so the next read that lands outside a resident span is
    /// playback's. Default no-op.
    func endIndexPass()

    /// AE#782: the demuxer was just repositioned for playback (a producer restart), so the next read
    /// that needs the network is where playback continues, not index work that returns. Default no-op.
    func notePlaybackRepositioned()

    /// AE#472: notify the provider that play/pause intent changed to wake any thread held in paused sleep.
    func notifyPlayIntentChanged()
}

extension AVIOProvider {
    func markOpenPhaseFinished() {}
    func beginIndexPass() {}
    func endIndexPass() {}
    func notePlaybackRepositioned() {}
    func notifyPlayIntentChanged() {}
    var currentSourceOffset: Int64? { nil }
    var sourceSurvivesReopen: Bool { false }
}

/// The shared bookkeeping behind `AVIOProvider.beginReadByteBudget`. Not thread-safe: it lives on the
/// demux thread with the read callback that consults it.
struct ReadByteBudget {
    private var remaining: Int64?
    private(set) var exhausted = false

    mutating func begin(_ bytes: Int64) {
        remaining = max(0, bytes)
        exhausted = false
    }

    mutating func end() { remaining = nil }

    /// The size a read may ask for, or nil (latching `exhausted`) once the budget is spent.
    mutating func allowance(_ size: Int32) -> Int32? {
        guard let remaining else { return size }
        guard remaining > 0 else {
            exhausted = true
            return nil
        }
        return Int32(min(Int64(size), remaining))
    }

    mutating func consumed(_ count: Int32) {
        if count > 0, let remaining { self.remaining = remaining - Int64(count) }
    }
}
