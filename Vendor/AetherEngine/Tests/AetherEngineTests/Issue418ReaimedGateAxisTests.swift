import Testing
import Foundation
@testable import AetherEngine

/// AE#418 (rrgomes): after a restart whose gate re-aimed below its boundary, the clock ran ahead of
/// the picture by the re-aim. Captions about four seconds early on a resume that re-aimed 3.045 s,
/// about eight after restarts that re-aimed 3.1 and 5.0, and a synced host reports the wrong position
/// with them. Lip sync survives, because audio and video sit in the same segment.
///
/// **AVPlayer presents a segment at the position the PLAYLIST gives it, not at the tfdt it carries.**
/// AE#408 shipped the early-opening gate on the opposite assumption and published no offset for that
/// case. `aetherctl play --picture-probe` measures it directly, on a fixture whose picture states its
/// own source time in binary.
///
/// Round 1 (6.43.0) got the offset right and its LIFETIME wrong. It keyed the offset to "the decode
/// run AVPlayer began here" and answered that from the fetch order, treating any request that did not
/// follow its predecessor as a fresh run. The reporter's seek burst falsified it: a fetch out of
/// sequence happens while AVPlayer stays inside the run it is already playing, and the axis was then
/// republished from under a picture that had not moved, which is the pre-fix shape re-entered.
///
/// Round 2 measures what the offset actually does, at re-aims of 0.5, 0.875, 1, 3, 5, 7, 9 and 11 s:
///
/// - It **composes**. AVPlayer places a segment at its advertised start read through the mapping its
///   timeline ALREADY carries, so re-placing an overlong segment adds its offset again. A resume that
///   opened 9 s below its boundary reads `axisErr=-9.000`; a seek that makes AVPlayer fetch that same
///   segment a second time reads `-18.000`, and one that provokes a restart re-aiming 5 s more reads
///   `-14.000`. Round 1 published `0.000` for all three.
/// - It survives a seek unchanged, which is what the reporter's case turns on, **unless it is under a
///   second**: `-0.500` and `-0.875` read `axisErr=0.000` after a seek, `-1.000` and everything above
///   it survive one. AVPlayer discards a sub-second axis and snaps back to the playlist.
///
/// Measured on `tc-cues-lie.mkv` (Cues injected at non-sync positions, 12 s keyframe drought at 43 s),
/// `capErr` being the error a host placing a cue at `sourceTime` would make:
///
/// | case | round 1 | round 2 |
/// | --- | --- | --- |
/// | resume 53, seek to 80 (the reporter's shape) | `-8.983` | `+0.017` |
/// | resume 53, seek to 65 (re-places the anchor) | `-8.983` | `+0.017` |
/// | resume 53, seek to 60 (restart re-aims again) | `-8.983` | `+0.017` |
/// | resume 10, burst (sub-second, snaps) | `-0.008` | `+0.017` |
struct Issue418ReaimedGateAxisTests {

    // The reporter's `#65 ledger`, in the millisecond time base its lines are printed in.
    // Each row is (advertised boundary, where the gate actually opened, the drift he tabulated).
    private static let ledger: [(boundary: Int64, gateOpenedAt: Int64, drift: Int64)] = [
        (352_936, 349_891, -3_045),   // session 1 + 2, the resume at 354.0
        (676_134, 662_078, -14_056),  // session 1, seek to 682.0, re-aimed 4s, 8s, 12s, 16s
        (972_847, 969_802, -3_045),   // session 1, seek to 992.0
        (1_084_375, 1_083_332, -1_043), // session 1, seek to 1102.0
        (512_053, 508_925, -3_128),   // session 2, seek to 519.3
        (684_809, 679_762, -5_047),   // session 2, seek to 689.3
        (604_521, 604_896, 375)       // session 2, seek to 609.3: a LATE opening, the pinned case
    ]

    // MARK: - The offset is measured against the advertised start
    //
    // Round 4 takes the offset on the epoch's first PRESENTED sample, so these rows read as pts. His
    // log printed the gate's `actual=`, which is the decode time, and on a source with B-frames the
    // two differ by the composition offset (`Issue418PresentedShiftTests`). The arithmetic under test
    // is the same either way.

