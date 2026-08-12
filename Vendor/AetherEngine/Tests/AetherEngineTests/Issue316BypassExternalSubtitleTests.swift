import Testing
import Foundation
@testable import AetherEngine

/// #316: `LoadOptions.externalSubtitles` used to be dropped on the nativeRemoteHLS bypass. The branch
/// returns from `load()` well before the probe path's registration step, so a host that declared
/// sidecars at load time got an empty `subtitleTracks` back, with no error and no log line. The only
/// remaining route was `addExternalSubtitleTrack`, which is overlay-only by contract.
@Suite("nativeRemoteHLS bypass keeps declared external subtitles (#316)")
@MainActor
struct Issue316BypassExternalSubtitleTests {

    private static func sidecar(_ name: String, _ lang: String) -> ExternalSubtitleTrack {
        ExternalSubtitleTrack(url: URL(string: "https://origin.test/\(lang).srt")!,
                              name: name, language: lang)
    }

    /// Dead-end URL: the bypass wires its host synchronously and never awaits readiness, so the
    /// registration is observable without a reachable origin (same trick as the #120 attach tests).
    private static let deadEndURL = URL(string: "http://127.0.0.1:9/vod.m3u8")!

    @Test("A load-time declaration is registered on the bypass")
    func bypassRegistersDeclaredTracks() async throws {
        let engine = try AetherEngine()
        _ = try await engine.load(
            url: Self.deadEndURL,
            options: LoadOptions(nativeRemoteHLS: true,
                                 externalSubtitles: [Self.sidecar("English", "en"),
                                                     Self.sidecar("Deutsch", "de")]))

        #expect(engine.subtitleTracks.map(\.name) == ["English", "Deutsch"])
        #expect(engine.subtitleTracks.allSatisfy { $0.isExternal })
        #expect(engine.externalSubtitleRegistry.count == 2)
        #expect(engine.subtitleTracks.map(\.id)
                == [AetherEngine.externalSubtitleTrackIDBase,
                    AetherEngine.externalSubtitleTrackIDBase + 1])
    }

    @Test("An empty declaration leaves the bypass exactly as it was")
    func bypassWithoutDeclarationStaysEmpty() async throws {
        let engine = try AetherEngine()
        _ = try await engine.load(url: Self.deadEndURL, options: LoadOptions(nativeRemoteHLS: true))
        #expect(engine.subtitleTracks.isEmpty)
        #expect(engine.externalSubtitleRegistry.isEmpty)
    }

    /// The AE#154 discovery assigned the legible list wholesale, so a bypass source carrying its own
    /// renditions delisted the host's sidecars again a beat after they were registered.
    @Test("Surfacing the legible group keeps the external tracks and appends the renditions")
    func legibleSurfacingMergesInsteadOfReplacing() {
        let declared = [
            Self.sidecar("English", "en").makeTrackInfo(id: AetherEngine.externalSubtitleTrackIDBase,
                                                        fallbackNumber: 1)
        ]
        let legible = [
            RemoteHLSMediaSelection.LegibleOption(displayName: "Français", extendedLanguageTag: "fr",
                                                  isDefault: false, isForced: false, isSDH: false)
        ]

        let merged = RemoteHLSMediaSelection.mergedSubtitleTracks(existing: declared, legible: legible)

        #expect(merged.map(\.name) == ["English", "Français"])
        #expect(merged.map(\.id) == [AetherEngine.externalSubtitleTrackIDBase,
                                     RemoteHLSMediaSelection.subtitleTrackIDBase])
        #expect(merged.map(\.isExternal) == [true, false])
    }

    /// With a proxy standing, the sidecar is AVPlayer's to draw. Starting the overlay decode as well
    /// would render the same cues twice, and only the rendition survives PiP / AirPlay.
    @Test("Selecting a proxied sidecar drives media selection, not the overlay decode")
    func selectingAnInjectedTrackSkipsTheSidecarDecode() async throws {
        let engine = try AetherEngine()
        _ = try await engine.load(
            url: Self.deadEndURL,
            options: LoadOptions(nativeRemoteHLS: true, externalSubtitles: [Self.sidecar("English", "en")]))
        let id = AetherEngine.externalSubtitleTrackIDBase
        engine.injectedSubtitleRenditionNames = [id: "English"]

        engine.selectSubtitleTrack(index: id)

        #expect(engine.activeSubtitleTrackIndex == id)
        #expect(engine.isSubtitleActive)
        #expect(engine.loadedSidecarURL == nil, "the overlay decode must not have started")
        #expect(!engine.isLoadingSubtitles)
    }

    /// Contrast: without a proxy the same track is the overlay's, exactly as #88 has always had it.
    @Test("Without a proxy the same selection still takes the sidecar path")
    func selectingWithoutProxyUsesTheSidecar() async throws {
        let engine = try AetherEngine()
        _ = try await engine.load(
            url: Self.deadEndURL,
            options: LoadOptions(nativeRemoteHLS: true, externalSubtitles: [Self.sidecar("English", "en")]))

        engine.selectSubtitleTrack(index: AetherEngine.externalSubtitleTrackIDBase)

        #expect(engine.loadedSidecarURL?.lastPathComponent == "en.srt")
        #expect(engine.isLoadingSubtitles)
    }

    /// A second surfacing (the readiness retry) must not stack duplicate renditions.
    @Test("Re-surfacing replaces the previous renditions instead of appending to them")
    func resurfacingReplacesRenditions() {
        let legible = [
            RemoteHLSMediaSelection.LegibleOption(displayName: "Français", extendedLanguageTag: "fr",
                                                  isDefault: false, isForced: false, isSDH: false)
        ]
        let first = RemoteHLSMediaSelection.mergedSubtitleTracks(existing: [], legible: legible)
        let second = RemoteHLSMediaSelection.mergedSubtitleTracks(existing: first, legible: legible)
        #expect(second.count == 1)
    }
}
