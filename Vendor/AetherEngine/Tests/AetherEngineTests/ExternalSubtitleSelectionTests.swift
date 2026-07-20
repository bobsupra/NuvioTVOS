import Testing
import Foundation
@testable import AetherEngine

/// AetherEngine#88: selecting an external id through the unified selectSubtitleTrack routes onto
/// the sidecar decode path and publishes the external id as the active track (the old sidecar API
/// nilled it, so hosts could not highlight an external selection).
@MainActor
struct ExternalSubtitleSelectionTests {

    private func makeTrack(_ name: String = "x") -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(url: URL(string: "https://s/\(name).srt")!, name: name, language: "de")
    }

    @Test("selecting an external id activates it and publishes activeSubtitleTrackIndex")
    func selectExternal() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(makeTrack())
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.isSubtitleActive)
        #expect(engine.activeSubtitleTrackIndex == info.id)
        #expect(engine.activeEmbeddedSubtitleStreamIndex == -1)
    }

    @Test("external selection works without a loaded URL (no loadedURL guard on the external path)")
    func selectExternalWithoutLoad() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(makeTrack())
        #expect(engine.loadedURL == nil)
        engine.selectSubtitleTrack(index: info.id)
        #expect(engine.isSubtitleActive)
    }

    @Test("unknown external-range id no-ops")
    func unknownIDNoop() throws {
        let engine = try AetherEngine()
        engine.selectSubtitleTrack(index: AetherEngine.externalSubtitleTrackIDBase + 7)
        #expect(!engine.isSubtitleActive)
    }

    @Test("secondary channel routes external ids")
    func secondaryExternal() throws {
        let engine = try AetherEngine()
        let info = engine.addExternalSubtitleTrack(makeTrack())
        engine.selectSecondarySubtitleTrack(index: info.id)
        #expect(engine.isSecondarySubtitleActive)
        #expect(engine.activeSecondaryExternalSubtitleTrackID == info.id)
        #expect(engine.activeSecondaryEmbeddedSubtitleStreamIndex == -1)
    }

    @Test("explicit clear latches hostExplicitSubtitleAction; a late add does not re-enable")
    func lateAddGate() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preferredSubtitleLanguages: ["de"]))
        engine.clearSubtitle()
        #expect(engine.hostExplicitSubtitleAction)
        _ = engine.addExternalSubtitleTrack(makeTrack())
        #expect(!engine.isSubtitleActive)
    }

    @Test("without an explicit action, a late add matching the preference auto-selects")
    func lateAddAutoSelect() throws {
        let engine = try AetherEngine()
        engine.setLoadedOptionsForTesting(LoadOptions(preferredSubtitleLanguages: ["de"]))
        let info = engine.addExternalSubtitleTrack(makeTrack())
        #expect(engine.activeSubtitleTrackIndex == info.id)
        #expect(engine.isSubtitleActive)
    }
}
