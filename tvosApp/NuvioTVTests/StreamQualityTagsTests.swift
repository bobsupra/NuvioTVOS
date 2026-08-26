import XCTest
@testable import NuvioTV

final class StreamQualityTagsTests: XCTestCase {
    func testParsesDolbyVisionHDRAtmosAndResolution() {
        let tags = StreamQualityTags.parse(
            name: "Movie 2160p DV HDR Atmos",
            description: "Dolby Vision | TrueHD Atmos",
            filename: "Movie.2160p.DV.mkv"
        )
        XCTAssertEqual(tags.resolution, 2160)
        XCTAssertTrue(tags.isDolbyVision)
        XCTAssertTrue(tags.isHDR)
        XCTAssertTrue(tags.isAtmos)
    }

    func testParsesCachedMarkers() {
        let cached = StreamQualityTags.parse(name: "⚡ 1080p RD+", description: "Cached")
        XCTAssertTrue(cached.isCached)
        XCTAssertEqual(cached.resolution, 1080)

        let uncached = StreamQualityTags.parse(name: "1080p WEB-DL", description: "12 GB")
        XCTAssertFalse(uncached.isCached)
    }

    func testResumeMatchPrefersSameVisualAndAudio() {
        let preferred = StreamQualityTags(
            resolution: 2160,
            isDolbyVision: true,
            isHDR: true,
            isAtmos: true,
            isCached: true,
            bingeGroup: "release-a"
        )
        let perfect = StreamQualityTags(
            resolution: 2160,
            isDolbyVision: true,
            isHDR: true,
            isAtmos: true,
            isCached: true,
            bingeGroup: "release-a"
        )
        let hdrOnly = StreamQualityTags(
            resolution: 1080,
            isDolbyVision: false,
            isHDR: true,
            isAtmos: false,
            isCached: false,
            bingeGroup: "other"
        )
        XCTAssertGreaterThan(perfect.matchScore(against: preferred), hdrOnly.matchScore(against: preferred))
    }

    func testSmartSelectorRanksLastWatchedQualityFirst() {
        let sdr = NuvioStream(
            url: "https://cdn.example/sdr.mkv",
            name: "1080p",
            description: "x264",
            addonName: "Torrentio"
        )
        let dv = NuvioStream(
            url: "https://cdn.example/dv.mkv",
            name: "2160p DV Atmos",
            description: "Dolby Vision",
            addonName: "Torrentio"
        )
        let preferred = StreamQualityTags.parse(stream: dv)
        let best = SmartPlaybackSelector.bestStream(
            from: [sdr, dv],
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false,
            preferredTags: preferred
        )
        XCTAssertEqual(best?.id, dv.id)
    }

    func testSmartSelectorKeepsManuallyChosenBingeSourceForNextEpisode() {
        let selected = NuvioStream(
            url: "https://fusion.example/show.s01e01.mkv",
            name: "1080p WEB-DL",
            description: "6.6 GB",
            addonName: "Fusion",
            bingeGroup: "web-rawr"
        )
        let oldDefault = NuvioStream(
            url: "https://hawk.example/show.s01e02.mkv",
            name: "1080p WEB-DL",
            description: "7 GB",
            addonName: "Hawk",
            bingeGroup: "web-other"
        )
        let continuation = NuvioStream(
            url: "https://fusion.example/show.s01e02.mkv",
            name: "1080p WEB-DL",
            description: "6.4 GB",
            addonName: "Fusion",
            bingeGroup: "web-rawr"
        )

        let best = SmartPlaybackSelector.bestStream(
            from: [oldDefault, continuation],
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false,
            preferredTags: StreamQualityTags.parse(stream: selected)
        )

        XCTAssertEqual(best?.id, continuation.id)
    }

    func testCachedOnlyFilter() {
        let cached = NuvioStream(
            url: "https://cdn.example/c.mkv",
            name: "4K RD+ Cached",
            description: "⚡",
            addonName: "Torrentio",
            isCached: true
        )
        let uncached = NuvioStream(
            url: "https://cdn.example/u.mkv",
            name: "1080p",
            description: "download",
            addonName: "Torrentio"
        )
        // "download" alone may match cached markers — use neutral text
        let plain = NuvioStream(
            url: "https://cdn.example/p.mkv",
            name: "1080p WEB",
            description: "12 GB",
            addonName: "Torrentio"
        )
        let playable = SmartPlaybackSelector.playableStreams(
            from: [plain, cached, uncached],
            includeDebrid: false,
            cachedOnly: true
        )
        XCTAssertTrue(playable.contains(where: { $0.id == cached.id }))
        XCTAssertFalse(playable.contains(where: { $0.id == plain.id }))
        XCTAssertFalse(playable.contains(where: { $0.id == uncached.id }))
    }

