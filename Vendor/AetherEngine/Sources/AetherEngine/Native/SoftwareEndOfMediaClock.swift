import Foundation

/// AE#374: what the software path's master clock does once the producer is done.
///
/// `AVSampleBufferRenderSynchronizer` is the master clock for the whole software session, and nothing
/// used to stop it at end of media: the demux loop drained, published `.ended` and parked its own
/// threads, but left the synchronizer at rate 1. So `currentTime` kept walking past `duration` for as
/// long as the host held the session, and the 1 Hz `[SWDiag]` line kept reporting an `aLead` falling at
/// exactly 1.00 per second, which is the shape of a session drifting rather than of one that finished.
/// A downstream host read those lines as evidence of a clock defect, and so did this repo. The native
/// path parks on its final sample; this is what makes the two agree.
enum SoftwareEndOfMediaClock {

    /// Longest the clock may keep running after the last packet, so a queued audio tail plays out
    /// instead of being cut off. Bounded because the anchor is a stream value: a broken PTS must not
    /// buy an unbounded runway on a session that is already over.
    static let maxTailPlayoutSeconds: TimeInterval = 5.0

    /// Seconds to let the clock run before parking it: the decoded audio still ahead of the playhead,
    /// clamped. Zero (park now) when the source carries no audio, when its PTS is unusable, or when the
    /// clock has already passed it, which is the normal VOD case because the drain that precedes end of
    /// media has already walked the clock to the last video frame.
    static func tailPlayoutSeconds(clockSeconds: Double, lastAudioPts: Double) -> TimeInterval {
        guard clockSeconds.isFinite, lastAudioPts.isFinite else { return 0 }
        let remaining = lastAudioPts - clockSeconds
        guard remaining > 0 else { return 0 }
        return min(remaining, maxTailPlayoutSeconds)
    }
}
