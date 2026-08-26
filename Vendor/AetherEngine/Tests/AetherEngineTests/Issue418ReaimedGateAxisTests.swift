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

    @Test("every re-aimed restart in the report publishes its own drift, not zero")
    func ledgerRowsPublishTheirDrift() {
        for row in Self.ledger {
            let published = HLSSegmentProducer.presentedShiftPts(
                actualFirstDts: row.gateOpenedAt, desiredTfdtPts: row.boundary)
            #expect(published == row.drift,
                    "boundary \(row.boundary) opened at \(row.gateOpenedAt)")
        }
    }

    @Test("a gate that opened early publishes a negative shift, which is what was missing")
    func earlyGatePublishesNegative() {
        // The harness case: boundary 52.000 s, gate re-aimed and opened at 43.000 s.
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: 43_000, desiredTfdtPts: 52_000) == -9_000)
    }

    @Test("a gate that opened exactly on its boundary publishes nothing")
    func exactGatePublishesZero() {
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: 44_000, desiredTfdtPts: 44_000) == 0)
    }

    @Test("a late gate is unchanged, because the pin already made the two axes agree")
    func lateGateUnchanged() {
        // Pre-AE#408 behaviour on the same fixture: the gate opened at 55.0 for a boundary at 52.0
        // and the pin moved the first frame down to 52.0, so the content sits 3 s above the axis.
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: 55_000, desiredTfdtPts: 52_000) == 3_000)
    }

    @Test("an unresolved timestamp publishes nothing rather than a garbage offset")
    func unresolvedPublishesZero() {
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: .min, desiredTfdtPts: 52_000) == 0)
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstDts: 43_000, desiredTfdtPts: .min) == 0)
    }

    // MARK: - The offset composes when a segment is placed

    @Test("the first placement of a session establishes the axis")
    func firstPlacementEstablishesTheAxis() {
        #expect(HLSVideoEngine.axisShift(after: 0, placing: -9.0) == -9.0)
    }

    @Test("an axis-true segment leaves the axis where it is")
    func axisTrueSegmentChangesNothing() {
        // The reporter's seek burst: seg179 was cut on its own boundary, and the run kept -14.056.
        #expect(HLSVideoEngine.axisShift(after: -14.056, placing: 0) == -14.056)
    }

    @Test("re-placing the segment the gate opened into adds its offset again")
    func rePlacingTheAnchorComposes() {
        // Measured: resume 53 reads -9.000, and a seek that re-fetches that same segment reads -18.000.
        #expect(HLSVideoEngine.axisShift(after: -9.0, placing: -9.0) == -18.0)
        // And at the deepest tier of the tiered fixture, -11.000 -> -22.000.
        #expect(HLSVideoEngine.axisShift(after: -11.0, placing: -11.0) == -22.0)
    }

    @Test("a later epoch's own re-aim composes onto what the timeline already carries")
    func newEpochComposesOntoTheOldAxis() {
        // Measured: a -9.000 run, seek to 60, producer restarts at seg12 and re-aims 5 s, reads -14.000.
        #expect(HLSVideoEngine.axisShift(after: -9.0, placing: -5.0) == -14.0)
        // Tiered fixture: a -11.000 run whose seek restarts at seg23 re-aiming 7 s reads -18.000.
        #expect(HLSVideoEngine.axisShift(after: -11.0, placing: -7.0) == -18.0)
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

    @Test("an epoch that opened on its boundary records nothing")
    func exactEpochRecordsNothing() {
        #expect(HLSVideoEngine.epochShiftTable([13: -9.0], recordingEpochAt: 20, shift: 0) == [13: -9.0])
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
