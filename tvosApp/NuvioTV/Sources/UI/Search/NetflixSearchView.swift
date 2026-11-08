import SwiftUI

/// Netflix-style alternative to `SearchView` with poster grid results.
/// Wired to the same `CatalogRepository` search use case as
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
    static let pageInset: CGFloat = 49
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28
    static let linearColumnCount = 5
    static let gridColumnCount = 5
    static let gridCardRowWidth = posterWidth * CGFloat(gridColumnCount)
        + posterGap * CGFloat(gridColumnCount - 1)
    static let gridContentWidth = gridCardRowWidth + 24
    static let listWidth: CGFloat = 440
    static let columnGap: CGFloat = 32
}

private enum NetflixSearchLeftPressDestination: Equatable {
    case result(String)
    case list(String)
    case gridKeyboard
}

private struct NetflixSearchLeftPressSnapshot: Equatable {
    let sourceFocusID: String
    let destination: NetflixSearchLeftPressDestination
    let presentationGeneration: Int
    let returnGeneration: Int
    let resultIDs: [String]
    let columns: Int
    let layoutMode: TVOSKeyboardLayoutMode
}

private struct NetflixSearchCellFrames: Equatable {
    var cells: [String: CGRect] = [:]
    var viewports: [String: CGRect] = [:]
}

private enum NetflixSearchCellFramesPreferenceKey: PreferenceKey {
    static var defaultValue = NetflixSearchCellFrames()

    static func reduce(value: inout NetflixSearchCellFrames, nextValue: () -> NetflixSearchCellFrames) {
        let next = nextValue()
        value.cells.merge(next.cells) { _, newer in newer }
        value.viewports.merge(next.viewports) { _, newer in newer }
    }
}

private final class NetflixSearchCellFrameCache {
    var cells: [String: CGRect] = [:]
    var viewports: [String: CGRect] = [:]
}

struct NetflixSearchView: View {
    @StateObject private var viewModel: NetflixSearchViewModel
    let showDiscover: Bool
    let isFullScreenOverlayPresented: Bool
    let detailsDidDisappearGeneration: UInt
    let isActive: Bool
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    /// Separate list and poster focus IDs preserve overlay restoration in linear mode.
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
    @State private var overlayRestoreLeftPressSourceID: String?
    @State private var overlayRestoreResultsSnapshot: [String]?
    @State private var overlayRestorePresentationGeneration = 0
    @State private var overlayRestoreEnteredFullscreenPresentationGeneration: Int?
    @State private var pendingOverlayLeftPressPresentationGeneration: Int?
    @State private var overlayRestoreReturnGeneration = 0
    @State private var completedOverlayLeftPressPresentationGeneration: Int?
    @State private var nativeFocusedResultID: String?
    @State private var overlayRestoreRetryKey: String?
    @State private var resultFrameCache = NetflixSearchCellFrameCache()
    @State private var resultsScrollTopGeneration = 0
    @State private var discoverOverlayTransitionActive = false
    /// Match Native search: the tvOS keyboard stays mounted for focus
    /// restoration but collapses while browsing results.
    @State private var searchPresented = true
    @State private var linearKeyboardExpandedHeight: CGFloat = 220
    @State private var resultFocusGeneration = 0
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false

    @AppStorage("nuvio.keyboard.detectedLayout") private var detectedKeyboardMode: TVOSKeyboardLayoutMode = .linear

