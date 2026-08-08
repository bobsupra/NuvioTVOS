import Foundation

/// #303: how far ahead of the clock the software path is actually holding decoded video, and how
/// that folds into the `bufferedPosition` a host reads.
///
/// The two inputs come from different places (the renderer knows what it has queued, the host knows
/// where the synchronizer is), and the arithmetic between them is the part worth pinning, so it
/// lives here as plain functions rather than inside either of them.
enum SoftwareBufferFrontier {

    /// Seconds of decoded video queued ahead of the source clock, or nil when nothing has been
    /// enqueued yet. Both arguments are on the source axis, so this needs no session anchor and
    /// reads the same on VOD and live.
    ///
    /// Clamped at zero on purpose: the synchronizer keeps running while the queue starves, which is
    /// exactly when this number is interesting, and a clock past the newest held frame means an
    /// empty cushion rather than a negative one.
    static func cushionSeconds(newestEnqueuedPts: Double?, sourceClock: Double) -> Double? {
        guard let newestEnqueuedPts, newestEnqueuedPts.isFinite, sourceClock.isFinite else { return nil }
        return max(0, newestEnqueuedPts - sourceClock)
    }

    /// `clock.bufferedPosition` for a software session. `liveFrontier` is the newest demuxed source
    /// PTS in session time, which only live sessions feed (`noteEdge` is gated on `isLive`); on VOD
    /// it is 0 and the cushion is the only thing that can carry a frontier. AetherEngine#54: the
    /// result never trails the playhead.
    static func bufferedPosition(currentTime: Double, liveFrontier: Double, cushion: Double?) -> Double {
        max(currentTime, liveFrontier, currentTime + (cushion ?? 0))
    }
}
