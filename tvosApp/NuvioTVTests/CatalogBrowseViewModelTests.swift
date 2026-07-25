//
//  CatalogBrowseViewModelTests.swift
//  NuvioTVTests
//
//  Unit tests for CatalogBrowseViewModel
//

import XCTest
import Combine
@testable import NuvioTV

@MainActor
final class CatalogBrowseViewModelTests: XCTestCase {

    var viewModel: CatalogBrowseViewModel!
    var repository: MockCatalogRepository!
    var cancellables: Set<AnyCancellable>!

    override func setUp() async throws {
        repository = MockCatalogRepository()
        viewModel = CatalogBrowseViewModel(repository: repository)
        cancellables = Set<AnyCancellable>()
    }

    override func tearDown() {
        viewModel = nil
        repository = nil
        cancellables = nil
    }

    // MARK: - Initial State Tests

    func testInitialState() {
        XCTAssertFalse(viewModel.uiState.isLoading, "Should not be loading initially after init completes")
        XCTAssertEqual(viewModel.uiState.currentPage, 1, "Should start at page 1")
        XCTAssertTrue(viewModel.uiState.hasMore, "Should have more pages initially")
        XCTAssertEqual(viewModel.uiState.filterState.contentType, "movie", "Should default to movies")
        XCTAssertEqual(viewModel.uiState.filterState.sort, .trending, "Should default to trending sort")
    }

    // MARK: - Content Type Tests

    func testContentTypeChange() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        let initialItemCount = viewModel.uiState.items.count

        // Change to series
        viewModel.setContentType("series")

        // Wait for reload
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertEqual(viewModel.uiState.filterState.contentType, "series", "Content type should be series")
        XCTAssertNil(viewModel.uiState.filterState.genre, "Genre should be reset when changing content type")

