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

/// AE#444 follow-up (Sodalite#104): the clamp reports what it did.
///
/// The clamp has been right since AE#444 and is the only sane thing to do: a session paused for
/// longer than its own buffer depth has had the position it was parked on evicted by the sliding
/// window. What it could not do is tell anyone. Measured on the harness with a 30 s window and a 70 s
/// pause, the playhead sat at 93881.2 while the window slid to 93890.0...93920.0 underneath it and
/// the resume landed at 93895.0 in silence, so a viewer who paused a match saw it continue somewhere
/// else with nothing on screen to say why.
@Suite("The live resume clamp reports what it took (Sodalite#104)")
struct LiveResumeClampReportTests {

    /// The harness capture, as the payload describes it.
    @Test("the payload names the content the window took, and where the resume landed")
    func thepayloadDescribesTheClamp() {
        // playhead 93881.16, window slid to 93890.0...93920.0, clamp target 93895.0, edge 93919.99.
        let clamp = LiveResumeClamp(skippedSeconds: 93895.0 - 93881.16,
                                    behindLiveSeconds: 93919.99 - 93895.0)
        #expect(abs(clamp.skippedSeconds - 13.84) < 0.01)
        #expect(abs(clamp.behindLiveSeconds - 24.99) < 0.01)
    }

    @Test("an edge snap skipped everything it was behind, and lands at the edge")
    func anedgeSnapIsAllOfIt() {
        // The live-only shape: no DVR window to clamp into, so the resume is the edge itself.
        let clamp = LiveResumeClamp(skippedSeconds: 38.8, behindLiveSeconds: 0)
        #expect(clamp.behindLiveSeconds == 0)
        #expect(clamp.skippedSeconds > 0)
    }

    @Test("the two numbers are independent, so a host can phrase either")
    func bothNumbersAreCarried() {
        // A host that wants "you missed 14 seconds" and one that wants "continuing 25 seconds behind
        // live" are both served without doing arithmetic against a window they cannot see.
        let a = LiveResumeClamp(skippedSeconds: 14, behindLiveSeconds: 25)
        let b = LiveResumeClamp(skippedSeconds: 14, behindLiveSeconds: 0)
        #expect(a != b)
        #expect(a.skippedSeconds == b.skippedSeconds)
    }
}
