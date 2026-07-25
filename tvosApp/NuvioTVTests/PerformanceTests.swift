//
//  PerformanceTests.swift
//  NuvioTVTests
//
//  Performance and memory profiling tests
//

import XCTest
import Combine
@testable import NuvioTV

@MainActor
final class PerformanceTests: XCTestCase {

    var repository: MockCatalogRepository!
    var cancellables: Set<AnyCancellable>!

    override func setUp() {
        repository = MockCatalogRepository()
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        repository = nil
        cancellables = nil
    }

    // MARK: - ViewModel Initialization Performance


    func testDetailsViewModelInitializationPerformance() {
        measure {
            let viewModel = DetailsViewModel(repository: repository)
            XCTAssertNotNil(viewModel)
        }
    }

    func testCatalogBrowseViewModelInitializationPerformance() {
        measure {
            let viewModel = CatalogBrowseViewModel(repository: repository)
            XCTAssertNotNil(viewModel)
        }
    }

    // MARK: - Data Loading Performance


    func testDetailsLoadingPerformance() {
        let viewModel = DetailsViewModel(repository: repository)

        measure {
            let expectation = XCTestExpectation(description: "Load details")

            Task { @MainActor in
                viewModel.loadDetails(id: "movie_1")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testCatalogLoadingPerformance() {
        let viewModel = CatalogBrowseViewModel(repository: repository)

        measure {
            let expectation = XCTestExpectation(description: "Load catalog")

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    // MARK: - Repository Performance

    func testGetHomeCatalogsPerformance() {
        measure {
            let expectation = XCTestExpectation(description: "Get home catalogs")

            Task {
                _ = try? await repository.getHomeCatalogs()
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testGetMetadataPerformance() {
        measure {
            let expectation = XCTestExpectation(description: "Get metadata")

            Task {
                _ = try? await repository.getMetadata(id: "movie_1")
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testGetStreamsPerformance() {
        measure {
            let expectation = XCTestExpectation(description: "Get streams")

            Task {
                _ = try? await repository.getStreams(id: "movie_1", type: "movie")
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testBrowseCatalogPerformance() {
        measure {
            let expectation = XCTestExpectation(description: "Browse catalog")

            Task {
                _ = try? await repository.browseCatalog(
                    contentType: "movie",
                    catalogId: "trending",
                    page: 1,
                    genre: nil,
                    year: nil,
                    sort: nil
                )
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testSearchPerformance() {
        measure {
            let expectation = XCTestExpectation(description: "Search")

            Task {
                _ = try? await repository.search(query: "test")
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    // MARK: - Pagination Performance

    func testPaginationLoadMorePerformance() {
        let viewModel = CatalogBrowseViewModel(repository: repository)

        measure {
            let expectation = XCTestExpectation(description: "Load more")

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                viewModel.loadMore()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testMultiplePageLoadsPerformance() {
        let viewModel = CatalogBrowseViewModel(repository: repository)

        measure {
            let expectation = XCTestExpectation(description: "Multiple page loads")

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                for _ in 1...3 {
                    viewModel.loadMore()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }

                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 10.0)
        }
    }

    // MARK: - Filter Performance

    func testGenreFilterChangePerformance() {
        let viewModel = CatalogBrowseViewModel(repository: repository)

        measure {
            let expectation = XCTestExpectation(description: "Genre filter change")

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                viewModel.setGenre("action")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testSortChangePerformance() {
        let viewModel = CatalogBrowseViewModel(repository: repository)

        measure {
            let expectation = XCTestExpectation(description: "Sort change")

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                viewModel.setSort(.popular)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testContentTypeChangePerformance() {
        let viewModel = CatalogBrowseViewModel(repository: repository)

        measure {
            let expectation = XCTestExpectation(description: "Content type change")

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                viewModel.setContentType("series")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    // MARK: - Memory Performance


    func testCatalogBrowseMemoryWithManyPages() async {
        let viewModel = CatalogBrowseViewModel(repository: repository)

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Load multiple pages
        for _ in 1...5 {
            if viewModel.uiState.hasMore {
                viewModel.loadMore()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        // Should accumulate many items
        XCTAssertGreaterThan(viewModel.uiState.items.count, 50)

        // Memory should be reasonable (no leaks)
        // In production, you'd measure actual memory usage
    }

    // MARK: - Concurrent Operation Performance

    func testConcurrentMetadataFetchesPerformance() {
        measure {
            let expectation = XCTestExpectation(description: "Concurrent fetches")

            Task {
                async let meta1 = repository.getMetadata(id: "movie_1")
                async let meta2 = repository.getMetadata(id: "movie_2")
                async let meta3 = repository.getMetadata(id: "movie_3")
                async let meta4 = repository.getMetadata(id: "movie_4")
                async let meta5 = repository.getMetadata(id: "movie_5")

                _ = try? await [meta1, meta2, meta3, meta4, meta5]
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    func testConcurrentCatalogBrowsesPerformance() {
        measure {
            let expectation = XCTestExpectation(description: "Concurrent browses")

            Task {
                async let page1 = repository.browseCatalog(
                    contentType: "movie",
                    catalogId: "trending",
                    page: 1,
                    genre: nil,
                    year: nil,
                    sort: nil
                )
                async let page2 = repository.browseCatalog(
                    contentType: "series",
                    catalogId: "trending",
                    page: 1,
                    genre: nil,
                    year: nil,
                    sort: nil
                )
                async let page3 = repository.browseCatalog(
                    contentType: "movie",
                    catalogId: "popular",
                    page: 1,
                    genre: nil,
                    year: nil,
                    sort: nil
                )

                _ = try? await [page1, page2, page3]
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    // MARK: - State Update Performance

    func testRapidStateUpdatesPerformance() {
        let viewModel = CatalogBrowseViewModel(repository: repository)

        measure {
            let expectation = XCTestExpectation(description: "Rapid state updates")

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                // Rapid filter changes
                for i in 1...10 {
                    if i % 2 == 0 {
                        viewModel.setGenre("action")
                    } else {
                        viewModel.setGenre("comedy")
                    }
                }

                try? await Task.sleep(nanoseconds: 2_000_000_000)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 5.0)
        }
    }

    // MARK: - Combine Publisher Performance


    // MARK: - Large Dataset Performance

    func testLargeDatasetHandlingPerformance() {
        measure {
            let expectation = XCTestExpectation(description: "Large dataset")

            Task {
                // Fetch multiple pages of data
                var allItems: [Meta] = []

                for page in 1...5 {
                    let catalogPage = try? await repository.browseCatalog(
                        contentType: "movie",
                        catalogId: "trending",
                        page: page,
                        genre: nil,
                        year: nil,
                        sort: nil
                    )

                    if let items = catalogPage?.items {
                        allItems.append(contentsOf: items)
                    }
                }

                XCTAssertGreaterThan(allItems.count, 50)
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 10.0)
        }
    }

    // MARK: - Watchlist Toggle Performance

    func testWatchlistTogglePerformance() {
        let viewModel = DetailsViewModel(repository: repository)

        measure {
            for _ in 1...100 {
                viewModel.toggleWatchlist()
            }
        }
    }


    // MARK: - Model Serialization Performance

    func testMetaModelEncodingPerformance() throws {
        let meta = Meta(
            id: "test_1",
            name: "Test Movie",
            description: "Test description",
            posterUrl: "https://example.com/poster.jpg",
            backgroundUrl: "https://example.com/bg.jpg",
            logoUrl: nil,
            imdbId: "tt1234567",
            tmdbId: 123456,
            type: "movie",
            year: 2024,
            genres: ["action", "drama"],
            rating: 8.5,
            releaseInfo: nil,
            runtime: "120 min",
            cast: ["Actor 1", "Actor 2"],
            director: ["Director"],
            writer: ["Writer"],
            certification: "PG-13",
            country: "USA",
            released: nil
        )

        let encoder = JSONEncoder()

        measure {
            _ = try? encoder.encode(meta)
        }
    }

    func testMetaModelDecodingPerformance() throws {
        let json = """
        {
            "id": "test_1",
            "name": "Test Movie",
            "description": "Test description",
            "posterUrl": "https://example.com/poster.jpg",
            "backgroundUrl": "https://example.com/bg.jpg",
            "type": "movie",
            "year": 2024,
            "genres": ["action", "drama"],
            "rating": 8.5,
            "runtime": "120 min",
            "cast": ["Actor 1", "Actor 2"],
            "director": ["Director"],
            "writer": ["Writer"],
            "certification": "PG-13",
            "country": "USA"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()

        measure {
            _ = try? decoder.decode(Meta.self, from: json)
        }
    }
}
