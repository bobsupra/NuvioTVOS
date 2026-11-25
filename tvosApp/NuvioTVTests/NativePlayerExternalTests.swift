import XCTest
@testable import NuvioTV

/// Native Player external-player handoff: deep-link building, x-callback progress
/// form, and best-complete-subtitle-first ordering. Lives in its own file because
/// StreamQualityTagsTests.swift is excluded from the test target's Sources.
final class NativePlayerExternalTests: XCTestCase {
    func testNativePlayerLaunchURLCarriesPercentEncodedName() {
        let stream = URL(string: "https://cdn.example/movie.mkv?token=a&b=c")!
        let sub = URL(string: "https://subs.example/en.srt")!
        let launch = ExternalPlayer.nativePlayer.launchURL(
            for: stream,
            subtitleURLs: [sub],
            title: "Lawrence of Arabia"
        )!

        XCTAssertTrue(launch.absoluteString.starts(with: "nativeplayer://play?url="))
        XCTAssertTrue(launch.absoluteString.contains("name=Lawrence%20of%20Arabia"))
        XCTAssertTrue(launch.absoluteString.contains("sub=https%3A%2F%2Fsubs.example%2Fen.srt"))
        XCTAssertFalse(launch.absoluteString.contains("movie.mkv?token"))
    }

    func testNativePlayerLaunchURLCarriesResumePosition() {
        // Native Player resumes an externally-launched URL only if the caller sends
        // the start time, the same `position=<seconds>` Infuse takes.
        let stream = URL(string: "https://cdn.example/movie.mkv")!
        let launch = ExternalPlayer.nativePlayer.launchURL(
            for: stream,
            position: 754.0,
            title: "Movie"
        )!
        XCTAssertTrue(launch.absoluteString.contains("position=754"))
    }

    func testNativePlayerLaunchURLOmitsZeroPosition() {
        let stream = URL(string: "https://cdn.example/movie.mkv")!
        let launch = ExternalPlayer.nativePlayer.launchURL(
            for: stream,
            position: 0,
            title: "Movie"
        )!
        XCTAssertFalse(launch.absoluteString.contains("position="))
    }

    func testTheTitleNamesTheEpisode() {
        XCTAssertEqual(
            ExternalPlayer.displayTitle(name: "Severance", season: 2, episode: 3, episodeTitle: "Who Is Alive?"),
            "Severance · S2 · E3 · Who Is Alive?"
        )
        // The episode line Nuvio passes can already carry the code.
        XCTAssertEqual(
            ExternalPlayer.displayTitle(name: "Severance", season: 2, episode: 3, episodeTitle: "S2 · E3 · Who Is Alive?"),
            "Severance · S2 · E3 · Who Is Alive?"
        )
        XCTAssertEqual(
            ExternalPlayer.displayTitle(name: "Severance", season: 2, episode: 3, episodeTitle: "Episode 3"),
            "Severance · S2 · E3"
        )
        XCTAssertEqual(
            ExternalPlayer.displayTitle(name: "Severance", season: 2, episode: 3, episodeTitle: nil),
            "Severance · S2 · E3"
        )
        XCTAssertEqual(
            ExternalPlayer.displayTitle(name: "Arrival", season: nil, episode: nil, episodeTitle: nil),
            "Arrival"
        )
    }

    func testNativePlayerGetsTheEpisodeInItsTitle() {
        let launch = ExternalPlayer.nativePlayer.launchURL(
            for: URL(string: "https://cdn.example/episode.mkv")!,
            title: ExternalPlayer.displayTitle(name: "Severance", season: 2, episode: 3, episodeTitle: "Who Is Alive?")
        )!
        let name = URLComponents(url: launch, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "name" }?.value
        XCTAssertEqual(name, "Severance · S2 · E3 · Who Is Alive?")
    }

    func testNativePlayerFallsBackForUnsupportedVideoURLs() {
        let file = URL(fileURLWithPath: "/tmp/movie.mp4")
        let magnet = URL(string: "magnet:?xt=urn:btih:0123456789")!
        let dash = URL(string: "https://cdn.example/manifest.mpd?token=abc")!

        XCTAssertNil(ExternalPlayer.nativePlayer.launchURL(for: file, title: "Movie"))
        XCTAssertNil(ExternalPlayer.nativePlayer.launchURL(for: magnet, title: "Movie"))
        XCTAssertNil(ExternalPlayer.nativePlayer.launchURL(for: dash, title: "Movie"))
        XCTAssertNotNil(ExternalPlayer.infuse.launchURL(for: magnet, title: "Movie"), "other player URLs retain existing behavior")
    }

    func testNativePlayerUsesXCallbackFormWhenCallbacksPresent() {
        let stream = URL(string: "https://cdn.example/movie.mkv")!
        let success = URL(string: "nuvio-tv://external-playback/ABC-123")!
        let error = URL(string: "nuvio-tv://external-playback/error/ABC-123")!

        let plain = ExternalPlayer.nativePlayer.launchURL(for: stream, title: "Movie")!
        XCTAssertTrue(plain.absoluteString.starts(with: "nativeplayer://play?url="))
        XCTAssertFalse(plain.absoluteString.contains("x-success"))

        let cb = ExternalPlayer.nativePlayer.launchURL(
            for: stream,
            title: "Movie",
            successURL: success,
            errorURL: error
        )!
        XCTAssertTrue(cb.absoluteString.starts(with: "nativeplayer://x-callback-url/play?url="))
        XCTAssertTrue(cb.absoluteString.contains("x-success=nuvio-tv%3A%2F%2Fexternal-playback%2FABC-123"))
        XCTAssertTrue(cb.absoluteString.contains("x-error=nuvio-tv%3A%2F%2Fexternal-playback%2Ferror%2FABC-123"))
        XCTAssertFalse(cb.absoluteString.contains("x-success=nuvio-tv://"))
    }

