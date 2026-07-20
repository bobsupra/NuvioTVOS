import Testing
import Foundation
@testable import AetherEngine

/// #100: PGS cues carry an open-ended placeholder endTime (FFmpeg's
/// end_display_time = UINT32_MAX ms) and are closed only by the successor
/// composition's trim. When the side reader catches up after starvation
/// (the #96 class), backlog cues arrive already behind the playhead, so each
/// one's open window covers the playhead the instant it inserts and renders
/// until its successor lands seconds later: a burst of stale subtitles
/// flashing through the overlay. The gate holds stale arrivals until their
/// successor resolves their true window, then publishes only the cue that
/// genuinely covers the playhead.
struct Issue100PGSStaleArrivalTests {

    private static let openEnd = 4_294_967.295   // UINT32_MAX ms, FFmpeg placeholder

    private func cue(id: Int, start: Double, end: Double? = nil) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end ?? (start + Self.openEnd),
                    body: .text("line \(id)"))
    }

    // MARK: - Steady state stays byte-identical

    @Test("a cue starting at or ahead of the playhead publishes immediately")
    func steadyStatePassesThrough() {
        var gate = PGSStaleArrivalGate()
        let incoming = [cue(id: 1, start: 101.0)]
        let published = gate.admit(cues: incoming, isPGS: true, playhead: 100.0)
        #expect(published == incoming)
        #expect(!gate.hasHeld)
    }

    @Test("the active cue at a seek landing (reader anchors ~2s back) publishes immediately")
    func seekLandingActiveCuePassesThrough() {
        var gate = PGSStaleArrivalGate()
        let incoming = [cue(id: 1, start: 98.0)]
        let published = gate.admit(cues: incoming, isPGS: true, playhead: 100.0)
        #expect(published == incoming)
        #expect(!gate.hasHeld)
    }

    @Test("non-PGS events are never held")
    func nonPGSNeverHeld() {
        var gate = PGSStaleArrivalGate()
        let incoming = [cue(id: 1, start: 100.0, end: 104.0)]
        let published = gate.admit(cues: incoming, isPGS: false, playhead: 400.0)
        #expect(published == incoming)
        #expect(!gate.hasHeld)
    }

    @Test("a PGS clear event (no cues) passes through without holding")
    func clearEventNotHeld() {
        var gate = PGSStaleArrivalGate()
        let published = gate.admit(cues: [], isPGS: true, playhead: 400.0)
        #expect(published.isEmpty)
        #expect(!gate.hasHeld)
    }

    // MARK: - Stale arrivals

    @Test("a cue arriving far behind the playhead is held, not published")
    func staleArrivalHeld() {
        var gate = PGSStaleArrivalGate()
        let published = gate.admit(cues: [cue(id: 1, start: 358.358)],
                                   isPGS: true, playhead: 436.439)
        #expect(published.isEmpty)
        #expect(gate.hasHeld)
    }

    @Test("the successor drops a held cue whose true window is already history")
    func successorDropsStaleHistory() {
        var gate = PGSStaleArrivalGate()
        _ = gate.admit(cues: [cue(id: 1, start: 358.358)], isPGS: true, playhead: 436.439)
        let resolved = gate.resolveHeld(trimAt: 360.735, playhead: 436.439)
        #expect(resolved.isEmpty)
        #expect(!gate.hasHeld)
    }

    @Test("the successor publishes a held cue that genuinely covers the playhead")
    func successorPublishesActiveCue() {
        var gate = PGSStaleArrivalGate()
        _ = gate.admit(cues: [cue(id: 9, start: 430.0)], isPGS: true, playhead: 436.439)
        let resolved = gate.resolveHeld(trimAt: 440.0, playhead: 436.439)
        #expect(resolved.count == 1)
        #expect(resolved.first?.startTime == 430.0)
        #expect(resolved.first?.endTime == 440.0)
    }

    @Test("resolve with nothing held returns empty")
    func resolveWithoutHold() {
        var gate = PGSStaleArrivalGate()
        let resolved = gate.resolveHeld(trimAt: 100.0, playhead: 100.0)
        #expect(resolved.isEmpty)
    }

    @Test("reset drops the held cue (seek re-anchor, track switch, stop)")
    func resetClearsHold() {
        var gate = PGSStaleArrivalGate()
        _ = gate.admit(cues: [cue(id: 1, start: 300.0)], isPGS: true, playhead: 400.0)
        gate.reset()
        #expect(!gate.hasHeld)
        let resolved = gate.resolveHeld(trimAt: 310.0, playhead: 400.0)
        #expect(resolved.isEmpty)
    }

    // MARK: - The reporter's burst, end to end

    @Test("a catch-up backlog publishes only the cue that covers the playhead")
    func backlogBurstSuppressed() {
        // Playhead ~80s ahead of a starved reader; the backlog replays 17 cues
        // spanning 80s of content. On the old path every one of them rendered
        // for its inter-decode gap. Expected now: everything up to 430.972 is
        // held and dropped on resolution (true windows all ended before the
        // playhead); 434.017 lands INSIDE the epsilon, passes straight through
        // and is the genuinely active cue (true window 434.017-436.519 covers
        // the playhead; the resident-array trim closes it when 436.519 lands);
        // 436.519 is a normal ahead-of-playhead insert.
        let starts = [358.358, 360.735, 385.719, 408.533, 409.910, 411.328,
                      414.623, 416.499, 418.335, 420.712, 422.005, 423.256,
                      425.300, 427.677, 430.972, 434.017, 436.519]
        let playhead = 436.439
        var gate = PGSStaleArrivalGate()
        var publishedHistorical: [SubtitleCue] = []
        var publishedImmediately: [SubtitleCue] = []
        for (i, start) in starts.enumerated() {
            publishedHistorical += gate.resolveHeld(trimAt: start, playhead: playhead)
            publishedImmediately += gate.admit(cues: [cue(id: i, start: start)],
                                               isPGS: true, playhead: playhead)
        }
        #expect(publishedHistorical.isEmpty)
        #expect(publishedImmediately.map(\.startTime) == [434.017, 436.519])
        #expect(!gate.hasHeld)
    }
}
