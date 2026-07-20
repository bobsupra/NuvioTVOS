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

    /// Plan boundaries in source PTS: `boundaries[i]` is the start PTS of segment `baseIndex + i`.
    /// `boundaries.count` is the segment count + 1 (the last entry is the end of the final segment).
    let boundaries: [Int64]
    let baseIndex: Int
    private(set) var current: Int

    init(boundaries: [Int64], baseIndex: Int) {
        self.boundaries = boundaries
        self.baseIndex = baseIndex
        self.current = baseIndex
    }

    /// Segment index for a video packet, in decode order. Advances on a keyframe that has reached the
    /// next boundary; every other packet (and an intra-segment keyframe that has not yet reached the
    /// next boundary, e.g. when the GOP is shorter than the segment) stays in the current segment.
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
