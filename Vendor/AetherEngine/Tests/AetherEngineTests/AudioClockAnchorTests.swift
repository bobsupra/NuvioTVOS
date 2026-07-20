import XCTest
import CoreMedia
@testable import AetherEngine

/// Issue #89: the software AudioDecoder stamped each CMSampleBuffer with its container-quantized PTS.
/// For frame durations that are not an integer number of container ticks (1536-sample AC-3 @ 44.1 kHz
/// = 34.83 ms in a 1 ms MKV timebase) consecutive buffers no longer abut, and
/// AVSampleBufferAudioRenderer clicks at every frame (~29 Hz, a continuous crackle). AudioClockAnchor
/// stamps from a running sample count so buffers abut to the sample, re-anchoring only on a real
/// (> 100 ms) source discontinuity.
final class AudioClockAnchorTests: XCTestCase {

    /// Container-quantized PTS the demuxer hands us: MKV carries a 1 ms timebase, so the per-packet
    /// PTS is the frame's true time rounded to the nearest millisecond.
    private func containerPTS(frame n: Int, samplesPerFrame: Int, sampleRate: Int32) -> CMTime {
        let seconds = Double(n * samplesPerFrame) / Double(sampleRate)
        let ms = Int64((seconds * 1000).rounded())
        return CMTimeMake(value: ms, timescale: 1000)
    }

    /// Drive the anchor exactly as AudioDecoder.emitPending does: resolve, then commit on success.
    @discardableResult
    private func runStream(_ anchor: inout AudioClockAnchor,
                           ptsList: [CMTime],
                           samplesPerFrame: Int,
                           sampleRate: Int32) -> [CMTime] {
        var out: [CMTime] = []
        for pts in ptsList {
            let r = anchor.resolve(startPTS: pts, sampleRate: sampleRate)
            anchor.commit(pts: r.pts, reanchor: r.reanchor, sampleCount: samplesPerFrame)
            out.append(r.pts)
        }
        return out
    }

    // MARK: - The crackle bug

    func testConsecutiveBuffersAbutToTheSample_441kHzAC3() {
        let rate: Int32 = 44100
        let spf = 1536  // AC-3 frame
        var anchor = AudioClockAnchor()
        let ptsList = (0..<10).map { containerPTS(frame: $0, samplesPerFrame: spf, sampleRate: rate) }

        let out = runStream(&anchor, ptsList: ptsList, samplesPerFrame: spf, sampleRate: rate)

        let expectedStep = Double(spf) / Double(rate)  // 34.8299... ms, the true frame length
        for n in 1..<out.count {
            let delta = CMTimeGetSeconds(CMTimeSubtract(out[n], out[n - 1]))
            XCTAssertEqual(delta, expectedStep, accuracy: 1e-6,
                "buffer \(n) must abut to the sample; got \(delta * 1000) ms, expected \(expectedStep * 1000) ms")
        }
    }

    func testFirstBufferAnchorsToItsStartPTS() {
        let anchor = AudioClockAnchor()
        let start = CMTimeMake(value: 5000, timescale: 1000)
        let r = anchor.resolve(startPTS: start, sampleRate: 44100)
        XCTAssertTrue(r.reanchor)
        XCTAssertEqual(r.pts, start)
    }

    // MARK: - Jitter is absorbed, real discontinuities re-anchor

    func testSmallContainerJitterIsAbsorbed() {
        let rate: Int32 = 44100
        let spf = 1536
        var anchor = AudioClockAnchor()

        let r0 = anchor.resolve(startPTS: .zero, sampleRate: rate)
        anchor.commit(pts: r0.pts, reanchor: r0.reanchor, sampleCount: spf)

        // True next boundary is 34.83 ms; the container rounds it to 35 ms. The 0.17 ms jitter is what
        // produced the per-frame click, so it must be absorbed (predicted used, not the rounded PTS).
        let jittery = CMTimeMake(value: 35, timescale: 1000)
        let r1 = anchor.resolve(startPTS: jittery, sampleRate: rate)
        XCTAssertFalse(r1.reanchor, "sub-threshold container rounding must not re-anchor")
        XCTAssertEqual(CMTimeGetSeconds(r1.pts), Double(spf) / Double(rate), accuracy: 1e-6,
            "buffer must be stamped at the sample-accurate predicted time, not the rounded container PTS")
    }

