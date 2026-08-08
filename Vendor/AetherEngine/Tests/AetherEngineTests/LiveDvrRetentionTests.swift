// Live DVR depth: the segment cache must retain the history the playlist advertises.
//
// Before this, live resolved a 0 retention budget on the reasoning that the sliding playlist had
// already dropped everything behind the window. It is the other way round: the playlist window is
// the looser bound (300 segments for a 600 s DVR window at a 2 s cadence), and pruneOutsideWindow
// with a 0 budget takes the hard-window branch and cuts at currentTargetIndex - backwardWindow,
// i.e. 20 segments. Measured on the real engine before the fix: cacheCount pinned at 21 for a
// whole 150 s session with dvrWindowSeconds 600, a plateau of ~31 MB, and a rewind 100 segments
// back landing on a deleted file that live (restartHandler == nil) cannot re-produce.
import XCTest
@testable import AetherEngine

final class LiveDvrRetentionTests: XCTestCase {

    /// The budget helper is now session-wide rather than VOD-only. Note what this does NOT cover:
    /// the fix itself is the removal of the `isLiveSession ? 0 :` branch in `HLSVideoEngine.start()`,
    /// which needs a real session to observe and has no seam here (the same reason
    /// `SegmentRetentionTests` only ever tested the helper). That wiring is verified end to end with
    /// `aetherctl live --dvr-window 600 --fast-zap`, where the session logs its resolved budget and
    /// `cacheCount` must track the window instead of pinning at backwardWindow + 1.
    func testRetentionBudgetHelperIsSessionWide() {
        let fourGiB: Int64 = 4 << 30
        XCTAssertEqual(HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: fourGiB), 1 << 30)
        XCTAssertEqual(HLSVideoEngine.sessionRetentionBudgetBytes(volumeAvailableBytes: 100 << 30), 2 << 30)
    }

    /// With a budget, edge-following playback keeps the history behind the playhead resident well
    /// past `backwardWindow`. Without one it collapsed to backwardWindow + 1 entries.
    func testHistoryBehindTheEdgeSurvivesPastBackwardWindow() {
        let segmentBytes = 1_500_000                    // ~2 s at 6 Mbps, the fastZap live shape
        let budget = 512 << 20                          // 512 MiB: far more than this run needs
        let cache = SegmentCache(forwardWindow: 10, retentionBudgetBytes: budget)
        let payload = Data(repeating: 0xAB, count: segmentBytes)
        let total = 200

        for i in 0..<total {
            cache.store(index: i, data: payload)
            cache.declareTarget(i)
        }

        let resident = (0..<total).filter { cache.peekURL(index: $0) != nil }
        XCTAssertEqual(resident.count, total,
                       "the budget covers this run, so nothing should have been evicted")

        // The specific rewind the old behaviour could not serve: 100 segments back, i.e. 200 s
        // inside a 600 s advertised window.
        XCTAssertNotNil(cache.peekURL(index: total - 1 - 100))
    }

    /// The budget, not backwardWindow, is what bounds the depth. Past it, eviction resumes
    /// farthest-from-target first, and the hard window around the playhead always survives.
    func testDepthIsBoundedByTheBudgetAndKeepsTheHardWindow() {
        let segmentBytes = 1_000_000
        let budget = 30 * segmentBytes                  // room for ~30 segments outside the window
        let cache = SegmentCache(forwardWindow: 10, retentionBudgetBytes: budget)
        let payload = Data(repeating: 0xAB, count: segmentBytes)
        let total = 200

        for i in 0..<total {
            cache.store(index: i, data: payload)
            cache.declareTarget(i)
        }

        let resident = (0..<total).filter { cache.peekURL(index: $0) != nil }
        let head = total - 1

        // Bounded: nowhere near the full run.
        XCTAssertLessThan(resident.count, total)
        // But deeper than the pre-fix hard window, which was backwardWindow + 1 = 21.
        XCTAssertGreaterThan(resident.count, 21)
        // The hard window around the consumer is never traded away for history.
        for i in (head - 20)...head {
            XCTAssertNotNil(cache.peekURL(index: i), "hard-window segment \(i) must stay resident")
        }
    }

    /// Guards the reasoning error the old comment encoded: the playlist window is the looser bound,
    /// so it can never be the thing that makes retention pointless on live.
    func testPlaylistWindowIsLooserThanTheCacheHardWindow() {
        // Sodalite's live shape: 600 s DVR, .fastZap cut target, ~2 s observed GOP cadence.
        let sizing = LiveWindowSizing(targetSegmentDurationSeconds: 0.5, dvrWindowSeconds: 600)
        let playlistWindow = sizing.windowSegmentCount(observedSegmentDurationSeconds: 2.0)
        XCTAssertEqual(playlistWindow, 300)
        // SegmentCache's default backward hard window, which used to be the real bound.
        XCTAssertGreaterThan(playlistWindow, 20)
    }
}
