import SwiftUI

/// Discover for the Classic search screen: the grid shown while the query is
/// empty. Popular titles, nothing to configure -- a placeholder with pictures,
/// not a browse tool. Uses the same `PosterGridCard` as the results grid so
/// both halves of the screen read as one. Data comes from the shared
/// `DiscoverViewModel`; the Netflix-style screen keeps its own `DiscoverSection`.
struct SearchDiscoverGrid: View {
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    @StateObject private var viewModel = DiscoverViewModel()
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false

    private let posterWidth: CGFloat = 210
    private let posterHeight: CGFloat = 315
    private let posterGap: CGFloat = 28

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .center, spacing: posterGap) {
                ForEach(visibleItems) { item in
                    PosterGridCard(
                        meta: item,
                        width: posterWidth,
                        height: posterHeight,
                        onLongPress: onLongPress.map { cb in { cb(item) } },
                        forceShowLabels: true
                    ) {
                        onContentClick(item.id, item.type)
                    }
                    .onAppear { viewModel.loadMoreIfNeeded(currentItem: item) }
                }
            }
            // Room for a focused card's scale-up and border at the scroll view's
            // edges; same insets as the results grid.
            .padding(.top, 16)
            .padding(.horizontal, 12)
        }
        .focusSection()
        .overlay { placeholder }
        .onAppear {
            if viewModel.items.isEmpty, !viewModel.isLoading { viewModel.reload() }
        }
    }

    // MARK: - Grid

    private var columns: [GridItem] {
        // No maximum: columns absorb the leftover width evenly and the card sits
        // centred in each, instead of the remainder piling up on the trailing edge.
        [GridItem(.adaptive(minimum: posterWidth), spacing: posterGap, alignment: .top)]
    }

    private var visibleItems: [NuvioMeta] {
        guard hideUnreleased else { return viewModel.items }
        return viewModel.items.filter { !ContentReleasePolicy.isUnreleased($0) }
    }

    /// Loading / error / empty states, shown over the (empty) grid.
    @ViewBuilder
    private var placeholder: some View {
        if visibleItems.isEmpty {
            if viewModel.isLoading {
                ProgressView().scaleEffect(1.6).tint(.white)
            } else if let error = viewModel.error {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.7))
            } else {
                Text(L10n.string("tvos_discover_empty_title", fallback: "Nothing here"))
                    .font(.system(size: 26))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
}
