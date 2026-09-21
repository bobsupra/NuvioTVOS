// Tests/AetherEngineTests/PacketRingBufferTests.swift
import XCTest
@testable import AetherEngine

final class PacketRingBufferTests: XCTestCase {
    private func tmpDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("prbtest-\(ProcessInfo.processInfo.globallyUniqueString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func testAppendAndKeyframeSeek() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: tmpDir())
        try ring.append(pts: 0, isKeyframe: true,  isVideo: true, bytes: Data([0]))
        try ring.append(pts: 1, isKeyframe: false, isVideo: true, bytes: Data([1]))
        try ring.append(pts: 2, isKeyframe: true,  isVideo: true, bytes: Data([2]))
        try ring.append(pts: 3, isKeyframe: false, isVideo: true, bytes: Data([3]))
        XCTAssertEqual(try ring.keyframePts(atOrBefore: 3.5), 2)
        XCTAssertEqual(try ring.packets(fromPts: 2).map(\.pts), [2, 3])
    }
    func testEvictsOutsideWindow() throws {
        let ring = try PacketRingBuffer(windowSeconds: 5, scratch: tmpDir())
        for i in 0...20 { try ring.append(pts: Double(i), isKeyframe: i % 2 == 0, isVideo: true, bytes: Data([UInt8(i)])) }
        // edge 20, window 5 -> oldest retained must keep a keyframe at/below 15
        XCTAssertLessThanOrEqual(try XCTUnwrap(ring.oldestPts), 15)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(ring.oldestPts), 13)
    }
    func testReplayBytesRoundTrip() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: tmpDir())
        try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: Data([9, 8, 7]))
        XCTAssertEqual(try ring.packets(fromPts: 0).first?.bytes, Data([9, 8, 7]))
    }

    /// SW DVR reseed: host routes replay by `isVideo` (audio shares `isKeyframe == false`); verify flag + payload round-trip in order.
    func testReseedRoutingPreservesStreamKindInOrder() throws {
        let ring = try PacketRingBuffer(windowSeconds: 30, scratch: tmpDir())
        try ring.append(pts: 10.0, isKeyframe: true,  isVideo: true,  bytes: Data([1]))
        try ring.append(pts: 10.0, isKeyframe: false, isVideo: false, bytes: Data([2]))
        try ring.append(pts: 10.1, isKeyframe: false, isVideo: true,  bytes: Data([3]))
        try ring.append(pts: 10.1, isKeyframe: false, isVideo: false, bytes: Data([4]))
        try ring.append(pts: 10.2, isKeyframe: false, isVideo: true,  bytes: Data([5]))

        let kf = try XCTUnwrap(try ring.keyframePts(atOrBefore: 10.15))
        XCTAssertEqual(kf, 10.0)

        let replay = try ring.packets(fromPts: kf)
        XCTAssertEqual(replay.count, 5)
        XCTAssertEqual(replay.map(\.isVideo), [true, false, true, false, true])
        XCTAssertEqual(replay.map(\.isKeyframe), [true, false, false, false, false])
        XCTAssertEqual(replay.filter(\.isKeyframe).count, 1)
        XCTAssertTrue(replay.first?.isKeyframe == true && replay.first?.isVideo == true)
        XCTAssertEqual(replay.map { $0.bytes.first }, [1, 2, 3, 4, 5])
    }

    /// #136: close() clears the in-RAM index synchronously (ring immediately unusable) and is
    /// idempotent, so a second teardown from a racing thread is a no-op rather than a crash.
    func testCloseClearsStateSynchronouslyAndIsIdempotent() throws {
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: tmpDir())
        try ring.append(pts: 0, isKeyframe: true,  isVideo: true, bytes: Data([0]))
        try ring.append(pts: 1, isKeyframe: false, isVideo: true, bytes: Data([1]))
        XCTAssertNotNil(ring.oldestPts)

        ring.close()
        XCTAssertNil(ring.oldestPts)
        XCTAssertNil(try ring.keyframePts(atOrBefore: .infinity))
        XCTAssertTrue(try ring.packets(fromPts: 0).isEmpty)
        XCTAssertEqual(ring.seqBounds.first, ring.seqBounds.end)

        ring.close()  // second teardown must be a harmless no-op
    }

    /// #136: scratch-directory removal is dispatched to a background queue so close() never blocks the
    /// caller; the directory (and every spooled packet file under it) is gone shortly after.
    func testCloseRemovesScratchDirectoryOffCaller() throws {
        let scratch = tmpDir()
        let ring = try PacketRingBuffer(windowSeconds: 10, scratch: scratch)
        try ring.append(pts: 0, isKeyframe: true, isVideo: true, bytes: Data([0]))
        try ring.append(pts: 1, isKeyframe: true, isVideo: true, bytes: Data([1]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))

        ring.close()

        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: scratch.path), Date() < deadline {
            usleep(20_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path),
                       "scratch dir should be removed by the background teardown")
    }

    /// Target predating the window: host clamps to `oldestPts`, which the ring guarantees is a keyframe.
    func testTargetBeforeWindowClampsToKeyframeOldest() throws {
        let ring = try PacketRingBuffer(windowSeconds: 5, scratch: tmpDir())
        for i in 0...20 { try ring.append(pts: Double(i), isKeyframe: i % 2 == 0, isVideo: true, bytes: Data([UInt8(i)])) }
        let oldest = try XCTUnwrap(ring.oldestPts)
        XCTAssertNil(try ring.keyframePts(atOrBefore: -100))
        let firstAtOldest = try XCTUnwrap(try ring.packets(fromPts: oldest).first)
        XCTAssertTrue(firstAtOldest.isKeyframe)
    }
}

