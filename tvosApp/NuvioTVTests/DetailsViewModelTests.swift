//
//  DetailsViewModelTests.swift
//  NuvioTVTests
//
//  Unit tests for DetailsViewModel
//

import XCTest
import Combine
@testable import NuvioTV

/// Returns metadata only when the test explicitly releases the request. It
/// deliberately ignores task cancellation so generation checks are exercised.
private final class ControlledDetailsRepository: MockCatalogRepository {
    var didStartStreams = false
    var metadataWaiterEntered: ((String) -> Void)?
    private var releaseCount = 0
    private let waiterLock = NSLock()
    private var waiters: [String: [CheckedContinuation<NuvioMeta, Never>]] = [:]

    override func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        await withCheckedContinuation { (continuation: CheckedContinuation<NuvioMeta, Never>) in
            waiterLock.lock()
            waiters[id, default: []].append(continuation)
            waiterLock.unlock()
            metadataWaiterEntered?(id)
        }
    }

    override func getStreams(id: String, type: String) async throws -> [NuvioStream] {
        didStartStreams = true
        return []
    }

    func release(id: String, type: String = "movie") {
        waiterLock.lock()
        releaseCount += 1
        let revision = releaseCount
        let waiter = waiters[id]?.popLast()
        waiterLock.unlock()
        waiter?.resume(returning: Self.makeMeta(id: id, type: type, revision: revision))
    }

    static func makeMeta(id: String, type: String, revision: Int = 0) -> NuvioMeta {
        NuvioMeta(id: id, name: "\(id)-v\(revision)", description: id, posterUrl: nil, backgroundUrl: nil,
                  logoUrl: nil, imdbId: nil, tmdbId: nil, type: type, year: 2024,
                  genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil,
                  director: nil, writer: nil, certification: nil, country: nil,
                  released: nil, status: nil, videos: nil, trailerYtIds: nil,
                  externalRatings: nil)
    }
}

private final class ImmediateDetailsRepository: MockCatalogRepository {
    override func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        return Self.makeMeta(id: id, type: type)
    }

    override func getStreams(id: String, type: String) async throws -> [NuvioStream] {
        [NuvioStream(url: "https://example.com/stream.mp4", name: "HD", description: "HD", addonName: "Test")]
    }

    private static func makeMeta(id: String, type: String) -> NuvioMeta {
        NuvioMeta(id: id, name: id, description: id, posterUrl: "https://example.com/poster.jpg", backgroundUrl: nil,
                  logoUrl: nil, imdbId: nil, tmdbId: nil, type: type, year: 2024,
                  genres: ["test"], rating: 8, releaseInfo: nil, runtime: nil, cast: nil,
                  director: nil, writer: nil, certification: nil, country: nil,
                  released: nil, status: nil, videos: nil, trailerYtIds: nil,
                  externalRatings: nil)
    }
}

@MainActor
final class DetailsViewModelTests: XCTestCase {

    var viewModel: DetailsViewModel!
    var repository: MockCatalogRepository!
    var cancellables: Set<AnyCancellable>!
    private var originalLibrarySourceMode: TraktLibrarySourceMode!

    override func setUp() async throws {
        originalLibrarySourceMode = TraktSettingsStore.librarySourceMode
        TraktSettingsStore.librarySourceMode = .local
        repository = ImmediateDetailsRepository()
        viewModel = DetailsViewModel(repository: repository, streamDiscoveryMode: .repository,
                                     deferredPreparationDelay: { },
                                     enrichmentStarter: { _, _ in })
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        viewModel?.cancelAllTasks()
        LibraryStore.remove(metaId: "watchlist_remove", type: "movie")
        LibraryStore.remove(metaId: "watchlist_multiple", type: "movie")
        TraktSettingsStore.librarySourceMode = originalLibrarySourceMode
        viewModel = nil
        repository = nil
        cancellables = nil
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertTrue(viewModel.uiState.isLoading, "Should be loading initially")
        XCTAssertNil(viewModel.uiState.meta, "Meta should be nil initially")
        XCTAssertTrue(viewModel.uiState.streams.isEmpty, "Streams should be empty initially")
        XCTAssertNil(viewModel.uiState.error, "Error should be nil initially")
        XCTAssertFalse(viewModel.uiState.isInWatchlist, "Should not be in watchlist initially")
    }

    // MARK: - Load Details Tests

