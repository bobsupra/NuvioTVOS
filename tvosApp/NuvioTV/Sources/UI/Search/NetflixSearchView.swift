import SwiftUI

/// Netflix-style alternative to `SearchView`: results split into a text index
/// on the left and a poster grid on the right, mirroring the tvOS Netflix
/// search screen. Wired to the same `CatalogRepository` search use case as
/// `SearchView` via `NetflixSearchViewModel`.
///
/// Text entry uses the same tvOS `.searchable` host as Native search, so
/// Netflix gets the identical full-size linear keyboard, 123/space/delete
/// controls, and Siri dictation while retaining its own result layout.
///
/// Reuses `PosterGridCard`, `GlassChip`, `GlassCapsule`,
/// `GlassChipBackground`, `PosterCardButtonStyle`, `DiscoverSection`,
/// `SearchContentType` and `ContentReleasePolicy` from `SearchView.swift`.
private enum NetflixSearchMetrics {
    /// Sits on top of tvOS's own ~80pt overscan safe area, so this only needs
    /// to be big enough that a focused key/card's scale-up doesn't visually
    /// touch the safe-area boundary.
    /// Match Classic Search's outer gutter so every Netflix Search surface —
    /// not only Discover — shares the same centered content column.
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
    let isFullScreenOverlayPresented: Bool
    let detailsDidDisappearGeneration: UInt
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

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
    @State private var restoreArmTask: Task<Void, Never>?
    @State private var overlayRestoreItemID: String?
    @State private var overlayRestoreGeneration = 0
    @State private var overlayFocusRestoreStartedGeneration: Int?
    @State private var overlayFocusRestorationActive = false
    @State private var suppressOverlayDismissalExit = false
    @State private var resultsScrollTopGeneration = 0
    @State private var discoverOverlayTransitionActive = false
    /// Match Native search: the tvOS keyboard stays mounted for focus
    /// restoration but collapses while browsing results.
    @State private var searchPresented = true
    @State private var resultFocusGeneration = 0
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false

