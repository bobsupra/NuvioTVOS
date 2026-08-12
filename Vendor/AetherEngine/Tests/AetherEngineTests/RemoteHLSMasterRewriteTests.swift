import Testing
import Foundation
@testable import AetherEngine

/// #316: the master rewriter that lets a host-declared sidecar become a legible rendition on the
/// nativeRemoteHLS bypass. The load-bearing property under test is that the media never moves: every
/// variant, audio rendition and key URI still points at the origin after the rewrite, so AVPlayer keeps
/// fetching A/V straight from there and passthrough is unaffected. Only the master and the WebVTT
/// renditions come from the loopback server.
@Suite("Remote-HLS master rewrite (#316)")
struct RemoteHLSMasterRewriteTests {

    private static let origin = URL(string: "https://jf.test/videos/42/master.m3u8?api_key=abc")!

    private static let english = RemoteHLSMasterRewrite.Rendition(
        ordinal: 0, name: "English", language: "en")

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: - Master

    private static let master = """
    #EXTM3U
    #EXT-X-INDEPENDENT-SEGMENTS
    #EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS="hvc1.2.4.L150.B0,ec-3",RESOLUTION=3840x2160
    main.m3u8
    """

    @Test("Variant URIs are absolutised against the origin, so the media stays at the origin")
    func variantURIBecomesAbsolute() throws {
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: Self.master, originURL: Self.origin, renditions: [Self.english])

