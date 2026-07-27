import SwiftUI

private enum DiscoverGridMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28
}

/// Embeddable Discover section — a filterable poster grid (type / sort / genre)
/// backed by Cinemeta. Hosted inside the Search tab below the search bar.
/// The host provides the outer title, padding and background.
struct DiscoverSection: View {
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    @StateObject private var viewModel = DiscoverViewModel()
    @FocusState private var focusedCardID: String?
    /// Last card focused in the grid, kept so returning from details (which
    /// steals focus and nils `focusedCardID`) restores that card instead of
    /// snapping back to the top of the grid.
    @State private var lastFocusedCardID: String?
    @State private var shouldRestoreFocus = false
    /// Card to actively re-focus once the Details overlay dismisses; captured
    /// when the tab view gets disabled (overlay up), consumed on re-enable.
    @State private var overlayRestoreCardID: String?
    @State private var overlayRestoreGeneration = 0
    @Environment(\.isEnabled) private var isEnabled
    @Binding private var parentTransitionActive: Bool
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false

    init(
        onContentClick: @escaping (String, String) -> Void,
        onLongPress: ((NuvioMeta) -> Void)? = nil,
        parentTransitionActive: Binding<Bool>
    ) {
        self.onContentClick = onContentClick
        self.onLongPress = onLongPress
        _parentTransitionActive = parentTransitionActive
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            filterBar
                .disabled(overlayRestoreCardID != nil)
                .zIndex(1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .zIndex(0)
        }
        .onChange(of: focusedCardID) { newValue in
            if let newValue {
                lastFocusedCardID = newValue
                shouldRestoreFocus = false
                // Restoration complete -- lift the focus restriction.
                if isEnabled, newValue == overlayRestoreCardID {
                    overlayRestoreCardID = nil
                    parentTransitionActive = false
                }
            } else if lastFocusedCardID != nil {
                shouldRestoreFocus = true
            }
        }
        // Overlay dismissal re-places focus geometrically without consulting
        // `defaultFocus`. While `overlayRestoreCardID` is set every other card
        // is unfocusable, so the engine can only land back on the saved card
        // -- no scroll-to-top flash. See TVHomeView for the full story.
        .onChange(of: isEnabled) { enabled in
            if !enabled {
                overlayRestoreGeneration &+= 1
                overlayRestoreCardID = focusedCardID ?? lastFocusedCardID
            } else if let target = overlayRestoreCardID {
                restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
            }
        }
    }

    private func restoreOverlayFocus(to target: String, generation: Int) {
        for delay in [0.12, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if overlayRestoreGeneration == generation, overlayRestoreCardID == target {
                    focusedCardID = target
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if overlayRestoreGeneration == generation, overlayRestoreCardID == target {
                overlayRestoreCardID = nil
                parentTransitionActive = false
            }
        }
    }

    // MARK: - Filters (dropdown menus)

    private var filterBar: some View {
        HStack(spacing: 16) {
            FilterMenu(label: viewModel.type.title) {
                ForEach(DiscoverType.allCases) { type in
                    Button { viewModel.setType(type) } label: {
                        menuItem(type.title, selected: viewModel.type == type)
                    }
                }
            }

            FilterMenu(label: viewModel.sort.title) {
                ForEach(DiscoverSort.allCases) { sort in
                    Button { viewModel.setSort(sort) } label: {
                        menuItem(sort.title, selected: viewModel.sort == sort)
                    }
                }
            }

            FilterMenu(label: viewModel.genre ?? L10n.string("tvos_discover_all_genres", fallback: "All Genres")) {
                Button { viewModel.setGenre(nil) } label: {
                    menuItem(
                        L10n.string("tvos_discover_all_genres", fallback: "All Genres"),
                        selected: viewModel.genre == nil
                    )
                }
                ForEach(viewModel.genres, id: \.self) { genre in
                    Button { viewModel.setGenre(genre) } label: {
                        menuItem(genre, selected: viewModel.genre == genre)
                    }
                }
            }
        }
    }

    private func menuItem(_ title: String, selected: Bool) -> some View {
        Text(selected ? "✓  \(title)" : title)
    }

    // MARK: - Content

    private var visibleItems: [NuvioMeta] {
        guard hideUnreleased else { return viewModel.items }
        return viewModel.items.filter { !ContentReleasePolicy.isUnreleased($0) }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            centered { ProgressView().scaleEffect(1.6).tint(.white) }
        } else if let error = viewModel.error, visibleItems.isEmpty {
            centered {
                message(icon: "wifi.exclamationmark", title: error)
            }
        } else if visibleItems.isEmpty {
            centered {
                message(
                    icon: "rectangle.on.rectangle.slash",
                    title: L10n.string("tvos_discover_empty_title", fallback: "Nothing here"),
                    subtitle: L10n.string(
                        "tvos_discover_empty_subtitle",
                        fallback: "Try a different genre or category."
                    )
                )
            }
        } else {
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: DiscoverGridMetrics.posterGap) {
                ForEach(visibleItems) { item in
                    DiscoverCard(
                        meta: item,
                        externalFocus: $focusedCardID,
                        retainFocusAppearance: overlayRestoreCardID == item.id,
                        onLongPress: onLongPress.map { cb in { cb(item) } }
                    ) {
                        parentTransitionActive = true
                        overlayRestoreCardID = item.id
                        lastFocusedCardID = item.id
                        onContentClick(item.id, item.type)
                    }
                    .disabled(overlayRestoreCardID != nil && overlayRestoreCardID != item.id)
                    .onAppear { viewModel.loadMoreIfNeeded(currentItem: item) }
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 12)

            if viewModel.isLoadingMore {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 28)
            }

            Color.clear.frame(height: 60)
        }
        // This is a vertical grid beneath fixed controls. Its focused cards
        // must remain inside the viewport instead of spilling upward over the
        // Movies / Popular / All Genres menus.
        .scrollClipDisabled(false)
        .focusSection()
        .defaultFocusIfAvailable($focusedCardID, shouldRestoreFocus ? lastFocusedCardID : nil)
    }

    private var columns: [GridItem] {
        [GridItem(
            .adaptive(minimum: DiscoverGridMetrics.posterWidth, maximum: DiscoverGridMetrics.posterWidth),
            spacing: DiscoverGridMetrics.posterGap,
            alignment: .top
        )]
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 40)
            content()
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private func message(icon: String, title: String, subtitle: String? = nil) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .light))
                .foregroundColor(.white.opacity(0.4))
            Text(title)
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 700)
    }
}

