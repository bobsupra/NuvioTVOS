import Testing
import Foundation
@testable import AetherEngine

/// #368 follow-up: the chunk-seam rebase keeps the ITEM axis continuous by moving the producer's
/// shift, which is exactly what the cutter and the append playlist need. The published clock,
/// however, was folded as `item + shift - origin` against an origin latched once at session start,
/// so the whole rebase delta landed on the scrubber: on the field archive (source PTS start
/// 32070.8 s, chunk seam wrap-corrected by libavformat to 2^33 ticks = 95443.7 s) the playhead
/// leaps from 250 s to 63378 s on an item whose declared duration is one hour.
///
/// A sequential origin's source axis is not an axis: every archive chunk restarts near PTS 0 and
/// the 33-bit wrap correction turns each seam into a fresh fiction. Its published axis is therefore
/// the item axis, which starts at 0 by construction (the producer is pinned to byte 0) and is what
/// `declaredDurationSeconds` measures.
@MainActor
struct Issue368SequentialDisplayAxisTests {

    /// Field numbers: archive source PTS start 32070.8 s, seam at item 244 s, 50 fps.
    private static let sourceStart = 32_070.8
    private static let seamItemSeconds = 244.02
    private static let wrappedSeamSourceSeconds = Double(Int64(1) << 33) / 90_000.0
    private static var rebasedShift: Double { wrappedSeamSourceSeconds - seamItemSeconds }

    /// A sequential archive publishes the item axis, so a chunk seam moves the clock by one tick's
    /// worth of playback, not by the wrap.
    @Test("the published clock stays on the archive's own axis across a chunk seam")
    func clockStaysContinuousAcrossAChunkSeam() throws {
        let engine = try AetherEngine()
        engine.displayAxisIsItemAxis = true
        engine.sourcePresentationOrigin = Self.sourceStart
        engine.latchedPresentationOrigin = Self.sourceStart
        engine.setPresentationAxis(.anchored(shiftSeconds: Self.sourceStart))

        engine.applyNativeHostClockTick(240.0)
        #expect(abs(engine.clock.currentTime - 240.0) < 0.001)

        var map = engine.presentationAxis
        map.appendSeam(shiftSeconds: Self.rebasedShift, activatingAtItemSeconds: Self.seamItemSeconds)
        engine.setPresentationAxis(map)

        // Still rendering pre-seam bytes: the shift in effect is the pre-seam one either way.
        engine.applyNativeHostClockTick(243.0)
        #expect(abs(engine.clock.currentTime - 243.0) < 0.001)

        // Past the seam: the rebase delta (~63 129 s) must not reach the scrubber.
        engine.applyNativeHostClockTick(250.0)
        #expect(abs(engine.clock.currentTime - 250.0) < 0.001)
        #expect(abs(engine.playlistShiftSeconds - Self.rebasedShift) < 0.001)
    }

    /// The buffer bar is drawn against the same 0-based duration as the playhead, so it folds the
    /// same way. Its input is the RENDERED position, which lags the clock across the seam.
    @Test("the buffered frontier folds on the item axis too")
    func bufferedPositionStaysOnTheItemAxis() throws {
        let engine = try AetherEngine()
        engine.displayAxisIsItemAxis = true
        engine.sourcePresentationOrigin = Self.sourceStart

        #expect(abs(engine.displayOrigin(forShift: Self.rebasedShift) - Self.rebasedShift) < 0.001)
        #expect(abs(PresentationAxis.display(sourcePTS: 250.0 + Self.rebasedShift,
                                             origin: engine.displayOrigin(forShift: Self.rebasedShift))
                    - 250.0) < 0.001)
    }

    /// Every other source keeps AE#270's latched origin: its source timestamps are a real axis, and a
    /// later publish carries producer drift, not a new origin.
    @Test("an ordinary VOD source keeps its latched display origin")
    func ordinarySourceKeepsTheLatchedOrigin() throws {
        let engine = try AetherEngine()
        engine.sourcePresentationOrigin = 1_002.741
        #expect(engine.displayOrigin(forShift: 1_004.7) == 1_002.741)

        engine.setPresentationAxis(.anchored(shiftSeconds: 1_002.741))
        engine.applyNativeHostClockTick(480.0)
        #expect(abs(engine.clock.currentTime - 480.0) < 0.001)
    }
}
