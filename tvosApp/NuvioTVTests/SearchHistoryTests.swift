import XCTest
@testable import NuvioTV

final class SearchHistoryTests: XCTestCase {
    func testSanitizeDiscardsShortAndEmptyQueries() {
        let input = ["", " ", "S", "a", "  b  "]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertTrue(output.isEmpty)
    }

    func testSanitizePrunesSubstringsAndPrefixes() {
        let input = ["Silo", "Sil", "Si", "S"]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertEqual(output, ["Silo"])
    }

    func testSanitizeDeduplicatesCaseInsensitively() {
        let input = ["Silo", "silo", "SILO"]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertEqual(output, ["Silo"])
    }

    func testSanitizePreservesDistinctQueries() {
        let input = ["Star Wars", "Star Trek", "Dune"]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertEqual(output, ["Star Wars", "Star Trek", "Dune"])
    }

    func testSanitizeRespectsMaxCount() {
        let input = (1...12).map { "Movie \($0)" }
        let output = SearchHistoryStore.sanitize(input, maxCount: 8)
        XCTAssertEqual(output.count, 8)
        XCTAssertEqual(output.first, "Movie 1")
        XCTAssertEqual(output.last, "Movie 8")
    }

    func testCommitReplacesIntermediateTypingPrefixes() {
        var current: [String] = []
        var session: String? = nil

        // User types 'S' (ignored because < 2)
        (current, session) = SearchHistoryStore.commit("S", current: current, sessionQuery: session)
        XCTAssertEqual(current, [])
        XCTAssertNil(session)

        // User types 'Si'
        (current, session) = SearchHistoryStore.commit("Si", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Si"])
        XCTAssertEqual(session, "Si")

        // User types 'Sil'
        (current, session) = SearchHistoryStore.commit("Sil", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Sil"])
        XCTAssertEqual(session, "Sil")

        // User types 'Silo'
        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo"])
        XCTAssertEqual(session, "Silo")
    }

    func testCommitHandlesBackspacingInSameSession() {
        var current: [String] = []
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo"])

        // User backspaces to "Sil" in same session
        (current, session) = SearchHistoryStore.commit("Sil", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Sil"])
        XCTAssertEqual(session, "Sil")

        // User changes to "Sila"
        (current, session) = SearchHistoryStore.commit("Sila", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Sila"])
        XCTAssertEqual(session, "Sila")
    }

    func testCommitPreservesUnrelatedQueries() {
        var current = ["Dune", "Inception"]
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo", "Dune", "Inception"])
    }

    func testCommitMovesExistingQueryToFront() {
        var current = ["Dune", "Silo", "Batman"]
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo", "Dune", "Batman"])
    }

    func testCommitPrunesSubstringOfMultiWordQuery() {
        var current: [String] = []
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("The", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["The"])

        (current, session) = SearchHistoryStore.commit("The Bat", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["The Bat"])

        (current, session) = SearchHistoryStore.commit("The Batman", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["The Batman"])
    }

    func testCommitPreservesDistinctPrefixShares() {
        var current = ["Star Wars"]
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Star Trek", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Star Trek", "Star Wars"])
    }
}

// MARK: - Search and Discover Request Lifecycle Tests

private final class ControllableLifecycleRepository: MockCatalogRepository {
    var searchHandler: ((String) async throws -> [NuvioMeta])?
    var browseDiscoverHandler: ((DiscoverCatalogOption, Int, String?) async throws -> CatalogPage)?

    override func search(query: String) async throws -> [NuvioMeta] {
        if let searchHandler {
            return try await searchHandler(query)
        }
        return [
            NuvioMeta(
                id: "meta_\(query)",
                name: "Result for \(query)",
                posterUrl: nil,
                backgroundUrl: nil,
                logoUrl: nil,
                imdbId: nil,
                tmdbId: nil,
                type: "movie",
                year: 2024
            )
        ]
    }

    override func getDiscoverSources() async -> [DiscoverCatalogOption] {
        [
            DiscoverCatalogOption(
                key: "movie:top",
                addonId: "mock.addon",
                addonName: "Mock Addon",
                manifestURL: URL(string: "https://example.com/manifest.json")!,
                type: "movie",
                catalogId: "top",
                catalogName: "Popular Movies",
                genreOptions: ["action", "drama"],
                genreRequired: false,
                supportsPagination: true
            ),
            DiscoverCatalogOption(
                key: "series:top",
                addonId: "mock.addon",
                addonName: "Mock Addon",
                manifestURL: URL(string: "https://example.com/manifest.json")!,
                type: "series",
                catalogId: "top",
                catalogName: "Popular Series",
                genreOptions: ["drama", "comedy"],
                genreRequired: false,
                supportsPagination: true
            )
        ]
    }

    override func browseDiscover(
        option: DiscoverCatalogOption,
        page: Int,
        genre: String?
    ) async throws -> CatalogPage {
        if let browseDiscoverHandler {
            return try await browseDiscoverHandler(option, page, genre)
        }
        let items = (1...5).map { i in
            NuvioMeta(
                id: "\(option.type)_\(page)_\(i)",
                name: "Item \(option.type) \(page) \(i)",
                posterUrl: nil,
                backgroundUrl: nil,
                logoUrl: nil,
                imdbId: nil,
                tmdbId: nil,
                type: option.type,
                year: 2024
            )
        }
        return CatalogPage(items: items, hasMore: page < 3, page: page)
    }
}

@MainActor
private protocol SearchLifecycleModel: AnyObject {
    var searchText: String { get set }
    var results: [NuvioMeta] { get }
    var isLoading: Bool { get }
}

extension SearchViewModel: SearchLifecycleModel {}
extension NetflixSearchViewModel: SearchLifecycleModel {}

private actor SearchRequestCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }
}

