import Testing
@testable import AetherEngine

struct ClosedCaptionRenditionTests {

    private func cue(_ id: Int, _ start: Double, _ end: Double, _ text: String) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(text))
    }

    @Test("A CC tap snapshot fills a native store and yields a WebVTT body with the cues")
    func snapshotFillsStoreAndBuildsVTT() {
        let store = NativeSubtitleCueStore()
        // Two publishes: the second extends cue 0's end (roll-up finalization). replaceCues (not
        // append) is what the CC tap fill uses, so the extended end replaces, not duplicates.
        store.replaceCues([cue(0, 1.0, 3.0, "HELLO"), cue(1, 4.0, 6.0, "WORLD")])
        store.replaceCues([cue(0, 1.0, 5.0, "HELLO"), cue(1, 4.0, 6.0, "WORLD")])
        let snap = store.snapshotCues()
        #expect(snap.count == 2)
        #expect(snap.contains { $0.startTime == 1.0 && $0.endTime == 5.0 && $0.text == "HELLO" })
        let vtt = WebVTTBuilder.body(cues: store.allCues())
        #expect(vtt.hasPrefix("WEBVTT"))
        #expect(vtt.contains("HELLO"))
        #expect(vtt.contains("WORLD"))
    }
}