// MARK: - Filter dropdown

/// A glass chip that opens a dropdown menu of options. Falls back to a static
/// chip on tvOS < 17 (where `Menu` is unavailable). Shared by Discover & Library.
struct FilterMenu<MenuContent: View>: View {
    let label: String
    @ViewBuilder var menu: () -> MenuContent
    @State private var showOptions = false
    @FocusState private var focused: Bool

    var body: some View {
        Button { showOptions = true } label: { chipLabel }
            .buttonStyle(PosterCardButtonStyle())
            .focused($focused)
            .focusEffectDisabledIfAvailable()
            .scaleEffect(focused ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.14), value: focused)
            .confirmationDialog(label, isPresented: $showOptions, titleVisibility: .visible, actions: menu)
    }

    private var chipLabel: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 24, weight: .semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .semibold))
        }
        .foregroundColor(.white.opacity(focused ? 1.0 : 0.9))
        .padding(.horizontal, 28)
        .frame(height: 60)
        .modifier(GlassChipBackground(filled: false))
        .overlay(
            Capsule()
                .strokeBorder(focused ? AppFocusOutline.color : .clear, lineWidth: focused ? AppFocusOutline.width : 0)
        )
    }
}

// MARK: - Card

private struct DiscoverCard: View {
    let meta: NuvioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
    var retainFocusAppearance = false
    var onLongPress: (() -> Void)? = nil
    let action: () -> Void
    @FocusState private var focused: Bool
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottom) {
                    AsyncImage(url: URL(string: meta.posterUrl ?? "")) { phase in
                        if case .success(let image) = phase {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                Rectangle().fill(Color.white.opacity(0.07))
                                Image(systemName: meta.type == "series" ? "tv" : "film")
                                    .font(.system(size: 40))
                                    .foregroundColor(.white.opacity(0.25))
                            }
                        }
                    }
                    .frame(width: DiscoverGridMetrics.posterWidth, height: DiscoverGridMetrics.posterHeight)

                    if metaLine != nil {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.85)],
                            startPoint: .center,
                            endPoint: .bottom
                        )
                        .frame(height: 120)
                        .frame(maxWidth: .infinity, alignment: .bottom)

                        if let metaLine {
                            Text(metaLine)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(.white.opacity(0.95))
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(width: DiscoverGridMetrics.posterWidth, height: DiscoverGridMetrics.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    WatchedCheckmarkBadge(meta: meta)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(showsFocusedAppearance ? focusBorderColor : .clear, lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width)
                )
                .shadow(color: .black.opacity(showsFocusedAppearance ? 0.5 : 0.2), radius: showsFocusedAppearance ? 16 : 6)

                if posterLabels {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meta.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(showsFocusedAppearance ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        if let year = meta.year {
                            Text(String(year))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    .frame(width: DiscoverGridMetrics.posterWidth, alignment: .leading)
                }
            }
            .scaleEffect(showsFocusedAppearance ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: meta.id))
        .focusEffectDisabledIfAvailable()
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in onLongPress?() }
        )
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: showsFocusedAppearance)
    }

    /// "Genre · ★ Rating" overlay, omitting whichever piece is missing.
    private var metaLine: String? {
        var parts: [String] = []
        if let genre = meta.genres?.first, !genre.isEmpty { parts.append(genre) }
        if let rating = meta.rating, rating > 0 { parts.append(String(format: "★ %.1f", rating)) }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private var focusBorderColor: Color {
        AppFocusOutline.color
    }

    private var showsFocusedAppearance: Bool {
        focused || retainFocusAppearance
    }
}