    @Test("every re-aimed restart in the report publishes its own drift, not zero")
    func ledgerRowsPublishTheirDrift() {
        for row in Self.ledger {
            let published = HLSSegmentProducer.presentedShiftPts(
                actualFirstPts: row.gateOpenedAt, desiredTfdtPts: row.boundary)
            #expect(published == row.drift,
                    "boundary \(row.boundary) opened at \(row.gateOpenedAt)")
        }
    }

    @Test("a gate that opened early publishes a negative shift, which is what was missing")
    func earlyGatePublishesNegative() {
        // The harness case: boundary 52.000 s, gate re-aimed and opened at 43.000 s.
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: 43_000, desiredTfdtPts: 52_000) == -9_000)
    }

    @Test("a gate that opened exactly on its boundary publishes nothing")
    func exactGatePublishesZero() {
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: 44_000, desiredTfdtPts: 44_000) == 0)
    }

    @Test("a late gate is unchanged, because the pin already made the two axes agree")
    func lateGateUnchanged() {
        // Pre-AE#408 behaviour on the same fixture: the gate opened at 55.0 for a boundary at 52.0
        // and the pin moved the first frame down to 52.0, so the content sits 3 s above the axis.
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: 55_000, desiredTfdtPts: 52_000) == 3_000)
    }

    @Test("an unresolved timestamp publishes nothing rather than a garbage offset")
    func unresolvedPublishesZero() {
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: .min, desiredTfdtPts: 52_000) == 0)
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: 43_000, desiredTfdtPts: .min) == 0)
    }

    // MARK: - The offset composes when a segment is placed

    @Test("the first placement of a session establishes the axis")
    func firstPlacementEstablishesTheAxis() {
        #expect(HLSVideoEngine.axisShift(after: 0, placing: -9.0, presentationLead: 0) == -9.0)
    }

    @Test("an axis-true segment leaves the axis where it is")
    func axisTrueSegmentChangesNothing() {
        // The reporter's seek burst: seg179 was cut on its own boundary, and the run kept -14.056.
        #expect(HLSVideoEngine.axisShift(after: -14.056, placing: 0, presentationLead: 0) == -14.056)
    }

    @Test("re-placing the segment the gate opened into adds its offset again")
    func rePlacingTheAnchorComposes() {
        // Measured: resume 53 reads -9.000, and a seek that re-fetches that same segment reads -18.000.
        #expect(HLSVideoEngine.axisShift(after: -9.0, placing: -9.0, presentationLead: 0) == -18.0)
        // And at the deepest tier of the tiered fixture, -11.000 -> -22.000.
        #expect(HLSVideoEngine.axisShift(after: -11.0, placing: -11.0, presentationLead: 0) == -22.0)
    }

    @Test("a later epoch's own re-aim composes onto what the timeline already carries")
    func newEpochComposesOntoTheOldAxis() {
        // Measured: a -9.000 run, seek to 60, producer restarts at seg12 and re-aims 5 s, reads -14.000.
        #expect(HLSVideoEngine.axisShift(after: -9.0, placing: -5.0, presentationLead: 0) == -14.0)
        // Tiered fixture: a -11.000 run whose seek restarts at seg23 re-aiming 7 s reads -18.000.
        #expect(HLSVideoEngine.axisShift(after: -11.0, placing: -7.0, presentationLead: 0) == -18.0)
    }

    // MARK: - Round 5: a composition lands on the base, not on the axis

    @Test("the lead is what the gating sample is presented after its own decode time")
    func leadIsTheCompositionOffset() {
        // The fixture's B-frame arm: the gate opens on a random-access point decoded at 42917 and
        // presented at 43000, two frames at 24 fps.
        #expect(HLSSegmentProducer.presentationLeadPts(actualFirstPts: 43_000, actualFirstDts: 42_917) == 83)
        // Its twin without B-frames is one number, which is why the pair isolates this.
        #expect(HLSSegmentProducer.presentationLeadPts(actualFirstPts: 43_000, actualFirstDts: 43_000) == 0)
    }

    @Test("an unresolved or inverted timestamp leads by nothing")
    func leadNeverGoesNegative() {
        #expect(HLSSegmentProducer.presentationLeadPts(actualFirstPts: .min, actualFirstDts: 42_917) == 0)
        #expect(HLSSegmentProducer.presentationLeadPts(actualFirstPts: 43_000, actualFirstDts: .min) == 0)
        #expect(HLSSegmentProducer.presentationLeadPts(actualFirstPts: 42_917, actualFirstDts: 43_000) == 0)
    }

    @Test("a composition onto an existing timeline lands one lead below the axis")
    func compositionLandsOnTheBase() {
        // Measured on tc-bframes.mkv: the axis stood at -9.000 and AVPlayer held the re-placed
        // segment from item 61.083, not the 61.000 the axis alone predicts, and the picture read
        // -18.083 for the rest of the run.
        #expect(HLSVideoEngine.placementBase(axis: -9.0, presentationLead: 0.083) == -9.083)
        #expect(abs(HLSVideoEngine.axisShift(
            after: -9.0, placing: -9.0, presentationLead: 0.083) - (-18.083)) < 1e-9)
    }

    @Test("each composition eats its own lead, so an unmeasured chain of them accumulates")
    func leadAccumulatesPerComposition() {
        // The three-placement burst arm: -9.000 -> -18.083 -> -27.166, all three read back off the
        // picture. Before this the third was kept at -27.000, 0.166 s over the truth.
        let second = HLSVideoEngine.axisShift(after: -9.0, placing: -9.0, presentationLead: 0.083)
        let third = HLSVideoEngine.axisShift(after: second, placing: -9.0, presentationLead: 0.083)
        #expect(abs(third - (-27.166)) < 1e-9)
    }

    @Test("a source without reordering composes exactly as it did")
    func noLeadIsTheOldArithmetic() {
        // tc-drought.mkv, same three arms: -9.000 -> -18.000, confirmed by both the reading and the
        // picture, so this round changes nothing where there is nothing to change.
        #expect(HLSVideoEngine.axisShift(after: -9.0, placing: -9.0, presentationLead: 0) == -18.0)
        #expect(HLSVideoEngine.placementBase(axis: -9.0, presentationLead: 0) == -9.0)
    }

    @Test("the seam sits where the placement lands, which is below the advertised start by the base")
    func seamFollowsTheBase() {
        // seg13 advertised at 52.000 composing onto -9.000 with a lead of 0.083 begins at item
        // 61.083, which is where AVPlayer reported holding it.
        let base = HLSVideoEngine.placementBase(axis: -9.0, presentationLead: 0.083)
        #expect(abs(HLSVideoEngine.seamItemSeconds(advertisedStart: 52.0, currentShift: base) - 61.083) < 1e-9)
    }

    // MARK: - Where the new axis starts applying

    @Test("the seam is the advertised start read through the axis already in effect")
    func seamIsReadThroughTheOldAxis() {
        // seg12 advertised at 48.0 landing on a timeline that already carries -9.0 begins at item 57.0,
        // which is where the picture probe found its first frame.
        #expect(HLSVideoEngine.seamItemSeconds(advertisedStart: 48.0, currentShift: -9.0) == 57.0)
    }

    @Test("on a fresh timeline the seam is the advertised start itself")
    func seamOnAFreshTimeline() {
        #expect(HLSVideoEngine.seamItemSeconds(advertisedStart: 52.0, currentShift: 0) == 52.0)
    }

    // MARK: - What a producer restart does to the record

    @Test("a new epoch drops what older epochs claimed at and above its own index")
    func newEpochDropsTheIndicesItRewrites() {
        let table = HLSVideoEngine.epochShiftTable([11: -0.875, 13: -9.0], recordingEpochAt: 12, shift: -5.0)
        #expect(table == [11: -0.875, 12: -5.0])
        // seg13 is now cut on its own boundary by the new producer, so claiming -9.0 for it would be
        // the table-shaped mistake round 1 avoided by keeping a single pair.
        #expect(table[13] == nil)
    }

    @Test("an epoch that opened on its boundary is recorded as worth nothing")
    func exactEpochIsRecordedAsZero() {
        // Round 2 asserted the opposite, that such an epoch is not recorded at all, and that
        // assertion was the AE#448 defect written down: the entry is what says "an epoch begins
        // here", so dropping it left the stretch the epoch had just taken over folding with the seam
        // underneath it. Worth nothing to the axis VALUE is not the same as nothing to record.
        #expect(HLSVideoEngine.epochShiftTable([13: -9.0], recordingEpochAt: 20, shift: 0)
                == [13: -9.0, 20: 0])
    }

    @Test("segments below a restart keep the offset their bytes still carry")
    func segmentsBelowARestartAreUntouched() {
        let table = HLSVideoEngine.epochShiftTable([2: -0.875], recordingEpochAt: 13, shift: -9.0)
        #expect(table == [2: -0.875, 13: -9.0])
    }

    // MARK: - What a seek does to the axis

    @Test("a sub-second axis does not survive a seek")
    func subSecondAxisSnaps() {
        // Measured: -0.500 and -0.875 both read axisErr 0.000 after a seek.
        #expect(HLSVideoEngine.axisShiftAfterSeek(-0.5) == 0)
        #expect(HLSVideoEngine.axisShiftAfterSeek(-0.875) == 0)
        #expect(HLSVideoEngine.axisShiftAfterSeek(0.375) == 0)
    }

    @Test("a second or more survives a seek unchanged")
    func secondOrMoreSurvivesASeek() {
        // Measured, every one of them across a seek: -1.000, -1.083, -1.292, -1.500, -3.000,
        // -4.000, -7.000, -9.000, -11.000. The boundary sits between -0.875 and -1.000.
        for shift in [-1.0, -1.083, -1.292, -1.5, -3.0, -4.0, -7.0, -9.0, -11.0, -22.0] {
            #expect(HLSVideoEngine.axisShiftAfterSeek(shift) == shift)
        }
    }

    @Test("an axis of zero stays zero")
    func zeroStaysZero() {
        #expect(HLSVideoEngine.axisShiftAfterSeek(0) == 0)
    }

    // MARK: - What counts as a placement

    @Test("every fetch places a segment, whatever its order")
    func everyFetchIsAPlacement() {
        #expect(VideoSegmentProvider.placesSegmentAnew(index: 12, previousTarget: 11))
        // The reporter's burst: seg179 after seg169, which round 1 called a fresh run and this calls
        // what it is, a placement of a segment worth nothing.
        #expect(VideoSegmentProvider.placesSegmentAnew(index: 179, previousTarget: 169))
        #expect(VideoSegmentProvider.placesSegmentAnew(index: 3, previousTarget: 11))
    }

    @Test("the same index again is a retry of one placement, not a second one")
    func repeatedFetchIsARetry() {
        // Counting it twice would move the axis by an offset AVPlayer applied once; the restart path
        // serves exactly this shape (`fetch seg12 prev=seg12` right after a producer rebuild).
        #expect(!VideoSegmentProvider.placesSegmentAnew(index: 11, previousTarget: 11))
    }

    @Test("the session's first fetch is a placement")
    func firstFetchIsAPlacement() {
        #expect(VideoSegmentProvider.placesSegmentAnew(index: 13, previousTarget: -1))
    }
}
/// AE#418 round 4 (rrgomes, retest on 6.56.5, Mac Catalyst 26.6.2 and an Apple TV 4K, same asset):
/// **the reading IS the axis.**
///
/// Round 3 measured the base out of `AVPlayerItem.loadedTimeRanges` and then collapsed it onto the
/// nearest value this side had already published, which made the prediction the yardstick for the
/// measurement that was supposed to check it. His logs show both ways that fails, and the numbers in
/// this suite are his:
///
/// - A reading that matched no prediction was thrown away. Two readings 400 s of media apart both
///   said `-10.93` while the session composed its way out to `-26.152`; the Apple TV ended at
///   `-45.045` against a measured `-2.411`, a 42.6 s error, permanent until playback restarted.
/// - A reading a frame or two off the prediction was called a confirmation, so that difference stayed
///   in the axis and the next placement composed on top of it. Six confirmations walked the error
///   0.000, 0.083, 0.125, 0.209, 0.283, 0.290, past the 0.25 s tolerance the first four had already
///   spent 84 percent of, after which every reading was refused for the rest of the session.
///
/// Round 4 adopts what it measures, so a per-placement difference is one placement's and never a
/// run's, and a placement counted twice is undone by the next reading rather than carried. What
/// decides whether a reading is about THIS placement is where it came from, not whether it agrees:
/// `freshRunStart` refuses the run that was already there and refuses a start that walked downward,
/// because AVPlayer backfills below a run after it opens (his: a run that opened at 1522.6 read
/// 1507.1 fifteen seconds later).
@Suite("AE#418 round 4: the reading is the axis")
struct Issue418PlacementReconcileTests {