final class SearchAndDiscoverLifecycleTests: XCTestCase {
    @MainActor
    func testSearchRapidQueryChangePreservesFinalDebouncedQuery() async throws {
        let repo = ControllableLifecycleRepository()
        try await assertRapidQueryChangeRecovers(
            SearchViewModel(repository: repo), repository: repo
        )
    }

    @MainActor
    func testNetflixSearchRapidQueryChangePreservesFinalDebouncedQuery() async throws {
        let repo = ControllableLifecycleRepository()
        try await assertRapidQueryChangeRecovers(
            NetflixSearchViewModel(repository: repo), repository: repo
        )
    }

    @MainActor
    private func assertRapidQueryChangeRecovers(
        _ viewModel: any SearchLifecycleModel,
        repository: ControllableLifecycleRepository
    ) async throws {
        let firstStarted = expectation(description: "first debounced request started")
        let secondStarted = expectation(description: "replacement request started")
        let releaseFirst = expectation(description: "release cancelled first request")
        let firstReturned = expectation(description: "first request returned despite cancellation")
        let counter = SearchRequestCounter()
        repository.searchHandler = { query in
            let requestNumber = await counter.next()
            XCTAssertEqual(query, "Matrix")
            if requestNumber == 1 {
                firstStarted.fulfill()
                // Ignore cancellation like a provider that finishes an already-issued request.
                await self.fulfillment(of: [releaseFirst], timeout: 5)
                firstReturned.fulfill()
            } else if requestNumber == 2 {
                secondStarted.fulfill()
            } else {
                XCTFail("Unexpected extra search request")
            }
            return [NuvioMeta(id: "request_\(requestNumber)", name: "Result for Matrix", type: "movie")]
        }
        defer { viewModel.searchText = "" }

        // The first query must already have passed debounce and still be in flight.
        viewModel.searchText = "Matrix"
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertTrue(viewModel.isLoading)
        viewModel.searchText = "Matrix Reloaded"
        viewModel.searchText = "Matrix"

        await fulfillment(of: [secondStarted], timeout: 2)
        releaseFirst.fulfill()
        await fulfillment(of: [firstReturned], timeout: 1)

        let deadline = Date().addingTimeInterval(1)
        while viewModel.isLoading && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.results.map(\.id), ["request_2"])
    }

    @MainActor
    func testDelayedSearchCannotOverwriteCachedResults() async throws {
        let repo = ControllableLifecycleRepository()
        let viewModel = SearchViewModel(repository: repo)

        // Fast search completes and is cached
        viewModel.performSearch(query: "Fast")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(viewModel.results.first?.name, "Result for Fast")

        // Slow search starts
        let slowSearchStarted = expectation(description: "slow search started")
        let slowSearchCanFinish = expectation(description: "slow search can finish")
        repo.searchHandler = { query in
            if query == "Slow" {
                slowSearchStarted.fulfill()
                await self.fulfillment(of: [slowSearchCanFinish], timeout: 5.0)
                return [
                    NuvioMeta(
                        id: "slow_1",
                        name: "Result for Slow",
                        posterUrl: nil,
                        backgroundUrl: nil,
                        logoUrl: nil,
                        imdbId: nil,
                        tmdbId: nil,
                        type: "movie",
                        year: 2024
                    )
                ]
            }
            return [
                NuvioMeta(
                    id: "meta_\(query)",
                    name: "Result for \(query)",
                    posterUrl: nil,
                    backgroundUrl: nil,
                    logoUrl: nil,
                    imdbId: nil,
                    tmdbId: nil,
                    type: "movie",
                    year: 2024
                )
            ]
        }

        viewModel.performSearch(query: "Slow")
        await fulfillment(of: [slowSearchStarted], timeout: 2.0)
        XCTAssertTrue(viewModel.isLoading)

        // While slow is in-flight, user switches back to "Fast" (which is cached)
        viewModel.performSearch(query: "Fast")
        XCTAssertEqual(viewModel.results.first?.name, "Result for Fast")
        XCTAssertFalse(viewModel.isLoading)

        // Allow slow search to finally finish
        slowSearchCanFinish.fulfill()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Stale slow search must NOT overwrite the cached fast search
        XCTAssertEqual(viewModel.results.first?.name, "Result for Fast")
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testDiscoverReloadCancelsInFlightPaginationAndGuardsState() async throws {
        let repo = ControllableLifecycleRepository()
        let paginationStarted = expectation(description: "pagination started")
        let paginationCanFinish = expectation(description: "pagination can finish")

        repo.browseDiscoverHandler = { option, page, genre in
            if page == 2 && option.type == "movie" {
                paginationStarted.fulfill()
                await self.fulfillment(of: [paginationCanFinish], timeout: 5.0)
                return CatalogPage(
                    items: [
                        NuvioMeta(
                            id: "stale_page2_movie",
                            name: "Stale Page 2 Movie",
                            posterUrl: nil,
                            backgroundUrl: nil,
                            logoUrl: nil,
                            imdbId: nil,
                            tmdbId: nil,
                            type: "movie",
                            year: 2024
                        )
                    ],
                    hasMore: false,
                    page: 2
                )
            }
            let items = (1...5).map { i in
                NuvioMeta(
                    id: "\(option.type)_\(page)_\(i)",
                    name: "\(option.type) \(page) \(i)",
                    posterUrl: nil,
                    backgroundUrl: nil,
                    logoUrl: nil,
                    imdbId: nil,
                    tmdbId: nil,
                    type: option.type,
                    year: 2024
                )
            }
            return CatalogPage(items: items, hasMore: true, page: page)
        }

        let viewModel = DiscoverViewModel(repository: repo)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.items.count, 5)

        // Trigger pagination (loading page 2)
        viewModel.loadMoreIfNeeded(currentItem: viewModel.items.last!)
        await fulfillment(of: [paginationStarted], timeout: 2.0)
        XCTAssertTrue(viewModel.isLoadingMore)

        // User switches type to series, which triggers reload()
        viewModel.setType("series")
        try await Task.sleep(nanoseconds: 100_000_000)

        // Now let the stale page 2 from "movie" finish
        paginationCanFinish.fulfill()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify: items contains series items only, NOT contaminated by stale movie page 2
        XCTAssertTrue(viewModel.items.allSatisfy { $0.type == "series" })
        XCTAssertFalse(viewModel.items.contains(where: { $0.id == "stale_page2_movie" }))
        XCTAssertFalse(viewModel.isLoadingMore)
        XCTAssertTrue(viewModel.hasMore)
    }
}

