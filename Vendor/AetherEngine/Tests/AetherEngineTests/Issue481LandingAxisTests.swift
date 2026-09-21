import Testing
import Foundation
@testable import AetherEngine

/// AE#481: a standing axis outlives the stretch it was measured for.
///
/// The #418 axis is published once, at the advertised start of the segment whose gate re-aimed below
/// its boundary, and it holds for everything after that seam. Measured with `play --picture-probe`
/// over `Scripts/slowrange.py` at 600 kbps / 300 ms, the arm being the #418 chain with the re-anchoring
/// seek LAST (`--seek-count 5 --seek-pattern 65,60,70,58,75`), the picture says it does not:
///
/// | item | 53.000 | 67.833 | 79.000 | 84.917 | ... | 119.958 |
/// | --- | --- | --- | --- | --- | --- | --- |
/// | `pic - picItem` | **-9.000** | 0.000 | 0.000 | 0.000 | | 0.000 |
///
/// The -9.000 belongs to the run `seg13` opened, not to the timeline from item 52.000 onward. When a
/// seek opens a NEW run at a segment the producer wrote at its planned position, that run is
/// source-true, and the session goes on mapping with the old axis: `capErr=+9.017` from the landing to
/// the end of the session, 2 of 2 runs at 600 kbps / 300 ms and 1 of 1 at 1200 kbps / 200 ms (and not
/// at 3200 kbps / 100 ms, where the landing stays inside the run it was already playing).
///
/// Ten rounds of #418 never saw it standing because a seek burst heals it: the next seek composes a
/// placement whose reading comes off the changed timeline and corrects the axis within a second or
/// two. Only a session whose last re-anchoring seek is also its last seek keeps the error.
///
/// **The discriminator is where the run OPENS, asked of ONE segment**: the first the local server
/// answered after the seek, which is the one whose content opens the run the landing sits in. It goes
/// into a timeline carrying an axis at the seam that axis predicts, and into a timeline carrying
/// nothing at its own position, which is round 7's pair of admissible answers. Asked of the PLAN
/// instead, the same rule publishes on a coincidence, and this suite pins the case that proved it: 31
/// boundaries over 120 s against a half-second tolerance wrote a 0.000 axis into a timeline carrying
/// -27.875 s, `capErr` +0.092 to -27.883 in one tick. A wrong candidate now costs silence.
@Suite("AE#481: the axis belongs to the run, and a landing can read it")
struct Issue481LandingAxisTests {

    /// PR #533: the same arm on the same bytes remuxed with `-output_ts_offset 600`, so the item axis
    /// runs 0 to 120 s over a source that runs 600 to 720 s, which is the reporter's geometry.
    ///
    /// The run holding the landing has no placement offset left to carry, and the reading below is
    /// what "nothing to place" meant until #533: item time is source time here. It is not. Those
    /// bytes were folded by the producer's 600 s normalization like every other segment of the run,
    /// and publishing a zero for them took `capErr` from -600.000 to +0.017 in one tick and put the
    /// host clock at `cur=-515.10` for the rest of the session.
    @Test("a rebuilt run still carries the normalization its bytes were written with")
    func landingOnARebuiltRunCarriesTheNormalization() {
        let reading = HLSVideoEngine.landingAxisReading(
            landingItemSeconds: 84.0,
            ranges: [(52.0, 61.0), (72.0, 119.958)],
            openingSegmentStart: 72.0,
            worth: 600.0,
            assumedBase: -9.0,
            standingAxis: 591.0)
        #expect(reading?.axis == 600.0)
        #expect(reading?.runStart == 72.0)
    }

    /// The measured arm. The session maps with -9.000, the run holding the landing opens at the
    /// playlist position of the segment that opened it, so that run carries what the segment is worth,
    /// which on a source whose timestamps start at zero is nothing.
    @Test("a run opened on its segment's own playlist position carries what the segment is worth")
    func landingOnARebuiltRunReadsZero() {
        let reading = HLSVideoEngine.landingAxisReading(
            landingItemSeconds: 84.917,
            ranges: [(52.0, 61.0), (75.125, 119.958)],
            openingSegmentStart: 75.125,
            worth: 0,
            assumedBase: -9.0,
            standingAxis: -9.0)
        #expect(reading?.axis == 0.0)
        #expect(reading?.runStart == 75.125)
    }

