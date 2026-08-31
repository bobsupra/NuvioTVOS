import Foundation
import Testing
@testable import AetherEngine

/// AE#446 round 4: the engine's own rejoin after an outage is not the host's scrubber, and the range
/// it is measured against is the producer's, not either of the two clocks the session publishes.
///
/// Reported from a device run on 6.56.3 (cmcpherson274): the swap carried the place the viewer held
/// and the replay of that position was refused before it could land, `seek(to:139.18) ignored: live,
/// DVR disabled` -> `rejected(liveWithoutDVR)`. That client keeps its rewind outside the engine, so
/// `LoadOptions.dvrWindowSeconds` is nil and the session advertises none.
///
/// Lifting the refusal alone made it worse, which the harness measured before this was believed:
/// the carried 71.40 s landed at 43.40 s, because the fresh item's `seekableEnd` at the readiness
/// instant the rejoin replays in had not caught up (43.40 s while the published edge said 53.40 s and
/// the producer was already cutting past 100 s). Both published edges are stale at that moment, in
/// opposite directions. The cache is not.
@Suite("AE#446 rejoin without a DVR window")
struct Issue446RejoinWithoutDVRTests {

    private let axis = PresentationAxisMap.anchored(shiftSeconds: 0)

    /// The harness numbers: an outage held to 71.40 s, an item reporting 43.40 s at readiness, a
    /// producer that had been cutting again for several segments.
    private func liveOnlyWindow(edge: Double = 53.4, residentFloor: Double? = 20.0) -> LiveWindow {
        var window = LiveWindow(windowSeconds: nil)
        window.noteEdge(edge)
        window.noteResidentFloor(residentFloor)
        return window
    }

    // MARK: - The refusal, which is the host's contract and not the engine's

    @Test("a host scrub is still refused on a session that advertises no rewind")
    func hostScrubStillRefused() {
        #expect(AetherEngine.liveSeekRefusedWithoutDVR(origin: .host, windowSeconds: nil))
        #expect(!AetherEngine.liveSeekRefusedWithoutDVR(origin: .host, windowSeconds: 1800))
    }

    @Test("the engine's own rejoin is not refused by the scrubber's guard")
    func rejoinNotRefused() {
        #expect(!AetherEngine.liveSeekRefusedWithoutDVR(origin: .liveRejoin, windowSeconds: nil))
    }

    // MARK: - The landing, measured against the producer

    /// The statement of the defect, in both halves. Refusing costs the placement outright; accepting
    /// it against the item's own sample lands 28 s below the place held, which is worse.
    @Test("clamping a carried rejoin against the published clocks loses the place either way")
    func publishedClocksLoseThePlace() {
        let window = liveOnlyWindow()
        // What the advertised clamp says on a session with no window: the edge, whatever was asked.
        #expect(abs(window.clamp(71.40, edge: 43.40) - 43.40) < 0.01)
        // And with a window, the same stale item edge binds just as hard.
        var dvr = LiveWindow(windowSeconds: 1800)
        dvr.noteEdge(53.4)
        dvr.noteResidentFloor(20.0)
        #expect(abs(dvr.clamp(71.40, edge: 43.40) - 43.40) < 0.01)
    }

    @Test("a carried rejoin lands on the place the producer still holds")
    func rejoinLandsOnWhatTheProducerHolds() {
        let landing = AetherEngine.liveSeekLanding(
            requested: 71.40, window: liveOnlyWindow(), itemEnd: 43.40, shift: 0,
            axis: axis, origin: .liveRejoin, residentRange: 20.0...110.0)
        #expect(abs(landing.sessionTarget - 71.40) < 0.01)
        #expect(abs(landing.clockTarget - 71.40) < 0.01)
    }

    @Test("a host scrub is still measured against what the session advertises")
    func hostLandingUnchanged() {
        let landing = AetherEngine.liveSeekLanding(
            requested: 71.40, window: liveOnlyWindow(), itemEnd: 43.40, shift: 0,
            axis: axis, origin: .host, residentRange: 20.0...110.0)
        #expect(abs(landing.sessionTarget - 43.40) < 0.01)
    }

