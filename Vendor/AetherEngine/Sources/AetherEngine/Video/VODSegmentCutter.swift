import Foundation

/// Decode-order, keyframe-gated VOD segment cutter.
///
/// A new segment opens only when a keyframe whose presentation time reaches the next plan boundary
/// arrives, so the IRAP becomes that segment's first sample and its open-GOP RASL leading pictures
/// (which follow it in decode order) stay with it. This matches how FFmpeg's hls muxer and Apple's
/// tools cut, and makes every segment start on a clean random-access point.
///
/// It replaces routing each packet by its DTS against PTS-valued boundaries: under B-frame reorder a
/// keyframe's DTS is below its PTS, so `dts < boundary[N]` dropped the keyframe into segment N-1 and
/// left segment N starting mid-GOP, decode-dependent on its predecessor (#92). Both open-GOP (CRA +
/// RASL) and closed-GOP-with-B-frames were affected because the reorder delay is constant across the
/// stream. The cut point is the only thing that changes; EXTINF still comes from the plan boundaries.
struct VODSegmentCutter {

    /// Plan boundaries on the ITEM axis, in the timestamps the PLAN is expressed in: `boundaries[i]`
    /// is the start of segment `baseIndex + i`, i.e. the plan's source timestamp minus the plan anchor.
    ///
    /// #358: for a keyframe-aligned plan those timestamps come from the container index, and mov/mp4
    /// index entries are DECODE timestamps. The gate is therefore fed decode timestamps too. Feeding
    /// it presentation timestamps let a keyframe reach boundaries beyond its own by its composition
    /// offset, which is a couple of frames on an ordinary encode and was 3 s on a remux carrying an
    /// edit list; every boundary inside that offset was consumed and never opened a segment, while
    /// the playlist kept offering it.
    /// `boundaries.count` is the segment count + 1 (the last entry is the end of the final segment).
    ///
    /// AE#268: packets reach the cutter with the producer's shift already subtracted, so they are on
    /// the item axis; comparing them against SOURCE-axis boundaries offset every cut by the anchor,
    /// and by the whole gate overshoot after a restart that landed off a random-access point. Both
    /// axes now agree, which also lets a plan whose boundaries ARE the source's IRAPs cut on them
    /// (against source boundaries such a keyframe never reaches its own boundary, so the cutter would
    /// never advance).
    let boundaries: [Int64]
    let baseIndex: Int
    private(set) var current: Int

    init(sourceBoundaries: [Int64], planAnchorPts: Int64, baseIndex: Int) {
        self.boundaries = sourceBoundaries.map { $0 &- planAnchorPts }
        self.baseIndex = baseIndex
        self.current = baseIndex
    }

    /// Segment index for a video packet, in decode order, from its ITEM-axis presentation time.
    /// Advances on a keyframe that has reached the next boundary; every other packet (and an
    /// intra-segment keyframe that has not yet reached the next boundary, e.g. when the GOP is shorter
    /// than the segment) stays in the current segment.
    mutating func index(pts: Int64, isKeyframe: Bool) -> Int {
        guard isKeyframe, pts != Int64.min else { return current }
        // boundaries[count-1] is the end of the final segment, not a segment start, so the last segment
        // a keyframe can open is local (count-2): advance only while the next entry is a real start.
        var nextLocal = (current - baseIndex) + 1
        while nextLocal < boundaries.count - 1, pts >= boundaries[nextLocal] {
            current += 1
            nextLocal += 1
        }
        return current
    }
}
