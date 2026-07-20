import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// #112 (ijuniorfu): after an audio-track switch (and, on some sources, a fast-forward) the PGS overlay scrolled
/// through ~24 s of earlier subtitles while the playhead was frozen ("the subtitles keep changing while paused",
/// "content from before the current playback position"). Root cause: the reconstruction pass seeks a lead-in back
/// of the playhead and decodes forward, and the gate published EVERY self-contained composition (Acquisition
/// Point / Epoch Start) in that window the instant it decoded. A Blu-ray has several dialogue lines in 24 s, so
/// each one replaced the last on screen.
///
/// The fix holds the lead-in's compositions and emits only the single line active at the playhead, once the
/// decode reaches it. These tests lock that: no lead-in composition publishes until the playhead is reached, and
/// then only the newest one at/behind it does.
struct Issue112PGSReconstructionScrollTests {

    private func imageCue(id: Int, start: Double, end: Double = 4_296_178) -> SubtitleCue {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SubtitleCue(id: id, startTime: start, endTime: end,
                           body: .image(SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)))
    }

    @Test("during reconstruction a self-contained composition behind the playhead is held, not published")
    func leadInCompositionHeldNotPublished() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // Acquisition point composed 10 s before the seek target. Old code published it at once; now it is held as
        // the candidate active line until the decode reaches the playhead.
        let out = gate.admit(cues: [imageCue(id: 1, start: 90)], isPGS: true, isSelfContained: true, playhead: 100)
        #expect(out.isEmpty)
        #expect(gate.hasHeld)
    }

    @Test("the lead-in's compositions do not scroll: only the active line publishes when the decode reaches the playhead")
    func onlyActiveLinePublishesNoScroll() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        let p = 100.0
        // Four self-contained compositions decoded across the 24 s lead-in. On the old path all four rendered in
        // turn (the scroll). Each admit here must publish nothing.
        #expect(gate.admit(cues: [imageCue(id: 1, start: 78)], isPGS: true, isSelfContained: true, playhead: p).isEmpty)
        #expect(gate.admit(cues: [imageCue(id: 2, start: 85)], isPGS: true, isSelfContained: true, playhead: p).isEmpty)
        #expect(gate.admit(cues: [imageCue(id: 3, start: 92)], isPGS: true, isSelfContained: true, playhead: p).isEmpty)
        #expect(gate.admit(cues: [imageCue(id: 4, start: 98)], isPGS: true, isSelfContained: true, playhead: p).isEmpty)
        // The reader decodes past the playhead (next composition at 106). Only id 4 (newest <= playhead) is the
        // active line; ids 1-3 never publish. The ahead composition (5) is stored for when the playhead reaches it.
        let out = gate.admit(cues: [imageCue(id: 5, start: 106)], isPGS: true, isSelfContained: true, playhead: p)
        #expect(out.map(\.id).sorted() == [4, 5])
        #expect(gate.reconstructing == false)
        #expect(!gate.hasHeld)
    }

    @Test("a composition arriving at the playhead is itself the active line and exits reconstruction")
    func caughtUpCompositionAtPlayheadPublishes() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // The reader catches up with a live composition exactly at the playhead; it is the current line and passes.
        let out = gate.admit(cues: [imageCue(id: 1, start: 100)], isPGS: true, isSelfContained: false, playhead: 100)
        #expect(out.map(\.id) == [1])
        #expect(gate.reconstructing == false)
    }

    @Test("a line composed before the lead-in publishes when a later composition is reached, its window covering the playhead")
    func candidatePublishesOnAheadSuccessor() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        // Active line composed 8 s before the playhead (> stale epsilon), open-ended. Held as candidate.
        #expect(gate.admit(cues: [imageCue(id: 1, start: 92)], isPGS: true, isSelfContained: true, playhead: 100).isEmpty)
        // Its successor lands 20 s ahead; the candidate's window (92 -> open) covers the playhead, so it publishes.
        let out = gate.admit(cues: [imageCue(id: 2, start: 120)], isPGS: true, isSelfContained: true, playhead: 100)
        #expect(out.contains { $0.id == 1 })
        #expect(gate.reconstructing == false)
    }

    @Test("outside reconstruction a historical acquisition point is held (no #100 catch-up flash)")
    func historicalAcquisitionOutsideReconstructionHeld() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = false
        // A #100 catch-up backlog can contain an acquisition point 70 s behind the playhead; it is NOT the current
        // line and must not flash. The stale hold keeps #100 intact.
        let out = gate.admit(cues: [imageCue(id: 1, start: 30)], isPGS: true, isSelfContained: true, playhead: 100)
        #expect(out.isEmpty)
        #expect(gate.hasHeld)
    }

    @Test("a non-stale live composition passes through unchanged")
    func liveCompositionPassesThrough() {
        var gate = PGSStaleArrivalGate()
        let out = gate.admit(cues: [imageCue(id: 1, start: 99)], isPGS: true, isSelfContained: false, playhead: 100)
        #expect(out.map(\.id) == [1])
    }

    @Test("reset clears the reconstruction candidate")
    func resetClearsCandidate() {
        var gate = PGSStaleArrivalGate()
        gate.reconstructing = true
        _ = gate.admit(cues: [imageCue(id: 1, start: 90)], isPGS: true, isSelfContained: true, playhead: 100)
        #expect(gate.hasHeld)
        gate.reset()
        #expect(!gate.hasHeld)
        #expect(gate.reconstructing == false)
    }
}
