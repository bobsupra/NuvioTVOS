import SwiftUI

/// Netflix-style alternative to `SearchView`: an always-visible, embedded
/// on-screen keyboard (no modal system keyboard) with results split into a
/// text index on the left and a poster grid on the right, mirroring the
/// tvOS Netflix search screen. Wired to the same `CatalogRepository` search
/// use case as `SearchView` via `NetflixSearchViewModel`.
///
/// Reuses `PosterGridCard`, `GlassChip`, `GlassChipBackground`,
/// `GlassSearchBar`, `PosterCardButtonStyle`, `DiscoverSection`,
/// `SearchContentType`, `ContentReleasePolicy` and the hidden-text-field
/// dictation fallback from `SearchView.swift` rather than duplicating them.
/// The keyboard is the one place that can't reuse `GlassChip`: it needs
/// fixed-width keys to guarantee a no-scroll fit (see `NetflixKeyboardKey`).
private enum NetflixSearchMetrics {
    /// Sits on top of tvOS's own ~80pt overscan safe area, so this only needs
    /// to be big enough that a focused key/card's scale-up doesn't visually
    /// touch the safe-area boundary.
    static let pageInset: CGFloat = 8
    static let posterWidth: CGFloat = 190
    static let posterHeight: CGFloat = 285
    static let posterGap: CGFloat = 24
    static let listWidth: CGFloat = 440
    static let columnGap: CGFloat = 32
    /// Keys are sized so all 29 of them (26 letters + 123/Space/delete) fit on
    /// one 1080p line. `KeyboardFlowLayout` wraps to a second line rather than
    /// scrolling if a narrower viewport can't fit them.
    static let keyHeight: CGFloat = 54
    static let letterKeyWidth: CGFloat = 46
    static let toggleKeyWidth: CGFloat = 76
    static let spaceKeyWidth: CGFloat = 116
    static let deleteKeyWidth: CGFloat = 64
    static let keyHGap: CGFloat = 8
    static let keyVGap: CGFloat = 10
}

private enum NetflixKeyboardMode {
    case letters, numbers

    var keys: [String] {
        switch self {
        case .letters: return (UnicodeScalar("a").value...UnicodeScalar("z").value)
            .compactMap { UnicodeScalar($0).map(String.init) }
        case .numbers: return (0...9).map(String.init)
        }
    }

    var toggleLabel: String {
        switch self {
        case .letters: return "123"
        case .numbers: return "ABC"
        }
    }
}