// MARK: - Still run planning (#544)

/// The span a ring-backed still needs, as a pure function of the index, so the decode step never
/// has to reason about eviction or bounds.
final class PacketRingStillRunTests: XCTestCase {

    private func video(_ pts: Double, key: Bool = false) -> PacketRingBuffer.IndexEntry {
        PacketRingBuffer.IndexEntry(pts: pts, isKeyframe: key, isVideo: true)
    }
    private func audio(_ pts: Double) -> PacketRingBuffer.IndexEntry {
        PacketRingBuffer.IndexEntry(pts: pts, isKeyframe: false, isVideo: false)
    }

    private func span(_ index: [PacketRingBuffer.IndexEntry],
                      target: Double,
                      firstSeq: Int = 0,
                      maxPackets: Int = 1000,
                      maxSpanSeconds: Double = 30,
                      reorderTail: Int = 0,
                      indexReachesEnd: Bool = true) -> ClosedRange<Int>? {
        PacketRingBuffer.stillRunSpan(target: target, index: index, firstSeq: firstSeq,
                                      maxPackets: maxPackets, maxSpanSeconds: maxSpanSeconds,
                                      reorderTail: reorderTail, indexReachesEnd: indexReachesEnd)
    }

    /// Starts at the newest keyframe at or before the target, ends at the first video packet reaching it.
    func testStartsAtKeyframeBeforeTargetAndEndsWhenReached() {
        let index = [video(0, key: true), video(1), video(2, key: true), video(3), video(4)]
        XCTAssertEqual(span(index, target: 3), 2...3)
    }

    /// A later keyframe wins: the run never decodes more of the GOP than it has to.
    func testPicksTheNewestKeyframeNotTheOldest() {
        let index = [video(0, key: true), video(2, key: true), video(4, key: true), video(6)]
        XCTAssertEqual(span(index, target: 6), 2...3)
    }

    /// Sequence numbers are absolute, so an evicted ring still addresses its packets.
    func testSpanIsInAbsoluteSequenceNumbers() {
        let index = [video(10, key: true), video(11), video(12)]
        XCTAssertEqual(span(index, target: 12, firstSeq: 900), 900...902)
    }

    /// At the live edge the target routinely overshoots the newest packet by a fraction. Clamping
    /// there rather than returning nil is what keeps the card from blinking out at the edge.
    func testTargetPastNewestPacketClampsToIt() {
        let index = [video(0, key: true), video(1), video(2)]
        XCTAssertEqual(span(index, target: 9.5), 0...2)
    }

    /// Scrubbed off the back of the window: nothing decodable, and saying so is the honest answer.
    func testTargetBeforeOldestKeyframeIsNil() {
        let index = [video(5, key: true), video(6)]
        XCTAssertNil(span(index, target: 1))
    }

    /// A stream whose keyframes are minutes apart must not hold a still request hostage.
    func testRefusesAGopLongerThanTheSpanBound() {
        let index = [video(0, key: true)] + (1...40).map { video(Double($0)) }
        XCTAssertNil(span(index, target: 40, maxSpanSeconds: 10))
        XCTAssertNotNil(span(index, target: 40, maxSpanSeconds: 60))
    }

    /// The same guard in packets, because the cost is one file read each.
    func testRefusesARunLongerThanThePacketBound() {
        let index = [video(0, key: true)] + (1...40).map { video(Double($0) * 0.04) }
        XCTAssertNil(span(index, target: 1.6, maxPackets: 20))
        XCTAssertNotNil(span(index, target: 1.6, maxPackets: 200))
    }

    /// Audio rides along inside the span (the caller skips it) but never ends the run.
    func testAudioDoesNotEndTheRun() {
        let index = [video(0, key: true), audio(0.5), audio(1.5), video(2)]
        XCTAssertEqual(span(index, target: 2), 0...3)
    }

    /// Packets arrive in decode order, so with B-frames the first packet reaching the target is not
    /// the last one the decoder needs to emit it. The tail is what a reordered stream costs.
    func testReorderTailExtendsPastTheFirstPacketReachingTheTarget() {
        // decode order I P B B, presentation 0 3 1 2
        let index = [video(0, key: true), video(3), video(1), video(2)]
        XCTAssertEqual(span(index, target: 2, reorderTail: 0), 0...1)
        XCTAssertEqual(span(index, target: 2, reorderTail: 2), 0...3)
    }

    /// The tail cannot walk past the newest packet the ring holds.
    func testReorderTailStopsAtTheNewestPacket() {
        let index = [video(0, key: true), video(1), video(2)]
        XCTAssertEqual(span(index, target: 2, reorderTail: 8), 0...2)
    }

    /// An index with no video at all (audio-only stretch) has no still in it.
    func testNoVideoIsNil() {
        XCTAssertNil(span([audio(0), audio(1)], target: 1))
    }

    /// A window the CALLER truncated must not be read as the ring ending. Clamping there would
    /// return a picture from before the requested time and present it as the answer.
    func testTruncatedWindowRefusesInsteadOfClamping() {
        let index = [video(0, key: true), video(1), video(2)]
        XCTAssertNil(span(index, target: 9.5, indexReachesEnd: false))
        XCTAssertEqual(span(index, target: 9.5, indexReachesEnd: true), 0...2)
    }

    /// A target the window DOES reach is unaffected by where the window ends.
    func testTruncatedWindowStillAnswersATargetItCovers() {
        let index = [video(0, key: true), video(1), video(2)]
        XCTAssertEqual(span(index, target: 2, indexReachesEnd: false), 0...2)
    }
}