    /// Round 2's arm, which must not change: the landing stays inside the run that carries the axis, so
    /// the run opens where the composition says it should and there is nothing to correct.
    @Test("a run that opens where the composition predicts is the timeline this session knows")
    func ownRunIsSilent() {
        #expect(HLSVideoEngine.landingAxisReading(
            landingItemSeconds: 80.0,
            ranges: [(84.125, 119.0)],
            openingSegmentStart: 75.125,
            worth: 0,
            assumedBase: -9.0,
            standingAxis: -9.0) == nil)
    }

    /// The false positive this rule was rewritten to exclude, measured before it was: asking the whole
    /// plan whether a run opens on "a" playlist position is a coincidence 31 boundaries wide, and on the
    /// #418 chain it published a 0.000 axis into a timeline carrying -27.875 s (`capErr` +0.092 to
    /// -27.883 in one tick). Asked of the segment that actually opened the run, the same numbers are
    /// silent: the opening matches neither its predicted seam nor its own position.
    @Test("a run opening near some other segment's boundary is not this segment's")
    func aCoincidingBoundaryIsNotARebuild() {
        #expect(HLSVideoEngine.landingAxisReading(
            landingItemSeconds: 122.875,
            ranges: [(115.875, 140.0)],
            openingSegmentStart: 143.75,
            worth: 0,
            assumedBase: -27.875,
            standingAxis: -27.875) == nil)
    }

    @Test("no run holds the landing, so there is nothing to read")
    func noRunHoldsTheLanding() {
        #expect(HLSVideoEngine.landingAxisReading(
            landingItemSeconds: 200.0,
            ranges: [(52.0, 96.0)],
            openingSegmentStart: 52.0,
            worth: -9.0,
            assumedBase: 0,
            standingAxis: -9.0) == nil)
    }

    /// A run opens where its segment's content begins, which is a frame or two off the boundary on
    /// reordered material. The placement reading's tolerance covers it.
    @Test("an opening a frame off its own position is still its own")
    func frameScaleToleranceHolds() {
        let reading = HLSVideoEngine.landingAxisReading(
            landingItemSeconds: 78.0,
            ranges: [(75.167, 119.958)],
            openingSegmentStart: 75.125,
            worth: 0,
            assumedBase: -9.0,
            standingAxis: -9.0)
        // The run opens a frame ABOVE the position, so its content sits a frame below it, which is the
        // same arithmetic a placement reading does with its residual.
        #expect(abs((reading?.axis ?? .nan) + 0.042) < 0.0005)
    }

    /// What the opening segment is worth is part of the reading: a run opened by a re-aimed segment
    /// carries that offset, not zero.
    @Test("a run opened by a re-aimed segment carries its offset")
    func runOpenedByAReaimedSegmentReadsItsWorth() {
        let reading = HLSVideoEngine.landingAxisReading(
            landingItemSeconds: 60.0,
            ranges: [(52.0, 96.0)],
            openingSegmentStart: 52.0,
            worth: -9.0,
            assumedBase: -14.0,
            standingAxis: -14.0)
        #expect(reading?.axis == -9.0)
    }

    /// With no standing axis the two admissible answers are the same position, so a landing has nothing
    /// to tell apart and says nothing. A re-aim from zero always arrives with a placement, which is the
    /// reading that owns that case.
    @Test("without a standing axis the two answers coincide and the landing is silent")
    func noStandingAxisMeansNoDiscriminator() {
        #expect(HLSVideoEngine.landingAxisReading(
            landingItemSeconds: 55.0,
            ranges: [(52.0, 96.0)],
            openingSegmentStart: 52.0,
            worth: -9.0,
            assumedBase: 0,
            standingAxis: 0) == nil)
    }

    /// Reading back what is already standing is not a correction, and republishing it would re-arm the
    /// verification for the rest of the session.
    @Test("a reading that agrees with the standing axis publishes nothing")
    func agreementIsSilent() {
        #expect(HLSVideoEngine.landingAxisReading(
            landingItemSeconds: 78.0,
            ranges: [(75.125, 119.958)],
            openingSegmentStart: 75.125,
            worth: 0,
            assumedBase: -9.0,
            standingAxis: 0) == nil)
    }
}
