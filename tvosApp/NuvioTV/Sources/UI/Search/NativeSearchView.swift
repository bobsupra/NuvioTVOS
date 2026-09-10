import SwiftUI

/// Native tvOS search using the system `.searchable` keyboard — the built-in
/// single-row horizontal alphabet that Apple ships on Apple TV. Wraps its
/// content in a local `NavigationStack` (required by `.searchable`) without
/// affecting the app's overlay-based navigation elsewhere.
///
/// Reuses `SearchViewModel` (same as Classic search), `PosterGridCard`,
/// `GlassChip`, `DiscoverSection`, `SearchContentType`, and
/// `ContentReleasePolicy`.
private enum NativeSearchGridMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28
    static let columnCount: CGFloat = 7
    static let cardRowWidth = posterWidth * columnCount + posterGap * (columnCount - 1)
    static let gridContentInset: CGFloat = 12
    static let pageInset: CGFloat = 36
}

struct NativeSearchView: View {
    @StateObject private var viewModel: SearchViewModel
    let showDiscover: Bool
    let isFullScreenOverlayPresented: Bool
    let detailsDidDisappearGeneration: UInt
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    @FocusState private var focusedResultID: String?
    @FocusState private var clearRecentFocused: Bool
    @State private var lastFocusedResultID: String?
    @State private var shouldRestoreResultFocus = false
    @State private var restoreArmTask: Task<Void, Never>?
    @State private var overlayRestoreResultID: String?
    @State private var overlayRestoreGeneration = 0
    @State private var overlayFocusRestoreStartedGeneration: Int?
    @State private var overlayFocusRestorationActive = false
    @State private var suppressOverlayDismissalExit = false
    @State private var resultsScrollTopGeneration = 0
    @State private var nativeGridColumnCount = Int(NativeSearchGridMetrics.columnCount)
    @State private var discoverOverlayTransitionActive = false
    /// Controls the native `.searchable` keyboard visibility. Collapsed when
    /// focus enters the result grid or Discover cards, restored when the user
    /// exits back up (matching Netflix's collapse behaviour).
    @State private var searchPresented = true
    /// Arms result-focus restoration only after a nil focus survives the same
    /// short debounce used by Discover. A lazy cell can briefly blur while a
    /// fast swipe realizes the next card; that must not open the keyboard.
    @State private var resultFocusGeneration = 0
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false

