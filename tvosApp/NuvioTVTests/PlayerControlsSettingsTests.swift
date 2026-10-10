import XCTest
import CoreGraphics
@testable import NuvioTV

final class PlayerControlsSettingsTests: XCTestCase {
    func testPlayerControlsSettingsKeysDefined() {
        XCTAssertEqual(SettingsKey.playerShowPiP, "nuvio.tv.settings.playback.showPiP")
        XCTAssertEqual(SettingsKey.playerShowEpisodes, "nuvio.tv.settings.playback.showEpisodes")
        XCTAssertEqual(SettingsKey.playerShowSources, "nuvio.tv.settings.playback.showSources")
        XCTAssertEqual(SettingsKey.playerShowSubtitles, "nuvio.tv.settings.playback.showSubtitles")
        XCTAssertEqual(SettingsKey.playerShowAudio, "nuvio.tv.settings.playback.showAudio")
        XCTAssertEqual(SettingsKey.seekPreviewEnabled, "nuvio.tv.settings.playback.seekPreviewEnabled")
        XCTAssertEqual(SettingsKey.showLoadingStatus, "nuvio.tv.settings.playback.showLoadingStatus")

        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowPiP))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowEpisodes))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowSources))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowSubtitles))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.playerShowAudio))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.seekPreviewEnabled))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.showLoadingStatus))
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

        XCTAssertTrue(pipEnabled)
        XCTAssertTrue(episodesEnabled)
        XCTAssertTrue(sourcesEnabled)
        XCTAssertTrue(subtitlesEnabled)
        XCTAssertTrue(audioEnabled)
        XCTAssertTrue(seekPreviewEnabled)
        XCTAssertTrue(showLoadingStatus)

        // When explicitly set to false, it should disable
        defaults.set(false, forKey: SettingsKey.playerShowPiP)
        defaults.set(false, forKey: SettingsKey.playerShowEpisodes)
        defaults.set(false, forKey: SettingsKey.playerShowSources)
        defaults.set(false, forKey: SettingsKey.playerShowSubtitles)
        defaults.set(false, forKey: SettingsKey.playerShowAudio)
        defaults.set(false, forKey: SettingsKey.seekPreviewEnabled)
        defaults.set(false, forKey: SettingsKey.showLoadingStatus)

        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowPiP))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowEpisodes))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowSources))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowSubtitles))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.playerShowAudio))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.seekPreviewEnabled))
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.showLoadingStatus))
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
}



