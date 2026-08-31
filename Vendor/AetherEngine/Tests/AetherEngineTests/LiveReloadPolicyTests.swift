// Tests/AetherEngineTests/LiveReloadPolicyTests.swift
// Pins LiveReloadPolicy: live audio-switch reloads must not resume at a stale clock and must skip the initial seek;
// VOD reloads resume at playhead; initial live joins keep the device-verified seek-to-0.
import XCTest
@testable import AetherEngine

final class LiveReloadPolicyTests: XCTestCase {

    // MARK: - resumePosition

    func testVODReloadResumesAtPlayhead() {
        XCTAssertEqual(
            LiveReloadPolicy.resumePosition(isLive: false, currentTime: 25.4), 25.4,
            "a VOD audio switch must not lose the user's position"
        )
    }

    func testVODReloadNearHeadCollapsesToNil() {
        // Positions <= 1s collapse to nil to avoid a pointless seek at head (matches the `resumeAt > 1` guard).
        XCTAssertNil(LiveReloadPolicy.resumePosition(isLive: false, currentTime: 0.0))
        XCTAssertNil(LiveReloadPolicy.resumePosition(isLive: false, currentTime: 1.0))
        XCTAssertNotNil(LiveReloadPolicy.resumePosition(isLive: false, currentTime: 1.01))
    }

    func testLiveReloadNeverResumesAtStaleClock() {
        // Pre-reload playhead is stale against the rebuilt session's fresh timeline; live reload always returns nil.
        for playhead in [0.0, 0.5, 25.4, 3600.0] {
            XCTAssertNil(
                LiveReloadPolicy.resumePosition(isLive: true, currentTime: playhead),
                "live reload must rejoin the live edge, not resume at \(playhead)s"
            )
        }
    }

    // MARK: - skipInitialSeek

    func testLiveRejoinSkipsTheHostSeek() {
        XCTAssertTrue(
            LiveReloadPolicy.skipInitialSeek(isLive: true, isRejoin: true),
            "a live REJOIN must leave the join position to AVPlayer (the rebuilt "
            + "playlist can present a backlog where seek-to-0 points a window "
            + "behind the live edge and wedges item readiness)"
        )
    }

    func testInitialLiveJoinKeepsTheSeek() {
        XCTAssertFalse(
            LiveReloadPolicy.skipInitialSeek(isLive: true, isRejoin: false),
            "the initial live join's seek-to-0 is device-verified behavior "
            + "(seg0 IS the cushioned live edge at the first manifest); the "
            + "rejoin policy must not change it"
        )
    }

    func testVODNeverSkipsTheSeek() {
        // VOD relies on the explicit seek for replay-from-beginning.
        XCTAssertFalse(LiveReloadPolicy.skipInitialSeek(isLive: false, isRejoin: false))
        XCTAssertFalse(LiveReloadPolicy.skipInitialSeek(isLive: false, isRejoin: true))
    }

    // MARK: - recoveryRejoinPosition (AE#442)

    /// The reported case: a viewer 540 s inside an 1800 s window when the consumer dies. The in-place
    /// recovery reload leaves the cache standing, so the position is still resident content.
    func testParkedViewerKeepsItsPlaceAcrossAnInPlaceRecovery() {
        XCTAssertEqual(
            LiveReloadPolicy.recoveryRejoinPosition(
                isLive: true, playhead: 1572, behindWhenLastAdvancing: 540,
                residentRange: 400...2134.8, targetDurationSeconds: 6),
            1572
        )
    }

    /// The distance that decides is the last one measured while the picture moved. A live
    /// `behindLiveSeconds` at the moment of a recovery carries the stall's own duration, which would
    /// drag an edge viewer backwards by however long they stared at a frozen frame.
    func testEdgeViewerWhoJustStalledStillRejoinsAtTheEdge() {
        XCTAssertNil(
            LiveReloadPolicy.recoveryRejoinPosition(
                isLive: true, playhead: 2094.8, behindWhenLastAdvancing: 1.2,
                residentRange: 400...2134.8, targetDurationSeconds: 6),
            "a 40 s stall must not turn an edge viewer into a viewer parked 40 s back"
        )
    }

    /// One TARGETDURATION is the oscillation the edge itself imposes: it advances a segment at a time.
    func testDistanceWithinOneTargetDurationCountsAsTheEdge() {
        for behind in [0.0, 3.2, 5.9] {
            XCTAssertNil(
                LiveReloadPolicy.recoveryRejoinPosition(
                    isLive: true, playhead: 100, behindWhenLastAdvancing: behind,
                    residentRange: 0...200, targetDurationSeconds: 6))
        }
        XCTAssertEqual(
            LiveReloadPolicy.recoveryRejoinPosition(
                isLive: true, playhead: 100, behindWhenLastAdvancing: 6.1,
                residentRange: 0...200, targetDurationSeconds: 6),
            100)
    }

    /// No cache to ask (remote-HLS live, the software live path) is exactly the shape the edge-rejoin
    /// rule was written for: nothing can vouch for the position, so nothing changes.
    func testNoResidentRangeKeepsTheEdgeRejoin() {
        XCTAssertNil(
            LiveReloadPolicy.recoveryRejoinPosition(
                isLive: true, playhead: 1572, behindWhenLastAdvancing: 540,
                residentRange: nil, targetDurationSeconds: 6))
    }

    /// Before the first playlist build there is no served TARGETDURATION, and nothing can be parked.
    func testNoServedTargetDurationKeepsTheEdgeRejoin() {
        XCTAssertNil(
            LiveReloadPolicy.recoveryRejoinPosition(
                isLive: true, playhead: 1572, behindWhenLastAdvancing: 540,
                residentRange: 400...2134.8, targetDurationSeconds: nil))
    }

    /// A position that slid out from under the stall is gone; the oldest surviving second beats the edge.
    func testPositionBelowTheResidentFloorClampsToTheFloor() {
        XCTAssertEqual(
            LiveReloadPolicy.recoveryRejoinPosition(
                isLive: true, playhead: 320, behindWhenLastAdvancing: 540,
                residentRange: 400...2134.8, targetDurationSeconds: 6),
            400)
    }

    func testVODRecoveryIsUntouched() {
        XCTAssertNil(
            LiveReloadPolicy.recoveryRejoinPosition(
                isLive: false, playhead: 1572, behindWhenLastAdvancing: 540,
                residentRange: 0...2000, targetDurationSeconds: 6))
    }

    // MARK: - LoadOptions plumbing

    func testHostsCannotSetLiveRejoin() {
        // isLiveRejoin is engine-internal; every publicly constructible LoadOptions carries false.
        XCTAssertFalse(LoadOptions().isLiveRejoin)
        XCTAssertFalse(LoadOptions(isLive: true, dvrWindowSeconds: 600).isLiveRejoin)
    }
}
