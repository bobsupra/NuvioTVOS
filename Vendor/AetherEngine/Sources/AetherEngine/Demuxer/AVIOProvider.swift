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

    /// Free the `AVIOContext` and release the underlying source. Idempotent.
    func close()

    /// #281: the demuxer's header + stream-info pass is done, so any further seek is playback, not
    /// parsing. A provider that keeps cold-start state (AVIOReader parks a discarded window for the
    /// parse seek's return trip) releases it here. Default no-op: a provider without that state,
    /// like the custom-reader bridge, ignores it.
    func markOpenPhaseFinished()
}

extension AVIOProvider {
    func markOpenPhaseFinished() {}
}
