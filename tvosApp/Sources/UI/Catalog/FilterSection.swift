//
//  FilterSection.swift
//  NuvioTV
//
//  Filter section for catalog browsing
//

import SwiftUI

/// Filter section with content type, sort, and genre filters
struct FilterSection: View {
    let filterState: FilterState
    let availableGenres: [String]
    let onContentTypeChange: (String) -> Void
    let onGenreChange: (String?) -> Void
    let onSortChange: (SortOption) -> Void
    let onClearFilters: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Content Type Toggle
            HStack(spacing: 8) {
                Text("Type:")
                    .font(.headline)
                    .foregroundColor(.primary)

                FilterChip(
                    text: "Movies",
                    selected: filterState.contentType == "movie",
                    onClick: { onContentTypeChange("movie") }
                )

                FilterChip(
                    text: "Series",
                    selected: filterState.contentType == "series",
                    onClick: { onContentTypeChange("series") }
                )
            }

            // Sort Options
            HStack(spacing: 8) {
                Text("Sort:")
                    .font(.headline)
                    .foregroundColor(.primary)

                ForEach(SortOption.allCases, id: \.self) { sortOption in
                    FilterChip(
                        text: sortOption.displayName,
                        selected: filterState.sort == sortOption,
                        onClick: { onSortChange(sortOption) }
                    )
                }
            }

            // Genre Filter (horizontally scrollable)
            if !availableGenres.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Genre:")
                        .font(.headline)
                        .foregroundColor(.primary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            // All genres option
                            FilterChip(
                                text: "All",
                                selected: filterState.genre == nil,
                                onClick: { onGenreChange(nil) }
                            )

                            ForEach(availableGenres, id: \.self) { genre in
                                FilterChip(
                                    text: genre.capitalized,
                                    selected: filterState.genre == genre,
                                    onClick: { onGenreChange(genre) }
                                )
                            }
                        }
                        .padding(.trailing, 40)
                    }
                }
            }

            // Clear filters button (only show if filters are applied)
            if shouldShowClearButton {
                Button(action: onClearFilters) {
                    Text("Clear Filters")
                        .font(.subheadline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.gray.opacity(0.3))
                        .clipShape(Capsule())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    // MARK: - Computed Properties

    private var shouldShowClearButton: Bool {
        filterState.genre != nil ||
        filterState.year != nil ||
        filterState.sort != .trending
    }
}

// MARK: - Preview

#if DEBUG
struct FilterSection_Previews: PreviewProvider {
    static var previews: some View {
        FilterSection(
            filterState: FilterState(contentType: "movie", genre: "action", year: nil, sort: .trending),
            availableGenres: ["action", "comedy", "drama", "horror", "sci-fi"],
            onContentTypeChange: { _ in },
            onGenreChange: { _ in },
            onSortChange: { _ in },
            onClearFilters: { }
        )
        .previewLayout(.sizeThatFits)
        .padding()
        .background(Color.black)
    }
}
#endif
