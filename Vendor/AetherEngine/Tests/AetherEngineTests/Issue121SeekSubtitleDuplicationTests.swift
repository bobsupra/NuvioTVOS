import Foundation
import CoreGraphics
import Testing
@testable import AetherEngine

/// #121: rapid forward-then-backward seeking duplicated embedded SRT cues in the retained store.
///
/// On a seek the overlay drainer rebuilds the `EmbeddedSubtitleDecoder` (`.resetAndDecode`), which
/// restarts the decoder-local dedupe set (`seenKeys`) and cue-id counter (`nextCueID`) at zero. The
/// backscan then re-decodes cues that are still retained in `subtitleCues`, and the old insert always
/// appended text cues, so identical lines accumulated (4 -> 7 -> 11 in the report) and the fresh
/// decoder's reset ids collided with retained ids (`ForEach(id:)` "occurs multiple times").
///
/// The session-wide invariants belong at the retained-store insert funnel, not the ephemeral decoder:
/// `insertCueSorted(_:into:nextID:)` de-dupes a text cue already present with the same window+content
/// and stamps every materialized cue with a session-monotonic id.
struct Issue121SeekSubtitleDuplicationTests {

    private func textCue(id: Int, start: Double, end: Double, _ s: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(s))
    }
    private func img() -> SubtitleCue.Body {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return .image(SubtitleImage(cgImage: ctx.makeImage()!, position: .zero))
    }

    /// The exact report trace: 4 cues, seek re-decodes 3 of them with reset ids, then a backward seek
    /// re-decodes all 4. The retained count must stay at 4 rather than growing to 7 then 11.
    @Test("re-decoded retained text cues after a seek reset are not duplicated")
    func repdroCountStaysStable() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        // First forward decode near the playhead (fresh decoder ids 0...3).
        for c in [textCue(id: 0, start: 4637.174, end: 4638.926, "Ils n'arretent pas le combat ?"),
                  textCue(id: 1, start: 4639.093, end: 4640.302, "Les plans dans les plans."),
                  textCue(id: 2, start: 4645.891, end: 4647.268, "Montre-moi qui tu es."),
                  textCue(id: 3, start: 4664.451, end: 4665.870, "Le voila !")] {
            AetherEngine.insertCueSorted(c, into: &cues, nextID: &nextID)
        }
        #expect(cues.count == 4)

        // Forward seek -> decoder rebuilt -> backscan re-emits the same lines with RESET ids 0,1,2.
        for c in [textCue(id: 0, start: 4639.093, end: 4640.302, "Les plans dans les plans."),
                  textCue(id: 1, start: 4645.891, end: 4647.268, "Montre-moi qui tu es."),
                  textCue(id: 2, start: 4664.451, end: 4665.870, "Le voila !")] {
            AetherEngine.insertCueSorted(c, into: &cues, nextID: &nextID)
        }
        #expect(cues.count == 4)

        // Backward seek -> another rebuild -> the whole retained window re-decodes with reset ids 0...3.
        for c in [textCue(id: 0, start: 4637.174, end: 4638.926, "Ils n'arretent pas le combat ?"),
                  textCue(id: 1, start: 4639.093, end: 4640.302, "Les plans dans les plans."),
                  textCue(id: 2, start: 4645.891, end: 4647.268, "Montre-moi qui tu es."),
                  textCue(id: 3, start: 4664.451, end: 4665.870, "Le voila !")] {
            AetherEngine.insertCueSorted(c, into: &cues, nextID: &nextID)
        }
        #expect(cues.count == 4)
    }

    /// Even when a seek lands in genuinely fresh territory (no content overlap to de-dupe), the
    /// reset decoder ids must not collide with retained cues: every id in the store stays unique.
    @Test("session ids stay unique across a decoder reset into fresh cues")
    func sessionIDsUniqueAcrossReset() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        for c in [textCue(id: 0, start: 100, end: 101, "a"),
                  textCue(id: 1, start: 102, end: 103, "b"),
                  textCue(id: 2, start: 104, end: 105, "c"),
                  textCue(id: 3, start: 106, end: 107, "d")] {
            AetherEngine.insertCueSorted(c, into: &cues, nextID: &nextID)
        }
        // Fresh region: different content, but decoder ids reset to 0,1,2.
        for c in [textCue(id: 0, start: 200, end: 201, "e"),
                  textCue(id: 1, start: 202, end: 203, "f"),
                  textCue(id: 2, start: 204, end: 205, "g")] {
            AetherEngine.insertCueSorted(c, into: &cues, nextID: &nextID)
        }
        let ids = cues.map(\.id)
        #expect(cues.count == 7)
        #expect(Set(ids).count == ids.count)
    }

    /// Two simultaneous speaker lines share a start/end but differ in text; both must survive.
    @Test("distinct simultaneous speaker lines at the same window are both kept")
    func distinctSimultaneousTextKept() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        AetherEngine.insertCueSorted(textCue(id: 0, start: 100, end: 110, "left"), into: &cues, nextID: &nextID)
        AetherEngine.insertCueSorted(textCue(id: 1, start: 100, end: 110, "right"), into: &cues, nextID: &nextID)
        #expect(cues.count == 2)
    }

    /// A cue re-appearing at a NEW time (not a re-decode of the retained window) is a real new line
    /// and must be inserted, not swallowed by content matching.
    @Test("the same text at a different window is a new cue, not a duplicate")
    func sameTextNewWindowInserted() {
        var cues: [SubtitleCue] = []
        var nextID = 0
        AetherEngine.insertCueSorted(textCue(id: 0, start: 100, end: 101, "..."), into: &cues, nextID: &nextID)
        AetherEngine.insertCueSorted(textCue(id: 1, start: 200, end: 201, "..."), into: &cues, nextID: &nextID)
        #expect(cues.count == 2)
    }

    /// The image same-start replace (issue #112) still holds through the nextID overload.
    @Test("a same-start image cue still replaces rather than duplicating")
    func sameStartImageStillReplaces() {
        var cues: [SubtitleCue] = [SubtitleCue(id: 1, startTime: 100, endTime: 4_296_178, body: img())]
        var nextID = 5
        AetherEngine.insertCueSorted(SubtitleCue(id: 2, startTime: 100, endTime: 118, body: img()),
                                     into: &cues, nextID: &nextID)
        #expect(cues.count == 1)
        #expect(cues[0].endTime == 118)
    }
}
