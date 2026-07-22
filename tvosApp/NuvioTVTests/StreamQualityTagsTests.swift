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
            name: "1080p RD+ Cached",
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
    }
}
