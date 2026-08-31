// Tests/AetherEngineTests/Issue447TargetDurationEvidenceTests.swift
// AE#447: the served TARGETDURATION is sealed for the session (RFC 8216 forbids changing it, AE#209) and
// its 3x holdback gates the first live manifest, so what it is derived FROM decides every zap's startup
// depth. It must be derived from measurement. A packager's habitual `segment + 1` padding used to seed the
// cadence floor and cost 3x itself in first-serve holdback: measured in the field at 1.07-1.09 s per tune
// on a 2.000 s source advertising 3.
import XCTest
@testable import AetherEngine

private final class ScriptedUpstream: @unchecked Sendable {
    var now: Double = 0
    var cadence: Double?
    var closedCadence: Double?
    var segmentDuration: Double?
}

final class Issue447TargetDurationEvidenceTests: XCTestCase {

    private func makePolicy(_ s: ScriptedUpstream, cutTarget: Double = 0.5, advertised: Double?) -> LiveCadencePolicy {
        LiveCadencePolicy(
            observe: { s.cadence },
            cutTargetSeconds: cutTarget,
            observeSealEvidence: {
                LiveCadenceEvidence(closedCadenceSeconds: s.closedCadence,
                                    servedSegmentDurationSeconds: s.segmentDuration)
            },
            selfReportedTargetDurationSeconds: advertised,
            clock: { s.now }
        )
    }

    // MARK: - What the floor is made of

    func testAdvertisedTargetDurationDoesNotRaiseTheFloor() {
        let s = ScriptedUpstream()
        let policy = makePolicy(s, advertised: 3)     // padded advert over a 2.000 s cadence
        s.now = 1; s.cadence = 0.5; s.segmentDuration = 2.0
        XCTAssertEqual(try XCTUnwrap(policy.targetDurationFloorSeconds), 2.0, accuracy: 1e-9,
                       "the floor is the measured segment duration, not the advertised 3")
        XCTAssertEqual(policy.selfReportedTargetDurationSeconds, 3,
                       "the advert is still carried, for the seal log to report")
    }

    func testServedSegmentDurationFloorsTheBurstFlatteredCadence() {
        let s = ScriptedUpstream()
        let policy = makePolicy(s, advertised: nil)
        // A join burst hands over a backlog at 4-5x realtime, so the intervals say 0.5 s while the source
        // will never sustain better than its 2.000 s cut. Sealing on the interval alone would advertise a
        // 3 s patience for a 2 s cadence and leave no margin at all.
        s.now = 3; s.cadence = 0.5; s.segmentDuration = 2.0
        XCTAssertEqual(try XCTUnwrap(policy.targetDurationFloorSeconds), 2.0, accuracy: 1e-9)
    }

    func testFloorIsNilWhileNothingHasBeenMeasured() {
        let s = ScriptedUpstream()
        let policy = makePolicy(s, advertised: 6)
        s.now = 0
        XCTAssertNil(policy.targetDurationFloorSeconds,
                     "an advert alone is not a measurement; ceil(max EXTINF) carries the TD until one exists")
    }

    func testBatchyUpstreamStillWidensTheFloorPastItsSegmentDuration() {
        let s = ScriptedUpstream()
        let policy = makePolicy(s, cutTarget: 4, advertised: 4)
        s.now = 0; s.cadence = 0; s.segmentDuration = 4.0
        _ = policy.targetDurationFloorSeconds
        s.now = 20; s.cadence = 20; s.closedCadence = 20   // one real 20 s inter-batch gap, closed
        XCTAssertEqual(try XCTUnwrap(policy.targetDurationFloorSeconds), 20, accuracy: 1e-9,
                       "#167's relay shape is covered by observation, which is the only thing that ever covered it")
    }

    // MARK: - What it costs at the first serve

