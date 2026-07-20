// Tests/AetherEngineTests/SegmentRetentionTests.swift
// Byte-budgeted backward retention (#93 / Sodalite#32): already-produced segments beyond the hard
// prune window stay resident until a byte budget fills, so a backward seek into watched content is
// served straight from cache instead of tearing the producer down. The producer restart is what
// wedges AVPlayer on slow sources (#93) and detaches AVKit's PiP legible renderer (Sodalite#32),
// so the retained span is exactly the span across which seeks are restart-free.
import Foundation
import Testing
@testable import AetherEngine

@Suite("SegmentCache byte-budgeted retention")
struct SegmentCacheRetentionTests {

    private func makeData(_ n: Int, fill: UInt8 = 0xAA) -> Data { Data(repeating: fill, count: n) }

    @Test("Budget keeps out-of-window backward segments resident across a forward march")
    func budgetRetainsBackwardHistory() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 2, retentionBudgetBytes: 1_000_000)
        defer { c.close() }
        for i in 0...30 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        // Legacy pruning would have evicted everything below 30 - backwardWindow = 28.
        #expect(c.count == 31)
        #expect(c.peek(index: 0) != nil)
        #expect(c.peek(index: 15) != nil)
    }

    @Test("Over budget, the farthest-behind extras are evicted first; the window survives")
    func budgetEvictsFarthestFirst() {
        // Window at the march head is [t-1, t] (hi anchors on highestStoredIndex == t): 2 x 10 B.
        // Budget 60 leaves room for the 4 extras nearest the target.
        let c = SegmentCache(forwardWindow: 1, backwardWindow: 1, retentionBudgetBytes: 60)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        #expect(c.peek(index: 10) != nil)
        #expect(c.peek(index: 9) != nil)
        #expect(c.peek(index: 5) != nil)   // nearest extras retained: 8, 7, 6, 5
        #expect(c.peek(index: 4) == nil)   // farthest behind: evicted once the budget filled
        #expect(c.totalBytes == 60)
    }

    @Test("Hard window is never evicted, even when it alone exceeds the budget")
    func windowSurvivesTinyBudget() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 2, retentionBudgetBytes: 30)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(20)) }
        // Window [8..10] = 60 B > budget: extras all gone, window fully resident (correctness
        // beats the budget; the near-behind window covers AVPlayer audio-handover refetches).
        #expect(c.peek(index: 8) != nil)
        #expect(c.peek(index: 9) != nil)
        #expect(c.peek(index: 10) != nil)
        #expect(c.peek(index: 7) == nil)
    }

    @Test("Zero budget preserves the legacy window-only pruning exactly")
    func zeroBudgetIsLegacy() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 2, retentionBudgetBytes: 0)
        defer { c.close() }
        for i in 0...10 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        #expect(c.peek(index: 7) == nil)   // below target - backwardWindow
        #expect(c.peek(index: 8) != nil)
    }

    @Test("A backward target jump into retained history evicts nothing")
    func backwardJumpKeepsEverything() {
        let c = SegmentCache(forwardWindow: 2, backwardWindow: 2, retentionBudgetBytes: 1_000_000)
        defer { c.close() }
        for i in 0...30 { c.declareTarget(i); c.store(index: i, data: makeData(10)) }
        c.declareTarget(0)   // the backward seek
        #expect(c.count == 31)
        #expect(c.peek(index: 0) != nil)
        #expect(c.peek(index: 30) != nil)
    }
}

// MARK: - Provider-level: the restart gate

/// Records restartHandler invocations; the fake "new producer" stores the requested segment so the
/// provider's post-restart fetch resolves immediately instead of parking on the reposition wait.
private final class RestartRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _indices: [Int] = []
    var indices: [Int] { lock.lock(); defer { lock.unlock() }; return _indices }
    func record(_ idx: Int) { lock.lock(); _indices.append(idx); lock.unlock() }
}

@Suite("VideoSegmentProvider backward-seek restart avoidance")
struct VideoSegmentProviderRetentionTests {

    private func makeSegments(_ n: Int) -> [HLSVideoEngine.Segment] {
        (0..<n).map { i in
            HLSVideoEngine.Segment(
                startPts: Int64(i) * 4000,
                endPts: Int64(i + 1) * 4000,
                startSeconds: Double(i) * 4.0,
                durationSeconds: 4.0
            )
        }
    }

    private func makeProvider(cache: SegmentCache, count: Int,
                              recorder: RestartRecorder) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: cache,
            segments: makeSegments(count),
            codecsString: "hvc1.2.4.L120.B0",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 24.0,
            hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            restartHandler: { [weak cache] idx in
                recorder.record(idx)
                // Simulate the restarted producer: write the segment AVPlayer is starved for.
                cache?.store(index: idx, data: Data(repeating: 0xCD, count: 10))
            }
        )
    }

    @Test("Backward seek into retained content is served from cache with zero producer restarts")
    func retainedBackwardSeekDoesNotRestart() {
        let cache = SegmentCache(forwardWindow: 2, backwardWindow: 2, retentionBudgetBytes: 1_000_000)
        defer { cache.close() }
        let restarts = RestartRecorder()
        let provider = makeProvider(cache: cache, count: 31, recorder: restarts)
        // Playback march: producer stores each segment, AVPlayer fetches it.
        for i in 0...30 {
            cache.store(index: i, data: Data(repeating: 0xAB, count: 10))
            #expect(provider.mediaSegment(at: i) != nil)
        }
        // AVPlayer backward seek to segment 0: far outside the hard window, inside the retained span.
        #expect(provider.mediaSegment(at: 0) != nil)
        #expect(restarts.indices.isEmpty)
    }

    @Test("Zero-budget cache restarts the producer on the same backward seek (legacy contrast)")
    func legacyBackwardSeekRestarts() {
        let cache = SegmentCache(forwardWindow: 2, backwardWindow: 2, retentionBudgetBytes: 0)
        defer { cache.close() }
        let restarts = RestartRecorder()
        let provider = makeProvider(cache: cache, count: 31, recorder: restarts)
        for i in 0...30 {
            cache.store(index: i, data: Data(repeating: 0xAB, count: 10))
            #expect(provider.mediaSegment(at: i) != nil)
        }
        #expect(provider.mediaSegment(at: 0) != nil)
        #expect(restarts.indices == [0])
    }
}

// MARK: - Budget sizing

@Suite("VOD retention budget sizing")
struct RetentionBudgetSizingTests {

    @Test("Budget clamps to a quarter of the available capacity on tight disks")
    func clampsToQuarterOfFreeDisk() {
        #expect(HLSVideoEngine.vodRetentionBudgetBytes(volumeAvailableBytes: 4 << 30) == 1 << 30)
    }

    @Test("Budget caps at 2 GiB on roomy disks")
    func capsAtDefault() {
        #expect(HLSVideoEngine.vodRetentionBudgetBytes(volumeAvailableBytes: 100 << 30) == 2 << 30)
    }

    @Test("Unknown capacity falls back to the cap")
    func unknownCapacityFallsBack() {
        #expect(HLSVideoEngine.vodRetentionBudgetBytes(volumeAvailableBytes: nil) == 2 << 30)
    }
}