    func testLoadDetailsSuccess() async {
        await viewModel.loadDetails(id: "movie_1", type: "movie").value

        XCTAssertFalse(viewModel.uiState.isLoading, "Should not be loading after data loads")
        XCTAssertNil(viewModel.uiState.error, "Error should be nil on success")
        XCTAssertNotNil(viewModel.uiState.meta, "Meta should be loaded")
    }

    func testLoadDetailsMetadata() async {
        await viewModel.loadDetails(id: "movie_1", type: "movie").value

        guard let meta = viewModel.uiState.meta else {
            XCTFail("Meta should be loaded")
            return
        }

        XCTAssertEqual(meta.id, "movie_1", "Meta ID should match requested ID")
        XCTAssertFalse(meta.name.isEmpty, "Meta should have name")
        XCTAssertNotNil(meta.description, "Meta should have description")
        XCTAssertNotNil(meta.posterUrl, "Meta should have poster URL")
        XCTAssertEqual(meta.type, "movie", "Meta type should be movie")
    }

    func testLoadDetailsStreams() async {
        // Wait for loading to complete (including streams)
        let streams = expectation(description: "streams loaded")
        var didFulfillStreams = false
        viewModel.$uiState.sink { state in
            if !state.streams.isEmpty && !didFulfillStreams {
                didFulfillStreams = true
                streams.fulfill()
            }
        }.store(in: &cancellables)
        await viewModel.loadDetails(id: "movie_1", type: "movie").value
        await fulfillment(of: [streams], timeout: 5)

        XCTAssertFalse(viewModel.uiState.streams.isEmpty, "Streams should be loaded")
        XCTAssertGreaterThan(viewModel.uiState.streams.count, 0, "Should have at least one stream")

        // Verify stream structure
        if let firstStream = viewModel.uiState.streams.first {
            XCTAssertNotNil(firstStream.url, "Stream should have URL")
            XCTAssertNotNil(firstStream.name, "Stream should have name")
            XCTAssertNotNil(firstStream.description, "Stream should have description")
        }
    }

    func testLoadDetailsSeriesContent() async {
        await viewModel.loadDetails(id: "series_1", type: "series").value

        guard let meta = viewModel.uiState.meta else {
            XCTFail("Meta should be loaded")
            return
        }

        XCTAssertEqual(meta.type, "series", "Meta type should be series")
    }

    func testOlderMetadataCannotOverwriteNewerRequest() async {
        let delayedRepository = ControlledDetailsRepository()
        let delayedViewModel = DetailsViewModel(
            repository: delayedRepository,
            streamDiscoveryMode: .repository,
            deferredPreparationDelay: { },
            enrichmentStarter: { _, _ in }
        )

        let oldWaiter = expectation(description: "old metadata waiter")
        let newWaiter = expectation(description: "new metadata waiter")
        delayedRepository.metadataWaiterEntered = { id in
            if id == "old_request" { oldWaiter.fulfill() }
            if id == "new_request" { newWaiter.fulfill() }
        }
        let oldLoad = delayedViewModel.loadDetails(id: "old_request", type: "movie")
        let newLoad = delayedViewModel.loadDetails(id: "new_request", type: "movie")
        await fulfillment(of: [oldWaiter, newWaiter], timeout: 1)
        delayedRepository.release(id: "new_request")
        await newLoad.value
        delayedRepository.release(id: "old_request")
        await oldLoad.value

        XCTAssertEqual(delayedViewModel.uiState.meta?.name, "new_request-v1")
        XCTAssertNil(delayedViewModel.uiState.error)
    }

    func testOlderSameIDMetadataCannotOverwriteReload() async {
        let delayedRepository = ControlledDetailsRepository()
        let delayedViewModel = DetailsViewModel(repository: delayedRepository,
                                                  streamDiscoveryMode: .repository,
                                                  deferredPreparationDelay: { },
                                                  enrichmentStarter: { _, _ in })
        let firstWaiter = expectation(description: "first metadata waiter")
        let secondWaiter = expectation(description: "second metadata waiter")
        var waiterCount = 0
        delayedRepository.metadataWaiterEntered = { _ in
            waiterCount += 1
            (waiterCount == 1 ? firstWaiter : secondWaiter).fulfill()
        }
        let firstLoad = delayedViewModel.loadDetails(id: "same_request", type: "movie")
        await fulfillment(of: [firstWaiter], timeout: 1)
        let secondLoad = delayedViewModel.loadDetails(id: "same_request", type: "movie")
        await fulfillment(of: [secondWaiter], timeout: 1)
        delayedRepository.release(id: "same_request")
        await secondLoad.value
        delayedRepository.release(id: "same_request")
        await firstLoad.value
        XCTAssertEqual(delayedViewModel.uiState.meta?.name, "same_request-v1")
    }

