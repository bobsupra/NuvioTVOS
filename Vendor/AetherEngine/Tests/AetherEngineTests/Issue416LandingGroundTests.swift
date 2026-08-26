import CoreGraphics
import Testing
@testable import AetherEngine

/// #416: a PGS set decoded behind a seek landing claims to be the line still on screen there, and
/// that claim rests on the store holding nothing between it and the playhead. These tests cover the
/// ledger that says whether anyone READ that stretch, and the gate rule that refuses the claim when
/// nobody did.
struct Issue416LandingGroundTests {

    private func imageCue(id: Int, start: Double, end: Double = 4_296_178) -> SubtitleCue {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return SubtitleCue(
            id: id, startTime: start, endTime: end,
            body: .image(SubtitleImage(cgImage: context.makeImage()!, position: .zero))
        )
    }

    /// A reader working its way forwards, reporting as it goes. Notes land in steps rather than in
    /// one leap on purpose: that is what every reader here does, and a leap is what the ledger
    /// treats as a reposition nobody announced.
    private func read(_ coverage: inout SubtitleHarvestCoverage,
                      _ writer: SubtitlePacketStore.Writer,
                      from: Double, to: Double, step: Double = 0.5) {
        coverage.noteAnchor(writer, at: from)
        var position = from
        while position < to {
            position = min(to, position + step)
            coverage.noteProgress(writer, through: position)
        }
    }

    // MARK: - The ledger

    @Test("nothing noted is not the same as nothing read")
    func emptyLedgerClaimsNothing() {
        let coverage = SubtitleHarvestCoverage()
        #expect(coverage.isEmpty)
        // The store, not the ledger, decides what ignorance means; the ledger itself says no.
        #expect(!coverage.covers(from: 10, through: 20))
    }

    @Test("a run covers what it read and nothing beyond it")
    func runCoversItsOwnSpan() {
        var coverage = SubtitleHarvestCoverage()
        read(&coverage, .prefetch, from: 100, to: 187.4)
        #expect(coverage.covers(from: 120, through: 180))
        #expect(coverage.covers(from: 100, through: 187.4))
        #expect(!coverage.covers(from: 180, through: 190))
        #expect(!coverage.covers(from: 90, through: 120))
    }

    @Test("an empty or inverted span is covered by definition")
    func emptySpanIsCovered() {
        var coverage = SubtitleHarvestCoverage()
        read(&coverage, .pump, from: 10, to: 20)
        #expect(coverage.covers(from: 500, through: 500))
        #expect(coverage.covers(from: 500, through: 499))
    }

    @Test("the reporter's shape: two runs that met nowhere leave the stretch between them unread")
    func reAnchoredRunLeavesAHole() {
        var coverage = SubtitleHarvestCoverage()
        // The run that harvested the set at 184 and was re-aimed before it reached the clear at 190.
        read(&coverage, .prefetch, from: 100, to: 187.4)
        read(&coverage, .prefetch, from: 197, to: 260)
        // The pump, restarted on the boundary below the seek target: one anchor, then the drain
        // tick stating that playback is rendering at the landing.
        coverage.noteAnchor(.pump, at: 192)
        coverage.noteProgress(.pump, through: 197)

        #expect(!coverage.covers(from: 184, through: 197))   // the set's claim to the landing
        #expect(coverage.covers(from: 192, through: 197))    // a set the restarted pump read
        #expect(coverage.covers(from: 150, through: 187))
    }

    @Test("runs that meet at a seam read as one")
    func adjacentRunsMerge() {
        var coverage = SubtitleHarvestCoverage()
        read(&coverage, .prefetch, from: 100, to: 192.0)
        read(&coverage, .pump, from: 192.1, to: 200)
        #expect(coverage.covers(from: 180, through: 199))
    }

    @Test("a step no reader announced starts a new run rather than claiming the jump")
    func unannouncedJumpDoesNotClaimTheGround() {
        var coverage = SubtitleHarvestCoverage()
        read(&coverage, .pump, from: 100, to: 110)
        // A reposition nobody reported: the next note is 200 s further on.
        coverage.noteProgress(.pump, through: 310)
        #expect(!coverage.covers(from: 150, through: 200))
        #expect(coverage.covers(from: 100, through: 110))
    }

