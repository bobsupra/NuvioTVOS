import SwiftUI
import UIKit

// MARK: - Keyboard Layout Mode

public enum TVOSKeyboardLayoutMode: String, CaseIterable, Identifiable {
    case linear = "Linear"
    case grid = "Grid"

    public var id: String { rawValue }
}

/// Detects whether tvOS is presenting a Linear (single row) or Grid (multi-row) keyboard.
struct TVOSKeyboardLayoutDetector: UIViewRepresentable {
    @Binding var layoutMode: TVOSKeyboardLayoutMode

    func makeUIView(context: Context) -> TVOSKeyboardDetectorUIView {
        let view = TVOSKeyboardDetectorUIView()
        view.onDetected = { mode in
            if layoutMode != mode {
                layoutMode = mode
            }
        }
        return view
    }

    func updateUIView(_ uiView: TVOSKeyboardDetectorUIView, context: Context) {
        uiView.onDetected = { mode in
            if layoutMode != mode {
                layoutMode = mode
            }
        }
    }
}

final class TVOSKeyboardDetectorUIView: UIView {
    var onDetected: ((TVOSKeyboardLayoutMode) -> Void)?
    private var lastMode: TVOSKeyboardLayoutMode?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleInspection()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleInspection()
    }

    private func scheduleInspection() {
        DispatchQueue.main.async { [weak self] in
            self?.inspectHierarchy()
        }
    }

    private func inspectHierarchy() {
        guard let window = self.window else { return }
        var detected: TVOSKeyboardLayoutMode?

        func inspect(view: UIView) {
            let className = String(describing: type(of: view))
            if className.contains("Keyboard") {
                let size = view.bounds.size
                // Grid keyboard is tall (> 320pt) and bounded in width (< 900pt)
                if size.height > 320 && size.width > 200 && size.width < 900 {
                    detected = .grid
                } else if detected == nil, size.width >= 900, size.height > 40 {
                    detected = .linear
                }
            }
            for subview in view.subviews {
                inspect(view: subview)
            }
        }

        inspect(view: window)

        // An absent keyboard during mounting or dismissal is not a layout change.
        guard let detected else { return }
        if detected != lastMode {
            lastMode = detected
            onDetected?(detected)
        }
    }
}

// MARK: - Search Grid Metrics

private enum NativeSearchGridMetrics {
    // Linear layout metrics (7 columns)
    static let linearPosterWidth: CGFloat = 210
    static let linearPosterHeight: CGFloat = 315
    static let linearPosterGap: CGFloat = 28
    static let linearColumnCount: CGFloat = 7
    static let linearCardRowWidth = linearPosterWidth * linearColumnCount + linearPosterGap * (linearColumnCount - 1)

    // Grid layout metrics (4 columns beside the keyboard)
    static let gridPosterWidth: CGFloat = 210
    static let gridPosterHeight: CGFloat = 315
    static let gridPosterGap: CGFloat = 28
    static let gridColumnCount: CGFloat = 4
    static let gridCardRowWidth = gridPosterWidth * gridColumnCount + gridPosterGap * (gridColumnCount - 1)

    static let keyboardWidth: CGFloat = 520
    // The system search field includes the prompt and dictation affordance in
    // the same toolbar view as the keyboard. Give that view enough room for
    // the full prompt while the outer frame keeps the content column anchored
    // to the keyboard's actual layout width.
    static let keyboardRenderWidth: CGFloat = 840
    static let columnSpacing: CGFloat = 32
    static let gridContentInset: CGFloat = 12
    static let pageInset: CGFloat = 36
    static let topPadding: CGFloat = 68
    static let contentTopPadding: CGFloat = 210
}

// MARK: - NativeSearchView

struct NativeSearchView: View {
    @StateObject private var viewModel: SearchViewModel
    let showDiscover: Bool
    var forcedLayoutMode: TVOSKeyboardLayoutMode? = nil
    let isFullScreenOverlayPresented: Bool
    let detailsDidDisappearGeneration: UInt
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    @AppStorage("nuvio.keyboard.detectedLayout") private var detectedKeyboardMode: TVOSKeyboardLayoutMode = .linear

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
    @State private var nativeGridColumnCount = Int(NativeSearchGridMetrics.linearColumnCount)
    @State private var discoverOverlayTransitionActive = false
    /// Controls the native `.searchable` keyboard visibility in Linear mode.
    @State private var searchPresented = true
    @State private var resultFocusGeneration = 0
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false

    var effectiveLayoutMode: TVOSKeyboardLayoutMode {
        if let forced = forcedLayoutMode {
            return forced
        }
        return detectedKeyboardMode
    }

