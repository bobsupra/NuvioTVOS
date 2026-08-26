import Testing
@testable import AetherEngine

/// AE#408: the seek-deadline reconcile budget spends 12 s (8 s + one extension) on a target the
/// producer is not serving, and the residency gate leaves the producer aimed somewhere else while it
/// does. Both halves rest on a measurement, and both measurements proved less than they claimed.
@Suite("AE#408 reconcile evidence")
struct Issue408ReconcileEvidenceTests {

    // MARK: - The island has to be AT the target

    @Test("media downstream of the target is not evidence that the target is served")
    func downstreamIslandIsNotAnIslandAtTheTarget() {
        // Reporter's shape: island=7.30s reported at the target while `rendered == bufferedEnd` and the
        // seek never lands. Nothing was loaded at the target at all; the figure came from a band 20 s
        // downstream, which the 30 s measurement window swept up whole. Had the target itself carried
        // 7.3 s, AVPlayer would have landed on it instead of parking.
        #expect(NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: [(start: 266.1, end: 273.4)], target: 246.57) == 0.0)

        // The same depth with the target covered reads as what it is: the producer is serving there.
        let served = NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: [(start: 246.0, end: 253.3)], target: 246.57)
        #expect(abs(served - 7.3) < 0.001)
    }

    @Test("the window still measures how deep the served region runs")
    func coverageGatesTheWindowItDoesNotShrinkIt() {
        // Coverage is a gate on the reading, not a cap: once the target is covered, a producer that has
        // marched on past it is credited for the whole run, holes and all. That is what separates a
        // producer still filling (extend) from one that served a little and stopped (recover).
        let deep = NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: [(start: 246.0, end: 252.0), (start: 254.0, end: 262.0)], target: 246.57)
        #expect(abs(deep - 14.0) < 0.001)
    }

    @Test("a segment boundary just above the target still counts as covering it")
    func coverageAllowsTheBoundaryTolerance() {
        // The producer re-anchors on a segment boundary, so the first range it serves can start a
        // fraction above a target that sits at the very start of that segment. The tolerance the
        // window already uses on its lower edge is the same one coverage is judged by.
        let boundary = NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: [(start: 246.9, end: 254.9)], target: 246.57)
        #expect(abs(boundary - 8.0) < 0.001)
    }

    @Test("the AE#216 slow-source island keeps counting")
    func slowSourceIslandStillCounts() {
        // Regression anchor for the case the extension budget exists for: a slow SMB / DV source whose
        // producer IS serving the target, from the target forward, while the pre-seek playhead's own
        // buffer sits far below the window.
        let forwardIsland = NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: [(start: 440.0, end: 450.0), (start: 1288.0, end: 1294.4)], target: 1288.14)
        #expect(abs(forwardIsland - 6.4) < 0.001)
    }

    @Test("the near-backward exclusion bound still reports nothing at the target")
    func exclusionBoundStillReportsNothing() {
        // #216 hardening anchor: a backward seek shorter than the measurement window leaves the
        // abandoned playhead's full buffer inside it, and the bound is what keeps that out.
        #expect(NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: [(start: 1200.0, end: 1230.0)], target: 1185.0, excludeAtOrAbove: 1200.0) == 0.0)
        // Genuine progress at the same target, below the bound, still counts.
        #expect(NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: [(start: 1185.0, end: 1191.0), (start: 1200.0, end: 1230.0)],
            target: 1185.0, excludeAtOrAbove: 1200.0) == 6.0)
    }

    // MARK: - A resident target segment is not a producer aimed at the target

    @Test("a shallow resident run does not license leaving the producer where it is")
    func shallowResidentRunReanchors() {
        // Measured on the `aetherctl play` repro: a backward seek landed in a 3-segment scrub band
        // (38...40) while the pump sat at 113. Nothing re-anchored it; the consumer walked the band in
        // 4 s and asked for seg41 with 5 s of buffer left, which is when the restart was finally paid.
        #expect(!VideoSegmentProvider.residentBackwardTargetKeepsProducer(
            index: 38, residentFrontier: 40, activeMarchFront: 113, prefetchDepth: 8))
    }

    @Test("a resident run that reaches the march front has no gap to fall into")
    func residentRunReachingTheFrontKeepsProducer() {
        // The Continuous-Audio handover refetch the residency gate was added for: ~8 segments backward
        // into content the ACTIVE pump is still writing, so the run carries the consumer straight back
        // into the live output. Restarting here re-arms the FLAC bridge and glitches the audio.
        #expect(VideoSegmentProvider.residentBackwardTargetKeepsProducer(
            index: 96, residentFrontier: 108, activeMarchFront: 104, prefetchDepth: 8))
    }

    @Test("a deep resident run is asked for its gap with a full prefetch cushion")
    func deepResidentRunKeepsProducer() {
        // Back-scrub to the head of a file whose first 21 segments are still resident, pump at 300.
        // The run ends far below the front, but AVPlayer asks for the missing index 5-7 segments before
        // it plays it, so the existing out-of-range restart runs with a full cushion. Re-anchoring here
        // would also re-produce 80 s of content that is already on disk.
        #expect(VideoSegmentProvider.residentBackwardTargetKeepsProducer(
            index: 0, residentFrontier: 20, activeMarchFront: 300, prefetchDepth: 8))
        // One segment short of the cushion is the shape that stalls.
        #expect(!VideoSegmentProvider.residentBackwardTargetKeepsProducer(
            index: 0, residentFrontier: 6, activeMarchFront: 300, prefetchDepth: 8))
    }

    @Test("a pump at or behind the target will march into it")
    func pumpBelowTargetKeepsProducer() {
        // Front at or below the target: there is no gap between the resident run and the pump's own
        // output, because the pump is on its way up into it.
        #expect(VideoSegmentProvider.residentBackwardTargetKeepsProducer(
            index: 40, residentFrontier: 41, activeMarchFront: 38, prefetchDepth: 8))
    }
}
