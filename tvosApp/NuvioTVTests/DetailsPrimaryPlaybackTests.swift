import XCTest
@testable import NuvioTV

private final class PrimaryPlaybackCatalogRepository: CatalogRepository {
    private let metadata: NuvioMeta
    private let failsMetadataRequest: Bool
    private var cachedMetadataByID: [String: NuvioMeta] = [:]

    init(metadata: NuvioMeta, failsMetadataRequest: Bool = false) {
        self.metadata = metadata
        self.failsMetadataRequest = failsMetadataRequest
    }

    func getHomeCatalogs() async throws -> [NuvioCatalog] { [] }

    func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        if failsMetadataRequest { throw TestFailure.metadataUnavailable }
        return metadata
    }

    func getStreams(id: String, type: String) async throws -> [NuvioStream] { [] }

    func search(query: String) async throws -> [NuvioMeta] { [] }

    func browseCatalog(
        contentType: String,
        catalogId: String,
        page: Int,
        genre: String?,
        year: Int?,
        sort: String?
    ) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: page)
    }

    func browseCatalog(
        contentType: String,
        catalogId: String,
        skip: Int,
        genre: String?
    ) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: 0, nextSkip: skip)
    }

    func browseCatalog(
        addonId: String?,
        contentType: String,
        catalogId: String,
        skip: Int,
        genre: String?
    ) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: 0, nextSkip: skip)
    }

    func getGenres(contentType: String) async throws -> [String] { [] }

    func getCollectionFolderItems(
        sources: [NuvioCollectionCatalogSource],
        limit: Int
    ) async -> [NuvioMeta] {
        []
    }

    func cacheCatalogMetadata(_ meta: NuvioMeta) {
        cachedMetadataByID[meta.id] = meta
    }

    func cachedMetadata(for id: String) -> NuvioMeta? {
        cachedMetadataByID[id]
    }
}

private enum TestFailure: Error {
    case metadataUnavailable
}

@MainActor
final class DetailsPrimaryMetadataReadinessTests: XCTestCase {
    func testSuccessfulMetadataLoadMarksReadiness() async {
        let meta = NuvioMeta(id: "movie", name: "Movie", type: "movie")
        let repository = PrimaryPlaybackCatalogRepository(metadata: meta)
        let viewModel = DetailsViewModel(
            repository: repository,
            streamDiscoveryMode: .repository,
            deferredPreparationDelay: { throw CancellationError() },
            enrichmentStarter: { _, _ in }
        )

        await viewModel.loadDetails(id: meta.id, type: meta.type).value

        XCTAssertTrue(viewModel.didLoadMetadataSuccessfully)
        XCTAssertNil(viewModel.metadataLoadError)
        viewModel.cancelAllTasks()
    }

    func testCachedSeriesWithoutEpisodesRemainsVisibleWhenMetadataRefreshFails() async {
        let cachedMeta = NuvioMeta(id: "cached-series", name: "Cached Series", type: "series")
        let repository = PrimaryPlaybackCatalogRepository(metadata: cachedMeta, failsMetadataRequest: true)
        repository.cacheCatalogMetadata(cachedMeta)
        let viewModel = DetailsViewModel(
            repository: repository,
            streamDiscoveryMode: .repository,
            deferredPreparationDelay: { throw CancellationError() },
            enrichmentStarter: { _, _ in }
        )

        await viewModel.loadDetails(id: cachedMeta.id, type: cachedMeta.type).value

        XCTAssertEqual(viewModel.uiState.meta?.id, cachedMeta.id)
        XCTAssertNil(viewModel.uiState.meta?.videos)
        XCTAssertFalse(viewModel.uiState.isLoading)
        XCTAssertNil(viewModel.uiState.error)
        XCTAssertFalse(viewModel.didLoadMetadataSuccessfully)
        XCTAssertNotNil(viewModel.metadataLoadError)
        viewModel.cancelAllTasks()
    }

    func testManualEpisodeRequestReplacesDefaultRequestedStreamIdentity() async {
        let meta = NuvioMeta(id: "series", name: "Series", type: "series")
        let repository = PrimaryPlaybackCatalogRepository(metadata: meta)
        let viewModel = DetailsViewModel(
            repository: repository,
            streamDiscoveryMode: .repository,
            deferredPreparationDelay: { throw CancellationError() },
            enrichmentStarter: { _, _ in }
        )

        viewModel.prepareStreams(forId: "series:1:1", type: "series")
        XCTAssertEqual(viewModel.requestedStreamId, "series:1:1")
        viewModel.prepareStreams(forId: "series:2:1", type: "series")
        XCTAssertEqual(viewModel.requestedStreamId, "series:2:1")

        viewModel.cancelAllTasks()
    }
}

