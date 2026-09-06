import SwiftUI

/// Netflix-style alternative to `SearchView`: results split into a text index
/// on the left and a poster grid on the right, mirroring the tvOS Netflix
/// search screen. Wired to the same `CatalogRepository` search use case as
/// `SearchView` via `NetflixSearchViewModel`.
///
/// Text entry uses a real tvOS `TextField` in the search layout. Its native
/// editor stays in the focus hierarchy while the visible text is rendered by
/// the app's glass chrome, preventing tvOS's default white focus platter from
/// covering the design. This preserves the full-size linear alphabet keyboard,
/// suggestions strip, Siri dictation, and native focus transitions.
///
/// Reuses `PosterGridCard`, `GlassChip`, `GlassCapsule`, `GlassChipBackground`,
/// `PosterCardButtonStyle`, `DiscoverSection`, `SearchContentType` and
/// `ContentReleasePolicy` from `SearchView.swift` rather than duplicating them.
private enum NetflixSearchMetrics {
    /// Sits on top of tvOS's own ~80pt overscan safe area, so this only needs
    /// to be big enough that a focused key/card's scale-up doesn't visually
    /// touch the safe-area boundary.
    /// Match Classic Search's outer gutter so every Netflix Search surface,
    /// not only Discover, shares the same centered content column.
    static let pageInset: CGFloat = 36
    static let posterWidth: CGFloat = 190
    static let posterHeight: CGFloat = 285
    static let posterGap: CGFloat = 24
    static let listWidth: CGFloat = 440
    static let columnGap: CGFloat = 32
}

struct NetflixSearchView: View {
    @StateObject private var viewModel: NetflixSearchViewModel
    let showDiscover: Bool
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    /// The query field is the screen's entry point. Its native editor remains
    /// focusable so tvOS owns keyboard presentation and Siri dictation.
    @FocusState private var searchFieldFocused: Bool
    /// One shared focus id-space for both the text list and the poster grid,
    /// namespaced ("list:"/"grid:") so the same result can be focused in
    /// either column without the two bindings fighting over one id.
    @FocusState private var focusedItemID: String?
    @FocusState private var focusedTypeFilterID: String?
    @FocusState private var clearRecentFocused: Bool
    @FocusState private var focusedRecentSearchID: String?
    /// Same overlay-restore dance as `SearchView`: Details is a sibling
    /// overlay (not a navigation push), so returning from it needs to
    /// re-place focus geometrically instead of snapping to the first result.
    @State private var lastFocusedItemID: String?
    @State private var shouldRestoreFocus = false
    @State private var overlayRestoreItemID: String?
    @State private var overlayRestoreGeneration = 0
    @State private var discoverOverlayTransitionActive = false
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false