    /// The place can genuinely be gone: a live-only session retains
    /// `LiveWindowSizing.liveOnlyFloorSeconds`, and an outage plus the backlog that follows it can
    /// slide the floor past where the viewer was. The oldest surviving second is the answer then,
    /// for the same reason `LiveReloadPolicy.recoveryRejoinPosition` clamps rather than refuses.
    @Test("a place the cache has evicted clamps to the oldest second that survives")
    func evictedPlaceClampsToTheFloor() {
        let landing = AetherEngine.liveSeekLanding(
            requested: 71.40, window: liveOnlyWindow(), itemEnd: 43.40, shift: 0,
            axis: axis, origin: .liveRejoin, residentRange: 80.0...140.0)
        #expect(abs(landing.sessionTarget - 80.0) < 0.01)
    }

    @Test("a rejoin above everything resident comes back to the newest second there is")
    func aboveTheCeilingClampsToTheCeiling() {
        let landing = AetherEngine.liveSeekLanding(
            requested: 200.0, window: liveOnlyWindow(), itemEnd: 43.40, shift: 0,
            axis: axis, origin: .liveRejoin, residentRange: 20.0...110.0)
        #expect(abs(landing.sessionTarget - 110.0) < 0.01)
    }

    /// The degradation that must stay: no cache to ask (the software live path, or before the first
    /// segment is resident) leaves the rejoin exactly where it was before this round.
    @Test("a rejoin with no resident range to read falls back to the window clamp")
    func withoutAResidentRangeNothingMoves() {
        let landing = AetherEngine.liveSeekLanding(
            requested: 71.40, window: liveOnlyWindow(), itemEnd: 43.40, shift: 0,
            axis: axis, origin: .liveRejoin, residentRange: nil)
        #expect(abs(landing.sessionTarget - 43.40) < 0.01)
    }

    /// The seam-aware conversion is unchanged by any of this: the item time a position was muxed at
    /// is read from the shift that was in force for THAT position.
    @Test("a rejoin still reads the seam its position belongs to")
    func rejoinReadsItsOwnSeam() {
        var window = LiveWindow(windowSeconds: nil)
        window.noteEdge(718.83)
        var seamed = PresentationAxisMap.anchored(shiftSeconds: 271.90)
        seamed.appendSeam(shiftSeconds: 320.95, activatingAtItemSeconds: 397.88)
        let landing = AetherEngine.liveSeekLanding(
            requested: 602.48, window: window, itemEnd: 397.882, shift: 271.90,
            axis: seamed, origin: .liveRejoin, residentRange: 400.0...720.0)
        #expect(abs(landing.sessionTarget - 602.48) < 0.01)
        #expect(abs(landing.clockTarget - 330.58) < 0.01)
    }

    // MARK: - What the host reads is untouched

    /// The advertised range is what hosts read to decide whether to draw a scrubber, and a rejoin
    /// reading the cache must not move it.
    @Test("reading the cache does not advertise a rewind the session does not offer")
    func advertisedRangeStaysNil() {
        #expect(liveOnlyWindow().seekableRange == nil)
        #expect(liveOnlyWindow().seekableRange(edge: 110.0) == nil)
    }

    @Test("a healthy DVR scrub is unchanged")
    func healthyDVRScrubUnchanged() {
        var window = LiveWindow(windowSeconds: 1800)
        window.noteEdge(288.4)
        window.noteResidentFloor(1.4)
        let landing = AetherEngine.liveSeekLanding(
            requested: 88.4, window: window, itemEnd: 287.0, shift: 1.4,
            axis: PresentationAxisMap.anchored(shiftSeconds: 1.4))
        #expect(abs(landing.sessionTarget - 88.4) < 0.01)
    }
}

/// AE#446 round 4, the third ceiling the first two were hiding: an item attached after the live
/// window has slid runs on its own timeline, and the session had no term for that.
///
/// AVPlayer places a live playlist's content by the PLAYLIST it was handed, so a fresh item's zero is
/// the first segment that playlist listed, not the producer's first segment. Measured on the harness:
/// the item's clock read 70.01 s while the picture was at session 121.4 s, its own seekable range read
/// 0.00..42.00 s while the producer held 51.40..111.40 s, and the rejoin to "the place it held" jumped
/// 50 s forward to the live edge, skipping the whole outage backlog. Every DVR leg had passed only
/// because an 1800 s window never slides inside one run.
@Suite("AE#446 the item's own axis")
struct Issue446ItemAxisTests {

