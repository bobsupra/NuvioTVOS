import Foundation
import Testing
@testable import AetherEngine

/// AE#523: a healthy source was judged by the client's patience, so every ordinary delivery closed the
/// window.
///
/// Captured on a device. The upstream hands over about 6 s of media at a time and the cutter makes 3 s
/// segments of it, so segments finalize in PAIRS 30 ms apart and then nothing is heard for the rest of
/// the delivery interval:
///
///     15:55:34.708  live seg-17 finalized: dur=3.000s
///     15:55:34.736  live seg-18 finalized: dur=3.000s
///     15:55:41.251  live seg-19 finalized: dur=3.000s
///     15:55:41.277  live seg-20 finalized: dur=3.000s
///
/// TARGETDURATION sealed at 4, so the client's patience is 6.0 s, and the delivery interval runs 6.50
/// to 6.85 s. Every single burst was therefore read as the source having stopped: ENDLIST, the item
/// played out its runway, and a swap the viewer sees. Two of them 31.4 s apart in the captured minute,
/// on a session delivering 72 s of media per 64 s of wall clock, which is to say not behind at all.
@Suite("AE#523 a source is judged by its own delivery rhythm")
struct Issue523SourceCadenceLatenessTests {

    /// The device capture, as the meter sees it: one short interval inside each pair, one wide one
    /// between pairs. The short ones are inside a single delivery and the meter drops them (AE#524).
    private var fieldIntervals: [Double] {
        [0.028, 6.85, 0.032, 6.52, 0.026, 6.59, 0.028, 6.50, 0.032, 6.85, 0.033, 6.53]
    }

    private func meter(_ intervals: [Double]) -> SourceDeliveryCadenceMeter {
        var m = SourceDeliveryCadenceMeter()
        for i in intervals { m.note(intervalSeconds: i) }
        return m
    }

    @Test("the meter reads the wide gap, not the pair")
    func theMeterReadsTheDeliveryInterval() {
        let cadence = meter(fieldIntervals).cadenceSeconds
        #expect(cadence != nil)
        // The second largest of what is left once the intra-delivery intervals are dropped.
        #expect(abs((cadence ?? 0) - 6.85) < 0.001)
        // A mean would have read 2.9 s here, which is not an interval this source ever takes.
        #expect((cadence ?? 0) > 6.0)
    }

