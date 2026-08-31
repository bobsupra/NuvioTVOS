import Testing
import Foundation
@testable import AetherEngine

/// AE#432: a live MPEG-TS whose video packets stopped carrying timestamps wedged the segment
/// cutter. The repair for a packet with neither dts nor pts was `lastValidDts + 1`, one tick of the
/// source time base, which is enough for the muxer's monotonic invariant and nothing else. The live
/// cutter's clock IS that timestamp: it opens a segment at a keyframe's pts and cuts at the next
/// keyframe whose pts is `targetSegmentDurationSeconds` past the open segment's start. One tick per
/// packet on a 90 kHz axis means 11 microseconds per 20 ms frame, so the clock froze and the cutter
/// could not cut again for as long as the run lasted.
///
/// The field window, from the report: 1792 video packets, 30 keyframes, no audio, the whole 35.8 s
/// of media muxed into one 85 MB segment advertised as 0.5 s, and `videoPtsAdvance=0.0s` where
/// 1792 ticks / 90000 = 0.0199 s. The repair's own signature: had the packets truly reached the
/// watchdog without timestamps, that field would have been suppressed instead of printing 0.0.
@Suite("Synthesized timestamp stride and the live cutter (AE#432)")
struct Issue432SynthesizedTimestampStrideTests {

    /// 50 fps on the MPEG-TS 90 kHz axis, as measured on the reporter's channel.
    private let tbSeconds = 1.0 / 90_000.0
    private let frameTicks: Int64 = 1800
    private let cutTarget = HLSVideoEngine.fastZapLiveCutTargetSeconds  // 0.5 s

    // MARK: - The stride cascade

    @Test("the demuxer's own duration for the packet wins")
    func packetDurationWins() {
        #expect(HLSSegmentProducer.repairStrideTicks(
            packetDuration: 1800, observedStride: 3600, fallbackDuration: 40) == 1800)
    }

    @Test("without a duration the stream's last genuine delta is used")
    func observedStrideIsSecond() {
        #expect(HLSSegmentProducer.repairStrideTicks(
            packetDuration: 0, observedStride: 1800, fallbackDuration: 40) == 1800)
    }

    @Test("without either, the frame duration the producer already carries")
    func fallbackDurationIsThird() {
        #expect(HLSSegmentProducer.repairStrideTicks(
            packetDuration: 0, observedStride: 0, fallbackDuration: 1800) == 1800)
    }

    @Test("a stream that has never carried a usable timestamp keeps the single tick")
    func lastResortIsOneTick() {
        #expect(HLSSegmentProducer.repairStrideTicks(
            packetDuration: 0, observedStride: 0, fallbackDuration: 0) == 1)
        // Negative/absurd inputs are not evidence either.
        #expect(HLSSegmentProducer.repairStrideTicks(
            packetDuration: -1, observedStride: -5, fallbackDuration: -40) == 1)
    }

    // MARK: - Learning the stride from the source

    @Test("a forward delta inside the cap becomes the stride")
    func forwardDeltaAdopted() {
        #expect(HLSSegmentProducer.updatedStrideTicks(
            current: 0, previousDts: 90_000, dts: 91_800, maxStrideTicks: 90_000) == 1800)
    }

    @Test("the first genuine timestamp of a stream teaches nothing yet")
    func firstTimestampKeepsCurrent() {
        #expect(HLSSegmentProducer.updatedStrideTicks(
            current: 0, previousDts: Int64.min, dts: 91_800, maxStrideTicks: 90_000) == 0)
    }

    @Test("a backward or standing delta is not a frame interval")
    func backwardDeltaRejected() {
        #expect(HLSSegmentProducer.updatedStrideTicks(
            current: 1800, previousDts: 91_800, dts: 90_000, maxStrideTicks: 90_000) == 1800)
        #expect(HLSSegmentProducer.updatedStrideTicks(
            current: 1800, previousDts: 91_800, dts: 91_800, maxStrideTicks: 90_000) == 1800)
    }

    @Test("a leap past the cap is a program boundary, not a cadence change")
    func hugeDeltaRejected() {
        // The reporter's origin renumbers on reconnect; a 100 s jump must not become the stride.
        #expect(HLSSegmentProducer.updatedStrideTicks(
            current: 1800, previousDts: 90_000, dts: 9_090_000, maxStrideTicks: 90_000) == 1800)
    }

    // MARK: - What the cutter does with the synthesized timeline

    /// Runs the field window through the real live cut rule: 1792 packets, a keyframe every 60
    /// (the measured 30 keyframes), a 0.5 s cut target.
    private func cutsAcrossFieldWindow(strideTicks: Int64) -> Int {
        var anchor: Int64 = 0
        var segmentStart = 0.0
        var cuts = 0
        for i in 0..<1792 {
            anchor &+= strideTicks
            let ptsSeconds = Double(anchor) * tbSeconds
            if HLSSegmentProducer.liveShouldCut(
                ptsSeconds: ptsSeconds, segmentStartSeconds: segmentStart,
                targetSeconds: cutTarget, isKeyframe: i % 60 == 0, forceCut: false) {
                cuts += 1
                segmentStart = ptsSeconds
            }
        }
        return cuts
    }

    @Test("one tick per packet cannot reach the cut target: the wedge as reported")
    func singleTickWedgesTheCutter() {
        #expect(cutsAcrossFieldWindow(strideTicks: 1) == 0)
        // The number the watchdog printed as videoPtsAdvance=0.0s.
        #expect(abs(Double(1792) * tbSeconds - 0.0199) < 0.001)
    }

    @Test("the frame stride keeps the cutter cutting across the same window")
    func frameStrideKeepsCutting() {
        // 1792 frames at 50 fps is 35.84 s of media; at a 0.5 s target and a 1.2 s keyframe
        // cadence every keyframe past the first cuts, so the window yields 29 segments, not one.
        #expect(cutsAcrossFieldWindow(strideTicks: frameTicks) == 29)
    }

    @Test("a keyframe below the target does not cut, a forced boundary does")
    func cutRuleUnchangedOtherwise() {
        #expect(!HLSSegmentProducer.liveShouldCut(
            ptsSeconds: 0.2, segmentStartSeconds: 0, targetSeconds: 0.5,
            isKeyframe: true, forceCut: false))
        #expect(HLSSegmentProducer.liveShouldCut(
            ptsSeconds: 0.2, segmentStartSeconds: 0, targetSeconds: 0.5,
            isKeyframe: true, forceCut: true))
        // A non-keyframe never cuts, forced or not.
        #expect(!HLSSegmentProducer.liveShouldCut(
            ptsSeconds: 9.0, segmentStartSeconds: 0, targetSeconds: 0.5,
            isKeyframe: false, forceCut: true))
    }
}
