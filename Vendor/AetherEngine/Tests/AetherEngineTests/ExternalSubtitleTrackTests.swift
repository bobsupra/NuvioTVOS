import Testing
import Foundation
@testable import AetherEngine

/// AetherEngine#88: external subtitle files register as first-class tracks. The descriptor is the
/// host-facing registration input; codec derivation feeds TrackInfo.codec (libavcodec decoder names,
/// matching embedded tracks so host codec checks keep working).
struct ExternalSubtitleTrackTests {

    @Test("codec derives from the file extension")
    func codecFromExtension() {
        #expect(ExternalSubtitleTrack.codecName(url: URL(string: "https://s/x.srt")!, formatHint: nil) == "subrip")
        #expect(ExternalSubtitleTrack.codecName(url: URL(string: "https://s/x.ass")!, formatHint: nil) == "ass")
        #expect(ExternalSubtitleTrack.codecName(url: URL(string: "https://s/x.ssa")!, formatHint: nil) == "ass")
        #expect(ExternalSubtitleTrack.codecName(url: URL(string: "https://s/x.vtt")!, formatHint: nil) == "webvtt")
    }

    @Test("formatHint beats the extension; unknown falls back to subrip")
    func codecFromHint() {
        #expect(ExternalSubtitleTrack.codecName(url: URL(string: "https://s/x?format=json")!, formatHint: "ass") == "ass")
        #expect(ExternalSubtitleTrack.codecName(url: URL(string: "https://s/Subtitles/3/0/Stream.srt")!, formatHint: "srt") == "subrip")
        #expect(ExternalSubtitleTrack.codecName(url: URL(string: "https://s/x.xyz")!, formatHint: nil) == "subrip")
    }

    @Test("TrackInfo carries the synthetic id, isExternal, and descriptor metadata")
    func trackInfoFactory() {
        let track = ExternalSubtitleTrack(
            url: URL(string: "https://s/de.srt")!, name: "German (SDH)", language: "de",
            isHearingImpaired: true)
        let info = track.makeTrackInfo(id: 100_000, fallbackNumber: 1)
        #expect(info.id == 100_000)
        #expect(info.isExternal)
        #expect(info.name == "German (SDH)")
        #expect(info.language == "de")
        #expect(info.isHearingImpaired)
        #expect(!info.isForced)
        #expect(info.codec == "subrip")
    }

    @Test("TrackInfo name falls back to localized language, then External <n>")
    func trackInfoNameFallback() {
        let langOnly = ExternalSubtitleTrack(url: URL(string: "https://s/x.srt")!, language: "de")
        // Locale-dependent human name; assert it resolved to SOMETHING non-generic.
        #expect(langOnly.makeTrackInfo(id: 100_001, fallbackNumber: 2).name != "External 2")
        let bare = ExternalSubtitleTrack(url: URL(string: "https://s/x.srt")!)
        #expect(bare.makeTrackInfo(id: 100_002, fallbackNumber: 3).name == "External 3")
    }
}