    /// AE#524: the same meter, on a device, read "it delivers every 0.04s" for a source delivering
    /// every 6.5 s, and the window then closed on the first quiet stretch. A backlogged join fills the
    /// whole sample window with intervals INSIDE one delivery: the origin hands over its window at I/O
    /// speed, the cutter finalizes five segments in 55 ms, and every one of those is 30 ms from the
    /// last. Dropping the single worst sample then threw away the only real interval there was.
    @Test("a backlogged join is one delivery, not five")
    func abacklogIsNotARhythm() {
        // The device capture, verbatim: seg-0 to seg-4 of a fastZap join.
        let backlog = meter([0.039, 0.016, 3.532, 0.036])
        // Not "every 0.04s", which is what the close fired on. One real interval is not a rhythm
        // either, so the honest answer here is that this meter has nothing to say yet.
        #expect(backlog.cadenceSeconds == nil)
        // Which leaves the client's own patience, and that is NOT enough on this source: 1.5 x
        // TARGETDURATION is 6.0 s against a 6.45 s quiet stretch. The ingest's arrival meter is what
        // covers the start, and the test below is the one that matters for a fastZap join.
        #expect(LiveEdgePolicy.sourceLateSeconds(targetDuration: 4,
                                                 cadenceSeconds: backlog.cadenceSeconds) == 6.0)
    }

    @Test("the ingest's own arrival meter is the better measurement, and it is there sooner")
    func theIngestFloorCarriesTheStart() {
        // The upstream's measured arrival cadence, which this session had before the provider had
        // finalized its second segment: 6.000 s, so a 6.45 s quiet stretch is not late.
        let late = LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: 6.0)
        #expect(abs(late - 7.5) < 0.001)
        #expect(6.45 < late)
    }

    @Test("none of the captured gaps is late any more, and every one of them used to be")
    func theFieldCaptureNoLongerReadsAsAnOutage() {
        let cadence = meter(fieldIntervals).cadenceSeconds
        let late = LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: cadence)
        // The four silences the log printed before it closed the window.
        for silence in [6.02, 6.52, 6.56, 6.85] {
            #expect(silence <= late)
            // The old reading, TARGETDURATION alone, called every one of them a stopped source.
            #expect(silence > LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * 4)
        }
    }

    @Test("a source that stops for good still closes the window")
    func arealOutageStillCloses() {
        let cadence = meter(fieldIntervals).cadenceSeconds
        let late = LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: cadence)
        let ceiling = LiveEdgePolicy.outageCloseCeilingSeconds(targetDuration: 4, cadenceSeconds: cadence)
        #expect(ceiling > late)
        // AE#523 round 2: the close is not a deadline on the silence any more, so what this pins is
        // the one clock bound left, the producer's own patience with a source that cuts nothing.
        #expect(abs(ceiling - 29.0) < 0.001)
        #expect(ceiling <= HLSSegmentProducer.liveSourceStarvationTimeoutSeconds)
    }

    @Test("one outage does not teach the meter to be patient with the next")
    func theWorstSampleIsDropped() {
        // The same capture with a 30 s stall recorded in the middle of it, which is what happens when
        // the source comes back: the gap is an interval like any other.
        var withStall = fieldIntervals
        withStall[5] = 30.0
        let cadence = meter(withStall).cadenceSeconds
        #expect(abs((cadence ?? 0) - 6.85) < 0.001)
        // Two stalls inside one window do move it, and a source that stalls twice in six deliveries
        // has earned the wider threshold.
        var twice = withStall
        twice[7] = 28.0
        #expect((meter(twice).cadenceSeconds ?? 0) > 20)
    }

    @Test("a source finer than its target duration keeps the client's patience")
    func afineSourceIsUnchanged() {
        // 1 s deliveries against TARGETDURATION 4: judging this source by its own rhythm would call it
        // dead a second after every segment, so the floor is the client's patience and nothing moves.
        let cadence = meter([1.0, 1.02, 0.98, 1.01, 1.0, 1.03]).cadenceSeconds
        #expect(LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: cadence)
                == LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * 4)
    }

    @Test("no measurement means the reading is exactly what it was before")
    func noCadenceIsTheOldBehaviour() {
        for td in 1...30 {
            #expect(LiveEdgePolicy.sourceLateSeconds(targetDuration: td, cadenceSeconds: nil)
                    == LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * Double(td))
            #expect(LiveEdgePolicy.outageCloseCeilingSeconds(targetDuration: td, cadenceSeconds: nil)
                    == LiveEdgePolicy.outageCloseCeilingSeconds(targetDuration: td))
        }
    }

    @Test("a backlogged join has no rhythm to read yet")
    func aBacklogReadsAsNoMeasurement() {
        // An origin that arrives with a window in hand appends it in milliseconds. Reading a rhythm off
        // that would put the threshold under the client's patience on every live join.
        #expect(meter([0.001, 0.002, 0.001]).cadenceSeconds == nil)
        #expect(meter([]).cadenceSeconds == nil)
        let backlog = meter([0.001, 0.002, 0.001, 0.002]).cadenceSeconds
        #expect(LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: backlog)
                == LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * 4)
    }

    @Test("the threshold never waits past the producer's own starvation exit")
    func theCeilingHolds() {
        // A source measured at half a minute per delivery cannot buy a threshold on the far side of the
        // 35 s exit, past which nothing would be served in time to matter.
        let absurd = LiveEdgePolicy.sourceLateSeconds(targetDuration: 4, cadenceSeconds: 30)
        #expect(absurd <= HLSSegmentProducer.liveSourceStarvationTimeoutSeconds
                - LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * 4)
        for cadence in stride(from: 1.0, through: 60.0, by: 0.5) {
            for td in [2, 4, 6, 14] {
                let late = LiveEdgePolicy.sourceLateSeconds(targetDuration: td, cadenceSeconds: cadence)
                let ceiling = LiveEdgePolicy.outageCloseCeilingSeconds(targetDuration: td,
                                                                       cadenceSeconds: cadence)
                #expect(late >= LiveEdgePolicy.unchangedPlaylistPatienceMultiplier * Double(td))
                #expect(ceiling >= late)
                #expect(ceiling <= HLSSegmentProducer.liveSourceStarvationTimeoutSeconds)
            }
        }
    }

    @Test("the meter keeps only a trailing window, so a rhythm change is followed")
    func themeterFollowsTheSource() {
        var m = meter(fieldIntervals)
        // The upstream switches to handing over one segment at a time, every two seconds.
        for _ in 0..<SourceDeliveryCadenceMeter.sampleCount { m.note(intervalSeconds: 2.0) }
        #expect(abs((m.cadenceSeconds ?? 0) - 2.0) < 0.001)
    }
}