    func testRealDiscontinuityReanchors() {
        let rate: Int32 = 44100
        let spf = 1536
        var anchor = AudioClockAnchor()
        let ptsList = (0..<5).map { containerPTS(frame: $0, samplesPerFrame: spf, sampleRate: rate) }
        runStream(&anchor, ptsList: ptsList, samplesPerFrame: spf, sampleRate: rate)

        let seek = CMTimeMake(value: 60_000, timescale: 1000)  // a 60 s jump dwarfs container jitter
        let r = anchor.resolve(startPTS: seek, sampleRate: rate)
        XCTAssertTrue(r.reanchor)
        XCTAssertEqual(r.pts, seek, "a real source discontinuity must be honoured, not papered over")
    }

    func testResetReanchorsNextBuffer() {
        let rate: Int32 = 44100
        let spf = 1536
        var anchor = AudioClockAnchor()
        let ptsList = (0..<5).map { containerPTS(frame: $0, samplesPerFrame: spf, sampleRate: rate) }
        runStream(&anchor, ptsList: ptsList, samplesPerFrame: spf, sampleRate: rate)

        anchor.reset()

        // 174 ms sits right on the predicted clock (5 * 1536 / 44100 = 174.1 ms); without reset it would
        // be absorbed as a continuation. After a flush it must re-anchor to its own PTS instead.
        let afterFlush = CMTimeMake(value: 174, timescale: 1000)
        let r = anchor.resolve(startPTS: afterFlush, sampleRate: rate)
        XCTAssertTrue(r.reanchor, "flush must drop the anchor so the post-seek buffer re-anchors")
        XCTAssertEqual(r.pts, afterFlush)
    }

    // MARK: - The clean case stays clean, and dropped buffers don't drift the clock

    func test48kHzAC3StaysGapless() {
        let rate: Int32 = 48000
        let spf = 1536  // exactly 32 ms, always was gapless
        var anchor = AudioClockAnchor()
        let ptsList = (0..<10).map { containerPTS(frame: $0, samplesPerFrame: spf, sampleRate: rate) }

        let out = runStream(&anchor, ptsList: ptsList, samplesPerFrame: spf, sampleRate: rate)

        let expectedStep = Double(spf) / Double(rate)
        for n in 1..<out.count {
            let delta = CMTimeGetSeconds(CMTimeSubtract(out[n], out[n - 1]))
            XCTAssertEqual(delta, expectedStep, accuracy: 1e-6)
        }
    }

    func testDroppedBufferDoesNotAdvanceClock() {
        let rate: Int32 = 44100
        let spf = 1536
        var anchor = AudioClockAnchor()

        // Frame 0 emits and commits: clock now holds 1536 samples.
        let r0 = anchor.resolve(startPTS: .zero, sampleRate: rate)
        anchor.commit(pts: r0.pts, reanchor: r0.reanchor, sampleCount: spf)

        // Frame 1 resolves but its CMSampleBuffer creation fails, so it is never committed.
        _ = anchor.resolve(startPTS: containerPTS(frame: 1, samplesPerFrame: spf, sampleRate: rate), sampleRate: rate)

        // Frame 2 must predict off the still-1536 sample count (one frame in), proving the dropped
        // buffer injected no phantom samples.
        let r2 = anchor.resolve(startPTS: containerPTS(frame: 2, samplesPerFrame: spf, sampleRate: rate), sampleRate: rate)
        XCTAssertFalse(r2.reanchor)
        XCTAssertEqual(CMTimeGetSeconds(r2.pts), Double(spf) / Double(rate), accuracy: 1e-6,
            "an uncommitted (dropped) buffer must not advance the sample clock")
    }
}
