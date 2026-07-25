//
//  CatalogBrowseViewModel.swift
//  NuvioTV
//
//  ViewModel for catalog browsing with Combine
//

import Foundation
import Combine

/// ViewModel for catalog browse screen
@MainActor
class CatalogBrowseViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var uiState = CatalogBrowseUiState()

    // MARK: - Dependencies

    private let repository: CatalogRepository
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(repository: CatalogRepository) {
        self.repository = repository
        loadGenres()
        loadCatalog()
    }

    // MARK: - Public Methods

    /// Load available genres
    func loadGenres() {
        Task {
            do {
                let genres = try await repository.getGenres(contentType: uiState.filterState.contentType)
                uiState.availableGenres = genres
            } catch {
                // Silently fail for genres, not critical
                print("Failed to load genres: \(error)")
            }
        }
    }

    /// Load catalog (optionally reset to page 1)
    func loadCatalog(resetPage: Bool = true) {
        Task {
            // Update loading state
            uiState.isLoading = resetPage
            uiState.error = nil
            if resetPage {
                uiState.items = []
                uiState.currentPage = 1
            }

            do {
                let page = try await repository.browseCatalog(
                    contentType: uiState.filterState.contentType,
                    catalogId: uiState.filterState.sort.catalogId,
                    page: uiState.currentPage,
                    genre: uiState.filterState.genre,
                    year: uiState.filterState.year,
                    sort: nil
                )

                // Update state with results
                uiState.isLoading = false
                if resetPage {
                    uiState.items = page.items
                } else {
                    uiState.items.append(contentsOf: page.items)
                }
                uiState.hasMore = page.hasMore
                uiState.currentPage = page.page

            } catch {
                uiState.isLoading = false
                uiState.error = error.localizedDescription
            }
        }
    }

    /// Load more items (pagination)
    func loadMore() {
        guard !uiState.isLoadingMore && uiState.hasMore else { return }

        Task {
            uiState.isLoadingMore = true

            do {
                let page = try await repository.browseCatalog(
                    contentType: uiState.filterState.contentType,
                    catalogId: uiState.filterState.sort.catalogId,
                    page: uiState.currentPage + 1,
                    genre: uiState.filterState.genre,
                    year: uiState.filterState.year,
                    sort: nil
                )

                uiState.isLoadingMore = false
                uiState.items.append(contentsOf: page.items)
                uiState.hasMore = page.hasMore
                uiState.currentPage = page.page

            } catch {
                uiState.isLoadingMore = false
                uiState.error = error.localizedDescription
            }
        }
    }

    /// Set content type (movie/series)
    func setContentType(_ contentType: String) {
        guard uiState.filterState.contentType != contentType else { return }

        uiState.filterState.contentType = contentType
        uiState.filterState.genre = nil // Reset genre when changing content type
        loadGenres()
        loadCatalog()
    }

    /// Set genre filter
    func setGenre(_ genre: String?) {
        guard uiState.filterState.genre != genre else { return }

        uiState.filterState.genre = genre
        loadCatalog()
    }

    /// Set year filter
    func setYear(_ year: Int?) {
        guard uiState.filterState.year != year else { return }

        uiState.filterState.year = year
        loadCatalog()
    }

    /// Set sort option
    func setSort(_ sort: SortOption) {
        guard uiState.filterState.sort != sort else { return }

        uiState.filterState.sort = sort
        loadCatalog()
    }

    /// Clear all filters
    func clearFilters() {
        let currentContentType = uiState.filterState.contentType
        uiState.filterState = FilterState(contentType: currentContentType)
        loadCatalog()
    }

    /// Retry loading
    func retry() {
        loadCatalog()
    }
}
