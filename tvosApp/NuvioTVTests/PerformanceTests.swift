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
            let viewModel = DetailsViewModel(repository: repository, streamDiscoveryMode: .repository)
            XCTAssertNotNil(viewModel)
        }
    }

    func testDetailsLoadingPerformance() {
        let viewModel = DetailsViewModel(repository: repository, streamDiscoveryMode: .repository)

        measure {
            let expectation = XCTestExpectation(description: "Load details")

            Task { @MainActor in
                viewModel.loadDetails(id: "movie_1", type: "movie")
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
        let viewModel = DetailsViewModel(repository: repository, streamDiscoveryMode: .repository)

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

    // MARK: - Watchdog Memory Diagnostic Tests

    func testTVMemoryDiagnosticCaptureAndReport() {
        let snapshot = TVMemoryDiagnostic.capture()
        XCTAssertGreaterThan(snapshot.totalPhysicalRAMMB, 0, "Total physical RAM should be non-zero")
        XCTAssertGreaterThan(snapshot.availableMemoryMB, 0, "Available memory should be non-zero")
        XCTAssertGreaterThanOrEqual(snapshot.physicalFootprintMB, 0, "Physical footprint should be non-negative")

        let detailed = TVMemoryDiagnostic.detailedReport(snapshot: snapshot, label: "TEST_WATCHDOG_RAM")
        XCTAssertTrue(detailed.contains("TEST_WATCHDOG_RAM"))
        XCTAssertTrue(detailed.contains("Total Physical Footprint"))
        XCTAssertTrue(detailed.contains("Mach VM"))
        XCTAssertTrue(detailed.contains("Network URLCache"))
        XCTAssertTrue(detailed.contains("Poster Image Cache"))
        XCTAssertTrue(detailed.contains("Backdrop Image Cache"))
        XCTAssertTrue(detailed.contains("Tracked App In-Memory Caches"))

        let pulse = TVMemoryDiagnostic.summaryPulse(snapshot: snapshot)
        XCTAssertTrue(pulse.contains("Footprint:"))
        XCTAssertTrue(pulse.contains("Avail:"))
        XCTAssertTrue(pulse.contains("URLCache:"))
    }

    func testNSCacheMemoryTracker() {
        let tracker = NSCacheMemoryTracker(maxCost: 10 * 1024 * 1024)
        let cache = NSCache<NSString, UIImage>()
        cache.delegate = tracker
        cache.countLimit = 2

        let m1 = tracker.metrics()
        XCTAssertEqual(m1.count, 0)
        XCTAssertEqual(m1.totalBytes, 0)
        XCTAssertEqual(m1.maxCost, 10 * 1024 * 1024)

        tracker.recordInsertion(cost: 1024)
        let m2 = tracker.metrics()
        XCTAssertEqual(m2.count, 1)
        XCTAssertEqual(m2.totalBytes, 1024)

        tracker.reset()
        let m3 = tracker.metrics()
        XCTAssertEqual(m3.count, 0)
        XCTAssertEqual(m3.totalBytes, 0)
    }

    func testSimpleCountTracker() {
        let tracker = SimpleCountTracker()
        XCTAssertEqual(tracker.count, 0)

        tracker.increment(bytes: 500)
        XCTAssertEqual(tracker.count, 1)
        XCTAssertEqual(tracker.metrics.totalBytes, 500)

        tracker.decrement(bytes: 200)
        XCTAssertEqual(tracker.count, 0)
        XCTAssertEqual(tracker.metrics.totalBytes, 300)

        tracker.set(count: 10, bytes: 4096)
        XCTAssertEqual(tracker.count, 10)
        XCTAssertEqual(tracker.metrics.totalBytes, 4096)

        tracker.reset()
        XCTAssertEqual(tracker.count, 0)
        XCTAssertEqual(tracker.metrics.totalBytes, 0)
    }

    func testAnimatedGIFCacheGCDAndFrameExpansion() {
        XCTAssertEqual(AnimatedGIFCache.greatestCommonDivisor(10, 20), 10)
        XCTAssertEqual(AnimatedGIFCache.greatestCommonDivisor(15, 25), 5)
        XCTAssertEqual(AnimatedGIFCache.greatestCommonDivisor(7, 13), 1)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
        let img1 = renderer.image { ctx in ctx.cgContext.setFillColor(UIColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        let img2 = renderer.image { ctx in ctx.cgContext.setFillColor(UIColor.blue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }

        let frames = [
            (image: img1, delayCentiseconds: 10),
            (image: img2, delayCentiseconds: 20)
        ]

        let expanded = AnimatedGIFCache.expandFrames(frames: frames)
        XCTAssertNotNil(expanded)
        XCTAssertEqual(expanded?.images.count, 3) // 1 img1 + 2 img2
        XCTAssertEqual(expanded?.duration, 0.30, accuracy: 0.001)

        let metrics = AnimatedGIFCache.telemetryMetrics()
        XCTAssertGreaterThanOrEqual(metrics.maxCost, 0)
    }
}
