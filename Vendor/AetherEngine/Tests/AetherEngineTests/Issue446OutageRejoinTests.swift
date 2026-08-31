import Foundation
import Testing
@testable import AetherEngine

/// AE#446 round 3: where the rejoin after an outage lands, and how long the wait for the source is
/// allowed to last.
///
/// Round 2 made the runway reachable and gave the session somewhere to go when it ran out. Two device
/// legs then measured what round 2 could not: the swap put a timeshifted viewer on the live edge, and
/// the source read the hold was waiting on had already been abandoned by the no-cut watchdog.
@Suite("AE#446 outage rejoin")
struct Issue446OutageRejoinTests {

    // MARK: - The landing

    /// The regime both device reports were in: the item that saw the ENDLIST stops reloading its
    /// playlist, so nothing advances the published edge, while the playhead legitimately runs on
    /// through the runway. The held position is then ABOVE the edge the window still advertises.
    @Test("a held position past a frozen edge is not clamped back onto it")
    func heldPositionSurvivesAFrozenEdge() {
        var window = LiveWindow(windowSeconds: 1800)
        window.noteEdge(163.4)          // frozen when the source stopped
        window.noteResidentFloor(1.4)
        // The fresh item has loaded the live playlist again: 252 s of item time, shift 1.4 s.
        let landing = AetherEngine.liveSeekLanding(
            requested: 181.4, window: window, itemEnd: 252.0, shift: 1.4,
            axis: PresentationAxisMap.anchored(shiftSeconds: 1.4))
        #expect(abs(landing.sessionTarget - 181.4) < 0.01)
        #expect(abs(landing.clockTarget - 180.0) < 0.01)
    }

    /// What the old formula did with the same inputs, kept as the statement of the defect: the clamp
    /// pulled the target onto the stale edge, `behind` collapsed to zero, and the conversion then
    /// resolved to the fresh item's own edge.
    @Test("the edge-delta form lands a frozen-edge rejoin on the live edge")
    func edgeDeltaFormLandsOnTheEdge() {
        var window = LiveWindow(windowSeconds: 1800)
        window.noteEdge(163.4)
        window.noteResidentFloor(1.4)
        let clampedToStaleEdge = window.clamp(181.4)
        let behind = window.edgeTime - clampedToStaleEdge
        #expect(abs(behind) < 0.01)
        #expect(abs((252.0 - behind) - 252.0) < 0.01)   // the live edge, 72 s past the place held
    }

    /// The reported backward landing: an edge published while the producer had already rebased
    /// (shift 320.95) against an item still presenting the old epoch (shift 271.90). The seam-aware
    /// conversion reads the shift that was in force for THIS position instead.
    @Test("a rejoin does not follow a rebase the position predates")
    func rejoinReadsTheSeamItsPositionBelongsTo() {
        var window = LiveWindow(windowSeconds: 1800)
        window.noteEdge(718.83)         // 397.882 + 320.95, published on the new shift
        window.noteResidentFloor(100.0)
        var axis = PresentationAxisMap.anchored(shiftSeconds: 271.90)
        axis.appendSeam(shiftSeconds: 320.95, activatingAtItemSeconds: 397.88)
        let landing = AetherEngine.liveSeekLanding(
            requested: 602.48, window: window, itemEnd: 397.882, shift: 271.90, axis: axis)
        #expect(abs(landing.sessionTarget - 602.48) < 0.01)
        // 602.48 - 271.90: the item time this content was muxed at, not 397.882 - 116.35.
        #expect(abs(landing.clockTarget - 330.58) < 0.01)
    }

    @Test("a healthy DVR seek is unchanged")
    func healthySeekIsUnchanged() {
        var window = LiveWindow(windowSeconds: 1800)
        window.noteEdge(288.4)
        window.noteResidentFloor(1.4)
        let landing = AetherEngine.liveSeekLanding(
            requested: 88.4, window: window, itemEnd: 287.0, shift: 1.4,
            axis: PresentationAxisMap.anchored(shiftSeconds: 1.4))
        #expect(abs(landing.sessionTarget - 88.4) < 0.01)
        #expect(abs(landing.clockTarget - 87.0) < 0.01)
    }

