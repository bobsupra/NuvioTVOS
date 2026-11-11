import SwiftUI
import UIKit

// MARK: - Keyboard Layout Mode

public enum TVOSKeyboardLayoutMode: String, CaseIterable, Identifiable {
    case linear = "Linear"
    case grid = "Grid"

    public var id: String { rawValue }
}

private enum NativeSearchLeftPressDestination: Equatable {
    case result(String)
    case gridKeyboard
}

private struct NativeSearchLeftPressSnapshot: Equatable {
    let sourceFocusID: String
    let destination: NativeSearchLeftPressDestination
    let presentationGeneration: Int
    let returnGeneration: Int
    let resultIDs: [String]
    let columns: Int
    let layoutMode: TVOSKeyboardLayoutMode
}

/// Detects whether tvOS is presenting a Linear (horizontal) or Grid (multi-row) keyboard.
struct TVOSKeyboardLayoutDetector: UIViewRepresentable {
    @Binding var layoutMode: TVOSKeyboardLayoutMode
    @Binding var linearExpandedHeight: CGFloat

    init(
        layoutMode: Binding<TVOSKeyboardLayoutMode>,
        linearExpandedHeight: Binding<CGFloat> = .constant(220)
    ) {
        _layoutMode = layoutMode
        _linearExpandedHeight = linearExpandedHeight
    }

    static func measuredLinearExpandedHeight(for keyPlaneHeight: CGFloat) -> CGFloat? {
        guard keyPlaneHeight > 0 else { return nil }
        // Observed key planes are about 66pt for one row and 144pt for two; 100pt separates them.
        return keyPlaneHeight <= 100 ? 220 : 320
    }

    func makeUIView(context: Context) -> TVOSKeyboardDetectorUIView {
        let view = TVOSKeyboardDetectorUIView()
        configure(view)
        return view
    }

    func updateUIView(_ uiView: TVOSKeyboardDetectorUIView, context: Context) {
        configure(uiView)
    }

    private func configure(_ view: TVOSKeyboardDetectorUIView) {
        view.onDetected = { mode in
            if layoutMode != mode {
                layoutMode = mode
            }
        }
        view.onLinearKeyboardHeight = { height in
            if linearExpandedHeight != height {
                linearExpandedHeight = height
            }
        }
    }
}

final class TVOSKeyboardDetectorUIView: UIView {
    var onDetected: ((TVOSKeyboardLayoutMode) -> Void)?
    var onLinearKeyboardHeight: ((CGFloat) -> Void)?
    private var lastMode: TVOSKeyboardLayoutMode?
    private var lastLinearExpandedHeight: CGFloat?
    private var inspectionScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupNotifications()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupNotifications()
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(focusDidChange),
            name: UIFocusSystem.didUpdateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(inputModeDidChange),
            name: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func focusDidChange() {
        scheduleInspection()
    }

    @objc private func inputModeDidChange() {
        scheduleInspection()
        scheduleDeferredInspections(after: [0.1, 0.3])
    }

    private func updateMode(_ mode: TVOSKeyboardLayoutMode) {
        if mode != lastMode {
            lastMode = mode
            onDetected?(mode)
        }
    }

    private func updateLinearExpandedHeight(from keyPlaneHeight: CGFloat) {
        guard let height = TVOSKeyboardLayoutDetector.measuredLinearExpandedHeight(for: keyPlaneHeight),
              height != lastLinearExpandedHeight else { return }
        lastLinearExpandedHeight = height
        onLinearKeyboardHeight?(height)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleInspection()
        scheduleDeferredInspections(after: [0.1, 0.3, 0.6, 1.0])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleInspection()
    }