/// AE#523 round 2: the same source, judged by its own rhythm since round 1, still lost its window to a
/// clock while the content that would have paid for the wait was in hand.
///
/// Reported on 6.84.0 after a 45 minute session: about 35 of 40 delivery gaps absorbed silently, and 5
/// closes, each one with the silence just past the deadline (two measured deliveries, 7.6 s), 5.8 to
/// 8.5 s of runway still ahead of the consumer, and the source delivering again within a few seconds.
/// Every close cost a visible item swap.
///
/// The mechanism, measured on the harness at TARGETDURATION 6 with a viewer 30 s inside the window
/// against a 22 s freeze: late at 10.07 s of silence holding 24.0 s of runway, closed at 20.10 s of
/// silence holding the same 24.0 s, swapped, and the source was back 2 s after the decision.
@Suite("AE#523 round 2 the content ends the wait, not the clock")
struct Issue523RunwayCarriesTheWaitTests {

    /// The reporter's session: a source delivering every 3.8 s, sealed at TARGETDURATION 2.
    private let reportedCadence = 3.8
    private let reportedTargetDuration = 2

    @Test("the reported closes do not happen any more")
    func theReportedGapsAreAbsorbed() {
        let reserve = LiveEdgePolicy.outageCloseDepthReserveSeconds(
            targetDuration: reportedTargetDuration)
        // Every one of the five closes had more content in hand than the close needs to reach the
        // consumer, so none of them is a close any more.
        for runway in [5.8, 6.5, 7.2, 8.0, 8.5] {
            #expect(runway > reserve)
            #expect(!LiveEdgePolicy.outageCloseOnDepth(depthSeconds: runway,
                                                        targetDuration: reportedTargetDuration))
        }
        // And the clock that used to close them, two measured deliveries, is not a bound any more: what
        // is left is the producer's own patience, which is four times further away.
        let ceiling = LiveEdgePolicy.outageCloseCeilingSeconds(targetDuration: reportedTargetDuration,
                                                              cadenceSeconds: reportedCadence)
        #expect(ceiling == 32.0)
        #expect(ceiling > 2 * reportedCadence)
    }

    /// The structural half of the round, and the reason AE#520's reading could not have worked: while
    /// the source is quiet the consumer keeps walking the window, so `runway + silence` is fixed and
    /// `runway <= deadline - silence` is decided the first time it is asked. The bound that replaces it
    /// does not read the clock at all.
    @Test("the content bound does not read the clock at all")
    func theBoundIsOnTheRunwaysOwnAxis() {
        // Whatever the silence has been, the same content gives the same answer. The old bound could
        // not say that: it was a comparison against a clock that falls at exactly the rate the runway
        // does, so it answered once and then never again.
        #expect(!LiveEdgePolicy.outageCloseOnDepth(depthSeconds: 24, targetDuration: 6))
        #expect(LiveEdgePolicy.outageCloseOnDepth(depthSeconds: 4, targetDuration: 6))
    }

    /// The harness arm, as the provider sees it: 6 segments of 4 s ahead of the fetch point, which is
    /// the 24.0 s the measured run held at both ends of its outage.
    @Test("the harness arm that closed at 20.10s of silence holds its window")
    func theHarnessArmIsAbsorbed() {
        let cache = SegmentCache(forwardWindow: 40, backwardWindow: 40)
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "avc1.640029,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 4.0,
                                               dvrWindowSeconds: 1800)
        )
        for i in 0..<20 { provider.appendLiveSegment(index: i, startSeconds: Double(i) * 4.0,
                                                     durationSeconds: 4.0) }
        #expect(provider.liveTargetDurationSeconds(maxSegmentDuration: 4.0) == 6)
        cache.declareTarget(13) // 6 segments / 24.0 s of runway, the measured arm
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 10.07) // late, as measured

        // The same content at every silence the measured arm passed through, including the 20.10 s at
        // which it used to close. `runway + silence` is fixed while the source is quiet, so a bound
        // that reads the clock has already decided; this one has not.
        #expect(!provider.liveOutageEndlist)
        for step in [5.0, 5.03, 5.0] { // 15.07, 20.10, 25.10 s of silence
            provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: step)
            #expect(!provider.liveOutageEndlist)
        }
        #expect(!provider.liveOutageEndlistLatched)
        // And the producer's own patience still ends it, with the content untouched.
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 1.5) // 26.60 s, past 35 - 9
        #expect(provider.liveOutageEndlist)
    }
}