    @Test("a target beyond the sampled edge still clamps to it")
    func beyondTheEdgeStillClamps() {
        var window = LiveWindow(windowSeconds: 1800)
        window.noteEdge(288.4)
        window.noteResidentFloor(1.4)
        let landing = AetherEngine.liveSeekLanding(
            requested: 999.0, window: window, itemEnd: 287.0, shift: 1.4,
            axis: PresentationAxisMap.anchored(shiftSeconds: 1.4))
        #expect(abs(landing.sessionTarget - 288.4) < 0.01)
        #expect(abs(landing.clockTarget - 287.0) < 0.01)
    }

    @Test("a target below the resident floor still clamps to it")
    func belowTheFloorStillClamps() {
        var window = LiveWindow(windowSeconds: 60)
        window.noteEdge(288.4)
        window.noteResidentFloor(240.0)
        let landing = AetherEngine.liveSeekLanding(
            requested: 10.0, window: window, itemEnd: 287.0, shift: 1.4,
            axis: PresentationAxisMap.anchored(shiftSeconds: 1.4))
        #expect(abs(landing.sessionTarget - 240.0) < 0.01)
    }

    /// An item with no seekable range of its own yet: there is nothing to sample, so the window's own
    /// edge is what is left. Without this the clamp would collapse onto the shift.
    @Test("an item with no range yet falls back to the published edge")
    func unloadedItemFallsBackToTheWindow() {
        var window = LiveWindow(windowSeconds: 1800)
        window.noteEdge(288.4)
        window.noteResidentFloor(1.4)
        let landing = AetherEngine.liveSeekLanding(
            requested: 200.0, window: window, itemEnd: 0, shift: 1.4,
            axis: PresentationAxisMap.anchored(shiftSeconds: 1.4))
        #expect(abs(landing.sessionTarget - 200.0) < 0.01)
        #expect(abs(landing.clockTarget - 198.6) < 0.01)
    }

    // MARK: - The wait

    /// The device leg's finding: the hold says it is watching for the source to cut again, and the
    /// no-cut watchdog abandons the source read 35 s after the last cut, which is the only thing that
    /// could ever observe it. Measured on the harness: with a 76 s outage the read was aborted at
    /// +35 s while 46 s of runway were still playing, and the source coming back at +76 s was never
    /// seen at all.
    @Test("a starved source is not abandoned while its runway is still feeding the consumer")
    func outageRunwayKeepsTheReadAlive() {
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 40, readRate: 0.4, videoPtsAdvanceSeconds: 0.5, consecutiveHolds: 0,
            servingOutageRunway: true
        ) == .holdForSlowDelivery)
    }

    @Test("the same stall without a runway to serve still exits")
    func withoutRunwayTheExitStands() {
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 40, readRate: 0.4, videoPtsAdvanceSeconds: 0.5, consecutiveHolds: 0,
            servingOutageRunway: false
        ) == .exitForRetune)
    }

    /// The wait is bounded by the hold budget that already exists, so a consumer that stops fetching
    /// with runway still listed cannot hold a dead source open for the rest of the session.
    @Test("the outage wait ends at the existing hold budget")
    func outageWaitIsBounded() {
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 40, readRate: 0.4, videoPtsAdvanceSeconds: 0.5,
            consecutiveHolds: HLSSegmentProducer.liveSlowDeliveryMaxHolds,
            servingOutageRunway: true
        ) == .exitForRetune)
    }

    @Test("a cutter wedge is not an outage and still exits at its own timeout")
    func wedgeIsUnaffected() {
        #expect(HLSSegmentProducer.noCutStallAction(
            stalledFor: 11, readRate: 60, videoPtsAdvanceSeconds: 0, consecutiveHolds: 0,
            servingOutageRunway: true
        ) == .exitForRetune)
    }
}
