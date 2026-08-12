import XCTest
@testable import AetherEngine

/// #65 follow-up: the stall re-engage watchdog was one-shot and edge-triggered, armed per
/// playbackStalled notification, then a SINGLE instantaneous check 6 s later. Any fetch activity
/// inside that grace window disarmed it permanently, which parked a live player that drained its
/// remaining tail segments and then waited forever on a frozen playlist: with a non-empty forward
/// buffer, playbackStalled never re-fires, failedToPlayToEndTime never fires while waiting, and the
/// producer-side wedge detector died with the pump. Field trace: playlist frozen at its last
/// segment, AVPlayer parked in waitingToMinimizeStalls with ~2 s buffered, no recovery layer ever
/// re-examined the session.
final class StallWatchdogLevelRearmTests: XCTestCase {

    // MARK: - Level re-watch verdict

    func testFetchActivityDuringGraceRewatchesInsteadOfDisarming() {
        XCTAssertEqual(
            AetherEngine.stallWatchVerdict(
                fetchesNow: 7, baseline: 3, isWaitingToPlay: true, itemFailed: false,
                passesSoFar: 0, cap: 10),
            .rewatch,
            "the incident: AVPlayer fetched tail segments inside the grace window; the old single check returned permanently and nothing ever re-armed")
    }

    func testSilentGraceEscalatesIntoTheLadder() {
        XCTAssertEqual(
            AetherEngine.stallWatchVerdict(
                fetchesNow: 5, baseline: 5, isWaitingToPlay: true, itemFailed: false,
                passesSoFar: 3, cap: 10),
            .escalate)
    }

    func testRecoveredPlayerDisarms() {
        XCTAssertEqual(
            AetherEngine.stallWatchVerdict(
                fetchesNow: 9, baseline: 5, isWaitingToPlay: false, itemFailed: false,
                passesSoFar: 0, cap: 10),
            .disarm,
            "a playing or paused player is not this watchdog's business (user pause has its own guard; playback has recovered)")
    }

    func testFailedItemDisarms() {
        XCTAssertEqual(
            AetherEngine.stallWatchVerdict(
                fetchesNow: 5, baseline: 5, isWaitingToPlay: true, itemFailed: true,
                passesSoFar: 0, cap: 10),
            .disarm,
            "a failed item belongs to the item-death escalation, not the stall ladder")
    }

    func testTricklingFetchesExhaustTheWatchCap() {
        XCTAssertEqual(
            AetherEngine.stallWatchVerdict(
                fetchesNow: 42, baseline: 40, isWaitingToPlay: true, itemFailed: false,
                passesSoFar: 9, cap: 10),
            .disarm,
            "a merely slow session that keeps fetching hands back to the producer-side arms instead of watching forever")
    }

    // MARK: - Final rung: frozen live clock after the stage-2 reload

    func testFrozenLiveClockAfterReloadPublishesReset() {
        XCTAssertTrue(AetherEngine.shouldPublishLiveSourceReset(
            isLive: true, clockAtReload: 62.89, clockNow: 62.89, isWaitingToPlay: true),
            "a reload against a frozen playlist refills the same tail; only the host can retune")
    }

    /// One variable at a time: the clock advanced, everything else held at the firing values.
    func testAdvancedClockAloneWithholdsTheReset() {
        XCTAssertFalse(AetherEngine.shouldPublishLiveSourceReset(
            isLive: true, clockAtReload: 62.89, clockNow: 68.11, isWaitingToPlay: true),
            "the reload took: the rendered clock moved past the dead spot")
    }

    /// And the player state alone, with the clock held frozen.
    func testRecoveredPlayerAloneWithholdsTheReset() {
        XCTAssertFalse(AetherEngine.shouldPublishLiveSourceReset(
            isLive: true, clockAtReload: 62.89, clockNow: 62.89, isWaitingToPlay: false),
            "a player that is no longer waiting owns its own state; this rung is for the parked one")
    }

    /// The shape an equality test misses: the in-place swap took the item but not the playback, so
    /// the fresh item parks on ITS clock (own timeline, or zero before it is ready). Just as dead,
    /// and the rung has to see it.
    func testSwapThatParkedOnADifferentClockStillPublishesReset() {
        XCTAssertTrue(AetherEngine.shouldPublishLiveSourceReset(
            isLive: true, clockAtReload: 62.89, clockNow: 0, isWaitingToPlay: true),
            "the fresh item never got ready; a clock at zero is not progress")
        XCTAssertTrue(AetherEngine.shouldPublishLiveSourceReset(
            isLive: true, clockAtReload: 62.89, clockNow: 63.2, isWaitingToPlay: true),
            "sub-epsilon drift is the same dead spot, not a reload that took")
    }

    func testVODNeverPublishesLiveSourceReset() {
        XCTAssertFalse(AetherEngine.shouldPublishLiveSourceReset(
            isLive: false, clockAtReload: 100.0, clockNow: 100.0, isWaitingToPlay: true),
            "VOD stalls have their own arms (#99/#126/#169); liveSourceReset is a live-retune contract")
    }

    // MARK: - Storm shape: reload budget across superseding stall events

    func testStageTwoReloadsAtFrozenPositionExhaustThenProgressRestores() {
        // On a frozen playlist each reload replays the tail and re-stalls within seconds; the fresh
        // stall supersedes the ladder task before its post-reload rung can run. The persistent gate
        // is what breaks that loop.
        var gate = ItemDeathReviveGate(maxAttempts: 2)
        XCTAssertTrue(gate.admit(position: 62.89), "first reload is always worth trying")
        XCTAssertTrue(gate.admit(position: 62.88), "clock jitter below the epsilon is the same dead spot")
        XCTAssertFalse(gate.admit(position: 62.89),
            "third reload at the same frozen position is futile; the ladder must publish liveSourceReset instead")
        XCTAssertTrue(gate.admit(position: 130.4),
            "real progress (the reload took, or the user zapped/scrubbed) is a fresh episode with a fresh budget")
    }
}