final class DetailsPrimaryPlayTargetTests: XCTestCase {
    func testMovieTargetUsesPlayAndResumeLabels() {
        let movie = NuvioMeta(id: "movie", name: "Movie", type: "movie")
        let playTarget = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: [],
            continueItem: nil,
            watchedKeys: []
        )
        let resumeTarget = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: [],
            continueItem: continueItem(for: movie),
            watchedKeys: []
        )

        XCTAssertNil(playTarget.episode)
        XCTAssertEqual(playTarget.label, L10n.string("action_play", fallback: "Play"))
        XCTAssertTrue(playTarget.isPlayable)
        XCTAssertNil(resumeTarget.episode)
        XCTAssertEqual(resumeTarget.label, L10n.string("action_resume", fallback: "Resume"))
        XCTAssertTrue(resumeTarget.isPlayable)
    }

    func testSeriesStartsAtFirstRegularEpisodeAfterOrderingSpecialsLast() {
        let episodes = [
            episode("special", season: 0, number: 1),
            episode("s2e1", season: 2, number: 1),
            episode("s1e2", season: 1, number: 2),
            episode("s1e1", season: 1, number: 1)
        ]

        let ordered = TvDetailsPlayTargetBuilder.orderedEpisodes(episodes)
        let target = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: ordered,
            continueItem: nil,
            watchedKeys: []
        )

        XCTAssertEqual(ordered.map(\.id), ["s1e1", "s1e2", "s2e1", "special"])
        XCTAssertEqual(target.episode?.id, "s1e1")
        XCTAssertEqual(target.label, "\(L10n.string("action_play", fallback: "Play")) S1 E1")
        XCTAssertTrue(target.isPlayable)
    }

    func testContinueWatchingResumesTheRecordedEpisode() {
        let series = seriesMeta()
        let episodes = TvDetailsPlayTargetBuilder.orderedEpisodes(series.videos ?? [])
        let target = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: episodes,
            continueItem: continueItem(for: series, season: 1, episode: 2),
            watchedKeys: []
        )

        XCTAssertEqual(target.episode?.id, "series:1:2")
        XCTAssertEqual(target.label, "\(L10n.string("action_resume", fallback: "Resume")) S1 E2")
        XCTAssertTrue(target.isPlayable)
    }

    func testWatchedFurthestEpisodeSelectsNextEpisode() {
        let series = seriesMeta()
        let episodes = TvDetailsPlayTargetBuilder.orderedEpisodes(series.videos ?? [])
        let target = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: episodes,
            continueItem: nil,
            watchedKeys: ["1:1", "2:1"]
        )

        XCTAssertEqual(target.episode?.id, "series:2:2")
        XCTAssertEqual(target.label, "\(L10n.string("details_next", fallback: "Next")) S2 E2")
        XCTAssertTrue(target.isPlayable)
    }

    func testLibraryEpisodeMarksDoNotChangeGlobalInitialPlayTarget() {
        let series = seriesMeta()
        let progressItem = WatchedStoreItem(
            meta: series,
            watchedAt: Date(timeIntervalSince1970: 1),
            season: 1,
            episode: 1,
            sources: [TraktWatchProgressSource.nuvioSync.rawValue],
            legacyUnattributed: false
        )
        let libraryItem = WatchedStoreItem(
            meta: series,
            watchedAt: Date(timeIntervalSince1970: 2),
            season: 1,
            episode: 2,
            sources: [TraktWatchProgressSource.trakt.rawValue],
            legacyUnattributed: false
        )
        let progressSnapshot = WatchedSnapshot(items: [progressItem, libraryItem], source: .nuvioSync)
        let librarySnapshot = WatchedSnapshot(
            items: [progressItem, libraryItem],
            source: .trakt,
            strictSourceOnly: true
        )

        let watchedKeys = TvDetailsEpisodeWatchedKeys(
            meta: series,
            progressSnapshot: progressSnapshot,
            librarySnapshot: librarySnapshot
        )
        let target = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: TvDetailsPlayTargetBuilder.orderedEpisodes(series.videos ?? []),
            continueItem: nil,
            watchedKeys: watchedKeys.playTarget
        )
        let initialEpisode = TvDetailsInitialEpisodeResolver.resolve(
            episodes: TvDetailsPlayTargetBuilder.orderedEpisodes(series.videos ?? []),
            continueItem: nil,
            watchedKeys: watchedKeys.playTarget
        )

        XCTAssertEqual(watchedKeys.display, ["1:2"])
        XCTAssertEqual(watchedKeys.playTarget, ["1:1"])
        XCTAssertEqual(target.episode?.id, "series:1:2")
        XCTAssertEqual(initialEpisode?.id, "series:1:2")
    }

    func testUnairedNextEpisodeIsUpcomingAndNotPlayable() {
        let episodes = [
            episode("s1e1", season: 1, number: 1, released: "2020-01-01"),
            episode("s1e2", season: 1, number: 2, released: "2999-01-01")
        ]
        let target = TvDetailsPlayTargetBuilder.makePlayTarget(
            episodes: episodes,
            continueItem: nil,
            watchedKeys: ["1:1"]
        )

        XCTAssertEqual(target.episode?.id, "s1e2")
        XCTAssertEqual(target.label, "\(L10n.string("details_upcoming", fallback: "Upcoming")) S1 E2")
        XCTAssertFalse(target.isPlayable)
    }

    private func continueItem(
        for meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil
    ) -> ContinueWatchingItem {
        ContinueWatchingItem(
            meta: meta,
            streamUrl: "https://example.com/video.mkv",
            position: 60,
            duration: 600,
            lastWatchedAt: Date(timeIntervalSince1970: 1),
            season: season,
            episode: episode
        )
    }

    private func seriesMeta() -> NuvioMeta {
        NuvioMeta(
            id: "series",
            name: "Series",
            type: "series",
            videos: [
                episode("series:2:2", season: 2, number: 2, released: "2020-01-01"),
                episode("series:1:1", season: 1, number: 1, released: "2020-01-01"),
                episode("series:2:1", season: 2, number: 1, released: "2020-01-01"),
                episode("series:1:2", season: 1, number: 2, released: "2020-01-01")
            ]
        )
    }

    private func episode(
        _ id: String,
        season: Int,
        number: Int,
        released: String? = nil
    ) -> NuvioVideo {
        NuvioVideo(
            id: id,
            title: id,
            season: season,
            episode: number,
            released: released
        )
    }
}