    @Test("a run is extended, not restarted, over the step from a fresh anchor to the landing")
    func anchorToLandingIsOneRun() {
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.pump, at: 192)
        coverage.noteProgress(.pump, through: 197)   // the first drain tick after the landing
        #expect(coverage.covers(from: 193, through: 197))
    }

    @Test("the pump's reach is stated from its anchor, however far the first note is")
    func reachIsNotAStep() {
        // A track selected an hour into a film: the drain's first note is an hour-long step over
        // ground the pump certainly read, and it has to count.
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.pump, at: 0)
        coverage.noteReach(.pump, through: 3600)
        #expect(coverage.covers(from: 3585, through: 3600))
    }

    @Test("reach still cannot reach below its own anchor")
    func reachStartsAtTheAnchor() {
        var coverage = SubtitleHarvestCoverage()
        coverage.noteAnchor(.pump, at: 192)
        coverage.noteReach(.pump, through: 260)
        #expect(!coverage.covers(from: 184, through: 197))
        #expect(coverage.covers(from: 192, through: 260))
    }

    // MARK: - The store

    @Test("a store nobody reports coverage to answers every span with yes")
    func storeFailsOpenWithoutNotes() {
        let store = SubtitlePacketStore()
        #expect(store.hasReadSpan(from: 100, through: 200))
    }

    @Test("a store that is told about its readers answers from the ledger")
    func storeAnswersFromTheLedger() {
        let store = SubtitlePacketStore()
        store.noteHarvestAnchor(.prefetch, at: 100)
        for position in stride(from: 100.5, through: 187.4, by: 0.5) {
            store.noteHarvestProgress(.prefetch, through: position)
        }
        store.noteHarvestAnchor(.pump, at: 192)
        store.noteHarvestReach(.pump, through: 197)
        #expect(!store.hasReadSpan(from: 184, through: 197))
        #expect(store.hasReadSpan(from: 193, through: 197))
        store.clear()
        #expect(store.hasReadSpan(from: 184, through: 197))   // a fresh session knows nothing again
    }

    // MARK: - The gate rule

    @Test("a set stranded over unread ground does not become the landing line")
    func unreadGroundRefusesTheCandidate() {
        let playhead = 197.0
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true

        // The set at 184, decoded from a packet an abandoned run left behind.
        #expect(gate.admit(cues: [imageCue(id: 1, start: 184)], isPGS: true,
                           playhead: playhead, groundIsRead: false).isEmpty)
        #expect(!gate.hasReconstructionCandidate)

        // The next authored set, 43 s ahead, still ends the pass and publishes itself.
        let out = gate.admit(cues: [imageCue(id: 2, start: 240)], isPGS: true,
                             playhead: playhead, groundIsRead: false)
        #expect(out.map(\.id) == [2])
        #expect(!gate.reconstructing)
    }

    @Test("the same set with its ground read is the landing line, as #143 requires")
    func readGroundKeepsTheCandidate() {
        let playhead = 197.0
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true

        #expect(gate.admit(cues: [imageCue(id: 1, start: 194)], isPGS: true,
                           playhead: playhead, groundIsRead: true).isEmpty)
        #expect(gate.hasReconstructionCandidate)

        let out = gate.admit(cues: [imageCue(id: 2, start: 240)], isPGS: true,
                             playhead: playhead, groundIsRead: true)
        #expect(out.map(\.id) == [2, 1])
        #expect(out.last?.endTime == 240)
    }

    @Test("a refused set cannot be finalized either")
    func refusedCandidateCannotFinalize() {
        let playhead = 197.0
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        _ = gate.admit(cues: [imageCue(id: 1, start: 184)], isPGS: true,
                       playhead: playhead, groundIsRead: false)
        #expect(!SubtitleOverlayDrainer.shouldFinalizeReconstruction(
            reconstructing: gate.reconstructing, hasCandidate: gate.hasReconstructionCandidate))
        #expect(gate.finalizeReconstruction(playhead: playhead).isEmpty)
    }

    @Test("a stale arrival over unread ground is not held for a successor to publish")
    func unreadGroundDropsTheStaleHold() {
        let playhead = 197.0
        var gate = PGSStaleArrivalGate()
        #expect(gate.admit(cues: [imageCue(id: 1, start: 184)], isPGS: true,
                           playhead: playhead, groundIsRead: false).isEmpty)
        #expect(!gate.hasHeld)
        #expect(gate.resolveHeld(trimAt: 240, playhead: playhead).isEmpty)
    }

    @Test("a stale arrival over read ground is held and resolves exactly as before")
    func readGroundKeepsTheStaleHold() {
        let playhead = 197.0
        var gate = PGSStaleArrivalGate()
        #expect(gate.admit(cues: [imageCue(id: 1, start: 184)], isPGS: true,
                           playhead: playhead, groundIsRead: true).isEmpty)
        #expect(gate.hasHeld)
        let resolved = gate.resolveHeld(trimAt: 240, playhead: playhead)
        #expect(resolved.map(\.id) == [1])
    }
}