    init(
        viewModel: NetflixSearchViewModel,
        showDiscover: Bool = true,
        isFullScreenOverlayPresented: Bool = false,
        detailsDidDisappearGeneration: UInt = 0,
        onContentClick: @escaping (String, String) -> Void,
        onLongPress: ((NuvioMeta) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.showDiscover = showDiscover
        self.isFullScreenOverlayPresented = isFullScreenOverlayPresented
        self.detailsDidDisappearGeneration = detailsDidDisappearGeneration
        self.onContentClick = onContentClick
        self.onLongPress = onLongPress
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                NativeSearchKeyboardHost(
                    text: $viewModel.searchText,
                    prompt: L10n.string("search_placeholder", fallback: "Search movies & series"),
                    isPresented: $searchPresented,
                    isDisabled: overlayRestoreItemID != nil || discoverOverlayTransitionActive
                )

                VStack(alignment: .leading, spacing: 20) {
                    if viewModel.hasQuery {
                        typeFilterRow
                            .disabled(overlayRestoreItemID != nil || (searchPresented && focusedTypeFilterID == nil))
                        resultsBody
                    } else {
                        if searchPresented, !viewModel.recentSearches.isEmpty {
                            recentRow
                                .disabled(discoverOverlayTransitionActive)
                        }
                        if showDiscover {
                            DiscoverSection(
                                onContentClick: onContentClick,
                                onLongPress: onLongPress,
                                onCardFocus: {
                                    withAnimation(.easeInOut(duration: 0.22)) {
                                        searchPresented = false
                                    }
                                },
                                onFilterFocus: {
                                    showKeyboard()
                                },
                                onFocusExit: {
                                    // A recent-search chip is directly above Discover.
                                    // If focus moved there, keep it there instead of
                                    // stealing it back for the query field.
                                    guard isEnabled,
                                          !discoverOverlayTransitionActive,
                                          focusedRecentSearchID == nil else { return }
                                    showKeyboard()
                                },
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
                .padding(.top, 40)
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .onAppear {
            viewModel.reloadRecent()
        }
        .onExitCommand(perform: canHandleExitCommand ? handleExitCommand : nil)
        .onChange(of: focusedItemID) { _, newValue in
            resultFocusGeneration &+= 1
            if let newValue {
                withAnimation(.easeInOut(duration: 0.22)) {
                    searchPresented = false
                }
                lastFocusedItemID = newValue
                shouldRestoreFocus = false
                if isEnabled,
                   newValue == overlayRestoreItemID,
                   !overlayFocusRestorationActive {
                    overlayRestoreItemID = nil
                }
            } else if lastFocusedItemID != nil {
                // A fast lazy-list/grid transition can briefly report nil
                // focus. Match Discover: wait for a stable departure and arm
                // card restoration without reopening the keyboard.
                scheduleRestoreArm()
            }
        }
        .onChange(of: focusedTypeFilterID) { _, newValue in
            guard newValue != nil,
                  focusedItemID == nil,
                  isEnabled,
                  overlayRestoreItemID == nil,
                  !overlayFocusRestorationActive else { return }
            showKeyboard()
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                overlayRestoreGeneration &+= 1
                overlayRestoreItemID = focusedItemID ?? lastFocusedItemID
            } else if let target = overlayRestoreItemID {
                searchPresented = false
                restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
            }
        }
        .onChange(of: detailsDidDisappearGeneration) { _, _ in
            guard !isFullScreenOverlayPresented,
                  let target = overlayRestoreItemID else { return }
            restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
        }
    }

    private func scheduleRestoreArm() {
        guard lastFocusedItemID != nil, focusedItemID == nil else { return }
        restoreArmTask?.cancel()
        restoreArmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled,
                  focusedItemID == nil,
                  focusedTypeFilterID == nil,
                  viewModel.hasQuery,
                  isEnabled,
                  overlayRestoreItemID == nil,
                  !searchPresented,
                  !overlayFocusRestorationActive else { return }
            shouldRestoreFocus = true
        }
    }

    private func restoreOverlayFocus(to target: String, generation: Int) {
        guard overlayFocusRestoreStartedGeneration != generation else { return }
        overlayFocusRestoreStartedGeneration = generation
        // Invalidate any focus-loss callback left over from the detail
        // transition before placing focus back on the saved result.
        resultFocusGeneration &+= 1
        overlayFocusRestorationActive = true
        searchPresented = false
        for delay in [0.06, 0.12, 0.45] {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            if overlayRestoreGeneration == generation {
                overlayFocusRestorationActive = false
                suppressOverlayDismissalExit = false
            }
        }
    }

    private var canHandleExitCommand: Bool {
        guard isEnabled,
              overlayRestoreItemID == nil,
              !discoverOverlayTransitionActive else { return false }
        return focusedItemID != nil ||
            focusedTypeFilterID != nil ||
            focusedRecentSearchID != nil ||
            clearRecentFocused ||
            (viewModel.hasQuery && !searchPresented)
    }

    private func handleExitCommand() {
        if suppressOverlayDismissalExit {
            suppressOverlayDismissalExit = false
            return
        }
        returnToResultsTop()
        focusedTypeFilterID = nil
        focusedRecentSearchID = nil
        clearRecentFocused = false
        shouldRestoreFocus = false
    }

    /// Back on search behaves like Discover: leave the keyboard collapsed and
    /// return the results columns to their top edge.
    private func returnToResultsTop() {
        searchPresented = false
        resultsScrollTopGeneration &+= 1
        guard let first = visibleResults.first else {
            focusedItemID = nil
            return
        }
        let prefix = focusedItemID?.hasPrefix("grid:") == true ? "grid:" : "list:"
        focusedItemID = "\(prefix)\(first.id)"
    }

    /// Re-expands the shared Native search host after focus leaves results.
    private func showKeyboard() {
        guard isEnabled,
              overlayRestoreItemID == nil,
              !overlayFocusRestorationActive else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            searchPresented = true
        }
    }

    /// tvOS can continue processing the same Up press after `onMoveCommand`
    /// returns. Hold the source card through that pass, reveal the keyboard,
    /// then land on the All filter as the intermediate focus stop.
    private func transferFirstRowFocusToAllFilter() {
        guard let sourceFocusID = focusedItemID else {
            showKeyboard()
            return
        }

        resultFocusGeneration &+= 1
        let generation = resultFocusGeneration
        showKeyboard()

        // Claim the current card again so this Up press cannot also open the
        // adaptive tab sidebar/menu. This mirrors the app's grid-hero focus guard.
        focusedItemID = sourceFocusID
        DispatchQueue.main.async {
            guard resultFocusGeneration == generation,
                  searchPresented,
                  isEnabled else { return }
            focusedItemID = sourceFocusID
            DispatchQueue.main.async {
                guard searchPresented,
                      isEnabled,
                      focusedItemID == sourceFocusID else { return }
                focusedItemID = nil
                focusedTypeFilterID = "type:\(SearchContentType.all.rawValue)"
            }
        }
    }

    /// Claim the filter for the remainder of its Up press, then enter the
    /// keyboard on the next focus pass so the adaptive sidebar cannot win.
    private func transferTypeFilterFocusToKeyboard() {
        guard let sourceFocusID = focusedTypeFilterID else {
            showKeyboard()
            return
        }

        resultFocusGeneration &+= 1
        let generation = resultFocusGeneration
        showKeyboard()

        focusedTypeFilterID = sourceFocusID
        DispatchQueue.main.async {
            guard resultFocusGeneration == generation,
                  searchPresented,
                  isEnabled else { return }
            focusedTypeFilterID = sourceFocusID
            DispatchQueue.main.async {
                guard searchPresented,
                      isEnabled,
                      focusedTypeFilterID == sourceFocusID else { return }
                focusedTypeFilterID = nil
            }
        }
    }

    private func transferRecentRowFocusToKeyboard() {
        resultFocusGeneration &+= 1
        let generation = resultFocusGeneration
        showKeyboard()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard resultFocusGeneration == generation,
                  searchPresented,
                  isEnabled else { return }
            focusedRecentSearchID = nil
            clearRecentFocused = false
        }
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
        .onMoveCommand { direction in
            guard direction == .up, focusedTypeFilterID != nil else { return }
            transferTypeFilterFocusToKeyboard()
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
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 1)
                    .id("netflix-search-list-top")

                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, item in
                        let focusID = "list:\(item.id)"
                        let isFocused = focusedItemID == focusID
                        Button {
                            overlayRestoreGeneration &+= 1
                            overlayFocusRestoreStartedGeneration = nil
                            overlayFocusRestorationActive = true
                            suppressOverlayDismissalExit = true
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
                        .onMoveCommand { direction in
                            guard index == 0, direction == .up else { return }
                            transferFirstRowFocusToAllFilter()
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
            .onChange(of: resultsScrollTopGeneration) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("netflix-search-list-top", anchor: .top)
                }
            }
        }
        .frame(width: NetflixSearchMetrics.listWidth)
        .disabled(searchPresented && focusedTypeFilterID == nil && focusedItemID == nil)
        .focusSection()
        .defaultFocusIfAvailable($focusedItemID, defaultItemFocusID)
    }

