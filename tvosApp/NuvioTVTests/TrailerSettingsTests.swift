import AVFoundation
import XCTest
@testable import NuvioTV

private final class TrailerResolverTestState: @unchecked Sendable {
    var language = "en-US"
    var configuration = "config-1"
    var calls: [String] = []
    var trailerIdLookups = 0
}

final class TrailerSettingsTests: XCTestCase {
    private let suiteName = "TrailerSettingsTestsSuite"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        testDefaults?.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        ProfileSettings.clearActiveProfile()
        super.tearDown()
    }

    func testTrailerSettingsKeysDefined() {
        XCTAssertEqual(SettingsKey.trailersEnabled, "nuvio.tv.settings.playback.trailersEnabled")
        XCTAssertEqual(SettingsKey.backgroundTrailersEnabled, "nuvio.tv.settings.playback.backgroundTrailersEnabled")
        XCTAssertEqual(SettingsKey.trailerPreviewSound, "nuvio.tv.settings.playback.trailerPreviewSound")
        XCTAssertEqual(SettingsKey.trailerDelay, "nuvio.tv.settings.playback.trailerDelay")

        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.trailersEnabled))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.backgroundTrailersEnabled))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.trailerPreviewSound))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.trailerDelay))
    }

    func testTrailerSettingsDefaults() {
        let trailersEnabled = testDefaults.object(forKey: SettingsKey.trailersEnabled) as? Bool ?? true
        let backgroundTrailersEnabled = testDefaults.object(forKey: SettingsKey.backgroundTrailersEnabled) as? Bool ?? true
        let trailerPreviewSound = testDefaults.object(forKey: SettingsKey.trailerPreviewSound) as? Bool ?? false
        let trailerDelay = testDefaults.object(forKey: SettingsKey.trailerDelay) as? Int ?? 7

        XCTAssertTrue(trailersEnabled, "Autoplay trailers should default to true")
        XCTAssertTrue(backgroundTrailersEnabled, "Background trailers should default to true")
        XCTAssertFalse(trailerPreviewSound, "Trailer preview sound should default to false")
        XCTAssertEqual(trailerDelay, 7, "Trailer delay should default to 7 seconds")
    }

    func testZeroSecondTrailerDelay() {
        testDefaults.set(0, forKey: SettingsKey.trailerDelay)
        let delay = testDefaults.object(forKey: SettingsKey.trailerDelay) as? Int ?? 7
        XCTAssertEqual(delay, 0, "Zero-second trailer delay should be supported and persisted")
    }

    func testTrailerDelayRangePersistence() {
        let testDelays = [0, 1, 3, 5, 7, 10, 15]
        for expected in testDelays {
            testDefaults.set(expected, forKey: SettingsKey.trailerDelay)
            let actual = testDefaults.object(forKey: SettingsKey.trailerDelay) as? Int ?? 7
            XCTAssertEqual(actual, expected, "Trailer delay of \(expected)s should persist accurately")
        }
    }

    func testPreservationAcrossAutoplayToggles() {
        // User turns off background trailers
        testDefaults.set(false, forKey: SettingsKey.backgroundTrailersEnabled)
        XCTAssertFalse(testDefaults.bool(forKey: SettingsKey.backgroundTrailersEnabled))

        // User turns off master autoplay toggle
        testDefaults.set(false, forKey: SettingsKey.trailersEnabled)
        XCTAssertFalse(testDefaults.bool(forKey: SettingsKey.trailersEnabled))

        // Background trailer preference is preserved
        XCTAssertFalse(testDefaults.bool(forKey: SettingsKey.backgroundTrailersEnabled))

        // User turns autoplay back on
        testDefaults.set(true, forKey: SettingsKey.trailersEnabled)
        XCTAssertTrue(testDefaults.bool(forKey: SettingsKey.trailersEnabled))
        XCTAssertFalse(testDefaults.bool(forKey: SettingsKey.backgroundTrailersEnabled))
    }

    func testTrailerSettingsProfileIsolation() {
        let profile1Defaults = UserDefaults(suiteName: "TrailerProfile1Suite")!
        let profile2Defaults = UserDefaults(suiteName: "TrailerProfile2Suite")!
        profile1Defaults.removePersistentDomain(forName: "TrailerProfile1Suite")
        profile2Defaults.removePersistentDomain(forName: "TrailerProfile2Suite")

        // Profile 1 disables background trailers with 0s delay and sound on
        profile1Defaults.set(false, forKey: SettingsKey.backgroundTrailersEnabled)
        profile1Defaults.set(0, forKey: SettingsKey.trailerDelay)
        profile1Defaults.set(true, forKey: SettingsKey.trailerPreviewSound)

        // Profile 2 has default unconfigured values
        let p2Background = profile2Defaults.object(forKey: SettingsKey.backgroundTrailersEnabled) as? Bool ?? true
        let p2Delay = profile2Defaults.object(forKey: SettingsKey.trailerDelay) as? Int ?? 7
        let p2Sound = profile2Defaults.object(forKey: SettingsKey.trailerPreviewSound) as? Bool ?? false

        XCTAssertTrue(p2Background, "Profile 2 should retain default true for background trailers")
        XCTAssertEqual(p2Delay, 7, "Profile 2 should retain default 7s delay")
        XCTAssertFalse(p2Sound, "Profile 2 should retain default muted sound")

        // Clean up
        profile1Defaults.removePersistentDomain(forName: "TrailerProfile1Suite")
        profile2Defaults.removePersistentDomain(forName: "TrailerProfile2Suite")
    }

    func testLocalizedTrailerResolutionPrefersTMDBYouTubeBeforeTrailerio() async {
        let state = TrailerResolverTestState()
        state.language = "fr-FR"
        let resolver = YouTubeTrailerResolver(
            preferredLanguageProvider: { state.language },
            configurationIdentityProvider: { state.configuration },
            trailerYouTubeIdProvider: { _ in
                state.calls.append("tmdb")
                return "tmdb1234567"
            },
            refreshedTrailerIdsProvider: { _ in nil },
            trailerioProvider: { _, _ in
                state.calls.append("trailerio")
                return TrailerPlaybackSource(videoUrl: "https://trailerio.test/trailer.m3u8", audioUrl: nil)
            },
            youtubeSourceProvider: { videoID, _, _, isPreview in
                state.calls.append("youtube:\(videoID):\(isPreview)")
                return TrailerPlaybackSource(videoUrl: "https://youtube.test/\(videoID).m3u8", audioUrl: nil)
            }
        )
        let meta = NuvioMeta(
            id: "tt1234567",
            name: "Localized trailer",
            imdbId: "tt1234567",
            type: "movie",
            trailerYtIds: ["meta1234567"]
        )

        let source = await resolver.resolve(for: meta)

        XCTAssertEqual(source?.videoUrl, "https://youtube.test/tmdb1234567.m3u8")
        XCTAssertEqual(state.calls, ["tmdb", "youtube:tmdb1234567:false"])
    }

    func testEnglishTrailerResolutionKeepsTrailerioFastPath() async {
        let state = TrailerResolverTestState()
        state.calls = []
        let resolver = YouTubeTrailerResolver(
            preferredLanguageProvider: { "en-US" },
            configurationIdentityProvider: { state.configuration },
            trailerYouTubeIdProvider: { _ in
                state.calls.append("tmdb")
                return "tmdb1234567"
            },
            refreshedTrailerIdsProvider: { _ in nil },
            trailerioProvider: { _, _ in
                state.calls.append("trailerio")
                return TrailerPlaybackSource(videoUrl: "https://trailerio.test/english.m3u8", audioUrl: nil)
            },
            youtubeSourceProvider: { _, _, _, _ in
                state.calls.append("youtube")
                return nil
            }
        )
        let meta = NuvioMeta(id: "tt7654321", name: "English trailer", imdbId: "tt7654321", type: "movie")

        let source = await resolver.resolve(for: meta)

        XCTAssertEqual(source?.videoUrl, "https://trailerio.test/english.m3u8")
        XCTAssertEqual(state.calls, ["trailerio"])
    }

    func testLocalizedTrailerResolutionFallsBackToTrailerioAfterYouTubeFailure() async {
        let state = TrailerResolverTestState()
        state.language = "fr-FR"
        let resolver = YouTubeTrailerResolver(
            preferredLanguageProvider: { state.language },
            configurationIdentityProvider: { state.configuration },
            trailerYouTubeIdProvider: { _ in
                state.calls.append("tmdb")
                return "tmdb1234567"
            },
            refreshedTrailerIdsProvider: { _ in nil },
            trailerioProvider: { _, _ in
                state.calls.append("trailerio")
                return TrailerPlaybackSource(videoUrl: "https://trailerio.test/fallback.m3u8", audioUrl: nil)
            },
            youtubeSourceProvider: { _, _, _, _ in
                state.calls.append("youtube")
                return nil
            }
        )
        let meta = NuvioMeta(id: "tt1122334", name: "Fallback trailer", imdbId: "tt1122334", type: "movie")

        let source = await resolver.resolve(for: meta)

        XCTAssertEqual(source?.videoUrl, "https://trailerio.test/fallback.m3u8")
        XCTAssertEqual(state.calls, ["tmdb", "youtube", "trailerio"])
    }

    func testTrailerIDCacheIncludesLanguageConfigurationAndMediaType() async {
        let state = TrailerResolverTestState()
        let resolver = YouTubeTrailerResolver(
            preferredLanguageProvider: { state.language },
            configurationIdentityProvider: { state.configuration },
            trailerYouTubeIdProvider: { _ in
                state.trailerIdLookups += 1
                return "tmdb1234567"
            },
            refreshedTrailerIdsProvider: { _ in nil }
        )
        let movie = NuvioMeta(id: "same-meta-id", name: "Cache test", tmdbId: 42, type: "movie")
        let series = NuvioMeta(id: "same-meta-id", name: "Cache test", tmdbId: 42, type: "series")

        _ = await resolver.preferredTrailerYouTubeId(for: movie)
        _ = await resolver.preferredTrailerYouTubeId(for: movie)
        XCTAssertEqual(state.trailerIdLookups, 1)

        state.language = "fr-FR"
        _ = await resolver.preferredTrailerYouTubeId(for: movie)
        XCTAssertEqual(state.trailerIdLookups, 2)

        state.configuration = "config-2"
        _ = await resolver.preferredTrailerYouTubeId(for: movie)
        XCTAssertEqual(state.trailerIdLookups, 3)

        _ = await resolver.preferredTrailerYouTubeId(for: series)
        XCTAssertEqual(state.trailerIdLookups, 4)
    }

    func testTrailerConfigurationIdentityDoesNotExposeRawAPIKey() async {
        let key = "trailer-cache-test-secret"
        testDefaults.set(key, forKey: SettingsKey.tmdbApiKey)
        testDefaults.set(true, forKey: SettingsKey.tmdbEnabled)
        testDefaults.set(true, forKey: SettingsKey.tmdbUseTrailers)

        let identity = await TmdbDetailsService.withRequestContext(defaults: testDefaults) {
            TmdbDetailsService.trailerResolutionConfigurationIdentity
        }

        XCTAssertFalse(identity.contains(key))
        XCTAssertNotEqual(identity, "true|true|no-key")
    }

    @MainActor
    func testBackgroundTrailerRequiresSettingRegardlessOfHandoff() {
        testDefaults.set(false, forKey: SettingsKey.backgroundTrailersEnabled)
        testDefaults.set(true, forKey: SettingsKey.trailersEnabled)

        TrailerPlaybackHandoff.shared.recordHandoff(metaId: "test_meta_123", time: 12.0)
        let handoff = TrailerPlaybackHandoff.shared.takeHandoff(for: "test_meta_123")
        XCTAssertNotNil(handoff)

        let bgEnabled = testDefaults.bool(forKey: SettingsKey.backgroundTrailersEnabled)
        XCTAssertFalse(bgEnabled, "Background trailers setting must remain disabled regardless of handoff")
    }

    func testTrailerPlaybackSourceMakePlayerItemSingleVideo() {
        let source = TrailerPlaybackSource(
            videoUrl: "https://trailerio.test/video.mp4",
            audioUrl: nil,
            qualityLabel: "1080p (MP4)"
        )
        let item = source.makePlayerItem(preferredForwardBufferDuration: 2.0)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.preferredForwardBufferDuration, 2.0)
        XCTAssertEqual(item?.preferredPeakBitRate, 0)
        XCTAssertEqual(item?.preferredMaximumResolution, .zero)
        XCTAssertTrue(item?.asset is AVURLAsset)
    }

    func testTrailerPlaybackSourceMakePlayerItemInvalidURL() {
        let source = TrailerPlaybackSource(
            videoUrl: "",
            audioUrl: nil
        )
        let item = source.makePlayerItem()
        XCTAssertNil(item)
    }

    func testTrailerPlaybackSourceCarriesAudioURLForAdaptivePairs() async {
        let state = TrailerResolverTestState()
        let resolver = YouTubeTrailerResolver(
            preferredLanguageProvider: { "en-US" },
            configurationIdentityProvider: { state.configuration },
            trailerYouTubeIdProvider: { _ in "ge_ABjtYx88" },
            refreshedTrailerIdsProvider: { _ in nil },
            trailerioProvider: { _, _ in nil },
            youtubeSourceProvider: { _, _, _, isPreview in
                TrailerPlaybackSource(
                    videoUrl: "https://googlevideo.test/video.mp4",
                    audioUrl: "https://googlevideo.test/audio.m4a",
                    qualityLabel: "1080p (Adaptive)"
                )
            }
        )
        let meta = NuvioMeta(id: "tmdb:804616", name: "F1: The Movie", type: "movie")
        let source = await resolver.resolvePreview(for: meta)
        XCTAssertNotNil(source)
        XCTAssertEqual(source?.videoUrl, "https://googlevideo.test/video.mp4")
        XCTAssertEqual(source?.audioUrl, "https://googlevideo.test/audio.m4a")
        XCTAssertEqual(source?.qualityLabel, "1080p (Adaptive)")
    }

    func testTrailerResolutionPrefersTrailerioWhenAvailableForEnglish() async {
        let state = TrailerResolverTestState()
        let resolver = YouTubeTrailerResolver(
            preferredLanguageProvider: { "en-US" },
            configurationIdentityProvider: { state.configuration },
            trailerYouTubeIdProvider: { _ in
                state.calls.append("tmdb")
                return "tmdb1234567"
            },
            refreshedTrailerIdsProvider: { _ in nil },
            trailerioProvider: { _, _ in
                state.calls.append("trailerio")
                return TrailerPlaybackSource(videoUrl: "https://trailerio.test/english.mp4", qualityLabel: "1080p")
            },
            imdbTrailerProvider: { imdbId in
                state.calls.append("imdb:\(imdbId)")
                return TrailerPlaybackSource(
                    videoUrl: "https://imdb-video.media-imdb.com/1080p.mp4",
                    qualityLabel: "1080p (IMDb)"
                )
            },
            youtubeSourceProvider: { _, _, _, _ in
                state.calls.append("youtube")
                return nil
            }
        )
        let meta = NuvioMeta(id: "tt2359704", name: "JoJo's Bizarre Adventure", imdbId: "tt2359704", type: "series")
        let source = await resolver.resolve(for: meta)

        XCTAssertEqual(source?.videoUrl, "https://trailerio.test/english.mp4")
        XCTAssertEqual(state.calls, ["trailerio"])
    }

    func testTrailerResolutionPrefersImdbWhenTrailerioUnavailable() async {
        let state = TrailerResolverTestState()
        let resolver = YouTubeTrailerResolver(
            preferredLanguageProvider: { "en-US" },
            configurationIdentityProvider: { state.configuration },
            trailerYouTubeIdProvider: { _ in
                state.calls.append("tmdb")
                return "tmdb1234567"
            },
            refreshedTrailerIdsProvider: { _ in nil },
            trailerioProvider: { _, _ in
                state.calls.append("trailerio")
                return nil
            },
            imdbTrailerProvider: { imdbId in
                state.calls.append("imdb:\(imdbId)")
                return TrailerPlaybackSource(
                    videoUrl: "https://imdb-video.media-imdb.com/1080p.mp4",
                    qualityLabel: "1080p (IMDb)"
                )
            },
            youtubeSourceProvider: { _, _, _, _ in
                state.calls.append("youtube")
                return nil
            }
        )
        let meta = NuvioMeta(id: "tt2560140", name: "Attack on Titan", imdbId: "tt2560140", type: "series")
        let source = await resolver.resolve(for: meta)

        XCTAssertEqual(source?.videoUrl, "https://imdb-video.media-imdb.com/1080p.mp4")
        XCTAssertEqual(source?.qualityLabel, "1080p (IMDb)")
        XCTAssertEqual(state.calls, ["trailerio", "imdb:tt2560140"])
    }

    func testBackgroundPreviewPrefersImdbHighResolutionEvenForNonEnglish() async {
        let state = TrailerResolverTestState()
        state.language = "de-DE"
        let resolver = YouTubeTrailerResolver(
            preferredLanguageProvider: { state.language },
            configurationIdentityProvider: { state.configuration },
            trailerYouTubeIdProvider: { _ in
                state.calls.append("tmdb")
                return "tmdb_de_1234"
            },
            refreshedTrailerIdsProvider: { _ in nil },
            trailerioProvider: { _, _ in
                state.calls.append("trailerio")
                return nil
            },
            imdbTrailerProvider: { imdbId in
                state.calls.append("imdb:\(imdbId)")
                return TrailerPlaybackSource(
                    videoUrl: "https://imdb-video.media-imdb.com/backdrop1080p.mp4",
                    qualityLabel: "1080p (IMDb)"
                )
            },
            youtubeSourceProvider: { _, _, _, _ in
                state.calls.append("youtube")
                return nil
            }
        )
        let meta = NuvioMeta(id: "tt7654321", name: "Dune", imdbId: "tt7654321", type: "movie")
        let source = await resolver.resolvePreview(for: meta)

        XCTAssertEqual(source?.videoUrl, "https://imdb-video.media-imdb.com/backdrop1080p.mp4")
        XCTAssertEqual(state.calls, ["imdb:tt7654321"])
    }

    func testImdbTrailerFallbackToYouTubeWhenImdbUnavailable() async {
        let state = TrailerResolverTestState()
        let resolver = YouTubeTrailerResolver(
            preferredLanguageProvider: { "en-US" },
            configurationIdentityProvider: { state.configuration },
            trailerYouTubeIdProvider: { _ in
                state.calls.append("tmdb")
                return "ge_ABjtYx88"
            },
            refreshedTrailerIdsProvider: { _ in nil },
            trailerioProvider: { _, _ in
                state.calls.append("trailerio")
                return nil
            },
            imdbTrailerProvider: { imdbId in
                state.calls.append("imdb:\(imdbId)")
                return nil
            },
            youtubeSourceProvider: { videoID, _, _, _ in
                state.calls.append("youtube:\(videoID)")
                return TrailerPlaybackSource(
                    videoUrl: "https://youtube.test/\(videoID).mp4",
                    qualityLabel: "360p (MP4)"
                )
            }
        )
        let meta = NuvioMeta(id: "tt12332200", name: "F1: The Movie", imdbId: "tt12332200", type: "movie")
        let source = await resolver.resolvePreview(for: meta)

        XCTAssertEqual(source?.videoUrl, "https://youtube.test/ge_ABjtYx88.mp4")
        XCTAssertEqual(source?.qualityLabel, "360p (MP4)")
        XCTAssertEqual(state.calls, ["trailerio", "imdb:tt12332200", "tmdb", "youtube:ge_ABjtYx88"])
    }

    func testImdbCandidateScoringPrefersLanguage() {
        let enScoreEnglish = YouTubeTrailerResolver.scoreImdbVideoName("Official English Trailer", preferredLanguage: "en-US")
        let enScoreFrench = YouTubeTrailerResolver.scoreImdbVideoName("Jojo's Bizarre Adventure: Stone Ocean (French Trailer 3 Subtitled)", preferredLanguage: "en-US")
        let enScoreTrailer = YouTubeTrailerResolver.scoreImdbVideoName("Official Trailer 2", preferredLanguage: "en-US")
        let enScoreVertical = YouTubeTrailerResolver.scoreImdbVideoName("Official Vertical Teaser", preferredLanguage: "en-US")

        XCTAssertGreaterThan(enScoreEnglish, enScoreFrench, "English trailer must score higher than French subtitled trailer for English user")
        XCTAssertGreaterThan(enScoreTrailer, enScoreFrench, "Official trailer must score higher than foreign subtitled trailer for English user")
        XCTAssertLessThan(enScoreVertical, -5000, "Vertical promo video must be heavily penalized")

        let deScoreGerman = YouTubeTrailerResolver.scoreImdbVideoName("Jojo's Bizarre Adventure: Stone Ocean (German Trailer 3 Subtitled)", preferredLanguage: "de-DE")
        let deScoreEnglish = YouTubeTrailerResolver.scoreImdbVideoName("Official English Trailer", preferredLanguage: "de-DE")
        XCTAssertGreaterThan(deScoreGerman, deScoreEnglish, "German trailer must score higher than English trailer for German user")
    }

    // MARK: AniList titles

    private func aniListResolver(_ state: TrailerResolverTestState, youtubePlays: Bool, imdbID: String?) -> YouTubeTrailerResolver {
        YouTubeTrailerResolver(
            preferredLanguageProvider: { state.language },
            configurationIdentityProvider: { state.configuration },
            trailerYouTubeIdProvider: { _ in
                state.calls.append("tmdb")
                return nil
            },
            refreshedTrailerIdsProvider: { _ in nil },
            trailerioProvider: { imdb, _ in
                state.calls.append("trailerio:\(imdb)")
                return TrailerPlaybackSource(videoUrl: "https://trailerio.test/\(imdb).m3u8", audioUrl: nil)
            },
            imdbTrailerProvider: { imdb in
                state.calls.append("imdb:\(imdb)")
                return nil
            },
            youtubeSourceProvider: { videoID, _, _, _ in
                state.calls.append("youtube:\(videoID)")
                return youtubePlays ? TrailerPlaybackSource(videoUrl: "https://youtube.test/\(videoID).m3u8", audioUrl: nil) : nil
            },
            aniListIMDbIDProvider: { _ in
                state.calls.append("ids")
                return imdbID
            }
        )
    }

    func testAnAniListTitlePlaysItsOwnTrailerFirstInAnyLanguage() async {
        let state = TrailerResolverTestState()
        let meta = NuvioMeta(id: "anilist:146065", name: "Season 2", type: "series", trailerYtIds: ["dQw4w9WgXcQ"])

        let source = await aniListResolver(state, youtubePlays: true, imdbID: "tt9335498").resolve(for: meta)

        XCTAssertEqual(source?.videoUrl, "https://youtube.test/dQw4w9WgXcQ.m3u8")
        XCTAssertEqual(state.calls, ["youtube:dQw4w9WgXcQ"])
    }

    func testAnAniListTitleWithoutAPlayableTrailerTriesTrailerio() async {
        let withoutTrailer = TrailerResolverTestState()
        let meta = NuvioMeta(id: "anilist:146065", name: "Season 2", type: "series")
        let source = await aniListResolver(withoutTrailer, youtubePlays: true, imdbID: "tt9335498").resolve(for: meta)
        XCTAssertEqual(source?.videoUrl, "https://trailerio.test/tt9335498.m3u8")
        XCTAssertEqual(withoutTrailer.calls, ["ids", "trailerio:tt9335498"])

        // The YouTube video is gone or blocked.
        let blocked = TrailerResolverTestState()
        blocked.language = "cs-CZ"
        let withTrailer = NuvioMeta(id: "anilist:146065", name: "Season 2", type: "series", trailerYtIds: ["dQw4w9WgXcQ"])
        let fallback = await aniListResolver(blocked, youtubePlays: false, imdbID: "tt9335498").resolve(for: withTrailer)
        XCTAssertEqual(fallback?.videoUrl, "https://trailerio.test/tt9335498.m3u8")
        XCTAssertEqual(blocked.calls, ["youtube:dQw4w9WgXcQ", "ids", "trailerio:tt9335498"])

        // Without an IMDb id there is nothing more to try.
        let unknown = TrailerResolverTestState()
        let none = await aniListResolver(unknown, youtubePlays: false, imdbID: nil).resolve(for: meta)
        XCTAssertNil(none)
        XCTAssertEqual(unknown.calls, ["ids"])
    }
}
