//
//  CatalogBrowseView.swift
//  NuvioTV
//
//  Main catalog browsing screen with adaptive grid layout
//

import SwiftUI

/// Catalog browse screen with adaptive grid layout and infinite scroll
struct CatalogBrowseView: View {
    @StateObject private var viewModel: CatalogBrowseViewModel
    let onContentClick: (String) -> Void

    init(repository: CatalogRepository, onContentClick: @escaping (String) -> Void) {
        _viewModel = StateObject(wrappedValue: CatalogBrowseViewModel(repository: repository))
        self.onContentClick = onContentClick
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Title
                Text("Browse \(viewModel.uiState.filterState.contentType == "movie" ? "Movies" : "Series")")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .padding(.horizontal, horizontalPadding)

                // Filter Section
                FilterSection(
                    filterState: viewModel.uiState.filterState,
                    availableGenres: viewModel.uiState.availableGenres,
                    onContentTypeChange: viewModel.setContentType,
                    onGenreChange: viewModel.setGenre,
                    onSortChange: viewModel.setSort,
                    onClearFilters: viewModel.clearFilters
                )
                .padding(.horizontal, horizontalPadding)

                // Content Grid
                contentView
            }
            .padding(.vertical, 24)
        }
        .background(Color.black.edgesIgnoringSafeArea(.all))
    }

    // MARK: - Content Views

    @ViewBuilder
    private var contentView: some View {
        if viewModel.uiState.isLoading {
            loadingView
        } else if let error = viewModel.uiState.error {
            errorView(error)
        } else if viewModel.uiState.items.isEmpty {
            emptyView
        } else {
            gridView
        }
    }

    private var loadingView: some View {
        VStack {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.white)
            Text("Loading...")
                .foregroundColor(.gray)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Text(error)
                .font(.body)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)

            Button("Retry") {
                viewModel.retry()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 400)
        .padding(.horizontal, horizontalPadding)
    }

    private var emptyView: some View {
        Text("No items found")
            .font(.body)
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, minHeight: 400)
    }

    private var gridView: some View {
        LazyVGrid(columns: gridColumns, spacing: 16) {
            ForEach(viewModel.uiState.items) { meta in
                PosterCard(meta: meta) {
                    onContentClick(meta.id)
                }
                .onAppear {
                    checkIfNeedToLoadMore(meta)
                }
            }

            // Loading indicator for pagination
            if viewModel.uiState.isLoadingMore {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
        }
        .padding(.horizontal, horizontalPadding)
    }

    // MARK: - Helper Methods

    /// Check if we need to load more items (infinite scroll)
    private func checkIfNeedToLoadMore(_ meta: NuvioMeta) {
        // Find the index of the current item
        guard let index = viewModel.uiState.items.firstIndex(where: { $0.id == meta.id }) else {
            return
        }

        // Load more when we're close to the end (within last row)
        let threshold = viewModel.uiState.items.count - gridColumnCount
        if index >= threshold && viewModel.uiState.hasMore && !viewModel.uiState.isLoadingMore {
            viewModel.loadMore()
        }
    }

    // MARK: - Computed Properties

    /// Adaptive grid columns based on platform and screen size
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: gridColumnCount)
    }

    /// Number of columns based on platform
    private var gridColumnCount: Int {
        #if os(tvOS)
        return 6 // tvOS: 6 columns
        #else
        // iOS: Adaptive based on device
        if UIDevice.current.userInterfaceIdiom == .pad {
            // iPad: 4-5 columns based on orientation
            return isLandscape ? 5 : 4
        } else {
            // iPhone: 2-3 columns based on orientation
            return isLandscape ? 3 : 2
        }
        #endif
    }

    /// Horizontal padding based on platform
    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        return 60 // More padding for TV
        #else
        return 16
        #endif
    }

    /// Check if device is in landscape orientation (iOS only)
    private var isLandscape: Bool {
        #if os(iOS)
        return UIDevice.current.orientation.isLandscape ||
               (UIScreen.main.bounds.width > UIScreen.main.bounds.height)
        #else
        return false
        #endif
    }
}

// MARK: - Preview

#if DEBUG
struct CatalogBrowseView_Previews: PreviewProvider {
    static var previews: some View {
        CatalogBrowseView(repository: MockCatalogRepository()) { id in
            print("Clicked: \(id)")
        }
    }
}
#endif