final class DetailsSavedPlaybackTargetResolverTests: XCTestCase {
    func testSavedEpisodeLinkBeatsAddonWinnerAndWarmsWhenSmartSelectionIsOff() {
        let savedURL = URL(string: "https://saved.example/signed.mkv")!
        let savedHeaders = ["Referer": "https://saved-addon.example"]
        let episode = NuvioVideo(id: "series:2:3", title: "Episode", season: 2, episode: 3)
        let addonWinner = NuvioStream(
            url: "https://new-addon.example/other.mkv",
            name: "New addon source",
            description: "1080p",
            addonName: "Addon"
        )
        var lookup: (metaID: String, season: Int?, episode: Int?, profileID: String?)?

        let target = DetailsSavedPlaybackTargetResolver.resolve(
            metaID: "series",
            episode: episode,
            profileID: "profile-a",
            reuseEnabled: true,
            manualPicker: false,
            lookup: { metaID, season, episode, profileID in
                lookup = (metaID, season, episode, profileID)
                return (savedURL.absoluteString, savedHeaders)
            }
        )

        XCTAssertEqual(lookup?.metaID, "series")
        XCTAssertEqual(lookup?.season, 2)
        XCTAssertEqual(lookup?.episode, 3)
        XCTAssertEqual(lookup?.profileID, "profile-a")
        XCTAssertEqual(target?.url, savedURL)
        XCTAssertEqual(target?.httpHeaders, savedHeaders)
        XCTAssertNotEqual(target?.url.absoluteString, addonWinner.directURL)
        XCTAssertTrue(DetailsPlaybackPrewarmPolicy.shouldPrewarm(
            url: target?.url,
            backend: .aether,
            backgroundStreamPreFetchEnabled: true,
            smartStreamSelectionEnabled: false,
            usesExternalPlayer: false,
            isPlayableMovieOrEpisode: true,
            isLiveOrSports: false,
            isSavedPlaybackTarget: true
        ))
    }

