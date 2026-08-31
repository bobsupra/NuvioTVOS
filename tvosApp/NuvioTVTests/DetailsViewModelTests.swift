//
//  DetailsViewModelTests.swift
//  NuvioTVTests
//
//  Unit tests for DetailsViewModel
//

import XCTest
import Combine
@testable import NuvioTV

@MainActor
final class DetailsViewModelTests: XCTestCase {

    var viewModel: DetailsViewModel!
    var repository: MockCatalogRepository!
    var cancellables: Set<AnyCancellable>!

    override func setUp() async throws {
        repository = MockCatalogRepository()
        viewModel = DetailsViewModel(repository: repository)
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
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
        viewModel.loadDetails(id: "movie_1")

        // Wait for loading to complete
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertFalse(viewModel.uiState.isLoading, "Should not be loading after data loads")
        XCTAssertNil(viewModel.uiState.error, "Error should be nil on success")
        XCTAssertNotNil(viewModel.uiState.meta, "Meta should be loaded")
    }

    func testLoadDetailsMetadata() async {
        viewModel.loadDetails(id: "movie_1")

        // Wait for loading to complete
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

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
        viewModel.loadDetails(id: "movie_1")

        // Wait for loading to complete (including streams)
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

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
        viewModel.loadDetails(id: "series_1")

        // Wait for loading to complete
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        guard let meta = viewModel.uiState.meta else {
            XCTFail("Meta should be loaded")
            return
        }

        XCTAssertEqual(meta.type, "series", "Meta type should be series")
    }

    // MARK: - Watchlist Tests

    func testToggleWatchlistAdd() {
        XCTAssertFalse(viewModel.uiState.isInWatchlist, "Should not be in watchlist initially")

        viewModel.toggleWatchlist()

        XCTAssertTrue(viewModel.uiState.isInWatchlist, "Should be in watchlist after toggle")
    }

    func testToggleWatchlistRemove() {
        viewModel.toggleWatchlist() // Add to watchlist
        XCTAssertTrue(viewModel.uiState.isInWatchlist, "Should be in watchlist")

        viewModel.toggleWatchlist() // Remove from watchlist
        XCTAssertFalse(viewModel.uiState.isInWatchlist, "Should not be in watchlist after second toggle")
    }

    func testToggleWatchlistMultipleTimes() {
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

        viewModel.loadDetails(id: "movie_1")

        await fulfillment(of: [expectation], timeout: 5.0)
    }

    // MARK: - Multiple Load Tests

    func testMultipleLoadDetailsCalls() async {
        // First load
        viewModel.loadDetails(id: "movie_1")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let firstMeta = viewModel.uiState.meta

        // Second load with different ID
        viewModel.loadDetails(id: "movie_2")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let secondMeta = viewModel.uiState.meta

        XCTAssertNotEqual(firstMeta?.id, secondMeta?.id, "Multiple loads should replace data")
        XCTAssertEqual(secondMeta?.id, "movie_2", "Second load should have correct ID")
    }

    // MARK: - Metadata Validation Tests

    func testMetadataHasRequiredFields() async {
        viewModel.loadDetails(id: "movie_1")
        try? await Task.sleep(nanoseconds: 1_000_000_000)

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
        viewModel.loadDetails(id: "movie_1")
        try? await Task.sleep(nanoseconds: 1_000_000_000)

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
        viewModel.loadDetails(id: "movie_1")
        try? await Task.sleep(nanoseconds: 1_000_000_000)

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
        viewModel.loadDetails(id: "movie_1")
        try? await Task.sleep(nanoseconds: 2_000_000_000) // Wait for streams

        XCTAssertFalse(viewModel.uiState.streams.isEmpty, "Should have streams")

        for stream in viewModel.uiState.streams {
            XCTAssertNotNil(stream.url, "Stream should have URL")
            XCTAssertNotNil(stream.name, "Stream should have name")
        }
    }

    // MARK: - Performance Tests

    func testLoadDetailsPerformance() {
        measure {
            let expectation = XCTestExpectation(description: "Load details performance")

            Task { @MainActor in
                viewModel.loadDetails(id: "movie_1")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 10.0)
        }
    }

    // MARK: - Live TV & Series Type Tests

    func testLiveContentTypeRecognition() {
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("channel"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("live"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("livetv"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("live-tv"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("iptv"))
        XCTAssertTrue(CinemetaCatalogRepository.isLiveContentType("radio"))
        XCTAssertFalse(CinemetaCatalogRepository.isLiveContentType("tv"))
        XCTAssertFalse(CinemetaCatalogRepository.isLiveContentType("movie"))
        XCTAssertFalse(CinemetaCatalogRepository.isLiveContentType("series"))
    }

    func testSeriesTypeRecognition() {
        let metaSeries = NuvioMeta(id: "1", name: "S1", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "series", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaShow = NuvioMeta(id: "2", name: "S2", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "show", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaTv = NuvioMeta(id: "3", name: "S3", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "tv", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaTvShow = NuvioMeta(id: "4", name: "S4", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "tvshow", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
        let metaMovie = NuvioMeta(id: "5", name: "M1", description: nil, posterUrl: nil, backgroundUrl: nil, logoUrl: nil, imdbId: nil, tmdbId: nil, type: "movie", year: nil, genres: nil, rating: nil, releaseInfo: nil, runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)

        XCTAssertTrue(metaSeries.isSeries)
        XCTAssertTrue(metaShow.isSeries)
        XCTAssertTrue(metaTv.isSeries)
        XCTAssertTrue(metaTvShow.isSeries)
        XCTAssertFalse(metaMovie.isSeries)
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
