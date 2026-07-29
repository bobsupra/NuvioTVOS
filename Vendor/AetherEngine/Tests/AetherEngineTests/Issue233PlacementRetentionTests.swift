import Testing
import CoreGraphics
@testable import AetherEngine

/// #233 follow-up, reported by tresby: no cue reached the host with a `placement` on an embedded
/// track, while the same field survived fine on sidecars.
///
/// The decoders were right. Every reconstruction between them and `$subtitleCues` rebuilt the cue
/// through the memberwise initializer to change one field, and `placement` defaults to nil there
/// (deliberately, for source compatibility), so each of those call sites dropped it and still
/// compiled. `insertCueSorted` is the decisive one: it stamps the session-monotonic id on every
/// cue entering the retained store, so nothing on the embedded path could keep a placement. The
/// #107 text trim would then have dropped it a second time on every teletext page transition.
///
/// The split explains the reporter seeing WebVTT placement work and teletext placement not: a
/// sidecar's cues are published as decoded (`subtitleCues = result.cues`), a native rendition's go
/// into a store verbatim, and only the drained embedded path goes through the retained store.
///
/// These assert the invariant on the store operations rather than on any one format, since the
/// defect was never format-specific.
@Suite("#233: cue placement survives the retained store")
struct Issue233PlacementRetentionTests {

    private let top = SubtitleTextPlacement(alignment: 8, position: nil)
    private let anchored = SubtitleTextPlacement(alignment: 5, position: CGPoint(x: 0.25, y: 0.75))

    private func textCue(id: Int, start: Double, end: Double, _ text: String = "line",
                         placement: SubtitleTextPlacement?) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(text), placement: placement)
    }

    private func tinyImage() -> SubtitleImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return SubtitleImage(cgImage: ctx.makeImage()!, position: .zero)
    }

    // MARK: - The id stamp

    @Test("the id stamp keeps the placement it restamps")
    func insertKeepsPlacement() {
        var cues: [SubtitleCue] = []
        var nextID = 7
        AetherEngine.insertCueSorted(textCue(id: 0, start: 10, end: 12, placement: top),
                                     into: &cues, nextID: &nextID)
        #expect(cues.count == 1)
        #expect(cues[0].id == 7)
        #expect(cues[0].placement?.alignment == 8)
    }

    @Test("an anchor point survives the stamp intact")
    func insertKeepsAnchor() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        AetherEngine.insertCueSorted(textCue(id: 0, start: 10, end: 12, placement: anchored),
                                     into: &cues, nextID: &nextID)
        #expect(cues[0].placement?.position == CGPoint(x: 0.25, y: 0.75))
        #expect(cues[0].placement?.alignment == 5)
    }

    @Test("rich-text cues keep placement too (the teletext shape)")
    func insertKeepsPlacementOnRichText() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        let runs = [SubtitleTextRun(text: "CAPTION", color: SubtitleColor(r: 255, g: 255, b: 0))]
        AetherEngine.insertCueSorted(
            SubtitleCue(id: 0, startTime: 10, endTime: 12, body: .richText(runs), placement: top),
            into: &cues, nextID: &nextID)
        #expect(cues[0].placement?.alignment == 8)
    }

    @Test("a placementless cue still arrives placementless")
    func insertKeepsNil() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        AetherEngine.insertCueSorted(textCue(id: 0, start: 10, end: 12, placement: nil),
                                     into: &cues, nextID: &nextID)
        #expect(cues[0].placement == nil)
    }

    // MARK: - The #107 text trim

    @Test("closing a cue at a page transition keeps its placement")
    func trimKeepsPlacement() {
        var cues = [textCue(id: 0, start: 100, end: 100 + 4_294_967, placement: top)]
        AetherEngine.trimTextCues(&cues, at: 110)
        #expect(cues[0].endTime == 110)
        #expect(cues[0].placement?.alignment == 8)
    }

    // MARK: - Both, in the order the drain applies them

    @Test("a teletext page and its successor both keep their placement end to end")
    func drainOrderKeepsPlacement() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        let openEnded = 4_294_967.0
        AetherEngine.insertCueSorted(textCue(id: 0, start: 100, end: 100 + openEnded, "FIRST", placement: top),
                                     into: &cues, nextID: &nextID)
        AetherEngine.trimTextCues(&cues, at: 110)
        AetherEngine.insertCueSorted(textCue(id: 0, start: 110, end: 110 + openEnded, "SECOND",
                                             placement: SubtitleTextPlacement(alignment: 2, position: nil)),
                                     into: &cues, nextID: &nextID)
        #expect(cues.count == 2)
        #expect(cues[0].placement?.alignment == 8)
        #expect(cues[0].endTime == 110)
        #expect(cues[1].placement?.alignment == 2)
    }

    // MARK: - The other reconstructions

    @Test("the PGS trim keeps the fields it does not change")
    func pgsTrimKeepsBody() {
        // Image cues carry geometry on SubtitleImage rather than in placement, so this asserts the
        // shape rather than a live regression: the trim must not become a field-dropping rebuild.
        var cues = [SubtitleCue(id: 3, startTime: 100, endTime: 100 + 4_294_967, body: .image(tinyImage()))]
        AetherEngine.trimTextCues(&cues, at: 110)
        #expect(cues[0].endTime == 100 + 4_294_967)  // image cues are not the text trim's business
        #expect(cues[0].id == 3)
    }

    @Test("the OCR pending close keeps the fields it does not change")
    func ocrPendingCloseKeepsFields() {
        var state = SubtitleOCRPendingState()
        _ = state.consume(eventPts: 100,
                          cues: [SubtitleCue(id: 1, startTime: 100, endTime: 100 + 4_294_967,
                                             body: .image(tinyImage()))],
                          trimAt: nil)
        let closed = state.consume(eventPts: 110, cues: [], trimAt: nil)
        #expect(closed.count == 1)
        #expect(closed[0].endTime == 110)
        #expect(closed[0].id == 1)
    }
}