    init(
        viewModel: SearchViewModel,
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
                // Native tvOS keyboard in a collapsible container.
                // The NavigationStack is needed solely for `.searchable`.
                NativeSearchKeyboardHost(
                    text: $viewModel.searchText,
                    prompt: L10n.string("search_placeholder", fallback: "Search movies & series"),
                    isPresented: $searchPresented,
                    isDisabled: overlayRestoreResultID != nil || discoverOverlayTransitionActive
                )

                // Main content: type filters + results or Discover.
                VStack(alignment: .leading, spacing: 24) {
                    if viewModel.hasQuery {
                        typeFilter
                            .frame(width: NativeSearchGridMetrics.cardRowWidth, alignment: .leading)
                            .padding(.horizontal, NativeSearchGridMetrics.gridContentInset)
                            .disabled(overlayRestoreResultID != nil)
                            .zIndex(1)
                        resultsContainer
                            .zIndex(0)
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
                                    guard isEnabled,
                                          !discoverOverlayTransitionActive else { return }
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
                .padding(.horizontal, NativeSearchGridMetrics.pageInset)
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        .onAppear {
            viewModel.reloadRecent()
        }
        .onChange(of: focusedResultID) { _, newValue in
            resultFocusGeneration &+= 1
            if let newValue {
                restoreArmTask?.cancel()
                lastFocusedResultID = newValue
                shouldRestoreResultFocus = false
                // Collapse the native keyboard when a result card gains focus.
                withAnimation(.easeInOut(duration: 0.22)) {
                    searchPresented = false
                }
                if isEnabled,
                   newValue == overlayRestoreResultID,
                   !overlayFocusRestorationActive {
                    overlayRestoreResultID = nil
                }
            } else if lastFocusedResultID != nil {
                // Focus can be nil for a frame while a lazy cell is realized.
                // Arm restoration only if it remains nil; do not expand the
                // keyboard from this passive focus transition.
                scheduleRestoreArm()
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                overlayRestoreGeneration &+= 1
                overlayRestoreResultID = focusedResultID ?? lastFocusedResultID
            } else if let target = overlayRestoreResultID {
                restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
            }
        }
        .onChange(of: detailsDidDisappearGeneration) { _, _ in
            guard !isFullScreenOverlayPresented,
                  let target = overlayRestoreResultID else { return }
            restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
        }
        .onExitCommand(perform: canHandleExitCommand ? handleExitCommand : nil)
    }

    // MARK: - Overlay focus restoration

    private func scheduleRestoreArm() {
        guard lastFocusedResultID != nil, focusedResultID == nil else { return }
        restoreArmTask?.cancel()
        restoreArmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled,
                  focusedResultID == nil,
                  isEnabled,
                  overlayRestoreResultID == nil,
                  !searchPresented,
                  !overlayFocusRestorationActive else { return }
            shouldRestoreResultFocus = true
        }
    }

    /// Re-presents the native `.searchable` keyboard after it was collapsed.
    private func showKeyboard() {
        guard isEnabled,
              overlayRestoreResultID == nil,
              !overlayFocusRestorationActive else { return }
        withAnimation(.easeInOut(duration: 0.22)) {
            searchPresented = true
        }
    }

    private func transferFirstRowFocusToKeyboard() {
        guard let source = focusedResultID else {
            showKeyboard()
            return
        }
        resultFocusGeneration &+= 1
        let generation = resultFocusGeneration
        showKeyboard()
        focusedResultID = source
        DispatchQueue.main.async {
            guard resultFocusGeneration == generation, isEnabled else { return }
            focusedResultID = source
            DispatchQueue.main.async {
                guard isEnabled, focusedResultID == source else { return }
                focusedResultID = nil
            }
        }
    }

    /// Back on the search results behaves like the Discover surface: keep the
    /// keyboard collapsed and return the result viewport/focus to its top.
    private func returnToResultsTop() {
        searchPresented = false
        resultsScrollTopGeneration &+= 1
        focusedResultID = visibleResults.first?.id
    }

    private var canHandleExitCommand: Bool {
        guard isEnabled,
              overlayRestoreResultID == nil,
              !discoverOverlayTransitionActive,
              viewModel.hasQuery else { return false }
        return focusedResultID != nil || clearRecentFocused || !searchPresented
    }

    private func handleExitCommand() {
        if suppressOverlayDismissalExit {
            suppressOverlayDismissalExit = false
            return
        }
        returnToResultsTop()
        clearRecentFocused = false
    }

    private func restoreOverlayFocus(to target: String, generation: Int) {
        guard overlayFocusRestoreStartedGeneration != generation else { return }
        overlayFocusRestoreStartedGeneration = generation
        // A delayed nil-focus callback from the detail transition must not
        // reopen the keyboard while the saved result is being restored.
        resultFocusGeneration &+= 1
        overlayFocusRestorationActive = true
        searchPresented = false
        for delay in [0.12, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if overlayRestoreGeneration == generation, overlayRestoreResultID == target {
                    focusedResultID = target
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if overlayRestoreGeneration == generation, overlayRestoreResultID == target {
                overlayRestoreResultID = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            if overlayRestoreGeneration == generation {
                overlayFocusRestorationActive = false
                suppressOverlayDismissalExit = false
            }
        }
    }

    // MARK: - Type filter

    private var typeFilter: some View {
        HStack(spacing: 16) {
            ForEach(SearchContentType.allCases) { type in
                GlassChip(title: type.title, isSelected: viewModel.selectedType == type) {
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
            guard direction == .up else { return }
            transferFirstRowFocusToKeyboard()
        }
    }

    // MARK: - Results

    private var visibleResults: [NuvioMeta] {
        guard hideUnreleased else { return viewModel.results }
        return viewModel.results.filter { !ContentReleasePolicy.isUnreleased($0) }
    }

    @ViewBuilder
    private var resultsContainer: some View {
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
                        fallback: "No results for \u{201C}%@\u{201D}",
                        viewModel.searchText
                    )
                )
            }
        } else {
            resultsGrid
        }
    }

    private var resultsCountLabel: String {
        let count = visibleResults.count
        if count == 1 {
            return L10n.format("tvos_search_result_count_one", fallback: "%d result", count)
        }
        return L10n.format("tvos_search_result_count_other", fallback: "%d results", count)
    }

    private var resultsGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 1)
                    .id("native-search-results-top")

                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: NativeSearchGridMetrics.posterGap) {
                    ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, item in
                        PosterGridCard(
                            meta: item,
                            width: NativeSearchGridMetrics.posterWidth,
                            height: NativeSearchGridMetrics.posterHeight,
                            externalFocus: $focusedResultID,
                            retainFocusAppearance: overlayRestoreResultID == item.id,
                            onLongPress: onLongPress.map { cb in { cb(item) } },
                            forceShowLabels: true,
                            onMove: index < nativeGridColumnCount ? { direction in
                                guard direction == .up else { return }
                                transferFirstRowFocusToKeyboard()
                            } : nil
                        ) {
                            overlayRestoreGeneration &+= 1
                            overlayFocusRestoreStartedGeneration = nil
                            overlayFocusRestorationActive = true
                            suppressOverlayDismissalExit = true
                            overlayRestoreResultID = item.id
                            lastFocusedResultID = item.id
                            onContentClick(item.id, item.type)
                        }
                        .disabled(overlayRestoreResultID != nil && overlayRestoreResultID != item.id)
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, NativeSearchGridMetrics.gridContentInset)
            }
            .onChange(of: resultsScrollTopGeneration) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("native-search-results-top", anchor: .top)
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { updateNativeGridColumnCount(for: geometry.size.width) }
                        .onChange(of: geometry.size.width) { _, width in
                            updateNativeGridColumnCount(for: width)
                        }
                }
            }
        }
        .focusSection()
        .defaultFocusIfAvailable($focusedResultID, defaultResultFocusID)
    }

    private var defaultResultFocusID: String? {
        if shouldRestoreResultFocus,
           let saved = lastFocusedResultID,
           visibleResults.contains(where: { $0.id == saved }) {
            return saved
        }
        return visibleResults.first?.id
    }

    private var gridColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: NativeSearchGridMetrics.posterWidth, maximum: NativeSearchGridMetrics.posterWidth),
            spacing: NativeSearchGridMetrics.posterGap,
            alignment: .top
        )]
    }

    private func updateNativeGridColumnCount(for width: CGFloat) {
        let contentWidth = max(0, width - (NativeSearchGridMetrics.gridContentInset * 2))
        let step = NativeSearchGridMetrics.posterWidth + NativeSearchGridMetrics.posterGap
        let count = max(1, Int((contentWidth + NativeSearchGridMetrics.posterGap) / step))
        if nativeGridColumnCount != count {
            nativeGridColumnCount = count
        }
    }

    // MARK: - Recent searches

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("search_recent_title", fallback: "Recent searches"))
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(viewModel.recentSearches, id: \.self) { term in
                        GlassChip(title: term, isSelected: false, leadingSystemImage: "clock.arrow.circlepath") {
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
            showKeyboard()
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

/// Shared tvOS `.searchable` host used by both Native and Netflix search.
/// Keeping the clear `NavigationStack` bounded is important: its content is
/// otherwise flexible and reserves the rest of the screen below the keyboard.
struct NativeSearchKeyboardHost: View {
    @Binding var text: String
    let prompt: String
    @Binding var isPresented: Bool
    let isDisabled: Bool
    var expandedHeight: CGFloat = 220
    var collapsedHeight: CGFloat = 110
    var onMove: ((MoveCommandDirection) -> Void)? = nil

    var body: some View {
        NavigationStack {
            Color.clear
                // `Color.clear` has no intrinsic width. Without an explicit
                // width here, tvOS can size the searchable host to its small
                // ideal width, which leaves the native keyboard compressed
                // to the leading part of the screen on some devices.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .searchable(text: $text, prompt: prompt)
                #if os(tvOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(
            height: isPresented ? expandedHeight : collapsedHeight,
            alignment: .top
        )
        .clipped()
        .disabled(isDisabled)
        .onMoveCommand { direction in
            onMove?(direction)
        }
        .animation(.easeInOut(duration: 0.22), value: isPresented)
    }
}
