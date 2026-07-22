import XCTest
@testable import NuvioTV

final class PlaybackBackendPolicyTests: XCTestCase {

    func testAutoSelectsAetherWithFallback() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/movie.mkv",
                separateAudioURL: nil,
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .auto,
                requiresMPVAudioControls: false,
                assMode: .strip
            )
        )
        XCTAssertEqual(result.backend, .aether)
        XCTAssertTrue(result.allowAutomaticFallback)
    }

    func testForcedMPV() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/movie.mkv",
                separateAudioURL: nil,
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .mpv,
                requiresMPVAudioControls: false,
                assMode: .strip
            )
        )
        XCTAssertEqual(result.backend, .mpv)
        XCTAssertFalse(result.allowAutomaticFallback)
    }

    func testForcedAetherDisablesOrdinaryFallback() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/movie.mkv",
                separateAudioURL: nil,
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .aether,
                requiresMPVAudioControls: false,
                assMode: .strip
            )
        )
        XCTAssertEqual(result.backend, .aether)
        XCTAssertFalse(result.allowAutomaticFallback)
    }

    func testSeparateAudioURLForcesMPV() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/video.mp4",
                separateAudioURL: "https://cdn.example/audio.m4a",
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .auto,
                requiresMPVAudioControls: false,
                assMode: .strip
            )
        )
        XCTAssertEqual(result.backend, .mpv)
        XCTAssertFalse(result.allowAutomaticFallback)
    }

    func testAudioControlsForceMPV() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/movie.mkv",
                separateAudioURL: nil,
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .auto,
                requiresMPVAudioControls: true,
                assMode: .strip
            )
        )
        XCTAssertEqual(result.backend, .mpv)
    }

    func testASSScaleForcesMPV() {
        let result = PlaybackBackendPolicy.resolve(
            .init(
                urlString: "https://cdn.example/anime.mkv",
                separateAudioURL: nil,
                streamName: nil,
                streamDescription: nil,
                filename: nil,
                engineSetting: .auto,
                requiresMPVAudioControls: false,
                assMode: .scale
            )
        )
        XCTAssertEqual(result.backend, .mpv)
    }

    func testSettingsMigration() {
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "Auto"), .auto)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "AVPlayer"), .auto)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "MPVKit"), .mpv)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "mpv"), .mpv)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "AetherEngine"), .aether)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "unknown"), .auto)
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "AVPlayer").settingsRawValue, "Auto")
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "AetherEngine").settingsRawValue, "AetherEngine")
        XCTAssertEqual(PlayerEngineSetting.migrated(from: "MPVKit").settingsRawValue, "MPVKit")
    }

    func testMPVFallbackConfigurationPreservesSessionState() throws {
        let videoURL = try XCTUnwrap(URL(string: "https://cdn.example/movie.mkv"))
        let subtitle = NuvioSubtitle(
            url: "https://cdn.example/en.srt",
            language: "eng",
            label: "English"
        )
        let request = PlaybackLoadRequest(
            videoURL: videoURL,
            resumePositionSeconds: 123.456,
            externalSubtitles: [subtitle],
            autoplay: false,
            playbackRate: 1.5,
            subtitleDelaySeconds: -0.25,
            audioDelaySeconds: 0.175,
            audioGainDB: 4
        )

        let configuration = MPVLoadConfiguration(request: request)

        XCTAssertEqual(configuration.resumePositionMs, 123_456)
        XCTAssertEqual(configuration.externalSubtitles, [subtitle])
        XCTAssertEqual(configuration.playbackRate, 1.5)
        XCTAssertEqual(configuration.subtitleDelaySeconds, -0.25)
        XCTAssertEqual(configuration.audioDelaySeconds, 0.175)
        XCTAssertEqual(configuration.audioGainDB, 4)
        XCTAssertFalse(configuration.autoplay)
    }

    func testCacheSegmentMapping() {
        XCTAssertEqual(PlaybackCacheProfile.conservative.aetherForwardBufferSegments, 4)
        XCTAssertEqual(PlaybackCacheProfile.auto.aetherForwardBufferSegments, 10)
        XCTAssertEqual(PlaybackCacheProfile.large.aetherForwardBufferSegments, 30)
        XCTAssertEqual(PlaybackCacheProfile.max.aetherForwardBufferSegments, 60)
    }

    @MainActor
    func testAetherExternalSubtitleIdentityKeepsOrderWhenOneIsRejected() {
        let english = NuvioSubtitle(
            url: "https://cdn.example/en.srt", language: "en", label: "English"
        )
        let norwegian = NuvioSubtitle(
            url: "https://cdn.example/no.srt", language: "no", label: "Norsk"
        )

        let accepted = AetherExternalSubtitleIdentity.accepted(
            [NuvioSubtitle(url: "", language: "", label: nil), english, norwegian]
        )

        XCTAssertEqual(accepted.map(\.subtitle.url), [english.url, norwegian.url])
        XCTAssertEqual(accepted.map(\.url.absoluteString), [english.url, norwegian.url])
    }

    @MainActor
    func testAetherOverlayStatePublishesClockIndependently() {
        let state = AetherSubtitleOverlayState()
        state.updateSourceTime(12.5)

        XCTAssertEqual(state.sourceTime, 12.5)
    }

    @MainActor
    func testAetherDisplaySizeAppliesAnamorphicPixelAspectRatio() {
        let size = AetherPlaybackController.displayVideoSize(
            codedWidth: 720,
            codedHeight: 576,
            pixelAspectRatio: 64.0 / 45.0
        )

        XCTAssertEqual(size.width, 1024, accuracy: 0.001)
        XCTAssertEqual(size.height, 576, accuracy: 0.001)
    }
}

