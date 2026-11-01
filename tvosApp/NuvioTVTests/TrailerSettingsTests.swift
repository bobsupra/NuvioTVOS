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

    func testTrailerPlaybackSourceMakePlayerItemSingleVideo() async {
        let source = TrailerPlaybackSource(
            videoUrl: "https://trailerio.test/video.mp4",
            audioUrl: nil,
            qualityLabel: "1080p (MP4)"
        )
        let item = await source.makePlayerItem(preferredForwardBufferDuration: 2.0)
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.preferredForwardBufferDuration, 2.0)
        XCTAssertEqual(item?.preferredPeakBitRate, 0)
        XCTAssertEqual(item?.preferredMaximumResolution, .zero)
        XCTAssertTrue(item?.asset is AVURLAsset)
    }

    func testTrailerPlaybackSourceMakePlayerItemInvalidURL() async {
        let source = TrailerPlaybackSource(
            videoUrl: "",
            audioUrl: nil
        )
        let item = await source.makePlayerItem()
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
}
