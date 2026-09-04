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
