import Foundation
import Testing
@testable import AetherEngine

/// #357: one test per way the delivery line could lie about a drain tick. The report that motivated
/// it read "no `applySubtitleEvent` line" as "nothing was delivered", which the old diagnostic could
/// not support: it was capped at 20 lines per load and sat ahead of every gate. Each case below
/// pins one of the outcomes that were indistinguishable from outside.
struct Issue357SubtitleDeliveryTests {

    private func tally(packets: Int = 0, events: Int = 0, cues: Int = 0,
                       admitted: Int = 0, published: Int = 0,
                       reconstructing: Bool = false) -> SubtitleDeliveryStatement.Tally {
        var tally = SubtitleDeliveryStatement.Tally()
        tally.packets = packets
        tally.events = events
        tally.cues = cues
        tally.admitted = admitted
        tally.published = published
        tally.reconstructing = reconstructing
        return tally
    }

    // MARK: - Outcome classification

    @Test("a window with no stored packets reads as empty, not as a delivery failure")
    func emptyWindow() {
        #expect(tally().outcome == .empty)
    }

    @Test("packets that produce no event read as undecodable, which the cursor alone hides")
    func packetsWithoutEvents() {
        // The drain cursor advances over these packets regardless, so `decodedThrough` keeps pace
        // while nothing renders. That combination is exactly what #357 reported.
        #expect(tally(packets: 12, events: 0).outcome == .undecodable)
    }

