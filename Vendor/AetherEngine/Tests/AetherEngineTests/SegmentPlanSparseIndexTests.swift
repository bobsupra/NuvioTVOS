// Sparse / clustered keyframe-index detection for the VOD segment plan (#64).
//
// MPEG-TS / M2TS have no upfront keyframe table (unlike MKV Cues / MP4 stss). The libavformat index
// holds only what avformat_find_stream_info plus the mid-file cue-prewarm seek happened to scan, so it
// comes back sparse and clustered (one entry near the start, a handful near the seek point). Trusting
// that as a complete plan yields a single multi-thousand-second first segment; the frag_custom muxer
// then buffers that whole span in libavformat's interleaver before its first flush, which on a 110 min
// Blu-ray grew to ~13 GB of RAM and swapped until the device disk filled. keyframeIndexIsTrustworthy
// is the guard that routes such an index to the uniform-stride fallback instead.
import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

@Suite("HLSVideoEngine sparse keyframe-index detection (#64)")
struct SegmentPlanSparseIndexTests {

    /// MPEG-TS 90 kHz video time base.
    private let ts90k = AVRational(num: 1, den: 90_000)

    /// Matroska 1 kHz (millisecond) video time base.
    private let mkvMs = AVRational(num: 1, den: 1_000)

    /// The reported #64 case: one keyframe at 11.609 s, nine clustered ~0.5 s apart past the 3299.8 s
    /// mid-file seek point. duration 6599 s.
    private func clusteredTSIndex() -> [Int64] {
        let firstKf: Int64 = 1_044_806                 // 11.609 s
        let clusterStart: Int64 = Int64(3299.8 * 90_000) // 296_982_000
        var kfs: [Int64] = [firstKf]
        for i in 0..<9 { kfs.append(clusterStart + Int64(i) * 45_000) } // +0.5 s each
        return kfs
    }

