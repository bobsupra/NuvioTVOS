import Testing
import Foundation
@testable import AetherEngine

/// Issue #72: the engine resolves the first-frame audio track from its single internal probe,
/// honoring an ordered language preference, so a host avoids a separate audio pre-probe or a
/// post-load `selectAudioTrack` reload. These cover the pure resolution in isolation.
struct AudioLanguageSelectionTests {

    private func track(_ id: Int, _ lang: String?, isDefault: Bool = false) -> TrackInfo {
        TrackInfo(id: id, name: "a\(id)", codec: "aac", language: lang, channels: 2, isDefault: isDefault)
    }

    @Test("language matching is case-insensitive across ISO 639-1/2 and English names")
    func matches() {
        #expect(AetherEngine.languageMatches("en", "en"))
        #expect(AetherEngine.languageMatches("eng", "en"))
        #expect(AetherEngine.languageMatches("EN", "eng"))
        #expect(AetherEngine.languageMatches("german", "de"))
        #expect(AetherEngine.languageMatches("ger", "deu"))
        #expect(AetherEngine.languageMatches(" en ", "english"))
    }

    @Test("language matching rejects mismatches and empty/nil inputs")
    func noMatch() {
        #expect(!AetherEngine.languageMatches("en", "de"))
        #expect(!AetherEngine.languageMatches(nil, "en"))
        #expect(!AetherEngine.languageMatches("", "en"))
        #expect(!AetherEngine.languageMatches("en", ""))
    }

    @Test("explicit override wins when it names a real track")
    func overrideWins() {
        let tracks = [track(0, "en"), track(1, "de")]
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: 1, preferredLanguages: ["en"]) == 1)
    }

    @Test("an out-of-range override falls through to the preference")
    func invalidOverrideFallsThrough() {
        let tracks = [track(0, "en"), track(1, "de")]
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: 9, preferredLanguages: ["de"]) == 1)
    }

    @Test("preference order beats track order")
    func preferenceOrder() {
        let tracks = [track(0, "fr"), track(1, "de"), track(2, "en")]
        // en is on a later track than de, but en is the earlier preference -> en wins.
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["en", "de"]) == 2)
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["de", "en"]) == 1)
    }

    @Test("no preference match selects nothing (caller keeps the default)")
    func noMatchIsNil() {
        let tracks = [track(0, "fr"), track(1, "es")]
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["en"]) == nil)
    }

    @Test("empty preferences with no override select nothing (a #72 no-op)")
    func emptyPreferences() {
        let tracks = [track(0, "fr"), track(1, "es")]
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: []) == nil)
    }

    @Test("a no-audio source selects nothing")
    func noAudio() {
        #expect(AetherEngine.selectAudioIndex(
            tracks: [], override: nil, preferredLanguages: ["en"]) == nil)
    }

    @Test("preference matches a track tagged with a 3-letter code")
    func synonymTrack() {
        let tracks = [track(0, "jpn"), track(1, "eng")]
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["en"]) == 1)
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["ja"]) == 0)
    }
}
