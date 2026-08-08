import Foundation

/// #112 rework: playhead-paced decode planning for the subtitle overlay. The drainer
/// replaces the embedded side reader's positioning/pacing half: it reads packets from
/// the SubtitlePacketStore near the playhead and decodes them into the existing
/// applySubtitleEvent path, so the PGS stale-arrival gate, trim state machine, and
/// retention semantics stay playhead-relative and untouched.
struct SubtitleDrainCursor: Sendable {
    /// Source PTS (seconds) of the last packet handed to the decoder.
    var lastDecodedPts: Double
    /// Playhead at the previous tick; a jump beyond the threshold means the user
    /// seeked (or the producer re-anchored) and the decoder must be rebuilt.
    var lastPlayhead: Double
    /// #250: where the current contiguous decoded run started, i.e. the window start of the last
    /// `.resetAndDecode`. Steady ticks decode forward from the cursor, so the tick's own window
    /// start says nothing about how far back determination reaches. nil until the first reset.
    var coverageStart: Double? = nil
    /// #276: the retained run, i.e. the same span folded ACROSS seeks for as long as the runs keep
    /// touching. Lives on the cursor because the cursor's lifetime is exactly the claim's: both are
    /// cleared by `stopSubtitleDrainer` and by every track switch, and those are the same points
    /// that empty the channel's cue array.
    var retained: SubtitleResolutionStatement.Retention? = nil
}

enum SubtitleDrainPlan: Equatable, Sendable {
    /// Continue decoding forward from the cursor (exclusive) through the lead edge.
    case decode(from: Double, through: Double)
    /// Discontinuity: rebuild the decoder, then decode the window around the playhead.
    case resetAndDecode(from: Double, through: Double)
    /// Caught up; nothing worth scanning this tick.
    case idle
}

enum SubtitleOverlayDrainer {
    /// Sub-second forward windows are not worth a store scan; the next tick accumulates.
    /// The cursor only ever advances to an actually-decoded packet's PTS, so deferring
    /// the scan never skips late-arriving packets.
    static let minimumScanWindowSeconds: Double = 1.0

    /// #271: `elapsedSinceLastPlan` is the wall time between this plan and the previous one. Steady
    /// playback advances the playhead by roughly that much, so a tick that itself took longer than
    /// `jumpThreshold` would otherwise read its own duration as a seek and reset onto a fresh,
    /// disjoint window: a positive feedback loop where one slow tick guarantees the next one is
    /// slower. Only FORWARD drift is forgiven; playback never moves the playhead backwards, so a
    /// backward delta is a seek at any tick duration. Rate is not modelled: above 1x a pathologically
    /// slow tick can still trip the threshold, which costs a redundant window decode, not correctness.
    static func drainPlan(cursor: SubtitleDrainCursor?, playhead: Double,
                          lead: Double, backscan: Double,
                          jumpThreshold: Double,
                          elapsedSinceLastPlan: Double = 0) -> SubtitleDrainPlan {
        let through = playhead + lead
        guard let cursor else {
            return .resetAndDecode(from: playhead - backscan, through: through)
        }
        let delta = playhead - cursor.lastPlayhead
        let allowance = delta > 0 ? jumpThreshold + max(0, elapsedSinceLastPlan) : jumpThreshold
        if abs(delta) > allowance {
            return .resetAndDecode(from: playhead - backscan, through: through)
        }
        guard through - cursor.lastDecodedPts >= minimumScanWindowSeconds else {
            return .idle
        }
        return .decode(from: cursor.lastDecodedPts.nextUp, through: through)
    }

    /// #271: how far into a PTS-ordered store window one tick may decode. The window is bounded in
    /// seconds of content (backscan + lead) and never in packets, so its size is set by the file's
    /// subtitle density; a typeset ASS track puts thousands of packets in one window and the decode
    /// loop has no suspension point. `cap` bounds the batch, and the boundary is then extended
    /// forward to the end of the run sharing the last packet's PTS.
    ///
    /// That extension is required, not a nicety: the drain cursor is a bare PTS advanced by
    /// `lastDecodedPts.nextUp`, so a cut INSIDE a same-PTS run would skip its remainder rather than
    /// resume it on the next tick. Bitmap tracks put one composition on a PTS and never notice;
    /// dense ASS deliberately keeps hundreds of distinct payloads on one timestamp and would lose
    /// every one of them past the cut. A single run longer than the cap is therefore decoded whole.
    static func batchEnd(count: Int, cap: Int, ptsAt: (Int) -> Double) -> Int {
        guard cap > 0 else { return count }
        guard count > cap else { return count }
        let boundary = ptsAt(cap - 1)
        var end = cap
        while end < count, ptsAt(end) == boundary { end += 1 }
        return end
    }

    /// Whether a reconstruction pass should be finalized after its drain window has decoded.
    /// A renderable composition at/after the playhead ends the pass inside
    /// `admitDuringReconstruction`. If the pass is still active with a seeded candidate, only
    /// non-rendering packets such as a PGS clear were decoded ahead, or no successor was present.
    static func shouldFinalizeReconstruction(reconstructing: Bool,
                                             hasCandidate: Bool) -> Bool {
        reconstructing && hasCandidate
    }
}