    func testCancellationInvalidatesMetadataAndDeferredWork() async {
        let delayedRepository = ControlledDetailsRepository()
        let delayedViewModel = DetailsViewModel(
            repository: delayedRepository,
            streamDiscoveryMode: .repository,
            deferredPreparationDelay: { },
            enrichmentStarter: { _, _ in }
        )

        let waiter = expectation(description: "metadata waiter")
        delayedRepository.metadataWaiterEntered = { _ in waiter.fulfill() }
        let load = delayedViewModel.loadDetails(id: "old_request", type: "movie")
        await fulfillment(of: [waiter], timeout: 1)
        delayedViewModel.cancelAllTasks()
        delayedRepository.release(id: "old_request")
        await load.value

        XCTAssertNil(delayedViewModel.uiState.meta)
        XCTAssertNil(delayedViewModel.uiState.error)
    }

    func testCancellationBeforeDeferredPreparationPreventsStreamsAndEnrichment() async {
        let delayedRepository = ControlledDetailsRepository()
        let gate = AsyncStream<Void>.makeStream()
        let deferredEntered = expectation(description: "deferred preparation entered")
        let deferredCompleted = expectation(description: "deferred preparation completed")
        var didStartEnrichment = false
        let delayedViewModel = DetailsViewModel(
            repository: delayedRepository,
            streamDiscoveryMode: .repository,
            deferredPreparationDelay: {
                deferredEntered.fulfill()
                for await _ in gate.stream { break }
                deferredCompleted.fulfill()
            },
            enrichmentStarter: { _, _ in didStartEnrichment = true }
        )

        let waiter = expectation(description: "metadata waiter")
        delayedRepository.metadataWaiterEntered = { _ in waiter.fulfill() }
        let load = delayedViewModel.loadDetails(id: "deferred_request", type: "movie")
        await fulfillment(of: [waiter], timeout: 1)
        delayedRepository.release(id: "deferred_request")
        await load.value
        await fulfillment(of: [deferredEntered], timeout: 1)
        delayedViewModel.cancelAllTasks()
        gate.continuation.yield(())
        await fulfillment(of: [deferredCompleted], timeout: 1)

        XCTAssertFalse(delayedRepository.didStartStreams)
        XCTAssertFalse(didStartEnrichment)
    }

    // MARK: - Watchlist Tests

    func testToggleWatchlistAddWithoutMetadataIsNoOp() {
        XCTAssertFalse(viewModel.uiState.isInWatchlist, "Should not be in watchlist initially")

        viewModel.toggleWatchlist()

        XCTAssertFalse(viewModel.uiState.isInWatchlist, "Missing metadata must be a no-op")
    }

    func testToggleWatchlistRemove() async {
        await viewModel.loadDetails(id: "watchlist_remove", type: "movie").value
        TraktSettingsStore.librarySourceMode = .local
        LibraryStore.remove(metaId: "watchlist_remove", type: "movie")
        viewModel.toggleWatchlist() // Add to watchlist
        XCTAssertTrue(viewModel.uiState.isInWatchlist, "Should be in watchlist")

        viewModel.toggleWatchlist() // Remove from watchlist
        XCTAssertFalse(viewModel.uiState.isInWatchlist, "Should not be in watchlist after second toggle")
    }

    func testToggleWatchlistMultipleTimes() async {
        await viewModel.loadDetails(id: "watchlist_multiple", type: "movie").value
        TraktSettingsStore.librarySourceMode = .local
        LibraryStore.remove(metaId: "watchlist_multiple", type: "movie")
        for i in 1...5 {
            viewModel.toggleWatchlist()
            let expectedState = i % 2 == 1
            XCTAssertEqual(viewModel.uiState.isInWatchlist, expectedState, "Watchlist state should toggle correctly on iteration \(i)")
        }
    }


    // MARK: - Loading State Tests