    // MARK: - Reading the base out of the placement

    @Test("the placement inverts to the base AVPlayer composed onto")
    func placementInvertsToBase() {
        // The round-2 reporting case: advertised 788.204, held from item 791.249.
        #expect(abs(HLSVideoEngine.measuredPlacementBase(
            advertisedStart: 788.204, observedItemStart: 791.249) - -3.045) < 0.001)
        // The harness case, where the assumption held: advertised 12.000, held from item 21.000.
        #expect(abs(HLSVideoEngine.measuredPlacementBase(
            advertisedStart: 12.0, observedItemStart: 21.0) - -9.0) < 0.001)
    }

    @Test("a placement that landed where it was predicted reads a residual of nothing")
    func agreesWithThePrediction() {
        // ARM C on the harness: resume at -9.000, a far seek whose restart re-aims 1.667 s more, and
        // the picture reads -10.667 for the rest of the run. Nothing here may move.
        let reading = HLSVideoEngine.placementReading(
            advertisedStart: 12.0, worth: -1.667, assumedBase: -9.0, observedItemStart: 21.0)!
        #expect(abs(reading.residual) <= HLSVideoEngine.axisRepublishEpsilonSeconds)
        #expect(abs(reading.axis - -10.667) < 0.001)
    }

    @Test("the round-2 burst: the axis collapses onto the base AVPlayer actually used")
    func correctsTheBurstCase() {
        // His host log printed the range to one decimal (`loaded=[791.2-...]`); the placement it
        // describes is the resume axis, 788.204 + 3.045. Round 3 could take the printed number because
        // it snapped the reading onto a published value; round 4 reports what it reads, so the reading
        // is the full-precision one AVPlayer actually returns.
        let reading = HLSVideoEngine.placementReading(
            advertisedStart: 788.204, worth: -5.589, assumedBase: -5.088, observedItemStart: 791.249)!
        #expect(abs(reading.base - -3.045) < 0.001)
        // -8.634, not -10.677: the middle fetch moved nothing, so its worth is not in the axis.
        #expect(abs(reading.axis - -8.634) < 0.001)
        // And the seam belongs at the placement, which is what the item reported holding.
        #expect(abs(reading.seam - 791.249) < 0.001)
    }

    @Test("a reading that matches no axis this session published is still the axis")
    func adoptsAnUnrecognisedReading() {
        // His Mac, seg396: measured -10.937 while the session had composed to -22.773. Round 3 refused
        // this for matching no prediction and kept composing. The item was carrying the measurement.
        let reading = HLSVideoEngine.placementReading(
            advertisedStart: 1584.708, worth: -1.5, assumedBase: -22.773, observedItemStart: 1595.645)!
        #expect(abs(reading.base - -10.937) < 0.001)
        #expect(abs(reading.residual - 11.836) < 0.001)
        #expect(abs(reading.axis - -12.437) < 0.001)
    }

    @Test("a placement counted twice is undone by the next reading, not carried")
    func doubleCountHealsOnTheNextReading() {
        // His Apple TV: seg380 folded in twice four seconds apart across a producer restart,
        // -6.173 -> -25.609 -> -45.045, and the item then reported holding it from 1522.555, a base
        // of -2.411. Round 3 kept -45.045 for the rest of the session (audio out of sync, subtitles
        // far behind, a set of subtitles repeating at the onset).
        let reading = HLSVideoEngine.placementReading(
            advertisedStart: 1520.144, worth: -19.436, assumedBase: -25.609,
            observedItemStart: 1522.555)!
        #expect(abs(reading.base - -2.411) < 0.001)
        #expect(abs(reading.axis - -21.847) < 0.001)
        // Whatever else is true of that session, the doubled value cannot survive a reading.
        #expect(reading.axis != -45.045)
    }

    @Test("adopting the reading keeps a per-placement difference from accumulating")
    func residualDoesNotAccumulate() {
        // His measured shape: each placement lands about two frames off its prediction, on both
        // devices at the same rate, which makes it a property of the content rather than of the
        // hardware. Round 3 kept the assumption, so those differences summed until the sixth was
        // outside the tolerance. Adopting means each placement starts from what was measured.
        let quantum = 0.083
        var assumed = 0.0
        var worstResidual = 0.0
        for _ in 0..<12 {
            let observed = 100.0
            // AVPlayer placed it a quantum away from where the composition assumed it would land.
            let advertised = observed + assumed - quantum
            let reading = HLSVideoEngine.placementReading(
                advertisedStart: advertised, worth: -2.0, assumedBase: assumed,
                observedItemStart: observed)!
            worstResidual = max(worstResidual, abs(reading.residual))
            assumed = reading.axis
        }
        #expect(abs(worstResidual - quantum) < 0.001)
    }

    @Test("a reading below a millisecond is not worth republishing")
    func tinyResidualIsNoCorrection() {
        // The harness arms: a resume whose gate opened 9 s below its boundary reads item 52.000 for an
        // advertised 52.000, exactly the base the composition assumed. Publishing that again would
        // re-arm the check on its own output for the rest of the session.
        let reading = HLSVideoEngine.placementReading(
            advertisedStart: 52.0, worth: -9.0, assumedBase: 0.0, observedItemStart: 52.0)!
        #expect(abs(reading.residual) <= HLSVideoEngine.axisRepublishEpsilonSeconds)
    }

    @Test("a reading that is not a number is not a placement")
    func nonFiniteReadingIsRefused() {
        #expect(HLSVideoEngine.placementReading(
            advertisedStart: 52.0, worth: -9.0, assumedBase: 0.0, observedItemStart: .nan) == nil)
    }

    // MARK: - Which range describes the picture

    @Test("the range holding the playhead is the one that was placed")
    func rangeHoldingThePlayhead() {
        let ranges = [(352.9, 400.0), (791.2, 816.6)]
        #expect(HLSVideoEngine.placementRangeStart(ranges: ranges, itemClock: 810.868) == 791.2)
        #expect(HLSVideoEngine.placementRangeStart(ranges: ranges, itemClock: 360.0) == 352.9)
    }

    @Test("a playhead no range holds says nothing about a placement")
    func noRangeHoldsThePlayhead() {
        // The state right after a seek, before AVPlayer has taken the bytes. Answering from the range
        // that happens to exist is how a check invents a placement out of the previous epoch.
        #expect(HLSVideoEngine.placementRangeStart(
            ranges: [(352.9, 400.0)], itemClock: 810.868) == nil)
        #expect(HLSVideoEngine.placementRangeStart(ranges: [], itemClock: 810.868) == nil)
    }

    @Test("overlapping ranges resolve to the newest placement")
    func overlappingRangesTakeTheHighestStart() {
        // Two runs can cover one position while the older one is still being evicted; the picture is
        // the one placed last.
        #expect(HLSVideoEngine.placementRangeStart(
            ranges: [(780.0, 800.0), (791.2, 816.6)], itemClock: 795.0) == 791.2)
    }

    // MARK: - Which run belongs to this placement

    @Test("a resume has no baseline, so the first run it opens is its own")
    func firstRunOfTheSessionIsFresh() {
        // Measured on the fixture: at the placement the item holds nothing, and 250 ms later it holds
        // [52.000-64.958] for an advertised 52.000.
        #expect(HLSVideoEngine.freshRunStart(
            ranges: [(52.0, 64.958)], baseline: [], itemClock: 53.1) == 52.0)
    }

    @Test("the run that was already there is not this placement's")
    func baselineRunIsRefused() {
        // A placement is recorded when AVPlayer FETCHES, so it cannot have the bytes yet: a range whose
        // start the baseline already reported is the previous epoch's run still holding the playhead.
        // Its start inverts to an OLDER placement's base, and round 3 read that as a confirmation.
        #expect(HLSVideoEngine.freshRunStart(
            ranges: [(52.0, 74.9)], baseline: [(52.0, 68.952)], itemClock: 60.0) == nil)
    }

    @Test("a run that opens above the baseline is a placement, not backfill")
    func upwardRunIsFresh() {
        // The fixture's second arm: a seek that re-places the overlong segment opens [61.000-81.969]
        // against a baseline of [52.000-68.952]. It overlaps, and it is still a different run.
        #expect(HLSVideoEngine.freshRunStart(
            ranges: [(61.0, 81.969)], baseline: [(52.0, 68.952)], itemClock: 74.1) == 61.0)
    }

    @Test("a start that walked downward is the same run backfilling")
    func backfilledRunIsRefused() {
        // His Apple TV: a run that opened at 1522.6 read 1507.1 fifteen seconds later, so "the start of
        // the range holding the playhead" answers a different question depending on when it is sampled.
        // AVPlayer only ever extends a run downward, so a downward move is never a placement. The cost
        // is a missed measurement on a backward reopen inside the buffer, where the composed axis
        // stands, as it did before any of this.
        #expect(HLSVideoEngine.freshRunStart(
            ranges: [(1507.1, 1538.9)], baseline: [(1510.6, 1518.5)], itemClock: 1530.0) == nil)
    }

    @Test("a run disjoint from everything the baseline held is fresh either way")
    func disjointRunIsFresh() {
        // The same device four seconds earlier: the buffer flushed and a fresh run opened at 1522.6.
        #expect(HLSVideoEngine.freshRunStart(
            ranges: [(1522.6, 1530.6)], baseline: [(1510.6, 1518.5)], itemClock: 1525.0) == 1522.6)
    }

    @Test("a playhead outside every range measures nothing")
    func noFreshRunWithoutThePlayhead() {
        #expect(HLSVideoEngine.freshRunStart(
            ranges: [(61.0, 81.969)], baseline: [], itemClock: 40.0) == nil)
    }
}