    func testSavedTargetResolverRejectsManualPickerDisabledReuseAndExpiredOrInvalidLinks() {
        var lookupCalls = 0
        let lookup: DetailsSavedPlaybackTargetResolver.Lookup = { _, _, _, _ in
            lookupCalls += 1
            return ("https://saved.example/movie.mkv", [:])
        }

        XCTAssertNil(DetailsSavedPlaybackTargetResolver.resolve(
            metaID: "movie", episode: nil, profileID: "profile-a",
            reuseEnabled: true, manualPicker: true, lookup: lookup
        ))
        XCTAssertNil(DetailsSavedPlaybackTargetResolver.resolve(
            metaID: "movie", episode: nil, profileID: "profile-a",
            reuseEnabled: false, manualPicker: false, lookup: lookup
        ))
        XCTAssertEqual(lookupCalls, 0)
        XCTAssertNil(DetailsSavedPlaybackTargetResolver.resolve(
            metaID: "movie", episode: nil, profileID: "profile-a",
            reuseEnabled: true, manualPicker: false, lookup: { _, _, _, _ in nil }
        ), "an expired LastPlaybackStreamStore lookup falls back to normal source selection")
        XCTAssertNil(DetailsSavedPlaybackTargetResolver.resolve(
            metaID: "movie", episode: nil, profileID: "profile-a",
            reuseEnabled: true, manualPicker: false, lookup: { _, _, _, _ in ("https://", [:]) }
        ))
        XCTAssertEqual(lookupCalls, 0)
    }
}

@MainActor
final class DetailsPlaybackPrewarmerTests: XCTestCase {
    func testPreparedHandoffSurvivesMainActorSettlementAndReturnedDetailsContext() async {
        let firstURL = URL(string: "https://cdn.example/prepared-first.mkv")!
        let secondURL = URL(string: "https://cdn.example/returned-details.mkv")!
        let headers = ["Referer": "https://addon.example"]
        let barrier = DetailsPrewarmPreparedGate()
        let recorder = DetailsPrewarmHybridRecorder()
        let prewarmer = DetailsPlaybackPrewarmer(
            warm: { url, _ in recorder.sourceWarm(url) },
            discard: { recorder.sourceDiscard($0) },
            warmRangeProbe: { _, _, _, token in recorder.rangeWarm(token) },
            discardRangeProbe: { recorder.rangeDiscard($0) },
            afterWarmPrepared: { await barrier.pauseFirstPreparedOperation() }
        )

        prewarmer.warm(url: firstURL, headers: headers, hybridProfileID: "profile-a")
        await barrier.waitUntilPrepared()
        let firstSettlement = prewarmer.settlementTaskForTesting()
        let retained = prewarmer.handOff(
            urlString: firstURL.absoluteString,
            headers: headers,
            retainOnlyIf: true
        )
        XCTAssertTrue(retained, "prepared work can be claimed before MainActor settlement")

        // Reopening Details can start a new warm while the claimed operation is
        // still held before its old settlement callback.
        prewarmer.activateContext()
        prewarmer.warm(url: secondURL, headers: headers, hybridProfileID: "profile-a")
        let secondSettlement = prewarmer.settlementTaskForTesting()
        await prewarmer.waitForCurrentOperation()
        let firstProbeToken = recorder.rangeWarmTokens[0]
        let secondProbeToken = recorder.rangeWarmTokens[1]
        prewarmer.endContext()

        await barrier.releasePreparedOperation()
        await firstSettlement?.value
        await secondSettlement?.value

        XCTAssertFalse(recorder.sourceDiscardURLs.contains(firstURL))
        XCTAssertTrue(recorder.sourceDiscardURLs.contains(secondURL))
        XCTAssertFalse(recorder.discardedRangeTokens.contains(firstProbeToken))
        XCTAssertTrue(recorder.discardedRangeTokens.contains(secondProbeToken))
    }

    func testUnfinishedWarmCannotBeClaimedAndIsDiscardedOnHandoff() async {
        let url = URL(string: "https://cdn.example/unprepared.mkv")!
        let gate = DetailsPrewarmGate()
        let discards = DetailsPrewarmDiscardRecorder()
        let prewarmer = DetailsPlaybackPrewarmer(
            warm: { url, headers in await gate.warm(url: url, headers: headers) },
            discard: { discards.record($0) }
        )

        prewarmer.warm(url: url, headers: [:])
        await gate.waitForStartCount(1)
        let retained = prewarmer.handOff(urlString: url.absoluteString, headers: [:], retainOnlyIf: true)
        XCTAssertFalse(retained)

        await gate.release(start: 1)
        await prewarmer.waitForCurrentOperation()
        XCTAssertFalse(discards.urls.isEmpty)
        XCTAssertTrue(discards.urls.allSatisfy { $0 == url })
    }

