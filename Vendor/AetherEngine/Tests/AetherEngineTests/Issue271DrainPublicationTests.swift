import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// #271: `$subtitleCues` published once per DECODED PACKET, each publication carrying the whole
/// cumulative array. `applyEventMutations` takes the channel's cue array inout, and `@Published`
/// exposes get/set with no `_modify`, so every event copy-on-wrote the array and republished it.
/// On a typeset ASS track (5,852 retained cues, ~52 packets per 500 ms tick) the reporter measured
/// 104 publications and 608,608 cue visits per second in one consumer, with zero new cues found:
/// a cumulative snapshot does not say which elements are new, so no host can skip the walk.
///
/// Three things are asserted here, all of them decisions the drain tick makes:
///
/// - the batch is bounded per tick and the bound falls on a PTS boundary (`batchEnd`),
/// - a tick that ran long is not mistaken for a seek by the next one (`drainPlan`),
/// - the insert reports whether it changed anything and finds same-start cues without walking the
///   whole retained array.
struct Issue271DrainPublicationTests {

    private func textCue(id: Int, start: Double, end: Double, _ s: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(s))
    }
    private func img(width: Int = 1) -> SubtitleCue.Body {
        let ctx = CGContext(data: nil, width: width, height: 1, bitsPerComponent: 8,
                            bytesPerRow: 4 * width, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return .image(SubtitleImage(cgImage: ctx.makeImage()!, position: .zero))
    }

    // MARK: - Batch bound on a PTS boundary

    @Test("a window at or under the cap decodes whole")
    func batchUnderCapIsWhole() {
        let pts: [Double] = [1, 2, 3, 4]
        #expect(SubtitleOverlayDrainer.batchEnd(count: 4, cap: 8) { pts[$0] } == 4)
        #expect(SubtitleOverlayDrainer.batchEnd(count: 4, cap: 4) { pts[$0] } == 4)
        #expect(SubtitleOverlayDrainer.batchEnd(count: 0, cap: 4) { pts[$0] } == 0)
    }

    @Test("a cap landing between two timestamps cuts there")
    func capOnPTSBoundaryCutsExactly() {
        let pts: [Double] = [1, 2, 3, 4, 5, 6]
        #expect(SubtitleOverlayDrainer.batchEnd(count: 6, cap: 3) { pts[$0] } == 3)
    }

    /// The load-bearing case. The cursor is a bare PTS advanced by `lastDecodedPts.nextUp`, so the
    /// next tick asks the store for packets AFTER the last decoded timestamp. A cut inside a
    /// same-PTS run would therefore skip its remainder for good, and a dense typeset track puts
    /// hundreds of distinct payloads on one timestamp (the reporter measured 303 on the densest).
    @Test("a cap landing inside a same-PTS run extends to the end of that run")
    func capExtendsThroughSamePTSRun() {
        let pts: [Double] = [1, 2, 2, 2, 2, 5, 6]
        #expect(SubtitleOverlayDrainer.batchEnd(count: 7, cap: 2) { pts[$0] } == 5)
        #expect(SubtitleOverlayDrainer.batchEnd(count: 7, cap: 3) { pts[$0] } == 5)
        #expect(SubtitleOverlayDrainer.batchEnd(count: 7, cap: 5) { pts[$0] } == 5)
    }

    @Test("a single run longer than the cap is decoded whole rather than split")
    func oversizedRunIsNotSplit() {
        let pts = [Double](repeating: 107.680, count: 303)
        #expect(SubtitleOverlayDrainer.batchEnd(count: 303, cap: 48) { pts[$0] } == 303)
    }

    @Test("a non-positive cap disables bounding")
    func zeroCapIsUnbounded() {
        let pts: [Double] = [1, 2, 3]
        #expect(SubtitleOverlayDrainer.batchEnd(count: 3, cap: 0) { pts[$0] } == 3)
    }

    // MARK: - A slow tick is not a seek

    /// `drainPlan` compares the live playhead against the playhead captured at the PREVIOUS tick's
    /// start, so a tick lasting longer than the 2.5 s jump threshold made the next one see a
    /// discontinuity and reset onto a fresh, disjoint window: a positive feedback loop, since the
    /// reset window is the expensive one.
    @Test("forward drift within the tick's own duration is not a seek")
    func slowTickIsNotASeek() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 104,
                                                    lead: 60, backscan: 15, jumpThreshold: 2.5,
                                                    elapsedSinceLastPlan: 4.0)
        guard case .decode = plan else {
            Issue.record("expected decode, got \(plan)"); return
        }
    }

    @Test("a real forward seek during a slow tick still resets")
    func realSeekDuringSlowTickStillResets() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 400,
                                                    lead: 60, backscan: 15, jumpThreshold: 2.5,
                                                    elapsedSinceLastPlan: 4.0)
        guard case .resetAndDecode(let from, _) = plan else {
            Issue.record("expected resetAndDecode, got \(plan)"); return
        }
        #expect(from == 385)
    }

    /// Playback never moves the playhead backwards, so elapsed wall time explains nothing about a
    /// backward delta and must not forgive one.
    @Test("a backward jump is a seek at any tick duration")
    func backwardJumpIsNeverForgiven() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 96,
                                                    lead: 60, backscan: 15, jumpThreshold: 2.5,
                                                    elapsedSinceLastPlan: 30)
        guard case .resetAndDecode(let from, _) = plan else {
            Issue.record("expected resetAndDecode, got \(plan)"); return
        }
        #expect(from == 81)
    }

    @Test("elapsed defaults to zero, so the threshold alone still governs a fast tick")
    func fastTickKeepsThresholdOnly() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 104,
                                                    lead: 60, backscan: 15, jumpThreshold: 2.5)
        guard case .resetAndDecode = plan else {
            Issue.record("expected resetAndDecode, got \(plan)"); return
        }
    }

    // MARK: - The insert reports change, and finds same-start cues without a full walk

    @Test("a re-decoded text cue reports no change and consumes no id")
    func dedupedInsertReportsNoChange() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        #expect(AetherEngine.insertCueSorted(textCue(id: 0, start: 100, end: 110, "line"),
                                             into: &cues, nextID: &nextID))
        #expect(!AetherEngine.insertCueSorted(textCue(id: 0, start: 100, end: 110, "line"),
                                              into: &cues, nextID: &nextID))
        #expect(cues.count == 1)
        #expect(nextID == 1)
    }

    @Test("a same-start image re-decode reports a change: it replaces the retained bitmap")
    func imageReplaceReportsChange() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        #expect(AetherEngine.insertCueSorted(SubtitleCue(id: 0, startTime: 100, endTime: 110, body: img()),
                                             into: &cues, nextID: &nextID))
        #expect(AetherEngine.insertCueSorted(SubtitleCue(id: 0, startTime: 100, endTime: 118, body: img()),
                                             into: &cues, nextID: &nextID))
        #expect(cues.count == 1)
        #expect(cues[0].endTime == 118)
    }

    /// The dedupe key requires an exact start match, so the equal-start run is the only place a
    /// match can live and the binary-search lookup must find it wherever the run sits in a large
    /// sorted array. Same text at a DIFFERENT start is a genuine repeat and still inserts.
    @Test("dedupe over a large sorted store finds the buried same-start cue, and only that one")
    func dedupeFindsBuriedRunInLargeStore() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        for i in 0..<2000 {
            AetherEngine.insertCueSorted(textCue(id: 0, start: Double(i), end: Double(i) + 0.5, "l\(i)"),
                                         into: &cues, nextID: &nextID)
        }
        #expect(cues.count == 2000)
        #expect(!AetherEngine.insertCueSorted(textCue(id: 0, start: 1337, end: 1337.5, "l1337"),
                                              into: &cues, nextID: &nextID))
        #expect(cues.count == 2000)
        // Same text, different start: a genuine repeat.
        #expect(AetherEngine.insertCueSorted(textCue(id: 0, start: 4000, end: 4000.5, "l1337"),
                                             into: &cues, nextID: &nextID))
        #expect(cues.count == 2001)
        // Simultaneous speaker at a start already present: distinct text, both kept.
        #expect(AetherEngine.insertCueSorted(textCue(id: 0, start: 1337, end: 1337.5, "other"),
                                             into: &cues, nextID: &nextID))
        #expect(cues.count == 2002)
        #expect(cues.map(\.startTime) == cues.map(\.startTime).sorted())
    }

    @Test("insertion order among cues sharing a start is unchanged by the binary-search lookup")
    func sameStartInsertPositionUnchanged() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        AetherEngine.insertCueSorted(textCue(id: 0, start: 100, end: 110, "first"), into: &cues, nextID: &nextID)
        AetherEngine.insertCueSorted(textCue(id: 0, start: 100, end: 110, "second"), into: &cues, nextID: &nextID)
        AetherEngine.insertCueSorted(textCue(id: 0, start: 100, end: 110, "third"), into: &cues, nextID: &nextID)
        #expect(cues.map(\.text) == ["third", "second", "first"])
    }

    // MARK: - Trim and prune report change

    @Test("a trim covering no open window reports no change")
    func trimReportsNoChange() {
        var cues = [textCue(id: 0, start: 10, end: 12, "done")]
        #expect(!AetherEngine.trimTextCues(&cues, at: 50))
        #expect(AetherEngine.trimTextCues(&cues, at: 11))
        #expect(cues[0].endTime == 11)
    }

    @Test("a prune that drops nothing reports no change")
    func pruneReportsNoChange() {
        var cues = [textCue(id: 0, start: 100, end: 110, "a"),
                    textCue(id: 1, start: 500, end: 510, "b")]
        #expect(!AetherEngine.pruneCues(&cues, before: 50))
        // A non-positive cutoff is "no retention pressure yet", not "drop everything".
        #expect(!AetherEngine.pruneCues(&cues, before: -300))
        #expect(cues.count == 2)
        #expect(AetherEngine.pruneCues(&cues, before: 200))
        #expect(cues.count == 1)
    }
}
