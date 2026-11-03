import XCTest
@testable import NuvioTV

final class AudioSubtitleSyncTests: XCTestCase {
    /// A repeatable stream of numbers in 0..<1.
    private struct Numbers {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((state >> 33) & 0x7FFF_FFFF) / Double(0x8000_0000)
        }
    }

    /// 70 lines from 5 s on, with short gaps and now and then a longer one.
    private func lines(seed: UInt64) -> [ClosedRange<Double>] {
        var numbers = Numbers(state: seed)
        var time = 5.0
        var out: [ClosedRange<Double>] = []
        for i in 0..<70 {
            let gap = i % 9 == 8 ? 6.0 : 0.6 + 2.4 * numbers.next()
            let length = 1.2 + 2.8 * numbers.next()
            time += gap
            out.append(time...(time + length))
            time += length
        }
        return out
    }

    /// Speech levels (dB per 20 ms frame) of a soundtrack where the lines are spoken `shift`
    /// seconds after their subtitle times: a quiet bed, speech from just after each line starts
    /// to half a second before it ends, with syllable dips.
    private func soundtrack(_ lines: [ClosedRange<Double>], shift: Double, seconds: Double = 260) -> [Float] {
        var numbers = Numbers(state: 7)
        let count = Int(seconds * 50)
        var levels = (0..<count).map { _ in Float(-45 + 6 * (numbers.next() - 0.5)) }
        for line in lines {
            let start = Int(((line.lowerBound + shift + 0.1) * 50).rounded())
            let end = Int(((line.upperBound + shift - 0.5) * 50).rounded())
            guard max(start, 0) < min(end, count) else { continue }
            for frame in max(start, 0)..<min(end, count) {
                levels[frame] = Float(-24 - ((frame / 10) % 3 == 2 ? 10 : 0) + 4 * (numbers.next() - 0.5))
            }
        }
        return levels
    }

    private func window(_ levels: [Float]) -> (levels: [Float], first: Int) {
        (Array(levels[3250..<10750]), 3250)
    }

    // MARK: Estimate

    func testTheLinesAreFoundWhereTheyAreSpoken() throws {
        let subtitle = lines(seed: 42)
        let (levels, first) = window(soundtrack(subtitle, shift: 2.4))
        let estimate = try XCTUnwrap(AudioSubtitleSync.estimate(levels: levels, firstFrame: first, lines: subtitle))
        // Speech sets in 0.1 s after each line does.
        XCTAssertEqual(estimate.shift, 2.5, accuracy: 0.15)
        XCTAssertTrue(estimate.isSure, estimate.doubt ?? "")
        XCTAssertGreaterThan(estimate.lines, 20)
    }

    func testASubtitleShownTooLateIsPulledEarlier() throws {
        let subtitle = lines(seed: 42)
        let (levels, first) = window(soundtrack(subtitle, shift: -7.3))
        let estimate = try XCTUnwrap(AudioSubtitleSync.estimate(levels: levels, firstFrame: first, lines: subtitle))
        XCTAssertEqual(estimate.shift, -7.2, accuracy: 0.15)
        XCTAssertTrue(estimate.isSure, estimate.doubt ?? "")
    }

    func testTheWrongSubtitleIsNotSure() throws {
        let (levels, first) = window(soundtrack(lines(seed: 42), shift: 2.4))
        let estimate = try XCTUnwrap(AudioSubtitleSync.estimate(levels: levels, firstFrame: first, lines: lines(seed: 1234)))
        XCTAssertFalse(estimate.isSure)
        XCTAssertNotNil(estimate.doubt)
    }

    func testNothingHeardGivesNoEstimate() {
        let levels = [Float](repeating: .nan, count: 7500)
        XCTAssertNil(AudioSubtitleSync.estimate(levels: levels, firstFrame: 3250, lines: lines(seed: 42)))
    }

    func testOverlappingLinesAreMerged() {
        let cues = [
            SubtitleTimingCue(start: 1, end: 3),
            SubtitleTimingCue(start: 2, end: 4),
            SubtitleTimingCue(start: 6, end: 7),
        ]
        XCTAssertEqual(AudioSubtitleSync.intervals(of: cues), [1...4, 6...7])
    }

    // MARK: Meter

    private func tone(_ frequency: Double, seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * 48_000)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / 48_000)) }
    }

    func testTheMeterHearsTheSpeechBand() {
        var meter = SpeechLevelMeter()
        let voice = tone(1000, seconds: 0.2)
        let frames = voice.withUnsafeBufferPointer { meter.add($0, at: 10, discontinuity: true) }
        XCTAssertEqual(frames.map { $0.frame }, Array(500..<510))
        // A sine of 0.5 is 0.125 in mean square: −9 dB.
        XCTAssertEqual(frames[5].level, -9.0, accuracy: 1.0)

        var low = SpeechLevelMeter()
        let hum = tone(100, seconds: 0.2)
        let humFrames = hum.withUnsafeBufferPointer { low.add($0, at: 10, discontinuity: true) }
        XCTAssertLessThan(humFrames[5].level, frames[5].level - 12)
    }

    func testAFrameSpanningTwoBuffersIsOneFrame() {
        var meter = SpeechLevelMeter()
        let half = tone(1000, seconds: 0.01)
        let first = half.withUnsafeBufferPointer { meter.add($0, at: 1.0, discontinuity: true) }
        XCTAssertTrue(first.isEmpty)
        let second = half.withUnsafeBufferPointer { meter.add($0, at: 1.01, discontinuity: false) }
        XCTAssertEqual(second.map { $0.frame }, [50])
    }

    func testTheTimelineKeepsWhatWasHeard() {
        var timeline = SpeechLevelTimeline()
        timeline.set(-20, at: 0)
        timeline.set(-21, at: 1)
        timeline.set(-22, at: 1)
        timeline.set(-23, at: 600)
        XCTAssertEqual(timeline.heardFrames, 3)
        let start = timeline.levels(from: -1, count: 3)
        XCTAssertTrue(start[0].isNaN)
        XCTAssertEqual(Array(start[1...]), [-20, -22])
        let later = timeline.levels(from: 599, count: 2)
        XCTAssertTrue(later[0].isNaN)
        XCTAssertEqual(later[1], -23)
    }

    // MARK: Following

    private func estimate(_ shift: Double, sure: Bool = true) -> AudioSyncEstimate {
        AudioSyncEstimate(shift: shift, standout: sure ? 8 : 2, rival: 0.5, halvesApart: 0.05,
                          lines: 30, heard: 120, speech: 0.4)
    }

    func testTheShiftFollowsAChangeSeenTwice() {
        var tracker = AudioShiftTracker()
        XCTAssertEqual(tracker.take(estimate(2.0, sure: false)), .hold)
        XCTAssertEqual(tracker.take(estimate(2.0)), .apply(2.0))
        tracker.didApply(2.0)
        XCTAssertEqual(tracker.take(estimate(2.25)), .keep)
        XCTAssertEqual(tracker.take(estimate(3.0)), .hold)
        XCTAssertEqual(tracker.take(estimate(3.125)), .apply(3.0625))
        tracker.didApply(3.0625)
        XCTAssertEqual(tracker.take(estimate(1.0)), .hold)
        XCTAssertEqual(tracker.take(estimate(5.0)), .hold)
        XCTAssertEqual(tracker.take(estimate(5.125)), .apply(5.0625))
    }

    func testTheDelayChangesWithoutALineOnScreen() {
        let shown: [ClosedRange<Double>] = [10...12, 14...15]
        XCTAssertTrue(AudioSyncGap.isClear(at: 13, shown: shown, from: 0, to: 0))
        XCTAssertFalse(AudioSyncGap.isClear(at: 11, shown: shown, from: 0, to: 0))
        XCTAssertFalse(AudioSyncGap.isClear(at: 13.7, shown: shown, from: 0, to: 0))
        XCTAssertFalse(AudioSyncGap.isClear(at: 13, shown: shown, from: 0, to: 1.5))
        XCTAssertTrue(AudioSyncGap.isClear(at: 16, shown: shown, from: 0, to: 0.5))
    }
}