    func testDetailsCandidateIdentityIgnoresSubtitleAndDisplayChangesAndReusesWarm() async {
        let url = "https://cdn.example/same-source.mkv"
        let headers = ["Referer": "https://addon.example"]
        let original = NuvioStream(
            url: url,
            name: "Original label",
            description: "1080p",
            addonName: "Original addon",
            subtitles: [],
            addonLogoURL: "https://cdn.example/old-logo.png",
            videoSize: 100,
            videoHash: "old-hash",
            httpHeaders: headers
        )
        let subtitle = NuvioSubtitle(
            url: "https://cdn.example/subtitles.vtt",
            language: "en",
            label: "English"
        )
        let latest = NuvioStream(
            url: url,
            name: "Updated label",
            description: "4K",
            addonName: "Updated addon",
            subtitles: [subtitle],
            addonLogoURL: "https://cdn.example/new-logo.png",
            videoSize: 200,
            videoHash: "new-hash",
            httpHeaders: headers
        )
        let originalIdentity = DetailsBackgroundResolutionIdentity(
            streamID: "movie",
            episodeID: nil,
            candidate: original
        )
        let latestIdentity = DetailsBackgroundResolutionIdentity(
            streamID: "movie",
            episodeID: nil,
            candidate: latest
        )
        XCTAssertEqual(originalIdentity, latestIdentity)
        XCTAssertEqual(latestIdentity.candidate.subtitles, [subtitle])

        let resolvedURL = URL(string: url)!
        let recorder = DetailsPrewarmHybridRecorder()
        let prewarmer = DetailsPlaybackPrewarmer(
            warm: { sourceURL, _ in recorder.sourceWarm(sourceURL) },
            discard: { recorder.sourceDiscard($0) }
        )
        prewarmer.warm(url: resolvedURL, headers: headers)
        await prewarmer.waitForCurrentOperation()
        prewarmer.warm(url: resolvedURL, headers: latest.httpHeaders ?? [:])
        await prewarmer.waitForCurrentOperation()
        let retained = prewarmer.handOff(
            urlString: latest.directURL!,
            headers: latest.httpHeaders ?? [:],
            retainOnlyIf: true
        )

        XCTAssertEqual(recorder.sourceWarmURLs, [resolvedURL])
        XCTAssertTrue(retained)
        XCTAssertTrue(recorder.sourceDiscardURLs.isEmpty)
    }

