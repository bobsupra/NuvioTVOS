import Testing
import Foundation
@testable import AetherEngine

/// AE#408 (rrgomes), second finding: after a restart the seek landed 3 to 14 s past its target with a
/// broken first picture, on every one of sixteen instances across two devices.
///
/// The plan boundary is a container index entry, and for Matroska every entry is a Cue point that
/// libavformat enters as `AVINDEX_KEYFRAME` regardless of the block's own keyframe flag
/// (`matroska_add_index_entries`). Cues mark seek points, not sync points. On the reporting asset the
/// boundary at 244.119 s carried no sync sample at all: the next one was at 255.297 s, 11.1 s later,
/// which is exactly the shift the producer then applied ("dropped=200 ... isKey=false target=244119"
/// followed by "video gate open: actual=255255 ... shift=11136"). ffprobe on the asset confirms it,
/// and its K flags cover open-GOP random access too, since the H.264 parser marks a recovery point as
/// a keyframe and the HEVC parser marks every IRAP NAL.
///
/// The gate now refuses to open past a boundary that claimed random access, and goes back for a sync
/// sample that covers it. Reproduced headless on a fixture whose Cues were injected at non-sync
/// positions (`target=44000` with sync samples at 43.0 and 55.0): before, the gate opened at 55.0 and
/// a resume at 45 s started at 55.8; after, it re-aims once and opens at 43.0, and the resume starts
/// where it was asked to.
struct Issue408BoundaryRandomAccessTests {

    // Reporting asset geometry, in the source's millisecond time base.
    private static let boundary: Int64 = 244_119        // the plan boundary, a Cue point
    private static let nextSyncSample: Int64 = 255_297  // the next real one, 11.178 s later
    private static let prevSyncSample: Int64 = 243_118  // the one that covers the boundary
    private static let graceTicks: Int64 = 1_000        // boundaryProbeGraceSeconds at 1/1000
    private static let toleranceTicks: Int64 = 500      // boundaryOpenToleranceSeconds at 1/1000

    // MARK: - Proving the boundary is not a random-access point