        #expect(Self.lines(out).contains("https://jf.test/videos/42/main.m3u8"))
        #expect(!Self.lines(out).contains("main.m3u8"))
    }

    @Test("The variant keeps every attribute it arrived with and gains only the subtitles group")
    func streamInfIsPreserved() throws {
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: Self.master, originURL: Self.origin, renditions: [Self.english])

        let streamInf = try #require(Self.lines(out).first { $0.hasPrefix("#EXT-X-STREAM-INF:") })
        #expect(streamInf.contains("BANDWIDTH=8000000"))
        #expect(streamInf.contains("CODECS=\"hvc1.2.4.L150.B0,ec-3\""))
        #expect(streamInf.contains("RESOLUTION=3840x2160"))
        #expect(streamInf.hasSuffix(",SUBTITLES=\"subs\""))
    }

    @Test("The rendition is declared before the variant that references it")
    func mediaTagPrecedesVariant() throws {
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: Self.master, originURL: Self.origin, renditions: [Self.english])
        let all = Self.lines(out)
        let media = try #require(all.firstIndex { $0.hasPrefix("#EXT-X-MEDIA:") })
        let variant = try #require(all.firstIndex { $0.hasPrefix("#EXT-X-STREAM-INF:") })
        #expect(media < variant)
    }

    @Test("The rendition URI stays relative so the AirPlay LAN-IP swap carries it along")
    func renditionURIStaysRelative() throws {
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: Self.master, originURL: Self.origin, renditions: [Self.english])
        let media = try #require(Self.lines(out).first { $0.hasPrefix("#EXT-X-MEDIA:") })
        #expect(media.contains("URI=\"subs_0.m3u8\""))
        #expect(media.contains("TYPE=SUBTITLES"))
        #expect(media.contains("LANGUAGE=\"en\""))
        // #15 / Sodalite#38: never self-engaging, and never FORCED. The host selects.
        #expect(media.contains("DEFAULT=NO"))
        #expect(media.contains("AUTOSELECT=NO"))
        #expect(!media.contains("FORCED"))
    }

    @Test("An SDH sidecar carries the accessibility characteristics")
    func sdhCharacteristics() throws {
        let sdh = RemoteHLSMasterRewrite.Rendition(ordinal: 1, name: "English SDH", language: "en",
                                                   isSDH: true)
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: Self.master, originURL: Self.origin, renditions: [sdh])
        let media = try #require(Self.lines(out).first { $0.hasPrefix("#EXT-X-MEDIA:") })
        #expect(media.contains("public.accessibility.transcribes-spoken-dialog"))
        #expect(media.contains("public.accessibility.describes-music-and-sound"))
    }

    // MARK: - Origin renditions and groups

    private static let masterWithAudioAndSubs = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Surround",DEFAULT=YES,URI="audio/eac3.m3u8"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub1",NAME="English",LANGUAGE="en",URI="subs/en.m3u8"
    #EXT-X-SESSION-KEY:METHOD=AES-128,URI="key?id=7"
    #EXT-X-STREAM-INF:BANDWIDTH=8000000,AUDIO="aud",SUBTITLES="sub1"
    v0/main.m3u8
    """

    @Test("Audio, subtitle and session-key URIs are absolutised too")
    func otherURIAttributesBecomeAbsolute() throws {
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: Self.masterWithAudioAndSubs, originURL: Self.origin,
            renditions: [Self.english])

        #expect(out.contains("URI=\"https://jf.test/videos/42/audio/eac3.m3u8\""))
        #expect(out.contains("URI=\"https://jf.test/videos/42/subs/en.m3u8\""))
        #expect(out.contains("URI=\"https://jf.test/videos/42/key?id=7\""))
    }

    @Test("An origin subtitles group is joined rather than shadowed by a second one")
    func joinsExistingGroup() throws {
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: Self.masterWithAudioAndSubs, originURL: Self.origin,
            renditions: [RemoteHLSMasterRewrite.Rendition(ordinal: 0, name: "Deutsch", language: "de")])

        let injected = try #require(Self.lines(out).first { $0.contains("URI=\"subs_0.m3u8\"") })
        #expect(injected.contains("GROUP-ID=\"sub1\""))
        // The variant already named its group; it must not be rewritten to ours.
        let streamInf = try #require(Self.lines(out).first { $0.hasPrefix("#EXT-X-STREAM-INF:") })
        #expect(streamInf.contains("SUBTITLES=\"sub1\""))
        #expect(!streamInf.contains("SUBTITLES=\"subs\""))
    }

    @Test("A name the origin already uses in that group gets a disambiguator, not a collapse")
    func duplicateNameIsDisambiguated() throws {
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: Self.masterWithAudioAndSubs, originURL: Self.origin,
            renditions: [Self.english])
        let injected = try #require(Self.lines(out).first { $0.contains("URI=\"subs_0.m3u8\"") })
        #expect(injected.contains("NAME=\"English 2\""))
    }

    @Test("Two sidecars with the same name are disambiguated against each other")
    func duplicateAmongInjectedIsDisambiguated() throws {
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: Self.master, originURL: Self.origin,
            renditions: [Self.english,
                         RemoteHLSMasterRewrite.Rendition(ordinal: 1, name: "English", language: "en")])
        let names = Self.lines(out).filter { $0.hasPrefix("#EXT-X-MEDIA:") }
            .compactMap { HLSPlaylistParser.attribute("NAME", in: $0) }
        #expect(names == ["English", "English 2"])
    }

    private static let masterWithTwoGroups = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub-hd",NAME="English",LANGUAGE="en",URI="hd/en.m3u8"
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub-sd",NAME="English",LANGUAGE="en",URI="sd/en.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=8000000,SUBTITLES="sub-hd"
    hd.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=800000,SUBTITLES="sub-sd"
    sd.m3u8
    """

    @Test("Every origin subtitles group gets the sidecar, so variant choice cannot lose it")
    func injectsIntoEveryGroup() throws {
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: Self.masterWithTwoGroups, originURL: Self.origin,
            renditions: [RemoteHLSMasterRewrite.Rendition(ordinal: 0, name: "Deutsch", language: "de")])
        let groups = Self.lines(out).filter { $0.contains("URI=\"subs_0.m3u8\"") }
            .compactMap { HLSPlaylistParser.attribute("GROUP-ID", in: $0) }
        #expect(groups.sorted() == ["sub-hd", "sub-sd"])
    }

    private static let masterMixedGroups = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="sub1",NAME="English",LANGUAGE="en",URI="subs/en.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=8000000,SUBTITLES="sub1"
    hd.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=800000
    sd.m3u8
    """

    @Test("A variant with no group of its own is pointed at the engine's group")
    func variantWithoutGroupGetsOurs() throws {
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: Self.masterMixedGroups, originURL: Self.origin,
            renditions: [RemoteHLSMasterRewrite.Rendition(ordinal: 0, name: "Deutsch", language: "de")])
        let groups = Self.lines(out).filter { $0.contains("URI=\"subs_0.m3u8\"") }
            .compactMap { HLSPlaylistParser.attribute("GROUP-ID", in: $0) }
        #expect(groups.sorted() == ["sub1", "subs"])
        // Anchored, not `contains`: "BANDWIDTH=800000" is a substring of the HD variant's 8000000.
        let bare = try #require(Self.lines(out).first {
            $0.hasPrefix("#EXT-X-STREAM-INF:") && HLSPlaylistParser.attribute("BANDWIDTH", in: $0) == "800000"
        })
        #expect(bare.hasSuffix(",SUBTITLES=\"subs\""))
    }

    // MARK: - Media playlist wrap

    @Test("A bare media playlist is wrapped in a single-variant master pointing back at the origin")
    func mediaPlaylistIsWrapped() throws {
        let media = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:6.0,
        seg0.mp4
        #EXT-X-ENDLIST
        """
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: media, originURL: Self.origin, renditions: [Self.english])

        let all = Self.lines(out)
        #expect(all.last == Self.origin.absoluteString)
        #expect(all.contains { $0.hasPrefix("#EXT-X-STREAM-INF:") && $0.contains("BANDWIDTH=") })
        #expect(all.contains { $0.contains("URI=\"subs_0.m3u8\"") })
        // The origin's own segments must not have been copied into the wrap.
        #expect(!all.contains("seg0.mp4"))
    }

    // MARK: - Refusals

    @Test("A body that is not a playlist is refused")
    func nonPlaylistRefused() {
        #expect(throws: RemoteHLSMasterRewrite.Refusal.notAPlaylist) {
            try RemoteHLSMasterRewrite.rewrite(
                originPlaylist: "<html>404</html>", originURL: Self.origin, renditions: [Self.english])
        }
    }

    @Test("A master whose STREAM-INF has no URI line is refused")
    func masterWithoutVariantsRefused() {
        #expect(throws: RemoteHLSMasterRewrite.Refusal.masterWithoutVariants) {
            try RemoteHLSMasterRewrite.rewrite(
                originPlaylist: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n",
                originURL: Self.origin, renditions: [Self.english])
        }
    }

    @Test("Nothing to inject is refused rather than served as a pointless proxy")
    func noRenditionsRefused() {
        #expect(throws: RemoteHLSMasterRewrite.Refusal.noRenditions) {
            try RemoteHLSMasterRewrite.rewrite(
                originPlaylist: Self.master, originURL: Self.origin, renditions: [])
        }
    }

    @Test("An already-absolute variant URI is left alone")
    func absoluteURIUntouched() throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=8000000
        https://cdn.test/other/main.m3u8
        """
        let out = try RemoteHLSMasterRewrite.rewrite(
            originPlaylist: master, originURL: Self.origin, renditions: [Self.english])
        #expect(Self.lines(out).contains("https://cdn.test/other/main.m3u8"))
    }
}