    func testBestCompleteSubtitleFirstSinksForcedAndPrefersLanguage() {
        let subs = [
            NuvioSubtitle(url: "u1", language: "English", label: "English (Forced)"),
            NuvioSubtitle(url: "u2", language: "Spanish", label: "Español"),
            NuvioSubtitle(url: "u3", language: "en", label: "English"),
            NuvioSubtitle(url: "u4", language: "English", label: "Foreign Parts Only"),
        ]
        let ordered = SubtitleLanguagePreferences.bestCompleteFirst(subs, preferredLanguages: ["English"])

        XCTAssertEqual(ordered.count, 4, "nothing dropped; forced sinks, not removed")
        XCTAssertEqual(ordered.first?.url, "u3", "first = complete English (preferred language)")
        XCTAssertTrue(["u1", "u4"].contains(ordered.last?.url ?? ""), "a forced track is last")
        let completeSpanish = ordered.firstIndex { $0.url == "u2" }!
        let forcedEnglish = ordered.firstIndex { $0.url == "u1" }!
        XCTAssertLessThan(completeSpanish, forcedEnglish, "complete (any lang) beats forced")
    }

    func testBestCompleteSubtitleFirstDedupsAndKeepsSingletons() {
        let dup = [
            NuvioSubtitle(url: "same", language: "en", label: "English"),
            NuvioSubtitle(url: "same", language: "en", label: "English"),
        ]
        XCTAssertEqual(SubtitleLanguagePreferences.bestCompleteFirst(dup, preferredLanguages: ["English"]).count, 1)
        let one = [NuvioSubtitle(url: "only", language: "en", label: "English")]
        XCTAssertEqual(SubtitleLanguagePreferences.bestCompleteFirst(one, preferredLanguages: []).map(\.url), ["only"])
    }

    func testBestCompleteSubtitleFirstKeepsExplicitNonForcedLabelsComplete() {
        let subs = [
            NuvioSubtitle(url: "https://subs.example/forced.srt", language: "English", label: "English (Not Forced)"),
            NuvioSubtitle(url: "https://subs.example/en.srt", language: "English", label: "English"),
            NuvioSubtitle(url: "https://subs.example/en-unforced.srt", language: "English", label: "English (Unforced)"),
        ]

        let ordered = SubtitleLanguagePreferences.bestCompleteFirst(subs, preferredLanguages: ["English"])
        XCTAssertEqual(ordered.map(\.url), subs.map(\.url))
    }

    func testBestCompleteSubtitleFirstIgnoresForcedTokensOutsideFilename() {
        let forced = NuvioSubtitle(url: "https://cdn.example/subs/english-forced.srt", language: "English", label: "English")
        let queryToken = NuvioSubtitle(
            url: "https://forced.example/forced-folder/english.srt?token=forced",
            language: "English",
            label: "English"
        )

        let ordered = SubtitleLanguagePreferences.bestCompleteFirst([forced, queryToken], preferredLanguages: ["English"])
        XCTAssertEqual(ordered.first?.url, queryToken.url)
        XCTAssertEqual(ordered.last?.url, forced.url)
    }

    func testNativePlayerFiltersUnsupportedSubtitleFormatsBeforeTheEightSubtitleLimit() {
        let video = URL(string: "https://cdn.example/movie.mkv")!
        let subtitles = [
            URL(string: "https://subs.example/unsupported.vtt")!,
            URL(string: "https://subs.example/unsupported.ass")!,
            URL(string: "https://subs.example/unsupported.ssa")!,
        ] + (0..<5).map { URL(string: "https://subs.example/track-\($0).srt")! }
            + [URL(string: "https://subs.example/late-track.srt")!]

        let launch = ExternalPlayer.nativePlayer.launchURL(for: video, subtitleURLs: subtitles, title: "Movie")!
        let forwarded = URLComponents(url: launch, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { $0.name == "sub" }.compactMap(\.value) ?? []

        XCTAssertEqual(forwarded.count, 6)
        XCTAssertTrue(forwarded.contains { $0.hasSuffix("late-track.srt") })
        XCTAssertFalse(forwarded.contains { $0.hasSuffix(".vtt") || $0.hasSuffix(".ass") || $0.hasSuffix(".ssa") })
    }

    func testNativePlayerKeepsExtensionlessSubtitleAndOtherPlayersKeepVTT() {
        let video = URL(string: "https://cdn.example/movie.mkv")!
        let extensionless = URL(string: "https://subs.example/export?id=7&format=vtt")!
        let vtt = URL(string: "https://subs.example/captions.vtt")!

        let native = ExternalPlayer.nativePlayer.launchURL(for: video, subtitleURLs: [extensionless], title: "Movie")!
        let nativeSubtitle = URLComponents(url: native, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "sub" }?.value
        XCTAssertEqual(nativeSubtitle, extensionless.absoluteString, "unknown and extensionless URLs may serve SRT; query tokens do not determine format")

        let vlc = ExternalPlayer.vlc.launchURL(for: video, subtitleURLs: [vtt])!
        let vlcSubtitle = URLComponents(url: vlc, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "sub" }?.value
        XCTAssertEqual(vlcSubtitle, vtt.absoluteString)
    }
}