    private var resultsGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 1)
                    .id("netflix-search-grid-top")

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
                            forceShowLabels: true,
                            onMove: index < gridColumns.count ? { direction in
                                guard direction == .up else { return }
                                transferFirstRowFocusToAllFilter()
                            } : nil
                        ) {
                            overlayRestoreGeneration &+= 1
                            overlayFocusRestoreStartedGeneration = nil
                            overlayFocusRestorationActive = true
                            suppressOverlayDismissalExit = true
                            overlayRestoreItemID = focusID
                            lastFocusedItemID = focusID
                            onContentClick(item.id, item.type)
                        }
                        .disabled(overlayRestoreItemID != nil && overlayRestoreItemID != focusID)
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 12)
                .padding(.bottom, 40)
            }
            .onChange(of: resultsScrollTopGeneration) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("netflix-search-grid-top", anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .focusSection()
        .defaultFocusIfAvailable($focusedItemID, defaultGridFocusID)
    }

    private var defaultGridFocusID: String? {
        if shouldRestoreFocus,
           let saved = lastFocusedItemID,
           saved.hasPrefix("grid:"),
           visibleResults.contains(where: { "grid:\($0.id)" == saved }) {
            return saved
        }
        return visibleResults.first.map { "grid:\($0.id)" }
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
        return nil
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
        .onMoveCommand { direction in
            guard direction == .up else { return }
            transferRecentRowFocusToKeyboard()
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
}
