import Testing
import Foundation
@testable import AetherEngine

/// Issue #73: at the end of a successful load the engine activates the first subtitle track whose
/// language matches an ordered preference, so a host honors a saved subtitle-language preference from
/// one open instead of language-matching `subtitleTracks` itself. Unlike audio there is no explicit
/// index override and no default fallback: no match means "keep subtitles off". These cover the pure
/// resolution in isolation.
struct SubtitleLanguageSelectionTests {

    private func track(_ id: Int, _ lang: String?, codec: String = "subrip",
                       forced: Bool = false, sdh: Bool = false, commentary: Bool = false) -> TrackInfo {
        TrackInfo(id: id, name: "s\(id)", codec: codec, language: lang, channels: 0,
                  isDefault: false, isForced: forced, isHearingImpaired: sdh, isCommentary: commentary)
    }

    @Test("first matching preference selects its track")
    func firstMatch() {
        let tracks = [track(0, "en"), track(1, "de")]
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["de"]) == 1)
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["en"]) == 0)
    }

    @Test("preference order beats track order")
    func preferenceOrder() {
        let tracks = [track(0, "fr"), track(1, "de"), track(2, "en")]
        // en is on a later track than de, but en is the earlier preference -> en wins.
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["en", "de"]) == 2)
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["de", "en"]) == 1)
    }

    @Test("no preference match selects nothing (subtitles stay off)")
    func noMatchIsNil() {
        let tracks = [track(0, "fr"), track(1, "es")]
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["en"]) == nil)
    }

    @Test("empty preferences select nothing (the default-off no-op)")
    func emptyPreferences() {
        let tracks = [track(0, "en"), track(1, "de")]
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: []) == nil)
    }

    @Test("a source with no subtitle tracks selects nothing")
    func noSubtitles() {
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: [], preferredLanguages: ["en"]) == nil)
    }

    @Test("preference matches a track tagged with a 3-letter code")
    func synonymTrack() {
        let tracks = [track(0, "jpn"), track(1, "eng")]
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["en"]) == 1)
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["ja"]) == 0)
    }

    @Test("an untagged subtitle track never matches")
    func untaggedNeverMatches() {
        let tracks = [track(0, nil), track(1, "")]
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["en"]) == nil)
    }

    @Test("within a language, a full track beats forced / SDH / commentary")
    func fullBeatsDescriptors() {
        // Full track is last, so this also proves rank beats container order within the matched language.
        let forced = [track(0, "en", forced: true), track(1, "en")]
        #expect(AetherEngine.selectSubtitleIndex(tracks: forced, preferredLanguages: ["en"]) == 1)
        let sdh = [track(0, "en", sdh: true), track(1, "en")]
        #expect(AetherEngine.selectSubtitleIndex(tracks: sdh, preferredLanguages: ["en"]) == 1)
        let commentary = [track(0, "en", commentary: true), track(1, "en")]
        #expect(AetherEngine.selectSubtitleIndex(tracks: commentary, preferredLanguages: ["en"]) == 1)
    }

    @Test("descriptor ranking is full > SDH > forced > commentary")
    func descriptorOrdering() {
        #expect(AetherEngine.subtitlePickRank(track(0, "en")) <
                AetherEngine.subtitlePickRank(track(1, "en", sdh: true)))
        #expect(AetherEngine.subtitlePickRank(track(0, "en", sdh: true)) <
                AetherEngine.subtitlePickRank(track(1, "en", forced: true)))
        #expect(AetherEngine.subtitlePickRank(track(0, "en", forced: true)) <
                AetherEngine.subtitlePickRank(track(1, "en", commentary: true)))
    }

    @Test("at equal descriptor rank, text beats bitmap")
    func textBeatsBitmap() {
        let tracks = [track(0, "en", codec: "hdmv_pgs_subtitle"), track(1, "en", codec: "subrip")]
        #expect(AetherEngine.selectSubtitleIndex(tracks: tracks, preferredLanguages: ["en"]) == 1)
        // But a full bitmap still beats a forced text track (descriptor dominates the codec tiebreaker).
        let mixed = [track(0, "en", codec: "subrip", forced: true), track(1, "en", codec: "hdmv_pgs_subtitle")]
        #expect(AetherEngine.selectSubtitleIndex(tracks: mixed, preferredLanguages: ["en"]) == 1)
    }

    @Test("preference order dominates rank")
    func preferenceOrderDominatesRank() {
        // en is only available forced; de is a full track. en is the earlier preference, so en wins
        // despite ranking lower, because preference order is the outer loop.
        let tracks = [track(0, "en", forced: true), track(1, "de")]
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["en", "de"]) == 0)
    }

    @Test("bitmap classification matches libavcodec DECODER names, not descriptor names")
    func bitmapCodecClassification() {
        // TrackInfo.codec carries the decoder name; these are what the demuxer actually emits.
        for c in ["pgssub", "dvdsub", "dvbsub", "xsub", "PGSSUB"] {
            #expect(AetherEngine.isBitmapSubtitleCodec(c), "\(c) should be bitmap")
        }
        // Descriptor-style names are tolerated defensively.
        for c in ["hdmv_pgs_subtitle", "dvb_subtitle", "dvd_subtitle"] {
            #expect(AetherEngine.isBitmapSubtitleCodec(c), "\(c) should be bitmap")
        }
        // Text codecs are never bitmap.
        for c in ["subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"] {
            #expect(!AetherEngine.isBitmapSubtitleCodec(c), "\(c) should not be bitmap")
        }
    }
}