    init(
        viewModel: SearchViewModel,
        showDiscover: Bool = true,
        forcedLayoutMode: TVOSKeyboardLayoutMode? = nil,
        isFullScreenOverlayPresented: Bool = false,
        detailsDidDisappearGeneration: UInt = 0,
        onContentClick: @escaping (String, String) -> Void,
        onLongPress: ((NuvioMeta) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.showDiscover = showDiscover
        self.forcedLayoutMode = forcedLayoutMode
        self.isFullScreenOverlayPresented = isFullScreenOverlayPresented
        self.detailsDidDisappearGeneration = detailsDidDisappearGeneration
        self.onContentClick = onContentClick
        self.onLongPress = onLongPress
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            TVOSKeyboardLayoutDetector(layoutMode: $detectedKeyboardMode)
                .frame(width: 0, height: 0)
                .opacity(0)

            if effectiveLayoutMode == .grid {
                gridSearchBody
            } else {
                linearBody
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
                // Collapse the native keyboard in linear mode when a result card gains focus.
                if effectiveLayoutMode == .linear {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        searchPresented = false
                    }
                }
                if isEnabled,
                   newValue == overlayRestoreResultID,
                   !overlayFocusRestorationActive {
                    overlayRestoreResultID = nil
                }
            } else if lastFocusedResultID != nil {
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

    // MARK: - Linear Layout (Top Horizontal Keyboard, Results Below)

    private var linearBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeSearchKeyboardHost(
                text: $viewModel.searchText,
                prompt: L10n.string("search_placeholder", fallback: "Search movies & series"),
                isPresented: $searchPresented,
                isDisabled: overlayRestoreResultID != nil || discoverOverlayTransitionActive,
                topPadding: 56
            )

            VStack(alignment: .leading, spacing: 24) {
                if viewModel.hasQuery {
                    typeFilter(width: NativeSearchGridMetrics.linearCardRowWidth, isGridMode: false)
                        .padding(.horizontal, NativeSearchGridMetrics.gridContentInset)
                        .disabled(overlayRestoreResultID != nil)
                        .zIndex(1)
                    resultsContainer(isGridMode: false)
                        .zIndex(0)
                } else {
                    if searchPresented, !viewModel.recentSearches.isEmpty {
                        recentRow(isGridMode: false)
                            .disabled(discoverOverlayTransitionActive)
                    }
                    if showDiscover {
                        DiscoverSection(
                            onContentClick: onContentClick,
                            columnCount: 7,
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
            .padding(.top, 16)
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    // MARK: - Grid Layout (Side-by-Side: Keyboard on Left, Results on Right)

    private var gridSearchBody: some View {
        gridNavigationBody
            .padding(.top, 56)
            .safeAreaPadding(.horizontal, TVLayout.rowLeading)
    }

    private var gridNavigationBody: some View {
        NavigationStack {
            gridBody
                .searchable(
                    text: $viewModel.searchText,
                    prompt: L10n.string("search_placeholder", fallback: "Search movies & series")
                )
                .autocorrectionDisabled()
                #if os(tvOS)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                #endif
        }
    }

    private var gridBody: some View {
        HStack(alignment: .top, spacing: NativeSearchGridMetrics.columnSpacing) {
            // Right column: Content (filters + results or discover)
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.hasQuery {
                    GridSearchSuggestionChips(
                        query: $viewModel.searchText,
                        suggestions: gridSuggestionTitles,
                        isDisabled: overlayRestoreResultID != nil,
                        onSubmit: {
                            viewModel.performSearch(query: viewModel.searchText)
                        }
                    )
                    typeFilter(width: NativeSearchGridMetrics.gridCardRowWidth, isGridMode: true)
                        .padding(.horizontal, NativeSearchGridMetrics.gridContentInset)
                        .disabled(overlayRestoreResultID != nil)
                        .zIndex(1)
                    resultsContainer(isGridMode: true)
                        .zIndex(0)
                } else {
                    if !viewModel.recentSearches.isEmpty {
                        recentRow(isGridMode: true)
                            .disabled(discoverOverlayTransitionActive)
                    }
                    if showDiscover {
                        DiscoverSection(
                            onContentClick: onContentClick,
                            isBesideKeyboard: true,
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
            .frame(maxWidth: viewModel.hasQuery
                ? NativeSearchGridMetrics.gridCardRowWidth + (NativeSearchGridMetrics.gridContentInset * 2)
                : 210 * 5 + 24 * 4 + 24, alignment: .leading)
            .padding(.top, 24)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .padding(.trailing, NativeSearchGridMetrics.pageInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Overlay Focus Restoration

    private func scheduleRestoreArm() {
        guard lastFocusedResultID != nil, focusedResultID == nil else { return }
        restoreArmTask?.cancel()
        restoreArmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled,
                  focusedResultID == nil,
                  isEnabled,
                  overlayRestoreResultID == nil,
                  effectiveLayoutMode == .grid || !searchPresented,
                  !overlayFocusRestorationActive else { return }
            shouldRestoreResultFocus = true
        }
    }

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

    private func transferFocusToGridKeyboard() {
        focusedResultID = nil
        clearRecentFocused = false
    }

    private func returnToResultsTop() {
        if effectiveLayoutMode == .linear {
            searchPresented = false
        }
        resultsScrollTopGeneration &+= 1
        focusedResultID = visibleResults.first?.id
    }

    private var canHandleExitCommand: Bool {
        guard isEnabled,
              overlayRestoreResultID == nil,
              !discoverOverlayTransitionActive,
              viewModel.hasQuery else { return false }
        return focusedResultID != nil || clearRecentFocused || (effectiveLayoutMode == .linear && !searchPresented)
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
        resultFocusGeneration &+= 1
        overlayFocusRestorationActive = true
        if effectiveLayoutMode == .linear {
            searchPresented = false
        }
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

    // MARK: - Type Filter

    private func typeFilter(width: CGFloat, isGridMode: Bool) -> some View {
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
        .frame(width: width, alignment: .leading)
        .onMoveCommand { direction in
            if isGridMode {
                if direction == .left {
                    transferFocusToGridKeyboard()
                }
            } else {
                if direction == .up {
                    transferFirstRowFocusToKeyboard()
                }
            }
        }
    }

    // MARK: - Results

    private var visibleResults: [NuvioMeta] {
        guard hideUnreleased else { return viewModel.results }
        return viewModel.results.filter { !ContentReleasePolicy.isUnreleased($0) }
    }

    private var gridSuggestionTitles: [String] {
        let query = viewModel.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let matchingRecent = viewModel.recentSearches.filter {
            $0.localizedCaseInsensitiveContains(query)
        }
        let titles = viewModel.isLoading || viewModel.error != nil ? [] : visibleResults.map(\.name)
        var seen = Set<String>()
        return (titles + matchingRecent).filter { title in
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.caseInsensitiveCompare(query) != .orderedSame else { return false }
            return seen.insert(trimmed.lowercased()).inserted
        }.prefix(8).map { $0 }
    }

    @ViewBuilder
    private func resultsContainer(isGridMode: Bool) -> some View {
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
            resultsGrid(isGridMode: isGridMode)
        }
    }

    private var resultsCountLabel: String {
        let count = visibleResults.count
        if count == 1 {
            return L10n.format("tvos_search_result_count_one", fallback: "%d result", count)
        }
        return L10n.format("tvos_search_result_count_other", fallback: "%d results", count)
    }

    private func resultsGrid(isGridMode: Bool) -> some View {
        let cols = isGridMode ? gridModeColumns : linearModeColumns
        let colCount = isGridMode ? Int(NativeSearchGridMetrics.gridColumnCount) : nativeGridColumnCount

        return ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 1)
                    .id("native-search-results-top")

                LazyVGrid(columns: cols, alignment: .leading, spacing: NativeSearchGridMetrics.linearPosterGap) {
                    ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, item in
                        PosterGridCard(
                            meta: item,
                            width: NativeSearchGridMetrics.linearPosterWidth,
                            height: NativeSearchGridMetrics.linearPosterHeight,
                            externalFocus: $focusedResultID,
                            retainFocusAppearance: overlayRestoreResultID == item.id,
                            onLongPress: onLongPress.map { cb in { cb(item) } },
                            forceShowLabels: true,
                            onMove: { direction in
                                if isGridMode {
                                    if index % 4 == 0, direction == .left {
                                        transferFocusToGridKeyboard()
                                    }
                                } else {
                                    if index < colCount, direction == .up {
                                        transferFirstRowFocusToKeyboard()
                                    }
                                }
                            }
                        ) {
                            overlayRestoreGeneration &+= 1
                            overlayFocusRestoreStartedGeneration = nil
                            overlayFocusRestorationActive = true
                            suppressOverlayDismissalExit = true
                            overlayRestoreResultID = item.id
                            lastFocusedResultID = item.id
                            viewModel.commitCurrentSearch()
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
                if !isGridMode {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { updateNativeGridColumnCount(for: geometry.size.width) }
                            .onChange(of: geometry.size.width) { _, width in
                                updateNativeGridColumnCount(for: width)
                            }
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

    private var linearModeColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: NativeSearchGridMetrics.linearPosterWidth, maximum: NativeSearchGridMetrics.linearPosterWidth),
            spacing: NativeSearchGridMetrics.linearPosterGap,
            alignment: .top
        )]
    }

    private var gridModeColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: NativeSearchGridMetrics.gridPosterWidth, maximum: NativeSearchGridMetrics.gridPosterWidth),
            spacing: NativeSearchGridMetrics.gridPosterGap,
            alignment: .top
        )]
    }

    private func updateNativeGridColumnCount(for width: CGFloat) {
        let contentWidth = max(0, width - (NativeSearchGridMetrics.gridContentInset * 2))
        let step = NativeSearchGridMetrics.linearPosterWidth + NativeSearchGridMetrics.linearPosterGap
        let count = max(1, Int((contentWidth + NativeSearchGridMetrics.linearPosterGap) / step))
        if nativeGridColumnCount != count {
            nativeGridColumnCount = count
        }
    }

    // MARK: - Recent Searches

    private func recentRow(isGridMode: Bool) -> some View {
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
            if isGridMode {
                if direction == .left {
                    transferFocusToGridKeyboard()
                }
            } else {
                if direction == .up {
                    showKeyboard()
                }
            }
        }
    }

    // MARK: - Shared States

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

// MARK: - Grid Search Suggestions

/// Compact, focusable suggestions shown above grid results on tvOS.
struct GridSearchSuggestionChips: View {
    @Binding var query: String
    let suggestions: [String]
    let isDisabled: Bool
    let onSubmit: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                GlassChip(
                    title: "\u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}",
                    isSelected: false,
                    leadingSystemImage: "magnifyingglass"
                ) {
                    onSubmit()
                }
                .fixedSize(horizontal: true, vertical: false)

                ForEach(suggestions, id: \.self) { title in
                    GlassChip(title: title, isSelected: false) {
                        query = title
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .padding(.trailing, 80)
        }
        .frame(height: 76)
        .clipped()
        .disabled(isDisabled)
    }
}

// MARK: - Native Search Keyboard Hosts

/// Shared tvOS `.searchable` host for Linear keyboard (single horizontal row).
/// Bounded height with collapsible container.
struct NativeSearchKeyboardHost: View {
    @Binding var text: String
    let prompt: String
    @Binding var isPresented: Bool
    let isDisabled: Bool
    var topPadding: CGFloat = 56
    var expandedHeight: CGFloat = 220
    var collapsedHeight: CGFloat = 110

    var body: some View {
        NavigationStack {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .searchable(text: $text, prompt: prompt)
                #if os(tvOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
        }
        .padding(.top, topPadding)
        .frame(maxWidth: .infinity, alignment: .top)
        .frame(
            height: isPresented ? (expandedHeight + topPadding) : (collapsedHeight + topPadding),
            alignment: .top
        )
        .clipped()
        .disabled(isDisabled)
        .animation(.easeInOut(duration: 0.22), value: isPresented)
    }
}

/// Dedicated `.searchable` host for tvOS Grid keyboard (multi-row vertical layout).
/// Fixed width on the left with full vertical height to show all rows (a-f, g-l, m-r, s-x, y-z, space/clear).
struct NativeSearchGridKeyboardHost: View {
    @Binding var text: String
    let prompt: String
    let isDisabled: Bool
    var topPadding: CGFloat = 68
    var width: CGFloat = 780
    /// Optional visual width for the native toolbar/search field. The outer
    /// frame still reports `width` to the sibling content column.
    var renderWidth: CGFloat?
    var height: CGFloat = 780

    init(
        text: Binding<String>,
        prompt: String,
        isDisabled: Bool,
        topPadding: CGFloat = 68,
        width: CGFloat = 780,
        renderWidth: CGFloat? = nil,
        height: CGFloat = 780
    ) {
        _text = text
        self.prompt = prompt
        self.isDisabled = isDisabled
        self.topPadding = topPadding
        self.width = width
        self.renderWidth = renderWidth
        self.height = height
    }

    var body: some View {
        NavigationStack {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .searchable(text: $text, prompt: prompt)
                #if os(tvOS)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                #endif
        }
        .padding(.top, topPadding)
        .frame(width: renderWidth ?? width, height: height, alignment: .topLeading)
        .clipped()
        .frame(width: width, height: height, alignment: .topLeading)
        .disabled(isDisabled)
    }
}
