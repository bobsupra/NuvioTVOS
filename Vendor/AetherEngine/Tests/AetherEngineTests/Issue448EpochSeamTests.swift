import Testing
import Foundation
@testable import AetherEngine

/// AE#448: after a seek whose restart opened a fresh epoch, the reported clock sat about 1.7 s ABOVE
/// the frame on screen for seven seconds and then settled on its own.
///
/// The axis was right the whole time. What was missing was a SEAM. An epoch whose first segment opens
/// exactly on its boundary carries no offset, so nothing was recorded for it and nothing was published,
/// and the stretch it had just taken over kept folding with whatever seam sat below it. After a
/// backward seek that seam belongs to an older epoch, and the difference between the two is the error.
///
/// Measured on `tc-cues-lie.mkv` with `play --picture-probe`, resume at 53 s and seeks to 25 and 3:
///
/// ```
/// #418 seg13 placed (advertised 52.000s, worth -9.000s): axis  0.000 ->  -9.000  seamAt=52.000
/// #418 seg3  placed (advertised 12.000s, worth -1.667s): axis -9.000 -> -10.667  seamAt=21.000
/// video gate open: actual=0 desired=0 shift=0                      <- worth nothing, published nothing
/// t=25 cur=5.50  pic=3.875  picItem=14.584  axisErr=-10.709  capErr=-1.625
/// t=31 cur=11.60 pic=9.875  picItem=20.584  axisErr=-10.709  capErr=-1.725
/// t=32 cur=10.93 pic=10.875 picItem=21.584  axisErr=-10.709  capErr=-0.058   <- crossed item 21.000
/// memprobe: prodShift=-10.67s hostShift=-9.00s seams=2
/// ```
///
/// `prodShift` against `hostShift` names it exactly: the session's axis was `-10.667` and the clock
/// folded `-9.000`, because the playhead sat below the newest seam at 21.000 and the map answered
/// from the one under it. It healed by itself the moment playback crossed 21.000, which is why this
/// reads as a settle rather than as a wrong axis.
@Suite("AE#448: an epoch worth nothing still owns the stretch it took over")
struct Issue448EpochSeamTests {

    // MARK: - The record

    @Test("an epoch that opened on its boundary is recorded")
    func zeroWorthEpochIsRecorded() {
        // The entry is what says "an epoch begins here". Without it the placement publishes nothing,
        // and the stretch from that placement upward keeps the seam below it.
        let table = HLSVideoEngine.epochShiftTable([:], recordingEpochAt: 0, shift: 0)
        #expect(table[0] == 0)
    }

    @Test("recording an epoch still drops every entry at and above it")
    func recordingStillDropsAbove() {
        // A producer that starts writing at an index rewrites everything from there forward, so an
        // older epoch's offset must stop being claimed for those segments.
        var table = HLSVideoEngine.epochShiftTable([:], recordingEpochAt: 13, shift: -9.0)
        table = HLSVideoEngine.epochShiftTable(table, recordingEpochAt: 3, shift: -1.667)
        #expect(table[3] == -1.667)
        #expect(table[13] == nil)
        // And the same for an epoch worth nothing, which is the case AE#448 turned on.
        table = HLSVideoEngine.epochShiftTable(table, recordingEpochAt: 0, shift: 0)
        #expect(table[0] == 0)
        #expect(table[3] == nil)
    }

    // MARK: - What the seam is for

    @Test("an epoch worth nothing leaves the axis where it is")
    func zeroWorthKeepsTheAxis() {
        // Its content begins exactly at its advertised start, so the placement adds nothing. The
        // picture agrees: axisErr read -10.709 before and after that epoch took over.
        #expect(HLSVideoEngine.axisShift(after: -10.667, placing: 0, presentationLead: 0) == -10.667)
    }

    @Test("the seam belongs at the placement, which is below the newest one after a backward seek")
    func seamSitsAtThePlacement() {
        // seg0 advertised at 0.000 with the axis at -10.667 is placed at item 10.667, and the seam it
        // needs sits there, under the 21.000 the previous epoch left behind.
        #expect(HLSVideoEngine.seamItemSeconds(advertisedStart: 0.0, currentShift: -10.667) == 10.667)
    }

    @Test("without that seam the map answers from the epoch underneath")
    func mapFoldsTheOlderShiftWithoutTheSeam() {
        // The state at t=25 above, reproduced: two seams, playhead at item 14.584.
        var map = PresentationAxisMap.anchored(shiftSeconds: -9.0)
        map.appendSeam(shiftSeconds: -10.667, activatingAtItemSeconds: 21.0)
        #expect(map.shiftSeconds(atItemSeconds: 14.584) == -9.0)
        // Which puts the clock 1.667 s above the picture: the source at that item position reads
        // 5.584 where the frame on screen is 3.917.
        #expect(abs(map.sourceSeconds(forItemSeconds: 14.584)! - 5.584) < 0.001)
        // And it heals by itself one item second later, at 21.000, which is the settle in the log.
        #expect(map.shiftSeconds(atItemSeconds: 21.584) == -10.667)
    }

    @Test("with the seam the map describes the picture from the first frame of the epoch")
    func mapFoldsTheEpochsOwnShift() {
        var map = PresentationAxisMap.anchored(shiftSeconds: -9.0)
        map.appendSeam(shiftSeconds: -10.667, activatingAtItemSeconds: 21.0)
        // What the fix publishes: the same axis, at the placement of an epoch worth nothing.
        map.appendSeam(shiftSeconds: -10.667, activatingAtItemSeconds: 10.667)
        #expect(map.shiftSeconds(atItemSeconds: 14.584) == -10.667)
        #expect(abs(map.sourceSeconds(forItemSeconds: 14.584)! - 3.917) < 0.001)
        // The seam it replaced is gone rather than shadowing it: the epoch rewrote everything above.
        #expect(map.shiftSeconds(atItemSeconds: 21.584) == -10.667)
    }

    // MARK: - The check from AE#418 still passes on it

    @Test("a placement worth nothing verifies like any other")
    func zeroWorthPlacementVerifies() {
        // AVPlayer holds seg0 from item 10.667, which inverts to the base the composition assumed.
        let reading = HLSVideoEngine.placementReading(
            advertisedStart: 0.0, worth: 0, assumedBase: -10.667, observedItemStart: 10.667)!
        #expect(abs(reading.residual) < HLSVideoEngine.axisRepublishEpsilonSeconds)
        #expect(abs(reading.axis - -10.667) < 0.001)
    }
}