/// AE#418 round 4: the gate's offset describes what AVPlayer SHOWS, so it is taken on the PTS.
///
/// A segment opens on a random-access point in DECODE order, and with B-frames that sample is
/// presented `video_delay` frames after it is decoded. The gate published the decode one, so the axis
/// sat that far under the truth on every epoch of a B-frame source, which is most real content.
@Suite("AE#418 round 4: the presented shift is measured on the presented sample")
struct Issue418PresentedShiftTests {

    @Test("the offset is the distance from the ADVERTISED start to the first presented sample")
    func takenOnThePresentedSample() {
        // `tc-bframes.mkv` (24 fps h264, has_b_frames=2, source timebase 1/1000): the gate opens on a
        // random-access point at dts 42917 whose pts is 43000, for a boundary of 52000. The segment's
        // own bytes agree, tfdt baseMediaDecodeTime=686672 with a first-sample composition offset of
        // 1328 in a timescale of 16000, which is the same 0.083 s.
        #expect(HLSSegmentProducer.presentedShiftPts(
            actualFirstPts: 43000, desiredTfdtPts: 52000) == -9000)
    }

    @Test("what the decode time would have published, which is what the picture contradicted")
    func decodeTimeUnderstatesTheAxis() {
        // Taken on the gate's own `actual=42917` the same epoch publishes -9083, while
        // `play --picture-probe` reads the true axis as -9.000 for the whole run. Mean capErr over 39
        // ticks on the two-epoch arm: +0.113 s before, +0.031 s after, against +0.030 s on the same
        // fixture encoded without B-frames.
        #expect(HLSSegmentProducer.presentedShiftPts(
            actualFirstPts: 42917, desiredTfdtPts: 52000) == -9083)
    }

}