    func testCachedOnlyFilterReturnsNoStreamsWhenNoCachedSourcesExist() {
        let uncached = NuvioStream(
            url: "https://cdn.example/u.mkv",
            name: "1080p WEB-DL",
            description: "12 GB",
            addonName: "Torrentio"
        )

        let playable = SmartPlaybackSelector.playableStreams(
            from: [uncached],
            includeDebrid: false,
            cachedOnly: true
        )

        XCTAssertTrue(playable.isEmpty)
    }

    func testBadges() {
        let stream = NuvioStream(
            url: "https://cdn.example/x.mkv",
            name: "4K DV Atmos",
            description: "Cached",
            addonName: "A"
        )
        let badges = StreamBadgeKind.badges(for: stream)
        XCTAssertTrue(badges.contains(.dolbyVision))
        XCTAssertTrue(badges.contains(.atmos))
        XCTAssertTrue(badges.contains(.fourK))
        XCTAssertTrue(badges.contains(.cached))
    }

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

        let builtIn = ExternalPlayer.builtIn.launchURL(for: stream)
        XCTAssertNil(builtIn)
    }

    func testInfuseXCallbacksArePercentEncoded() {
        let stream = URL(string: "https://cdn.example/movie.mkv?token=a&b=c")!
        let success = URL(string: "nuvio-tv://external-playback/ABC-123")!
        let error = URL(string: "nuvio-tv://external-playback/error/ABC-123")!
        let launch = ExternalPlayer.infuse.launchURL(
            for: stream,
            successURL: success,
            errorURL: error
        )!

        XCTAssertTrue(launch.absoluteString.contains("x-success=nuvio-tv%3A%2F%2Fexternal-playback%2FABC-123"))
        XCTAssertTrue(launch.absoluteString.contains("x-error=nuvio-tv%3A%2F%2Fexternal-playback%2Ferror%2FABC-123"))
        XCTAssertFalse(launch.absoluteString.contains("x-success=nuvio-tv://"))
    }

    func testExternalPlaybackCallbackParsingAndCompletionFraction() {
        let callback = ExternalPlaybackCallback.parse(
            URL(string: "nuvio-tv://external-playback/ABC-123?progress=0.9")!
        )
        XCTAssertEqual(callback?.id, "ABC-123")
        XCTAssertEqual(callback?.progress, 0.9)
        XCTAssertFalse(callback?.isError == true)

        let error = ExternalPlaybackCallback.parse(
            URL(string: "nuvio-tv://external-playback/error/ABC-123?position=90")!
        )
        XCTAssertEqual(error?.id, "ABC-123")
        XCTAssertTrue(error?.isError == true)
        XCTAssertEqual(error?.position, 90)
        XCTAssertEqual(WatchProgressLedger.completionFraction, 0.90)
    }

    func testExternalPlaybackCallbackRejectsProgressOutsideDocumentedFractionBounds() {
        XCTAssertNil(ExternalPlaybackCallback.parse(
            URL(string: "nuvio-tv://external-playback/id?progress=-0.01")!
        ))
        XCTAssertNil(ExternalPlaybackCallback.parse(
            URL(string: "nuvio-tv://external-playback/id?progress=1.01")!
        ))
        XCTAssertEqual(
            ExternalPlaybackCallback.parse(
                URL(string: "nuvio-tv://external-playback/id?progress=1")!
            )?.progress,
            1
        )
    }

    func testExternalPlaybackSessionConsumptionIsIdempotentAndProfileScoped() {
        let suiteName = "ExternalPlaybackSessionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let meta = NuvioMeta(
            id: "tt123",
            name: "Movie",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt123",
            tmdbId: nil,
            type: "movie",
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: "100 min",
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: nil
        )
        let session = ExternalPlaybackSession(
            id: "session-1",
            meta: meta.persistenceSnapshot,
            sourceURL: "https://cdn.example/movie.mkv",
            season: nil,
            episode: nil,
            duration: 6_000,
            profileID: "profile-a"
        )
        ExternalPlaybackSessionStore.save(session, defaults: defaults)
        XCTAssertNil(ExternalPlaybackSessionStore.consume(id: session.id, profileID: "profile-b", defaults: defaults))
        XCTAssertEqual(
            ExternalPlaybackSessionStore.consume(id: session.id, profileID: "profile-a", defaults: defaults),
            session
        )
        XCTAssertNil(ExternalPlaybackSessionStore.consume(id: session.id, profileID: "profile-a", defaults: defaults))
    }

    func testExternalPlayerSystemImagesAndLabels() {
        for player in ExternalPlayer.allCases {
            XCTAssertFalse(player.systemImage.isEmpty)
            XCTAssertFalse(player.rawValue.isEmpty)
            XCTAssertEqual(ExternalPlayer.from(player.rawValue), player)
        }
        XCTAssertEqual(ExternalPlayer.from("Unknown"), .builtIn)
        XCTAssertEqual(ExternalPlayer.from(nil), .builtIn)
    }
}