struct NetflixSearchView: View {
    @StateObject private var viewModel: NetflixSearchViewModel
    let showDiscover: Bool
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    /// One shared focus id-space for both the text list and the poster grid,
    /// namespaced ("list:"/"grid:") so the same result can be focused in
    /// either column without the two bindings fighting over one id.
    @FocusState private var focusedItemID: String?
    @FocusState private var clearRecentFocused: Bool
    @FocusState private var dictateFocused: Bool
    @State private var keyboardMode: NetflixKeyboardMode = .letters
    /// Same overlay-restore dance as `SearchView`: Details is a sibling
    /// overlay (not a navigation push), so returning from it needs to
    /// re-place focus geometrically instead of snapping to the first result.
    @State private var lastFocusedItemID: String?
    @State private var shouldRestoreFocus = false
    @State private var overlayRestoreItemID: String?
    @State private var overlayRestoreGeneration = 0
    @State private var discoverOverlayTransitionActive = false
    @Environment(\.isEnabled) private var isEnabled
    /// True while the hidden text field is first responder, i.e. the system
    /// keyboard (with its own Siri dictation button) is covering the screen
    /// as a dictation fallback. The embedded keyboard has no way to hook the
    /// remote's physical mic button itself.
    @State private var systemDictationActive = false
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
                keyboard
                    .disabled(overlayRestoreItemID != nil || discoverOverlayTransitionActive)
                Rectangle()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: 1)

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

            // Off-screen; becomes first responder only for the dictation
            // fallback (see `dictateButton`). Reused from `SearchView.swift`.
            HiddenSearchTextField(text: $viewModel.searchText, isEditing: $systemDictationActive)
                .frame(width: 1, height: 1)
                .offset(x: -4_000)
                .allowsHitTesting(false)
        }
        .onAppear {
            viewModel.reloadRecent()
        }
        .onChange(of: focusedItemID) { newValue in
            if let newValue {
                lastFocusedItemID = newValue
                shouldRestoreFocus = false
                if isEnabled, newValue == overlayRestoreItemID { overlayRestoreItemID = nil }
            } else if lastFocusedItemID != nil {
                shouldRestoreFocus = true
            }
        }
        .onChange(of: isEnabled) { enabled in
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

    // MARK: - Header: query readout + dictate

    private var queryHeader: some View {
        HStack(spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Text(
                    viewModel.searchText.isEmpty
                        ? L10n.string("search_placeholder", fallback: "Search for movies and TV shows")
                        : viewModel.searchText
                )
                    .textCase(.uppercase)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(viewModel.searchText.isEmpty ? .white.opacity(0.45) : .white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 26)
            .frame(height: 58)
            .frame(maxWidth: 720, alignment: .leading)
            .modifier(GlassSearchBar(focused: false))

            Spacer(minLength: 0)

            dictateButton
        }
    }

    private var dictateButton: some View {
        Button {
            systemDictationActive = true
        } label: {
            HStack(spacing: 12) {
                Text(L10n.string("search_dictate_hint", fallback: "Press to dictate"))
                    .font(.system(size: 20, weight: .medium))
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(6)
                    .background(Circle().fill(Color.white.opacity(dictateFocused ? 1 : 0.16)))
                    .foregroundColor(dictateFocused ? .black : .white)
            }
            .foregroundColor(.white.opacity(0.75))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($dictateFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(dictateFocused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.14), value: dictateFocused)
    }

    // MARK: - Embedded keyboard

    private var keyboard: some View {
        KeyboardFlowLayout(
            hSpacing: NetflixSearchMetrics.keyHGap,
            vSpacing: NetflixSearchMetrics.keyVGap
        ) {
            NetflixKeyboardKey(
                label: keyboardMode.toggleLabel,
                width: NetflixSearchMetrics.toggleKeyWidth
            ) {
                keyboardMode = keyboardMode == .letters ? .numbers : .letters
            }

            NetflixKeyboardKey(
                label: L10n.string("search_keyboard_space", fallback: "Space"),
                width: NetflixSearchMetrics.spaceKeyWidth
            ) {
                viewModel.typeCharacter(" ")
            }

            ForEach(keyboardMode.keys, id: \.self) { key in
                NetflixKeyboardKey(
                    label: key,
                    width: NetflixSearchMetrics.letterKeyWidth
                ) {
                    viewModel.typeCharacter(key)
                }
            }

            NetflixKeyboardKey(
                label: "",
                systemImage: "delete.left",
                width: NetflixSearchMetrics.deleteKeyWidth
            ) {
                viewModel.deleteLastCharacter()
            }
        }
        .focusSection()
    }

    // MARK: - Type filter

    private var typeFilterRow: some View {
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
                ForEach(visibleResults) { item in
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
            // Top room so a focused card's 1.06 scale isn't clipped by the
            // viewport edge; bottom room so the last row can scroll clear.
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .focusSection()
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

    private var gridColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: NetflixSearchMetrics.posterWidth, maximum: NetflixSearchMetrics.posterWidth),
            spacing: NetflixSearchMetrics.posterGap,
            alignment: .top
        )]
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

// MARK: - Keyboard key

/// Fixed-width keyboard key. `GlassChip` sizes itself from its text plus 30pt
/// of horizontal padding, which is far too wide for single characters, so keys
/// take an explicit width instead.
private struct NetflixKeyboardKey: View {
    let label: String
    var systemImage: String? = nil
    let width: CGFloat
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .semibold))
                } else {
                    Text(label)
                        .font(.system(size: 24, weight: .semibold))
                }
            }
            .foregroundColor(focused ? .black : .white.opacity(0.85))
            .frame(width: width, height: NetflixSearchMetrics.keyHeight)
            .modifier(GlassChipBackground(filled: focused))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.08 : 1.0)
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}

// MARK: - Wrapping keyboard layout

/// Lays keys out left-to-right, wrapping onto another line when the next key
/// wouldn't fit. The keyboard must never scroll — every key has to be visible
/// and directly reachable — so overflow becomes a second row instead.
private struct KeyboardFlowLayout: Layout {
    let hSpacing: CGFloat
    let vSpacing: CGFloat

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(for: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { $0 + $1.height }
            + vSpacing * CGFloat(max(0, rows.count - 1))
        let widest = rows.map(\.width).max() ?? 0
        return CGSize(width: maxWidth.isFinite ? maxWidth : widest, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + hSpacing
            }
            y += row.height + vSpacing
        }
    }

    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthIfAppended = current.indices.isEmpty
                ? size.width
                : current.width + hSpacing + size.width

            if !current.indices.isEmpty, widthIfAppended > maxWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = widthIfAppended
                current.height = max(current.height, size.height)
            }
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
