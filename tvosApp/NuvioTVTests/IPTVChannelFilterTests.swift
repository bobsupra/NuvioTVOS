import XCTest
@testable import NuvioTV

final class IPTVChannelFilterTests: XCTestCase {
    func testSearchAndGroupAreAppliedTogether() {
        XCTAssertTrue(IPTVChannelFilter.matches(name: "News World", group: "News", query: "world", selectedGroup: "News"))
        XCTAssertFalse(IPTVChannelFilter.matches(name: "News World", group: "News", query: "world", selectedGroup: "Sports"))
        XCTAssertFalse(IPTVChannelFilter.matches(name: "News World", group: "News", query: "sports", selectedGroup: nil))
        XCTAssertTrue(IPTVChannelFilter.matches(name: "News World", group: nil, query: "  ", selectedGroup: nil))
    }

    func testSearchMatchesCurrentProgrammeTitle() {
        XCTAssertTrue(IPTVChannelFilter.matches(name: "Motorsport", group: "Sport", query: "NASCAR", selectedGroup: nil, currentProgrammeTitle: "NASCAR Cup Series"))
        XCTAssertTrue(IPTVChannelFilter.matches(name: "Motorsport", group: "Sport", query: "  nascar  ", selectedGroup: nil, currentProgrammeTitle: "NASCAR Cup Series"))
        XCTAssertFalse(IPTVChannelFilter.matches(name: "Motorsport", group: "Sport", query: "NASCAR", selectedGroup: nil))
        XCTAssertFalse(IPTVChannelFilter.matches(name: "Motorsport", group: "Sport", query: "NASCAR", selectedGroup: "News", currentProgrammeTitle: "NASCAR Cup Series"))
    }