    func testLoadingStateTransition() async {
        let expectation = XCTestExpectation(description: "Loading state should transition")

        viewModel.$uiState
            .dropFirst() // Skip initial state
            .sink { state in
                if !state.isLoading {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)

        viewModel.loadDetails(id: "movie_1", type: "movie")

        await fulfillment(of: [expectation], timeout: 5.0)
    }

    // MARK: - Multiple Load Tests

    func testMultipleLoadDetailsCalls() async {
        // First load
        await viewModel.loadDetails(id: "movie_1", type: "movie").value
        let firstMeta = viewModel.uiState.meta

        // Second load with different ID
        await viewModel.loadDetails(id: "movie_2", type: "movie").value
        let secondMeta = viewModel.uiState.meta

        XCTAssertNotEqual(firstMeta?.id, secondMeta?.id, "Multiple loads should replace data")
        XCTAssertEqual(secondMeta?.id, "movie_2", "Second load should have correct ID")
    }

    // MARK: - Metadata Validation Tests

    func testMetadataHasRequiredFields() async {
        await viewModel.loadDetails(id: "movie_1", type: "movie").value

        guard let meta = viewModel.uiState.meta else {
            XCTFail("Meta should be loaded")
            return
        }

        XCTAssertFalse(meta.id.isEmpty, "Meta should have ID")
        XCTAssertFalse(meta.name.isEmpty, "Meta should have name")
        XCTAssertNotNil(meta.description, "Meta should have description")
        XCTAssertNotNil(meta.genres, "Meta should have genres")
        XCTAssertNotNil(meta.rating, "Meta should have rating")
        XCTAssertNotNil(meta.year, "Meta should have year")
    }

    func testMetadataGenresPopulated() async {
        await viewModel.loadDetails(id: "movie_1", type: "movie").value

        guard let meta = viewModel.uiState.meta else {
            XCTFail("Meta should be loaded")
            return
        }

        XCTAssertNotNil(meta.genres, "Meta should have genres")
        if let genres = meta.genres {
            XCTAssertGreaterThan(genres.count, 0, "Should have at least one genre")
            XCTAssertLessThanOrEqual(genres.count, 4, "Should have at most 4 genres (as per mock)")
        }
    }

    func testMetadataRatingInValidRange() async {
        await viewModel.loadDetails(id: "movie_1", type: "movie").value

        guard let meta = viewModel.uiState.meta else {
            XCTFail("Meta should be loaded")
            return
        }

        if let rating = meta.rating {
            XCTAssertGreaterThanOrEqual(rating, 0.0, "Rating should be >= 0")
            XCTAssertLessThanOrEqual(rating, 10.0, "Rating should be <= 10")
        }
    }

    // MARK: - Stream Validation Tests

    func testStreamsHaveValidData() async {
        let streams = expectation(description: "streams loaded")
        var didFulfillStreams = false
        viewModel.$uiState.sink { state in
            if !state.streams.isEmpty && !didFulfillStreams {
                didFulfillStreams = true
                streams.fulfill()
            }
        }.store(in: &cancellables)
        await viewModel.loadDetails(id: "movie_1", type: "movie").value
        await fulfillment(of: [streams], timeout: 5)

        XCTAssertFalse(viewModel.uiState.streams.isEmpty, "Should have streams")

        for stream in viewModel.uiState.streams {
            XCTAssertNotNil(stream.url, "Stream should have URL")
            XCTAssertNotNil(stream.name, "Stream should have name")
        }
    }

    // MARK: - Live TV & Series Type Tests

    func testLiveContentTypeRecognition() {
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("channel"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("channels"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("live"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("livetv"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("live-tv"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("live_tv"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("iptv"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("radio"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("sports"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("sport"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("stream"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("streams"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("event"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("events"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("broadcast"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("feed"))
        XCTAssertFalse(CinemetaCatalogRepository.isLiveContentType("tv"))
        XCTAssertFalse(CinemetaCatalogRepository.isLiveContentType("movie"))
        XCTAssertFalse(CinemetaCatalogRepository.isLiveContentType("series"))
    }

    func testSeriesTypeRecognition() {
        let metaSeries = NuvioMeta(id: "1", name: "S1", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "series", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaShow = NuvioMeta(id: "2", name: "S2", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "show", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaTv = NuvioMeta(id: "3", name: "S3", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "tv", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaTvShow = NuvioMeta(id: "4", name: "S4", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "tvshow", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaShows = NuvioMeta(id: "5", name: "S5", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "shows", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaAnime = NuvioMeta(id: "6", name: "S6", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "anime", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaTvSeries = NuvioMeta(id: "7", name: "S7", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "tv_series", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaMiniseries = NuvioMeta(id: "8", name: "S8", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "miniseries", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaMovie = NuvioMeta(id: "9", name: "M1", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "movie", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)

        XCTAssertTrue(metaSeries.isSeries)
        XCTAssertTrue(metaShow.isSeries)
        XCTAssertTrue(metaTv.isSeries)
        XCTAssertTrue(metaTvShow.isSeries)
        XCTAssertTrue(metaShows.isSeries)
        XCTAssertTrue(metaAnime.isSeries)
        XCTAssertTrue(metaTvSeries.isSeries)
        XCTAssertTrue(metaMiniseries.isSeries)
        XCTAssertFalse(metaMovie.isSeries)
    }

    func testWithVideosUpdatesTypeToSeries() {
        let movieMeta = NuvioMeta(id: "m1", name: "M1", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "movie", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        XCTAssertFalse(movieMeta.isSeries)

        let episode = NuvioVideo(id: "m1:1:1", title: "Pilot", season: 1, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil)
        let updated = movieMeta.withVideos([episode])
        XCTAssertTrue(updated.isSeries)
        XCTAssertEqual(updated.type, "series")
    }

    func testVideoBearingMovieIsRecognizedAsSeries() {
        let meta = NuvioMeta(
            id: "movie-with-episode",
            name: "Movie",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: nil,
            tmdbId: nil,
            type: "movie",
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil,
            videos: [NuvioVideo(id: "movie-with-episode:1:1", title: "Episode", season: 1, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil)],
            trailerYtIds: nil,
            externalRatings: nil
        )

        XCTAssertTrue(meta.isSeries)
    }

    func testLiveTVFallbackTitleFormatting() {
        XCTAssertEqual(CinemetaCatalogRepository.fallbackTitle(forId: "usatv_espn_hd"), "ESPN HD")
        XCTAssertEqual(CinemetaCatalogRepository.fallbackTitle(forId: "iptv:cnn"), "CNN")
        XCTAssertEqual(CinemetaCatalogRepository.fallbackTitle(forId: "channel_hbo_east"), "HBO East")
    }

    func testEpisodeMergingAndSorting() {
        let existing = [
            NuvioVideo(id: "tt:4:1", title: "S4E1", season: 4, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil),
            NuvioVideo(id: "tt:5:1", title: "S5E1", season: 5, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil)
        ]
        let tmdb = [
            NuvioVideo(id: "tt:1:1", title: "S1E1", season: 1, episode: 1, thumbnail: "thumb1", overview: "Overview 1", released: nil, rating: nil),
            NuvioVideo(id: "tt:2:1", title: "S2E1", season: 2, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil),
            NuvioVideo(id: "tt:3:1", title: "S3E1", season: 3, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil),
            NuvioVideo(id: "tt:4:1", title: "S4E1 TMDB Title", season: 4, episode: 1, thumbnail: "thumb4", overview: "Overview 4", released: nil, rating: nil)
        ]

        let merged = DetailsViewModel.mergeEpisodes(existing: existing, fromTmdb: tmdb, parentId: "tt")
        XCTAssertNotNil(merged)
        XCTAssertEqual(merged?.count, 5)
        XCTAssertEqual(merged?.map(\.season), [1, 2, 3, 4, 5])
        XCTAssertEqual(merged?.first(where: { $0.season == 4 })?.title, "S4E1 TMDB Title")
    }

    func testCatalogPreviewsDoNotCountAsFullCachedMetadata() {
        let repo = CinemetaCatalogRepository()
        let testId = "tt_test_series_preview"

        // Cache a full meta
        let fullMeta = NuvioMeta(
            id: testId,
            name: "Test Series",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: testId,
            tmdbId: nil,
            type: "series",
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil,
            videos: [NuvioVideo(id: "\(testId):1:1", title: "Pilot", season: 1, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil)],
            trailerYtIds: nil,
            externalRatings: nil
        )

        repo.cacheMetadata(fullMeta, requestedID: testId)
        XCTAssertTrue(repo.isCachedFullMetadata(id: testId))
    }
}