    /// The reported field shape: 2.000 s segments, fastZap cut target, upstream advertising 3.
    func testPaddedAdvertNoLongerDeepensTheStartupGate() {
        let s = ScriptedUpstream()
        let policy = makePolicy(s, advertised: 3)
        s.now = 3; s.cadence = 0.5; s.segmentDuration = 2.0

        let td = LiveEdgePolicy.targetDurationSeconds(
            maxSegmentDuration: 2.0,
            cutTargetSeconds: 0.5,
            cadenceFloorSeconds: policy.targetDurationFloorSeconds
        )
        XCTAssertEqual(td, 2, "ceil(max EXTINF) carries it; the advert used to push this to 3")
        XCTAssertEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: td), 6.0, accuracy: 1e-9)

        // The gate opens on 3 segments / 6.0 s instead of 5 / 10.0 s: one segment-and-a-half of startup,
        // which the reporter measured as 1.07-1.09 s of wall clock on every tune.
        XCTAssertTrue(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 3, summedDurationSeconds: 6.0, targetDuration: td, windowSegmentCount: 30))
        XCTAssertFalse(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 3, summedDurationSeconds: 6.0, targetDuration: 3, windowSegmentCount: 30),
            "the value this replaces: 9 s of holdback, so 3 segments were never enough")
    }

    func testPatienceStillCoversTheMeasuredCadence() {
        // AVPlayer's unchanged-playlist tolerance is 1.5 x TD. At TD 2 that is 3 s over a 2 s cadence,
        // the same ratio the cut-target floor was built to guarantee.
        let td = LiveEdgePolicy.targetDurationSeconds(
            maxSegmentDuration: 2.0, cutTargetSeconds: 0.5, cadenceFloorSeconds: 2.0)
        XCTAssertGreaterThanOrEqual(Double(td) * 1.5, 2.0 * 1.5)
    }

    // MARK: - The seal says why

    func testSealAccountReportsMeasuredTermsAndTheUnusedAdvert() {
        let derivation = LiveTargetDurationDerivation(
            value: 2, maxSegmentDuration: 2.0, cutTargetFloor: 0.5,
            cadenceFloor: .measured(2.0), selfReported: 3.0)
        let account = derivation.account
        XCTAssertTrue(account.contains("sealed at 2s"), account)
        XCTAssertTrue(account.contains("holdback 6.000s"), account)
        XCTAssertTrue(account.contains("max EXTINF 2.000s"), account)
        XCTAssertTrue(account.contains("measured floor 2.000s"), account)
        XCTAssertTrue(account.contains("upstream advertises 3.000s (reported, not used)"), account)
    }

    func testSealAccountNamesAnAbsentMeasurement() {
        let derivation = LiveTargetDurationDerivation(
            value: 4, maxSegmentDuration: 3.2, cutTargetFloor: 4.0,
            cadenceFloor: .pending, selfReported: nil)
        XCTAssertTrue(derivation.account.contains("measured floor none yet"), derivation.account)
    }

    /// Round 3, from the retest: on a source the engine cuts itself there is no meter at all, and the
    /// line said `none yet`, which reads as a measurement still to come. Two runs on the reporter's
    /// device were read that way, crediting the four floor fixes on a path that has no floor to fix.
    func testSealAccountSeparatesNoMeterFromNoMeasurementYet() {
        let unmeasurable = LiveTargetDurationDerivation(
            value: 2, maxSegmentDuration: 2.0, cutTargetFloor: 0.5,
            cadenceFloor: .unmeasurable, selfReported: nil).account
        XCTAssertTrue(unmeasurable.contains("no measured floor (segments are cut here, not ingested)"),
                      unmeasurable)
        XCTAssertFalse(unmeasurable.contains("none yet"),
                       "a term that will never be measured must not read as pending: \(unmeasurable)")
        XCTAssertFalse(unmeasurable.contains("upstream advertises"),
                       "and a source with no meter has no advert to report either: \(unmeasurable)")
    }

    /// The seal is taken at the first-serve gate, so an ingest session that has not closed an interval
    /// yet is genuinely pending, and that is the ONLY case the old word was right about.
    func testPendingAndUnmeasurableSealTheSameValueAndDifferInTheLineOnly() {
        let terms: [CadenceFloorTerm] = [.pending, .unmeasurable]
        let values = terms.map {
            LiveEdgePolicy.targetDurationSeconds(
                maxSegmentDuration: 2.0, cutTargetSeconds: 0.5, cadenceFloorSeconds: $0.seconds)
        }
        XCTAssertEqual(values, [2, 2], "neither absence may move the number, only what the line claims")
    }

    // MARK: - Round 2: the resolution the playlist serves

    /// The producer derives a live EXTINF as `nextStart - startSeconds`, both accumulated item-axis
    /// doubles. Built the way the producer builds them, from the reporter's own first start (0.060 s),
    /// so the case is in the fixture and not in a hand-picked literal.
    private func accumulatedDurations(first: Double, cut: Double, count: Int) -> [Double] {
        var starts: [Double] = []
        var t = first
        for _ in 0...count { starts.append(t); t += cut }
        return (0..<count).map { starts[$0 + 1] - starts[$0] }
    }

    func testAccumulatedStartsReallyProduceAnExcessBelowTheServedResolution() {
        let durations = accumulatedDurations(first: 0.06, cut: 2.0, count: 8)
        let maxDuration = durations.max() ?? 0
        XCTAssertGreaterThan(maxDuration, 2.0,
                             "if no duration exceeds 2.0 this suite proves nothing about the ceil")
        XCTAssertLessThan(maxDuration - 2.0, 0.0005,
                          "and the excess is below the millisecond the playlist can even print")
        XCTAssertEqual(String(format: "%.3f", maxDuration), "2.000",
                       "which is why the seal line read 2.000 while the value sealed at 3")
    }

    func testInvisibleExcessNoLongerBuysASecondOfTargetDuration() {
        let durations = accumulatedDurations(first: 0.06, cut: 2.0, count: 8)
        let td = LiveEdgePolicy.targetDurationSeconds(
            maxSegmentDuration: durations.max() ?? 0,
            cutTargetSeconds: 0.5,
            cadenceFloorSeconds: 2.0
        )
        XCTAssertEqual(td, 2, "one ulp over a 2.000 s GOP used to seal at 3, holdback 9 s")
        XCTAssertEqual(LiveEdgePolicy.holdBackSeconds(targetDuration: td), 6.0, accuracy: 1e-9)
    }

    /// The invariant the served value has to satisfy, checked against the formatter the playlist writer
    /// actually uses: TARGETDURATION covers every EXTINF the client is handed.
    func testTargetDurationCoversEveryEXTINFAsServed() {
        for first in [0.0, 0.06, 0.123, 1.7, 9.94] {
            for cut in [0.96, 2.0, 3.2, 5.76] {
                let durations = accumulatedDurations(first: first, cut: cut, count: 12)
                let td = LiveEdgePolicy.targetDurationSeconds(
                    maxSegmentDuration: durations.max() ?? 0,
                    cutTargetSeconds: nil, cadenceFloorSeconds: nil)
                for duration in durations {
                    let served = Double(String(format: "%.3f", duration))!
                    XCTAssertGreaterThanOrEqual(Double(td), served,
                                                "TD \(td) < served EXTINF \(served) (cut \(cut))")
                }
            }
        }
    }

    func testARealExcessStillRaisesIt() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(
            maxSegmentDuration: 2.0006, cutTargetSeconds: nil, cadenceFloorSeconds: nil), 3,
            "half a millisecond over is visible in the playlist, so it is paid for")
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(
            maxSegmentDuration: 2.4, cutTargetSeconds: nil, cadenceFloorSeconds: nil), 3)
        XCTAssertEqual(LiveEdgePolicy.targetDurationSeconds(
            maxSegmentDuration: 5.76, cutTargetSeconds: nil, cadenceFloorSeconds: nil), 6,
            "AE#189's long-GOP shape is unchanged")
    }

    func testCadenceFloorIsTakenAtTheSameResolution() {
        XCTAssertEqual(LiveEdgePolicy.targetDurationForCadence(3.0000000000000004), 2,
                       "3 / 1.5 lands one ulp above 2 and used to ask for a third second of patience")
        XCTAssertEqual(LiveEdgePolicy.targetDurationForCadence(3.003), 3,
                       "a measurable 3 ms over still does")
    }

    /// The other half of the same error: with TD sealed at 2 the gate wants exactly three 2.000 s
    /// segments, and their float sum lands a hair BELOW 6.0 for some first-segment starts.
    func testStartupCushionIsJudgedAtTheServedResolutionToo() {
        let durations = accumulatedDurations(first: 0.03, cut: 2.0, count: 3)
        let summed = durations.reduce(0, +)
        XCTAssertLessThan(summed, 6.0, "if this sum is not short the case is not in the fixture")
        XCTAssertTrue(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 3, summedDurationSeconds: summed, targetDuration: 2, windowSegmentCount: 30),
            "otherwise the gate holds for a fourth segment, a full extra 2 s, intermittently")
        XCTAssertTrue(LiveEdgePolicy.firstServeAccount(
            waitedSeconds: 2.2, segmentCount: 3, summedDurationSeconds: summed, targetDuration: 2)
            .contains(">= 6.000s holdback"),
            "and the account has to agree with the gate it reports on")
        XCTAssertFalse(LiveEdgePolicy.startupCushionSatisfied(
            segmentCount: 3, summedDurationSeconds: 5.998, targetDuration: 2, windowSegmentCount: 30),
            "a genuinely short window is still short")
    }

    private func number(after label: String, in text: String) -> Double? {
        guard let r = text.range(of: label + "[0-9]+\\.?[0-9]*", options: .regularExpression) else { return nil }
        return Double(text[r].dropFirst(label.count))
    }

    /// What made the round-2 report answerable at all: the seal line contradicted itself, printing
    /// `max(ceil(2.000), ceil(0.750), -)` and sealing at 3. It could, because the terms decided at full
    /// precision and printed at millisecond. Now they decide at the resolution they print at, so the line
    /// can be checked against itself by anyone holding a log, and that is what this asserts.
    func testSealAccountRecomputesTheValueItReports() {
        let accumulated = accumulatedDurations(first: 0.06, cut: 2.0, count: 8).max() ?? 0
        for maxSegment in [0.96, 2.0, accumulated, 2.4, 3.2, 5.76] {
            for cut in [nil, 0.5, 2.0, 4.0] as [Double?] {
                for floor in [nil, 2.0, 3.0000000000000004, 20.0] as [Double?] {
                    let value = LiveEdgePolicy.targetDurationSeconds(
                        maxSegmentDuration: maxSegment, cutTargetSeconds: cut, cadenceFloorSeconds: floor)
                    let account = LiveTargetDurationDerivation(
                        value: value, maxSegmentDuration: maxSegment, cutTargetFloor: cut,
                        cadenceFloor: floor.map { CadenceFloorTerm.measured($0) } ?? .pending,
                        selfReported: 3.0).account
                    var recomputed = Int(ceil(try! XCTUnwrap(number(after: "max EXTINF ", in: account))))
                    if cut != nil {
                        recomputed = max(recomputed,
                                         Int(ceil(try! XCTUnwrap(number(after: "1.5 x cut target ", in: account)))))
                    }
                    if floor != nil {
                        recomputed = max(recomputed, Int(try! XCTUnwrap(number(after: "needs ", in: account))))
                    }
                    XCTAssertEqual(Int(try! XCTUnwrap(number(after: "sealed at ", in: account))), recomputed,
                                   "the line has to add up to the number it reports: \(account)")
                }
            }
        }
    }
}