// MARK: - Collection Folder Pagination Tests

final class CollectionFolderPaginationTests: XCTestCase {
    func testPagination40TitlesSinglePage() {
        let source = NuvioCollectionSource(provider: "addon", addonId: "cinemeta", type: "movie", catalogId: "top")
        let items = (0..<40).map { NuvioMeta(id: "item_\($0)", name: "Item \($0)", type: "movie") }
        let page = CatalogPage(items: items, hasMore: false, page: 1)

        let initial = CollectionFolderBrowseView.calculatePagination(page: page, source: source, requestedCursor: 0, pageSize: 40)
        XCTAssertEqual(initial.displayItems.count, 40)
        XCTAssertEqual(initial.nextCursor, 40)
        XCTAssertFalse(initial.hasMore)
    }

    func testPagination60TitlesExposesEveryItemWithoutSkipsOrLoops() {
        let source = NuvioCollectionSource(provider: "addon", addonId: "cinemeta", type: "movie", catalogId: "top")
        let allItems = (0..<60).map { NuvioMeta(id: "item_\($0)", name: "Item \($0)", type: "movie") }

        // Initial load returns 60 items with hasMore = false (e.g. all in one batch from source)
        let page1 = CatalogPage(items: allItems, hasMore: false, page: 1)
        let p1 = CollectionFolderBrowseView.calculatePagination(page: page1, source: source, requestedCursor: 0, pageSize: 40)
        XCTAssertEqual(p1.displayItems.count, 40)
        XCTAssertEqual(p1.displayItems.map(\.id), (0..<40).map { "item_\($0)" })
        XCTAssertEqual(p1.nextCursor, 40)
        XCTAssertTrue(p1.hasMore, "Should have more because 60 exceeds pageSize 40")

        // Next load requests cursor 40, receives remaining items 40..<60 (20 items)
        let page2Items = Array(allItems.dropFirst(40))
        let page2 = CatalogPage(items: page2Items, hasMore: false, page: 2)
        let p2 = CollectionFolderBrowseView.calculatePagination(page: page2, source: source, requestedCursor: 40, pageSize: 40)
        XCTAssertEqual(p2.displayItems.count, 20)
        XCTAssertEqual(p2.displayItems.map(\.id), (40..<60).map { "item_\($0)" })
        XCTAssertEqual(p2.nextCursor, 60)
        XCTAssertFalse(p2.hasMore, "Should have no more because 20 does not exceed 40 and page.hasMore is false")

        let combined = p1.displayItems + p2.displayItems
        XCTAssertEqual(combined.count, 60)
        XCTAssertEqual(combined.map(\.id), allItems.map(\.id))
    }

