import Testing
import Foundation
@testable import AetherEngine

/// AetherEngine#88: load-declared external tracks join the native rendition table (externalID set,
/// sourceStreamIndex nil) and the PiP ordinal mapping resolves them. A finished store (whole-file
/// decode at load) backfills the overlay instantly on select instead of re-downloading.
@MainActor
struct ExternalNativeSubtitleTests {

    @Test("PiP ordinal maps embedded actives via sourceStreamIndex")
    func ordinalEmbedded() {
        let table = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 2, language: "en"),
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 4, language: "de"),
        ]
        #expect(AetherEngine.nativeSubtitleOrdinal(forActiveTrack: 4, in: table) == 1)
    }

    @Test("PiP ordinal maps external actives via externalID")
    func ordinalExternal() {
        let table = [
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: 2, language: "en"),
            AetherEngine.NativeSubtitleTrackEntry(sourceStreamIndex: nil, externalID: 100_000, language: "de"),
        ]
        #expect(AetherEngine.nativeSubtitleOrdinal(forActiveTrack: 100_000, in: table) == 1)
        #expect(AetherEngine.nativeSubtitleOrdinal(forActiveTrack: 100_001, in: table) == nil)
    }

    @Test("finished external store backfills the overlay instantly on select")
    func instantBackfill() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(string: "https://s/x.srt")!, language: "de"))
        let store = NativeSubtitleCueStore()
        store.appendCues([SubtitleCue(id: 1, startTime: 1, endTime: 2, body: .text("hi"))])
        store.markFinished()
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: nil, externalID: info.id, language: "de")
        ]
        engine.testHookInstallNativeStores([store])
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.subtitleCues.count == 1)
        #expect(!engine.isLoadingSubtitles)
        #expect(engine.activeSubtitleTrackIndex == info.id)
    }

    @Test("an unfinished store does not short-circuit; the sidecar decode runs")
    func unfinishedStoreDecodes() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(string: "https://s/x.srt")!, language: "de"))
        let store = NativeSubtitleCueStore()
        store.appendCues([SubtitleCue(id: 1, startTime: 1, endTime: 2, body: .text("hi"))])
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: nil, externalID: info.id, language: "de")
        ]
        engine.testHookInstallNativeStores([store])
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.subtitleCues.isEmpty)
        #expect(engine.isLoadingSubtitles)
    }

    @Test("styled-ASS preference skips the plain-text store backfill")
    func assSkipsBackfill() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preserveASSMarkup: true))
        let info = engine.addExternalSubtitleTrack(
            ExternalSubtitleTrack(url: URL(string: "https://s/x.ass")!, language: "de"))
        let store = NativeSubtitleCueStore()
        store.appendCues([SubtitleCue(id: 1, startTime: 1, endTime: 2, body: .text("hi"))])
        store.markFinished()
        engine.nativeSubtitleTrackTable = [
            .init(sourceStreamIndex: nil, externalID: info.id, language: "de")
        ]
        engine.testHookInstallNativeStores([store])
        engine.selectSubtitleTrack(index: info.id)
        // Falls through to the sidecar decode (async, fake URL): loading spinner on, no store cues.
        #expect(engine.subtitleCues.isEmpty)
        #expect(engine.isLoadingSubtitles)
    }
}