    func testDetailsCandidateIdentityChangesForTransportAndEpisodeChanges() {
        let headers = ["Referer": "https://addon.example"]
        let direct = NuvioStream(
            url: "https://cdn.example/first.mkv", name: "Source", description: nil,
            addonName: "Addon", httpHeaders: headers
        )
        let identity = DetailsBackgroundResolutionIdentity(
            streamID: "series:1:1", episodeID: "series:1:1", candidate: direct
        )
        let changedURL = NuvioStream(
            url: "https://cdn.example/second.mkv", name: "Source", description: nil,
            addonName: "Addon", httpHeaders: headers
        )
        let changedHeaders = NuvioStream(
            url: "https://cdn.example/first.mkv", name: "Source", description: nil,
            addonName: "Addon", httpHeaders: ["Referer": "https://other.example"]
        )
        XCTAssertNotEqual(identity, DetailsBackgroundResolutionIdentity(
            streamID: identity.streamID, episodeID: identity.episodeID, candidate: changedURL
        ))
        XCTAssertNotEqual(identity, DetailsBackgroundResolutionIdentity(
            streamID: identity.streamID, episodeID: identity.episodeID, candidate: changedHeaders
        ))
        XCTAssertNotEqual(identity, DetailsBackgroundResolutionIdentity(
            streamID: identity.streamID, episodeID: "series:1:2", candidate: direct
        ))

        let torrent = NuvioStream(
            url: nil, name: "Torrent", description: nil, addonName: "Addon",
            infoHash: String(repeating: "a", count: 40), fileIdx: 1, sources: ["udp://tracker-a.example:1337/announce"], filename: "episode.mkv"
        )
        let torrentIdentity = DetailsBackgroundResolutionIdentity(
            streamID: "series:1:1", episodeID: "series:1:1", candidate: torrent
        )
        XCTAssertEqual(torrent.effectiveInfoHash, String(repeating: "a", count: 40))
        XCTAssertEqual(torrent.sources, ["udp://tracker-a.example:1337/announce"])
        let changedHash = NuvioStream(
            url: nil, name: "Torrent", description: nil, addonName: "Addon",
            infoHash: String(repeating: "b", count: 40), fileIdx: 1, sources: ["udp://tracker-a.example:1337/announce"], filename: "episode.mkv"
        )
        let changedIndex = NuvioStream(
            url: nil, name: "Torrent", description: nil, addonName: "Addon",
            infoHash: String(repeating: "a", count: 40), fileIdx: 2, sources: ["udp://tracker-a.example:1337/announce"], filename: "episode.mkv"
        )
        let changedSources = NuvioStream(
            url: nil, name: "Torrent", description: nil, addonName: "Addon",
            infoHash: String(repeating: "a", count: 40), fileIdx: 1, sources: ["udp://tracker-b.example:1337/announce"], filename: "episode.mkv"
        )
        let changedFilename = NuvioStream(
            url: nil, name: "Torrent", description: nil, addonName: "Addon",
            infoHash: String(repeating: "a", count: 40), fileIdx: 1, sources: ["udp://tracker-a.example:1337/announce"], filename: "other.mkv"
        )
        XCTAssertNotEqual(torrent.effectiveInfoHash, changedHash.effectiveInfoHash)
        XCTAssertNotEqual(torrent.effectiveFileIdx, changedIndex.effectiveFileIdx)
        XCTAssertNotEqual(torrent.sources, changedSources.sources)
        XCTAssertNotEqual(torrent.filename, changedFilename.filename)
        for changed in [changedHash, changedIndex, changedSources, changedFilename] {
            XCTAssertNotEqual(torrentIdentity, DetailsBackgroundResolutionIdentity(
                streamID: torrentIdentity.streamID, episodeID: torrentIdentity.episodeID, candidate: changed
            ))
        }
    }

    func testDuplicateWarmDoesNotRestartAndReplacementWaitsForLateCleanup() async {
        let url = URL(string: "https://cdn.example/video.mkv")!
        let headersA = ["Authorization": "a"]
        let headersB = ["Authorization": "b"]
        let gate = DetailsPrewarmGate()
        let discards = DetailsPrewarmDiscardRecorder()
        let prewarmer = DetailsPlaybackPrewarmer(
            warm: { url, headers in await gate.warm(url: url, headers: headers) },
            discard: { discards.record($0) }
        )

        prewarmer.warm(url: url, headers: headersA)
        await gate.waitForStartCount(1)
        prewarmer.warm(url: url, headers: headersA)
        let duplicateStartCount = await gate.startCount
        XCTAssertEqual(duplicateStartCount, 1)

        // Same URL with new headers is serialized behind the canceled operation;
        // its late completion must discard before the replacement starts.
        prewarmer.warm(url: url, headers: headersB)
        await gate.release(start: 1)
        await gate.waitForStartCount(2)
        let replacementCleanup = discards.urls
        XCTAssertFalse(replacementCleanup.isEmpty)
        XCTAssertTrue(replacementCleanup.allSatisfy { $0 == url })
        await gate.release(start: 2)
        await prewarmer.waitForCurrentOperation()
        let totalStartCount = await gate.startCount
        XCTAssertEqual(totalStartCount, 2)
    }

    func testBackCleanupDiscardsCompletedWarm() async {
        let url = URL(string: "https://cdn.example/back.mkv")!
        let discards = DetailsPrewarmDiscardRecorder()
        let prewarmer = DetailsPlaybackPrewarmer(
            warm: { _, _ in },
            discard: { discards.record($0) }
        )

        prewarmer.warm(url: url, headers: [:])
        await prewarmer.waitForCurrentOperation()
        prewarmer.endContext()

        XCTAssertEqual(discards.urls, [url])
    }

    func testMatchingCompletedWarmSurvivesPlaybackHandoffAndDetailsExit() async {
        let url = URL(string: "https://cdn.example/handoff.mkv")!
        let headers = ["Referer": "https://addon.example"]
        let discards = DetailsPrewarmDiscardRecorder()
        let prewarmer = DetailsPlaybackPrewarmer(
            warm: { _, _ in },
            discard: { discards.record($0) }
        )

        prewarmer.warm(url: url, headers: headers)
        await prewarmer.waitForCurrentOperation()
        let retained = prewarmer.handOff(
            urlString: url.absoluteString,
            headers: headers,
            retainOnlyIf: true
        )
        prewarmer.endContext()

        XCTAssertTrue(retained)
        XCTAssertTrue(discards.urls.isEmpty)
    }