    @Test("a non-sync packet sitting exactly on the boundary proves the claim false at once")
    func packetOnTheBoundaryProvesIt() {
        // The asset's own reading: `244.119000,243.994000,___`, an ordinary frame where the index
        // promised random access. No need to read the drought to find that out.
        #expect(HLSSegmentProducer.boundaryProvenNotRandomAccess(
            droppedPts: Self.boundary, targetPts: Self.boundary,
            sawKeyframeBeforeTarget: false, graceTicks: Self.graceTicks))
    }

    @Test("the scan reaching past the boundary without a sync sample proves it too")
    func scanPastTheBoundaryProvesIt() {
        #expect(HLSSegmentProducer.boundaryProvenNotRandomAccess(
            droppedPts: Self.boundary + 1_200, targetPts: Self.boundary,
            sawKeyframeBeforeTarget: false, graceTicks: Self.graceTicks))
    }

    @Test("a packet inside the grace window is not evidence yet")
    func insideGraceIsNotEvidence() {
        // A seek can land a few frames early and those frames present past the target while their
        // own keyframe is still to come. One frame past the boundary decides nothing.
        #expect(!HLSSegmentProducer.boundaryProvenNotRandomAccess(
            droppedPts: Self.boundary + 42, targetPts: Self.boundary,
            sawKeyframeBeforeTarget: false, graceTicks: Self.graceTicks))
    }

    @Test("a seek that landed on its own keyframe below the target vetoes the proof")
    func earlyLandingVetoesTheProof() {
        // Reorder window of a keyframe BELOW the boundary: those packets present past it and say
        // nothing about the boundary itself. Without this veto an MP4 whose stss entries are decode
        // timestamps would re-aim on every restart.
        #expect(!HLSSegmentProducer.boundaryProvenNotRandomAccess(
            droppedPts: Self.boundary + 4_000, targetPts: Self.boundary,
            sawKeyframeBeforeTarget: true, graceTicks: Self.graceTicks))
    }

    @Test("an absent timestamp or an absent target decides nothing")
    func missingValuesDecideNothing() {
        #expect(!HLSSegmentProducer.boundaryProvenNotRandomAccess(
            droppedPts: Int64.min, targetPts: Self.boundary,
            sawKeyframeBeforeTarget: false, graceTicks: Self.graceTicks))
        // Head of stream has no boundary to disprove.
        #expect(!HLSSegmentProducer.boundaryProvenNotRandomAccess(
            droppedPts: Self.boundary, targetPts: Int64.min,
            sawKeyframeBeforeTarget: false, graceTicks: Self.graceTicks))
    }

    // MARK: - Refusing to open past the boundary

    @Test("the reported 11.1 s overshoot re-aims instead of opening")
    func reportedOvershootReaims() {
        #expect(HLSSegmentProducer.shouldReanchorBeforeOpening(
            keyframePts: Self.nextSyncSample, boundaryPts: Self.boundary,
            toleranceTicks: Self.toleranceTicks, attemptsUsed: 0,
            maxAttempts: HLSSegmentProducer.gateBackoffStepsSeconds.count))
    }

    @Test("ordinary index-versus-packet skew opens as before")
    func smallSkewOpens() {
        // A couple of frames past the boundary is the decode-timestamp-versus-presentation-time skew
        // every well-formed index carries. Paying a second seek for that would be worse than the skew.
        #expect(!HLSSegmentProducer.shouldReanchorBeforeOpening(
            keyframePts: Self.boundary + 120, boundaryPts: Self.boundary,
            toleranceTicks: Self.toleranceTicks, attemptsUsed: 0,
            maxAttempts: HLSSegmentProducer.gateBackoffStepsSeconds.count))
    }

    @Test("a sync sample that covers the boundary opens it")
    func coveringSyncSampleOpens() {
        #expect(!HLSSegmentProducer.shouldReanchorBeforeOpening(
            keyframePts: Self.prevSyncSample, boundaryPts: Self.boundary,
            toleranceTicks: Self.toleranceTicks, attemptsUsed: 1,
            maxAttempts: HLSSegmentProducer.gateBackoffStepsSeconds.count))
    }

    @Test("the backoff budget is finite: a source with no random access anywhere still opens")
    func exhaustedBudgetOpens() {
        // Otherwise a genuinely broken source would re-seek forever instead of playing what it has.
        #expect(!HLSSegmentProducer.shouldReanchorBeforeOpening(
            keyframePts: Self.nextSyncSample, boundaryPts: Self.boundary,
            toleranceTicks: Self.toleranceTicks,
            attemptsUsed: HLSSegmentProducer.gateBackoffStepsSeconds.count,
            maxAttempts: HLSSegmentProducer.gateBackoffStepsSeconds.count))
    }

    @Test("the tolerance covers the stream's own reorder depth, so a B-pyramid does not re-aim")
    func toleranceCoversReorderDepth() {
        // 24 fps at 1/1000: a 16-frame DPB puts a correctly indexed keyframe's presentation time
        // 0.67 s above the decode timestamp it was indexed at, past the 0.5 s floor.
        let ticks = HLSSegmentProducer.boundaryOpenToleranceTicks(
            reorderFrames: 16, frameDurationPts: 42, floorTicks: 500)
        #expect(ticks == 16 * 42 + 42)
        #expect(!HLSSegmentProducer.shouldReanchorBeforeOpening(
            keyframePts: Self.boundary + 672, boundaryPts: Self.boundary,
            toleranceTicks: ticks, attemptsUsed: 0,
            maxAttempts: HLSSegmentProducer.gateBackoffStepsSeconds.count))
        // The reported drought still exceeds it by an order of magnitude.
        #expect(HLSSegmentProducer.shouldReanchorBeforeOpening(
            keyframePts: Self.nextSyncSample, boundaryPts: Self.boundary,
            toleranceTicks: ticks, attemptsUsed: 0,
            maxAttempts: HLSSegmentProducer.gateBackoffStepsSeconds.count))
    }

    @Test("a stream without reorder keeps the floor")
    func noReorderKeepsFloor() {
        #expect(HLSSegmentProducer.boundaryOpenToleranceTicks(
            reorderFrames: 0, frameDurationPts: 42, floorTicks: 500) == 500)
        // A codecpar that never resolved must not produce a negative window.
        #expect(HLSSegmentProducer.boundaryOpenToleranceTicks(
            reorderFrames: -1, frameDurationPts: -1, floorTicks: 500) == 500)
    }

    @Test("the backoff steps widen, and the first is one segment")
    func backoffStepsWiden() {
        let steps = HLSSegmentProducer.gateBackoffStepsSeconds
        #expect(steps.count >= 2)
        #expect(steps.first == 4)   // the covering sync sample is usually within one segment
        for i in 1..<steps.count {
            #expect(steps[i] > steps[i - 1])
        }
    }

    // MARK: - What the opened epoch is published at

    @Test("a gate that opened early keeps its own position, so the item axis stays where the plan put it")
    func earlyOpenKeepsItsPosition() {
        // 243.118 for a segment advertised at 244.119: publishing it at the advertised start would
        // relabel the axis by a second and land the seek a second early. The overlap with the
        // previous segment is the cost, and AVPlayer absorbs it.
        #expect(HLSSegmentProducer.pinnedFirstTfdtPts(
            actualFirstDts: Self.prevSyncSample, desiredTfdtPts: Self.boundary,
            planAnchorPts: 0) == Self.prevSyncSample)
    }

    @Test("a gate that opened late is still pinned to the advertised start")
    func lateOpenStaysPinned() {
        // The budget can run out on a source with a genuine drought. Publishing 255.297 at its own
        // time would leave a hole where the playlist promises 244.119, and AVPlayer waits on holes
        // forever; the pin (and the shift it produces) is what keeps that playable.
        #expect(HLSSegmentProducer.pinnedFirstTfdtPts(
            actualFirstDts: Self.nextSyncSample, desiredTfdtPts: Self.boundary,
            planAnchorPts: 0) == Self.boundary)
    }

    @Test("an exact landing publishes at the advertised start either way")
    func exactLandingIsUnchanged() {
        #expect(HLSSegmentProducer.pinnedFirstTfdtPts(
            actualFirstDts: Self.boundary, desiredTfdtPts: Self.boundary,
            planAnchorPts: 0) == Self.boundary)
        #expect(HLSSegmentProducer.pinnedFirstTfdtPts(
            actualFirstDts: Int64.min, desiredTfdtPts: Self.boundary,
            planAnchorPts: 0) == Self.boundary)
    }

    @Test("both operands are on the item axis, so a source starting after PTS 0 is unmoved")
    func planAnchorIsNotAnEarlyOpen() {
        // The restart-witness fixture's content starts at 1024 ticks (0.083 s), so a restart that
        // opens exactly on its boundary has a SOURCE timestamp below the boundary's ITEM time.
        // Reading that as an early open published every restarted epoch an anchor early: measured as
        // tfdt 48128 against the continuous run's 49152, and as a seam reported at 0.083 s.
        let anchor: Int64 = 1024
        let advertised: Int64 = 48_128        // item axis
        #expect(HLSSegmentProducer.pinnedFirstTfdtPts(
            actualFirstDts: advertised + anchor, desiredTfdtPts: advertised,
            planAnchorPts: anchor) == advertised)
        // A genuine early open on the same source still keeps its position, one anchor lower.
        #expect(HLSSegmentProducer.pinnedFirstTfdtPts(
            actualFirstDts: advertised, desiredTfdtPts: advertised,
            planAnchorPts: anchor) == advertised - anchor)
    }
}
