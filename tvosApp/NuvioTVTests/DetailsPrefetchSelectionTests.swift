import XCTest
@testable import NuvioTV

private final class PrefetchSelectionRepository: CatalogRepository {
    var requestedStreamIDs: [String] = []

    func getHomeCatalogs() async throws -> [NuvioCatalog] { [] }
    func getMetadata(id: String, type: String) async throws -> NuvioMeta { NuvioMeta(id: id, name: id, type: type) }

    func getStreams(id: String, type: String) async throws -> [NuvioStream] {
        requestedStreamIDs.append(id)
        return [NuvioStream(url: "https://example.com/\(id).mkv", name: id, description: nil, addonName: "Test")]
    }

    func search(query: String) async throws -> [NuvioMeta] { [] }

    func browseCatalog(contentType: String, catalogId: String, page: Int, genre: String?, year: Int?, sort: String?) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: page)
    }

    func browseCatalog(contentType: String, catalogId: String, skip: Int, genre: String?) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: 0, nextSkip: skip)
    }

    func browseCatalog(addonId: String?, contentType: String, catalogId: String, skip: Int, genre: String?) async throws -> CatalogPage {
        CatalogPage(items: [], hasMore: false, page: 0, nextSkip: skip)
    }

    func getGenres(contentType: String) async throws -> [String] { [] }
    func getCollectionFolderItems(sources: [NuvioCollectionCatalogSource], limit: Int) async -> [NuvioMeta] { [] }
}

/// Background pre-fetch loads streams for the default episode. Once the viewer
/// picks an episode, a default that changes later must not replace its streams.
@MainActor
final class DetailsPrefetchSelectionTests: XCTestCase {
    private let seriesID = "tt99900017"
    private var savedPrefetchSetting: Any?

    override func setUp() async throws {
        savedPrefetchSetting = ProfileSettings.current.object(forKey: SettingsKey.backgroundStreamPreFetch)
        ProfileSettings.current.set(true, forKey: SettingsKey.backgroundStreamPreFetch)
    }

    override func tearDown() async throws {
        if let savedPrefetchSetting {
            ProfileSettings.current.set(savedPrefetchSetting, forKey: SettingsKey.backgroundStreamPreFetch)
        } else {
            ProfileSettings.current.removeObject(forKey: SettingsKey.backgroundStreamPreFetch)
        }
    }

    private func series(_ episodes: [(season: Int, episode: Int)]) -> NuvioMeta {
        NuvioMeta(
            id: seriesID,
            name: "Series",
            imdbId: seriesID,
            type: "series",
            videos: episodes.map {
                NuvioVideo(id: "\(seriesID):\($0.season):\($0.episode)", title: "Episode", season: $0.season, episode: $0.episode)
            }
        )
    }

    private func makeViewModel(_ repository: PrefetchSelectionRepository) -> DetailsViewModel {
        DetailsViewModel(
            repository: repository,
            streamDiscoveryMode: .repository,
            deferredPreparationDelay: { throw CancellationError() },
            enrichmentStarter: { _, _ in }
        )
    }

    private func waitForStreams(_ viewModel: DetailsViewModel) async {
        for _ in 0..<200 where viewModel.uiState.streams.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testPrefetchFollowsANewDefaultEpisodeUntilTheViewerPicksOne() async {
        let viewModel = makeViewModel(PrefetchSelectionRepository())
        viewModel.triggerStreamPreFetch(for: series([(1, 1), (1, 2)]))
        XCTAssertEqual(viewModel.prefetchedStreamId, "\(seriesID):1:1")

        // Fuller metadata arrives with other seasons: the default moves.
        viewModel.triggerStreamPreFetch(for: series([(2, 5), (2, 6)]))
        XCTAssertEqual(viewModel.prefetchedStreamId, "\(seriesID):2:5")
        XCTAssertEqual(viewModel.requestedStreamId, "\(seriesID):2:5")
        viewModel.cancelAllTasks()
    }

    func testANewDefaultEpisodeDoesNotReplaceTheStreamsOfThePickedEpisode() async {
        let repository = PrefetchSelectionRepository()
        let viewModel = makeViewModel(repository)
        viewModel.triggerStreamPreFetch(for: series([(1, 1), (1, 119)]))

        // The viewer resumes S1E119 from Continue Watching.
        let picked = "\(seriesID):1:119"
        viewModel.streamSelectionStarted(for: picked)
        viewModel.prepareStreams(forId: picked, type: "series")

        // The default episode changes afterwards.
        viewModel.triggerStreamPreFetch(for: series([(2, 5), (2, 6)]))

        XCTAssertEqual(viewModel.requestedStreamId, picked)
        await waitForStreams(viewModel)
        XCTAssertEqual(viewModel.uiState.streams.map(\.name), [picked])
        XCTAssertTrue(viewModel.hasLoadedStreams(for: picked))
        XCTAssertFalse(repository.requestedStreamIDs.contains("\(seriesID):2:5"))
        viewModel.cancelAllTasks()
    }

    func testAnEpisodeKeepsItsSeasonAndEpisodeWhenMetadataLoads() {
        // Same title: nothing to reload.
        XCTAssertEqual(DetailsViewModel.streamIdAfterMetadataLoad(requested: "tt12853970:1:119", metaStreamId: "tt12853970"), "tt12853970:1:119")
        // Requested under another id for the title: only the title part changes.
        XCTAssertEqual(DetailsViewModel.streamIdAfterMetadataLoad(requested: "tmdb:1234:1:119", metaStreamId: "tt12853970"), "tt12853970:1:119")
        // Metadata without a canonical id: the request stays as it was.
        XCTAssertEqual(DetailsViewModel.streamIdAfterMetadataLoad(requested: "tmdb:1234:2:5", metaStreamId: "tmdb:1234"), "tmdb:1234:2:5")
        // A movie still moves to the canonical id.
        XCTAssertEqual(DetailsViewModel.streamIdAfterMetadataLoad(requested: "tmdb:603", metaStreamId: "tt0133093"), "tt0133093")
        XCTAssertEqual(DetailsViewModel.streamIdAfterMetadataLoad(requested: "tt0133093", metaStreamId: "tt0133093"), "tt0133093")
    }

    func testLoadedStreamsCountOnlyForTheEpisodeTheyWereLoadedFor() async {
        let viewModel = makeViewModel(PrefetchSelectionRepository())
        viewModel.triggerStreamPreFetch(for: series([(1, 1), (1, 2)]))
        await waitForStreams(viewModel)
        XCTAssertTrue(viewModel.hasLoadedStreams(for: "\(seriesID):1:1"))

        // The viewer picks another episode: the first one's streams are gone.
        viewModel.streamSelectionStarted(for: "\(seriesID):1:2")
        viewModel.prepareStreams(forId: "\(seriesID):1:2", type: "series")
        await waitForStreams(viewModel)
        XCTAssertFalse(viewModel.hasLoadedStreams(for: "\(seriesID):1:1"))
        XCTAssertTrue(viewModel.hasLoadedStreams(for: "\(seriesID):1:2"))
        viewModel.cancelAllTasks()
    }
}
