import Testing
@testable import AetherEngine

/// AE#444: `play()` moved a behind-live playhead by itself, which made a host's own live-pause semantics
/// unreachable. The decision is now one pure function, and the host can own it.
@Suite("AE#444 who moves a behind-live playhead on resume")
struct Issue444LiveResumePolicyTests {

    private func action(clamps: Bool = true,
                        window: Double?,
                        behind: Double,
                        lowerBound: Double? = nil,
                        edge: Double = 1000) -> AetherEngine.LiveResumeAction {
        AetherEngine.liveResumeAction(clampsToWindow: clamps,
                                      windowSeconds: window,
                                      behindLiveSeconds: behind,
                                      seekableLowerBound: lowerBound,
                                      edgeTime: edge)
    }

    // MARK: - Default behaviour, unchanged

    @Test("a DVR playhead the window has slid past lands above the retained floor")
    func evictedDVRPlayheadIsRecovered() {
        #expect(action(window: 1800, behind: 1799, lowerBound: 200) == .seek(to: 205))
    }

    @Test("a playhead still inside the window is left alone")
    func insideWindowIsUntouched() {
        #expect(action(window: 1800, behind: 540, lowerBound: 200) == .none)
    }

    /// The report's own healthy state: 540 s of deliberate rewind inside a 1800 s window must survive a
    /// resume, and did even before the option existed.
    @Test("deliberate deep rewind inside the window survives a resume")
    func deliberateRewindSurvives() {
        #expect(action(window: 1800, behind: 540) == .none)
    }

    @Test("live-only snaps to the edge only past its own threshold")
    func liveOnlyThreshold() {
        #expect(action(window: nil, behind: 44) == .none)
        #expect(action(window: nil, behind: 46) == .edgeSnap)
    }

    /// AE#441: the landing is measured from the range's lower bound, which is now the cache's real floor
    /// rather than window arithmetic, so the clamp cannot aim at a position that was never retained.
    @Test("the landing follows the advertised floor")
    func landingFollowsTheFloor() {
        #expect(action(window: 30, behind: 100, lowerBound: 981) == .seek(to: 986))
    }

    /// With no range at all there is nothing to measure from; the edge is the only position known to
    /// exist.
    @Test("an absent lower bound falls back to the edge")
    func absentBoundFallsBackToEdge() {
        #expect(action(window: 30, behind: 100, lowerBound: nil, edge: 400) == .seek(to: 405))
    }

    // MARK: - AE#441 follow-up: the trigger reads the same bound as the landing

    /// The regime the AE#441 retest confirmed on a real rewind strip: retention short of the window for
    /// the session's life (window 420 s, advertised depth ~405 s). A resume between the two used to find
    /// no clamp at all, because the trigger was window arithmetic while the landing had already moved to
    /// the cache's floor.
    @Test("retention short of the window still clamps a position the cache dropped")
    func retentionShortfallIsRecovered() {
        // edge 480, floor 75 -> 405 s of real depth in a 420 s window. A playhead 410 s behind sits
        // 5 s BELOW the floor; window arithmetic alone (410 > 415) said nothing was wrong.
        #expect(action(window: 420, behind: 410, lowerBound: 75, edge: 480) == .seek(to: 80))
    }

    /// The same session one second shallower is genuinely inside what the cache holds, and must be left
    /// where it is.
    @Test("a position the cache still holds is left alone in the same regime")
    func retentionShortfallLeavesHeldPositionsAlone() {
        #expect(action(window: 420, behind: 395, lowerBound: 75, edge: 480) == .none)
    }

    /// Where retention matches the window the two formulations are the same statement, so the boundary
    /// may not move.
    @Test("a full window clamps at exactly the same boundary as before")
    func fullWindowBoundaryIsUnchanged() {
        #expect(action(window: 60, behind: 55, lowerBound: 140, edge: 200) == .none)
        #expect(action(window: 60, behind: 56, lowerBound: 140, edge: 200) == .seek(to: 145))
    }

    /// Before the window fills, the floor is the session's own start, not an eviction frontier. Nothing
    /// is coming to take that position, so a resume near it must not be shoved forward by the margin.
    @Test("a young session is not clamped against its own start")
    func youngSessionKeepsItsPosition() {
        #expect(action(window: 1800, behind: 105, lowerBound: 1.45, edge: 108) == .none)
    }

    // MARK: - Host-owned

    @Test("a host that owns resume gets no implicit seek, in either shape")
    func hostOwnedMovesNothing() {
        #expect(action(clamps: false, window: 1800, behind: 1799, lowerBound: 200) == .none)
        #expect(action(clamps: false, window: nil, behind: 600) == .none)
    }

    @Test("host-owned still does nothing when nothing was warranted anyway")
    func hostOwnedIsNotAnInversion() {
        #expect(action(clamps: false, window: 1800, behind: 10) == .none)
    }

    @Test("the option defaults to today's behaviour")
    func defaultIsUnchanged() {
        #expect(LoadOptions().clampsLiveResumeToWindow)
    }
}
