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

    func testParsesVideoCodecs() {
        let hevcStream = StreamQualityTags.parse(
            name: "Movie.2160p.UHD.HDR.x265.mkv",
            description: "HEVC | 10-bit | TrueHD Atmos"
        )
        XCTAssertTrue(hevcStream.isHEVC)
        XCTAssertFalse(hevcStream.isAV1)
        XCTAssertFalse(hevcStream.isAVC)

        let av1Stream = StreamQualityTags.parse(
            name: "Movie 2160p AV1 SDR",
            description: "AV01 Opus 5.1"
        )
        XCTAssertTrue(av1Stream.isAV1)
        XCTAssertFalse(av1Stream.isHEVC)
        XCTAssertFalse(av1Stream.isAVC)

        let avcStream = StreamQualityTags.parse(
            name: "Movie.1080p.BluRay.x264.DTS-HD",
            description: "H.264 AVC"
        )
        XCTAssertTrue(avcStream.isAVC)
        XCTAssertFalse(avcStream.isHEVC)
        XCTAssertFalse(avcStream.isAV1)
    }

    func testHardwareAccelerationCapability() {
        let capabilityWithoutAV1 = AppleTVCapability(
            maxResolution: 2160,
            supportsHDR: true,
            supportsDolbyVision: true,
            supportsHEVCHardwareDecode: true,
            supportsAV1HardwareDecode: false
        )

        let fourKHEVC = StreamQualityTags(resolution: 2160, isHEVC: true)
        XCTAssertTrue(fourKHEVC.isHardwareAccelerated(on: capabilityWithoutAV1))

        let fourKAV1 = StreamQualityTags(resolution: 2160, isAV1: true)
        XCTAssertFalse(fourKAV1.isHardwareAccelerated(on: capabilityWithoutAV1))

        let fourKAVC = StreamQualityTags(resolution: 2160, isAVC: true)
        XCTAssertTrue(fourKAVC.isHardwareAccelerated(on: capabilityWithoutAV1))

        let capabilityWithAV1 = AppleTVCapability(
            maxResolution: 2160,
            supportsHDR: true,
            supportsDolbyVision: true,
            supportsHEVCHardwareDecode: true,
            supportsAV1HardwareDecode: true
        )
        XCTAssertTrue(fourKAV1.isHardwareAccelerated(on: capabilityWithAV1))
    }

    func testStreamBadgeKindIncludesCodecs() {
        let tagsHEVC = StreamQualityTags(resolution: 2160, isDolbyVision: true, isHEVC: true)
        let badgesHEVC = StreamBadgeKind.badges(for: tagsHEVC)
        XCTAssertTrue(badgesHEVC.contains(.fourK))
        XCTAssertTrue(badgesHEVC.contains(.dolbyVision))
        XCTAssertTrue(badgesHEVC.contains(.hevc))
        XCTAssertFalse(badgesHEVC.contains(.av1))

        let tagsAV1 = StreamQualityTags(resolution: 2160, isAV1: true)
        let badgesAV1 = StreamBadgeKind.badges(for: tagsAV1)
        XCTAssertTrue(badgesAV1.contains(.fourK))
        XCTAssertTrue(badgesAV1.contains(.av1))
        XCTAssertFalse(badgesAV1.contains(.hevc))
    }

    func testSmartSelectorPrioritizesHardwareAccelerated4KOverAV1() {
        let av1Stream = NuvioStream(
            url: "https://cdn.example/movie.4k.av1.mkv",
            name: "Movie 2160p 4K AV1 HDR",
            description: "AV1 10-bit",
            addonName: "Torrentio"
        )
        let hevcStream = NuvioStream(
            url: "https://cdn.example/movie.4k.hevc.mkv",
            name: "Movie 2160p 4K HEVC HDR",
            description: "x265 10-bit",
            addonName: "Torrentio"
        )

        let ranked = SmartPlaybackSelector.rankedStreams(
            from: [av1Stream, hevcStream],
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false
        )

        // 4K HEVC should be ranked first on Apple TV without AV1 HW
        XCTAssertEqual(ranked.first?.id, hevcStream.id)
    }

    func testQualitySortPrioritizesHardwareAccelerated4KOnEqualResolution() {
        let av1Stream = NuvioStream(
            url: "https://cdn.example/movie.4k.av1.mkv",
            name: "Movie 2160p 4K AV1 HDR",
            description: "AV1",
            addonName: "Torrentio"
        )
        let hevcStream = NuvioStream(
            url: "https://cdn.example/movie.4k.hevc.mkv",
            name: "Movie 2160p 4K HEVC HDR",
            description: "x265",
            addonName: "Torrentio"
        )

        let sorted = StreamPickerListBuilder.sorted([av1Stream, hevcStream], by: .quality)
        XCTAssertEqual(sorted.first?.id, hevcStream.id)
    }

    func testDisplayedStreamsForTopResultSelection() {
        let streamA = NuvioStream(
            url: "https://cdn.example/first.1080p.mkv",
            name: "1080p Stream First",
            description: "First result",
            addonName: "Torrentio"
        )
        let streamB = NuvioStream(
            url: "https://cdn.example/second.4k.mkv",
            name: "4K Stream Second",
            description: "Second result",
            addonName: "Torrentio"
        )

        // Under .default sort, stream order is preserved as provided by add-on
        let defaultSorted = StreamPickerListBuilder.displayedStreams(
            streams: [streamA, streamB],
            groups: [],
            selectedAddonId: nil,
            sortOption: .default,
            includeDebrid: true,
            cachedOnly: false
        )
        XCTAssertEqual(defaultSorted.first?.id, streamA.id)

        // Under .quality sort, 4K rises to the top
        let qualitySorted = StreamPickerListBuilder.displayedStreams(
            streams: [streamA, streamB],
            groups: [],
            selectedAddonId: nil,
            sortOption: .quality,
            includeDebrid: true,
            cachedOnly: false
        )
        XCTAssertEqual(qualitySorted.first?.id, streamB.id)
    }

    func testSubHDOrTicketStreamNeverSavedOrLoadedInLastStreamQualityStore() {
        let metaId = "test_ticket_\(UUID().uuidString)"
        let ticketStream = NuvioStream(
            url: "https://aio.example/stream",
            name: "AIOStreams | ElfHosted · N/A 🎫",
            description: "Download Ticket",
            addonName: "AIOStreams"
        )
        // 1. Trying to save ticket / 0-res stream must be ignored
        LastStreamQualityStore.save(metaId: metaId, stream: ticketStream)
        XCTAssertNil(LastStreamQualityStore.load(metaId: metaId))

        // 2. Pre-seed a corrupted 0-resolution entry in UserDefaults directly
        let key = "nuvio.tv.lastStreamQuality." + metaId
        let corruptTags = StreamQualityTags(resolution: 0, bingeGroup: "ticket-group")
        let data = try! JSONEncoder().encode(corruptTags)
        ProfileSettings.current.set(data, forKey: key)
        XCTAssertNotNil(ProfileSettings.current.data(forKey: key))

        // 3. Loading must self-heal by purging the key from UserDefaults and returning nil
        let loaded = LastStreamQualityStore.load(metaId: metaId)
        XCTAssertNil(loaded)
        XCTAssertNil(ProfileSettings.current.data(forKey: key))
    }

    func testTicketStreamCannotOutrankHDStreamsEvenWithBingeMatch() {
        let ticketStream = NuvioStream(
            url: "https://aio.example/ticket",
            name: "AIOStreams | ElfHosted · N/A 🎫",
            description: "ElfHosted Ticket",
            addonName: "AIOStreams",
            bingeGroup: "aio-superman"
        )
        let hdStream = NuvioStream(
            url: "https://realdebrid.example/s01e02.mkv",
            name: "1080p WEB-DL",
            description: "2.5 GB",
            addonName: "Torrentio",
            bingeGroup: "torrentio-superman"
        )

        // Even if preferredTags had matched bingeGroup or addon with the ticket stream
        let preferredTags = StreamQualityTags(resolution: 0, bingeGroup: "aio-superman", addonName: "AIOStreams")
        let best = SmartPlaybackSelector.bestStream(
            from: [ticketStream, hdStream],
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false,
            preferredTags: preferredTags
        )

        XCTAssertEqual(best?.id, hdStream.id)
    }

    func test1080pStreamWithTicketEmojiIsNotLowQuality() {
        let hdTicketStream = NuvioStream(
            url: "https://aio.example/remux",
            name: "🧿 1080p 🎫",
            description: "BLURAY REMUX",
            addonName: "AIOStreams | ElfHosted"
        )
        let naTicketStream = NuvioStream(
            url: "https://aio.example/ticket",
            name: "N/A 🎫",
            description: "AIOStreams | ElfHosted · 📦 692 MB",
            addonName: "AIOStreams | ElfHosted"
        )
        let webripNoResStream = NuvioStream(
            url: "https://aio.example/webrip",
            name: "WEBRIP",
            description: "AIOStreams | ElfHosted · 📦 418 MB",
            addonName: "AIOStreams | ElfHosted"
        )

        XCTAssertFalse(SmartPlaybackSelector.isLowQualityOrTicketStream(hdTicketStream))
        XCTAssertTrue(SmartPlaybackSelector.isLowQualityOrTicketStream(naTicketStream))
        XCTAssertTrue(SmartPlaybackSelector.isLowQualityOrTicketStream(webripNoResStream))
    }

    func testStreamPickerSortSinksNAStreamsBelow1080pInDefaultAndQualitySort() {
        let hdTicketStream = NuvioStream(
            url: "https://aio.example/remux",
            name: "🧿 1080p 🎫",
            description: "BLURAY REMUX",
            addonName: "AIOStreams | ElfHosted"
        )
        let naTicketStream = NuvioStream(
            url: "https://aio.example/ticket",
            name: "N/A 🎫",
            description: "AIOStreams | ElfHosted · 📦 692 MB",
            addonName: "AIOStreams | ElfHosted"
        )
        let webripNoResStream = NuvioStream(
            url: "https://aio.example/webrip",
            name: "WEBRIP",
            description: "AIOStreams | ElfHosted · 📦 418 MB",
            addonName: "AIOStreams | ElfHosted"
        )

        // Given input where N/A and WEBRIP come first:
        let input = [webripNoResStream, naTicketStream, hdTicketStream]

        // 1. Under .default sort, 1080p must be on top, N/A and 0-res at the bottom
        let defaultSorted = StreamPickerListBuilder.sorted(input, by: .default)
        XCTAssertEqual(defaultSorted.first?.id, hdTicketStream.id)

        // 2. Under .quality sort, 1080p must be on top
        let qualitySorted = StreamPickerListBuilder.sorted(input, by: .quality)
        XCTAssertEqual(qualitySorted.first?.id, hdTicketStream.id)
    }

    func testAndroidTokenBasedResolutionParsing() {
        XCTAssertEqual(StreamQualityTags.resolution(in: "Superman.and.Lois.S01E02.2160p.UHD.Remux"), 2160)
        XCTAssertEqual(StreamQualityTags.resolution(in: "Movie 4k DV"), 2160)
        XCTAssertEqual(StreamQualityTags.resolution(in: "Movie.1440p.WEB-DL"), 1440)
        XCTAssertEqual(StreamQualityTags.resolution(in: "Movie 2k rip"), 1440)
        XCTAssertEqual(StreamQualityTags.resolution(in: "Superman.and.Lois.S01E02.1080p.BluRay"), 1080)
        XCTAssertEqual(StreamQualityTags.resolution(in: "Movie FHD x264"), 1080)
        XCTAssertEqual(StreamQualityTags.resolution(in: "Episode 720p HD"), 720)
        XCTAssertEqual(StreamQualityTags.resolution(in: "Episode 576p"), 576)
        XCTAssertEqual(StreamQualityTags.resolution(in: "Episode 480p SD"), 480)
        XCTAssertEqual(StreamQualityTags.resolution(in: "Episode 360p"), 360)

        // Word boundaries: substrings that contain tokens inside words must NOT match
        XCTAssertEqual(StreamQualityTags.resolution(in: "soundtrack"), 0) // contains "2k"
        XCTAssertEqual(StreamQualityTags.resolution(in: "year2024"), 0)
        XCTAssertEqual(StreamQualityTags.resolution(in: "hasha720bf"), 0) // hex hash containing 720

        // Corrupt / ticket strings evaluate to 0 (UNKNOWN)
        XCTAssertEqual(StreamQualityTags.resolution(in: "N/A 🎫"), 0)
        XCTAssertEqual(StreamQualityTags.resolution(in: "WEBRIP"), 0)
        XCTAssertEqual(StreamQualityTags.resolution(in: "download ticket"), 0)
    }

    func testStreamURLsDoNotContaminateResolutionParsing() {
        let streamWithHexURL = NuvioStream(
            url: "https://aiostreams.elfhosted.com/playback/realdebrid/hash720abc/stream.mkv",
            name: "AIOStreams | ElfHosted",
            description: "N/A 🎫",
            addonName: "AIOStreams | ElfHosted"
        )
        let tags = StreamQualityTags.parse(stream: streamWithHexURL)
        XCTAssertEqual(tags.resolution, 0)
        XCTAssertEqual(StreamPickerListBuilder.resolution(for: streamWithHexURL), 0)
        XCTAssertTrue(SmartPlaybackSelector.isLowQualityOrTicketStream(streamWithHexURL))
    }

    func testAndroidDebridStreamQualityHierarchy() {
        XCTAssertGreaterThan(DebridStreamQuality.blurayRemux, DebridStreamQuality.bluray)
        XCTAssertGreaterThan(DebridStreamQuality.bluray, DebridStreamQuality.webDl)
        XCTAssertGreaterThan(DebridStreamQuality.webDl, DebridStreamQuality.webrip)
        XCTAssertGreaterThan(DebridStreamQuality.webrip, DebridStreamQuality.hdrip)
        XCTAssertGreaterThan(DebridStreamQuality.hdrip, DebridStreamQuality.dvdrip)
        XCTAssertGreaterThan(DebridStreamQuality.dvdrip, DebridStreamQuality.hdtv)
        XCTAssertGreaterThan(DebridStreamQuality.hdtv, DebridStreamQuality.unknown)

        XCTAssertEqual(StreamQualityTags.quality(in: "Movie 1080p BluRay REMUX TrueHD"), .blurayRemux)
        XCTAssertEqual(StreamQualityTags.quality(in: "Movie 1080p Blu-Ray"), .bluray)
        XCTAssertEqual(StreamQualityTags.quality(in: "Movie 1080p WEB-DL"), .webDl)
        XCTAssertEqual(StreamQualityTags.quality(in: "Movie 1080p WebRip"), .webrip)
        XCTAssertEqual(StreamQualityTags.quality(in: "Movie HDRip"), .hdrip)
        XCTAssertEqual(StreamQualityTags.quality(in: "Movie DVDRip"), .dvdrip)
        XCTAssertEqual(StreamQualityTags.quality(in: "Episode HDTV"), .hdtv)
        XCTAssertEqual(StreamQualityTags.quality(in: "Episode CAM"), .cam)
        XCTAssertEqual(StreamQualityTags.quality(in: "N/A 🎫"), .unknown)
    }

    func testAndroidMultiTierQualityComparator() {
        let stream4k = NuvioStream(
            url: "https://example.com/4k",
            name: "2160p WEB-DL",
            description: "15 GB",
            addonName: "Torrentio"
        )
        let stream1080pRemux = NuvioStream(
            url: "https://example.com/remux",
            name: "1080p BluRay REMUX",
            description: "8 GB",
            addonName: "Torrentio"
        )
        let stream1080pWebDlLarge = NuvioStream(
            url: "https://example.com/webdl_large",
            name: "1080p WEB-DL",
            description: "5 GB",
            addonName: "Torrentio"
        )
        let stream1080pWebDlSmall = NuvioStream(
            url: "https://example.com/webdl_small",
            name: "1080p WEB-DL",
            description: "2 GB",
            addonName: "Torrentio"
        )
        let stream1080pWebRip = NuvioStream(
            url: "https://example.com/webrip",
            name: "1080p WEBRip",
            description: "4 GB",
            addonName: "Torrentio"
        )
        let stream720p = NuvioStream(
            url: "https://example.com/720p",
            name: "720p HD",
            description: "1 GB",
            addonName: "Torrentio"
        )
        let streamNA = NuvioStream(
            url: "https://example.com/na",
            name: "N/A 🎫",
            description: "AIOStreams | ElfHosted · 📦 692 MB",
            addonName: "AIOStreams | ElfHosted"
        )

        // Shuffle input
        let shuffled = [stream1080pWebRip, streamNA, stream1080pRemux, stream720p, stream4k, stream1080pWebDlSmall, stream1080pWebDlLarge]
        let sorted = StreamPickerListBuilder.sorted(shuffled, by: .quality)

        // Tier 1: 4K comes first
        XCTAssertEqual(sorted[0].id, stream4k.id)
        // Tier 2: 1080p Remux beats 1080p WEB-DL
        XCTAssertEqual(sorted[1].id, stream1080pRemux.id)
        // Tier 3: 1080p WEB-DL 5 GB beats 1080p WEB-DL 2 GB (size tiebreaker)
        XCTAssertEqual(sorted[2].id, stream1080pWebDlLarge.id)
        XCTAssertEqual(sorted[3].id, stream1080pWebDlSmall.id)
        // Tier 2: 1080p WEB-DL beats 1080p WEBRip
        XCTAssertEqual(sorted[4].id, stream1080pWebRip.id)
        // Tier 1: 1080p beats 720p
        XCTAssertEqual(sorted[5].id, stream720p.id)
        // Tier 1: 720p beats N/A (0-res at the very bottom)
        XCTAssertEqual(sorted[6].id, streamNA.id)
    }

    func testStreamSortOptionSyncCompatibility() {
        XCTAssertEqual(StreamSortOption(rawValueOrSync: "QUALITY_DESC"), .quality)
        XCTAssertEqual(StreamSortOption(rawValueOrSync: "QUALITY"), .quality)
        XCTAssertEqual(StreamSortOption(rawValueOrSync: "Quality"), .quality)
        XCTAssertEqual(StreamSortOption(rawValueOrSync: "DEFAULT"), .default)
        XCTAssertEqual(StreamSortOption(rawValueOrSync: "Default"), .default)
        XCTAssertEqual(StreamSortOption(rawValueOrSync: "SIZE_DESC"), .size)
        XCTAssertEqual(StreamSortOption(rawValueOrSync: "SIZE_ASC"), .size)
        XCTAssertEqual(StreamSortOption(rawValueOrSync: "Size"), .size)
        XCTAssertEqual(StreamSortOption(rawValueOrSync: "NAME"), .name)
        XCTAssertEqual(StreamSortOption(rawValueOrSync: "Name"), .name)
    }

    func testStreamURLContaining4KDoesNotTrigger4KBadgeOn1080pStream() {
        var filter4K = StreamBadgeFilter()
        filter4K.id = "uhd"
        filter4K.groupId = "g-res"
        filter4K.name = "4K"
        filter4K.pattern = #"(?i)\b(?:4k|2160[pi]?|uhd(?:tv)?|ultra[\s._-]?hd|3840\s*x\s*2160|4096\s*x\s*2160)\b"#
        filter4K.imageURL = "https://example.com/uhd.png"

        var filter1080 = StreamBadgeFilter()
        filter1080.id = "fhd"
        filter1080.groupId = "g-res"
        filter1080.name = "1080p"
        filter1080.pattern = #"(?i)\b(?:1080[pi]?|fhd|full[\s._-]?hd|1920\s*x\s*1080)\b"#
        filter1080.imageURL = "https://example.com/fhd.png"

        var groupRes = StreamBadgeGroup()
        groupRes.id = "g-res"
        groupRes.name = "Resolution"

        let rules = StreamBadgeRules(
            imports: [
                StreamBadgeImport(
                    sourceUrl: "https://example.com/badges.json",
                    filters: [filter4K, filter1080],
                    groups: [groupRes],
                    isActive: true
                )
            ]
        )

        // Stream URL contains /4k/ and -4k- tokens (common in AIOStreams/Comet base64 or paths)
        let stream = NuvioStream(
            url: "https://aiostreams.elfhosted.com/playback/4k/token-4k-xyz/stream.mkv",
            name: "🧿 1080p 🎫\nWEB-DL",
            description: "📦 3.86 GB",
            addonName: "AIOStreams | ElfHosted",
            filename: "Superman.and.Lois.S01E02.1080p.AMZN.WEB-DL.DDP5.1.H.264-NTb.mkv"
        )

        let matched = StreamBadgeMatcher.matchedBadges(for: stream, rules: rules)
        let matchedNames = matched.map { $0.name }

        XCTAssertFalse(matchedNames.contains("4K"), "1080p stream must not match 4K badge due to URL tokens")
        XCTAssertTrue(matchedNames.contains("1080p"), "1080p stream must match 1080p badge")
    }

    func testResolutionBadgesAreMutuallyExclusive() {
        // A 1080p stream where both 4K and 1080p filters match (e.g. over-eager 4K pattern or tag)
        var filter4K = StreamBadgeFilter()
        filter4K.id = "uhd"
        filter4K.groupId = "g-res"
        filter4K.name = "4K"
        filter4K.pattern = #"(?i)\b(?:4k|master)\b"#
        filter4K.imageURL = "https://example.com/uhd.png"

        var filter1080 = StreamBadgeFilter()
        filter1080.id = "fhd"
        filter1080.groupId = "g-res"
        filter1080.name = "1080p"
        filter1080.pattern = #"(?i)\b(?:1080[pi]?|fhd|full[\s._-]?hd|1920\s*x\s*1080)\b"#
        filter1080.imageURL = "https://example.com/fhd.png"

        var groupRes = StreamBadgeGroup()
        groupRes.id = "g-res"
        groupRes.name = "Resolution"

        let rules = StreamBadgeRules(
            imports: [
                StreamBadgeImport(
                    sourceUrl: "https://example.com/badges.json",
                    filters: [filter4K, filter1080],
                    groups: [groupRes],
                    isActive: true
                )
            ]
        )

        // Metadata has 1080p resolution and triggers both filters ("Master" trips filter4K)
        let stream = NuvioStream(
            url: "https://example.com/movie.mkv",
            name: "Movie 1080p Master Edition",
            description: "WEB-DL 3.8 GB",
            addonName: "Torrentio",
            filename: "Movie.1080p.Master.mkv"
        )

        let matched = StreamBadgeMatcher.matchedBadges(for: stream, rules: rules)
        let matchedNames = matched.map { $0.name }

        XCTAssertEqual(matchedNames, ["1080p"], "Only canonical 1080p resolution badge should be preserved")
    }

    func testHDRAndSDRBadgesAreMutuallyExclusive() {
        var filterDV = StreamBadgeFilter()
        filterDV.id = "dv"
        filterDV.groupId = "g-rng"
        filterDV.name = "DV"
        filterDV.pattern = #"(?i)\b(?:dolby\s*vision|dovi|dv)\b"#
        filterDV.imageURL = "https://example.com/dv.png"

        var filterSDR = StreamBadgeFilter()
        filterSDR.id = "sdr"
        filterSDR.groupId = "g-rng"
        filterSDR.name = "SDR"
        filterSDR.pattern = #"(?i)\b(?:sdr)\b"#
        filterSDR.imageURL = "https://example.com/sdr.png"

        let rules = StreamBadgeRules(
            imports: [
                StreamBadgeImport(
                    sourceUrl: "https://example.com/badges.json",
                    filters: [filterDV, filterSDR],
                    isActive: true
                )
            ]
        )

        let stream = NuvioStream(
            url: "https://example.com/movie.mkv",
            name: "Movie 2160p DV (with SDR fallback track)",
            description: "Remux",
            addonName: "Torrentio"
        )

        let matched = StreamBadgeMatcher.matchedBadges(for: stream, rules: rules)
        let matchedNames = matched.map { $0.name }

        XCTAssertTrue(matchedNames.contains("DV"))
        XCTAssertFalse(matchedNames.contains("SDR"), "SDR badge must be suppressed when HDR/DV is present")
    }
}