    func testPagination100TitlesExposesEveryItemWithoutSkipsOrLoops() {
        let source = NuvioCollectionSource(provider: "addon", addonId: "cinemeta", type: "movie", catalogId: "top")
        let allItems = (0..<100).map { NuvioMeta(id: "item_\($0)", name: "Item \($0)", type: "movie") }

        // Load 1: cursor 0
        let page1 = CatalogPage(items: allItems, hasMore: false, page: 1)
        let p1 = CollectionFolderBrowseView.calculatePagination(page: page1, source: source, requestedCursor: 0, pageSize: 40)
        XCTAssertEqual(p1.displayItems.count, 40)
        XCTAssertEqual(p1.nextCursor, 40)
        XCTAssertTrue(p1.hasMore)

        // Load 2: cursor 40 (source returns items 40..<100 = 60 items)
        let page2 = CatalogPage(items: Array(allItems.dropFirst(40)), hasMore: false, page: 2)
        let p2 = CollectionFolderBrowseView.calculatePagination(page: page2, source: source, requestedCursor: 40, pageSize: 40)
        XCTAssertEqual(p2.displayItems.count, 40)
        XCTAssertEqual(p2.nextCursor, 80)
        XCTAssertTrue(p2.hasMore)

        // Load 3: cursor 80 (source returns items 80..<100 = 20 items)
        let page3 = CatalogPage(items: Array(allItems.dropFirst(80)), hasMore: false, page: 3)
        let p3 = CollectionFolderBrowseView.calculatePagination(page: page3, source: source, requestedCursor: 80, pageSize: 40)
        XCTAssertEqual(p3.displayItems.count, 20)
        XCTAssertEqual(p3.nextCursor, 100)
        XCTAssertFalse(p3.hasMore)

        let combined = p1.displayItems + p2.displayItems + p3.displayItems
        XCTAssertEqual(combined.count, 100)
        XCTAssertEqual(combined.map(\.id), allItems.map(\.id))
    }