    @Test("A clustered TS index is not trustworthy (largest gap is thousands of seconds)")
    func clusteredIndexRejected() {
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: clusteredTSIndex(),
            videoTimeBase: ts90k,
            sourceDurationSeconds: 6599
        ) == false)
    }

    @Test("Trusting the clustered index would have produced a multi-thousand-second first segment")
    func clusteredIndexProducesGiantSegment() {
        // Documents the exact bug the guard prevents: buildKeyframeSegmentPlan on the clustered input
        // yields a seg-0 spanning the 11.6 s -> 3288 s hole (#EXTINF:3288.076 in the field report).
        let plan = HLSVideoEngine.buildKeyframeSegmentPlan(
            keyframes: clusteredTSIndex(),
            videoTimeBase: ts90k,
            sourceDurationSeconds: 6599
        )
        #expect(plan.first != nil)
        #expect((plan.first?.durationSeconds ?? 0) > 3000)
    }

    /// The reported #91 case: a ~64 GB remote MKV whose Cues tail read fails, so the cue prewarm
    /// never loads the seek index. libavformat is left with only the keyframes scanned at open, all
    /// bunched within the first few seconds. Duration 6843.872 s (#EXTINF in the field report).
    private func bunchedMKVIndex() -> [Int64] {
        [0, 1_000, 2_000, 3_000, 3_500]  // ms: five IRAPs inside the first 3.5 s
    }

    @Test("An MKV index bunched in the first few seconds is not trustworthy (#91)")
    func bunchedIndexRejected() {
        // The gaps between these keyframes are all tiny, so the inter-keyframe gap check passes; the
        // index is still useless because it spans under one targetSegmentDuration. Coverage must reject it.
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: bunchedMKVIndex(),
            videoTimeBase: mkvMs,
            sourceDurationSeconds: 6843.872
        ) == false)
    }

    @Test("Trusting the bunched index would have produced a single whole-file segment (#91)")
    func bunchedIndexProducesWholeFileSegment() {
        // Documents the exact bug the coverage guard prevents: no keyframe reaches the first 4 s segment
        // boundary, so buildKeyframeSegmentPlan degenerates to one segment spanning the whole title, from
        // which AVPlayer loads zero tracks (kFigAssetError_TrackNotFound).
        let plan = HLSVideoEngine.buildKeyframeSegmentPlan(
            keyframes: bunchedMKVIndex(),
            videoTimeBase: mkvMs,
            sourceDurationSeconds: 6843.872
        )
        #expect(plan.count == 1)
        #expect((plan.first?.durationSeconds ?? 0) > 6000)
    }

    @Test("The minimum-coverage threshold is one targetSegmentDuration (boundary)")
    func minimumCoverageBoundary() {
        // Span exactly one segment is trustworthy (seg 0 can be cut); span just under is not (seg 0
        // degenerates to the whole file). Both have a single sub-cap inter-keyframe gap, so only the
        // coverage check decides. Pins the threshold to targetSegmentDuration (4.0 s).
        let exactlyOneSegment: [Int64] = [0, 4_000]   // ms: 4.000 s span
        let justUnderOneSegment: [Int64] = [0, 3_999] // ms: 3.999 s span
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: exactlyOneSegment, videoTimeBase: mkvMs, sourceDurationSeconds: 6843.872) == true)
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: justUnderOneSegment, videoTimeBase: mkvMs, sourceDurationSeconds: 6843.872) == false)
    }

    @Test("A dense 4 s-GOP index across the whole title is trustworthy")
    func denseIndexAccepted() {
        let stride: Int64 = 4 * 90_000
        var kfs: [Int64] = []
        var t: Int64 = 0
        while t <= Int64(6599 * 90_000) { kfs.append(t); t += stride }
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: kfs,
            videoTimeBase: ts90k,
            sourceDurationSeconds: 6599
        ) == true)
    }

    @Test("The trusted-gap cap is pinned at 30 s (boundary)")
    func gapCapBoundary() {
        // 30.000 s gap is trusted, 30.001 s is not. Pins the cap so a future targetSegmentDuration
        // change becomes a visible test break.
        let exactly30: [Int64] = [0, Int64(30.0 * 90_000)]
        let justOver30: [Int64] = [0, Int64(30.001 * 90_000)]
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: exactly30, videoTimeBase: ts90k, sourceDurationSeconds: 6599) == true)
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: justOver30, videoTimeBase: ts90k, sourceDurationSeconds: 6599) == false)
    }

    @Test("A trailing gap from the last keyframe to EOF is not counted")
    func tailGapNotCounted() {
        // Keyframes spaced 4 s up to 60% of the duration, then nothing. The last-keyframe-to-EOF span
        // is not an inter-keyframe gap and must not demote an otherwise-dense index.
        let stride: Int64 = 4 * 90_000
        var kfs: [Int64] = []
        var t: Int64 = 0
        let lastIndexed = Int64(0.6 * 6599 * 90_000)
        while t <= lastIndexed { kfs.append(t); t += stride }
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: kfs, videoTimeBase: ts90k, sourceDurationSeconds: 6599) == true)
    }

    @Test("Degenerate inputs are never trustworthy")
    func degenerateInputs() {
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: [], videoTimeBase: ts90k, sourceDurationSeconds: 6599) == false)
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: [42], videoTimeBase: ts90k, sourceDurationSeconds: 6599) == false)
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: [0, 360_000], videoTimeBase: AVRational(num: 0, den: 0),
            sourceDurationSeconds: 6599) == false)
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: [0, 360_000], videoTimeBase: ts90k, sourceDurationSeconds: 0) == false)
    }

    @Test("Unsorted input is handled (gaps computed on the sorted order)")
    func unsortedInput() {
        // indexedKeyframes does not guarantee sort order; the helper must sort before measuring gaps.
        let dense: [Int64] = [4 * 90_000, 0, 8 * 90_000, 2 * 90_000, 6 * 90_000]
        #expect(HLSVideoEngine.keyframeIndexIsTrustworthy(
            keyframes: dense, videoTimeBase: ts90k, sourceDurationSeconds: 12) == true)
    }

    @Test("The uniform fallback plan covers the duration in target-sized segments")
    func uniformPlanShape() {
        // buildUniformSegmentPlan had no test before #64; lock its shape since Fix A routes the
        // showstopper case through it.
        let plan = HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: ts90k, sourceDurationSeconds: 6599)
        #expect(plan.count == Int(ceil(6599.0 / 4.0)))
        for seg in plan {
            #expect(seg.durationSeconds <= 4.0 + 0.001)
            #expect(seg.durationSeconds > 0)
        }
        // Monotonic non-decreasing starts, last clamped to the source duration.
        for i in 1..<plan.count {
            #expect(plan[i].startSeconds >= plan[i - 1].startSeconds)
        }
        #expect((plan.last?.startSeconds ?? 0) < 6599)
    }

    @Test("The uniform stride is never finer than the measured IRAP spacing (#358)")
    func uniformStrideRespectsMeasuredSpacing() {
        // A 4 s grid over a 10 s GOP is the reported case: the keyframe-gated cutter opens a segment
        // only at the IRAP that reaches a boundary, so two boundaries in three get no segment while
        // the playlist keeps offering them, and AVPlayer stalls on the first of those forever.
        #expect(HLSVideoEngine.uniformStrideSeconds(spacing: .measured(10)) == 10)
        // A GOP at or under the target keeps the target: those boundaries all have an IRAP.
        #expect(HLSVideoEngine.uniformStrideSeconds(spacing: .measured(2)) == 4)
        #expect(HLSVideoEngine.uniformStrideSeconds(spacing: .measured(4)) == 4)
        // Budget spent holding one IRAP: the spacing is at least the budget, so the stride is too.
        #expect(HLSVideoEngine.uniformStrideSeconds(spacing: .exceedsBudget(30)) == 30)
        // Scanned to the end of the source holding one IRAP: same stride, different statement.
        #expect(HLSVideoEngine.uniformStrideSeconds(spacing: .singleKeyframeInSource(30)) == 30)
        // No witness at all leaves the previous behaviour rather than inventing a coarse grid.
        #expect(HLSVideoEngine.uniformStrideSeconds(spacing: .unknown) == 4)
        // Degenerate measurements are not strides.
        #expect(HLSVideoEngine.uniformStrideSeconds(spacing: .measured(0)) == 4)
        #expect(HLSVideoEngine.uniformStrideSeconds(spacing: .measured(-3)) == 4)
        #expect(HLSVideoEngine.uniformStrideSeconds(spacing: .measured(.infinity)) == 4)
    }

    @Test("A stride at the measured spacing puts an IRAP in every segment window (#358)")
    func uniformPlanAtMeasuredStrideHasNoUnopenableBoundary() {
        // The witness that matters is not the segment count but that every boundary is reachable by a
        // keyframe: with IRAPs every 10 s and boundaries every 10 s, each window holds exactly one.
        let gop = 10.0
        let firstKf: Int64 = Int64(1.4 * 90_000)
        let plan = HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: ts90k, sourceDurationSeconds: 120, startPts0: firstKf,
            strideSeconds: HLSVideoEngine.uniformStrideSeconds(spacing: .measured(gop)))
        var irap = firstKf
        let step = Int64(gop * 90_000)
        for segment in plan {
            // The IRAP that opens this segment sits at or after its boundary and before the next one.
            #expect(irap >= segment.startPts)
            #expect(Double(irap - segment.startPts) * (1.0 / 90_000) < gop)
            irap += step
        }
        // The old 4 s grid over the same source is the defect: boundary 1 has no IRAP at all.
        let fineGrid = HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: ts90k, sourceDurationSeconds: 120, startPts0: firstKf)
        #expect(fineGrid[1].startPts < firstKf + step)   // boundary before the next IRAP: unopenable
    }

    @Test("The uniform fallback anchors segment 0 at the content start, not source PTS 0")
    func uniformPlanAnchoredAtFirstKeyframe() {
        // A Blu-ray title whose first keyframe is at 11.609s must not advertise empty leading
        // segments (source 0-11.6s) that never get produced; seg 0 must begin at the content
        // keyframe so the player can start there. Regression guard: without the anchor the #64
        // disk-fill fix's uniform fallback put the first content at segment 2, so AVPlayer's
        // seg0 fetch was permanently out-of-range and playback only worked after seeking past ~13s.
        let firstKf: Int64 = 1_044_806  // 11.609 s @ 90 kHz
        let plan = HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: ts90k, sourceDurationSeconds: 6599, startPts0: firstKf)
        #expect(plan.first?.startPts == firstKf)       // source-axis seg 0 begins at the content keyframe
        #expect(plan.first?.startSeconds == 0)         // playlist axis stays 0-based
        #expect(plan[1].startPts == firstKf + 360_000) // next boundary is +4 s (4 * 90000) from the anchor
        // Default anchor (0) preserves the legacy behavior for callers that do not pass one.
        let unanchored = HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: ts90k, sourceDurationSeconds: 6599)
        #expect(unanchored.first?.startPts == 0)
    }
}