    init(
        viewModel: NetflixSearchViewModel,
        showDiscover: Bool = true,
        isFullScreenOverlayPresented: Bool = false,
        detailsDidDisappearGeneration: UInt = 0,
        isActive: Bool = true,
        onContentClick: @escaping (String, String) -> Void,
        onLongPress: ((NuvioMeta) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.showDiscover = showDiscover
        self.isFullScreenOverlayPresented = isFullScreenOverlayPresented
        self.detailsDidDisappearGeneration = detailsDidDisappearGeneration
        self.isActive = isActive
        self.onContentClick = onContentClick
        self.onLongPress = onLongPress
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            TVOSKeyboardLayoutDetector(
                layoutMode: $detectedKeyboardMode,
                linearExpandedHeight: $linearKeyboardExpandedHeight
            )
                .frame(width: 0, height: 0)
                .opacity(0)

            if detectedKeyboardMode == .grid {
                gridSearchBody
            } else {
                linearBody
            }
        }
        .background {
            #if os(tvOS)
            TVRemoteLeftPressMonitor(
                snapshotProvider: { overlayRestoreLeftPressSnapshot() },
                onRecognized: handleOverlayRestoreLeftPress
            )
            .frame(width: 0, height: 0)
            #else
            EmptyView()
            #endif
        }
        .onAppear {
            viewModel.reloadRecent()
        }
        .onExitCommand(perform: canHandleExitCommand ? handleExitCommand : nil)
        .onChange(of: focusedItemID) { _, newValue in
            resultFocusGeneration &+= 1
            if let newValue {
                if detectedKeyboardMode == .linear {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        searchPresented = false
                    }
                }
                lastFocusedItemID = newValue
                shouldRestoreFocus = false
            } else if lastFocusedItemID != nil {
                // A fast lazy-list/grid transition can briefly report nil
                // focus. Match Discover: wait for a stable departure and arm
                // card restoration without reopening the keyboard.
                scheduleRestoreArm()
            }
        }
        .onChange(of: focusedTypeFilterID) { _, newValue in
            if newValue != nil { clearOverlayRestoreLeftPressState() }
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
            } else if !isFullScreenOverlayPresented {
                retryOverlayRestoreAfterReturn()
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { clearOverlayRestoreLeftPressState() }
        }
        .onChange(of: focusedRecentSearchID) { _, newValue in
            if newValue != nil { clearOverlayRestoreLeftPressState() }
        }
        .onChange(of: clearRecentFocused) { _, focused in
            if focused { clearOverlayRestoreLeftPressState() }
        }
        .onPreferenceChange(NetflixSearchCellFramesPreferenceKey.self) { frames in
            resultFrameCache.cells = frames.cells
            resultFrameCache.viewports = frames.viewports
        }
        .onChange(of: visibleResultIDs) { _, resultIDs in
            if let overlayRestoreResultsSnapshot,
               overlayRestoreResultsSnapshot != resultIDs {
                clearOverlayRestoreLeftPressState()
            }
        }
        .onChange(of: isFullScreenOverlayPresented) { wasPresented, presented in
            if presented {
                guard isActive,
                      let sourceID = overlayRestoreLeftPressSourceID,
                      overlayRestoreItemID == sourceID,
                      lastFocusedItemID == sourceID,
                      overlayRestoreResultsSnapshot == visibleResultIDs else {
                    clearOverlayRestoreLeftPressState()
                    return
                }
                overlayRestoreEnteredFullscreenPresentationGeneration = overlayRestorePresentationGeneration
            } else if wasPresented,
                      isActive,
                      overlayRestoreEnteredFullscreenPresentationGeneration == overlayRestorePresentationGeneration,
                      overlayRestoreResultsSnapshot == visibleResultIDs,
                      let sourceID = overlayRestoreLeftPressSourceID,
                      lastFocusedItemID == sourceID {
                overlayRestoreReturnGeneration &+= 1
                pendingOverlayLeftPressPresentationGeneration = overlayRestorePresentationGeneration
                retryOverlayRestoreAfterReturn()
            } else if wasPresented {
                clearOverlayRestoreLeftPressState()
            }
        }
        .onChange(of: detailsDidDisappearGeneration) { _, _ in
            guard !isFullScreenOverlayPresented else { return }
            retryOverlayRestoreAfterReturn()
        }
    }

    // MARK: - Linear Layout

    private var linearBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeSearchKeyboardHost(
                text: $viewModel.searchText,
                prompt: L10n.string("search_placeholder", fallback: "Search movies & series"),
                isPresented: $searchPresented,
                isDisabled: overlayRestoreItemID != nil || discoverOverlayTransitionActive,
                topPadding: 56,
                expandedHeight: linearKeyboardExpandedHeight,
                onSubmit: {
                    viewModel.performSearch(query: viewModel.searchText)
                }
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
                .onSubmit(of: .search) {
                    viewModel.performSearch(query: viewModel.searchText)
                }
                .autocorrectionDisabled()
                #if os(tvOS)
                .toolbar(.hidden, for: .navigationBar)
                .toolbar(.hidden, for: .tabBar)
                #endif
        }
    }

    private var gridBody: some View {
        HStack(alignment: .top, spacing: NetflixSearchMetrics.columnGap) {
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.hasQuery {
                    typeFilterRow
                        .padding(.horizontal, 12)
                        .disabled(overlayRestoreItemID != nil)
                        .zIndex(1)
                    gridResultsBody
                        .zIndex(0)
                } else {
                    if !viewModel.recentSearches.isEmpty {
                        recentRow
                            .disabled(discoverOverlayTransitionActive)
                    }
                    if showDiscover {
                        DiscoverSection(
                            onContentClick: onContentClick,
                            isBesideKeyboard: true,
                            columnCount: 5,
                            onLongPress: onLongPress,
                            onFocusExit: {
                                transferFocusToGridKeyboard()
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
            .frame(width: NetflixSearchMetrics.gridContentWidth, alignment: .leading)
            .padding(.top, 24)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .padding(.trailing, NetflixSearchMetrics.pageInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func transferFocusToGridKeyboard() {
        withAnimation(.easeInOut(duration: 0.25)) {
            searchPresented = true
        }
        focusedItemID = nil
        focusedTypeFilterID = nil
        focusedRecentSearchID = nil
        clearRecentFocused = false
    }

    private func handlePosterGridCardMove(index: Int, colCount: Int, direction: MoveCommandDirection) {
        if detectedKeyboardMode == .grid {
            if index % colCount == 0, direction == .left {
                transferFocusToGridKeyboard()
            }
        } else if index < colCount {
            if direction == .up {
                transferFirstRowFocusToAllFilter()
            }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if overlayRestoreGeneration == generation, overlayRestoreItemID == target {
                overlayRestoreItemID = nil
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if overlayRestoreGeneration == generation {
                overlayFocusRestorationActive = false
                suppressOverlayDismissalExit = false
            }
        }
    }

    private func retryOverlayRestoreAfterReturn() {
        guard !isFullScreenOverlayPresented,
              isEnabled,
              let target = overlayRestoreItemID else { return }
        if overlayRestoreLeftPressSourceID != nil,
           overlayRestoreEnteredFullscreenPresentationGeneration == overlayRestorePresentationGeneration,
           pendingOverlayLeftPressPresentationGeneration == nil {
            return
        }
        let retryKey = "\(overlayRestorePresentationGeneration)|\(overlayRestoreReturnGeneration)|\(target)"
        guard overlayRestoreRetryKey != retryKey else { return }
        overlayRestoreRetryKey = retryKey
        overlayRestoreGeneration &+= 1
        overlayFocusRestoreStartedGeneration = nil
        restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
    }

    private func clearOverlayRestoreLeftPressState() {
        overlayRestoreLeftPressSourceID = nil
        overlayRestoreResultsSnapshot = nil
        overlayRestoreEnteredFullscreenPresentationGeneration = nil
        pendingOverlayLeftPressPresentationGeneration = nil
        completedOverlayLeftPressPresentationGeneration = nil
    }

    private func handleNativeResultFocusChange(_ isFocused: Bool, focusID: String) {
        if isFocused {
            if pendingOverlayLeftPressPresentationGeneration != nil,
               let sourceID = overlayRestoreLeftPressSourceID,
               sourceID != focusID {
                clearOverlayRestoreLeftPressState()
            } else if pendingOverlayLeftPressPresentationGeneration != nil,
                      overlayRestoreLeftPressSourceID == focusID {
                completedOverlayLeftPressPresentationGeneration = pendingOverlayLeftPressPresentationGeneration
                pendingOverlayLeftPressPresentationGeneration = nil
            }
            nativeFocusedResultID = focusID
            guard isEnabled, overlayRestoreItemID == focusID else { return }
            overlayRestoreItemID = nil
            overlayFocusRestorationActive = false
            suppressOverlayDismissalExit = false
        } else {
            if nativeFocusedResultID == focusID { nativeFocusedResultID = nil }
            if pendingOverlayLeftPressPresentationGeneration != nil,
               overlayRestoreLeftPressSourceID == focusID,
               !isFullScreenOverlayPresented {
                completedOverlayLeftPressPresentationGeneration = pendingOverlayLeftPressPresentationGeneration
                pendingOverlayLeftPressPresentationGeneration = nil
            }
        }
    }

    private func nearestVisibleListFocusID(for sourceFocusID: String) -> String? {
        guard let sourceFrame = resultFrameCache.cells[sourceFocusID],
              let gridViewport = resultFrameCache.viewports["grid"],
              sourceFrame.intersects(gridViewport),
              let listViewport = resultFrameCache.viewports["list"] else { return nil }

        return visibleResults.compactMap { item -> (String, CGFloat)? in
            let focusID = "list:\(item.id)"
            guard let frame = resultFrameCache.cells[focusID], frame.intersects(listViewport) else { return nil }
            return (focusID, abs(frame.midY - sourceFrame.midY))
        }
        .min { $0.1 < $1.1 }?.0
    }

    private func overlayRestoreLeftPressSnapshot() -> NetflixSearchLeftPressSnapshot? {
        guard isActive,
              isEnabled,
              !isFullScreenOverlayPresented,
              !discoverOverlayTransitionActive,
              viewModel.hasQuery,
              !viewModel.isLoading,
              viewModel.error == nil,
              detectedKeyboardMode == .grid || !searchPresented,
              let presentationGeneration = pendingOverlayLeftPressPresentationGeneration,
              presentationGeneration == overlayRestorePresentationGeneration,
              overlayRestoreEnteredFullscreenPresentationGeneration == presentationGeneration,
              let sourceFocusID = overlayRestoreLeftPressSourceID,
              sourceFocusID.hasPrefix("grid:"),
              sourceFocusID == lastFocusedItemID,
              focusedTypeFilterID == nil,
              focusedItemID == nil || focusedItemID == sourceFocusID || (overlayFocusRestorationActive && overlayRestoreItemID == sourceFocusID),
              nativeFocusedResultID == sourceFocusID || (overlayFocusRestorationActive && overlayRestoreItemID == sourceFocusID),
              overlayRestoreItemID == sourceFocusID || (overlayRestoreItemID == nil && focusedItemID == sourceFocusID),
              let originalResults = overlayRestoreResultsSnapshot,
              originalResults == visibleResultIDs,
              let sourceIndex = visibleResults.firstIndex(where: { "grid:\($0.id)" == sourceFocusID }) else {
            return nil
        }

        let columns = detectedKeyboardMode == .grid
            ? NetflixSearchMetrics.gridColumnCount
            : NetflixSearchMetrics.linearColumnCount
        let column = sourceIndex % columns
        let destination: NetflixSearchLeftPressDestination
        if column == 0 {
            if detectedKeyboardMode == .grid {
                destination = .gridKeyboard
            } else {
                guard let listFocusID = nearestVisibleListFocusID(for: sourceFocusID) else { return nil }
                destination = .list(listFocusID)
            }
        } else {
            destination = .result("grid:\(visibleResults[sourceIndex - 1].id)")
        }

        return NetflixSearchLeftPressSnapshot(
            sourceFocusID: sourceFocusID,
            destination: destination,
            presentationGeneration: presentationGeneration,
            returnGeneration: overlayRestoreReturnGeneration,
            resultIDs: visibleResultIDs,
            columns: columns,
            layoutMode: detectedKeyboardMode
        )
    }

    private func handleOverlayRestoreLeftPress(_ snapshot: NetflixSearchLeftPressSnapshot) {
        guard isActive,
              isEnabled,
              !isFullScreenOverlayPresented,
              !discoverOverlayTransitionActive,
              viewModel.hasQuery,
              !viewModel.isLoading,
              viewModel.error == nil,
              detectedKeyboardMode == .grid || !searchPresented,
              pendingOverlayLeftPressPresentationGeneration == snapshot.presentationGeneration || completedOverlayLeftPressPresentationGeneration == snapshot.presentationGeneration,
              overlayRestorePresentationGeneration == snapshot.presentationGeneration,
              overlayRestoreReturnGeneration == snapshot.returnGeneration,
              overlayRestoreEnteredFullscreenPresentationGeneration == snapshot.presentationGeneration,
              overlayRestoreLeftPressSourceID == snapshot.sourceFocusID,
              lastFocusedItemID == snapshot.sourceFocusID,
              focusedItemID == nil || focusedItemID == snapshot.sourceFocusID || completedOverlayLeftPressPresentationGeneration == snapshot.presentationGeneration,
              nativeFocusedResultID == snapshot.sourceFocusID || (overlayFocusRestorationActive && overlayRestoreItemID == snapshot.sourceFocusID) || completedOverlayLeftPressPresentationGeneration == snapshot.presentationGeneration,
              overlayRestoreItemID == snapshot.sourceFocusID || focusedItemID == snapshot.sourceFocusID || completedOverlayLeftPressPresentationGeneration == snapshot.presentationGeneration,
              focusedTypeFilterID == nil,
              visibleResultIDs == snapshot.resultIDs,
              snapshot.layoutMode == detectedKeyboardMode,
              snapshot.columns == (detectedKeyboardMode == .grid ? NetflixSearchMetrics.gridColumnCount : NetflixSearchMetrics.linearColumnCount) else { return }

        overlayRestoreGeneration &+= 1
        resultFocusGeneration &+= 1
        overlayFocusRestoreStartedGeneration = nil
        restoreArmTask?.cancel()
        shouldRestoreFocus = false

        switch snapshot.destination {
        case .result(let target):
            overlayRestoreItemID = target
            lastFocusedItemID = target
            overlayRestoreLeftPressSourceID = target
            pendingOverlayLeftPressPresentationGeneration = snapshot.presentationGeneration
            completedOverlayLeftPressPresentationGeneration = nil
            overlayRestoreRetryKey = "\(snapshot.presentationGeneration)|\(snapshot.returnGeneration)|\(target)"
            overlayFocusRestorationActive = true
            suppressOverlayDismissalExit = true
            restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
        case .list(let target):
            overlayRestoreItemID = target
            lastFocusedItemID = target
            clearOverlayRestoreLeftPressState()
            overlayRestoreRetryKey = "\(snapshot.presentationGeneration)|\(snapshot.returnGeneration)|\(target)"
            overlayFocusRestorationActive = true
            suppressOverlayDismissalExit = true
            restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
        case .gridKeyboard:
            clearOverlayRestoreLeftPressState()
            overlayRestoreItemID = nil
            overlayFocusRestorationActive = false
            suppressOverlayDismissalExit = false
            transferFocusToGridKeyboard()
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
        let prefix = focusedItemID?.hasPrefix("list:") == true ? "list:" : "grid:"
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

    private func transferFilterFocusToGridResults() {
        guard detectedKeyboardMode == .grid,
              viewModel.hasQuery,
              isEnabled,
              !isFullScreenOverlayPresented,
              overlayRestoreItemID == nil,
              !overlayFocusRestorationActive,
              !discoverOverlayTransitionActive,
              !viewModel.isLoading,
              viewModel.error == nil,
              let firstResultID = visibleResults.first?.id else { return }

        resultFocusGeneration &+= 1
        let generation = resultFocusGeneration
        restoreArmTask?.cancel()
        shouldRestoreFocus = false
        resultsScrollTopGeneration &+= 1

        focusedTypeFilterID = nil
        focusedItemID = "grid:\(firstResultID)"

        DispatchQueue.main.async {
            guard resultFocusGeneration == generation,
                  detectedKeyboardMode == .grid,
                  viewModel.hasQuery,
                  isEnabled,
                  !isFullScreenOverlayPresented,
                  overlayRestoreItemID == nil,
                  !overlayFocusRestorationActive,
                  !discoverOverlayTransitionActive,
                  !viewModel.isLoading,
                  viewModel.error == nil,
                  visibleResults.first?.id == firstResultID else { return }
            focusedTypeFilterID = nil
            focusedItemID = "grid:\(firstResultID)"
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
            if detectedKeyboardMode == .grid {
                if direction == .down, focusedTypeFilterID != nil {
                    transferFilterFocusToGridResults()
                } else if direction == .left {
                    let firstFilterID = SearchContentType.allCases.first.map { "type:\($0.rawValue)" }
                    if focusedTypeFilterID == nil || focusedTypeFilterID == firstFilterID {
                        transferFocusToGridKeyboard()
                    }
                }
            } else {
                guard direction == .up, focusedTypeFilterID != nil else { return }
                transferTypeFilterFocusToKeyboard()
            }
        }
    }

    // MARK: - Results: text list + poster grid

    private var visibleResults: [NuvioMeta] {
        guard hideUnreleased else { return viewModel.results }
        return viewModel.results.filter { !ContentReleasePolicy.isUnreleased($0) }
    }

    private var visibleResultIDs: [String] { visibleResults.map(\.id) }

    private var resultsCountLabel: String {
        let count = visibleResults.count
        if count == 1 {
            return L10n.format("tvos_search_result_count_one", fallback: "%d result", count)
        }
        return L10n.format("tvos_search_result_count_other", fallback: "%d results", count)
    }

    @ViewBuilder
    private var gridResultsBody: some View {
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
            let reason = viewModel.emptyStateReason ?? .noResults
            centeredState {
                messageState(
                    icon: reason.icon,
                    title: reason.title,
                    subtitle: reason.subtitle(for: viewModel.searchText)
                )
            }
        } else {
            resultsGrid
        }
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
            let reason = viewModel.emptyStateReason ?? .noResults
            centeredState {
                messageState(
                    icon: reason.icon,
                    title: reason.title,
                    subtitle: reason.subtitle(for: viewModel.searchText)
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
                            clearOverlayRestoreLeftPressState()
                            overlayRestoreGeneration &+= 1
                            overlayFocusRestoreStartedGeneration = nil
                            overlayFocusRestorationActive = true
                            suppressOverlayDismissalExit = true
                            overlayRestoreItemID = focusID
                            lastFocusedItemID = focusID
                            viewModel.commitCurrentSearch()
                            onContentClick(item.id, item.type)
                        } label: {
                            MarqueeText(item.name, size: 24, weight: isFocused ? .bold : .regular,
                                        color: isFocused ? .black : .white.opacity(0.85), isActive: isFocused)
                                .padding(.horizontal, 20)
                                .frame(height: 54)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .modifier(GlassChipBackground(filled: isFocused))
                        }
                        .buttonStyle(PosterCardButtonStyle(onNativeFocusChange: { focused in
                            handleNativeResultFocusChange(focused, focusID: focusID)
                        }))
                        .focused($focusedItemID, equals: focusID)
                        .focusEffectDisabledIfAvailable()
                        .disabled(overlayRestoreItemID != nil && overlayRestoreItemID != focusID)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: NetflixSearchCellFramesPreferenceKey.self,
                                    value: NetflixSearchCellFrames(cells: [focusID: geometry.frame(in: .global)])
                                )
                            }
                        }
                        .onMoveCommand { direction in
                            guard index == 0, direction == .up else { return }
                            transferFirstRowFocusToAllFilter()
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: NetflixSearchCellFramesPreferenceKey.self,
                        value: NetflixSearchCellFrames(viewports: ["list": geometry.frame(in: .global)])
                    )
                }
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
                        let colCount = detectedKeyboardMode == .grid ? NetflixSearchMetrics.gridColumnCount : gridColumns.count
                        PosterGridCard(
                            meta: item,
                            width: NetflixSearchMetrics.posterWidth,
                            height: NetflixSearchMetrics.posterHeight,
                            externalFocus: $focusedItemID,
                            focusValue: focusID,
                            retainFocusAppearance: overlayRestoreItemID == focusID,
                            onFocus: { _ in handleNativeResultFocusChange(true, focusID: focusID) },
                            onBlur: { _ in handleNativeResultFocusChange(false, focusID: focusID) },
                            onLongPress: onLongPress.map { cb in { cb(item) } },
                            forceShowLabels: true,
                            onMove: { direction in
                                handlePosterGridCardMove(index: index, colCount: colCount, direction: direction)
                            }
                        ) {
                            clearOverlayRestoreLeftPressState()
                            overlayRestoreGeneration &+= 1
                            overlayFocusRestoreStartedGeneration = nil
                            overlayFocusRestorationActive = true
                            suppressOverlayDismissalExit = true
                            overlayRestorePresentationGeneration &+= 1
                            overlayRestoreLeftPressSourceID = focusID
                            overlayRestoreResultsSnapshot = visibleResultIDs
                            overlayRestoreItemID = focusID
                            lastFocusedItemID = focusID
                            viewModel.commitCurrentSearch()
                            onContentClick(item.id, item.type)
                        }
                        .accessibilityIdentifier("netflix-search-result-\(focusID)")
                        .disabled(overlayRestoreItemID != nil && overlayRestoreItemID != focusID)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: NetflixSearchCellFramesPreferenceKey.self,
                                    value: NetflixSearchCellFrames(cells: [focusID: geometry.frame(in: .global)])
                                )
                            }
                        }
                    }
                }
                .padding(.top, 12)
                .padding(.horizontal, 12)
                .padding(.bottom, 40)
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: NetflixSearchCellFramesPreferenceKey.self,
                        value: NetflixSearchCellFrames(viewports: ["grid": geometry.frame(in: .global)])
                    )
                }
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

    private var defaultItemFocusID: String? {
        if shouldRestoreFocus,
           let saved = lastFocusedItemID,
           saved.hasPrefix("list:"),
           visibleResults.contains(where: { "list:\($0.id)" == saved }) {
            return saved
        }
        return nil
    }

    /// Keep posters within the content column beside either keyboard layout.
    private var gridColumns: [GridItem] {
        let count = detectedKeyboardMode == .grid
            ? NetflixSearchMetrics.gridColumnCount
            : NetflixSearchMetrics.linearColumnCount
        return Array(
            repeating: GridItem(
                .fixed(NetflixSearchMetrics.posterWidth),
                spacing: NetflixSearchMetrics.posterGap,
                alignment: .top
            ),
            count: count
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
            if detectedKeyboardMode == .grid {
                if direction == .left {
                    let firstRecentID = viewModel.recentSearches.first.map { "recent:\($0)" }
                    if focusedRecentSearchID == nil || focusedRecentSearchID == firstRecentID {
                        transferFocusToGridKeyboard()
                    }
                }
            } else {
                guard direction == .up else { return }
                transferRecentRowFocusToKeyboard()
            }
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