    func testPagination140TitlesExposesEveryItemWithoutSkipsOrLoops() {
        let source = NuvioCollectionSource(provider: "addon", addonId: "cinemeta", type: "movie", catalogId: "top")
        let allItems = (0..<140).map { NuvioMeta(id: "item_\($0)", name: "Item \($0)", type: "movie") }

        // Load 1: cursor 0 -> returns items 0..<100 (hasMore = true)
        let p1 = CollectionFolderBrowseView.calculatePagination(
            page: CatalogPage(items: Array(allItems.prefix(100)), hasMore: true, page: 1),
            source: source,
            requestedCursor: 0,
            pageSize: 40
        )
        XCTAssertEqual(p1.displayItems.count, 40)
        XCTAssertEqual(p1.nextCursor, 40)
        XCTAssertTrue(p1.hasMore)

        // Load 2: cursor 40 -> returns items 40..<140 (100 items, hasMore = true)
        let p2 = CollectionFolderBrowseView.calculatePagination(
            page: CatalogPage(items: Array(allItems.dropFirst(40).prefix(100)), hasMore: true, page: 2),
            source: source,
            requestedCursor: 40,
            pageSize: 40
        )
        XCTAssertEqual(p2.displayItems.count, 40)
        XCTAssertEqual(p2.nextCursor, 80)
        XCTAssertTrue(p2.hasMore)

        // Load 3: cursor 80 -> returns items 80..<140 (60 items, hasMore = false)
        let p3 = CollectionFolderBrowseView.calculatePagination(
            page: CatalogPage(items: Array(allItems.dropFirst(80)), hasMore: false, page: 3),
            source: source,
            requestedCursor: 80,
            pageSize: 40
        )
        XCTAssertEqual(p3.displayItems.count, 40)
        XCTAssertEqual(p3.nextCursor, 120)
        XCTAssertTrue(p3.hasMore)

        // Load 4: cursor 120 -> returns items 120..<140 (20 items, hasMore = false)
        let p4 = CollectionFolderBrowseView.calculatePagination(
            page: CatalogPage(items: Array(allItems.dropFirst(120)), hasMore: false, page: 4),
            source: source,
            requestedCursor: 120,
            pageSize: 40
        )
        XCTAssertEqual(p4.displayItems.count, 20)
        XCTAssertEqual(p4.nextCursor, 140)
        XCTAssertFalse(p4.hasMore)

        let combined = p1.displayItems + p2.displayItems + p3.displayItems + p4.displayItems
        XCTAssertEqual(combined.count, 140)
        XCTAssertEqual(combined.map(\.id), allItems.map(\.id))
    }

    func testPaginationPreservesHasMoreIndependentOfDisplayDeduplication() {
        let source = NuvioCollectionSource(provider: "addon", addonId: "cinemeta", type: "movie", catalogId: "top")
        let items = (0..<40).map { NuvioMeta(id: "dup_\($0)", name: "Dup \($0)", type: "movie") }
        let page = CatalogPage(items: items, hasMore: true, page: 1)
        let result = CollectionFolderBrowseView.calculatePagination(page: page, source: source, requestedCursor: 0, pageSize: 40)
        XCTAssertEqual(result.displayItems.count, 40)
        XCTAssertEqual(result.nextCursor, 40)
        XCTAssertTrue(result.hasMore)
    }
}

// MARK: - Cloud Library Lifecycle Tests

final class CloudLibraryLifecycleTests: XCTestCase {
    @MainActor
    func testCloudLibraryCancelsResolvingOnDepartureAndRejectsStaleCallback() async throws {
        let testStore = UserDefaults(suiteName: "CloudLibraryTests.\(UUID().uuidString)")!
        let viewModel = CloudLibraryViewModel(store: testStore)

        let item = CloudItem(
            providerId: "torbox",
            id: "item1",
            type: .torrent,
            name: "Test Item",
            status: "completed",
            sizeBytes: 1024,
            files: [
                CloudFile(id: "f1", name: "File 1", sizeBytes: 1024, mimeType: "video/mp4", playable: true, playbackUrl: nil)
            ]
        )
        let file = item.files[0]

        var resolvedCalled = false
        viewModel.play(item: item, file: file) { _, _ in
            resolvedCalled = true
        }

        // Cancel immediately simulating screen departure
        viewModel.cancelResolving()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(resolvedCalled, "Callback should be rejected on cancellation")
        XCTAssertNil(viewModel.resolvingKey)
        XCTAssertNil(viewModel.playbackErrorMessage)
    }