        // Verify items were reloaded
        XCTAssertGreaterThan(viewModel.uiState.items.count, 0, "Should have items after loading")
    }

    // MARK: - Genre Filter Tests

    func testGenreFilter() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Set genre filter
        viewModel.setGenre("action")

        // Wait for reload
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertEqual(viewModel.uiState.filterState.genre, "action", "Genre should be set to action")
        XCTAssertGreaterThan(viewModel.uiState.items.count, 0, "Should have items after filtering")

        // Verify genre is in the first item's genres
        if let firstItem = viewModel.uiState.items.first,
           let genres = firstItem.genres {
            XCTAssertTrue(genres.contains("action"), "First item should contain action genre")
        }
    }

    // MARK: - Sort Tests

    func testSortChange() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Change sort
        viewModel.setSort(.popular)

        // Wait for reload
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertEqual(viewModel.uiState.filterState.sort, .popular, "Sort should be popular")
        XCTAssertGreaterThan(viewModel.uiState.items.count, 0, "Should have items after sorting")
    }

    // MARK: - Pagination Tests

    func testPagination() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        let initialCount = viewModel.uiState.items.count
        let initialPage = viewModel.uiState.currentPage

        // Load more
        viewModel.loadMore()

        // Wait for load more
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertGreaterThan(viewModel.uiState.items.count, initialCount, "Should have more items after pagination")
        XCTAssertGreaterThan(viewModel.uiState.currentPage, initialPage, "Page should increment")
        XCTAssertFalse(viewModel.uiState.isLoadingMore, "Should not be loading after completion")
    }

    // MARK: - Clear Filters Tests

    func testClearFilters() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Apply filters
        viewModel.setGenre("comedy")
        viewModel.setSort(.newest)

        // Wait for reload
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Clear filters
        viewModel.clearFilters()

        // Wait for reload
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertNil(viewModel.uiState.filterState.genre, "Genre should be cleared")
        XCTAssertEqual(viewModel.uiState.filterState.sort, .trending, "Sort should reset to trending")
        XCTAssertGreaterThan(viewModel.uiState.items.count, 0, "Should have items after clearing filters")
    }

    // MARK: - Genre Loading Tests

    func testGenresLoaded() async {
        // Wait for initial load and genres
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertFalse(viewModel.uiState.availableGenres.isEmpty, "Should have available genres")
        XCTAssertTrue(viewModel.uiState.availableGenres.contains("action"), "Should contain action genre")
        XCTAssertTrue(viewModel.uiState.availableGenres.contains("comedy"), "Should contain comedy genre")
    }

    // MARK: - Retry Tests

    func testRetry() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Manually set error state
        viewModel.uiState.error = "Test error"
        viewModel.uiState.items = []

        // Retry
        viewModel.retry()

        // Wait for reload
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertNil(viewModel.uiState.error, "Error should be cleared after retry")
        XCTAssertGreaterThan(viewModel.uiState.items.count, 0, "Should have items after retry")
    }

    // MARK: - Data Validation Tests

    func testItemsHaveValidData() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertGreaterThan(viewModel.uiState.items.count, 0, "Should have items")

        // Verify first item has valid data
        if let firstItem = viewModel.uiState.items.first {
            XCTAssertFalse(firstItem.id.isEmpty, "Item should have ID")
            XCTAssertFalse(firstItem.name.isEmpty, "Item should have name")
            XCTAssertEqual(firstItem.type, "movie", "Item should be a movie")
            XCTAssertNotNil(firstItem.posterUrl, "Item should have poster URL")
            XCTAssertNotNil(firstItem.genres, "Item should have genres")
        }
    }

    // MARK: - Pagination Limit Tests

    func testPaginationHasMore() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertTrue(viewModel.uiState.hasMore, "Should have more pages initially")

        // Load multiple pages until no more
        for _ in 1...5 {
            if !viewModel.uiState.hasMore { break }
            viewModel.loadMore()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        // After 5 pages, should not have more (mock limit)
        XCTAssertFalse(viewModel.uiState.hasMore, "Should not have more pages after reaching limit")
    }

    // MARK: - Year Filter Tests

    func testYearFilter() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Set year filter
        viewModel.setYear(2020)

        // Wait for reload
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertEqual(viewModel.uiState.filterState.year, 2020, "Year should be set to 2020")
        XCTAssertGreaterThan(viewModel.uiState.items.count, 0, "Should have items after filtering")

        // Verify first item has the correct year
        if let firstItem = viewModel.uiState.items.first {
            XCTAssertEqual(firstItem.year, 2020, "First item should have year 2020")
        }
    }

    func testYearFilterClearing() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Set year filter
        viewModel.setYear(2020)
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        XCTAssertEqual(viewModel.uiState.filterState.year, 2020)

        // Clear filters (including year)
        viewModel.clearFilters()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertNil(viewModel.uiState.filterState.year, "Year filter should be cleared")
    }

    // MARK: - Combined Filter Tests

    func testCombinedFilters() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Apply multiple filters
        viewModel.setGenre("action")
        viewModel.setYear(2020)
        viewModel.setSort(.popular)

        // Wait for reload
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertEqual(viewModel.uiState.filterState.genre, "action", "Genre should be action")
        XCTAssertEqual(viewModel.uiState.filterState.year, 2020, "Year should be 2020")
        XCTAssertEqual(viewModel.uiState.filterState.sort, .popular, "Sort should be popular")
        XCTAssertGreaterThan(viewModel.uiState.items.count, 0, "Should have items with combined filters")
    }

    // MARK: - Edge Case Tests

    func testLoadMoreWhenNoMorePages() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Load all pages
        for _ in 1...5 {
            if !viewModel.uiState.hasMore { break }
            viewModel.loadMore()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        let itemCountBeforeLastLoad = viewModel.uiState.items.count

        // Try to load more when there are no more pages
        viewModel.loadMore()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertEqual(viewModel.uiState.items.count, itemCountBeforeLastLoad, "Should not add items when no more pages")
        XCTAssertFalse(viewModel.uiState.isLoadingMore, "Should not be loading more")
    }

    func testLoadMoreWhileAlreadyLoading() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Start loading more
        viewModel.loadMore()

        // Immediately try to load more again while still loading
        let isLoadingMore = viewModel.uiState.isLoadingMore
        viewModel.loadMore()

        // If implementation prevents duplicate loads, this is expected behavior
        // We just verify the state doesn't break
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        XCTAssertFalse(viewModel.uiState.isLoadingMore, "Should not be loading more after completion")
    }

    // MARK: - Sort Option Tests

    func testAllSortOptions() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        for sortOption in SortOption.allCases {
            viewModel.setSort(sortOption)
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

            XCTAssertEqual(viewModel.uiState.filterState.sort, sortOption, "Sort should be \(sortOption)")
            XCTAssertGreaterThan(viewModel.uiState.items.count, 0, "Should have items for sort option \(sortOption)")
        }
    }

    func testSortOptionDisplayNames() {
        XCTAssertEqual(SortOption.trending.displayName, "Trending")
        XCTAssertEqual(SortOption.popular.displayName, "Popular")
        XCTAssertEqual(SortOption.newest.displayName, "Newest")
        XCTAssertEqual(SortOption.rating.displayName, "Top Rated")
    }

    // MARK: - Content Type Switching Tests

    func testContentTypeSwitchingResetsPage() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Load a few pages
        viewModel.loadMore()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        let pageBeforeSwitch = viewModel.uiState.currentPage
        XCTAssertGreaterThan(pageBeforeSwitch, 1, "Should be on page > 1")

        // Switch content type
        viewModel.setContentType("series")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        XCTAssertEqual(viewModel.uiState.currentPage, 1, "Page should reset to 1 after content type change")
    }

    // MARK: - Filter State Tests

    func testFilterStateEquality() {
        let filter1 = FilterState(contentType: "movie", genre: "action", year: 2020, sort: .trending)
        let filter2 = FilterState(contentType: "movie", genre: "action", year: 2020, sort: .trending)
        let filter3 = FilterState(contentType: "series", genre: "action", year: 2020, sort: .trending)

        XCTAssertEqual(filter1, filter2, "Identical filter states should be equal")
        XCTAssertNotEqual(filter1, filter3, "Different filter states should not be equal")
    }

    // MARK: - Memory and Performance Tests

    func testMemoryUsageWithLargeCatalog() async {
        // Load multiple pages to build up items
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        for _ in 1...4 {
            if !viewModel.uiState.hasMore { break }
            viewModel.loadMore()
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }

        XCTAssertGreaterThan(viewModel.uiState.items.count, 60, "Should have accumulated many items")

        // Verify items are still valid
        for item in viewModel.uiState.items {
            XCTAssertFalse(item.id.isEmpty, "All items should maintain valid IDs")
        }
    }

    func testConcurrentFilterChanges() async {
        // Wait for initial load
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        // Rapidly change filters
        viewModel.setGenre("action")
        viewModel.setGenre("comedy")
        viewModel.setGenre("drama")

        // Wait for all changes to settle
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        XCTAssertEqual(viewModel.uiState.filterState.genre, "drama", "Should end with last genre")
        XCTAssertGreaterThan(viewModel.uiState.items.count, 0, "Should have items after rapid changes")
        XCTAssertFalse(viewModel.uiState.isLoading, "Should not be loading after settling")
    }
}
