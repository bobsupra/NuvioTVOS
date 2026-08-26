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

    func testLiveTVFallbackTitleFormatting() {
        XCTAssertEqual(CinemetaCatalogRepository.fallbackTitle(forId: "usatv_espn_hd"), "ESPN HD")
        XCTAssertEqual(CinemetaCatalogRepository.fallbackTitle(forId: "iptv:cnn"), "CNN")
        XCTAssertEqual(CinemetaCatalogRepository.fallbackTitle(forId: "channel_hbo_east"), "HBO East")
    }

    func testCinemetaCatalogRepositoryLiveTVMetadataResolution() async throws {
        let repo = CinemetaCatalogRepository()
        let meta = try await repo.getMetadata(id: "usatv_espn_hd", type: "channel")
        XCTAssertEqual(meta.id, "usatv_espn_hd")
        XCTAssertEqual(meta.name, "ESPN HD")
        XCTAssertEqual(meta.type, "channel")
        XCTAssertFalse(meta.isSeries)
    }

}

