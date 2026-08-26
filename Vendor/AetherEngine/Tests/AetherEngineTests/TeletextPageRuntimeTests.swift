import Testing
@testable import AetherEngine

/// #364: the teletext page as a live setting. The page reaches a decoder only at construction, so a
/// mid-session change is a decoder rebuild, and the interesting question is which channels it may
/// touch: rebuilding a channel that is not showing teletext would drop its cues for nothing.
@MainActor
struct TeletextPageRuntimeTests {

    private func track(id: Int, codec: String) -> TrackInfo {
        TrackInfo(id: id, name: "Track \(id)", codec: codec, language: "de", isDefault: false)
    }

    private func cursor(at pts: Double) -> SubtitleDrainCursor {
        SubtitleDrainCursor(lastDecodedPts: pts, lastPlayhead: pts)
    }

    @Test("both spellings of the teletext codec are recognised")
    func codecClassifier() {
        // The decoder name when FFmpeg carries libzvbi, the descriptor name when it does not.
        #expect(AetherEngine.isTeletextSubtitleCodec("libzvbi_teletextdec"))
        #expect(AetherEngine.isTeletextSubtitleCodec("dvb_teletext"))
        #expect(AetherEngine.isTeletextSubtitleCodec("DVB_TELETEXT"))
    }

    @Test("no other subtitle codec is taken for teletext")
    func codecClassifierNegatives() {
        for codec in ["subrip", "ass", "mov_text", "pgssub", "dvbsub", "dvdsub", "eia_608", "webvtt"] {
            #expect(AetherEngine.isTeletextSubtitleCodec(codec) == false, "\(codec) is not teletext")
        }
    }

    @Test("the page lands in the load options, so an internal reopen replays it")
    func pageSurvivesReopen() throws {
        let engine = try AetherEngine()
        #expect(engine.teletextPage == nil)
        engine.setTeletextPage(150)
        #expect(engine.teletextPage == 150)
        #expect(engine.loadedOptions.teletextPage == 150)
        engine.setTeletextPage(nil)   // back to libzvbi auto-detect
        #expect(engine.teletextPage == nil)
    }

    @Test("a teletext channel loses its decoder and cursor, so the next tick re-decodes the window")
    func teletextChannelIsRebuilt() throws {
        let engine = try AetherEngine()
        engine.subtitleTracks = [track(id: 3, codec: "libzvbi_teletextdec")]
        engine.subtitleDrainTargets[.primary] = 3
        engine.subtitleDrainCursors[.primary] = cursor(at: 120)
        engine.subtitleCues = [SubtitleCue(id: 1, startTime: 119, endTime: 122, body: .text("page 888"))]

        engine.setTeletextPage(150)

        #expect(engine.subtitleDrainCursors[.primary] == nil)
        #expect(engine.subtitleCues.isEmpty)
    }

    @Test("a channel showing another codec keeps its cursor and its cues")
    func otherCodecIsLeftAlone() throws {
        let engine = try AetherEngine()
        engine.subtitleTracks = [track(id: 4, codec: "pgssub")]
        engine.subtitleDrainTargets[.primary] = 4
        engine.subtitleDrainCursors[.primary] = cursor(at: 120)
        engine.subtitleCues = [SubtitleCue(id: 1, startTime: 119, endTime: 122, body: .text("still here"))]

        engine.setTeletextPage(150)

        #expect(engine.subtitleDrainCursors[.primary]?.lastDecodedPts == 120)
        #expect(engine.subtitleCues.count == 1)
    }

    @Test("with both channels active, only the teletext one is re-decoded")
    func onlyTheTeletextChannel() throws {
        let engine = try AetherEngine()
        engine.subtitleTracks = [track(id: 3, codec: "dvb_teletext"), track(id: 4, codec: "subrip")]
        engine.subtitleDrainTargets[.primary] = 3
        engine.subtitleDrainTargets[.secondary] = 4
        engine.subtitleDrainCursors[.primary] = cursor(at: 90)
        engine.subtitleDrainCursors[.secondary] = cursor(at: 90)
        engine.secondarySubtitleCues = [SubtitleCue(id: 7, startTime: 89, endTime: 92, body: .text("companion line"))]

        engine.setTeletextPage(801)

        #expect(engine.subtitleDrainCursors[.primary] == nil)
        #expect(engine.subtitleDrainCursors[.secondary]?.lastDecodedPts == 90)
        #expect(engine.secondarySubtitleCues.count == 1)
    }

    @Test("setting the page already in force changes nothing")
    func idempotent() throws {
        let engine = try AetherEngine()
        engine.setTeletextPage(150)
        engine.subtitleTracks = [track(id: 3, codec: "dvb_teletext")]
        engine.subtitleDrainTargets[.primary] = 3
        engine.subtitleDrainCursors[.primary] = cursor(at: 60)

        engine.setTeletextPage(150)

        // No rebuild: the decoder in place already decodes this page, and dropping the window would
        // blank the overlay for a change that is not one.
        #expect(engine.subtitleDrainCursors[.primary]?.lastDecodedPts == 60)
    }
}
