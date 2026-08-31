import Foundation
import Testing
@testable import AetherEngine

/// AE#443 round 4: a live window a session cannot hold is not a window, it is a fuse.
///
/// The reporter spent three campaigns attributing a frozen live edge to his server, because the
/// engine's own diagnostics agreed with him: the ladder reported "the producer is starved, not the
/// consumer" and AE#446 reported "source stopped delivering". Measured on the loopback fixture, an
/// EDGE session with no seek at all, 1800 s window at a 1 s cadence: the producer parked at
/// `resident=180 cap=180` after 179 s and never released, and every one of those lines followed. His
/// own freeze landed at 180 x his 3.9 s cadence, three runs running.
///
/// The cause is a unit mismatch. The window is sized in SECONDS from what the host asked for, while
/// the producer refuses to hold more than a fixed count of segments. The playlist does not start
/// sliding until `windowSegmentCount` segments exist, so whenever the window is deeper than the cap
/// the cache fills to the cap first and the pump parks against it forever. A parked live pump is not
/// reading, so the origin stops being drained, and a single-connection live source dies behind it.
struct Issue443LiveWindowFitsTheDiskTests {

    private let budget2GiB = 2 << 30

    @Test("a window deeper than the disk allowance is served at the depth the disk supports")
    func clampsToWhatTheBudgetHolds() {
        // The reporter's shape: 1800 s at a ~3.9 s cadence is 462 segments of ~7 MiB, i.e. 3.2 GB
        // against a 2 GiB allowance.
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 1800,
                                      retentionBudgetBytes: budget2GiB)
        let asked = sizing.windowSegmentCount(observedSegmentDurationSeconds: 3.9)
        #expect(asked == 462)
        let served = sizing.windowSegmentCount(observedSegmentDurationSeconds: 3.9,
                                               observedSegmentBytes: 7 << 20)
        #expect(served == 292)
    }

    @Test("a window the disk can hold is not touched")
    func leavesAnAffordableWindowAlone() {
        // 300 s at a 2 s cadence is 150 segments of 1 MiB: 150 MiB against 2 GiB.
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 300,
                                      retentionBudgetBytes: budget2GiB)
        #expect(sizing.windowSegmentCount(observedSegmentDurationSeconds: 2.0,
                                          observedSegmentBytes: 1 << 20) == 150)
    }

    @Test("an unmeasured segment size cannot shrink a window")
    func unknownSegmentSizeChangesNothing() {
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 1800,
                                      retentionBudgetBytes: budget2GiB)
        // Before the first segment is resident there is nothing to divide by, and guessing would size
        // the window on an invention.
        #expect(sizing.windowSegmentCount(observedSegmentDurationSeconds: 3.9,
                                          observedSegmentBytes: nil) == 462)
        #expect(LiveWindowSizing.affordableSegments(retentionBudgetBytes: budget2GiB,
                                                    observedSegmentBytes: nil) == .max)
        #expect(LiveWindowSizing.affordableSegments(retentionBudgetBytes: budget2GiB,
                                                    observedSegmentBytes: 0) == .max)
    }

    @Test("a session that states no allowance keeps the sizing it had")
    func unstatedBudgetIsNotAZeroBudget() {
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 1800)
        #expect(sizing.windowSegmentCount(observedSegmentDurationSeconds: 3.9,
                                          observedSegmentBytes: 7 << 20) == 462)
        #expect(LiveWindowSizing.affordableSegments(retentionBudgetBytes: 0,
                                                    observedSegmentBytes: 7 << 20) == .max)
    }

    @Test("the clamp never cuts below the floor AVPlayer needs at the live edge")
    func minSafeSegmentsSurvivesATinyBudget() {
        // A nearly full volume clamps the allowance to a quarter of what is left, and a window of one
        // segment would lose AVPlayer's live edge, which is the 81 s spike stall minSafeSegments exists
        // for. Running out of disk is not a reason to serve an unplayable playlist.
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 1800,
                                      retentionBudgetBytes: 8 << 20)
        #expect(sizing.windowSegmentCount(observedSegmentDurationSeconds: 3.9,
                                          observedSegmentBytes: 7 << 20) == LiveWindowSizing.minSafeSegments)
    }

    @Test("the playlist ceiling bounds a window whose segments are nearly free")
    func playlistCeilingBinds() {
        // The harness fixture: 1800 s at a 1 s cadence is 1800 entries, and the whole visible window is
        // rebuilt and re-served on every poll. Cheap on disk is not cheap on the playlist.
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 1800,
                                      retentionBudgetBytes: budget2GiB)
        #expect(sizing.windowSegmentCount(observedSegmentDurationSeconds: 1.0,
                                          observedSegmentBytes: 280 << 10)
                == LiveWindowSizing.maxWindowSegments)
    }

    @Test("the shape that parked now resolves below the count the pump refuses to pass")
    func theReportersShapeNoLongerMeetsTheCap() {
        // The defect in arithmetic. The pump's static floor is 180 segments; the reporter's session
        // asked for 462 and would therefore fill to 180 and park there, 702 s in, which is where his
        // edge froze. Clamped to what the disk holds, the window resolves to 292 and the pump's cap
        // for that session is the window plus slack, so the two can no longer meet in normal play.
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 1800,
                                      retentionBudgetBytes: budget2GiB)
        let asked = sizing.windowSegmentCount(observedSegmentDurationSeconds: 3.9)
        let served = sizing.windowSegmentCount(observedSegmentDurationSeconds: 3.9,
                                               observedSegmentBytes: 7 << 20)
        #expect(asked > 180)      // fills to the floor and parks
        #expect(served > 180)     // still deeper than the floor, so the cap has to follow the window
        #expect(served + VideoSegmentProvider.liveResidentParkSlackSegments > served)
        // And the slack has to be real: a park one poll's worth of segments above the window would be
        // met by a consumer that is merely a poll behind.
        #expect(VideoSegmentProvider.liveResidentParkSlackSegments >= 8)
    }
}