    @Test("cues the gate holds are reported as held, not as an absent event")
    func gateHold() {
        #expect(tally(packets: 4, events: 4, cues: 4, admitted: 0, published: 0,
                      reconstructing: true).outcome == .held)
    }

    @Test("cues the gate passed that the store already holds read as duplicate, not as published")
    func alreadyStored() {
        // A backward seek re-decodes a region whose cues are still retained. The insert dedupes, so
        // nothing is published and nothing is wrong.
        #expect(tally(packets: 6, events: 6, cues: 6, admitted: 6, published: 0).outcome == .duplicate)
    }

    @Test("clear-only events read as trimOnly: they retire a line and publish nothing")
    func clearOnly() {
        // A zero-object PGS clear carries pgsTrimAt and no cues. It is the composition that removes
        // the line during silence, and the old diagnostic could not see it at all.
        #expect(tally(packets: 2, events: 2, cues: 0).outcome == .trimOnly)
    }

    @Test("any published cue wins the classification")
    func published() {
        #expect(tally(packets: 9, events: 9, cues: 3, admitted: 3, published: 1).outcome == .published)
    }

    // MARK: - Emission policy

    @Test("a steady run of identical outcomes emits once, so 2 Hz cannot bury the transitions")
    func repeatedOutcomeStaysQuiet() {
        #expect(SubtitleDeliveryStatement.shouldEmit(outcome: .published, last: .published,
                                                     isReset: false) == false)
    }

    @Test("a change of outcome is always worth a line")
    func outcomeChangeEmits() {
        #expect(SubtitleDeliveryStatement.shouldEmit(outcome: .undecodable, last: .published,
                                                     isReset: false))
    }

    @Test("a reset tick states its outcome even when the class did not change")
    func resetAlwaysEmits() {
        // The post-seek window is the one every report is about; it may not be inferred from the
        // absence of a line.
        #expect(SubtitleDeliveryStatement.shouldEmit(outcome: .published, last: .published,
                                                     isReset: true))
    }

    @Test("the first tick of a channel emits whatever it did")
    func firstTickEmits() {
        #expect(SubtitleDeliveryStatement.shouldEmit(outcome: .empty, last: nil, isReset: false))
    }

    // MARK: - The line itself

    @Test("the line carries every count the outcome was derived from")
    func formatCarriesTheCounts() {
        let statement = SubtitleDeliveryStatement.Statement(
            fence: .init(loadGeneration: 3, seekGeneration: 7),
            streamIndex: 3,
            playhead: 2756.55,
            tally: tally(packets: 12, events: 0, cues: 0))
        let line = SubtitleDeliveryStatement.format(statement)
        #expect(line.contains("#357 subtitle-delivery"))
        #expect(line.contains("loadGen=3"))
        #expect(line.contains("seekGen=7"))
        #expect(line.contains("stream=3"))
        #expect(line.contains("playhead=2756.55"))
        #expect(line.contains("packets=12"))
        #expect(line.contains("events=0"))
        #expect(line.contains("cues=0"))
        #expect(line.contains("published=0"))
        #expect(line.contains("outcome=undecodable"))
    }

    @Test("held cues are printed, since held is the outcome no other surface reports")
    func formatPrintsHeld() {
        let statement = SubtitleDeliveryStatement.Statement(
            fence: .init(loadGeneration: 1, seekGeneration: 1),
            streamIndex: 3,
            playhead: 100,
            tally: tally(packets: 4, events: 4, cues: 4, admitted: 1, published: 1,
                         reconstructing: true))
        let line = SubtitleDeliveryStatement.format(statement)
        #expect(line.contains("held=3"))
        #expect(line.contains("recon=1"))
    }

    @Test("a channel whose decoder cannot be built reads as noDecoder, ahead of every other class")
    func noDecoderWins() {
        var tally = tally(packets: 40)
        tally.decoderMissing = true
        #expect(tally.outcome == .noDecoder)
    }

    // MARK: - Wiring

    @MainActor
    @Test("a drain tick states its outcome on the engine, not only in a value type")
    func drainTickRecordsItsOutcome() throws {
        // No native session and no software host, so no overlay decoder can be built. Before #357
        // the tick skipped such a channel without a word, which is the same silence a starved
        // delivery produces.
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.softwareSubtitlePacketStore = SubtitlePacketStore()
        engine.subtitleDrainTargets[.primary] = 5
        engine.clock.sourceTime = 120

        #expect(engine.subtitleDeliveryLastOutcome[.primary] == nil)
        engine.subtitleDrainTick()
        #expect(engine.subtitleDeliveryLastOutcome[.primary] == .noDecoder)
    }

    @MainActor
    @Test("clearing a drain target forgets the channel's outcome, so the next selection starts fresh")
    func clearingTheTargetForgetsTheOutcome() throws {
        let engine = try AetherEngine()
        engine.loadedURL = URL(string: "https://s/movie.mkv")!
        engine.softwareSubtitlePacketStore = SubtitlePacketStore()
        engine.subtitleDrainTargets[.primary] = 5
        engine.clock.sourceTime = 120
        engine.subtitleDrainTick()

        engine.clearSubtitleDrainTarget(channel: .primary)
        #expect(engine.subtitleDeliveryLastOutcome[.primary] == nil)
    }

    // MARK: - Per-cue diagnostic budget

    @Test("the per-cue budget refills on a new seek generation instead of dying with the load")
    func budgetRefillsPerSeekGeneration() {
        // The old budget was per load, so a session went blind after 20 events and every later seek
        // landed unobserved. A seek sequence is precisely what the reports are about.
        var budget = SubtitleDeliveryStatement.EventBudget(limit: 2)
        let first = budget.claim(generation: 4)
        let second = budget.claim(generation: 4)
        let exhausted = budget.claim(generation: 4)
        let afterSeek = budget.claim(generation: 5)
        #expect(first)
        #expect(second)
        #expect(exhausted == false)
        #expect(afterSeek)
    }

    @Test("the budget bounds one generation, so a dense track cannot flood the log")
    func budgetBoundsOneGeneration() {
        var budget = SubtitleDeliveryStatement.EventBudget(limit: 3)
        var granted = 0
        for _ in 0..<10 where budget.claim(generation: 1) { granted += 1 }
        #expect(granted == 3)
    }
}