    func testSportsEventTitlesAreCaseInsensitiveAndTokenAware() {
        for title in ["NFL: Seahawks vs. Rams", "MLB Mariners at Yankees", "NHL Hockey", "Ice Hockey", "Live MMA", "PWHL Game", "NASCAR Cup Series", "UFC Fight Night", "Premier League", "UEFA Champions League", "Formula 1 Grand Prix"] {
            XCTAssertTrue(IPTVChannelFilter.isSportsEventTitle(title), title)
        }
        XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle("The NFL Network"))
        XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle("Footballish drama"))
        XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle("NCIS"))
        XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle("Winter Storm Warning"))
        XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle("Winter Storm at 6"))
    }

    func testSportsListingsExcludeStudioAndRecordedContent() {
        for title in ["NFL GameDay Studio", "NFL Live", "MLB Tonight", "MLB News", "NHL Highlights", "NASCAR Replay", "NASCAR Race Hub", "UFC Recap"] {
            XCTAssertFalse(IPTVChannelFilter.isSportsEventTitle(title), title)
        }
        XCTAssertTrue(IPTVChannelFilter.isSportsEventTitle("Seahawks vs. Rams"))
        XCTAssertTrue(IPTVChannelFilter.isSportsEventTitle("Seattle Mariners at Boston"))
        XCTAssertTrue(IPTVChannelFilter.isSportsEventTitle("Seattle Storm vs. Las Vegas Aces"))
    }

    func testOrderedGroupsPreservesCustomOrderDeduplicatesAndFiltersHidden() {
        let groups = ["Sports", "News", "Alle", "Movies", "News", "Kids"]
        let preferences = IPTVCategoryPreferences(
            order: ["Movies", "Missing", "Movies", "Kids"],
            hiddenGroupIDs: ["News"],
            customNames: [:]
        )

        let visible = IPTVCategoryPreferencesStore.orderedGroups(groups, preferences: preferences)
        XCTAssertEqual(visible, ["Movies", "Kids", "Sports"])

        let all = IPTVCategoryPreferencesStore.orderedGroups(groups, preferences: preferences, includingHidden: true)
        XCTAssertEqual(all, ["Movies", "Kids", "News", "Sports"])

        let largeGroups = (0..<500).map { String(format: "Category %03d", $0) }
        let largePrefs = IPTVCategoryPreferences(
            order: ["Category 499", "Category 000", "Category 250"],
            hiddenGroupIDs: ["Category 001"],
            customNames: [:]
        )
        let orderedLarge = IPTVCategoryPreferencesStore.orderedGroups(largeGroups, preferences: largePrefs)
        XCTAssertEqual(orderedLarge.count, 499)
        XCTAssertEqual(Array(orderedLarge.prefix(4)), ["Category 499", "Category 000", "Category 250", "Category 002"])
    }

    func testChannelGuideLookupFindsCurrentAndUpcomingProgrammes() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let p1 = IPTVProgramme(channelID: "ch1", title: "Earlier", start: base.addingTimeInterval(-7200), end: base.addingTimeInterval(-3600))
        let p2 = IPTVProgramme(channelID: "ch1", title: "Now", start: base.addingTimeInterval(-1800), end: base.addingTimeInterval(1800))
        let p3 = IPTVProgramme(channelID: "ch1", title: "Next 1", start: base.addingTimeInterval(1800), end: base.addingTimeInterval(5400))
        let p4 = IPTVProgramme(channelID: "ch1", title: "Next 2", start: base.addingTimeInterval(5400), end: base.addingTimeInterval(9000))
        let p5 = IPTVProgramme(channelID: "ch1", title: "Later", start: base.addingTimeInterval(9000), end: base.addingTimeInterval(12600))
        let schedule = [p1, p2, p3, p4, p5]

        XCTAssertNil(IPTVChannelGuideLookup.currentProgramme(in: [], at: base))
        XCTAssertTrue(IPTVChannelGuideLookup.upcomingProgrammes(in: [], at: base).isEmpty)

        XCTAssertEqual(IPTVChannelGuideLookup.currentProgramme(in: schedule, at: base)?.title, "Now")
        XCTAssertEqual(IPTVChannelGuideLookup.currentProgramme(in: schedule, at: p2.start)?.title, "Now")
        XCTAssertEqual(IPTVChannelGuideLookup.currentProgramme(in: schedule, at: p2.end)?.title, "Next 1")
        XCTAssertNil(IPTVChannelGuideLookup.currentProgramme(in: schedule, at: base.addingTimeInterval(-3000)))
        XCTAssertNil(IPTVChannelGuideLookup.currentProgramme(in: schedule, at: p5.end))

        let upcoming = Array(IPTVChannelGuideLookup.upcomingProgrammes(in: schedule, at: base, limit: 2))
        XCTAssertEqual(upcoming.map(\.title), ["Next 1", "Next 2"])

        let atBoundary = Array(IPTVChannelGuideLookup.upcomingProgrammes(in: schedule, at: p3.start, limit: 2))
        XCTAssertEqual(atBoundary.map(\.title), ["Next 1", "Next 2"])

        let afterAll = Array(IPTVChannelGuideLookup.upcomingProgrammes(in: schedule, at: p5.end, limit: 2))
        XCTAssertTrue(afterAll.isEmpty)
    }

    func testPreparedLineupBuildsStalkerIndexAndSortedGroups() {
        let sourceID = UUID()
        let stalker = [
            IPTVStalkerChannel(id: "10", name: "Sports HD", command: "ffmpeg http://example.test/10", logo: "https://example.test/10.png", categoryID: "2", categoryName: "Sports"),
            IPTVStalkerChannel(id: "20", name: "News 24", command: "ffmpeg http://example.test/20", logo: "file:///etc/passwd", categoryID: "1", categoryName: "News"),
            IPTVStalkerChannel(id: "30", name: "All Placeholder", command: "ffmpeg http://example.test/30", logo: nil, categoryID: "3", categoryName: "Alle")
        ]

        let lineup = IPTVPreparedLineup.build(
            channels: [],
            stalkerChannels: stalker,
            sourceID: sourceID,
            liveBadge: "Live",
            miscCategory: "Other"
        )

        XCTAssertEqual(lineup.baseChannels.count, 3)
        XCTAssertEqual(lineup.baseChannelsByID["10"]?.name, "Sports HD")
        XCTAssertEqual(lineup.baseChannelsByID["10"]?.logoURL?.absoluteString, "https://example.test/10.png")
        XCTAssertEqual(lineup.baseChannelsByID["10"]?.streamURL?.absoluteString, "stalker://channel/10")
        XCTAssertNil(lineup.baseChannelsByID["20"]?.logoURL)
        XCTAssertEqual(lineup.baseCategoryGroups, ["News", "Sports"])
        XCTAssertFalse(lineup.hasGuideIDs)
        XCTAssertEqual(lineup.orderedFavoriteKeys.count, 3)
        XCTAssertEqual(lineup.favoriteKeys["10"], IPTVFavoritesStore.key(sourceID: sourceID, channelID: "10"))
    }

    func testLiveTimelineProgressResolverPrefersActiveEPGProgramme() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(900) // 25% of 1h programme
        let end = start.addingTimeInterval(3600)
        let nextEnd = end.addingTimeInterval(1800)
        let programmes = [
            IPTVProgramme(channelID: "ch1", title: "Evening News", start: start, end: end),
            IPTVProgramme(channelID: "ch1", title: "Late Show", start: end, end: nextEnd)
        ]

        let state = LiveTimelineProgressResolver.resolve(
            programmes: programmes,
            livePosition: 30,
            liveDuration: 120,
            liveBuffered: 45,
            startedAt: start,
            now: now
        )

        XCTAssertEqual(
            state,
            .programme(
                title: "Evening News",
                start: start,
                end: end,
                progress: 0.25,
                nextTitle: "Late Show",
                nextStart: end
            )
        )
    }

    func testLiveTimelineProgressResolverFallsBackToLiveWindowAndLiveEdge() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let now = startedAt.addingTimeInterval(125)

        let windowState = LiveTimelineProgressResolver.resolve(
            programmes: [],
            livePosition: 90,
            liveDuration: 120,
            liveBuffered: 110,
            startedAt: startedAt,
            now: now
        )
        XCTAssertEqual(
            windowState,
            .liveWindow(
                played: 0.75,
                buffered: 110.0 / 120.0,
                behindLiveSeconds: 30,
                windowDuration: 120,
                positionSeconds: 90
            )
        )

        let edgeState = LiveTimelineProgressResolver.resolve(
            programmes: [],
            livePosition: 0,
            liveDuration: 0,
            liveBuffered: 8,
            startedAt: startedAt,
            now: now
        )
        XCTAssertEqual(
            edgeState,
            .liveEdge(elapsedSeconds: 125, bufferedAheadSeconds: 8)
        )
    }

    @MainActor
    func testSceneViewModelExcludesInSightTabWhenDisabledForLivePlayback() {
        final class DummyFrameProvider: SceneFrameProviding {
            var isSupported: Bool { false }
            var capabilityMessage: String? { nil }
            func captureCurrentFrame(maxWidth: Int, context: SceneContext) async -> SceneFrame? { nil }
        }

        let coordinator = SceneCoordinator(frameProvider: DummyFrameProvider())
        let viewModel = SceneViewModel(coordinator: coordinator)
        viewModel.setMetadata(
            title: "BBC One",
            year: nil,
            overview: nil,
            runtime: nil,
            nextEpisode: nil,
            playbackInfo: ScenePlaybackInfo(engine: "AVPlayer"),
            hasChapters: false,
            hasAutoSync: false,
            includeSceneTab: false
        )
        viewModel.open()

        XCTAssertEqual(viewModel.availableTabs, [.info])
        XCTAssertEqual(viewModel.selectedTab, .info)
        XCTAssertFalse(coordinator.isPanelOpen)
    }

    func testInlinePreviewPolicySelectsAetherForStalkerAndMPEGTSAndAVPlayerForHLS() {
        let hlsURL = URL(string: "https://example.com/live/stream.m3u8")!
        let tsURL = URL(string: "http://example.com/live/user/pass/1234.ts")!
        let extensionlessURL = URL(string: "http://portal.example.com:8080/play/live.php?stream=42&play_token=abc")!

        XCTAssertEqual(
            IPTVInlinePreviewPolicy.backend(for: hlsURL, sourceKind: .m3u, xtreamOutput: nil),
            .avPlayer
        )
        XCTAssertEqual(
            IPTVInlinePreviewPolicy.backend(for: hlsURL, sourceKind: .stalker, xtreamOutput: nil),
            .avPlayer
        )
        XCTAssertEqual(
            IPTVInlinePreviewPolicy.backend(for: hlsURL, sourceKind: .xtream, xtreamOutput: .hls),
            .avPlayer
        )
        XCTAssertEqual(
            IPTVInlinePreviewPolicy.backend(for: tsURL, sourceKind: .m3u, xtreamOutput: nil),
            .aether
        )
        XCTAssertEqual(
            IPTVInlinePreviewPolicy.backend(for: extensionlessURL, sourceKind: .xtream, xtreamOutput: .mpegTS),
            .aether
        )
        XCTAssertEqual(
            IPTVInlinePreviewPolicy.backend(for: extensionlessURL, sourceKind: .stalker, xtreamOutput: nil),
            .aether
        )
        XCTAssertEqual(
            IPTVInlinePreviewPolicy.backend(for: extensionlessURL, sourceKind: .m3u, xtreamOutput: nil),
            .avPlayer
        )
    }

    func testSelectedSourceStoreRoundTripsAndClears() {
        let suite = "IPTVSelectedSourceStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(IPTVSelectedSourceStore.load(defaults: defaults))

        let first = UUID()
        IPTVSelectedSourceStore.save(first, defaults: defaults)
        XCTAssertEqual(IPTVSelectedSourceStore.load(defaults: defaults), first)

        let second = UUID()
        IPTVSelectedSourceStore.save(second, defaults: defaults)
        XCTAssertEqual(IPTVSelectedSourceStore.load(defaults: defaults), second)

        IPTVSelectedSourceStore.save(nil, defaults: defaults)
        XCTAssertNil(IPTVSelectedSourceStore.load(defaults: defaults))
    }
}