    /// The harness numbers, sampled three times across twelve seconds of sliding. Both floors move and
    /// their difference does not, which is what makes it a measurement rather than a guess.
    @Test("the offset holds still while both floors slide")
    func offsetIsStableAcrossTheSlide() {
        let samples: [(producer: Double, item: Double)] = [
            (51.40, 0.00), (56.40, 5.00), (66.40, 15.00),
        ]
        for sample in samples {
            let offset = AetherEngine.liveItemAxisOffset(
                producerFloorSession: sample.producer, itemSeekableStart: sample.item, shift: 1.40)
            #expect(abs(offset - 50.00) < 0.01)
        }
    }

    /// The item a session starts with: its playlist began at the producer's first segment, so the two
    /// axes are the same one and nothing needed this term until a swap attached a second item.
    @Test("the item a session starts with carries no offset")
    func firstItemHasNoOffset() {
        let offset = AetherEngine.liveItemAxisOffset(
            producerFloorSession: 1.40, itemSeekableStart: 0.00, shift: 1.40)
        #expect(abs(offset) < 0.001)
    }

    @Test("an item claiming to hold more than the producer does not push the axis backwards")
    func negativeOffsetFoldsToZero() {
        let offset = AetherEngine.liveItemAxisOffset(
            producerFloorSession: 10.0, itemSeekableStart: 40.0, shift: 1.40)
        #expect(abs(offset) < 0.001)
    }

    /// The conversion the rejoin actually rides: the place the viewer held is a session position, and
    /// it has to reach the item as a position on the item's own clock.
    @Test("a carried place converts onto the item's own clock")
    func carriedPlaceConvertsOntoTheItemAxis() {
        var window = LiveWindow(windowSeconds: nil)
        window.noteEdge(53.4)
        window.noteResidentFloor(51.40)
        let landing = AetherEngine.liveSeekLanding(
            requested: 71.40, window: window, itemEnd: 42.0, shift: 1.40,
            axis: PresentationAxisMap.anchored(shiftSeconds: 1.40),
            origin: .liveRejoin, residentRange: 51.40...111.40, itemAxisOffset: 50.0)
        #expect(abs(landing.sessionTarget - 71.40) < 0.01)
        // 71.40 - 1.40 - 50.00: what this item calls the place the session calls 71.40.
        #expect(abs(landing.clockTarget - 20.00) < 0.01)
    }

    /// Without the offset the same conversion produced 70.00, which this item resolves against its own
    /// playlist as 50 s further on, which is the live edge. Kept as the statement of the defect.
    @Test("ignoring the offset aims a rejoin at the live edge")
    func withoutTheOffsetTheRejoinAimsAtTheEdge() {
        var window = LiveWindow(windowSeconds: nil)
        window.noteEdge(53.4)
        window.noteResidentFloor(51.40)
        let landing = AetherEngine.liveSeekLanding(
            requested: 71.40, window: window, itemEnd: 42.0, shift: 1.40,
            axis: PresentationAxisMap.anchored(shiftSeconds: 1.40),
            origin: .liveRejoin, residentRange: 51.40...111.40, itemAxisOffset: 0)
        #expect(abs(landing.clockTarget - 70.00) < 0.01)
    }

    /// A host scrub on a swapped item is measured against an edge on the SESSION axis, so the item's
    /// reported end has to be lifted onto it too.
    @Test("the sampled edge of a swapped item is lifted onto the session axis")
    func sampledEdgeIsOnTheSessionAxis() {
        var window = LiveWindow(windowSeconds: 1800)
        window.noteEdge(53.4)
        window.noteResidentFloor(51.40)
        let landing = AetherEngine.liveSeekLanding(
            requested: 200.0, window: window, itemEnd: 42.0, shift: 1.40,
            axis: PresentationAxisMap.anchored(shiftSeconds: 1.40), itemAxisOffset: 50.0)
        // 42.00 + 1.40 + 50.00, not 43.40.
        #expect(abs(landing.sessionTarget - 93.40) < 0.01)
    }
}
