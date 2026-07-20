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

    // MARK: - LoadOptions plumbing

    func testHostsCannotSetLiveRejoin() {
        // isLiveRejoin is engine-internal; every publicly constructible LoadOptions carries false.
        XCTAssertFalse(LoadOptions().isLiveRejoin)
        XCTAssertFalse(LoadOptions(isLive: true, dvrWindowSeconds: 600).isLiveRejoin)
    }
}