    init(viewModel: NetflixSearchViewModel, showDiscover: Bool = true, onContentClick: @escaping (String, String) -> Void, onLongPress: ((NuvioMeta) -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.showDiscover = showDiscover
        self.onContentClick = onContentClick
        self.onLongPress = onLongPress
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                queryHeader
                    .disabled(overlayRestoreItemID != nil || discoverOverlayTransitionActive)

                if viewModel.hasQuery {
                    typeFilterRow
                        .disabled(overlayRestoreItemID != nil)
                    resultsBody
                } else {
                    if !viewModel.recentSearches.isEmpty {
                        recentRow
                            .disabled(discoverOverlayTransitionActive)
                    }
                    if showDiscover {
                        DiscoverSection(
                            onContentClick: onContentClick,
                            onLongPress: onLongPress,
                            parentTransitionActive: $discoverOverlayTransitionActive
                        )
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    } else {
                        centeredState {
                            messageState(
                                icon: "rectangle.grid.2x2",
                                title: L10n.string(
                                    "search_start_subtitle_no_discover",
                                    fallback: "Discover is disabled. Enter at least 2 characters"
                                )
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, NetflixSearchMetrics.pageInset)
            .padding(.top, 16)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .onAppear {
            viewModel.reloadRecent()
        }
        .onDisappear {
            searchFieldFocused = false
        }
        .onExitCommand(perform: canHandleExitCommand ? handleExitCommand : nil)
        .onChange(of: focusedItemID) { _, newValue in
            if let newValue {
                lastFocusedItemID = newValue
                shouldRestoreFocus = false
                if isEnabled, newValue == overlayRestoreItemID { overlayRestoreItemID = nil }
            } else if lastFocusedItemID != nil {
                shouldRestoreFocus = true
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                overlayRestoreGeneration &+= 1
                overlayRestoreItemID = focusedItemID ?? lastFocusedItemID
            } else if let target = overlayRestoreItemID {
                restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
            }
        }
    }

    private func restoreOverlayFocus(to target: String, generation: Int) {
        for delay in [0.12, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if overlayRestoreGeneration == generation, overlayRestoreItemID == target {
                    focusedItemID = target
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if overlayRestoreGeneration == generation, overlayRestoreItemID == target {
                overlayRestoreItemID = nil
            }
        }
    }

    // MARK: - Header: query field (system keyboard + dictation)

    /// Keeps the real tvOS editor in the focus hierarchy while rendering the
    /// query with the same glass treatment used by the rest of Search. The
    /// editor is nearly transparent rather than off-screen, so the native
    /// keyboard is attached directly to this search surface.
    private var queryHeader: some View {
        ZStack(alignment: .leading) {
            TextField(
                "",
                text: $viewModel.searchText
            )
            .textFieldStyle(.plain)
            .focused($searchFieldFocused)
            .focusEffectDisabledIfAvailable()
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(maxWidth: .infinity, minHeight: 72)
            // tvOS's native editor paints a white focus platter even when
            // the app supplies its own background. Keep the editor alive and
            // focusable, but let the glass overlay below own the appearance.
            .opacity(0.02)

            HStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                Text(
                    viewModel.searchText.isEmpty
                        ? L10n.string("search_placeholder", fallback: "Search for movies and TV shows")
                        : viewModel.searchText
                )
                .font(.system(size: 30, weight: .medium))
                .foregroundColor(viewModel.searchText.isEmpty ? .white.opacity(0.45) : .white)
                .lineLimit(1)
                .allowsHitTesting(false)
            }
            .allowsHitTesting(false)
        }
        .padding(.horizontal, 26)
        .frame(height: 72)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCapsule(focused: searchFieldFocused))
    }

    // MARK: - Type filter

    private var typeFilterRow: some View {
        HStack(spacing: 16) {
            ForEach(SearchContentType.allCases) { type in
                GlassChip(
                    title: type.title,
                    isSelected: viewModel.selectedType == type,
                    externalFocus: $focusedTypeFilterID,
                    focusValue: "type:\(type.rawValue)"
                ) {
                    viewModel.setType(type)
                }
            }

            Spacer()

            if !visibleResults.isEmpty {
                Text(resultsCountLabel)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    // MARK: - Results: text list + poster grid

    private var visibleResults: [NuvioMeta] {
        guard hideUnreleased else { return viewModel.results }
        return viewModel.results.filter { !ContentReleasePolicy.isUnreleased($0) }
    }

    private var resultsCountLabel: String {
        let count = visibleResults.count
        if count == 1 {
            return L10n.format("tvos_search_result_count_one", fallback: "%d result", count)
        }
        return L10n.format("tvos_search_result_count_other", fallback: "%d results", count)
    }

    @ViewBuilder
    private var resultsBody: some View {
        if viewModel.isLoading {
            centeredState {
                ProgressView()
                    .scaleEffect(1.6)
                    .tint(.white)
            }
        } else if let error = viewModel.error {
            centeredState {
                messageState(icon: "wifi.exclamationmark", title: error)
            }
        } else if visibleResults.isEmpty {
            centeredState {
                messageState(
                    icon: "magnifyingglass",
                    title: L10n.string("search_no_results_title", fallback: "No Results"),
                    subtitle: L10n.format(
                        "tvos_search_no_results_for",
                        fallback: "No results for “%@”",
                        viewModel.searchText
                    )
                )
            }
        } else {
            HStack(alignment: .top, spacing: NetflixSearchMetrics.columnGap) {
                resultsList
                resultsGrid
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(visibleResults) { item in
                    let focusID = "list:\(item.id)"
                    let isFocused = focusedItemID == focusID
                    Button {
                        overlayRestoreItemID = focusID
                        lastFocusedItemID = focusID
                        onContentClick(item.id, item.type)
                    } label: {
                        Text(item.name)
                            .font(.system(size: 24, weight: isFocused ? .bold : .regular))
                            .foregroundColor(isFocused ? .black : .white.opacity(0.85))
                            .lineLimit(1)
                            .padding(.horizontal, 20)
                            .frame(height: 54)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(GlassChipBackground(filled: isFocused))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focused($focusedItemID, equals: focusID)
                    .focusEffectDisabledIfAvailable()
                    .disabled(overlayRestoreItemID != nil && overlayRestoreItemID != focusID)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 40)
        }
        .frame(width: NetflixSearchMetrics.listWidth)
        .focusSection()
        .defaultFocusIfAvailable($focusedItemID, defaultItemFocusID)
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: NetflixSearchMetrics.posterGap) {
                ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, item in
                    let focusID = "grid:\(item.id)"
                    PosterGridCard(
                        meta: item,
                        width: NetflixSearchMetrics.posterWidth,
                        height: NetflixSearchMetrics.posterHeight,
                        externalFocus: $focusedItemID,
                        focusValue: focusID,
                        retainFocusAppearance: overlayRestoreItemID == focusID,
                        onLongPress: onLongPress.map { cb in { cb(item) } },
                        forceShowLabels: true
                    ) {
                        overlayRestoreItemID = focusID
                        lastFocusedItemID = focusID
                        onContentClick(item.id, item.type)
                    }
                    .disabled(overlayRestoreItemID != nil && overlayRestoreItemID != focusID)
                }
            }
            // Room on every edge so a focused card's 1.06 scale and outline
            // remain fully visible, including the last card at the right.
            .padding(.top, 12)
            .padding(.horizontal, 12)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
    }

    /// A 1080p Apple TV has room for six of these posters beside the text
    /// index. Keeping that count explicit avoids `LazyVGrid` choosing a
    /// smaller intrinsic width and leaving an unused sixth slot at the right.
    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(NetflixSearchMetrics.posterWidth),
                spacing: NetflixSearchMetrics.posterGap,
                alignment: .top
            ),
            count: 6
        )
    }

    /// List row the results area should focus when it (re)gains focus: the
    /// row the user left on when armed and still present, else the first one.
    private var defaultItemFocusID: String? {
        if shouldRestoreFocus,
           let saved = lastFocusedItemID,
           saved.hasPrefix("list:"),
           visibleResults.contains(where: { "list:\($0.id)" == saved }) {
            return saved
        }
        return visibleResults.first.map { "list:\($0.id)" }
    }

    // MARK: Recent searches (shown above Discover when idle)

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("search_recent_title", fallback: "Recent searches"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.recentSearches, id: \.self) { term in
                        GlassChip(
                            title: term,
                            isSelected: false,
                            leadingSystemImage: "clock.arrow.circlepath",
                            externalFocus: $focusedRecentSearchID,
                            focusValue: "recent:\(term)"
                        ) {
                            viewModel.applyRecent(term)
                        }
                    }

                    Button { viewModel.clearRecent() } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "trash")
                            Text(L10n.string("action_clear", fallback: "Clear"))
                        }
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(clearRecentFocused ? .black : .white.opacity(0.85))
                        .padding(.horizontal, 22)
                        .frame(height: 50)
                        .modifier(GlassChipBackground(filled: clearRecentFocused))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focused($clearRecentFocused)
                    .modifier(ExternalFocusBinding(binding: $focusedRecentSearchID, id: "recent:clear"))
                    .focusEffectDisabledIfAvailable()
                    .scaleEffect(clearRecentFocused ? 1.06 : 1.0)
                    .animation(.easeOut(duration: 0.14), value: clearRecentFocused)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
                .padding(.trailing, 80)
            }
            .scrollClipDisabledIfAvailable()
        }
    }

    // MARK: - Shared states

    private func centeredState<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 40)
            content()
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private func messageState(icon: String, title: String, subtitle: String? = nil) -> some View {
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

    // MARK: - Focus helpers

    /// Back button from the results returns to the query field, matching the
    /// old behavior where Menu re-opened the on-screen keyboard.
    private func focusSearchField() {
        guard isEnabled, overlayRestoreItemID == nil, !discoverOverlayTransitionActive else { return }
        searchFieldFocused = true
    }
    private var canHandleExitCommand: Bool {
        guard isEnabled,
              overlayRestoreItemID == nil,
              !discoverOverlayTransitionActive else { return false }
        return focusedItemID != nil || focusedTypeFilterID != nil
    }

    private func handleExitCommand() {
        focusSearchField()
    }
}
