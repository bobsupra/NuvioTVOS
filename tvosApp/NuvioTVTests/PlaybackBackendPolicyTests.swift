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
}
