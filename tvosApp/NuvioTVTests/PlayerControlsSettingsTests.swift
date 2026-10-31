import XCTest
import CoreGraphics
import UIKit
import AetherEngine
@testable import NuvioTV

private final class PlaybackTaskCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    func markCancelled() {
        lock.lock()
        _isCancelled = true
        lock.unlock()
    }
}

@MainActor
private final class PlayerControlsTestEngine: PlaybackEngineControlling {
    var onPlaybackSuspended: ((Int64, Int64) -> Void)?
    var onFirstFrameReady: (() -> Void)?
    let audioTracks: [PlaybackTrackInfo] = []
    let subtitleTracks: [PlaybackTrackInfo] = []
    var isPlayerLoading = false
    var isPlayerPlaying = false
    var isTransportPlaying = false
    var isPlayerEnded = false
    var isAtEndOfFile = false
    var hasCoherentTimeSample = false
    var hasFirstFrameReadyForDisplay = false
    var durationMs: Int64 = 0
    var positionMs: Int64 = 0
    var bufferedMs: Int64 = 0
    var currentSpeed: Float = 1
    var currentErrorMessage = ""
    var videoFrameSize = CGSize.zero
    var playbackDebugInfo = PlaybackDebugInfo(player: "Test")
    var loadingStepMessage: String?
    var supportsAudioProcessing = false
    var audioProcessingCalls: [(dialogue: EnhanceDialogueMode, reduceLoud: Bool)] = []

    func loadFile(_ urlString: String) {}
    func playPlayback() {}
    func pausePlayback() {}
    func seekToMs(_ ms: Int64) {}
    func setSpeed(_ speed: Float) {}
    func setAspectMode(_ mode: PlayerAspectMode) {}
    func setSubtitleDelay(_ seconds: Double) {}
    func setAudioDelay(_ seconds: Double) {}
    func setAudioVolumeGain(dB: Double) {}
    func setAudioProcessing(dialogue: EnhanceDialogueMode, reduceLoud: Bool) {
        audioProcessingCalls.append((dialogue, reduceLoud))
    }
    func selectAudio(_ trackId: Int) {}
    func selectSubtitle(_ trackId: Int) {}
    func addSubtitle(_ subtitle: NuvioSubtitle, select: Bool) {}
    func addAudioUrl(_ url: String) {}
    func applySubtitleStyle() {}
    func destroyPlayer() {}
    func refreshPlaybackState() {}
}

@MainActor
private final class PollingSceneFrameProvider: SceneFrameProviding {
    let isSupported = true
    let capabilityMessage: String? = nil
    private(set) var captureCount = 0
    var onCapture: ((Int) -> Void)?

    func captureCurrentFrame(maxWidth: Int, context: SceneContext) async -> SceneFrame? {
        captureCount += 1
        onCapture?(captureCount)
        return nil
    }
}

private struct EmptyPlaybackSceneCastProvider: SceneCastProviding {
    func fetchCast(context: SceneContext) async throws -> [SceneCastCandidate] { [] }
}

private struct EmptyPlaybackSceneSoundtrackProvider: SceneSoundtrackProviding {
    func fetchSoundtrack(context: SceneContext) async throws -> [SceneTimelineInterval] { [] }
}

@MainActor
private final class DeferredNextStreamResolver {
    var onStart: (() -> Void)?
    private var continuation: CheckedContinuation<PreparedNextStream?, Never>?

    func resolve() async -> PreparedNextStream? {
        onStart?()
        return await withCheckedContinuation { continuation = $0 }
    }

    func release(_ prepared: PreparedNextStream?) {
        continuation?.resume(returning: prepared)
        continuation = nil
    }
}

final class PlayerAudioProcessingTests: XCTestCase {
    @MainActor
    private func makeModel() -> PlayerViewModel {
        PlayerViewModel(sessionCoordinator: PlaybackSessionCoordinator(
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { _, _, _ in }
        ))
    }

    @MainActor
    func testUnsupportedRouteDoesNotClaimProcessingIsActive() {
        let model = makeModel()
        defer { model.shutdown() }
        model.setEnhanceDialogueMode(.boost)
        model.toggleReduceLoudSounds()
        XCTAssertEqual(model.enhanceDialogueMode, .off)
        XCTAssertFalse(model.isReduceLoudSoundsActive)

        let unsupported = PlayerControlsTestEngine()
        model.pollForTesting(using: unsupported)
        XCTAssertFalse(model.supportsAudioProcessing)
        XCTAssertTrue(unsupported.audioProcessingCalls.isEmpty)
    }

    @MainActor
    func testSelectedModesReachReplacementControllerWithTheSameCapability() {
        let model = makeModel()
        defer { model.shutdown() }
        model.enhanceDialogueMode = .boost
        model.isReduceLoudSoundsActive = true
        let original = PlayerControlsTestEngine()
        original.supportsAudioProcessing = true
        model.pollForTesting(using: original)
        model.pollForTesting(using: original)
        XCTAssertEqual(original.audioProcessingCalls.count, 1)

        let replacement = PlayerControlsTestEngine()
        replacement.supportsAudioProcessing = true
        model.pollForTesting(using: replacement)
        XCTAssertTrue(model.supportsAudioProcessing)
        XCTAssertEqual(replacement.audioProcessingCalls.count, 1)
        XCTAssertEqual(replacement.audioProcessingCalls.first?.dialogue, .boost)
        XCTAssertEqual(replacement.audioProcessingCalls.first?.reduceLoud, true)
    }

    @MainActor
    func testDecodedRouteAvailabilityReappliesSelectedModes() {
        let model = makeModel()
        defer { model.shutdown() }
        model.enhanceDialogueMode = .enhance
        model.isReduceLoudSoundsActive = true
        let controller = PlayerControlsTestEngine()
        model.pollForTesting(using: controller)
        XCTAssertTrue(controller.audioProcessingCalls.isEmpty)

        controller.supportsAudioProcessing = true
        model.pollForTesting(using: controller)
        XCTAssertTrue(model.supportsAudioProcessing)
        XCTAssertEqual(controller.audioProcessingCalls.first?.dialogue, .enhance)
        XCTAssertEqual(controller.audioProcessingCalls.first?.reduceLoud, true)

        controller.supportsAudioProcessing = false
        model.pollForTesting(using: controller)
        XCTAssertFalse(model.supportsAudioProcessing)
        XCTAssertEqual(controller.audioProcessingCalls.count, 1)
    }
}

final class ActionPlaybackSessionTests: XCTestCase {
    private let profileID = "action-playback-\(UUID().uuidString)"
    private var previousSettingsID: String?
    private var previousSettingsWerePrimary = false
    private var previousWatchedID: String?
    private var previousProgressID: String?
    private var previousContinueWatchingID: String?
    private var previousDismissID: String?
    private let meta = NuvioMeta(id: "tt-action-session", name: "Episode", type: "series", runtime: "24 min")
    private let episode = NuvioVideo(id: "tt-action-session:1:1", title: "One", season: 1, episode: 1)
    private let savedURL = "https://example.test/real-episode.mkv"

    override func setUp() {
        super.setUp()
        previousSettingsID = ProfileSettings.activeProfileID
        previousSettingsWerePrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        previousWatchedID = WatchedStore.activeProfileId
        previousProgressID = WatchProgressLedger.activeProfileId
        previousContinueWatchingID = ContinueWatchingStore.activeProfileId
        previousDismissID = ContinueWatchingDismissStore.activeProfileId
        ProfileSettings.setActiveProfile(profileID, isPrimary: false)
        WatchedStore.setActiveProfile(profileID)
        ContinueWatchingStore.setActiveProfile(profileID)
        LastPlaybackStreamStore.save(metaId: meta.id, url: savedURL, season: 1, episode: 1)
    }

    override func tearDown() {
        LastPlaybackStreamStore.remove(metaId: meta.id, season: 1, episode: 1)
        ContinueWatchingStore.eraseProfile(profileID)
        WatchedStore.eraseProfile(profileID)
        WatchedStore.setActiveProfile(previousWatchedID)
        ContinueWatchingStore.setActiveProfile(previousContinueWatchingID)
        WatchProgressLedger.setActiveProfile(previousProgressID)
        ContinueWatchingDismissStore.setActiveProfile(previousDismissID)
        if let previousSettingsID {
            ProfileSettings.setActiveProfile(previousSettingsID, isPrimary: previousSettingsWerePrimary)
        } else {
            ProfileSettings.clearActiveProfile()
        }
        UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(profileID)")
        super.tearDown()
    }

    @MainActor
    private func makeModel(isAction: Bool = true, playbackMeta: NuvioMeta? = nil,
                           playbackURL: URL? = nil, resumeFrom: Double? = 600) -> PlayerViewModel {
        let coordinator = PlaybackSessionCoordinator(
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { _, _, _ in }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator)
        model.reloadCurrentStream = { _, _ in
            XCTFail("An action must not resolve an alternative source")
            return nil
        }
        model.load(
            url: playbackURL ?? URL(fileURLWithPath: "/tmp/action-confirmation.mp4"),
            meta: playbackMeta ?? meta,
            subtitle: "S1 · E1 · One",
            resumeFrom: resumeFrom,
            playbackOrigin: .details,
            sourceID: "action-source",
            currentEpisode: (playbackMeta ?? meta).isSeries ? episode : nil,
            isActionPlaybackSession: isAction
        )
        return model
    }

    @MainActor
    private func sample(duration: Int64, position: Int64) -> PlayerControlsTestEngine {
        let engine = PlayerControlsTestEngine()
        engine.isPlayerPlaying = true
        engine.isTransportPlaying = true
        engine.hasCoherentTimeSample = true
        engine.hasFirstFrameReadyForDisplay = true
        engine.videoFrameSize = CGSize(width: 1920, height: 1080)
        engine.durationMs = duration
        engine.positionMs = position
        return engine
    }

    private func assertContentStateUnchanged(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(ContinueWatchingStore.item(for: meta.id), file: file, line: line)
        XCTAssertFalse(WatchedStore.contains(meta: meta), file: file, line: line)
        XCTAssertFalse(WatchedStore.containsEpisode(meta: meta, season: 1, episode: 1), file: file, line: line)
        XCTAssertEqual(LastPlaybackStreamStore.load(metaId: meta.id, season: 1, episode: 1)?.url, savedURL, file: file, line: line)
    }

    @MainActor
    func testMovieDurationRemainsUnknownUntilFiniteInsteadOfBecomingLive() {
        let movie = NuvioMeta(id: "tt-vod-duration", name: "Movie", type: "movie")
        let model = makeModel(playbackMeta: movie, resumeFrom: nil)
        defer { model.shutdown() }
        let engine = sample(duration: 0, position: 1_000)
        engine.hasCoherentTimeSample = false

        for _ in 0..<6 { model.pollForTesting(using: engine) }
        XCTAssertTrue(model.hasRenderedFirstFrame)
        XCTAssertEqual(model.status, .playing)
        XCTAssertFalse(model.isLiveStream, "Playing frames with unknown duration do not prove that a movie is live")
        XCTAssertEqual(model.time.duration, 0)

        engine.durationMs = 3_600_000
        engine.positionMs = 5_000
        engine.hasCoherentTimeSample = true
        for _ in 0..<2 { model.pollForTesting(using: engine) }
        XCTAssertFalse(model.isLiveStream)
        XCTAssertEqual(model.time.duration, 3_600)
    }

    @MainActor
    func testRecognizedLiveChannelStaysLiveWithUnknownOrFiniteDuration() {
        let channel = NuvioMeta(id: "channel:news", name: "News", type: "channel")
        let model = makeModel(playbackMeta: channel, resumeFrom: nil)
        defer { model.shutdown() }
        let engine = sample(duration: 0, position: 1_000)
        for _ in 0..<6 { model.pollForTesting(using: engine) }
        XCTAssertTrue(model.isLiveStream)
        engine.durationMs = 600_000
        engine.positionMs = 5_000
        for _ in 0..<2 { model.pollForTesting(using: engine) }
        XCTAssertTrue(model.isLiveStream, "A positive duration must not override an explicit channel identity")
    }

    @MainActor
    func testMovieURLHostQueryAndFragmentDoNotActAsLiveResourceHints() throws {
        let movie = NuvioMeta(id: "tt-vod-url", name: "Movie", type: "movie")
        for value in [
            "https://live.m3u8.example.test/vod/movie.mp4",
            "https://video.example.test/vod/movie.mp4?label=/live/",
            "https://video.example.test/vod/movie.mp4#live.m3u8"
        ] {
            let model = makeModel(playbackMeta: movie,
                                  playbackURL: try XCTUnwrap(URL(string: value)), resumeFrom: nil)
            defer { model.shutdown() }
            XCTAssertFalse(model.isLiveStream, "Only the resource path may supply a URL hint")
            let engine = sample(duration: 0, position: 1_000)
            for _ in 0..<6 { model.pollForTesting(using: engine) }
            XCTAssertFalse(model.isLiveStream, "Polling must not promote this source merely because duration is unknown")
        }
    }

    @MainActor
    func testLiveResourcePathsRemainRecognizedForMovieTypedAddons() throws {
        let movieTypedChannel = NuvioMeta(id: "addon-news", name: "News", type: "movie")
        for value in [
            "https://video.example.test/live/news.m3u8",
            "https://video.example.test/iptv/news.m3u8",
            "https://video.example.test/news/live.m3u8"
        ] {
            let model = makeModel(playbackMeta: movieTypedChannel,
                                  playbackURL: try XCTUnwrap(URL(string: value)), resumeFrom: nil)
            defer { model.shutdown() }
            XCTAssertTrue(model.isLiveStream, "Keep source-path hints for addons that use generic metadata types")
        }
    }

    @MainActor
    func testLiveIDAndNameHintsRemainRecognizedWithGenericMetadataTypes() {
        for item in [
            NuvioMeta(id: "iptv:news", name: "News", type: "movie"),
            NuvioMeta(id: "addon-news", name: "[Live] News", type: "series"),
            NuvioMeta(id: "pp-live:cdnlive~2558809", name: "🔴 LIVE: UFC 333 Volkanovski vs Evloev", type: "tv"),
            NuvioMeta(id: "custom:123", name: "🔴 [LIVE] Sports", type: "tv"),
            NuvioMeta(id: "addon-channel", name: "Live: Match", type: "movie"),
            NuvioMeta(id: "tv:daddylive~456", name: "Stream", type: "tv")
        ] {
            let model = makeModel(playbackMeta: item, resumeFrom: nil)
            defer { model.shutdown() }
            XCTAssertTrue(model.isLiveStream, "Failed for \(item.id) / \(item.name)")
        }
    }

    @MainActor
    func testKnownLiveHintWaitsForFiniteTimelineBeforeClearingAfterMetadataRefresh() {
        let hinted = NuvioMeta(id: "addon-news", name: "[Live] News", type: "movie")
        let model = makeModel(playbackMeta: hinted, resumeFrom: nil)
        defer { model.shutdown() }
        let engine = sample(duration: 0, position: 1_000)
        for _ in 0..<6 { model.pollForTesting(using: engine) }
        XCTAssertTrue(model.isLiveStream)

        model.activeMeta = NuvioMeta(id: "addon-news", name: "News", type: "movie")
        model.pollForTesting(using: engine)
        XCTAssertTrue(model.isLiveStream, "Missing duration must not erase an already recognized live hint")
        engine.durationMs = 600_000
        engine.hasCoherentTimeSample = true
        model.pollForTesting(using: engine)
        XCTAssertFalse(model.isLiveStream, "A coherent finite timeline may resolve the removed hint")
    }

    @MainActor
    func testShortActionPlaysAndEndsWithoutReplacementRecovery() async {
        let model = makeModel()
        defer { model.shutdown() }
        let engine = sample(duration: 5_000, position: 1_000)
        for _ in 0..<6 { model.pollForTesting(using: engine) }
        XCTAssertEqual(model.status, .playing)
        XCTAssertEqual(model.time.duration, 5)
        XCTAssertFalse(model.isReloadingStream)

        engine.positionMs = 4_900
        engine.isPlayerEnded = true
        engine.isAtEndOfFile = true
        engine.isPlayerPlaying = false
        model.pollForTesting(using: engine)
        XCTAssertEqual(model.status, .ended)
        await Task.yield()
        assertContentStateUnchanged()
    }

    @MainActor
    func testLongActionCannotTrackOrAdvanceEvenWithEpisodeCallbacks() async {
        let model = makeModel()
        defer { model.shutdown() }
        let next = NuvioVideo(id: "tt-action-session:1:2", title: "Two", season: 1, episode: 2)
        model.configureNextEpisode(
            episodes: [episode, next], current: episode,
            autoPlayEnabled: true, autoPlayCountdownSeconds: 1
        ) { _, _ in
            XCTFail("An action must not resolve the next episode")
            return nil
        }
        let engine = sample(duration: 1_440_000, position: 1_400_000)
        for _ in 0..<6 { model.pollForTesting(using: engine) }
        model.saveProgress(force: true, eventAction: .stop)
        XCTAssertNil(model.nextEpisode)
        XCTAssertFalse(model.showNextEpisodeCard)
        XCTAssertFalse(model.postPlayState.isVisible)
        XCTAssertNil(model.sessionCoordinator.playbackCompletionTracker)
        model.shutdown()
        await Task.yield()
        assertContentStateUnchanged()
    }

    @MainActor
    func testActionEngineErrorPreservesSavedEpisodeSource() async {
        let model = makeModel()
        defer { model.shutdown() }
        let engine = sample(duration: 5_000, position: 1_000)
        model.pollForTesting(using: engine)
        engine.currentErrorMessage = "Action URL failed"
        model.pollForTesting(using: engine)
        XCTAssertEqual(model.status, .error("Action URL failed"))
        model.retryCurrentPlayback()
        await Task.yield()
        XCTAssertFalse(model.isReloadingStream)
        assertContentStateUnchanged()
    }

    @MainActor
    func testOrdinaryEpisodeStillRejectsShortReplacementClip() {
        let model = makeModel(isAction: false)
        defer { model.shutdown() }
        model.reloadCurrentStream = nil
        let engine = sample(duration: 5_000, position: 1_000)
        for _ in 0..<6 { model.pollForTesting(using: engine) }
        guard case .error = model.status else {
            return XCTFail("A short replacement must still be rejected for ordinary episodes")
        }
    }
}

