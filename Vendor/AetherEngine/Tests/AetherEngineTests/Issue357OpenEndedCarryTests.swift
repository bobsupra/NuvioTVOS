import Testing
import CoreGraphics
@testable import AetherEngine

/// #357 round 3: a cue that is still open when a seek jumps past it.
///
/// A PGS composition has no end of its own. The decoder stamps it with FFmpeg's
/// `end_display_time = UINT32_MAX` placeholder and the SUCCESSOR composition's `pgsTrimAt` closes
/// it. Both bounds fail across a jump: the successor arrives only when the new landing point's
/// first composition does, and `pruneCues` filters on `endTime`, which a placeholder end can never
/// age out of. The reported result was a cue authored at 2549.8 s reading as active at 2855.15 s
/// and rendering for 24.5 s until a real cue displaced it.
///
/// The numbers below are the report's, with the drain's own 15 s backscan as the reconstruction
/// window: `boundary = 2855.15 - 15`.
@Suite("#357: an open-ended cue cannot claim a post-seek landing")
struct Issue357OpenEndedCarryTests {

    private let placeholder = 4_294_967.295   // UINT32_MAX ms, as EmbeddedSubtitleDecoder stamps it
    private let landing = 2855.15
    private var boundary: Double { landing - 15 }

    private func textCue(id: Int, start: Double, end: Double) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text("line"))
    }

    private func imageCue(id: Int, start: Double, end: Double) -> SubtitleCue {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)
        return SubtitleCue(id: id, startTime: start, endTime: end, body: .image(image))
    }

    // MARK: - The reported case

    @Test("the pre-seek cue the report saw is closed at the reconstruction window and stops covering the landing")
    func reportedCarryIsClosed() {
        var cues = [imageCue(id: 0, start: 2549.8, end: 2549.8 + placeholder)]
        #expect(cues[0].endTime > landing)   // the state the host rendered from
        #expect(AetherEngine.closeOpenEndedCues(&cues, startingBefore: boundary))
        #expect(cues[0].endTime == boundary)
        #expect(cues[0].startTime == 2549.8)   // retained for a backward seek, only the end retires
        #expect(!(cues[0].startTime <= landing && landing < cues[0].endTime))
    }

    @Test("the retention prune cannot do this: a placeholder end never ages out of the window")
    func retentionCannotReachIt() {
        // Why the close exists at all. 300 s of retention, a 305 s jump, and the cue still stays.
        var cues = [imageCue(id: 0, start: 2549.8, end: 2549.8 + placeholder)]
        #expect(!AetherEngine.pruneCues(&cues, before: landing - 300))
        #expect(cues.count == 1)
    }

    // MARK: - What must survive it

    @Test("an authored duration is left alone, however long")
    func authoredDurationUntouched() {
        // A typeset sign can legitimately run for a minute. This is what separates the close from a
        // blanket "drop the pre-seek set": only an unconfirmable end is retired.
        var cues = [textCue(id: 0, start: boundary - 30, end: landing + 30)]
        #expect(!AetherEngine.closeOpenEndedCues(&cues, startingBefore: boundary))
        #expect(cues[0].endTime == landing + 30)
    }

    @Test("an open cue starting inside the reconstruction window is left open")
    func insideWindowUntouched() {
        // The backscan re-decodes from `boundary`, so this one is re-confirmed by the pass and may
        // well be the landing line. Closing it here would dark exactly the cue #143 exists to light.
        var cues = [imageCue(id: 0, start: boundary + 2, end: boundary + 2 + placeholder)]
        #expect(!AetherEngine.closeOpenEndedCues(&cues, startingBefore: boundary))
        #expect(cues[0].endTime == boundary + 2 + placeholder)
    }

    @Test("a cue already closed before the boundary is untouched and reports no change")
    func alreadyClosedUntouched() {
        // The tick publishes only when something changed (#271); a no-op must stay one.
        var cues = [textCue(id: 0, start: 2549.8, end: 2553.9)]
        #expect(!AetherEngine.closeOpenEndedCues(&cues, startingBefore: boundary))
        #expect(cues[0].endTime == 2553.9)
    }

    @Test("an empty store reports no change")
    func emptyStore() {
        var cues: [SubtitleCue] = []
        #expect(!AetherEngine.closeOpenEndedCues(&cues, startingBefore: boundary))
    }

    @Test("only the carried cue is closed, the rest of the window is untouched")
    func closesOnlyTheCarriedCue() {
        var cues = [
            imageCue(id: 0, start: 2549.8, end: 2549.8 + placeholder),   // pre-seek, open
            textCue(id: 1, start: 2600, end: 2604),                      // pre-seek, closed
            imageCue(id: 2, start: landing + 4, end: landing + 4 + placeholder),   // ahead, open
        ]
        #expect(AetherEngine.closeOpenEndedCues(&cues, startingBefore: boundary))
        #expect(cues[0].endTime == boundary)
        #expect(cues[1].endTime == 2604)
        #expect(cues[2].endTime == landing + 4 + placeholder)
    }

    // MARK: - The same defect through the gate

    @Test("a reset drops the stale hold, so the first post-seek trim cannot republish it")
    func resetDropsTheHold() {
        // The store is not the only place a pre-seek open cue waits. #100 holds a catch-up arrival
        // for its successor; the hold keeps the placeholder end, and `resolveHeld` publishes what
        // covers the playhead. Without the reset, the first post-seek composition (a successor
        // AHEAD of the new playhead) closes the held cue there and it publishes as the active line.
        var gate = PGSStaleArrivalGate()
        let held = [imageCue(id: 0, start: 2549.8, end: 2549.8 + placeholder)]
        #expect(gate.admit(cues: held, isPGS: true, playhead: 2560).isEmpty)   // held, not published
        #expect(gate.hasHeld)

        var carried = gate
        #expect(!carried.resolveHeld(trimAt: landing + 4, playhead: landing).isEmpty)   // the defect

        gate.reset()                    // what the reset tick now does
        gate.reconstructing = true
        #expect(!gate.hasHeld)
        #expect(gate.resolveHeld(trimAt: landing + 4, playhead: landing).isEmpty)
    }
}