    private func scheduleInspection() {
        guard !inspectionScheduled else { return }
        inspectionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inspectionScheduled = false
            self.inspectHierarchy()
        }
    }

    private func scheduleDeferredInspections(after delays: [TimeInterval]) {
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.scheduleInspection()
            }
        }
    }

    private func inspectHierarchy() {
        guard let window = self.window else { return }
        var detected: TVOSKeyboardLayoutMode?
        var linearKeyPlaneHeight: CGFloat?

        func inspect(view: UIView) {
            guard !view.isHidden, view.alpha > 0 else { return }
            let className = String(describing: type(of: view))
            let size = view.bounds.size

            if className == "UIKeyboard", size.width >= 900, size.height > 0 {
                linearKeyPlaneHeight = size.height
            }

            if className.contains("Keyboard") {
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

        let windows: [UIWindow]
        if let sceneWindows = window.windowScene?.windows, !sceneWindows.isEmpty {
            windows = sceneWindows
        } else {
            windows = [window]
        }
        for w in windows {
            inspect(view: w)
        }

        // An absent keyboard during mounting or dismissal is not a layout change.
        if let detected {
            updateMode(detected)
        }
        if let linearKeyPlaneHeight {
            updateLinearExpandedHeight(from: linearKeyPlaneHeight)
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

    // Grid layout metrics (5 columns beside the keyboard)
    static let gridPosterWidth: CGFloat = 210
    static let gridPosterHeight: CGFloat = 315
    static let gridPosterGap: CGFloat = 28
    static let gridColumnCount: CGFloat = 5
    static let gridCardRowWidth = gridPosterWidth * gridColumnCount + gridPosterGap * (gridColumnCount - 1)

    static let keyboardWidth: CGFloat = 520
    // The system search field includes the prompt and dictation affordance in
    // the same toolbar view as the keyboard. Give that view enough room for
    // the full prompt while the outer frame keeps the content column anchored
    // to the keyboard's actual layout width.
    static let keyboardRenderWidth: CGFloat = 840
    static let columnSpacing: CGFloat = 32
    static let gridContentInset: CGFloat = 12
    static let pageInset: CGFloat = 49
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
    let isActive: Bool
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    @AppStorage("nuvio.keyboard.detectedLayout") private var detectedKeyboardMode: TVOSKeyboardLayoutMode = .linear

    @FocusState private var focusedResultID: String?
    @FocusState private var focusedFilterID: String?
    @FocusState private var clearRecentFocused: Bool
    @State private var lastFocusedResultID: String?
    @State private var shouldRestoreResultFocus = false
    @State private var restoreArmTask: Task<Void, Never>?
    @State private var overlayRestoreResultID: String?
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
    @State private var resultsScrollTopGeneration = 0
    @State private var nativeGridColumnCount = Int(NativeSearchGridMetrics.linearColumnCount)
    @State private var discoverOverlayTransitionActive = false
    /// Controls the native `.searchable` keyboard visibility in Linear mode.
    @State private var searchPresented = true
    @State private var linearKeyboardExpandedHeight: CGFloat = 220
    @State private var resultFocusGeneration = 0
    /// The results without unreleased titles, worked out once per results list.
    @State private var resultsMemo = ReleasedTitlesMemo()
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
        isActive: Bool = true,
        onContentClick: @escaping (String, String) -> Void,
        onLongPress: ((NuvioMeta) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.showDiscover = showDiscover
        self.forcedLayoutMode = forcedLayoutMode
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

            if effectiveLayoutMode == .grid {
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
        .onChange(of: focusedResultID) { _, newValue in
            resultFocusGeneration &+= 1
            if let newValue {
                restoreArmTask?.cancel()
                lastFocusedResultID = newValue
                shouldRestoreResultFocus = false
                if effectiveLayoutMode == .linear {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        searchPresented = false
                    }
                }
            } else if lastFocusedResultID != nil {
                scheduleRestoreArm()
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                overlayRestoreGeneration &+= 1
                overlayRestoreResultID = focusedResultID ?? lastFocusedResultID
            } else if !isFullScreenOverlayPresented {
                retryOverlayRestoreAfterReturn()
            }
        }
        .onChange(of: isActive) { _, active in
            if !active { clearOverlayRestoreLeftPressState() }
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
                      overlayRestoreResultID == sourceID,
                      lastFocusedResultID == sourceID,
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
                      lastFocusedResultID == sourceID {
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
                topPadding: 56,
                expandedHeight: linearKeyboardExpandedHeight,
                onSubmit: {
                    viewModel.performSearch(query: viewModel.searchText)
                }
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
                        },
                        onMoveLeft: {
                            transferFocusToGridKeyboard()
                        }
                    )
                    .padding(.horizontal, NativeSearchGridMetrics.gridContentInset)
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
            .frame(width: NativeSearchGridMetrics.gridCardRowWidth + (NativeSearchGridMetrics.gridContentInset * 2), alignment: .leading)
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

    private func transferFilterFocusToGridResults() {
        guard effectiveLayoutMode == .grid,
              isEnabled,
              !isFullScreenOverlayPresented,
              overlayRestoreResultID == nil,
              !overlayFocusRestorationActive,
              !discoverOverlayTransitionActive,
              !viewModel.isLoading,
              viewModel.error == nil,
              let firstResultID = visibleResults.first?.id else { return }

        resultFocusGeneration &+= 1
        let generation = resultFocusGeneration
        restoreArmTask?.cancel()
        shouldRestoreResultFocus = false
        resultsScrollTopGeneration &+= 1

        focusedFilterID = nil
        focusedResultID = firstResultID

        DispatchQueue.main.async {
            guard resultFocusGeneration == generation,
                  effectiveLayoutMode == .grid,
                  isEnabled,
                  !isFullScreenOverlayPresented,
                  overlayRestoreResultID == nil,
                  !overlayFocusRestorationActive,
                  !discoverOverlayTransitionActive,
                  !viewModel.isLoading,
                  viewModel.error == nil,
                  visibleResults.first?.id == firstResultID else { return }
            focusedFilterID = nil
            focusedResultID = firstResultID
        }
    }

    private func transferFocusToGridKeyboard() {
        withAnimation(.easeInOut(duration: 0.25)) {
            searchPresented = true
        }
        focusedResultID = nil
        focusedFilterID = nil
        clearRecentFocused = false
    }

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if overlayRestoreGeneration == generation, overlayRestoreResultID == target {
                overlayRestoreResultID = nil
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
              let target = overlayRestoreResultID else { return }
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
            guard isEnabled, overlayRestoreResultID == focusID else { return }
            overlayRestoreResultID = nil
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

    private func overlayRestoreLeftPressSnapshot() -> NativeSearchLeftPressSnapshot? {
        guard isActive,
              isEnabled,
              !isFullScreenOverlayPresented,
              !discoverOverlayTransitionActive,
              viewModel.hasQuery,
              !viewModel.isLoading,
              viewModel.error == nil,
              let presentationGeneration = pendingOverlayLeftPressPresentationGeneration,
              presentationGeneration == overlayRestorePresentationGeneration,
              overlayRestoreEnteredFullscreenPresentationGeneration == presentationGeneration,
              let sourceFocusID = overlayRestoreLeftPressSourceID,
              sourceFocusID == lastFocusedResultID,
              focusedResultID == nil || focusedResultID == sourceFocusID,
              nativeFocusedResultID == sourceFocusID || (overlayFocusRestorationActive && overlayRestoreResultID == sourceFocusID),
              focusedFilterID == nil,
              !clearRecentFocused,
              overlayRestoreResultID == sourceFocusID || (overlayRestoreResultID == nil && focusedResultID == sourceFocusID),
              let originalResults = overlayRestoreResultsSnapshot,
              originalResults == visibleResultIDs,
              let sourceIndex = visibleResults.firstIndex(where: { $0.id == sourceFocusID }) else {
            return nil
        }

        let columns = effectiveLayoutMode == .grid
            ? Int(NativeSearchGridMetrics.gridColumnCount)
            : nativeGridColumnCount
        let column = sourceIndex % columns
        let destination: NativeSearchLeftPressDestination
        if column == 0 {
            // Grid Search already routes this edge to its keyboard. Linear
            // Search has no poster-grid keyboard edge, so leave it to tvOS.
            guard effectiveLayoutMode == .grid else { return nil }
            destination = .gridKeyboard
        } else {
            destination = .result(visibleResults[sourceIndex - 1].id)
        }

        return NativeSearchLeftPressSnapshot(
            sourceFocusID: sourceFocusID,
            destination: destination,
            presentationGeneration: presentationGeneration,
            returnGeneration: overlayRestoreReturnGeneration,
            resultIDs: visibleResultIDs,
            columns: columns,
            layoutMode: effectiveLayoutMode
        )
    }

    private func handleOverlayRestoreLeftPress(_ snapshot: NativeSearchLeftPressSnapshot) {
        guard isActive,
              isEnabled,
              !isFullScreenOverlayPresented,
              !discoverOverlayTransitionActive,
              viewModel.hasQuery,
              !viewModel.isLoading,
              viewModel.error == nil,
              pendingOverlayLeftPressPresentationGeneration == snapshot.presentationGeneration || completedOverlayLeftPressPresentationGeneration == snapshot.presentationGeneration,
              overlayRestorePresentationGeneration == snapshot.presentationGeneration,
              overlayRestoreReturnGeneration == snapshot.returnGeneration,
              overlayRestoreEnteredFullscreenPresentationGeneration == snapshot.presentationGeneration,
              overlayRestoreLeftPressSourceID == snapshot.sourceFocusID,
              lastFocusedResultID == snapshot.sourceFocusID,
              focusedResultID == nil || focusedResultID == snapshot.sourceFocusID,
              nativeFocusedResultID == snapshot.sourceFocusID || (overlayFocusRestorationActive && overlayRestoreResultID == snapshot.sourceFocusID) || completedOverlayLeftPressPresentationGeneration == snapshot.presentationGeneration,
              overlayRestoreResultID == snapshot.sourceFocusID || focusedResultID == snapshot.sourceFocusID || completedOverlayLeftPressPresentationGeneration == snapshot.presentationGeneration,
              focusedFilterID == nil,
              !clearRecentFocused,
              visibleResultIDs == snapshot.resultIDs,
              snapshot.layoutMode == effectiveLayoutMode,
              snapshot.columns == (effectiveLayoutMode == .grid ? Int(NativeSearchGridMetrics.gridColumnCount) : nativeGridColumnCount) else { return }

        overlayRestoreGeneration &+= 1
        resultFocusGeneration &+= 1
        overlayFocusRestoreStartedGeneration = nil
        restoreArmTask?.cancel()
        shouldRestoreResultFocus = false

        switch snapshot.destination {
        case .result(let target):
            overlayRestoreResultID = target
            lastFocusedResultID = target
            overlayRestoreLeftPressSourceID = target
            pendingOverlayLeftPressPresentationGeneration = snapshot.presentationGeneration
            completedOverlayLeftPressPresentationGeneration = nil
            overlayRestoreRetryKey = "\(snapshot.presentationGeneration)|\(snapshot.returnGeneration)|\(target)"
            overlayFocusRestorationActive = true
            suppressOverlayDismissalExit = true
            restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
        case .gridKeyboard:
            clearOverlayRestoreLeftPressState()
            overlayRestoreResultID = nil
            overlayFocusRestorationActive = false
            suppressOverlayDismissalExit = false
            transferFocusToGridKeyboard()
        }
    }

    // MARK: - Type Filter

    private func typeFilter(width: CGFloat, isGridMode: Bool) -> some View {
        HStack(spacing: 16) {
            ForEach(SearchContentType.allCases) { type in
                GlassChip(
                    title: type.title,
                    isSelected: viewModel.selectedType == type,
                    externalFocus: $focusedFilterID,
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
        .frame(width: width, alignment: .leading)
        .onMoveCommand { direction in
            if isGridMode {
                if direction == .down, focusedFilterID != nil {
                    transferFilterFocusToGridResults()
                } else if direction == .left {
                    let firstFilterID = SearchContentType.allCases.first.map { "type:\($0.rawValue)" }
                    if focusedFilterID == nil || focusedFilterID == firstFilterID {
                        transferFocusToGridKeyboard()
                    }
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
        resultsMemo.update(viewModel.results, revision: viewModel.resultsRevision, hideUnreleased: hideUnreleased)
        return resultsMemo.titles
    }

    private var visibleResultIDs: [String] {
        resultsMemo.update(viewModel.results, revision: viewModel.resultsRevision, hideUnreleased: hideUnreleased)
        return resultsMemo.ids
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
            let reason = viewModel.emptyStateReason ?? .noResults
            centeredState {
                messageState(
                    icon: reason.icon,
                    title: reason.title,
                    subtitle: reason.subtitle(for: viewModel.searchText)
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
                            onFocus: { _ in handleNativeResultFocusChange(true, focusID: item.id) },
                            onBlur: { _ in handleNativeResultFocusChange(false, focusID: item.id) },
                            onLongPress: onLongPress.map { cb in { cb(item) } },
                            forceShowLabels: true,
                            onMove: { direction in
                                if isGridMode {
                                    if index % colCount == 0, direction == .left {
                                        transferFocusToGridKeyboard()
                                    }
                                } else {
                                    if index < colCount, direction == .up {
                                        transferFirstRowFocusToKeyboard()
                                    }
                                }
                            }
                        ) {
                            clearOverlayRestoreLeftPressState()
                            overlayRestoreGeneration &+= 1
                            overlayFocusRestoreStartedGeneration = nil
                            overlayFocusRestorationActive = true
                            suppressOverlayDismissalExit = true
                            overlayRestorePresentationGeneration &+= 1
                            overlayRestoreLeftPressSourceID = item.id
                            overlayRestoreResultsSnapshot = visibleResultIDs
                            overlayRestoreResultID = item.id
                            lastFocusedResultID = item.id
                            viewModel.commitCurrentSearch()
                            onContentClick(item.id, item.type)
                        }
                        .accessibilityIdentifier("native-search-result-\(item.id)")
                        // Kept as it was while it shows the same: every move along the results
                        // redraws this screen, which rebuilt every card on it. The lock for
                        // putting focus back stays outside it.
                        .cardSnapshot(GridCardSnapshotKey(
                            meta: item,
                            index: index,
                            columns: colCount,
                            mode: isGridMode ? 1 : 0,
                            retainsFocusAppearance: overlayRestoreResultID == item.id
                        ))
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
        Array(
            repeating: GridItem(.fixed(NativeSearchGridMetrics.gridPosterWidth), spacing: NativeSearchGridMetrics.gridPosterGap, alignment: .top),
            count: Int(NativeSearchGridMetrics.gridColumnCount)
        )
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
    var onMoveLeft: (() -> Void)? = nil
    @FocusState private var focusedSuggestionID: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                GlassChip(
                    title: "\u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}",
                    isSelected: false,
                    leadingSystemImage: "magnifyingglass",
                    externalFocus: $focusedSuggestionID,
                    focusValue: "query"
                ) {
                    onSubmit()
                }
                .fixedSize(horizontal: true, vertical: false)

                ForEach(suggestions, id: \.self) { title in
                    GlassChip(
                        title: title,
                        isSelected: false,
                        externalFocus: $focusedSuggestionID,
                        focusValue: title
                    ) {
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
        .onMoveCommand { direction in
            if direction == .left {
                if focusedSuggestionID == nil || focusedSuggestionID == "query" {
                    onMoveLeft?()
                }
            }
        }
    }
}

// MARK: - Native Search Keyboard Hosts

/// Shared tvOS `.searchable` host for horizontal keyboards, with caller-measured height.
/// Bounded height with collapsible container.
struct NativeSearchKeyboardHost: View {
    @Binding var text: String
    let prompt: String
    @Binding var isPresented: Bool
    let isDisabled: Bool
    var topPadding: CGFloat = 56
    /// Defaults to a compact height until the detector measures the native key plane.
    var expandedHeight: CGFloat = 220
    var collapsedHeight: CGFloat = 110
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .searchable(text: $text, prompt: prompt)
                .onSubmit(of: .search) {
                    onSubmit?()
                }
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
    var onSubmit: (() -> Void)? = nil

    init(
        text: Binding<String>,
        prompt: String,
        isDisabled: Bool,
        topPadding: CGFloat = 68,
        width: CGFloat = 780,
        renderWidth: CGFloat? = nil,
        height: CGFloat = 780,
        onSubmit: (() -> Void)? = nil
    ) {
        _text = text
        self.prompt = prompt
        self.isDisabled = isDisabled
        self.topPadding = topPadding
        self.width = width
        self.renderWidth = renderWidth
        self.height = height
        self.onSubmit = onSubmit
    }

    var body: some View {
        NavigationStack {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .searchable(text: $text, prompt: prompt)
                .onSubmit(of: .search) {
                    onSubmit?()
                }
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