final class PlayerControlsSettingsTests: XCTestCase {
    func testPlayerControlsSettingsKeysDefined() {
        XCTAssertEqual(SettingsKey.playerShowPiP, "nuvio.tv.settings.playback.showPiP")
        XCTAssertEqual(SettingsKey.playerShowEpisodes, "nuvio.tv.settings.playback.showEpisodes")
        XCTAssertEqual(SettingsKey.playerShowSources, "nuvio.tv.settings.playback.showSources")
        XCTAssertEqual(SettingsKey.playerShowSubtitles, "nuvio.tv.settings.playback.showSubtitles")
        XCTAssertEqual(SettingsKey.playerShowAudio, "nuvio.tv.settings.playback.showAudio")
        XCTAssertEqual(SettingsKey.seekPreviewEnabled, "nuvio.tv.settings.playback.seekPreviewEnabled")
        XCTAssertEqual(SettingsKey.showLoadingStatus, "nuvio.tv.settings.playback.showLoadingStatus")
        XCTAssertEqual(SettingsKey.sceneFeatureEnabled, "nuvio.tv.settings.playback.sceneFeatureEnabled")
        XCTAssertEqual(SettingsKey.audioDelayPersistEnabled, "nuvio.tv.settings.playback.audioDelayPersistEnabled")
        XCTAssertEqual(SettingsKey.persistentAudioDelayMs, "nuvio.tv.settings.playback.persistentAudioDelayMs")

        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowPiP))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowEpisodes))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowSources))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowSubtitles))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowAudio))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.seekPreviewEnabled))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.showLoadingStatus))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.sceneFeatureEnabled))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.audioDelayPersistEnabled))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.persistentAudioDelayMs))
    }

    func testSubtitleStyleKeysAndDefaults() {
        XCTAssertEqual(SubtitleStyleKey.fontName, "nuvio.tv.settings.subtitleStyle.fontName")
        XCTAssertEqual(SubtitleStyleKey.textSize, "nuvio.tv.settings.subtitleStyle.textSize")
        XCTAssertEqual(SubtitleStyleKey.verticalAlignment, "nuvio.tv.settings.subtitleStyle.verticalAlignment")
        XCTAssertEqual(SubtitleStyleKey.outlineWidth, "nuvio.tv.settings.subtitleStyle.outlineWidth")

        XCTAssertTrue(SubtitleStyleKey.all.contains(SubtitleStyleKey.fontName))
        XCTAssertTrue(SubtitleStyleKey.all.contains(SubtitleStyleKey.textSize))
        XCTAssertTrue(SubtitleStyleKey.all.contains(SubtitleStyleKey.verticalAlignment))
        XCTAssertTrue(SubtitleStyleKey.all.contains(SubtitleStyleKey.outlineWidth))

        XCTAssertEqual(SubtitleStyleDefaults.fontName, "System")
        XCTAssertEqual(SubtitleStyleDefaults.textSize, 100)
        XCTAssertEqual(SubtitleStyleDefaults.verticalAlignment, "Bottom")
        XCTAssertEqual(SubtitleStyleDefaults.outlineWidth, 2)
    }

    func testSubtitleStyleSmallerSizeClampingAndScaling() {
        var style = SubtitleStyle()
        style.textSize = 5
        XCTAssertEqual(style.subScale, 0.05, accuracy: 0.001)

        let clampedMin = SubtitleStyle(textSize: min(220, max(5, 2)))
        XCTAssertEqual(clampedMin.textSize, 5)
        XCTAssertEqual(clampedMin.subScale, 0.05, accuracy: 0.001)

        let clampedMax = SubtitleStyle(textSize: min(220, max(5, 250)))
        XCTAssertEqual(clampedMax.textSize, 220)
        XCTAssertEqual(clampedMax.subScale, 2.2, accuracy: 0.001)
    }

    func testSubtitleVerticalPositionAllowsNegativeAdjustmentsAndClampsAtScreenEdge() {
        XCTAssertEqual(SubtitleStyle().subMarginY, 42)
        XCTAssertEqual(SubtitleStyle(bottomOffset: 0).subMarginY, 22)
        XCTAssertEqual(SubtitleStyle(bottomOffset: -2).subMarginY, 20)
        XCTAssertEqual(SubtitleStyle(bottomOffset: -22).subMarginY, 0)
        XCTAssertEqual(SubtitleStyle(bottomOffset: -100).subMarginY, 0)
        XCTAssertEqual(SubtitleStyle(bottomOffset: 160).subMarginY, 182)
        XCTAssertEqual(SubtitleStyle(bottomOffset: 200).subMarginY, 182)
    }

    @MainActor
    func testNegativeSubtitleVerticalPositionSurvivesReloadAndLiveApply() {
        let defaults = ProfileSettings.current
        let savedOffset = defaults.object(forKey: SubtitleStyleKey.bottomOffset)
        defer {
            if let savedOffset {
                defaults.set(savedOffset, forKey: SubtitleStyleKey.bottomOffset)
            } else {
                defaults.removeObject(forKey: SubtitleStyleKey.bottomOffset)
            }
        }

        defaults.set(-2, forKey: SubtitleStyleKey.bottomOffset)
        XCTAssertEqual(SubtitleStyle.current.bottomOffset, -2)

        let viewModel = PlayerViewModel(sessionCoordinator: PlaybackSessionCoordinator(
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { _, _, _ in }
        ))
        defer { viewModel.shutdown() }
        defaults.set(-4, forKey: SubtitleStyleKey.bottomOffset)
        viewModel.applySubtitleStyle()
        XCTAssertEqual(viewModel.subtitleStyle.bottomOffset, -4)
        XCTAssertEqual(viewModel.subtitleStyle.subMarginY, 18)
    }

    func testSubtitleStyleFontAndPositionOptions() {
        var style = SubtitleStyle()
        XCTAssertEqual(style.mpvFontName, "")

        style.fontName = "Trebuchet MS"
        XCTAssertEqual(style.mpvFontName, "Trebuchet MS")

        style.fontName = "Serif"
        XCTAssertEqual(style.mpvFontName, "Times New Roman")

        style.outlineEnabled = true
        style.outlineWidth = 3
        XCTAssertEqual(style.subOutlineSize, 4.5, accuracy: 0.001)

        style.outlineEnabled = false
        XCTAssertEqual(style.subOutlineSize, 0.0)

        style.verticalAlignment = "Top"
        XCTAssertEqual(style.verticalAlignment, "Top")
    }

    func testPromptFocusBlocksWindowInputCaptureButTimelineCaptureRemainsAllowed() {
        XCTAssertTrue(PlayerWindowInputCapturePolicy.allowsCapture(
            existingConditions: true, // Existing timeline/hidden-controls condition allows capture.
            isNextEpisodeFocused: false,
            isCancelAutoPlayFocused: false,
            isSkipSegmentFocused: false
        ))

        XCTAssertFalse(PlayerWindowInputCapturePolicy.allowsCapture(
            existingConditions: true,
            isNextEpisodeFocused: true,
            isCancelAutoPlayFocused: false,
            isSkipSegmentFocused: false
        ), "The next-episode prompt must keep the window catcher from consuming input")
        XCTAssertFalse(PlayerWindowInputCapturePolicy.allowsCapture(
            existingConditions: true,
            isNextEpisodeFocused: false,
            isCancelAutoPlayFocused: true,
            isSkipSegmentFocused: false
        ), "The cancel auto-play button must keep the window catcher from consuming input")
        XCTAssertFalse(PlayerWindowInputCapturePolicy.allowsCapture(
            existingConditions: true,
            isNextEpisodeFocused: false,
            isCancelAutoPlayFocused: false,
            isSkipSegmentFocused: true
        ), "The skip-segment prompt must keep the window catcher from consuming input")
    }

    func testPlayerControlsSettingsSyncMappings() {
        let localMappings = Dictionary(uniqueKeysWithValues: PlayerSettingsSyncMapper.localToRemoteKeyMappings)
        XCTAssertEqual(localMappings[SettingsKey.playerShowPiP], "player_show_pip")
        XCTAssertEqual(localMappings[SettingsKey.playerShowEpisodes], "player_show_episodes")
        XCTAssertEqual(localMappings[SettingsKey.playerShowSources], "player_show_sources")
        XCTAssertEqual(localMappings[SettingsKey.playerShowSubtitles], "player_show_subtitles")
        XCTAssertEqual(localMappings[SettingsKey.playerShowAudio], "player_show_audio")
        XCTAssertEqual(localMappings[SettingsKey.seekPreviewEnabled], "seek_preview_enabled")
        XCTAssertEqual(localMappings[SettingsKey.showLoadingStatus], "show_player_loading_status")

        let remoteMappings = Dictionary(uniqueKeysWithValues: PlayerSettingsSyncMapper.remoteToLocalKeyMappings)
        XCTAssertEqual(remoteMappings["player_show_pip"], SettingsKey.playerShowPiP)
        XCTAssertEqual(remoteMappings["player_show_episodes"], SettingsKey.playerShowEpisodes)
        XCTAssertEqual(remoteMappings["player_show_sources"], SettingsKey.playerShowSources)
        XCTAssertEqual(remoteMappings["player_show_subtitles"], SettingsKey.playerShowSubtitles)
        XCTAssertEqual(remoteMappings["player_show_audio"], SettingsKey.playerShowAudio)
        XCTAssertEqual(remoteMappings["seek_preview_enabled"], SettingsKey.seekPreviewEnabled)
        XCTAssertEqual(remoteMappings["show_player_loading_status"], SettingsKey.showLoadingStatus)
        XCTAssertEqual(remoteMappings["player_show_loading_status"], SettingsKey.showLoadingStatus)
    }

    func testPlayerControlsButtonDefaults() {
        let defaults = UserDefaults(suiteName: "PlayerControlsSettingsTestsDefaults")!
        defaults.removePersistentDomain(forName: "PlayerControlsSettingsTestsDefaults")

        // When unconfigured, defaults for toggles should be treated as enabled (true)
        let pipEnabled = defaults.object(forKey: SettingsKey.playerShowPiP) as? Bool ?? true
        let episodesEnabled = defaults.object(forKey: SettingsKey.playerShowEpisodes) as? Bool ?? true
        let sourcesEnabled = defaults.object(forKey: SettingsKey.playerShowSources) as? Bool ?? true
        let subtitlesEnabled = defaults.object(forKey: SettingsKey.playerShowSubtitles) as? Bool ?? true
        let audioEnabled = defaults.object(forKey: SettingsKey.playerShowAudio) as? Bool ?? true
        let seekPreviewEnabled = defaults.object(forKey: SettingsKey.seekPreviewEnabled) as? Bool ?? true
        let showLoadingStatus = defaults.object(forKey: SettingsKey.showLoadingStatus) as? Bool ?? true
        let sceneEnabled = defaults.object(forKey: SettingsKey.sceneFeatureEnabled) as? Bool ?? true

        XCTAssertTrue(pipEnabled)
        XCTAssertTrue(episodesEnabled)
        XCTAssertTrue(sourcesEnabled)
        XCTAssertTrue(subtitlesEnabled)
        XCTAssertTrue(audioEnabled)
        XCTAssertTrue(seekPreviewEnabled)
        XCTAssertTrue(showLoadingStatus)
        XCTAssertTrue(sceneEnabled)

        // When explicitly set to false, it should disable
        defaults.set(false, forKey: SettingsKey.playerShowPiP)
        defaults.set(false, forKey: SettingsKey.playerShowEpisodes)
        defaults.set(false, forKey: SettingsKey.playerShowSources)
        defaults.set(false, forKey: SettingsKey.playerShowSubtitles)
        defaults.set(false, forKey: SettingsKey.playerShowAudio)
        defaults.set(false, forKey: SettingsKey.seekPreviewEnabled)
        defaults.set(false, forKey: SettingsKey.showLoadingStatus)
        defaults.set(false, forKey: SettingsKey.sceneFeatureEnabled)

        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowPiP))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowEpisodes))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowSources))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowSubtitles))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowAudio))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.seekPreviewEnabled))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.showLoadingStatus))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.sceneFeatureEnabled))
    }

    @MainActor
    func testSceneFeatureEnabledSettingRespectsProfileSettings() {
        let profileStore = ProfileSettings.store(for: "scene-test-profile")
        let previousActiveID = ProfileSettings.activeProfileID
        ProfileSettings.setActiveProfile("scene-test-profile", isPrimary: false)
        defer {
            ProfileSettings.setActiveProfile(previousActiveID, isPrimary: true)
            UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.scene-test-profile")
        }

        let model = PlayerViewModel()

        // Default should be enabled
        XCTAssertTrue(model.isSceneEnabled)

        // When disabled via profile settings (e.g. from SettingsView via @AppStorage)
        profileStore.set(false, forKey: SettingsKey.sceneFeatureEnabled)
        XCTAssertFalse(model.isSceneEnabled)

        // openScene() should be blocked
        model.openScene()
        XCTAssertFalse(model.showScenePanel)

        // When re-enabled via setSceneEnabled
        model.setSceneEnabled(true)
        XCTAssertTrue(model.isSceneEnabled)
        XCTAssertTrue(profileStore.bool(forKey: SettingsKey.sceneFeatureEnabled))

        // Opening scene works when enabled
        model.openScene()
        XCTAssertTrue(model.showScenePanel)

        // Disabling closes open scene
        model.setSceneEnabled(false)
        XCTAssertFalse(model.isSceneEnabled)
        XCTAssertFalse(model.showScenePanel)
    }

    func testHybridSeekThumbnailPolicy() {
        XCTAssertEqual(HybridSeekThumbnailPolicy.fineBucket(for: 0), 0)
        XCTAssertEqual(HybridSeekThumbnailPolicy.fineBucket(for: 9.99), 19)
        XCTAssertNil(HybridSeekThumbnailPolicy.fineBucket(for: -1))

        let duration = 2 * 60 * 60.0
        let samples = HybridSeekThumbnailPolicy.coarseSampleTimes(duration: duration)
        XCTAssertEqual(samples.count, 120)
        XCTAssertTrue(samples.allSatisfy { $0 > 0 && $0 < duration })
        XCTAssertEqual(Set(samples).count, samples.count)
        // Balanced breadth-first ordering reaches both halves and quarters
        // before walking the full chronological sample list.
        XCTAssertTrue(samples.prefix(8).contains { $0 < duration * 0.25 })
        XCTAssertTrue(samples.prefix(8).contains { $0 > duration * 0.75 })

        XCTAssertTrue(HybridSeekThumbnailPolicy.acceptsCoarse(
            sampleSeconds: 30, targetSeconds: 38, duration: duration
        ))
        XCTAssertFalse(HybridSeekThumbnailPolicy.acceptsCoarse(
            sampleSeconds: 30, targetSeconds: 45, duration: duration
        ))
        XCTAssertFalse(HybridSeekThumbnailPolicy.acceptsCoarse(
            sampleSeconds: 30, targetSeconds: 180, duration: duration
        ))
        XCTAssertEqual(
            HybridSeekThumbnailPolicy.coarseLookupTolerance(duration: 4 * 60 * 60),
            10.0
        )
    }

    @MainActor
    func testPlaybackEntryCancelsCoarseWorkOnce() async throws {
        let controller = try XCTUnwrap(AetherPlaybackController())
        defer {
            controller.coarseThumbnailTask?.cancel()
            controller.destroyPlayer()
        }

        controller.applyPhase(.paused, engineIsBuffering: false)
        let firstProbe = PlaybackTaskCancellationProbe()
        let firstTask = makePendingThumbnailTask(probe: firstProbe)
        controller.coarseThumbnailTask = firstTask

        controller.applyPhase(.playing, engineIsBuffering: false)
        XCTAssertNil(controller.coarseThumbnailTask)
        for _ in 0..<1_000 where !firstProbe.isCancelled {
            await Task.yield()
        }
        XCTAssertTrue(firstProbe.isCancelled)

        // CombineLatest may deliver multiple updates for one .playing phase. A
        // repeated value must not cancel work started after the phase transition.
        let secondProbe = PlaybackTaskCancellationProbe()
        let secondTask = makePendingThumbnailTask(probe: secondProbe)
        controller.coarseThumbnailTask = secondTask
        controller.applyPhase(.playing, engineIsBuffering: false)
        XCTAssertFalse(secondProbe.isCancelled)
        XCTAssertNotNil(controller.coarseThumbnailTask)

        secondTask.cancel()
        await secondTask.value
        XCTAssertTrue(secondProbe.isCancelled)
    }

    private func makePendingThumbnailTask(
        probe: PlaybackTaskCancellationProbe
    ) -> Task<Void, Never> {
        Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                probe.markCancelled()
            }
        }
    }

    func testHybridSeekThumbnailIndexRejectsDistantFramesForShortAndLongSeeks() async {
        let index = HybridSeekThumbnailIndex()
        await index.reset(generation: 1)
        let image = makeTestImage()

        await index.store(image, seconds: 10, kind: .fine, generation: 1)
        let shortClose = await index.lookup(seconds: 10.4, duration: 120, generation: 1)
        let shortDistant = await index.lookup(seconds: 10.6, duration: 120, generation: 1)
        XCTAssertNotNil(shortClose)
        XCTAssertNil(shortDistant)

        await index.store(image, seconds: 1_000, kind: .coarse, generation: 1)
        let longClose = await index.lookup(seconds: 1_008, duration: 7_200, generation: 1)
        let longDistant = await index.lookup(seconds: 1_025, duration: 7_200, generation: 1)
        XCTAssertNotNil(longClose)
        XCTAssertNil(longDistant)
    }

    private func makeTestImage() -> CGImage {
        let bytes = Data([0, 0, 0, 255])
        let provider = CGDataProvider(data: bytes as CFData)!
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return CGImage(
            width: 1, height: 1,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    func testAudioRouteDescriptionHelper() {
        let title = PlaybackSystemMonitor.currentAudioOutputTitle()
        XCTAssertFalse(title.isEmpty)
        let route = PlaybackSystemMonitor.audioRouteInfo()
        XCTAssertFalse(route.isEmpty)
    }

    @MainActor
    func testAetherEngineVideoNowPlayingSessionOptIn() {
        guard let controller = AetherPlaybackController() else {
            XCTFail("AetherEngine should initialize in the test environment")
            return
        }
        XCTAssertTrue(controller.engine.ownsVideoNowPlayingSession)
        controller.destroyPlayer()
    }

    @MainActor
    func testAetherPlaybackControllerExternalSubtitleSelectionAndMapping() throws {
        guard let controller = AetherPlaybackController() else {
            XCTFail("AetherEngine should initialize in the test environment")
            return
        }
        let subtitleURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).srt")
        try Data("1\n00:00:01,000 --> 00:00:02,000\nTest subtitle\n".utf8).write(to: subtitleURL)
        defer {
            controller.destroyPlayer()
            try? FileManager.default.removeItem(at: subtitleURL)
        }
        let sub = NuvioSubtitle(url: subtitleURL.absoluteString, language: "en", label: "English Subtitle", source: "OpenSubtitles")
        controller.addSubtitle(sub, select: true)

        XCTAssertEqual(controller.subtitleTracks.count, 1)
        let track = controller.subtitleTracks.first
        XCTAssertEqual(track?.title, "English Subtitle")
        XCTAssertEqual(track?.externalFilename, subtitleURL.absoluteString)
        XCTAssertEqual(track?.selected, true)

        controller.selectSubtitle(-1)
        XCTAssertEqual(controller.subtitleTracks.first?.selected, false)

        if let id = track?.id {
            controller.selectSubtitle(id)
            XCTAssertEqual(controller.subtitleTracks.first?.selected, true)
        }
    }

    @MainActor
    func testExternalSubtitleRegistrationUsesCleanHeaders() {
        let sub = NuvioSubtitle(url: "https://example.com/sub.srt", language: "en", label: "English")
        let registration = AetherExternalSubtitleRegistration.make(
            subtitles: [sub],
            httpHeaders: ["Authorization": "Bearer secret_stream_token", "Referer": "https://stream.host/"]
        )
        XCTAssertEqual(registration.tracks.count, 1)
        XCTAssertEqual(registration.tracks.first?.httpHeaders, [:])
    }

    func testStreamAddonSubtitleDTODecodingNumericAndStringID() throws {
        let jsonNumeric = """
        {
            "url": "https://subs.strem.io/file/12345.srt",
            "lang": "eng",
            "id": 1952383625
        }
        """.data(using: .utf8)!

        let jsonString = """
        {
            "url": "https://subs.strem.io/file/67890.srt",
            "lang": "spa",
            "id": "sub-custom-id"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let dtoNumeric = try decoder.decode(StreamAddonSubtitleDTO.self, from: jsonNumeric)
        let subNumeric = dtoNumeric.toNuvioSubtitle(source: "OpenSubtitles")
        XCTAssertNotNil(subNumeric)
        XCTAssertEqual(subNumeric?.url, "https://subs.strem.io/file/12345.srt")
        XCTAssertEqual(subNumeric?.language, "eng")
        XCTAssertEqual(subNumeric?.label, "1952383625")

        let dtoString = try decoder.decode(StreamAddonSubtitleDTO.self, from: jsonString)
        let subString = dtoString.toNuvioSubtitle(source: "SubDL")
        XCTAssertNotNil(subString)
        XCTAssertEqual(subString?.url, "https://subs.strem.io/file/67890.srt")
        XCTAssertEqual(subString?.language, "spa")
        XCTAssertEqual(subString?.label, "sub-custom-id")
    }

    func testSubtitleTrackBuiltInVsExternalClassification() {
        let builtInTrack = SubtitleTrack(
            id: "1",
            name: "English [SDH]",
            language: "en",
            isSelected: false,
            externalFilename: ""
        )
        let externalTrack = SubtitleTrack(
            id: "2",
            name: "English",
            language: "en",
            isSelected: true,
            externalFilename: "https://example.com/en.srt"
        )

        XCTAssertTrue(builtInTrack.externalFilename.isEmpty)
        XCTAssertFalse(externalTrack.externalFilename.isEmpty)
    }

    @MainActor
    func testMergeExternalSubtitlesUpdatesExistingLabelsAndAppendsNew() {
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        )
        let initialSub1 = NuvioSubtitle(
            url: "https://subs.strem.io/file/1.srt",
            language: "eng",
            label: "OpenSubtitles",
            source: "OpenSubtitles v3"
        )
        let initialSub2 = NuvioSubtitle(
            url: "https://subs.strem.io/file/2.srt",
            language: "spa",
            label: nil,
            source: "OpenSubtitles v3"
        )
        model.availableExternalSubtitles = [initialSub1, initialSub2]

        let updatedSub1 = NuvioSubtitle(
            url: "https://subs.strem.io/file/1.srt",
            language: "eng",
            label: "The.Batman.2022.1080p.WEBRip.x264-RARBG",
            source: "OpenSubtitles v3"
        )
        let newSub3 = NuvioSubtitle(
            url: "https://subs.strem.io/file/3.srt",
            language: "fre",
            label: "French.Release.1080p",
            source: "SubDL"
        )

        model.mergeExternalSubtitles([updatedSub1, newSub3])

        XCTAssertEqual(model.availableExternalSubtitles.count, 3)
        XCTAssertEqual(model.availableExternalSubtitles[0].label, "The.Batman.2022.1080p.WEBRip.x264-RARBG")
        XCTAssertEqual(model.availableExternalSubtitles[1].label, nil)
        XCTAssertEqual(model.availableExternalSubtitles[2].url, "https://subs.strem.io/file/3.srt")
        XCTAssertEqual(model.availableExternalSubtitles[2].label, "French.Release.1080p")
    }

    @MainActor
    func testSmartMatchedSubtitlesReturnsAtMostOneBestMatch() {
        let savedLangs = ProfileSettings.current.string(forKey: SettingsKey.subtitleLanguages)
        let savedSmart = ProfileSettings.current.object(forKey: SettingsKey.smartSubtitleMatching)
        addTeardownBlock {
            if let savedLangs {
                ProfileSettings.current.set(savedLangs, forKey: SettingsKey.subtitleLanguages)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.subtitleLanguages)
            }
            if let savedSmart {
                ProfileSettings.current.set(savedSmart, forKey: SettingsKey.smartSubtitleMatching)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.smartSubtitleMatching)
            }
        }

        ProfileSettings.current.set(SubtitleLanguagePreferences.encode(["Czech", "English"]), forKey: SettingsKey.subtitleLanguages)
        ProfileSettings.current.set(true, forKey: SettingsKey.smartSubtitleMatching)

        let tenCzechSubtitles = (1...10).map { i in
            NuvioSubtitle(
                url: "https://titulky.com/file/\(i).srt",
                language: "cze",
                label: "Release.Czech.\(i)",
                source: "Titulky"
            )
        }
        let fiveEnglishSubtitles = (11...15).map { i in
            NuvioSubtitle(
                url: "https://opensubtitles.org/file/\(i).srt",
                language: "eng",
                label: "Release.English.\(i)",
                source: "OpenSubtitles"
            )
        }
        let allSubtitles = tenCzechSubtitles + fiveEnglishSubtitles

        let matched = PlayerViewModel.smartMatchedSubtitles(in: allSubtitles)
        XCTAssertEqual(matched.count, 1, "Smart matching must return at most one subtitle to prevent bulk download")
        XCTAssertEqual(matched.first?.url, "https://titulky.com/file/1.srt")

        let forcedEnglish = NuvioSubtitle(
            url: "https://subs.example/forced.srt", language: "eng", label: "English Forced"
        )
        let fullEnglish = NuvioSubtitle(
            url: "https://subs.example/full.srt", language: "eng", label: "English Full"
        )
        XCTAssertEqual(
            PlayerViewModel.smartMatchedSubtitles(in: [forcedEnglish, fullEnglish]).map(\.url),
            [fullEnglish.url]
        )
        XCTAssertTrue(PlayerViewModel.smartMatchedSubtitles(in: [forcedEnglish]).isEmpty)
    }

    @MainActor
    func testMergeExternalSubtitlesQueuesAtMostOneBestMatch() {
        let savedLangs = ProfileSettings.current.string(forKey: SettingsKey.subtitleLanguages)
        let savedSmart = ProfileSettings.current.object(forKey: SettingsKey.smartSubtitleMatching)
        addTeardownBlock {
            if let savedLangs {
                ProfileSettings.current.set(savedLangs, forKey: SettingsKey.subtitleLanguages)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.subtitleLanguages)
            }
            if let savedSmart {
                ProfileSettings.current.set(savedSmart, forKey: SettingsKey.smartSubtitleMatching)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.smartSubtitleMatching)
            }
        }

        ProfileSettings.current.set(SubtitleLanguagePreferences.encode(["Czech"]), forKey: SettingsKey.subtitleLanguages)
        ProfileSettings.current.set(true, forKey: SettingsKey.smartSubtitleMatching)

        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        )
        model.subtitles = [SubtitleTrack(id: "off", name: "Off", language: "", isSelected: true)]

        let tenCzechSubtitles = (1...10).map { i in
            NuvioSubtitle(
                url: "https://titulky.com/file/\(i).srt",
                language: "cze",
                label: "Release.Czech.\(i)",
                source: "Titulky"
            )
        }

        model.mergeExternalSubtitles(tenCzechSubtitles)

        XCTAssertEqual(model.availableExternalSubtitles.count, 10, "All subtitles must remain browsable in UI")
        XCTAssertEqual(model.pendingExternalSubtitles.count, 1, "Only the single best match should be queued for download, not all 10")
        XCTAssertEqual(model.pendingExternalSubtitles.first?.url, "https://titulky.com/file/1.srt")
    }

    @MainActor
    func testMergeExternalSubtitlesDoesNotQueueWhenPreferredSubtitleAlreadyActive() {
        let savedLangs = ProfileSettings.current.string(forKey: SettingsKey.subtitleLanguages)
        let savedSmart = ProfileSettings.current.object(forKey: SettingsKey.smartSubtitleMatching)
        addTeardownBlock {
            if let savedLangs {
                ProfileSettings.current.set(savedLangs, forKey: SettingsKey.subtitleLanguages)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.subtitleLanguages)
            }
            if let savedSmart {
                ProfileSettings.current.set(savedSmart, forKey: SettingsKey.smartSubtitleMatching)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.smartSubtitleMatching)
            }
        }

        ProfileSettings.current.set(SubtitleLanguagePreferences.encode(["Czech"]), forKey: SettingsKey.subtitleLanguages)
        ProfileSettings.current.set(true, forKey: SettingsKey.smartSubtitleMatching)

        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        )
        model.subtitles = [
            SubtitleTrack(id: "off", name: "Off", language: "", isSelected: false),
            SubtitleTrack(id: "1", name: "Czech (Embedded)", language: "cze", isSelected: true)
        ]

        let tenCzechSubtitles = (1...10).map { i in
            NuvioSubtitle(
                url: "https://titulky.com/file/\(i).srt",
                language: "cze",
                label: "Release.Czech.\(i)",
                source: "Titulky"
            )
        }

        model.mergeExternalSubtitles(tenCzechSubtitles)

        XCTAssertEqual(model.availableExternalSubtitles.count, 10)
        XCTAssertEqual(model.pendingExternalSubtitles.count, 0, "No external subtitles should be queued when embedded preferred track is active")
    }

    @MainActor
    func testLateExternalSubtitlesUseForcedPolicyWhenPreferredAudioIsSelected() {
        let savedLangs = ProfileSettings.current.string(forKey: SettingsKey.subtitleLanguages)
        let savedSmart = ProfileSettings.current.object(forKey: SettingsKey.smartSubtitleMatching)
        let savedAudioLanguage = ProfileSettings.current.string(forKey: SettingsKey.audioLanguage)
        let savedForced = ProfileSettings.current.object(forKey: SettingsKey.forcedSubtitles)
        addTeardownBlock {
            if let savedLangs {
                ProfileSettings.current.set(savedLangs, forKey: SettingsKey.subtitleLanguages)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.subtitleLanguages)
            }
            if let savedSmart {
                ProfileSettings.current.set(savedSmart, forKey: SettingsKey.smartSubtitleMatching)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.smartSubtitleMatching)
            }
            if let savedAudioLanguage {
                ProfileSettings.current.set(savedAudioLanguage, forKey: SettingsKey.audioLanguage)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.audioLanguage)
            }
            if let savedForced {
                ProfileSettings.current.set(savedForced, forKey: SettingsKey.forcedSubtitles)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.forcedSubtitles)
            }
        }

        ProfileSettings.current.set(SubtitleLanguagePreferences.encode(["English"]), forKey: SettingsKey.subtitleLanguages)
        ProfileSettings.current.set("English", forKey: SettingsKey.audioLanguage)
        ProfileSettings.current.set(true, forKey: SettingsKey.smartSubtitleMatching)
        ProfileSettings.current.set(true, forKey: SettingsKey.forcedSubtitles)

        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        )
        model.audioTracks = [AudioTrack(id: "1", name: "English", language: "eng", isSelected: true)]
        model.subtitles = [
            SubtitleTrack(id: "off", name: "Off", language: "", isSelected: false),
            SubtitleTrack(id: "2", name: "English Full", language: "eng", isSelected: true)
        ]

        let full = NuvioSubtitle(url: "https://subs.example/full.srt", language: "eng", label: "English Full")
        let forced = NuvioSubtitle(url: "https://subs.example/forced.srt", language: "eng", label: "English Forced")
        model.mergeExternalSubtitles([full, forced])

        XCTAssertEqual(model.pendingExternalSubtitles.map(\.url), [forced.url])
        XCTAssertEqual(model.subtitles.first(where: { $0.isSelected })?.id, "off")
    }

    @MainActor
    func testLateExternalSubtitlesSelectPreferredEmbeddedLanguageWithOrderedFallback() {
        let savedLangs = ProfileSettings.current.string(forKey: SettingsKey.subtitleLanguages)
        let savedAudioLanguage = ProfileSettings.current.string(forKey: SettingsKey.audioLanguage)
        let savedSmart = ProfileSettings.current.object(forKey: SettingsKey.smartSubtitleMatching)
        let savedForced = ProfileSettings.current.object(forKey: SettingsKey.forcedSubtitles)
        addTeardownBlock {
            if let savedLangs {
                ProfileSettings.current.set(savedLangs, forKey: SettingsKey.subtitleLanguages)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.subtitleLanguages)
            }
            if let savedAudioLanguage {
                ProfileSettings.current.set(savedAudioLanguage, forKey: SettingsKey.audioLanguage)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.audioLanguage)
            }
            if let savedSmart {
                ProfileSettings.current.set(savedSmart, forKey: SettingsKey.smartSubtitleMatching)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.smartSubtitleMatching)
            }
            if let savedForced {
                ProfileSettings.current.set(savedForced, forKey: SettingsKey.forcedSubtitles)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.forcedSubtitles)
            }
        }

        ProfileSettings.current.set(SubtitleLanguagePreferences.encode(["English", "Arabic"]), forKey: SettingsKey.subtitleLanguages)
        ProfileSettings.current.set("English", forKey: SettingsKey.audioLanguage)
        ProfileSettings.current.set(true, forKey: SettingsKey.smartSubtitleMatching)
        ProfileSettings.current.set(false, forKey: SettingsKey.forcedSubtitles)

        let englishExternal = NuvioSubtitle(
            url: "https://subs.example/english.srt",
            language: "eng",
            label: "English Full"
        )
        let cases: [(tracks: [SubtitleTrack], expectedID: String)] = [
            (
                [
                    SubtitleTrack(id: "2", name: "English Full", language: "eng", isSelected: false),
                    SubtitleTrack(id: "3", name: "Arabic Full", language: "ara", isSelected: false)
                ],
                "2"
            ),
            (
                [SubtitleTrack(id: "3", name: "Arabic Full", language: "ara", isSelected: false)],
                "3"
            )
        ]

        for testCase in cases {
            let model = PlayerViewModel(
                sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil })
            )
            model.audioTracks = [AudioTrack(id: "1", name: "English", language: "eng", isSelected: true)]
            model.subtitles = [
                SubtitleTrack(id: "off", name: "Off", language: "", isSelected: true)
            ] + testCase.tracks

            model.mergeExternalSubtitles([englishExternal])

            XCTAssertEqual(model.subtitles.first(where: { $0.isSelected })?.id, testCase.expectedID)
            XCTAssertTrue(model.pendingExternalSubtitles.isEmpty)
        }
    }

    @MainActor
    func testMergeExternalSubtitlesDoesNotQueueWhenExplicitSelectionMade() {
        let savedLangs = ProfileSettings.current.string(forKey: SettingsKey.subtitleLanguages)
        let savedSmart = ProfileSettings.current.object(forKey: SettingsKey.smartSubtitleMatching)
        addTeardownBlock {
            if let savedLangs {
                ProfileSettings.current.set(savedLangs, forKey: SettingsKey.subtitleLanguages)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.subtitleLanguages)
            }
            if let savedSmart {
                ProfileSettings.current.set(savedSmart, forKey: SettingsKey.smartSubtitleMatching)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.smartSubtitleMatching)
            }
        }

        ProfileSettings.current.set(SubtitleLanguagePreferences.encode(["Czech"]), forKey: SettingsKey.subtitleLanguages)
        ProfileSettings.current.set(true, forKey: SettingsKey.smartSubtitleMatching)

        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        )
        model.hasExplicitSubtitleSelection = true

        let tenCzechSubtitles = (1...10).map { i in
            NuvioSubtitle(
                url: "https://titulky.com/file/\(i).srt",
                language: "cze",
                label: "Release.Czech.\(i)",
                source: "Titulky"
            )
        }

        model.mergeExternalSubtitles(tenCzechSubtitles)

        XCTAssertEqual(model.availableExternalSubtitles.count, 10)
        XCTAssertEqual(model.pendingExternalSubtitles.count, 0, "No external subtitles should be queued when user has explicitly selected subtitle state")
    }

    @MainActor
    func testMergeExternalSubtitlesUpdatesLoadedTrackNameInPlace() {
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        )
        let initialSub = NuvioSubtitle(
            url: "https://subs.strem.io/file/1.srt",
            language: "eng",
            label: "OpenSubtitles",
            source: "OpenSubtitles v3"
        )
        model.availableExternalSubtitles = [initialSub]
        model.subtitles = [
            SubtitleTrack(
                id: "1",
                name: "OpenSubtitles",
                language: "eng",
                isSelected: true,
                externalFilename: "https://subs.strem.io/file/1.srt"
            )
        ]

        let updatedSub = NuvioSubtitle(
            url: "https://subs.strem.io/file/1.srt",
            language: "eng",
            label: "Batman.2022.Proper.WEBRip",
            source: "OpenSubtitles v3"
        )

        model.mergeExternalSubtitles([updatedSub])

        XCTAssertEqual(model.availableExternalSubtitles[0].label, "Batman.2022.Proper.WEBRip")
        XCTAssertEqual(model.subtitles[0].name, "Batman.2022.Proper.WEBRip", "Loaded track name must be updated in-place")
    }

    @MainActor
    func testWatchPartyChatToastRespectsUserPreference() {
        let coordinator = PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        let model = PlayerViewModel(
            sessionCoordinator: coordinator,
            scrubThumbnailProvider: nil
        )

        let chatMessage = WatchPartyChatMessage(
            id: 42,
            memberID: "friend-1",
            name: "Bob",
            avatarURL: "https://example.com/avatar.jpg",
            avatarColor: "#00FF00",
            body: "Great movie!"
        )

        // 1. By default (no setting stored), toasts are enabled
        ProfileSettings.current.removeObject(forKey: SettingsKey.partyChatToastsEnabled)
        defer {
            ProfileSettings.current.removeObject(forKey: SettingsKey.partyChatToastsEnabled)
        }

        model.handleWatchPartyChatMessage(chatMessage)
        XCTAssertNotNil(model.playerToast)
        XCTAssertEqual(model.playerToast?.message, "Great movie!")
        XCTAssertEqual(model.playerToast?.senderName, "Bob")
        XCTAssertEqual(model.playerToast?.avatarColor, "#00FF00")
        XCTAssertEqual(model.playerToast?.initials, "B")

        // 2. When disabled in settings, chat messages do not trigger toast
        model.playerToast = nil
        ProfileSettings.current.set(false, forKey: SettingsKey.partyChatToastsEnabled)

        model.handleWatchPartyChatMessage(chatMessage)
        XCTAssertNil(model.playerToast)

        // 3. When explicitly re-enabled, toast triggers again
        ProfileSettings.current.set(true, forKey: SettingsKey.partyChatToastsEnabled)

        model.handleWatchPartyChatMessage(chatMessage)
        XCTAssertNotNil(model.playerToast)
        XCTAssertEqual(model.playerToast?.message, "Great movie!")
        XCTAssertEqual(model.playerToast?.senderName, "Bob")
    }
}
@MainActor
private final class ControlledScrubThumbnailProvider: ScrubThumbnailProviding {
    var supportsScrubThumbnails = true
    var decode: (Double, Bool) async -> CGImage? = { _, _ in nil }
    func cachedScrubThumbnail(atSeconds seconds: Double, duration: Double) async -> CGImage? { nil }
    func scrubThumbnail(atSeconds seconds: Double, maxWidth: Int, precise: Bool) async -> CGImage? {
        await decode(seconds, precise)
    }
}

extension PlayerControlsSettingsTests {
    @MainActor
    func testScrubThumbnailProviderIsReachedOnMPVBackend() async {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.seekPreviewEnabled)
        defaults.set(true, forKey: SettingsKey.seekPreviewEnabled)
        defer { defaults.set(previous, forKey: SettingsKey.seekPreviewEnabled) }

        let provider = ControlledScrubThumbnailProvider()
        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil },
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { _, _, _ in }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator, scrubThumbnailProvider: provider)
        defer { model.pendingSeekDelta = 0; coordinator.stopAll() }

        coordinator.load(PlaybackLoadRequest(videoURL: URL(fileURLWithPath: "/tmp/mpv-preview.mkv")))
        coordinator.onHandoffToast?("Compatibility player enabled")
        XCTAssertEqual(coordinator.activeBackend, .mpv)
        XCTAssertEqual(model.activeEngineKind, .mpv)

        let image = makeTestImage()
        let published = expectation(description: "MPV scrub provider frame reaches the preview")
        let subscription = model.$scrubThumbnail.sink { candidate in
            if candidate === image { published.fulfill() }
        }
        defer { subscription.cancel() }
        provider.decode = { _, precise in
            guard !precise else { return nil }
            return image
        }
        model.pendingSeekDelta = 1
        model.requestScrubThumbnail(at: 42)
        await fulfillment(of: [published], timeout: 3)
        XCTAssertTrue(model.scrubThumbnail === image)
    }

    @MainActor
    func testLateScrubThumbnailIsDiscardedAcrossMPVHandoff() async {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.seekPreviewEnabled)
        defaults.set(true, forKey: SettingsKey.seekPreviewEnabled)
        defer { defaults.set(previous, forKey: SettingsKey.seekPreviewEnabled) }

        let provider = ControlledScrubThumbnailProvider()
        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil },
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { _, _, _ in }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator, scrubThumbnailProvider: provider)
        defer { model.pendingSeekDelta = 0; coordinator.stopAll() }

        let started = expectation(description: "Old backend preview is in flight")
        var continuation: CheckedContinuation<CGImage?, Never>?
        provider.decode = { _, precise in
            guard !precise else { return nil }
            started.fulfill()
            return await withCheckedContinuation { continuation = $0 }
        }
        model.pendingSeekDelta = 1
        model.requestScrubThumbnail(at: 42)
        await fulfillment(of: [started], timeout: 3)

        coordinator.load(PlaybackLoadRequest(videoURL: URL(fileURLWithPath: "/tmp/mpv-preview-next.mkv")))
        coordinator.onHandoffToast?("Compatibility player enabled")
        XCTAssertEqual(model.activeEngineKind, .mpv)
        continuation?.resume(returning: makeTestImage())
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(model.scrubThumbnail, "A late preview from the prior backend must not repopulate the overlay")
    }

    @MainActor
    func testAetherBoundedScrubPreviewAdmitsKnownProgressiveVODOnly() {
        let suffixless = URL(string: "https://cdn.example.test/download/abc123")!
        XCTAssertTrue(AetherPlaybackController.shouldUseBoundedProgressiveScrubPreview(
            requestIsLive: false, engineIsLive: false, route: .loopback,
            isKnownHLS: false, sourceURL: suffixless, sourceContainerFormat: "matroska,webm"))
        XCTAssertFalse(AetherPlaybackController.shouldUseBoundedProgressiveScrubPreview(
            requestIsLive: false, engineIsLive: false, route: .loopback,
            isKnownHLS: false, sourceURL: suffixless, sourceContainerFormat: nil))
        XCTAssertFalse(AetherPlaybackController.shouldUseBoundedProgressiveScrubPreview(
            requestIsLive: false, engineIsLive: false, route: .remoteBypass,
            isKnownHLS: false, sourceURL: suffixless, sourceContainerFormat: "matroska"))
        XCTAssertFalse(AetherPlaybackController.shouldUseBoundedProgressiveScrubPreview(
            requestIsLive: true, engineIsLive: false, route: .loopback,
            isKnownHLS: false, sourceURL: suffixless, sourceContainerFormat: "matroska"))
        XCTAssertFalse(AetherPlaybackController.shouldUseBoundedProgressiveScrubPreview(
            requestIsLive: false, engineIsLive: true, route: .loopback,
            isKnownHLS: false, sourceURL: suffixless, sourceContainerFormat: "matroska"))
        XCTAssertFalse(AetherPlaybackController.shouldUseBoundedProgressiveScrubPreview(
            requestIsLive: false, engineIsLive: false, route: .loopback,
            isKnownHLS: true, sourceURL: suffixless, sourceContainerFormat: "matroska"))
        XCTAssertFalse(AetherPlaybackController.shouldUseBoundedProgressiveScrubPreview(
            requestIsLive: false, engineIsLive: false, route: .loopback,
            isKnownHLS: false, sourceURL: URL(fileURLWithPath: "/tmp/disc.iso"),
            sourceContainerFormat: "matroska"))
    }

    @MainActor
    func testAetherBoundedScrubFrameRequiresAccurateActualTimeAndValidRange() {
        let image = makeTestImage()
        let frame = ScrubFrame(image: image, actualSeconds: 42.25, refined: true, validRange: 40..<45)
        XCTAssertTrue(AetherPlaybackController.acceptsBoundedScrubFrame(frame, at: 42))
        XCTAssertFalse(AetherPlaybackController.acceptsBoundedScrubFrame(frame, at: 42.8))
        XCTAssertFalse(AetherPlaybackController.acceptsBoundedScrubFrame(frame, at: 46))

        let invalidTime = ScrubFrame(image: image, actualSeconds: .infinity, refined: true, validRange: nil)
        XCTAssertFalse(AetherPlaybackController.acceptsBoundedScrubFrame(invalidTime, at: 42))
        XCTAssertFalse(AetherPlaybackController.acceptsBoundedScrubFrame(nil, at: 42))
    }

    @MainActor
    func testAetherResidentFrameAvoidsFallbackAndKeepsActualTimestamp() async {
        let image = makeTestImage()
        var cleanupCount = 0
        var fallbackCount = 0
        let result = await AetherPlaybackController.boundedProgressiveScrubFrame(
            at: 42,
            resident: {
                ScrubFrame(image: image, actualSeconds: 42.25, refined: true, validRange: 40..<45)
            },
            ownsSource: { true },
            cleanup: { cleanupCount += 1 },
            isCurrent: { true },
            fallback: {
                fallbackCount += 1
                return nil
            })

        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(fallbackCount, 0)
        XCTAssertTrue(result?.image === image)
        XCTAssertEqual(result?.actualSeconds, 42.25)
    }

    @MainActor
    func testAetherMissingAndInaccurateResidentFramesFallbackAfterCleanup() async {
        let image = makeTestImage()
        let residentFrames: [ScrubFrame?] = [
            nil,
            ScrubFrame(image: image, actualSeconds: 42.8, refined: false, validRange: 40..<45),
        ]
        for residentFrame in residentFrames {
            var events: [String] = []
            let fallbackImage = makeTestImage()
            let result = await AetherPlaybackController.boundedProgressiveScrubFrame(
                at: 42,
                resident: {
                    events.append("resident")
                    return residentFrame
                },
                ownsSource: {
                    events.append("ownsSource")
                    return true
                },
                cleanup: { events.append("cleanup") },
                isCurrent: {
                    events.append("current")
                    return true
                },
                fallback: {
                    events.append("fallback")
                    return BoundedStillFrame(image: fallbackImage, actualSeconds: 42.1)
                })

            XCTAssertEqual(events, ["resident", "ownsSource", "cleanup", "current", "fallback"])
            XCTAssertTrue(result?.image === fallbackImage)
            XCTAssertEqual(result?.actualSeconds, 42.1)
        }
    }

    @MainActor
    func testAetherWaitsForCleanupBeforeStartingFallback() async {
        let image = makeTestImage()
        let cleanupStarted = expectation(description: "Resident decoder cleanup started")
        var cleanupContinuation: CheckedContinuation<Void, Never>?
        var fallbackStarted = false
        let operation = Task {
            await AetherPlaybackController.boundedProgressiveScrubFrame(
                at: 42,
                resident: { nil },
                ownsSource: { true },
                cleanup: {
                    cleanupStarted.fulfill()
                    await withCheckedContinuation { cleanupContinuation = $0 }
                },
                isCurrent: { true },
                fallback: {
                    fallbackStarted = true
                    return BoundedStillFrame(image: image, actualSeconds: 42)
                })
        }
        await fulfillment(of: [cleanupStarted], timeout: 2)
        XCTAssertFalse(fallbackStarted)
        cleanupContinuation?.resume()

        let result = await operation.value
        XCTAssertTrue(fallbackStarted)
        XCTAssertTrue(result?.image === image)
    }

    @MainActor
    func testAetherSameSourceCancellationCleansButSourceReplacementSkipsCleanup() async {
        let image = makeTestImage()
        var cleanupCount = 0
        var fallbackCount = 0
        let cancelled = await AetherPlaybackController.boundedProgressiveScrubFrame(
            at: 42,
            resident: { nil },
            ownsSource: { true },
            cleanup: { cleanupCount += 1 },
            isCurrent: { false },
            fallback: {
                fallbackCount += 1
                return BoundedStillFrame(image: image, actualSeconds: 42)
            })
        XCTAssertNil(cancelled)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(fallbackCount, 0)

        let replaced = await AetherPlaybackController.boundedProgressiveScrubFrame(
            at: 42,
            resident: { nil },
            ownsSource: { false },
            cleanup: { cleanupCount += 1 },
            isCurrent: { true },
            fallback: {
                fallbackCount += 1
                return BoundedStillFrame(image: image, actualSeconds: 42)
            })
        XCTAssertNil(replaced)
        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(fallbackCount, 0)
    }

    @MainActor
    func testSlowPreviewPublishesWhileNewerSeekIsPendingThenRefines() async {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.seekPreviewEnabled)
        defaults.set(true, forKey: SettingsKey.seekPreviewEnabled)
        defer { defaults.set(previous, forKey: SettingsKey.seekPreviewEnabled) }
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        model.pendingSeekDelta = 1
        defer { model.pendingSeekDelta = 0; model.setTimelineFocused(false) }
        let first = makeTestImage()
        let second = makeTestImage()
        let precise = makeTestImage()
        let started = expectation(description: "First slow decode started")
        let latestStarted = expectation(description: "Newest decode started")
        let refined = expectation(description: "Settled target published precise frame")
        var firstContinuation: CheckedContinuation<CGImage?, Never>?
        var secondContinuation: CheckedContinuation<CGImage?, Never>?
        provider.decode = { seconds, isPrecise in
            if isPrecise { return precise }
            return await withCheckedContinuation { continuation in
                if seconds == 10 {
                    firstContinuation = continuation
                    started.fulfill()
                } else {
                    secondContinuation = continuation
                    latestStarted.fulfill()
                }
            }
        }
        let subscription = model.$scrubThumbnail.sink { image in
            if image === precise { refined.fulfill() }
        }
        defer { subscription.cancel() }
        model.requestScrubThumbnail(at: 10)
        await fulfillment(of: [started], timeout: 2)
        model.requestScrubThumbnail(at: 100)
        firstContinuation?.resume(returning: first)
        await fulfillment(of: [latestStarted], timeout: 2)
        XCTAssertTrue(model.scrubThumbnail === first, "Movement must not discard every completed frame")
        secondContinuation?.resume(returning: second)
        await fulfillment(of: [refined], timeout: 2)
        XCTAssertTrue(model.scrubThumbnail === precise)
    }

    @MainActor
    func testMissingPreviewRetriesWithoutAnotherRemotePressAndStops() async {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.seekPreviewEnabled)
        defaults.set(true, forKey: SettingsKey.seekPreviewEnabled)
        defer { defaults.set(previous, forKey: SettingsKey.seekPreviewEnabled) }
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        model.pendingSeekDelta = 1
        defer { model.pendingSeekDelta = 0; model.setTimelineFocused(false) }
        let attempted = expectation(description: "Three fast/precise attempts")
        var calls = 0
        provider.decode = { _, _ in
            calls += 1
            if calls == 6 { attempted.fulfill() }
            return nil
        }
        model.requestScrubThumbnail(at: 10)
        await fulfillment(of: [attempted], timeout: 4)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls, 6)
        XCTAssertNil(model.scrubThumbnail)
    }

    @MainActor
    func testResetDuringSettleCancelsPrecisePreview() async {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.seekPreviewEnabled)
        defaults.set(true, forKey: SettingsKey.seekPreviewEnabled)
        defer { defaults.set(previous, forKey: SettingsKey.seekPreviewEnabled) }
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        model.pendingSeekDelta = 1
        let fast = makeTestImage()
        let published = expectation(description: "Fast frame visible")
        var preciseCalls = 0
        provider.decode = { _, precise in
            if precise { preciseCalls += 1 }
            return fast
        }
        let subscription = model.$scrubThumbnail.sink { image in
            if image === fast { published.fulfill() }
        }
        defer { subscription.cancel() }
        model.requestScrubThumbnail(at: 10)
        await fulfillment(of: [published], timeout: 2)
        model.pendingSeekDelta = 0
        model.setTimelineFocused(false)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(preciseCalls, 0)
        XCTAssertNil(model.scrubThumbnail)
    }

    func testTrickplayDiskCacheStoreAndLookup() async {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = TrickplayDiskCache(directoryOverride: tempDir)
        let streamKey = "test_stream_123"
        let testImage = makeTestImage()

        // 1. Initially empty
        let initial = await cache.lookup(streamKey: streamKey, seconds: 15)
        XCTAssertNil(initial)

        // 2. Store at second 15
        await cache.store(image: testImage, streamKey: streamKey, seconds: 15)

        // 3. Exact match
        let exact = await cache.lookup(streamKey: streamKey, seconds: 15)
        XCTAssertNotNil(exact)

        // 4. Match within tolerance
        let near = await cache.lookup(streamKey: streamKey, seconds: 16, tolerance: 2.0)
        XCTAssertNotNil(near)

        // 5. Miss outside tolerance
        let far = await cache.lookup(streamKey: streamKey, seconds: 40, tolerance: 2.0)
        XCTAssertNil(far)

        // 6. Clear
        await cache.clear(streamKey: streamKey)
        let afterClear = await cache.lookup(streamKey: streamKey, seconds: 15)
        XCTAssertNil(afterClear)

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testWebVTTStoryboardParsing() {
        let vtt = """
        WEBVTT

        00:00:00.000 --> 00:00:10.000
        spritesheet.jpg#xywh=0,0,160,90

        00:00:10.000 --> 00:00:20.000
        spritesheet.jpg#xywh=160,0,160,90
        """
        let base = URL(string: "https://example.com/media/storyboard.vtt")!
        let provider = WebVTTStoryboardProvider.parse(vttContent: vtt, baseURL: base)
        XCTAssertNotNil(provider)
    }

    func testTrickplayCanonicalKeyStability() {
        // Different debrid URLs with expired/different tokens for the same movie cut
        let url1 = "https://debrid.example.com/stream/tokenA/movie.mkv"
        let url2 = "https://debrid.example.com/stream/tokenB/movie.mkv"

        let key1 = TrickplayDiskCache.canonicalKey(
            contentId: "tt15239678",
            season: 1,
            episode: 4,
            duration: 2582.0,
            fallbackURL: url1
        )

        let key2 = TrickplayDiskCache.canonicalKey(
            contentId: "tt15239678",
            season: 1,
            episode: 4,
            duration: 2588.0, // Tolerates variance within 30-second bucket (2580)
            fallbackURL: url2
        )

        // Must match identically despite different URLs and slightly different durations
        XCTAssertEqual(key1, key2)
        XCTAssertTrue(key1.hasPrefix("canon_"))

        // Different episode must produce different key
        let keyEpisode5 = TrickplayDiskCache.canonicalKey(
            contentId: "tt15239678",
            season: 1,
            episode: 5,
            duration: 2582.0,
            fallbackURL: url1
        )
        XCTAssertNotEqual(key1, keyEpisode5)

        // Different movie must produce different key
        let keyOtherMovie = TrickplayDiskCache.canonicalKey(
            contentId: "tt9999999",
            season: 0,
            episode: 0,
            duration: 7200.0,
            fallbackURL: url1
        )
        XCTAssertNotEqual(key1, keyOtherMovie)

        // Fallback when contentId is empty
        let fallbackKey = TrickplayDiskCache.canonicalKey(
            contentId: nil,
            duration: 100,
            fallbackURL: url1
        )
        XCTAssertFalse(fallbackKey.hasPrefix("canon_"))

        // Release cut separation: 22-second difference (e.g. 7264s vs 7286s) must produce different buckets (7260 vs 7280)
        let releaseA = TrickplayDiskCache.canonicalKey(
            contentId: "tt1234567",
            duration: 7264.0,
            fallbackURL: url1
        )
        let releaseB = TrickplayDiskCache.canonicalKey(
            contentId: "tt1234567",
            duration: 7286.0,
            fallbackURL: url2
        )
        XCTAssertNotEqual(releaseA, releaseB, "10-second bucketing must isolate releases with 22-second cut differences")
    }

    func testTrickplayStoryboardBuilder() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create 15 dummy jpeg files
        var frames: [(seconds: Double, fileURL: URL)] = []
        let testImage = UIImage(cgImage: makeTestImage())
        let testData = testImage.jpegData(compressionQuality: 0.8)!

        for sec in stride(from: 0.0, through: 140.0, by: 10.0) {
            let fileURL = tempDir.appendingPathComponent("\(Int(sec)).jpg")
            try? testData.write(to: fileURL)
            frames.append((seconds: sec, fileURL: fileURL))
        }

        let bundle = TrickplayStoryboardBuilder.buildStoryboard(
            frames: frames,
            duration: 150.0,
            columns: 10,
            thumbWidth: 160,
            thumbHeight: 90
        )

        XCTAssertNotNil(bundle)
        guard let bundle else { return }
        XCTAssertEqual(bundle.frameCount, 15)
        XCTAssertFalse(bundle.spriteJPEGData.isEmpty)
        XCTAssertTrue(bundle.vttContent.contains("WEBVTT"))
        XCTAssertTrue(bundle.vttContent.contains("sprite.jpg#xywh=0,0,160,90"))
        XCTAssertTrue(bundle.vttContent.contains("sprite.jpg#xywh=160,0,160,90"))
    }

    func testHybridSeekThumbnailIndexNearestRAMFallback() async {
        let index = HybridSeekThumbnailIndex()
        let testImage = makeTestImage()

        await index.reset(generation: 1, streamKey: "test_key")

        // Store a coarse frame at 14:00 (840s)
        await index.store(testImage, seconds: 840, kind: .coarse, generation: 1, persistToDisk: false)

        // Lookup at 14:05 (845s) with 2-hour movie duration
        // Exact fine bucket is missing, but Tier 3 nearest RAM should return the 840s frame
        let hit = await index.lookup(seconds: 845, duration: 7200, generation: 1)
        XCTAssertNotNil(hit, "Tier 3 must provide immediate nearest RAM fallback")
    }

    @MainActor
    func testDistantScrubClearsStaleThumbnailOnMiss() async {
        let defaults = ProfileSettings.current
        let previous = defaults.object(forKey: SettingsKey.seekPreviewEnabled)
        defaults.set(true, forKey: SettingsKey.seekPreviewEnabled)
        defer { defaults.set(previous, forKey: SettingsKey.seekPreviewEnabled) }
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        model.pendingSeekDelta = 1
        defer { model.pendingSeekDelta = 0; model.setTimelineFocused(false) }

        let initialImage = makeTestImage()
        var returnInitial = true
        let initialPublished = expectation(description: "Initial image published")
        provider.decode = { seconds, isPrecise in
            if returnInitial { return initialImage }
            return nil
        }
        let subscription = model.$scrubThumbnail.sink { image in
            if image === initialImage { initialPublished.fulfill() }
        }
        defer { subscription.cancel() }

        // 1. Initial preview at 10s
        model.requestScrubThumbnail(at: 10)
        await fulfillment(of: [initialPublished], timeout: 2)
        XCTAssertTrue(model.scrubThumbnail === initialImage)

        // 2. Distant scrub to 300s (5 minutes away) where provider returns nil
        returnInitial = false
        model.requestScrubThumbnail(at: 300)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Stale still from 10s must be cleared so the preview card doesn't appear frozen on an ancient frame
        XCTAssertNil(model.scrubThumbnail, "Distant seek miss must clear ancient thumbnail")
    }

    @MainActor
    func testDiscreteNudgeLinearAccumulationAndNoThumbnail() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        defer { model.commitPendingSeekIfNeeded(); model.pendingSeekDelta = 0 }
        model.seekStepSeconds = 10
        model.time = PlayerTime(current: 100, duration: 1000)
        model.status = .playing

        // Discrete tap: linear accumulation without streak acceleration
        model.nudgeSeek(10)
        XCTAssertEqual(model.pendingSeekDelta, 10)
        XCTAssertFalse(model.isHoldingSeek)
        XCTAssertNil(model.seekSpeedMultiplier)
        XCTAssertNil(model.scrubThumbnail)

        model.nudgeSeek(10)
        XCTAssertEqual(model.pendingSeekDelta, 20)
        XCTAssertFalse(model.isHoldingSeek)
        XCTAssertNil(model.seekSpeedMultiplier)
        XCTAssertNil(model.scrubThumbnail)

        model.nudgeSeek(10)
        XCTAssertEqual(model.pendingSeekDelta, 30)
        XCTAssertFalse(model.isHoldingSeek)
        XCTAssertNil(model.seekSpeedMultiplier)
        XCTAssertNil(model.scrubThumbnail)
    }

    @MainActor
    func testHoldToSeekProgressiveMultiplierAndThumbnailActivation() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        defer { model.stopRepeatingSkip(); model.pendingSeekDelta = 0 }
        model.seekStepSeconds = 10
        model.time = PlayerTime(current: 100, duration: 1000)

        // Hold starts at 1x
        model.beginRepeatingSkipForward()
        XCTAssertTrue(model.isHoldingSeek)
        XCTAssertEqual(model.seekSpeedMultiplier, 1)

        // Releasing hold clears hold state and multiplier
        model.stopRepeatingSkip()
        XCTAssertFalse(model.isHoldingSeek)
        XCTAssertNil(model.seekSpeedMultiplier)
    }

    @MainActor
    func testMoveCommandAutorepeatHoldCadence() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        defer { model.commitPendingSeekIfNeeded(); model.pendingSeekDelta = 0 }
        model.seekStepSeconds = 10
        model.time = PlayerTime(current: 100, duration: 1000)
        model.status = .playing

        // First move command while playing (discrete tap: +10s)
        model.handleMoveSeek(direction: .right)
        XCTAssertEqual(model.pendingSeekDelta, 10)
        XCTAssertFalse(model.isHoldingSeek)
        XCTAssertNil(model.seekSpeedMultiplier)

        // Rapid second and third move commands (multi-tap spam: +20s, +30s) must NOT trigger hold
        model.handleMoveSeek(direction: .right)
        XCTAssertEqual(model.pendingSeekDelta, 20)
        XCTAssertFalse(model.isHoldingSeek)
        XCTAssertNil(model.seekSpeedMultiplier)

        model.handleMoveSeek(direction: .right)
        XCTAssertEqual(model.pendingSeekDelta, 30)
        XCTAssertFalse(model.isHoldingSeek)
        XCTAssertNil(model.seekSpeedMultiplier)

        // While paused, handleMoveSeek must NOT trigger discrete skips
        model.pendingSeekDelta = 0
        model.status = .paused
        model.handleMoveSeek(direction: .right)
        XCTAssertEqual(model.pendingSeekDelta, 0, "Move seek must be ignored while paused")
    }

    @MainActor
    func test1stGenRemoteEdgeClickSeeksLeftAndRight() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        defer { model.commitPendingSeekIfNeeded(); model.pendingSeekDelta = 0 }
        model.seekStepSeconds = 10
        model.time = PlayerTime(current: 100, duration: 1000)
        model.status = .playing

        // Left edge click on 1st Gen remote (x = -0.8)
        model.handleGCButtonA(isPressed: true, touchX: -0.8)
        model.handleGCButtonA(isPressed: false, touchX: -0.8)
        model.handleSelectTap()

        XCTAssertEqual(model.pendingSeekDelta, -10, "Left edge click must seek backward 10s")
        XCTAssertEqual(model.status, .playing, "Left edge click must not pause playback")

        // Right edge click on 1st Gen remote (x = 0.8)
        model.handleGCButtonA(isPressed: true, touchX: 0.8)
        model.handleGCButtonA(isPressed: false, touchX: 0.8)
        model.handleSelectTap()

        XCTAssertEqual(model.pendingSeekDelta, 0, "Right edge click must seek forward 10s (-10 + 10 = 0)")
        XCTAssertEqual(model.status, .playing, "Right edge click must not pause playback")
    }

    @MainActor
    func test1stGenRemoteCenterClickTogglesPlayPause() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        defer { model.commitPendingSeekIfNeeded(); model.pendingSeekDelta = 0 }
        model.time = PlayerTime(current: 100, duration: 1000)
        model.status = .paused

        // Center click on 1st Gen remote (x = 0.0) while paused resumes playback
        model.handleGCButtonA(isPressed: true, touchX: 0.0)
        model.handleGCButtonA(isPressed: false, touchX: 0.0)
        model.handleSelectTap()

        XCTAssertEqual(model.pendingSeekDelta, 0, "Center click must not seek")
        XCTAssertEqual(model.status, .playing, "Center click must toggle play/pause to playing")
    }

    @MainActor
    func test1stGenRemoteEdgeTapSeeks() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        defer { model.commitPendingSeekIfNeeded(); model.pendingSeekDelta = 0 }
        model.seekStepSeconds = 10
        model.time = PlayerTime(current: 100, duration: 1000)
        model.status = .playing

        // Light touch tap on left edge (x = -0.8) without clicking
        model.dpadSample(x: -0.8, y: 0.0)
        model.dpadSample(x: 0.0, y: 0.0)

        XCTAssertEqual(model.pendingSeekDelta, -10, "Left edge light tap must seek backward 10s")

        // Light touch tap on right edge (x = 0.8) without clicking
        model.dpadSample(x: 0.8, y: 0.0)
        model.dpadSample(x: 0.0, y: 0.0)

        XCTAssertEqual(model.pendingSeekDelta, 0, "Right edge light tap must seek forward 10s")
    }

    @MainActor
    func test1stGenRemoteCenterTapShowsPeek() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        model.time = PlayerTime(current: 100, duration: 1000)
        model.status = .playing

        // Center tap (x = 0.1)
        model.dpadSample(x: 0.1, y: 0.0)
        model.dpadSample(x: 0.0, y: 0.0)

        XCTAssertEqual(model.pendingSeekDelta, 0, "Center tap must not seek")
        XCTAssertTrue(model.peekVisible, "Center tap must show peek bar")
    }

    @MainActor
    func test1stGenRemoteEdgeClickWhilePausedResumesPlayback() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        model.time = PlayerTime(current: 100, duration: 1000)
        model.status = .paused

        // Clicking while paused (even on edge) should resume playback and not discrete-seek
        model.handleGCButtonA(isPressed: true, touchX: 0.8)
        model.handleGCButtonA(isPressed: false, touchX: 0.8)
        model.handleSelectTap()

        XCTAssertEqual(model.pendingSeekDelta, 0, "Clicking while paused must not discrete-seek")
        XCTAssertEqual(model.status, .playing, "Clicking while paused must resume playback")
    }

    @MainActor
    func testRemoteTouchScrubEntryHasNoThresholdJump() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        model.time = PlayerTime(current: 500, duration: 7200)

        // 1. While playing, touchpad swipes must NOT engage scrub
        model.status = .playing
        model.showControls = true
        model.isTimelineFocused = true
        model.remoteTouchBegan()
        model.remoteTouchMoved(dx: 50, dy: 0)
        // 2. When paused, scrubbing engages on swipe threshold
        model.status = .paused
        model.remoteTouchBegan()
        XCTAssertFalse(model.isScrubbing)

        // Movement under threshold does not engage scrub
        model.remoteTouchMoved(dx: 20, dy: 0)
        XCTAssertFalse(model.isScrubbing)

        // Movement crosses horizontal threshold (45pt)
        model.remoteTouchMoved(dx: 50, dy: 0)
        XCTAssertTrue(model.isScrubbing)
        // Scrub target must start at current position without a 50pt teleport jump
        XCTAssertEqual(model.clock.scrubTarget, 500)

        // Gentle subsequent incremental movement (slow finger slide: ~2pt per tick)
        for step in 1...5 {
            model.remoteTouchMoved(dx: 50 + CGFloat(step * 2), dy: 0)
        }
        model.remoteTouchEnded(dx: 60, dy: 0)
        if let target = model.clock.scrubTarget {
            XCTAssertGreaterThan(target, 500.0)
            XCTAssertLessThan(target, 501.5)
        } else {
            XCTFail("Scrub target should be non-nil")
        }

        // Tap/click jitter protection: touching down to press OK with micro-shift (< 10pt) must NOT move scrub target
        let targetBeforeTap = model.clock.scrubTarget
        model.remoteTouchBegan()
        model.remoteTouchMoved(dx: 5, dy: 1) // thumb micro-movement during click
        XCTAssertEqual(model.clock.scrubTarget, targetBeforeTap, "Micro-shift during click/tap must not move scrub position")
        model.remoteTouchEnded(dx: 5, dy: 1)

        // Second stroke: Intentional swipe (+25 points) while scrubbing
        model.remoteTouchBegan()
        model.remoteTouchMoved(dx: 25, dy: 0)
        model.remoteTouchEnded(dx: 25, dy: 0)
        if let target = model.clock.scrubTarget {
            XCTAssertGreaterThan(target, 505.0)
        }

        XCTAssertTrue(model.isScrubbing)

        // Committing scrub seeks and resets scrubbing
        model.commitScrub()
        XCTAssertFalse(model.isScrubbing)
    }

    @MainActor
    func testPauseShowsControlsAndTouchpadScrubGating() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        model.time = PlayerTime(current: 120, duration: 3600)
        model.status = .playing
        model.hideControls()

        XCTAssertFalse(model.showControls)
        XCTAssertFalse(model.isTimelineFocused)

        // 1. Pausing should immediately reveal controls and focus timeline
        model.pause()
        XCTAssertEqual(model.status, .paused)
        XCTAssertTrue(model.showControls, "Pausing playback must show controls/progressbar")
        XCTAssertTrue(model.isTimelineFocused, "Pausing playback must focus the timeline")

        // Touchpad swipe engages scrub while paused and controls are visible
        model.remoteTouchBegan()
        model.remoteTouchMoved(dx: 50, dy: 0)
        XCTAssertTrue(model.isScrubbing, "Touchpad swipe must engage scrub when paused and controls visible")
        model.remoteTouchEnded(dx: 50, dy: 0)
        model.cancelScrub()
        XCTAssertFalse(model.isScrubbing)

        // 2. User explicitly hides/closes the controls while paused
        model.hideControls()
        XCTAssertEqual(model.status, .paused)
        XCTAssertFalse(model.showControls, "Controls must be hidden initially")

        // Swiping while paused with controls hidden brings forward the Infuse scrubber
        model.remoteTouchBegan()
        model.remoteTouchMoved(dx: 50, dy: 0)
        XCTAssertTrue(model.isScrubbing, "Touchpad swipe while paused must bring front the Infuse scrubber")
        XCTAssertTrue(model.showControls, "Controls/timeline must be shown when scrubbing starts")
        model.remoteTouchEnded(dx: 50, dy: 0)

        // Committing scrub starts/resumes playback
        model.commitScrub()
        XCTAssertFalse(model.isScrubbing)
        XCTAssertEqual(model.status, .playing, "Committing scrub while paused must start playback")

        // 3. Resuming playback while controls are dismissed does not bring up the progress bar
        model.pause()
        model.hideControls()
        XCTAssertFalse(model.showControls)
        model.play()
        XCTAssertEqual(model.status, .playing)
        XCTAssertFalse(model.showControls, "Playing while controls were dismissed must not bring up the progress bar")
    }

    @MainActor
    func testPauseClickJitterDoesNotTriggerScrubbing() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        model.time = PlayerTime(current: 120, duration: 3600)
        model.status = .playing
        model.showControls = false

        // 1. Touch began on remote glass touchpad while playing (e.g. user touches down to click pause)
        model.remoteTouchBegan()

        // 2. Physical click pauses playback
        model.pause()
        XCTAssertEqual(model.status, .paused)
        XCTAssertTrue(model.showControls, "Pausing should display controls")

        // 3. Releasing thumb causes motion on the glass touchpad
        model.remoteTouchMoved(dx: 55, dy: 5)
        model.remoteTouchEnded(dx: 55, dy: 5)

        // 4. Scrubbing must NOT engage; transport controls should remain visible
        XCTAssertFalse(model.isScrubbing, "Touch stroke initiated before pause must not engage scrub")
        XCTAssertTrue(model.showControls, "Controls must stay visible")
    }

    @MainActor
    func testUndispatchedCachedLoadRejectsOldReadyPlaybackSample() {
        let defaults = ProfileSettings.current
        let previousCacheSetting = defaults.object(forKey: SettingsKey.hybridDiskCacheEnabled)
        defaults.set(true, forKey: SettingsKey.hybridDiskCacheEnabled)

        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil },
            engineSettingProvider: { "MPVKit" }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator)
        defer {
            model.cancelStartupBenchmark()
            model.shutdown()
            if let previousCacheSetting {
                defaults.set(previousCacheSetting, forKey: SettingsKey.hybridDiskCacheEnabled)
            } else {
                defaults.removeObject(forKey: SettingsKey.hybridDiskCacheEnabled)
            }
        }

        coordinator.load(PlaybackLoadRequest(
            videoURL: URL(string: "https://example.test/first.mkv")!
        ))
        let firstGeneration = coordinator.loadGeneration
        XCTAssertFalse(coordinator.hasDispatchedCurrentLoad(generation: firstGeneration))

        model.retryPlaybackStartup()
        let pendingGeneration = coordinator.loadGeneration
        XCTAssertGreaterThan(pendingGeneration, firstGeneration)
        XCTAssertFalse(coordinator.hasDispatchedCurrentLoad(generation: pendingGeneration))

        let oldReadyEngine = PlayerControlsTestEngine()
        oldReadyEngine.isPlayerPlaying = true
        oldReadyEngine.isTransportPlaying = true
        oldReadyEngine.hasFirstFrameReadyForDisplay = true
        oldReadyEngine.hasCoherentTimeSample = true
        oldReadyEngine.durationMs = 3_600_000
        oldReadyEngine.positionMs = 1_000
        oldReadyEngine.videoFrameSize = CGSize(width: 1_920, height: 1_080)
        model.pollForTesting(using: oldReadyEngine)

        XCTAssertEqual(model.status, .buffering, "Old ready frames cannot start a load still preparing its cache")
        XCTAssertFalse(model.canShowPauseOverlay)
        XCTAssertFalse(model.showPauseOverlay)
    }

    @MainActor
    func testNextEpisodeResolutionKeepsFreshClockAndCancelsPauseOverlayWork() async {
        let coordinator = PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        let model = PlayerViewModel(
            sessionCoordinator: coordinator,
            pauseOverlayDelaySeconds: 0.025
        )
        let resolver = DeferredNextStreamResolver()
        let resolverStarted = expectation(description: "Next episode resolver starts")
        resolver.onStart = { resolverStarted.fulfill() }
        defer {
            resolver.release(nil)
            model.cancelStartupBenchmark()
            model.shutdown()
        }

        let oldToken = PlaybackStartupTiming.start(title: "Current episode")
        model.adoptStartupBenchmarkToken(oldToken)
        let currentEpisode = NuvioVideo(id: "series:1:1", title: "Episode 1", season: 1, episode: 1)
        let nextEpisode = NuvioVideo(
            id: "series:1:2",
            title: "Episode 2",
            season: 1,
            episode: 2,
            released: "2024-01-01T00:00:00.000Z"
        )
        model.configureNextEpisode(
            episodes: [currentEpisode, nextEpisode],
            current: currentEpisode,
            autoPlayEnabled: false,
            autoPlayCountdownSeconds: 10,
            resolver: { _, _ in await resolver.resolve() }
        )
        model.time = PlayerTime(current: 2_640, duration: 6_000)
        model.status = .playing
        model.pause()

        let oldRequestDate = try! XCTUnwrap(PlaybackStartupTiming.requestDate(for: oldToken))
        try? await Task.sleep(nanoseconds: 10_000_000)
        model.advance()

        let nextToken = try! XCTUnwrap(model.startupBenchmarkToken)
        let nextRequestDate = try! XCTUnwrap(PlaybackStartupTiming.requestDate(for: nextToken))
        XCTAssertNotEqual(nextToken, oldToken)
        XCTAssertGreaterThan(nextRequestDate, oldRequestDate)
        XCTAssertLessThan(abs(Date().timeIntervalSince(nextRequestDate)), 1)
        XCTAssertEqual(model.status, .buffering)
        XCTAssertTrue(model.isAdvancingEpisode)
        XCTAssertFalse(model.canShowPauseOverlay)

        await fulfillment(of: [resolverStarted], timeout: 1)
        let oldPausedReadyEngine = PlayerControlsTestEngine()
        oldPausedReadyEngine.hasFirstFrameReadyForDisplay = true
        oldPausedReadyEngine.videoFrameSize = CGSize(width: 1_920, height: 1_080)
        oldPausedReadyEngine.hasCoherentTimeSample = true
        oldPausedReadyEngine.durationMs = 6_000_000
        oldPausedReadyEngine.positionMs = 2_640_000
        model.pollForTesting(using: oldPausedReadyEngine)

        try? await Task.sleep(nanoseconds: 100_000_000)
        model.pollForTesting(using: oldPausedReadyEngine)
        XCTAssertEqual(model.status, .buffering, "Old ready/paused samples must not complete the next load")
        XCTAssertTrue(model.isAdvancingEpisode)
        XCTAssertFalse(model.canShowPauseOverlay)
        XCTAssertFalse(model.showPauseOverlay, "A cancelled pause timer must not reopen the metadata sheet during resolution")

        resolver.release(nil)
        for _ in 0..<20 where model.status != .ended {
            await Task.yield()
        }
        XCTAssertEqual(model.status, .ended, "A failed resolver should exit the guarded loading state")
        XCTAssertFalse(model.showPauseOverlay)
    }

    @MainActor
    func testSteadyPauseShowsMetadataAndPlaybackHidesIt() async {
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            pauseOverlayDelaySeconds: 0.025
        )
        defer {
            model.cancelStartupBenchmark()
            model.shutdown()
        }

        model.status = .playing
        model.pause()
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(model.canShowPauseOverlay)
        XCTAssertTrue(model.showPauseOverlay, "A steady user pause should still reveal metadata after the short delay")

        model.play()
        XCTAssertEqual(model.status, .playing)
        XCTAssertFalse(model.canShowPauseOverlay)
        XCTAssertFalse(model.showPauseOverlay, "Resuming playback must hide the pause metadata sheet")
    }


    @MainActor
    func testControlsAutoHideIntervalsAndPanelSuspension() {
        let provider = ControlledScrubThumbnailProvider()
        let model = PlayerViewModel(
            sessionCoordinator: PlaybackSessionCoordinator(aetherControllerFactory: { nil }),
            scrubThumbnailProvider: provider
        )
        model.status = .playing
        model.showControls = true

        // 1. Focused on timeline: 5s auto-hide interval
        model.setTimelineFocused(true)
        model.scheduleControlsHide()
        XCTAssertTrue(model.showControls)

        // 2. Focused on buttons: 10s auto-hide interval
        model.setTimelineFocused(false)
        model.scheduleControlsHide()
        XCTAssertTrue(model.showControls)

        // 3. Opening settings panel or side panel suspends auto-hide
        model.showSettingsPanel = true
        model.scheduleControlsHide(after: 0.01)
        XCTAssertTrue(model.showControls, "Auto-hide must not dismiss while settings panel is open")

        model.showSettingsPanel = false
        model.openSidePanel(.episodes)
        XCTAssertEqual(model.sidePanel, .episodes, "Side panel must be active and open")
    }

    func testPlayerAspectModePropertiesAndScaling() {
        XCTAssertEqual(PlayerAspectMode.allCases, [.fit, .fill, .zoom, .stretch])

        let container = CGSize(width: 1920, height: 1080)
        let wideVideo = CGSize(width: 2350, height: 1000) // 2.35:1
        let tallVideo = CGSize(width: 1440, height: 1080) // 4:3

        // Fit
        XCTAssertEqual(PlayerAspectMode.fit.scale(video: wideVideo, container: container), CGSize(width: 1, height: 1))
        XCTAssertEqual(PlayerAspectMode.fit.scale(video: tallVideo, container: container), CGSize(width: 1, height: 1))

        // Fill
        let fillScaleWide = PlayerAspectMode.fill.scale(video: wideVideo, container: container)
        XCTAssertGreaterThan(fillScaleWide.width, 1.0)
        XCTAssertEqual(fillScaleWide.width, fillScaleWide.height)

        // Zoom (halfway zoom between fit and fill)
        let zoomScaleWide = PlayerAspectMode.zoom.scale(video: wideVideo, container: container)
        XCTAssertGreaterThan(zoomScaleWide.width, 1.0)
        XCTAssertLessThan(zoomScaleWide.width, fillScaleWide.width)
        XCTAssertEqual(zoomScaleWide.width, zoomScaleWide.height)

        // Stretch
        let stretchScaleWide = PlayerAspectMode.stretch.scale(video: wideVideo, container: container)
        XCTAssertGreaterThan(stretchScaleWide.height, 1.0)

        // Persistence
        let previous = PlayerAspectMode.current
        PlayerAspectMode.current = .zoom
        XCTAssertEqual(PlayerAspectMode.current, .zoom)
        PlayerAspectMode.current = .fit
        XCTAssertEqual(PlayerAspectMode.current, .fit)
        PlayerAspectMode.current = previous
    }

    func testPlaybackLoadRequestAspectMode() {
        let defaultRequest = PlaybackLoadRequest(videoURL: URL(string: "https://example.com/video.mp4")!)
        XCTAssertEqual(defaultRequest.aspectMode, .fit)

        let zoomRequest = PlaybackLoadRequest(
            videoURL: URL(string: "https://example.com/video.mp4")!,
            aspectMode: .zoom
        )
        XCTAssertEqual(zoomRequest.aspectMode, .zoom)
    }

    @MainActor
    func testPlayerViewModelPreservesOpaqueDiscFilenameForPlaybackRouting() throws {
        let resolvedURL = URL(string: "https://provider.example/download?token=opaque")!
        let aether = try XCTUnwrap(AetherPlaybackController())
        var dispatched: [(PlaybackLoadRequest, PlayerBackendKind)] = []
        let coordinator = PlaybackSessionCoordinator(
            aetherController: aether,
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { request, backend, _ in dispatched.append((request, backend)) }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator)
        defer {
            model.shutdown()
            coordinator.stopAll()
        }

        model.load(
            url: resolvedURL,
            meta: NuvioMeta(id: "opaque-disc-title", name: "Disc", type: "movie"),
            subtitle: "",
            resumeFrom: nil,
            filename: "movie.iso"
        )

        XCTAssertEqual(dispatched.count, 1)
        guard let (request, backend) = dispatched.first else {
            return XCTFail("Playback request was not dispatched")
        }
        XCTAssertEqual(request.filename, "movie.iso")
        XCTAssertEqual(backend, .aether)
        XCTAssertFalse(PlaybackSessionCoordinator.shouldUseHybridDiskCache(isEnabled: true, request: request))
    }

    @MainActor
    func testPlayerViewModelFallsBackToURLFilenameWhenNoFilenameIsSupplied() throws {
        let resolvedURL = URL(string: "https://provider.example/movie.mkv?token=opaque")!
        var dispatched: [PlaybackLoadRequest] = []
        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil },
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { request, _, _ in dispatched.append(request) }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator)
        defer {
            model.shutdown()
            coordinator.stopAll()
        }

        model.load(
            url: resolvedURL,
            meta: NuvioMeta(id: "opaque-video-title", name: "Video", type: "movie"),
            subtitle: "",
            resumeFrom: nil
        )

        XCTAssertEqual(dispatched.count, 1)
        XCTAssertEqual(dispatched.first?.filename, "movie.mkv")
    }

    @MainActor
    func testCurrentSourceUsesOriginalIDAfterPlaybackURLResolution() {
        let originalSource = NuvioStream(
            url: "https://provider.example/original.mkv",
            name: "Original source",
            description: nil,
            addonName: "Fixture"
        )
        let resolvedURL = URL(string: "https://playback.example/resolved.mkv")!
        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil },
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { _, _, _ in }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator)
        defer {
            model.shutdown()
            coordinator.stopAll()
        }

        model.load(
            url: resolvedURL,
            meta: NuvioMeta(id: "source-identity-title", name: "Fixture title", type: "movie"),
            subtitle: "",
            resumeFrom: nil,
            sourceID: originalSource.id
        )

        XCTAssertNotEqual(originalSource.id, resolvedURL.absoluteString)
        XCTAssertTrue(model.isCurrentSource(originalSource))
    }

    @MainActor
    func testCurrentSourceRejectsResolvedURLRowWhenOriginalIDIsExplicit() {
        let originalSource = NuvioStream(
            url: "https://provider.example/original.mkv",
            name: "Original source",
            description: nil,
            addonName: "Fixture"
        )
        let resolvedURL = URL(string: "https://playback.example/resolved.mkv")!
        let resolvedURLRow = NuvioStream(
            url: resolvedURL.absoluteString,
            name: "Resolved URL row",
            description: nil,
            addonName: "Fixture"
        )
        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil },
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { _, _, _ in }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator)
        defer {
            model.shutdown()
            coordinator.stopAll()
        }

        model.load(
            url: resolvedURL,
            meta: NuvioMeta(id: "source-identity-title", name: "Fixture title", type: "movie"),
            subtitle: "",
            resumeFrom: nil,
            sourceID: originalSource.id
        )

        XCTAssertEqual(resolvedURLRow.id, resolvedURL.absoluteString)
        XCTAssertFalse(model.isCurrentSource(resolvedURLRow))
    }

    @MainActor
    func testCurrentSourceFallsBackToURLWhenSourceIDIsMissing() {
        let originalSource = NuvioStream(
            url: "https://provider.example/original.mkv",
            name: "Original source",
            description: nil,
            addonName: "Fixture"
        )
        let resolvedURL = URL(string: "https://playback.example/resolved.mkv")!
        let resolvedURLRow = NuvioStream(
            url: resolvedURL.absoluteString,
            name: "Resolved URL row",
            description: nil,
            addonName: "Fixture"
        )
        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil },
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { _, _, _ in }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator)
        defer {
            model.shutdown()
            coordinator.stopAll()
        }

        model.load(
            url: resolvedURL,
            meta: NuvioMeta(id: "source-identity-title", name: "Fixture title", type: "movie"),
            subtitle: "",
            resumeFrom: nil
        )

        XCTAssertTrue(model.isCurrentSource(resolvedURLRow))
        XCTAssertFalse(model.isCurrentSource(originalSource))
    }

    @MainActor
    func testStartupBenchmarkOwnerIsForwardedAndReplacedOnCoordinatorRetry() {
        let firstOwner = UUID()
        let retryOwner = UUID()
        var dispatchedOwners: [UUID?] = []
        let coordinator = PlaybackSessionCoordinator(
            aetherControllerFactory: { nil },
            engineSettingProvider: { "MPVKit" },
            loadDispatcher: { request, _, _ in
                dispatchedOwners.append(request.startupBenchmarkToken)
            }
        )
        defer { coordinator.stopAll() }

        coordinator.load(PlaybackLoadRequest(
            videoURL: URL(string: "https://example.com/video.mp4")!,
            startupBenchmarkToken: firstOwner
        ))
        coordinator.retryLastLoad(startupBenchmarkToken: retryOwner)

        XCTAssertEqual(dispatchedOwners, [firstOwner, retryOwner])
        XCTAssertEqual(coordinator.lastRequest?.startupBenchmarkToken, retryOwner)
    }

    @MainActor
    func testPlayerViewModelAspectModeSwitching() {
        let coordinator = PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        let model = PlayerViewModel(
            sessionCoordinator: coordinator,
            scrubThumbnailProvider: nil
        )

        model.setAspectMode(.fill)
        XCTAssertEqual(model.aspectMode, .fill)
        XCTAssertEqual(PlayerAspectMode.current, .fill)

        model.setAspectMode(.zoom)
        XCTAssertEqual(model.aspectMode, .zoom)
        XCTAssertEqual(PlayerAspectMode.current, .zoom)

        model.setAspectMode(.stretch)
        XCTAssertEqual(model.aspectMode, .stretch)
        XCTAssertEqual(PlayerAspectMode.current, .stretch)

        model.setAspectMode(.fit)
        XCTAssertEqual(model.aspectMode, .fit)
        XCTAssertEqual(PlayerAspectMode.current, .fit)
    }

    func testPreferredAudioLanguageOriginal() {
        let defaults = UserDefaults(suiteName: "PreferredAudioLanguageTestsDefaults")!
        defaults.removePersistentDomain(forName: "PreferredAudioLanguageTestsDefaults")

        // 1. Settings options contains "Original"
        XCTAssertTrue(SubtitleLanguagePreferences.audioSettingsOptions.contains("Original"))
        XCTAssertTrue(SubtitleLanguagePreferences.audioSettingsOptions.contains("System"))

        // 2. Setting preferred audio language to "Original"
        defaults.set("Original", forKey: SettingsKey.audioLanguage)

        // Meta with explicit language "ko" (Korean)
        let koreanMeta = NuvioMeta(
            id: "movie-1", name: "Parasite", description: nil,
            posterUrl: nil, backgroundUrl: nil, logoUrl: nil,
            imdbId: nil, tmdbId: nil, type: "movie", year: 2019,
            genres: nil, rating: nil, releaseInfo: nil, runtime: nil,
            cast: nil, director: nil, writer: nil, certification: nil,
            country: "KR", language: "ko", released: nil
        )
        XCTAssertEqual(
            SubtitleLanguagePreferences.preferredAudioLanguage(meta: koreanMeta, defaults: defaults),
            "Korean"
        )

        // Meta with explicit language "ja" (Japanese)
        let japaneseMeta = NuvioMeta(
            id: "movie-2", name: "Spirited Away", description: nil,
            posterUrl: nil, backgroundUrl: nil, logoUrl: nil,
            imdbId: nil, tmdbId: nil, type: "movie", year: 2001,
            genres: nil, rating: nil, releaseInfo: nil, runtime: nil,
            cast: nil, director: nil, writer: nil, certification: nil,
            country: "JP", language: "ja", released: nil
        )
        XCTAssertEqual(
            SubtitleLanguagePreferences.preferredAudioLanguage(meta: japaneseMeta, defaults: defaults),
            "Japanese"
        )

        // Meta with isAnime and no language specified
        let animeMeta = NuvioMeta(
            id: "anime-1", name: "Attack on Titan", description: nil,
            posterUrl: nil, backgroundUrl: nil, logoUrl: nil,
            imdbId: nil, tmdbId: nil, type: "anime", year: 2013,
            genres: ["Anime"], rating: nil, releaseInfo: nil, runtime: nil,
            cast: nil, director: nil, writer: nil, certification: nil,
            country: nil, language: nil, released: nil
        )
        XCTAssertEqual(
            SubtitleLanguagePreferences.preferredAudioLanguage(meta: animeMeta, defaults: defaults),
            "Japanese"
        )

        // Meta without language or anime
        let unknownMeta = NuvioMeta(
            id: "other-1", name: "Unknown", description: nil,
            posterUrl: nil, backgroundUrl: nil, logoUrl: nil,
            imdbId: nil, tmdbId: nil, type: "movie", year: nil,
            genres: nil, rating: nil, releaseInfo: nil, runtime: nil,
            cast: nil, director: nil, writer: nil, certification: nil,
            country: nil, language: nil, released: nil
        )
        XCTAssertNil(
            SubtitleLanguagePreferences.preferredAudioLanguage(meta: unknownMeta, defaults: defaults)
        )

        // Nil meta
        XCTAssertNil(
            SubtitleLanguagePreferences.preferredAudioLanguage(meta: nil, defaults: defaults)
        )

        // When preferred language is explicit (e.g. "French"), it overrides meta
        defaults.set("French", forKey: SettingsKey.audioLanguage)
        XCTAssertEqual(
            SubtitleLanguagePreferences.preferredAudioLanguage(meta: koreanMeta, defaults: defaults),
            "French"
        )
    }

    @MainActor
    func testPlayerLoadingStepProgressMessages() async {
        let coordinator = PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        let vm = PlayerViewModel(sessionCoordinator: coordinator)
        
        // Initial state
        let initialMsg = vm.loadingStepMessage
        XCTAssertFalse(initialMsg.isEmpty)
        
        // When source switch begins
        let video = NuvioVideo(id: "ep-1", title: "Ep 1", season: 1, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil)
        vm.selectEpisode(video)
        let switchingMsg = vm.loadingStepMessage
        XCTAssertFalse(switchingMsg.isEmpty)

        // When advancing to next episode
        vm.isAdvancingEpisode = true
        vm.updateLoadingStepMessage()
        XCTAssertEqual(vm.loadingStepMessage, L10n.string("player_searching_sources", fallback: "Searching sources…"))
    }

    @MainActor
    func testRemoteTouchDoesNotSuppressMoveCommandForPhysicalClick() {
        let coordinator = PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        let vm = PlayerViewModel(sessionCoordinator: coordinator)
        vm.time = PlayerTime(current: 10, duration: 100)
        vm.status = .playing

        // Touching the remote clickpad down (without scrubbing) should NOT suppress move commands
        vm.remoteTouchBegan()
        XCTAssertFalse(vm.moveSuppressed, "Placing a finger on the remote must not suppress move commands")

        // Micro-movements during a physical button press (< 15pt) should NOT suppress move commands
        vm.remoteTouchMoved(dx: 5, dy: 5)
        XCTAssertFalse(vm.moveSuppressed, "Micro-movement before clicking must not suppress move commands")

        // Swiping across the threshold (>= 15pt) recognizes a swipe and suppresses move commands
        vm.remoteTouchMoved(dx: 50, dy: 10)
        XCTAssertTrue(vm.moveSuppressed, "Recognized swipe should suppress move commands")

        vm.remoteTouchEnded(dx: 50, dy: 10)
    }

    @MainActor
    func testSwipeWhilePlayingDoesNotSeekOnlyTapSeeks() {
        let coordinator = PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        let vm = PlayerViewModel(sessionCoordinator: coordinator)
        vm.seekStepSeconds = 10
        vm.time = PlayerTime(current: 100, duration: 1000)
        vm.status = .playing
        vm.showControls = false

        // 1. Swiping across the trackpad while content is playing
        vm.remoteTouchBegan()
        vm.remoteTouchMoved(dx: 30, dy: 0)
        XCTAssertTrue(vm.moveSuppressed, "Horizontal swipe while playing must suppress move commands")
        XCTAssertFalse(vm.isScrubbing, "Horizontal swipe while playing must not enter scrub mode")
        XCTAssertEqual(vm.pendingSeekDelta, 0, "Horizontal swipe must not trigger seek delta")

        vm.remoteTouchEnded(dx: 30, dy: 0)
        XCTAssertFalse(vm.isScrubbing)
        XCTAssertEqual(vm.pendingSeekDelta, 0)

        // 2. Tap / physical click (simulated by directional move command without swipe suppression)
        // Reset moveSuppressed for tap simulation
        vm.handleMoveSeek(direction: .right)
        XCTAssertEqual(vm.pendingSeekDelta, 10, "Tapping / pressing right D-pad must trigger discrete +10s seek")

        vm.handleMoveSeek(direction: .right)
        XCTAssertEqual(vm.pendingSeekDelta, 20, "Second tap must accumulate to +20s seek")
    }
}

final class ExternalPlayerTests: XCTestCase {
    func testExternalPlayerSubtitleForwarding() {
        let stream = URL(string: "https://cdn.example/movie.mkv")!
        let sub = URL(string: "https://subs.example/en.srt")!
        let infuse = ExternalPlayer.infuse.launchURL(for: stream, subtitleURLs: [sub])
        XCTAssertNotNil(infuse)
        XCTAssertTrue(infuse!.absoluteString.contains("sub="))
        XCTAssertTrue(infuse!.absoluteString.contains("infuse://"))

        let vlc = ExternalPlayer.vlc.launchURL(for: stream, subtitleURLs: [sub])
        XCTAssertNotNil(vlc)
        XCTAssertTrue(vlc!.absoluteString.contains("vlc-x-callback://"))
        XCTAssertTrue(vlc!.absoluteString.contains("sub="))

        let outplayer = ExternalPlayer.outplayer.launchURL(for: stream)
        XCTAssertNotNil(outplayer)
        XCTAssertTrue(outplayer!.absoluteString.starts(with: "outplayer://"))

        let nplayer = ExternalPlayer.nplayer.launchURL(for: stream)
        XCTAssertNotNil(nplayer)
        XCTAssertTrue(nplayer!.absoluteString.starts(with: "nplayer-https://"))

        let vidhub = ExternalPlayer.vidhub.launchURL(for: stream)
        XCTAssertNotNil(vidhub)
        XCTAssertTrue(vidhub!.absoluteString.starts(with: "vidhub://"))

        let senplayer = ExternalPlayer.senplayer.launchURL(for: stream, subtitleURLs: [sub])
        XCTAssertNotNil(senplayer)
        XCTAssertTrue(senplayer!.absoluteString.starts(with: "senplayer://x-callback-url/play?url="))
        XCTAssertTrue(senplayer!.absoluteString.contains("sub="))

        let builtIn = ExternalPlayer.builtIn.launchURL(for: stream)
        XCTAssertNil(builtIn)
    }

    func testExternalPlayerFilenameAndPositionParameters() {
        let stream = URL(string: "https://torrentio.strem.fun/stream/btQt7hBjitPmN5KQjRjZxT49F4ISsyPyyjqDx27KjX0os01JifcLDA")!
        let movieFilename = "Superman & Lois (2024).mp4"
        let infuse = ExternalPlayer.infuse.launchURL(
            for: stream,
            filename: movieFilename,
            position: 125.0
        )
        XCTAssertNotNil(infuse)
        XCTAssertTrue(infuse!.absoluteString.contains("filename=Superman%20%26%20Lois%20%282024%29.mp4"))
        XCTAssertTrue(infuse!.absoluteString.contains("position=125"))

        let outplayer = ExternalPlayer.outplayer.launchURL(
            for: stream,
            filename: movieFilename
        )
        XCTAssertNotNil(outplayer)
        XCTAssertTrue(outplayer!.absoluteString.contains("outplayer://x-callback-url/play?url="))
        XCTAssertTrue(outplayer!.absoluteString.contains("filename=Superman%20%26%20Lois%20%282024%29.mp4"))

        let vidhub = ExternalPlayer.vidhub.launchURL(
            for: stream,
            filename: movieFilename,
            position: 45.0
        )
        XCTAssertNotNil(vidhub)
        XCTAssertTrue(vidhub!.absoluteString.contains("vidhub://play?url="))
        XCTAssertTrue(vidhub!.absoluteString.contains("filename=Superman%20%26%20Lois%20%282024%29.mp4"))
        XCTAssertTrue(vidhub!.absoluteString.contains("position=45"))

        let senplayer = ExternalPlayer.senplayer.launchURL(
            for: stream,
            filename: movieFilename,
            position: 60.0
        )
        XCTAssertNotNil(senplayer)
        XCTAssertTrue(senplayer!.absoluteString.contains("senplayer://x-callback-url/play?url="))
        XCTAssertTrue(senplayer!.absoluteString.contains("filename=Superman%20%26%20Lois%20%282024%29.mp4"))
        XCTAssertTrue(senplayer!.absoluteString.contains("position=60"))
    }

    func testSenPlayerXCallbacksArePercentEncoded() {
        let stream = URL(string: "https://cdn.example/movie.mkv?token=a&b=c")!
        let success = URL(string: "nuvio-tv://external-playback/ABC-123")!
        let error = URL(string: "nuvio-tv://external-playback/error/ABC-123")!
        let launch = ExternalPlayer.senplayer.launchURL(
            for: stream,
            successURL: success,
            errorURL: error
        )!

        XCTAssertTrue(launch.absoluteString.starts(with: "senplayer://x-callback-url/play?url="))
        XCTAssertTrue(launch.absoluteString.contains("x-success=nuvio-tv%3A%2F%2Fexternal-playback%2FABC-123"))
        XCTAssertTrue(launch.absoluteString.contains("x-error=nuvio-tv%3A%2F%2Fexternal-playback%2Ferror%2FABC-123"))
        XCTAssertFalse(launch.absoluteString.contains("x-success=nuvio-tv://"))
    }

    func testExternalPlayerSystemImagesAndLabels() {
        for player in ExternalPlayer.allCases {
            XCTAssertFalse(player.systemImage.isEmpty)
            XCTAssertFalse(player.rawValue.isEmpty)
            XCTAssertEqual(ExternalPlayer.from(player.rawValue), player)
        }
        XCTAssertEqual(ExternalPlayer.from("SenPlayer"), .senplayer)
        XCTAssertEqual(ExternalPlayer.from("Unknown"), .builtIn)
        XCTAssertEqual(ExternalPlayer.from(nil), .builtIn)
    }

    func testSubtitleMenuFormatterExternalLabels() {
        // Standard external subtitle with distinct release label:
        // release label becomes primary title, add-on name becomes secondary subtitle.
        let optionWithRelease = SubtitlePanelOption(
            id: "ext-1",
            kind: .external(NuvioSubtitle(url: "https://example.com/1.srt", language: "en", label: "The.Batman.2022.1080p.WEBRip.x264-RARBG", source: "OpenSubtitles v3")),
            badge: "OpenSubtitles v3",
            title: "English",
            detail: "The.Batman.2022.1080p.WEBRip.x264-RARBG",
            language: "English",
            isSelected: false
        )
        let labelsWithRelease = SubtitleMenuFormatter.groupedExternalMenuLabels(option: optionWithRelease)
        XCTAssertEqual(labelsWithRelease.title, "The.Batman.2022.1080p.WEBRip.x264-RARBG")
        XCTAssertEqual(labelsWithRelease.subtitle, "OpenSubtitles v3")

        // External subtitle where label is redundant with the add-on name:
        let optionRedundantAddon = SubtitlePanelOption(
            id: "ext-2",
            kind: .external(NuvioSubtitle(url: "https://example.com/2.srt", language: "en", label: "OpenSubtitles", source: "OpenSubtitles v3")),
            badge: "OpenSubtitles v3",
            title: "English",
            detail: "OpenSubtitles",
            language: "English",
            isSelected: false
        )
        let labelsRedundant = SubtitleMenuFormatter.groupedExternalMenuLabels(option: optionRedundantAddon)
        XCTAssertEqual(labelsRedundant.title, "OpenSubtitles v3")
        XCTAssertNil(labelsRedundant.subtitle)

        // External subtitle without label (or label matches language):
        let optionLanguageOnly = SubtitlePanelOption(
            id: "ext-3",
            kind: .external(NuvioSubtitle(url: "https://example.com/3.srt", language: "en", label: "English", source: "SubDL")),
            badge: "SubDL",
            title: "English",
            detail: nil,
            language: "English",
            isSelected: false
        )
        let labelsLangOnly = SubtitleMenuFormatter.groupedExternalMenuLabels(option: optionLanguageOnly)
        XCTAssertEqual(labelsLangOnly.title, "SubDL")
        XCTAssertNil(labelsLangOnly.subtitle)

        // External subtitle with hash/token that gets filtered by sanitizer:
        let optionGarbageToken = SubtitlePanelOption(
            id: "ext-4",
            kind: .external(NuvioSubtitle(url: "https://example.com/4.srt", language: "en", label: "v3_e1_deadbeef123456", source: "OpenSubtitles v3")),
            badge: "OpenSubtitles v3",
            title: "English",
            detail: "v3_e1_deadbeef123456",
            language: "English",
            isSelected: false
        )
        let labelsGarbage = SubtitleMenuFormatter.groupedExternalMenuLabels(option: optionGarbageToken)
        XCTAssertEqual(labelsGarbage.title, "OpenSubtitles v3")
        XCTAssertNil(labelsGarbage.subtitle)

        // Orphaned external mpv track:
        let optionExternalTrack = SubtitlePanelOption(
            id: "track-1",
            kind: .track(SubtitleTrack(id: "1", name: "custom_sub.srt", language: "eng", isSelected: false, externalFilename: "custom_sub.srt")),
            badge: "External",
            title: "custom_sub.srt",
            detail: nil,
            language: "English",
            isSelected: false
        )
        let labelsTrack = SubtitleMenuFormatter.groupedExternalMenuLabels(option: optionExternalTrack)
        XCTAssertEqual(labelsTrack.title, "custom_sub.srt")
        XCTAssertEqual(labelsTrack.subtitle, "External")
    }

    func testSubtitleMenuFormatterBuiltInLabels() {
        // Built-in track with title and no extra detail:
        let optionStandard = SubtitlePanelOption(
            id: "track-builtin-1",
            kind: .track(SubtitleTrack(id: "2", name: "English [CC]", language: "eng", isSelected: false, externalFilename: "")),
            badge: "Built in",
            title: "English [CC]",
            detail: nil,
            language: "English",
            isSelected: false
        )
        let labelsStandard = SubtitleMenuFormatter.builtInMenuLabels(option: optionStandard)
        XCTAssertEqual(labelsStandard.title, "English [CC]")
        XCTAssertNil(labelsStandard.subtitle)

        // Built-in track with descriptive detail (e.g. commentary):
        let optionCommentary = SubtitlePanelOption(
            id: "track-builtin-2",
            kind: .track(SubtitleTrack(id: "3", name: "English", language: "eng", isSelected: false, externalFilename: "")),
            badge: "Built in",
            title: "English",
            detail: "Director Commentary",
            language: "English",
            isSelected: false
        )
        let labelsCommentary = SubtitleMenuFormatter.builtInMenuLabels(option: optionCommentary)
        XCTAssertEqual(labelsCommentary.title, "English")
        XCTAssertEqual(labelsCommentary.subtitle, "Director Commentary")

        // Built-in track where detail is identical to title:
        let optionDuplicate = SubtitlePanelOption(
            id: "track-builtin-3",
            kind: .track(SubtitleTrack(id: "4", name: "English", language: "eng", isSelected: false, externalFilename: "")),
            badge: "Built in",
            title: "English",
            detail: "English",
            language: "English",
            isSelected: false
        )
        let labelsDuplicate = SubtitleMenuFormatter.builtInMenuLabels(option: optionDuplicate)
        XCTAssertEqual(labelsDuplicate.title, "English")
        XCTAssertNil(labelsDuplicate.subtitle)
    }

    func testSubtitleLanguageGroupSelectedOptionAndDisplayTitle() {
        let externalOption = SubtitlePanelOption(
            id: "ext-1",
            kind: .external(NuvioSubtitle(url: "https://example.com/1.srt", language: "en", label: "WEB-DL.x264", source: "OpenSubtitles v3")),
            badge: "OpenSubtitles v3",
            title: "English",
            detail: "WEB-DL.x264",
            language: "English",
            isSelected: true
        )
        let unselectedOption = SubtitlePanelOption(
            id: "ext-2",
            kind: .external(NuvioSubtitle(url: "https://example.com/2.srt", language: "en", label: "720p.HDTV", source: "OpenSubtitles v3")),
            badge: "OpenSubtitles v3",
            title: "English",
            detail: "720p.HDTV",
            language: "English",
            isSelected: false
        )
        let group = SubtitleLanguageGroup(
            language: "English",
            options: [externalOption, unselectedOption]
        )

        XCTAssertTrue(group.hasSelected)
        XCTAssertEqual(group.selectedOption?.id, "ext-1")
        XCTAssertEqual(SubtitleMenuFormatter.optionDisplayTitle(for: externalOption), "WEB-DL.x264")

        let builtInWithDetail = SubtitlePanelOption(
            id: "track-1",
            kind: .track(SubtitleTrack(id: "1", name: "English", language: "eng", isSelected: true, externalFilename: "")),
            badge: "Built in",
            title: "English",
            detail: "SDH",
            language: "English",
            isSelected: true
        )
        XCTAssertEqual(SubtitleMenuFormatter.optionDisplayTitle(for: builtInWithDetail), "English (SDH)")
    }

    @MainActor
    func testAudioDelayPersistenceLifecycle() {
        let coordinator = PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        let model = PlayerViewModel(
            sessionCoordinator: coordinator,
            scrubThumbnailProvider: nil
        )

        // Clean up before test
        ProfileSettings.current.removeObject(forKey: SettingsKey.audioDelayPersistEnabled)
        ProfileSettings.current.removeObject(forKey: SettingsKey.persistentAudioDelayMs)
        defer {
            ProfileSettings.current.removeObject(forKey: SettingsKey.audioDelayPersistEnabled)
            ProfileSettings.current.removeObject(forKey: SettingsKey.persistentAudioDelayMs)
        }

        // 1. By default, audio delay persistence is disabled
        XCTAssertFalse(model.isAudioDelayPersistEnabled)
        XCTAssertEqual(model.audioDelayMs, 0)

        // 2. Setting audio delay when persistence is disabled does not persist to settings
        model.setAudioDelayMs(250)
        XCTAssertEqual(model.audioDelayMs, 250)
        XCTAssertEqual(ProfileSettings.current.integer(forKey: SettingsKey.persistentAudioDelayMs), 0)

        // 3. Enabling persistence saves current delay and updates setting
        model.setAudioDelayPersistEnabled(true)
        XCTAssertTrue(model.isAudioDelayPersistEnabled)
        XCTAssertEqual(ProfileSettings.current.integer(forKey: SettingsKey.persistentAudioDelayMs), 250)

        // 4. Modifying delay while persistence is enabled updates persisted value
        model.setAudioDelayMs(-150)
        XCTAssertEqual(model.audioDelayMs, -150)
        XCTAssertEqual(ProfileSettings.current.integer(forKey: SettingsKey.persistentAudioDelayMs), -150)

        // 5. Clamping works as expected (-3000ms to +3000ms)
        model.setAudioDelayMs(5000)
        XCTAssertEqual(model.audioDelayMs, 3000)
        XCTAssertEqual(ProfileSettings.current.integer(forKey: SettingsKey.persistentAudioDelayMs), 3000)

        model.setAudioDelayMs(-4000)
        XCTAssertEqual(model.audioDelayMs, -3000)
        XCTAssertEqual(ProfileSettings.current.integer(forKey: SettingsKey.persistentAudioDelayMs), -3000)

        // 6. Resetting / disabling persistence keeps current session delay but unsets persist flag
        model.setAudioDelayMs(100)
        model.setAudioDelayPersistEnabled(false)
        XCTAssertFalse(model.isAudioDelayPersistEnabled)
        XCTAssertEqual(model.audioDelayMs, 100)
    }

    @MainActor
    func testAudioDelayPersistenceAcrossPlaybackSessions() {
        ProfileSettings.current.removeObject(forKey: SettingsKey.audioDelayPersistEnabled)
        ProfileSettings.current.removeObject(forKey: SettingsKey.persistentAudioDelayMs)
        defer {
            ProfileSettings.current.removeObject(forKey: SettingsKey.audioDelayPersistEnabled)
            ProfileSettings.current.removeObject(forKey: SettingsKey.persistentAudioDelayMs)
        }

        let coordinator = PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        let model = PlayerViewModel(
            sessionCoordinator: coordinator,
            scrubThumbnailProvider: nil
        )

        // Enable persistence and set delay to 350ms
        model.setAudioDelayMs(350)
        model.setAudioDelayPersistEnabled(true)
        XCTAssertEqual(model.audioDelayMs, 350)

        // Start a new stream session (applyStreamState with preserveSessionPreferences = false)
        let sampleMeta = NuvioMeta(
            id: "tt1234567",
            name: "Sample Movie",
            type: "movie",
            year: 2024,
            genres: [],
            rating: 8.0,
            releaseInfo: "2024",
            runtime: "120 min"
        )
        model.applyStreamState(
            url: URL(string: "https://example.com/video.mkv")!,
            meta: sampleMeta,
            subtitle: "Sample Subtitle",
            httpHeaders: [:],
            externalSubtitles: [],
            resumeFrom: nil,
            preserveSessionPreferences: false
        )

        // Audio delay should have reloaded from persistent settings!
        XCTAssertEqual(model.audioDelayMs, 350)

        // Disable persistence
        model.setAudioDelayPersistEnabled(false)

        // Start another session without preserving session preferences
        model.applyStreamState(
            url: URL(string: "https://example.com/video2.mkv")!,
            meta: sampleMeta,
            subtitle: "Sample Subtitle 2",
            httpHeaders: [:],
            externalSubtitles: [],
            resumeFrom: nil,
            preserveSessionPreferences: false
        )

        // Audio delay should have reset to 0!
        XCTAssertEqual(model.audioDelayMs, 0)
    }
}

extension PlayerControlsSettingsTests {
    @MainActor
    func testPlaybackPollNotifiesSceneOnObservedPauseAndResumeOnce() async {
        let frameProvider = PollingSceneFrameProvider()
        let scene = SceneCoordinator(
            frameProvider: frameProvider,
            castProvider: EmptyPlaybackSceneCastProvider(),
            soundtrackProvider: EmptyPlaybackSceneSoundtrackProvider())
        let session = PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        let model = PlayerViewModel(sessionCoordinator: session, sceneCoordinator: scene)
        defer { scene.closePanel(); model.shutdown() }

        let context = SceneContext(canonicalId: "poll-pause-transition", mediaType: "movie", title: "Pause Transition")
        model.status = .playing
        model.showScenePanel = true
        model.sceneCoordinator.updateContext(context)
        let firstCapture = expectation(description: "Panel begins its playing capture loop")
        let pausedCapture = expectation(description: "Observed engine pause captures one frozen frame")
        let explicitPauseCapture = expectation(description: "Explicit pause captures one frozen frame")
        frameProvider.onCapture = { count in
            if count == 1 { firstCapture.fulfill() }
            if count == 2 { pausedCapture.fulfill() }
            if count == 3 { explicitPauseCapture.fulfill() }
        }
        model.sceneCoordinator.openPanel()
        await fulfillment(of: [firstCapture], timeout: 2)
        XCTAssertTrue(scene.isFrameSamplingActive)

        let engine = PlayerControlsTestEngine()
        engine.isPlayerPlaying = true
        engine.isTransportPlaying = true
        engine.hasCoherentTimeSample = true
        engine.durationMs = 120_000
        engine.positionMs = 20_000
        model.pollForTesting(using: engine)

        engine.isPlayerPlaying = false
        engine.isTransportPlaying = false
        model.pollForTesting(using: engine)
        await fulfillment(of: [pausedCapture], timeout: 2)
        XCTAssertEqual(model.status, .paused)
        XCTAssertFalse(scene.isFrameSamplingActive, "Paused Insight should retain only its one-shot frame")

        model.pollForTesting(using: engine)
        XCTAssertEqual(frameProvider.captureCount, 2, "Repeated paused polls must not capture another frame")

        engine.isPlayerPlaying = true
        engine.isTransportPlaying = true
        model.pollForTesting(using: engine)
        XCTAssertEqual(model.status, .playing)
        XCTAssertTrue(scene.isFrameSamplingActive, "The observed resume should restart scene sampling")

        model.pause()
        await fulfillment(of: [explicitPauseCapture], timeout: 2)
        engine.isPlayerPlaying = false
        engine.isTransportPlaying = false
        model.pollForTesting(using: engine)
        XCTAssertEqual(frameProvider.captureCount, 3, "Polling must not duplicate the explicit pause capture")
        XCTAssertFalse(scene.isFrameSamplingActive)
    }

    @MainActor
    func testPausedOpenAndSeekAreOneShotAndBufferingDoesNotResumeSceneScan() async {
        let frameProvider = PollingSceneFrameProvider()
        let scene = SceneCoordinator(
            frameProvider: frameProvider,
            castProvider: EmptyPlaybackSceneCastProvider(),
            soundtrackProvider: EmptyPlaybackSceneSoundtrackProvider())
        let session = PlaybackSessionCoordinator(aetherControllerFactory: { nil })
        let model = PlayerViewModel(sessionCoordinator: session, sceneCoordinator: scene)
        defer { scene.closePanel(); model.shutdown() }

        let context = SceneContext(canonicalId: "paused-one-shot", mediaType: "movie", title: "Paused")
        model.status = .paused
        model.showScenePanel = true
        model.sceneCoordinator.updateContext(context)
        let openCapture = expectation(description: "Paused open captures one frame")
        let seekCapture = expectation(description: "Paused seek captures one new frame")
        let resumedCapture = expectation(description: "Playback resumes Insight sampling after buffering")
        frameProvider.onCapture = { count in
            if count == 1 { openCapture.fulfill() }
            if count == 2 { seekCapture.fulfill() }
            if count == 3 { resumedCapture.fulfill() }
        }
        model.sceneCoordinator.openPanel()
        await fulfillment(of: [openCapture], timeout: 2)
        XCTAssertFalse(scene.isFrameSamplingActive)

        scene.handleSeek()
        await fulfillment(of: [seekCapture], timeout: 2)
        XCTAssertFalse(scene.isFrameSamplingActive, "Paused seek should not leave a polling task armed")

        let engine = PlayerControlsTestEngine()
        engine.isPlayerLoading = true
        engine.isPlayerPlaying = false
        engine.isTransportPlaying = false
        engine.durationMs = 120_000
        engine.positionMs = 20_000
        model.pollForTesting(using: engine)
        XCTAssertEqual(model.status, .buffering)
        XCTAssertFalse(scene.isFrameSamplingActive)
        XCTAssertEqual(frameProvider.captureCount, 2)

        engine.isPlayerLoading = false
        engine.isPlayerPlaying = true
        engine.isTransportPlaying = true
        model.pollForTesting(using: engine)
        await fulfillment(of: [resumedCapture], timeout: 2)
        XCTAssertEqual(model.status, .playing)
        XCTAssertTrue(scene.isFrameSamplingActive)

        model.sceneCoordinator.closePanel()
        model.showScenePanel = false
        engine.isPlayerPlaying = false
        engine.isTransportPlaying = false
        model.pollForTesting(using: engine)
        XCTAssertEqual(frameProvider.captureCount, 3, "Closed Insight must not capture from the poll path")
        XCTAssertFalse(scene.isFrameSamplingActive)
    }

    @MainActor
    func testSourceSwitchHidesControlsAndSuppressesReveal() async {
        let model = PlayerViewModel()
        defer { model.shutdown() }
        model.status = .playing
        model.showControls = true
        XCTAssertTrue(model.showControls)

        model.openSidePanel(.sources)
        XCTAssertFalse(model.showControls)
        XCTAssertEqual(model.sidePanel, .sources)

        let stream = NuvioStream(
            url: "http://example.com/stream.m3u8",
            name: "1080p Stream",
            description: "Test",
            addonName: "Addon"
        )
        model.activeMeta = NuvioMeta(id: "movie-1", name: "Movie", type: "movie")
        model.resolvePlaybackStream = { _, _, _, _ in nil }
        model.selectSource(stream)

        // Controls must stay hidden when side panel closes during a source switch
        XCTAssertFalse(model.showControls, "Controls must stay hidden during source switch")
        XCTAssertTrue(model.isSwitchingSource, "isSwitchingSource must be true")

        // Attempting to reveal controls while switching source must be suppressed
        model.revealControls()
        XCTAssertFalse(model.showControls, "revealControls must be suppressed while isSwitchingSource is true")
    }

    @MainActor
    func testCloseSidePanelDuringReloadOrAwaitingStreamStartKeepsControlsHidden() {
        let model = PlayerViewModel()
        defer { model.shutdown() }
        model.status = .playing

        model.openSidePanel(.sources)
        XCTAssertFalse(model.showControls)

        // Simulate awaiting stream start
        model.setAwaitingStreamStartForTesting(true)
        model.closeSidePanel()
        XCTAssertFalse(model.showControls, "closeSidePanel must not reveal controls while isAwaitingStreamStart is true")

        // revealControls should also be suppressed
        model.revealControls()
        XCTAssertFalse(model.showControls, "revealControls must be suppressed while isAwaitingStreamStart is true")
    }
}

@MainActor
final class NextEpisodeAetherTransitionRegressionTests: XCTestCase {
    func testAdvanceLoadsNextLocalEpisodeOnSameAetherController() async throws {
        guard let controller = AetherPlaybackController() else {
            throw XCTSkip("AetherEngine is unavailable in this test environment")
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nuvio-next-up-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appendingPathComponent("episode-1.mp4")
        let secondURL = directory.appendingPathComponent("episode-2.mp4")
        let fixture = try makeLocalFixture()
        try fixture.write(to: firstURL)
        try fixture.write(to: secondURL)

        let coordinator = PlaybackSessionCoordinator(
            aetherController: controller,
            engineSettingProvider: { "AetherEngine" }
        )
        let model = PlayerViewModel(sessionCoordinator: coordinator)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            model.cancelStartupBenchmark()
            model.shutdown()
            window.isHidden = true
            window.rootViewController = nil
            try? FileManager.default.removeItem(at: directory)
        }

        let meta = NuvioMeta(id: "next-up-local-fixture", name: "Next Up Fixture", type: "series")
        let episode1 = NuvioVideo(id: "fixture:1:1", title: "Episode 1", season: 1, episode: 1)
        let episode2 = NuvioVideo(
            id: "fixture:1:2",
            title: "Episode 2",
            season: 1,
            episode: 2,
            released: "2024-01-01T00:00:00.000Z"
        )

        model.load(
            url: firstURL,
            meta: meta,
            subtitle: "S1 · E1",
            resumeFrom: nil,
            currentEpisode: episode1
        )
        let initialGeneration = coordinator.loadGeneration
        let firstEpisodeReady = await waitForPlayback(timeout: 20) {
            model.status == .playing
                && controller.isPlayerPlaying
                && controller.isTransportPlaying
                && !controller.isPlayerLoading
                && !controller.audioTracks.isEmpty
                && coordinator.hasPresentedCurrentAetherLoad(generation: coordinator.loadGeneration)
        }
        XCTAssertTrue(firstEpisodeReady, playbackDiagnostics("episode 1", model: model, coordinator: coordinator, controller: controller))
        XCTAssertEqual(coordinator.activeBackend, .aether)
        XCTAssertTrue(coordinator.aetherController === controller)

        model.configureNextEpisode(
            episodes: [episode1, episode2],
            current: episode1,
            autoPlayEnabled: false,
            autoPlayCountdownSeconds: 10,
            resolver: { _, _ in
                PreparedNextStream(url: secondURL, subtitleLine: "S1 · E2", subtitles: [])
            }
        )
        model.advance()

        let nextEpisodeReady = await waitForPlayback(timeout: 20) {
            coordinator.loadGeneration > initialGeneration
                && coordinator.lastRequest?.videoURL == secondURL
                && model.status == .playing
                && !model.isAdvancingEpisode
                && controller.isPlayerPlaying
                && controller.isTransportPlaying
                && !controller.isPlayerLoading
                && !controller.audioTracks.isEmpty
                && coordinator.hasPresentedCurrentAetherLoad(generation: coordinator.loadGeneration)
        }
        XCTAssertTrue(nextEpisodeReady, playbackDiagnostics("episode 2 after advance", model: model, coordinator: coordinator, controller: controller))
        XCTAssertTrue(coordinator.aetherController === controller, "The transition must retain the original Aether controller")
        XCTAssertEqual(coordinator.lastRequest?.videoURL, secondURL)
        XCTAssertEqual(model.status, .playing)
        XCTAssertFalse(model.isAdvancingEpisode, "Aether presenting playback must release the Next Up loading state")
        XCTAssertTrue(controller.isTransportPlaying, "The next file's AAC track must be active on the existing controller")
        XCTAssertFalse(controller.audioTracks.isEmpty, "The next file must expose its local AAC track")
    }

    private func makeLocalFixture() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Self.localH264AACFixture, options: .ignoreUnknownCharacters))
    }

    private func waitForPlayback(timeout: TimeInterval, condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func playbackDiagnostics(
        _ phase: String,
        model: PlayerViewModel,
        coordinator: PlaybackSessionCoordinator,
        controller: AetherPlaybackController
    ) -> String {
        let requestName = coordinator.lastRequest?.videoURL.lastPathComponent ?? "none"
        let checkpoint = controller.engine.startupProgress.map { String(describing: $0.checkpoint) } ?? "none"
        return "\(phase): status=\(model.status), advancing=\(model.isAdvancingEpisode), backend=\(coordinator.activeBackend), generation=\(coordinator.loadGeneration), request=\(requestName), engine=\(controller.engine.state), checkpoint=\(checkpoint), presented=\(coordinator.hasPresentedCurrentAetherLoad(generation: coordinator.loadGeneration)), loading=\(controller.isPlayerLoading), playerPlaying=\(controller.isPlayerPlaying), transportPlaying=\(controller.isTransportPlaying), audioTracks=\(controller.audioTracks.count), error=\(controller.currentErrorMessage), coordinatorError=\(coordinator.lastLoadError ?? "none")"
    }

    // 1.2-second H.264/AAC tone fixture, embedded so the test needs no network or external media tool.
    private static let localH264AACFixture = """
AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAarbW9vdgAAAGxtdmhkAAAAAAAAAAAA
AAAAAAAD6AAABLAAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA
AABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwAAArx0cmFrAAAAXHRraGQAAAADAAAA
AAAAAAAAAAABAAAAAAAABI8AAAAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAA
AAAAAAAAAABAAAAAAEAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAASPAAAAAAABAAAA
AAI0bWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAwAAAAOABVxAAAAAAALWhkbHIAAAAAAAAAAHZp
ZGUAAAAAAAAAAAAAAABWaWRlb0hhbmRsZXIAAAAB321pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAA
ACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAZ9zdGJsAAAAt3N0c2QAAAAAAAAA
AQAAAKdhdmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAAAAAAAAABFUxhdmM2
Mi4yOC4xMDIgbGlieDI2NAAAAAAAAAAAAAAAGP//AAAALWF2Y0MBQsAe/+EAFmdCwB7aEJsBEAAA
AwAQAAADAYjxYuoBAARozg/IAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAAFSIAAAAAAAAA
GHN0dHMAAAAAAAAAAQAAAA4AAAQAAAAAGHN0c3MAAAAAAAAAAgAAAAEAAAANAAAAHHN0c2MAAAAA
AAAAAQAAAAEAAAABAAAAAQAAAExzdHN6AAAAAAAAAAAAAAAOAAACeQAAAAoAAAAKAAAACgAAAAoA
AAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAAJAAAAAoAAABIc3RjbwAAAAAAAAAOAAAHbgAA
CtAAAAu8AAAMqAAADYcAAA3gAAAOjAAAD2IAABAMAAAQtAAAEQ8AABH5AAAS6QAAE/EAAAMZdHJh
awAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAgAAAAAAAASwAAAAAAAAAAAAAAABAQAAAAABAAAAAAAA
AAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAA
AAABAAAEsAAABAAAAQAAAAACkW1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAAViIAAGtcVcQAAAAA
AC1oZGxyAAAAAAAAAABzb3VuAAAAAAAAAAAAAAAAU291bmRIYW5kbGVyAAAAAjxtaW5mAAAAEHNt
aGQAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1cmwgAAAAAQAAAgBzdGJsAAAA
fnN0c2QAAAAAAAAAAQAAAG5tcDRhAAAAAAAAAAEAAAAAAAAAAAABABAAAAAAViIAAAAAADZlc2Rz
AAAAAAOAgIAlAAIABICAgBdAFQAAAAAARTIAAEUyBYCAgAUTiFblAAaAgIABAgAAABRidHJ0AAAA
AAAARTIAAEUyAAAAIHN0dHMAAAAAAAAAAgAAABoAAAQAAAAAAQAAA1wAAABYc3RzYwAAAAAAAAAG
AAAAAQAAAAEAAAABAAAAAgAAAAIAAAABAAAABgAAAAEAAAABAAAABwAAAAIAAAABAAAACwAAAAEA
AAABAAAADAAAAAIAAAABAAAAgHN0c3oAAAAAAAAAAAAAABsAAACTAAAAgwAAAGYAAABmAAAAfAAA
AFQAAACOAAAATAAAAIkAAABPAAAATwAAAFMAAACBAAAASwAAAE8AAABRAAAASgAAAFQAAABRAAAA
kAAAAFAAAACWAAAAUAAAAJMAAABRAAAAXgAAAF8AAABMc3RjbwAAAAAAAAAPAAAG2wAACecAAAra
AAALxgAADLIAAA2RAAAN6gAADpYAAA9sAAAQFgAAEL4AABEZAAASAwAAEw0AABP7AAAAGnNncGQB
AAAAcm9sbAAAAAIAAAAB//8AAAAcc2JncAAAAAByb2xsAAAAAQAAABsAAAABAAAAYnVkdGEAAABa
bWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRpcmFwcGwAAAAAAAAAAAAAAAAtaWxzdAAAACWpdG9v
AAAAHWRhdGEAAAABAAAAAExhdmY2Mi4xMi4xMDIAAAAIZnJlZQAADeVtZGF03gIATGF2YzYyLjI4
LjEwMgACWKJUUiL+13Wc+/67/Ep4+N5qVNUkLDFYnFYnFYnj3VTRlUxrVdrVlsWJs3GePw2+6VUa
sKUKVO2KsyVZkn1spVGVRlcZKBgb+jf0YGBgYGBgYGBgYGNmwYGRIgYGBgYGRIpZZZZZZZZZZZZZ
ZZZZZZZZZZZZZZZZZZZZZZZZZZZeAAACUgYF//9O3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3Jl
IDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIw
MDMtMjAyNSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNh
YmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9
MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRy
ZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21h
X3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRz
PTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWlu
ZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0xMiBrZXlpbnRfbWluPTEgc2Nl
bmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMy4wIHFjb21wPTAu
NjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAAB9liIQ6
EYoAAhjxwABA9jgACHlJycnXXXXXXXXXXXXgARKS2spzZLmyXNkuX/9P/7/HVy9e//9b/3+uuLvX
5//q//P364vi/4//q//b461qdB29pMMgwMDAwM6JU9fqYr2E4tgRkYxGoio1xUfSKj6RUfTdxKg3
018YjLObjU/JG9KYCbURmRRsijeijeiD0UU4eeii6A8yA10Jip55555/lzcBIvEREFKrLe+Txf2+
3+ntc6alpqpd1wlagFBWikoKCmomqpLTYV4s1kmayEz/x8GT7+5D4+Gx7+8IyfGYZ/eEP/Bg77wh
/4bA94R8fGYZ/fQD/GYJ99AfyZgv30B/4ME6NAR8cOAAAAAGQZogEaCMAOwxENRieZ1av81rnP/7
3P/z/lE1vW5UiZcYgvFdp+hkboicRm8bPFR+1OuzARRGe79OlmnvLS84l5y4M0sR3JS6EFilAQnz
7Ee26PIrujTaeI7GsM2jvMl5/6Aow6SvAUhfd5+AAT4xACpbMjFQgn//vj9id//29/+f++RM13xK
sziVdXQOFffyhrY6RrgjXIgU5ZokcsgPlB2GYYeDEh6wtgvCs3g8GbeAzCkuAYGKuiMaFwCTom2s
/j7d9PQrum4jNxiVCdpiThMZ1Nd4/p2u/W1jtGJBZvKPnoDCIw55wAAAAAZBmkARoIwA8DERMjGy
U8O9z/4/t/9/83cvfSs1zpXfWt7uxEDR0VSyy/0Of7n68+dQRatWrVqhmghJnx18Webh1VS1YU5V
457ykLptMM5mnAxNdjcE5guq08ABPjEAKFs6OcLDgLCf//q+3DH/9n+P/P/zrnjaUsaqukpYfXX3
abjjy2W1Gt5c2rqxHLgBu9F5QNkcZU+U/nZl/nQmaaZZ6akvDCphHbQWnrLmmy8rwJCM1YYeoI8S
ZfEjtsi2Ya2XCV8jIBOiY0Vcmewok9B9w+ledKkUE7OQg1tKEyRRLsxptOxw7eHAAAAABkGaYBGg
jADwMQqC5I+Zvx8//2v0/9//3cSlcZvUb056Z49gRpR8kfL5fI78ZgYfL5fLYjZEEIJ8plYZmo/d
3QK+hQCJTRqL3rYquLCtKlVBDtwBPjEAKGsqPgSCgLCf/+3uzrx//F7//f/Mpkm9Ki163IBzSW6E
65iVgxLcpX0OQAKUyDTChtfPfpITqkJ0SE3SrQkJmhfLLDComswgEzuRy9p16lEFRZGGpbnckt5i
IFKimiWHwOUmCIU8OZDsdcwErfecXumFS8LAN0qzUMVAmIRF8si3GjHPhwAAAAZBmoASoIwA7DEK
Yvb16yufHz//a+f/4f+tSrl0zjZPHmV4+KD3VzHPPPOc6ow3OeedSlTg/rDU36LUNEbyvSlylLti
gna6JTfPfYq4jKK/LR2ULrOPAAAABkGaoBKgjADqMQqi0zO857+f/7fv/+P/5qRJKqSZ48r9/IZp
NyXnnnkpYYB79seeZIm5zveTExnfOTca9eOcs31hJ5MsgjCGcrISqZpDEQRguSSS9PAA8DELIpa3
W978fP/9v5/9//31JKE13xl/b2ufPxBhLWef1/Xqc8JAq/Xo9Y/Xp9cKAozQo6pws/j0Tg6/qZZg
78EhewF8lN9lbXEiC24XG3RfgAAAAAZBmsASoIwBPjEAKlszDJjBQbhYT//vf7PPe//r7/+X/WNo
rWIXElWB6ec/Qjelh1rDrdFPl/N2MZB20uLCgFnWhZ6p1y5cuUUhftDwcKJ5HedA7nsSukYEaHtv
erGBn/TXztgKjMC6rNAbdoo7ddbs41CO61LnGdlahkeUaqGYAU0WIB1pHRwA6jEJ4zXme9c88//3
v2/9//1msidd1qrV3rivf4CheqBdFFFCyIEuiiii0Yo7IxnHZKJEyiC3RCJ2GzYGVDH81ErxEiKI
upFSHTgAAAAGQZrgEqCMAOwxCoLmVr1vPHf/939P/P/9bmcSpVXEr5+F/PxQdhiqiRly5XzGBhFF
FxIsr47lI2Eqm93N6K5aUhk1Hp10oL3LFRkuPEKE6YMcJiBLfwDqMQoDJTfOb8fP/9v5/9//1tar
okytfPnVevvsWnb5+fz8/NKbiEL303fRa/ojF8PV62y3VWxytrRkJs6AnsjQqh7FZNdajOQn661t
MhLOlwAAAAZBmwASoIwA7jEKQwMnPPPfz//b9//x//RVpU63V5ed9R66oNZN85555znUYNz8085+
acTzz3Qe5CdLUeZtUVvam+oI3usVjeegpX4DaC4AtwDqMQtidzrnne/Hz//a+f/4f+8aVDOFVPt9
49/gLUpYlLzyUsbCg88l57F5iXcWISJAHnLU7XXhcxK0rekdYL7Y84rM3gVpbX8AzicKZ8BljLq6
8AAAAAZBmyASoIwA8DELYnJvOee/n/+37//P/61WqtN6ZZ4409/YD9Bz9XrPOc8JBmHR1Rn6go6l
0L6mgqMq6sDvitpoMEql1QLGa5sL7D8NrE84sRbNi5ShPhwAAAAGQZtAEqCMAT4xAFakexHCwn//
751K8f/xfb/2/7rzLVFcZKuXM1QAEh8QdItuiDzxmOeOZy/79nCQc5HCw6f5npPjP6n+pi/kYHLL
xmiLASKNhjGxztHg+ImDMuUREefxjseVAAE+GobBSK0OoLMgrzhlRGJbTiwJ77K9Da27D2fNehr4
tTXnaot3yzs6q+saDuzVT0aOAPIxCiMWsnque+f/737f+//75TW5qpVVxXv8XXv8AjKutdFFHSsi
BCihdBqOnBFbZGzabLLIoo4rO91BfIcLNGS1+SOJ+wsTb/BFvGit8/AAAAAGQZtgEqCMAT4xAEg7
Ow0YxIG//8euKb//s/1/9/+/GVru1XdVqq4ky4H+4mTq0quKNbyzjt5fRQ+rxe91xYUELapqtFSP
NVMotDSqxl86WXFnHh/J0ltSADNKfLyfDP8PUN+cBQwAAf1PVfpKzJTlouOrCwa5xBiG8aFvwyec
koEk5x9tEOUqtcI0ZI5Ym6RwPqA9V3ngNsAJhmXXAPAxCgMkqt1459//7f6f+//77pMvXdypJ44u
vXkHtZkr+m76JduIQuu/R12A1rWtK1prYVln4pWgWth25GUYciXAteuzkckBlFoaCYSh34AAAAAg
ZYiCAToRigACt/HAAEjmOAALa0nJyddddddddddddeABPjEAKFszDRkFYT//xXvxde//8Xz/6/7c
X4uUky0tdaoD8ZRXvozdiU26+iO5i/ovq6HlM6AMBNbTXN3Y4K94GvA1dV6sOvZigp0yKWMeSrqy
8gYuQnuXExpwLE4HwlsjIAnSAJAKBgoqVAAIRJFNpoAgmICspbSVwc7/9piTKXrJNsQRHblURsdj
8csIVqde7pwA7jEKQwZfeZz4+f/7Xz//D/5yLmVcvLy/XWs9ewXpxS8888lLLgpnO8888l4Pd8ky
vVjjlhScq3lOTC9efOPB5oNyc8Ftcir9RlInAuTZYz4AAAAGQZogEaCMASgxC+MpVMz/4+f/v9au
5ckkiWiJB3X9Xc901aek6iHV3X9XcytGnpq09NWnpqxv6u6/q7r+ruvrQ901aemrT0qxX1d1/V3X
9UjOpDOlDOlQMoljFasVqxvriFab+AFIMQvjUKrM+2ff21qXJJJJItEg5tznNuc5tzh8yjOQ7nOb
c5zbnOZfPla58rXPla50K3Oc25zm3Oc1DMrXPla58rXPlVAifc5zbnObcyZbJlsytc+VUCFQIn3O
c1HA
"""
}