final class WatchedIdentityPolicyTests: XCTestCase {
    func testMatchesCatalogAndTraktItemsAcrossIMDbAndTMDBAliases() {
        let catalog = makeMeta(id: "tmdb:94997", imdbId: "tt11198330", tmdbId: 94997)
        let trakt = makeMeta(id: "tt11198330", imdbId: "tt11198330", tmdbId: 94997)

        XCTAssertTrue(WatchedStore.sameContent(catalog, trakt))
    }

    func testDoesNotMatchDifferentTitlesThatShareAType() {
        let first = makeMeta(id: "tmdb:1", imdbId: nil, tmdbId: 1)
        let second = makeMeta(id: "tmdb:2", imdbId: nil, tmdbId: 2)

        XCTAssertFalse(WatchedStore.sameContent(first, second))
    }

    func testTraktSnapshotDoesNotDeleteWholeSeriesMarker() {
        let series = makeMeta(id: "tt11198330", imdbId: "tt11198330", tmdbId: 94997)
        let wholeSeries = WatchedStoreItem(meta: series, watchedAt: Date())
        let episode = WatchedStoreItem(meta: series, watchedAt: Date(), season: 3, episode: 4)
        let movie = WatchedStoreItem(
            meta: makeMeta(id: "tt0133093", imdbId: "tt0133093", tmdbId: 603, type: "movie"),
            watchedAt: Date()
        )

        XCTAssertFalse(WatchedStore.isRepresentedByTraktSnapshot(wholeSeries))
        XCTAssertTrue(WatchedStore.isRepresentedByTraktSnapshot(episode))
        XCTAssertTrue(WatchedStore.isRepresentedByTraktSnapshot(movie))
    }

    private func makeMeta(
        id: String,
        imdbId: String?,
        tmdbId: Int?,
        type: String = "series"
    ) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: "Test",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: imdbId,
            tmdbId: tmdbId,
            type: type,
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }
}

final class EpisodeResumeIsolationTests: XCTestCase {
    private let profileId = "episode-resume-isolation-tests"

    override func setUp() {
        super.setUp()
        ContinueWatchingStore.eraseAllProfiles()
        WatchedStore.eraseAllProfiles()
        ContinueWatchingStore.setActiveProfile(profileId)
        WatchedStore.setActiveProfile(profileId)
    }

    override func tearDown() {
        ContinueWatchingStore.eraseAllProfiles()
        WatchedStore.eraseAllProfiles()
        super.tearDown()
    }

    func testEachEpisodeKeepsItsOwnResumePoint() {
        let meta = makeSeries()
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e01.mkv",
            position: 360,
            duration: 3_000,
            season: 1,
            episode: 1,
            episodeId: "tt-test:1:1"
        )
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e02.mkv",
            position: 480,
            duration: 3_000,
            season: 1,
            episode: 2,
            episodeId: "tt-test:1:2"
        )

        XCTAssertEqual(
            ContinueWatchingStore.resumePosition(
                for: meta, season: 1, episode: 1, episodeId: "tt-test:1:1"
            ),
            360
        )
        XCTAssertEqual(
            ContinueWatchingStore.resumePosition(
                for: meta, season: 1, episode: 2, episodeId: "tt-test:1:2"
            ),
            480
        )
        XCTAssertNil(
            ContinueWatchingStore.resumePosition(
                for: meta, season: 1, episode: 3, episodeId: "tt-test:1:3"
            )
        )
    }

    func testWatchedEpisodeDoesNotResumeOlderProgress() {
        let meta = makeSeries()
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e01.mkv",
            position: 360,
            duration: 3_000,
            season: 1,
            episode: 1,
            episodeId: "tt-test:1:1"
        )
        XCTAssertTrue(WatchedStore.markWatched(meta, season: 1, episode: 1))

        XCTAssertNil(
            ContinueWatchingStore.resumePosition(
                for: meta, season: 1, episode: 1, episodeId: "tt-test:1:1"
            )
        )
    }

    func testOlderRemoteProgressCannotOverwriteNewerEpisodeResume() {
        let meta = makeSeries()
        ContinueWatchingStore.save(
            meta: meta,
            streamUrl: "https://example.test/show.s01e01.mkv",
            position: 360,
            duration: 3_000,
            season: 1,
            episode: 1,
            episodeId: "tt-test:1:1"
        )
        let staleRemote = ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: 120,
            duration: 3_000,
            lastWatchedAt: Date(timeIntervalSinceNow: -3_600),
            season: 1,
            episode: 1
        )

        XCTAssertTrue(ContinueWatchingStore.mergeRemote([staleRemote]))
        XCTAssertEqual(
            ContinueWatchingStore.resumePosition(
                for: meta, season: 1, episode: 1, episodeId: "tt-test:1:1"
            ),
            360
        )
    }

    private func makeSeries() -> NuvioMeta {
        NuvioMeta(
            id: "tt-test",
            name: "Test Series",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt-test",
            tmdbId: 123,
            type: "series",
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            videos: [
                NuvioVideo(id: "tt-test:1:1", title: "One", season: 1, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil),
                NuvioVideo(id: "tt-test:1:2", title: "Two", season: 1, episode: 2, thumbnail: nil, overview: nil, released: nil, rating: nil),
            ]
        )
    }
}
