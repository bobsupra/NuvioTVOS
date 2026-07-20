// Tests/AetherEngineTests/SubtitleBatchFlushTests.swift
//
// Covers the batch-flush decision that keeps the embedded ASS side reader from
// collapsing to MainActor scheduling rate on packet-dense tracks (#56). One
// awaited MainActor hop per decoded event serialised the demux loop against the
// host's on-MainActor ASS renderer; coalescing events into a handful of hops
// per source-time window decouples demux throughput from MainActor pressure.
import XCTest
@testable import AetherEngine

final class SubtitleBatchFlushTests: XCTestCase {
    private let window = AetherEngine.embeddedSubtitleFlushWindowSeconds
    private let cap = AetherEngine.embeddedSubtitleFlushCountCap

    private let noSpan: Double? = nil

    func test_emptyBatchNeverFlushes() {
        XCTAssertFalse(AetherEngine.shouldFlushSubtitleBatch(pendingCount: 0, batchSpanSeconds: 0))
        XCTAssertFalse(AetherEngine.shouldFlushSubtitleBatch(pendingCount: 0, batchSpanSeconds: noSpan))
        XCTAssertFalse(AetherEngine.shouldFlushSubtitleBatch(pendingCount: 0, batchSpanSeconds: 999))
    }

    func test_sparseTrackFlushesPerEvent_spanAtOrPastWindow() {
        // Sparse track: demux clock advances past the window per cue, so single events flush immediately.
        XCTAssertTrue(AetherEngine.shouldFlushSubtitleBatch(pendingCount: 1, batchSpanSeconds: window))
        XCTAssertTrue(AetherEngine.shouldFlushSubtitleBatch(pendingCount: 1, batchSpanSeconds: window + 5))
    }

    func test_densClusterHeldUntilWindowElapses() {
        // Dense cluster: held until demux position crosses the window boundary.
        XCTAssertFalse(AetherEngine.shouldFlushSubtitleBatch(pendingCount: 5, batchSpanSeconds: 0))
        XCTAssertFalse(AetherEngine.shouldFlushSubtitleBatch(pendingCount: 5, batchSpanSeconds: window - 0.001))
        XCTAssertTrue(AetherEngine.shouldFlushSubtitleBatch(pendingCount: 5, batchSpanSeconds: window))
    }

    func test_countCapForcesFlushWhenSpanStalls() {
        // Same-timestamp burst (span == 0 or nil) never trips the window rule; count cap bounds memory and hop size.
        XCTAssertFalse(AetherEngine.shouldFlushSubtitleBatch(pendingCount: cap - 1, batchSpanSeconds: 0))
        XCTAssertTrue(AetherEngine.shouldFlushSubtitleBatch(pendingCount: cap, batchSpanSeconds: 0))
        XCTAssertTrue(AetherEngine.shouldFlushSubtitleBatch(pendingCount: cap, batchSpanSeconds: noSpan))
        XCTAssertTrue(AetherEngine.shouldFlushSubtitleBatch(pendingCount: cap + 10, batchSpanSeconds: noSpan))
    }

    func test_nilSpanBelowCapDoesNotFlush() {
        // No usable demux clock yet (NOPTS) and under the cap: hold.
        XCTAssertFalse(AetherEngine.shouldFlushSubtitleBatch(pendingCount: 1, batchSpanSeconds: noSpan))
        XCTAssertFalse(AetherEngine.shouldFlushSubtitleBatch(pendingCount: cap - 1, batchSpanSeconds: noSpan))
    }
}