    func testMismatchedPlaybackHandoffDiscardsDetailsWarm() async {
        let warmedURL = URL(string: "https://cdn.example/warmed.mkv")!
        let playedURL = URL(string: "https://cdn.example/other.mkv")!
        let discards = DetailsPrewarmDiscardRecorder()
        let prewarmer = DetailsPlaybackPrewarmer(
            warm: { _, _ in },
            discard: { discards.record($0) }
        )

        prewarmer.warm(url: warmedURL, headers: [:])
        await prewarmer.waitForCurrentOperation()
        let retained = prewarmer.handOff(
            urlString: playedURL.absoluteString,
            headers: [:],
            retainOnlyIf: true
        )

        XCTAssertFalse(retained)
        XCTAssertEqual(discards.urls, [warmedURL])
    }

    func testMatchingURLWithDifferentHeadersDiscardsDetailsWarm() async {
        let url = URL(string: "https://cdn.example/headers.mkv")!
        let discards = DetailsPrewarmDiscardRecorder()
        let prewarmer = DetailsPlaybackPrewarmer(
            warm: { _, _ in },
            discard: { discards.record($0) }
        )

        prewarmer.warm(url: url, headers: ["Authorization": "warm"])
        await prewarmer.waitForCurrentOperation()
        let retained = prewarmer.handOff(
            urlString: url.absoluteString,
            headers: ["Authorization": "playback"],
            retainOnlyIf: true
        )

        XCTAssertFalse(retained)
        XCTAssertEqual(discards.urls, [url])
    }

    func testExternalPlaybackHandoffDiscardsMatchingWarm() async {
        let url = URL(string: "https://cdn.example/external.mkv")!
        let discards = DetailsPrewarmDiscardRecorder()
        let prewarmer = DetailsPlaybackPrewarmer(
            warm: { _, _ in },
            discard: { discards.record($0) }
        )

        prewarmer.warm(url: url, headers: [:])
        await prewarmer.waitForCurrentOperation()
        let retained = prewarmer.handOff(
            urlString: url.absoluteString,
            headers: [:],
            retainOnlyIf: false
        )

        XCTAssertFalse(retained)
        XCTAssertEqual(discards.urls, [url])
    }

    func testHybridWarmStartsRangeProbeAndMatchingHandoffRetainsBoth() async {
        let url = URL(string: "https://cdn.example/hybrid-handoff.mkv")!
        let headers = ["Referer": "https://addon.example"]
        let recorder = DetailsPrewarmHybridRecorder()
        let prewarmer = DetailsPlaybackPrewarmer(
            warm: { url, _ in recorder.sourceWarm(url) },
            discard: { recorder.sourceDiscard($0) },
            warmRangeProbe: { _, _, _, token in recorder.rangeWarm(token) },
            discardRangeProbe: { recorder.rangeDiscard($0) }
        )

        prewarmer.warm(url: url, headers: headers, hybridProfileID: "profile-a")
        await prewarmer.waitForCurrentOperation()
        XCTAssertEqual(recorder.sourceWarmURLs, [url])
        XCTAssertEqual(recorder.rangeWarmTokens.count, 1)

        let retained = prewarmer.handOff(
            urlString: url.absoluteString,
            headers: headers,
            retainOnlyIf: true
        )
        prewarmer.endContext()

        XCTAssertTrue(retained)
        XCTAssertTrue(recorder.sourceDiscardURLs.isEmpty)
        XCTAssertTrue(recorder.discardedRangeTokens.isEmpty)
    }

    func testHybridBackCleanupDiscardsProbeByItsOperationToken() async {
        let url = URL(string: "https://cdn.example/hybrid-back.mkv")!
        let recorder = DetailsPrewarmHybridRecorder()
        let prewarmer = DetailsPlaybackPrewarmer(
            warm: { url, _ in recorder.sourceWarm(url) },
            discard: { recorder.sourceDiscard($0) },
            warmRangeProbe: { _, _, _, token in recorder.rangeWarm(token) },
            discardRangeProbe: { recorder.rangeDiscard($0) }
        )

        prewarmer.warm(url: url, headers: [:], hybridProfileID: "profile-a")
        await prewarmer.waitForCurrentOperation()
        let token = try! XCTUnwrap(recorder.rangeWarmTokens.first)
        prewarmer.endContext()

        XCTAssertEqual(recorder.sourceDiscardURLs, [url])
        XCTAssertEqual(recorder.discardedRangeTokens, [token])
    }

