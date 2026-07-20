import Foundation

/// Final-stage fMP4 muxer input guard enforcing `av_interleaved_write_frame` invariants per stream: (1) DTS strictly increases; (2) PTS >= DTS. Needed for SSAI (Pluto/Samsung-TV+ FAST) where ad creatives restart source clock at 2^33 (MPEG-TS modulus) with independently muxed audio -- a single pts<dts audio packet silences the whole ad segment. No-op for healthy content. Operates on muxer-time-base values; AV_NOPTS_VALUE passes through untouched.
struct OutputTimestampSanitizer {
    private var lastDtsByStream: [Int32: Int64] = [:]

    mutating func sanitize(streamIndex: Int32, pts: Int64, dts: Int64) -> (pts: Int64, dts: Int64) {
        guard dts != Int64.min else { return (pts, dts) }  // NOPTS: nothing to enforce

        var outDts = dts
        if let last = lastDtsByStream[streamIndex], outDts <= last {
            outDts = last + 1
        }
        let outPts = pts == Int64.min ? outDts : max(pts, outDts)  // NOPTS pts collapses to dts (safe floor for audio and video)

        lastDtsByStream[streamIndex] = outDts
        return (outPts, outDts)
    }
}