    @MainActor
    func testCloudLibraryPlaybackErrorSetsPlaybackErrorMessageRegardlessOfItemsEmpty() async throws {
        let testStore = UserDefaults(suiteName: "CloudLibraryTests.\(UUID().uuidString)")!
        let viewModel = CloudLibraryViewModel(store: testStore)

        let item = CloudItem(
            providerId: "torbox",
            id: "item1",
            type: .torrent,
            name: "Test Item",
            status: "completed",
            sizeBytes: 1024,
            files: [
                CloudFile(id: "f1", name: "File 1", sizeBytes: 1024, mimeType: "video/mp4", playable: true, playbackUrl: nil)
            ]
        )
        let file = item.files[0]

        // When items are empty and playback fails
        viewModel.play(item: item, file: file) { _, _ in }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNotNil(viewModel.playbackErrorMessage, "Playback error should be set for empty items")
        viewModel.clearPlaybackError()
        XCTAssertNil(viewModel.playbackErrorMessage)

        // When items are not empty and playback fails
        // Playback error message must STILL be set so native alert is triggered!
        viewModel.play(item: item, file: file) { _, _ in }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNotNil(viewModel.playbackErrorMessage, "Playback error must be set regardless of items.isEmpty")
    }

    @MainActor
    func testCloudLibraryPreservesOpenItemAndFocusedKey() {
        let testStore = UserDefaults(suiteName: "CloudLibraryTests.\(UUID().uuidString)")!
        let viewModel = CloudLibraryViewModel(store: testStore)

        let item = CloudItem(
            providerId: "torbox",
            id: "item1",
            type: .torrent,
            name: "Test Folder",
            status: "completed",
            sizeBytes: 2048,
            files: [
                CloudFile(id: "f1", name: "Ep 1", sizeBytes: 1024, mimeType: "video/mp4", playable: true, playbackUrl: nil),
                CloudFile(id: "f2", name: "Ep 2", sizeBytes: 1024, mimeType: "video/mp4", playable: true, playbackUrl: nil)
            ]
        )

        viewModel.openItem = item
        viewModel.focusedKey = "torbox:torrent:item1:f2"

        XCTAssertEqual(viewModel.openItem?.id, "item1")
        XCTAssertEqual(viewModel.focusedKey, "torbox:torrent:item1:f2")
    }

    @MainActor
    func testCloudPlaybackPreservesSingleFileItemFocus() {
        let testStore = UserDefaults(suiteName: "CloudLibraryTests.\(UUID().uuidString)")!
        let viewModel = CloudLibraryViewModel(store: testStore)
        let file = CloudFile(id: "f1", name: "Movie", sizeBytes: nil, mimeType: "video/mp4", playable: true, playbackUrl: nil)
        let item = CloudItem(providerId: "torbox", id: "single", type: .torrent, name: "Movie", status: nil, sizeBytes: nil, files: [file])

        // The top-level list focuses the item, not a file row inside a folder.
        viewModel.focusedKey = item.stableKey
        viewModel.play(item: item, file: file) { _, _ in }
        defer { viewModel.cancelResolving() }

        XCTAssertEqual(viewModel.resolvingKey, "\(item.stableKey):\(file.id)")
        XCTAssertEqual(viewModel.focusedKey, item.stableKey)
    }

    @MainActor
    func testCloudPlaybackPreservesFolderFileFocus() {
        let testStore = UserDefaults(suiteName: "CloudLibraryTests.\(UUID().uuidString)")!
        let viewModel = CloudLibraryViewModel(store: testStore)
        let files = ["f1", "f2"].map {
            CloudFile(id: $0, name: $0, sizeBytes: nil, mimeType: "video/mp4", playable: true, playbackUrl: nil)
        }
        let item = CloudItem(providerId: "torbox", id: "folder", type: .torrent, name: "Season", status: nil, sizeBytes: nil, files: files)
        let focusedFileKey = "\(item.stableKey):\(files[1].id)"
        viewModel.openItem = item
        viewModel.focusedKey = focusedFileKey

        viewModel.play(item: item, file: files[1]) { _, _ in }
        defer { viewModel.cancelResolving() }

        XCTAssertEqual(viewModel.openItem, item)
        XCTAssertEqual(viewModel.focusedKey, focusedFileKey)
    }

    func testTVScreenIsPlayerProperty() {
        let playerScreen = TVScreen.player(
            url: URL(string: "https://example.com/video.mp4")!,
            meta: NuvioMeta(id: "test", name: "Test", type: "movie"),
            subtitle: "",
            httpHeaders: [:],
            externalSubtitles: [],
            resumeFrom: nil
        )
        XCTAssertTrue(playerScreen.isPlayer)
        XCTAssertFalse(TVScreen.cloudLibrary.isPlayer)
        XCTAssertFalse(TVScreen.main.isPlayer)
    }
}