    func testEligibilityRejectsDisabledHLSCacheLocalAndNativeHLSHosts() {
        func eligible(_ rawURL: String, background: Bool = true, smart: Bool = true) -> Bool {
            DetailsPlaybackPrewarmPolicy.shouldPrewarm(
                url: URL(string: rawURL),
                backend: .aether,
                backgroundStreamPreFetchEnabled: background,
                smartStreamSelectionEnabled: smart,
                usesExternalPlayer: false,
                isPlayableMovieOrEpisode: true,
                isLiveOrSports: false
            )
        }

        XCTAssertTrue(eligible("https://cdn.example/movie.mkv"))
        XCTAssertFalse(eligible("https://cdn.example/movie.mkv", background: false))
        XCTAssertFalse(eligible("https://cdn.example/movie.mkv", smart: false))
        XCTAssertTrue(eligible("https://cdn.example/movie.mkv"), "Hybrid caching remains eligible for an independent warm probe")
        XCTAssertFalse(eligible("https://cdn.example/live.m3u8"))
        XCTAssertFalse(eligible("http://localhost/movie.mkv"))
        XCTAssertFalse(eligible("http://LOCALHOST/movie.mkv"))
        XCTAssertFalse(eligible("http://[::1]/movie.mkv"))
        XCTAssertFalse(eligible("https://manifest.googlevideo.com/movie"))
        XCTAssertFalse(eligible("usenet://provider/release"))
        XCTAssertFalse(DetailsPlaybackPrewarmPolicy.shouldPrewarm(
            url: URL(string: "https://cdn.example/movie.mkv"),
            backend: .aether,
            backgroundStreamPreFetchEnabled: true,
            smartStreamSelectionEnabled: true,
            usesExternalPlayer: true,
            isPlayableMovieOrEpisode: true,
            isLiveOrSports: false
        ))
    }
}

private actor DetailsPrewarmGate {
    private var started = 0
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var operations: [Int: CheckedContinuation<Void, Never>] = [:]

    var startCount: Int { started }

    func warm(url: URL, headers: [String: String]) async {
        await withCheckedContinuation { continuation in
            started += 1
            let index = started
            operations[index] = continuation
            let ready = startWaiters.filter { index >= $0.key }
            for (requested, continuations) in ready {
                startWaiters.removeValue(forKey: requested)
                continuations.forEach { $0.resume() }
            }
        }
    }

    func waitForStartCount(_ count: Int) async {
        if started >= count { return }
        await withCheckedContinuation { continuation in
            startWaiters[count, default: []].append(continuation)
        }
    }

    func release(start index: Int) {
        operations.removeValue(forKey: index)?.resume()
    }
}

private actor DetailsPrewarmPreparedGate {
    private var didEnter = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func pauseFirstPreparedOperation() async {
        guard !didEnter else { return }
        didEnter = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilPrepared() async {
        if didEnter { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func releasePreparedOperation() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class DetailsPrewarmDiscardRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    func record(_ url: URL) {
        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
    }
}


private final class DetailsPrewarmHybridRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceURLs = [URL]()
    private var discardedURLs = [URL]()
    private var rangeTokens = [UUID]()
    private var discardedTokens = [UUID]()

    var sourceWarmURLs: [URL] { lock.lock(); defer { lock.unlock() }; return sourceURLs }
    var sourceDiscardURLs: [URL] { lock.lock(); defer { lock.unlock() }; return discardedURLs }
    var rangeWarmTokens: [UUID] { lock.lock(); defer { lock.unlock() }; return rangeTokens }
    var discardedRangeTokens: [UUID] { lock.lock(); defer { lock.unlock() }; return discardedTokens }

    func sourceWarm(_ url: URL) { lock.lock(); sourceURLs.append(url); lock.unlock() }
    func sourceDiscard(_ url: URL) { lock.lock(); discardedURLs.append(url); lock.unlock() }
    func rangeWarm(_ token: UUID) { lock.lock(); rangeTokens.append(token); lock.unlock() }
    func rangeDiscard(_ token: UUID) { lock.lock(); discardedTokens.append(token); lock.unlock() }
}
