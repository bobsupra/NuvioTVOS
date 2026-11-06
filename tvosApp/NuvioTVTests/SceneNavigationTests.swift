import XCTest
import SwiftUI
@testable import AetherEngine
@testable import NuvioTV

@MainActor
final class SceneNavigationTests: XCTestCase {
    
    func testRemoteDownOpensSceneWithoutPauseOrSeek() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        XCTAssertFalse(viewModel.showScenePanel)
        
        // Simulating remote Down when controls are hidden
        viewModel.openScene()
        
        XCTAssertTrue(viewModel.showScenePanel)
        XCTAssertEqual(viewModel.status, .playing, "Playback must not pause when Scene opens")
        XCTAssertEqual(viewModel.sceneViewModel.selectedTab, .scene, "Scene tab must be selected initially")
    }

    func testTouchpadSwipeDownOpensSceneWhenControlsHidden() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        viewModel.showControls = false
        XCTAssertFalse(viewModel.showScenePanel)

        viewModel.remoteTouchBegan()
        viewModel.remoteTouchMoved(dx: 0, dy: 35) // Downward swipe on touch surface

        XCTAssertTrue(viewModel.showScenePanel, "Swipe down on remote touchpad must open Scene panel")
        XCTAssertFalse(viewModel.showControls, "Swipe down on remote touchpad must not reveal transport controls")
        XCTAssertTrue(viewModel.moveSuppressed, "Swipe down should briefly suppress move commands")
        XCTAssertEqual(viewModel.status, .playing, "Playback must remain playing when Scene opens")

        viewModel.remoteTouchEnded(dx: 0, dy: 35)
    }

    func testTouchpadSwipeDownRevealsControlsWhenSceneDisabled() {
        let previous = ProfileSettings.current.object(forKey: SettingsKey.sceneFeatureEnabled)
        ProfileSettings.current.set(false, forKey: SettingsKey.sceneFeatureEnabled)
        defer {
            if let previous {
                ProfileSettings.current.set(previous, forKey: SettingsKey.sceneFeatureEnabled)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.sceneFeatureEnabled)
            }
        }

        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        viewModel.showControls = false
        XCTAssertFalse(viewModel.isSceneEnabled)
        XCTAssertFalse(viewModel.showScenePanel)

        viewModel.remoteTouchBegan()
        viewModel.remoteTouchMoved(dx: 0, dy: 35) // Downward swipe on touch surface

        XCTAssertFalse(viewModel.showScenePanel, "Scene panel must not open when disabled in settings")
        XCTAssertTrue(viewModel.showControls, "Swipe down should fall back to revealing controls when Scene is disabled")
        XCTAssertTrue(viewModel.moveSuppressed)

        viewModel.remoteTouchEnded(dx: 0, dy: 35)
    }

    func testTouchpadSwipeUpRevealsControls() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        viewModel.showControls = false
        XCTAssertFalse(viewModel.showScenePanel)

        viewModel.remoteTouchBegan()
        viewModel.remoteTouchMoved(dx: 0, dy: -35) // Upward swipe on touch surface

        XCTAssertFalse(viewModel.showScenePanel, "Swipe up must not open Scene panel")
        XCTAssertTrue(viewModel.showControls, "Swipe up on remote touchpad must reveal transport controls")
        XCTAssertTrue(viewModel.moveSuppressed)

        viewModel.remoteTouchEnded(dx: 0, dy: -35)
    }

    func testTouchpadSwipeUpFromTimelineDoesNotSuppressMove() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        viewModel.showControls = true
        viewModel.isTimelineFocused = true
        XCTAssertFalse(viewModel.showScenePanel)

        viewModel.remoteTouchBegan()
        viewModel.remoteTouchMoved(dx: 0, dy: -35) // Upward swipe on touch surface from timeline
        viewModel.remoteTouchEnded(dx: 0, dy: -35)

        XCTAssertFalse(viewModel.moveSuppressed, "Swipe up from timeline to transport buttons must not suppress move commands")
    }

    func testTouchpadSwipeDownFromTimelineOpensScene() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        viewModel.showControls = true
        viewModel.isTimelineFocused = true
        XCTAssertFalse(viewModel.showScenePanel)

        viewModel.remoteTouchBegan()
        viewModel.remoteTouchMoved(dx: 0, dy: 35) // Downward swipe from timeline

        XCTAssertTrue(viewModel.showScenePanel, "Swipe down from timeline must open Scene panel")
        XCTAssertFalse(viewModel.showControls, "Controls must be hidden when Scene panel opens")
        XCTAssertTrue(viewModel.moveSuppressed)

        viewModel.remoteTouchEnded(dx: 0, dy: 35)
    }

    func testTouchpadSwipeDownWithPauseOverlayRevealsControls() {
        let viewModel = PlayerViewModel()
        viewModel.status = .paused
        viewModel.showPauseOverlay = true
        viewModel.showControls = false
        XCTAssertFalse(viewModel.showScenePanel)

        viewModel.remoteTouchBegan()
        viewModel.remoteTouchMoved(dx: 0, dy: 35)

        XCTAssertFalse(viewModel.showScenePanel, "Pause overlay swipe should dismiss overlay and reveal controls, not open Scene")
        XCTAssertTrue(viewModel.showControls, "Controls should be revealed")
        XCTAssertFalse(viewModel.showPauseOverlay, "Pause overlay should be dismissed")

        viewModel.remoteTouchEnded(dx: 0, dy: 35)
    }

    func testTimelineDownPressOpensSceneWhenEnabled() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        viewModel.showControls = true
        viewModel.isTimelineFocused = true
        XCTAssertTrue(viewModel.isSceneEnabled)
        XCTAssertFalse(viewModel.showScenePanel)

        viewModel.openScene()

        XCTAssertTrue(viewModel.showScenePanel, "Down press from timeline must open Scene/InSight panel")
        XCTAssertFalse(viewModel.showControls, "Controls must be hidden when Scene/InSight panel opens")
    }

    func testRemoteDownDoesNotOpenSceneWhenDisabledInSettings() {
        let previous = ProfileSettings.current.object(forKey: SettingsKey.sceneFeatureEnabled)
        ProfileSettings.current.set(false, forKey: SettingsKey.sceneFeatureEnabled)
        defer {
            if let previous {
                ProfileSettings.current.set(previous, forKey: SettingsKey.sceneFeatureEnabled)
            } else {
                ProfileSettings.current.removeObject(forKey: SettingsKey.sceneFeatureEnabled)
            }
        }

        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        XCTAssertFalse(viewModel.isSceneEnabled, "isSceneEnabled must reflect ProfileSettings.current = false")
        XCTAssertFalse(viewModel.showScenePanel)

        // Simulating remote Down when controls are hidden
        viewModel.openScene()

        XCTAssertFalse(viewModel.showScenePanel, "Scene panel must not open when disabled in settings")
    }
    
    func testTabsAndCardsFocusNavigationLifecycle() {
        let coordinator = SceneCoordinator(
            frameProvider: UnsupportedSceneFrameProvider()
        )
        let sceneVM = SceneViewModel(coordinator: coordinator)
        
        sceneVM.open()
        XCTAssertTrue(sceneVM.isVisible)
        XCTAssertEqual(sceneVM.selectedTab, .scene)
        
        // Switching tabs
        sceneVM.selectTab(.info)
        XCTAssertEqual(sceneVM.selectedTab, .info)
        
        sceneVM.selectTab(.scene)
        XCTAssertEqual(sceneVM.selectedTab, .scene)
        
        // Opening detail sheet
        let actor = SceneRecognizedActor(id: "1", name: "Keanu Reeves", character: "Neo")
        sceneVM.openDetail(.actor(actor, detail: ScenePersonDetail(id: 1, name: "Keanu Reeves", biography: "Action star")))
        XCTAssertTrue(sceneVM.isDetailVisible)
        
        // Back/Menu closes detail first
        sceneVM.closeDetail()
        XCTAssertFalse(sceneVM.isDetailVisible)
        XCTAssertTrue(sceneVM.isVisible, "Closing detail sheet should keep Scene panel open")
        
        // Up/Back closes Scene panel
        sceneVM.close()
        XCTAssertFalse(sceneVM.isVisible)
    }
    
    func testControlsAutoHideSuspendedWhileSceneOpen() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        
        viewModel.openScene()
        XCTAssertTrue(viewModel.showScenePanel)
        
        // When Scene is open, closing it restores normal auto-hide behavior
        viewModel.closeScene()
        XCTAssertFalse(viewModel.showScenePanel)
    }
    
    func testPlayPauseTogglesPlaybackWithoutDismissingScene() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        viewModel.openScene()
        XCTAssertTrue(viewModel.showScenePanel)
        
        // Toggle play/pause
        viewModel.pause()
        XCTAssertEqual(viewModel.status, .paused)
        XCTAssertTrue(viewModel.showScenePanel, "Scene must remain open when pausing")
        
        viewModel.play()
        XCTAssertEqual(viewModel.status, .playing)
        XCTAssertTrue(viewModel.showScenePanel, "Scene must remain open when resuming")
        
        viewModel.closeScene()
    }
    
    func testScrubbingAndErrorPrecedenceOverScene() {
        let viewModel = PlayerViewModel()
        viewModel.status = .paused
        
        // When scrubbing, remote input is owned by scrub
        viewModel.beginScrub()
        // An active scrub retains input ownership; Down must not open Scene
        XCTAssertTrue(viewModel.isScrubbing)
        
        viewModel.cancelScrub()
        XCTAssertFalse(viewModel.isScrubbing)
    }
    
    func testSceneInfoTabPlaybackTelemetryPopulated() {
        let viewModel = PlayerViewModel()
        viewModel.status = .playing
        
        viewModel.openScene()
        XCTAssertTrue(viewModel.showScenePanel)
        
        // Assert playbackInfo is populated
        let playbackInfo = viewModel.sceneViewModel.playbackInfo
        XCTAssertNotNil(playbackInfo, "Playback info must be populated when opening Scene")
        XCTAssertEqual(playbackInfo?.engine, "AetherEngine")
        XCTAssertEqual(playbackInfo?.version, AetherEngine.version)
        XCTAssertEqual(playbackInfo?.videoCodec, "—")
        XCTAssertEqual(playbackInfo?.resolution, "—")
        XCTAssertEqual(playbackInfo?.frameRate, "—")
        XCTAssertEqual(playbackInfo?.dynamicRange, "—")
        XCTAssertNil(playbackInfo?.dolbyVisionProfile)
        XCTAssertEqual(playbackInfo?.videoBitrate, "—")
        XCTAssertEqual(playbackInfo?.container, "—")
        XCTAssertEqual(playbackInfo?.videoDecoder, "—")
        XCTAssertEqual(playbackInfo?.audioCodec, "—")
        XCTAssertEqual(playbackInfo?.audioChannels, "—")
        XCTAssertEqual(playbackInfo?.audioLanguage, "—")
        XCTAssertEqual(playbackInfo?.audioBitrate, "—")
        XCTAssertEqual(playbackInfo?.audioSpatialFormat, "Not confirmed")
        XCTAssertEqual(playbackInfo?.audioDecoder, "Unavailable")
        
        // Test Dolby Vision fallback telemetry model
        let dvInfo = ScenePlaybackInfo(
            dynamicRange: "Dolby Vision → HDR10",
            dolbyVisionProfile: "5"
        )
        viewModel.sceneViewModel.updatePlaybackInfo(dvInfo)
        XCTAssertEqual(viewModel.sceneViewModel.playbackInfo?.dynamicRange, "Dolby Vision → HDR10")
        XCTAssertEqual(viewModel.sceneViewModel.playbackInfo?.dolbyVisionProfile, "5")
        
        // Switching to info tab maintains playback telemetry
        viewModel.sceneViewModel.selectTab(.info)
        XCTAssertEqual(viewModel.sceneViewModel.selectedTab, .info)
        XCTAssertNotNil(viewModel.sceneViewModel.playbackInfo)
    }

    func testSceneAudioPresentationUsesStructuredSourceAndClearsOnTrackChangeOrHandoff() {
        let eac3Atmos = PlayerViewModel.sceneAudioPresentation(
            debug: PlaybackDebugInfo(
                audioSourceCodec: "eac3",
                audioSourceChannels: 6,
                audioSpatialFormat: "Atmos",
                audioPipeline: "APAC bridge"
            ),
            legacyDetails: "E-AC-3 | Atmos"
        )
        XCTAssertEqual(eac3Atmos.codec, "E-AC-3")
        XCTAssertEqual(eac3Atmos.channels, "Surround (5.1ch)")
        XCTAssertEqual(eac3Atmos.spatialFormat, "Atmos")
        XCTAssertEqual(eac3Atmos.pipeline, "APAC bridge")

        let ordinaryBridgeEAC3 = PlayerViewModel.sceneAudioPresentation(
            debug: PlaybackDebugInfo(
                audio: "E-AC-3 | 6 ch | passthrough",
                audioSourceCodec: "eac3",
                audioSourceChannels: 6
            ),
            legacyDetails: "E-AC-3 | 6 ch"
        )
        XCTAssertEqual(ordinaryBridgeEAC3.codec, "E-AC-3")
        XCTAssertEqual(ordinaryBridgeEAC3.channels, "Surround (5.1ch)")
        XCTAssertEqual(ordinaryBridgeEAC3.spatialFormat, "Not confirmed")
        XCTAssertEqual(ordinaryBridgeEAC3.pipeline, "Unavailable")

        let trueHDAtmos = PlayerViewModel.sceneAudioPresentation(
            debug: PlaybackDebugInfo(
                audioSourceCodec: "truehd",
                audioSourceChannels: 8,
                audioSpatialFormat: "Atmos",
                audioPipeline: "APAC 9.1.6"
            ),
            legacyDetails: "TRUEHD | Atmos"
        )
        XCTAssertEqual(trueHDAtmos.codec, "TRUEHD")
        XCTAssertEqual(trueHDAtmos.spatialFormat, "Atmos")
        XCTAssertEqual(trueHDAtmos.pipeline, "APAC 9.1.6")

        let dtsX = PlayerViewModel.sceneAudioPresentation(
            debug: PlaybackDebugInfo(
                audioSourceCodec: "dts-hd-ma",
                audioSourceChannels: 8,
                audioSpatialFormat: "DTS:X",
                audioPipeline: "APAC"
            ),
            legacyDetails: "DTS-HD MA | 8 ch"
        )
        XCTAssertEqual(dtsX.codec, "DTS-HD MA")
        XCTAssertEqual(dtsX.spatialFormat, "DTS:X")
        XCTAssertEqual(dtsX.pipeline, "APAC")

        let channelOnlyLegacyDetail = PlayerViewModel.sceneAudioPresentation(
            debug: PlaybackDebugInfo(audioSourceChannels: 6),
            legacyDetails: "6 ch | 48 kHz"
        )
        XCTAssertEqual(channelOnlyLegacyDetail.codec, "—")
        XCTAssertEqual(channelOnlyLegacyDetail.channels, "Surround (5.1ch)")

        let rawUnrecognizedCodec = PlayerViewModel.sceneAudioPresentation(
            debug: PlaybackDebugInfo(audioSourceCodec: "opus"),
            legacyDetails: "6 ch | 48 kHz"
        )
        XCTAssertEqual(rawUnrecognizedCodec.codec, "OPUS")

        let changedTrack = PlayerViewModel.sceneAudioPresentation(
            debug: PlaybackDebugInfo(audioSourceCodec: "eac3", audioSourceChannels: 2),
            legacyDetails: "E-AC-3 | 2 ch"
        )
        XCTAssertEqual(changedTrack.spatialFormat, "Not confirmed")
        XCTAssertEqual(changedTrack.pipeline, "Unavailable")

        let previousAether = PlaybackDebugInfo(
            audioSourceCodec: "truehd",
            audioSourceChannels: 8,
            audioSpatialFormat: "Atmos",
            audioPipeline: "APAC 9.1.6"
        )
        let mpvSnapshot = PlaybackDebugInfo(audio: "AAC | 2 ch")
        let activeSnapshot = PlayerViewModel.selectedScenePlaybackDebugInfo(
            activeEngineKind: .mpv,
            aether: previousAether,
            mpv: mpvSnapshot
        )
        let afterHandoff = PlayerViewModel.sceneAudioPresentation(
            debug: activeSnapshot,
            legacyDetails: nil
        )
        XCTAssertEqual(afterHandoff.codec, "AAC")
        XCTAssertEqual(afterHandoff.channels, "Stereo (2.0ch)")
        XCTAssertEqual(afterHandoff.spatialFormat, "Not confirmed")
        XCTAssertEqual(afterHandoff.pipeline, "Unavailable")
    }

    func testAetherAudioDiagnosticsUseTrackProfilesAndLivePipeline() {
        let trueHDAtmosTrack = TrackInfo(
            id: 1,
            name: "TrueHD Atmos",
            codec: "truehd",
            language: "en",
            channels: 8,
            isDefault: true,
            profile: "Dolby TrueHD + Dolby Atmos"
        )
        let trueHDAtmos = AetherPlaybackController.audioSourceDiagnostics(
            for: trueHDAtmosTrack,
            activeDecoder: "TrueHD Atmos → APAC 9.1.6"
        )
        XCTAssertEqual(trueHDAtmos.codec, "truehd")
        XCTAssertEqual(trueHDAtmos.channels, 8)
        XCTAssertEqual(trueHDAtmos.spatialFormat, "Atmos")
        XCTAssertEqual(trueHDAtmos.pipeline, "TrueHD Atmos → APAC 9.1.6")

        let trueHDAtmosWithoutProfile = TrackInfo(
            id: 5,
            name: "TrueHD",
            codec: "truehd",
            language: "en",
            channels: 8,
            isDefault: true,
            profile: nil
        )
        let trueHDAtmosFromPipeline = AetherPlaybackController.audioSourceDiagnostics(
            for: trueHDAtmosWithoutProfile,
            activeDecoder: "TrueHD Atmos → APAC 9.1.6"
        )
        XCTAssertEqual(trueHDAtmosFromPipeline.spatialFormat, "Atmos")

        let dtsXWithoutProfile = TrackInfo(
            id: 6,
            name: "DTS",
            codec: "dts",
            language: "en",
            channels: 8,
            isDefault: true,
            profile: nil
        )
        let dtsXFromPipeline = AetherPlaybackController.audioSourceDiagnostics(
            for: dtsXWithoutProfile,
            activeDecoder: "DTS:X → APAC 9.1.6"
        )
        XCTAssertEqual(dtsXFromPipeline.spatialFormat, "DTS:X")

        let loadingWithoutProfile = AetherPlaybackController.audioSourceDiagnostics(
            for: trueHDAtmosWithoutProfile,
            activeDecoder: "TrueHD Atmos → APAC 9.1.6",
            isLoading: true
        )
        XCTAssertNil(loadingWithoutProfile.spatialFormat)
        XCTAssertNil(loadingWithoutProfile.pipeline)

        let dtsXTrack = TrackInfo(
            id: 2,
            name: "DTS:X",
            codec: "dts",
            language: "en",
            channels: 8,
            isDefault: true,
            profile: "DTS-HD MA + DTS:X"
        )
        let dtsX = AetherPlaybackController.audioSourceDiagnostics(
            for: dtsXTrack,
            activeDecoder: "DTS:X → APAC 9.1.6"
        )
        XCTAssertEqual(dtsX.spatialFormat, "DTS:X")
        XCTAssertEqual(dtsX.pipeline, "DTS:X → APAC 9.1.6")

        let eac3JOCTrack = TrackInfo(
            id: 3,
            name: "E-AC-3 JOC",
            codec: "eac3",
            language: "en",
            channels: 6,
            isDefault: true,
            isAtmos: true,
            profile: "E-AC-3 + JOC"
        )
        let eac3JOC = AetherPlaybackController.audioSourceDiagnostics(
            for: eac3JOCTrack,
            activeDecoder: "Stream-copy (EAC3+JOC Atmos)"
        )
        XCTAssertEqual(eac3JOC.channels, 6)
        XCTAssertEqual(eac3JOC.spatialFormat, "Atmos")
        XCTAssertEqual(eac3JOC.pipeline, "Stream-copy (EAC3+JOC Atmos)")

        let ordinaryEAC3Track = TrackInfo(
            id: 4,
            name: "E-AC-3",
            codec: "eac3",
            language: "en",
            channels: 6,
            isDefault: true,
            profile: nil
        )
        let ordinaryBridge = AetherPlaybackController.audioSourceDiagnostics(
            for: ordinaryEAC3Track,
            activeDecoder: "E-AC3 → FLAC bridge"
        )
        XCTAssertNil(ordinaryBridge.spatialFormat)
        XCTAssertEqual(ordinaryBridge.pipeline, "E-AC3 → FLAC bridge")

        let loading = AetherPlaybackController.audioSourceDiagnostics(
            for: trueHDAtmosTrack,
            activeDecoder: "TrueHD Atmos → APAC 9.1.6",
            isLoading: true
        )
        XCTAssertEqual(loading.spatialFormat, "Atmos")
        XCTAssertNil(loading.pipeline, "a pipeline from the outgoing track is hidden during reload")
    }

    func testDolbyVisionRouteDescriptionUsesObservedRouteEvidence() {
        XCTAssertEqual(
            AetherPlaybackController.dolbyVisionRouteDescription(
                sourceProfile: 7,
                conversion: nil,
                felComposedFrameCount: 12
            ),
            "P7 FEL · 12 frames composed"
        )
        XCTAssertEqual(
            AetherPlaybackController.dolbyVisionRouteDescription(
                sourceProfile: 7,
                conversion: nil,
                felComposedFrameCount: 0
            ),
            "P7 FEL route · awaiting composition"
        )
        XCTAssertEqual(
            AetherPlaybackController.dolbyVisionRouteDescription(
                sourceProfile: 7,
                conversion: .profile7ToProfile81,
                felComposedFrameCount: nil
            ),
            "P7→8.1 libdovi"
        )
        XCTAssertEqual(
            AetherPlaybackController.dolbyVisionRouteDescription(
                sourceProfile: 7,
                conversion: nil,
                felComposedFrameCount: nil
            ),
            "P7"
        )
        XCTAssertEqual(
            AetherPlaybackController.dolbyVisionRouteDescription(
                sourceProfile: 8,
                conversion: nil,
                felComposedFrameCount: nil
            ),
            "P8"
        )
        XCTAssertNil(AetherPlaybackController.dolbyVisionRouteDescription(
            sourceProfile: nil,
            conversion: nil,
            felComposedFrameCount: nil
        ))
    }

    func testFreshAetherMetricsStayUnavailableAndMPVHandoffUsesActiveSnapshot() throws {
        guard let aetherController = AetherPlaybackController() else {
            throw XCTSkip("AetherEngine is unavailable in this test environment")
        }
        let aetherSnapshot = aetherController.playbackDebugInfo
        XCTAssertTrue(aetherSnapshot.frameRate.isEmpty)
        XCTAssertTrue(aetherSnapshot.aBitrate.isEmpty)
        XCTAssertNil(aetherSnapshot.audioSourceCodec)
        XCTAssertNil(aetherSnapshot.audioSourceChannels)
        XCTAssertNil(aetherSnapshot.audioSpatialFormat)
        XCTAssertNil(aetherSnapshot.audioPipeline)

        let mpvSnapshot = PlaybackDebugInfo(
            videoCodec: "AV1",
            resolution: "1920×1080",
            frameRate: "59.940 fps",
            vBitrate: "avg mux 8.0 Mbit/s",
            aBitrate: "meas 2.00 Mbit/s"
        )
        let activeSnapshot = PlayerViewModel.selectedScenePlaybackDebugInfo(
            activeEngineKind: .mpv,
            aether: aetherSnapshot,
            mpv: mpvSnapshot
        )

        XCTAssertEqual(activeSnapshot, mpvSnapshot)
        XCTAssertEqual(activeSnapshot?.videoCodec, "AV1")
        XCTAssertEqual(activeSnapshot?.frameRate, "59.940 fps")
        XCTAssertEqual(activeSnapshot?.aBitrate, "meas 2.00 Mbit/s")
    }

    func testSceneInfoUsesAetherDeliveryAndSyncGapThenClearsThemOnHandoff() throws {
        let engine = try AetherEngine()
        let outgoingPipeline = "TrueHD Atmos → APAC 9.1.6"
        engine.audioDelivery = .bridged
        engine.activeAudioDecoder = outgoingPipeline
        engine.audioTracks = [TrackInfo(
            id: 1,
            name: "TrueHD Atmos",
            codec: "truehd",
            language: "en",
            channels: 8,
            isDefault: true,
            profile: "Dolby TrueHD + Dolby Atmos"
        )]
        engine.activeAudioTrackIndex = 1
        engine.diagnostics.liveTelemetry = makeTelemetry(syncGapMs: -14.26)

        let aether = try XCTUnwrap(AetherPlaybackController(engine: engine))
        let coordinator = PlaybackSessionCoordinator(
            aetherController: aether,
            engineSettingProvider: { "AetherEngine" },
            loadDispatcher: { _, _, _ in }
        )
        let viewModel = PlayerViewModel(sessionCoordinator: coordinator)
        defer { viewModel.shutdown() }

        coordinator.load(PlaybackLoadRequest(videoURL: URL(string: "https://example.com/movie.mkv")!))
        let aetherDebug = aether.playbackDebugInfo
        let aetherInfo = viewModel.buildScenePlaybackInfo()
        XCTAssertEqual(aetherDebug.audioPipeline, "Bridged (\(outgoingPipeline))")
        XCTAssertTrue(aetherDebug.audio.hasSuffix("· \(aetherDebug.audioPipeline ?? "")"))
        XCTAssertEqual(aetherDebug.audioSourceCodec, "truehd")
        XCTAssertEqual(aetherDebug.audioSpatialFormat, "Atmos", "source profile evidence remains independent of the delivery label")
        XCTAssertEqual(aetherDebug.avSyncGapMs, -14.26)
        XCTAssertEqual(aetherInfo.audioDecoder, aetherDebug.audioPipeline)
        XCTAssertEqual(aetherInfo.audioSpatialFormat, "Atmos")
        XCTAssertEqual(aetherInfo.avSyncGapMs, -14.26)
        XCTAssertEqual(formattedAVSyncGap(aetherInfo.avSyncGapMs), "-14.3 ms")

        // Reload and no-session values cannot expose the outgoing pipeline. The
        // source profile can still establish Atmos while the live route is loading.
        engine.state = .loading
        engine.audioDelivery = .bridged
        engine.diagnostics.liveTelemetry = makeTelemetry(syncGapMs: .nan)
        let loadingDebug = aether.playbackDebugInfo
        XCTAssertNil(loadingDebug.audioPipeline)
        XCTAssertNil(loadingDebug.avSyncGapMs)
        XCTAssertEqual(loadingDebug.aJitter, "Unavailable")
        XCTAssertEqual(loadingDebug.audioSpatialFormat, "Atmos")
        XCTAssertFalse(loadingDebug.audio.contains(outgoingPipeline))
        XCTAssertEqual(formattedAVSyncGap(loadingDebug.avSyncGapMs), "Unavailable")
        let loadingInfo = viewModel.buildScenePlaybackInfo()
        XCTAssertEqual(loadingInfo.audioDecoder, "Unavailable")
        XCTAssertNil(loadingInfo.avSyncGapMs)

        engine.state = .idle
        engine.audioDelivery = .none
        engine.diagnostics.liveTelemetry = nil
        let idleDebug = aether.playbackDebugInfo
        XCTAssertNil(idleDebug.audioPipeline)
        XCTAssertNil(idleDebug.avSyncGapMs)
        XCTAssertFalse(idleDebug.audio.contains(outgoingPipeline))
        XCTAssertEqual(formattedAVSyncGap(nil), "Unavailable")
        XCTAssertEqual(formattedAVSyncGap(Double.infinity), "Unavailable")
        XCTAssertNil(PlayerViewModel.sceneAVSyncGap(debug: PlaybackDebugInfo(avSyncGapMs: Double.nan)))
        let idleInfo = viewModel.buildScenePlaybackInfo()
        XCTAssertEqual(idleInfo.audioDecoder, "Unavailable")
        XCTAssertNil(idleInfo.avSyncGapMs)

        coordinator.handoffToMPV(reason: "scene telemetry regression", resumeSeconds: 0)
        XCTAssertEqual(coordinator.activeBackend, .mpv)
        let mpvDebug = coordinator.mpvController.playbackDebugInfo
        let mpvInfo = viewModel.buildScenePlaybackInfo()
        XCTAssertNil(mpvDebug.avSyncGapMs)
        XCTAssertNil(mpvInfo.avSyncGapMs, "the previous Aether metric must not survive backend handoff")
        XCTAssertEqual(
            mpvInfo.audioDecoder,
            PlayerViewModel.sceneAudioPresentation(debug: mpvDebug, legacyDetails: nil).pipeline,
            "InSight keeps the active MPV pipeline fallback"
        )
        XCTAssertFalse(mpvInfo.audioDecoder.contains(outgoingPipeline))
    }

    private func makeTelemetry(syncGapMs: Double?) -> LiveTelemetry {
        LiveTelemetry(
            instantBitrateMbps: nil,
            averageBitrateMbps: nil,
            audioBridgeBitrateMbps: nil,
            observedFps: nil,
            droppedFrameCount: nil,
            forwardBufferSeconds: nil,
            cachedBytes: nil,
            networkThroughputMbps: nil,
            networkTransferredBytes: nil,
            avSyncGapMs: syncGapMs,
            producerRestartCount: 0,
            muxedBytesLifetime: 0,
            serverBytesSentLifetime: 0,
            serverRequestCount: 0,
            demuxerBytesFetched: 0,
            audioBridgeLiveBytes: 0,
            rssMb: 0
        )
    }

    func testSceneUpNextEpisodePlayabilityAndReleasePolicy() {
        let coordinator = SceneCoordinator(
            frameProvider: UnsupportedSceneFrameProvider()
        )
        let sceneVM = SceneViewModel(coordinator: coordinator)

        let airedEpisode = NuvioVideo(
            id: "ep1",
            title: "Aired Episode",
            season: 1,
            episode: 2,
            released: "2020-01-01T00:00:00Z"
        )
        let unreleasedEpisode = NuvioVideo(
            id: "ep2",
            title: "Future Episode",
            season: 1,
            episode: 3,
            released: "2099-01-01T00:00:00Z"
        )

        XCTAssertTrue(EpisodeReleasePolicy.hasAired(airedEpisode.released))
        XCTAssertFalse(EpisodeReleasePolicy.hasAired(unreleasedEpisode.released))

        sceneVM.setMetadata(
            title: "Test Show",
            year: 2026,
            overview: "Overview",
            runtime: "45m",
            nextEpisode: airedEpisode
        )
        XCTAssertEqual(sceneVM.nextEpisode?.id, "ep1")
        XCTAssertTrue(sceneVM.availableTabs.contains(.upNext))

        sceneVM.setMetadata(
            title: "Test Show",
            year: 2026,
            overview: "Overview",
            runtime: "45m",
            nextEpisode: unreleasedEpisode
        )
        XCTAssertEqual(sceneVM.nextEpisode?.id, "ep2")
        XCTAssertTrue(sceneVM.availableTabs.contains(.upNext))

        let panelView = ScenePanelView(
            viewModel: sceneVM,
            isAdvancing: true,
            onDismiss: {},
            onPlayNextEpisode: {}
        )
        XCTAssertTrue(panelView.isAdvancing)
    }

    func testPlayerAdvanceGuardsAgainstUnreleasedEpisode() {
        let viewModel = PlayerViewModel()
        defer { viewModel.shutdown() }

        let currentEpisode = NuvioVideo(
            id: "ep-current",
            title: "Current Episode",
            season: 1,
            episode: 1,
            released: "2020-01-01T00:00:00Z"
        )
        let unreleasedEpisode = NuvioVideo(
            id: "ep-future",
            title: "Future Episode",
            season: 1,
            episode: 2,
            released: "2099-01-01T00:00:00Z"
        )

        viewModel.configureNextEpisode(
            episodes: [currentEpisode, unreleasedEpisode],
            current: currentEpisode,
            autoPlayEnabled: true,
            autoPlayCountdownSeconds: 10,
            resolver: { _, _ in nil }
        )

        XCTAssertEqual(viewModel.nextEpisode?.id, unreleasedEpisode.id)
        XCTAssertFalse(EpisodeReleasePolicy.hasAired(unreleasedEpisode.released))

        viewModel.playNextEpisode()

        XCTAssertFalse(viewModel.isAdvancingEpisode, "playNextEpisode must not proceed when episode has not aired")
    }
}

