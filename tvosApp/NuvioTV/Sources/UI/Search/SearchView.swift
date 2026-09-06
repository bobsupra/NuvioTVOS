import SwiftUI

/// Same poster geometry as the See All catalog and Grid Home. Seven columns fit
/// only because of `pageInset` — the old 80pt inset left room for six.
private enum SearchGridMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28
    static let columnCount: CGFloat = 7
    /// Width of the seven visible cards, from the first card's leading edge to
    /// the last card's trailing edge. Header controls use this too so their
    /// right edge lands directly above the last card.
    static let cardRowWidth = posterWidth * columnCount + posterGap * (columnCount - 1)
    static let gridContentInset: CGFloat = 12
    /// Leading/trailing inset for the whole screen. With the grid's own 12pt
    /// (which keeps a focused card's 1.06 scale from clipping) this is the 48pt
    /// gutter Grid Home uses, so posters line up across the two screens.
    static let pageInset: CGFloat = 36
}

struct SearchView: View {
    @StateObject private var viewModel: SearchViewModel
    let showDiscover: Bool
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil

    @FocusState private var searchBarFocused: Bool
    @FocusState private var focusedResultID: String?
    @FocusState private var clearRecentFocused: Bool
    /// Last card focused in the results grid, kept so returning from details
    /// (which steals focus and nils `focusedResultID`) restores that card
    /// instead of snapping back to the first result.
    @State private var lastFocusedResultID: String?
    @State private var shouldRestoreResultFocus = false
    /// Debounced arming of the restore flag: a rapid vertical move blips
    /// `focusedResultID` to nil while the next lazy cell materializes, and
    /// arming instantly on that blip bounces focus back to the previous card.
    @State private var restoreArmTask: Task<Void, Never>?
    /// Card to actively re-focus once the Details overlay dismisses; captured
    /// when the tab view gets disabled (overlay up), consumed on re-enable.
    @State private var overlayRestoreResultID: String?
    @State private var overlayRestoreGeneration = 0
    @State private var discoverOverlayTransitionActive = false
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false

    init(viewModel: SearchViewModel, showDiscover: Bool = true, onContentClick: @escaping (String, String) -> Void, onLongPress: ((NuvioMeta) -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.showDiscover = showDiscover
        self.onContentClick = onContentClick
        self.onLongPress = onLongPress
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                header
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(overlayRestoreResultID != nil || discoverOverlayTransitionActive)
                    .zIndex(1)

                if viewModel.hasQuery {
                    typeFilter
                        .frame(width: SearchGridMetrics.cardRowWidth, alignment: .leading)
                        .padding(.horizontal, SearchGridMetrics.gridContentInset)
                        .disabled(overlayRestoreResultID != nil)
                        .zIndex(1)
                    resultsContainer
                        .zIndex(0)
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
            .padding(.horizontal, SearchGridMetrics.pageInset)
            .padding(.top, 56)
            // Let the results viewport use the space below tvOS's bottom safe
            // area instead of leaving a black bar at the screen edge.
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .onAppear {
            viewModel.reloadRecent()
        }
        .onDisappear {
            searchBarFocused = false
        }
        .onChange(of: focusedResultID) { _, newValue in
            if let newValue {
                restoreArmTask?.cancel()
                lastFocusedResultID = newValue
                shouldRestoreResultFocus = false
                // Restoration complete -- lift the focus restriction.
                if isEnabled, newValue == overlayRestoreResultID { overlayRestoreResultID = nil }
            } else if lastFocusedResultID != nil {
                scheduleRestoreArm()
            }
        }
        // Overlay dismissal re-places focus geometrically without consulting
        // `defaultFocus`. While `overlayRestoreResultID` is set every other
        // card is unfocusable, so the engine can only land back on the saved
        // card -- no scroll-to-top flash. See TVHomeView for the full story.
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                overlayRestoreGeneration &+= 1
                overlayRestoreResultID = focusedResultID ?? lastFocusedResultID
            } else if let target = overlayRestoreResultID {
                restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
            }
        }
    }

    /// Arms the restore flag only after focus has stayed off the cards long
    /// enough that the nil is a real departure (menu/tab) instead of the
    /// one-frame blip of a rapid vertical move between lazy cells.
    private func scheduleRestoreArm() {
        guard lastFocusedResultID != nil, focusedResultID == nil else { return }
        restoreArmTask?.cancel()
        restoreArmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, focusedResultID == nil else { return }
            shouldRestoreResultFocus = true
        }
    }

    private func restoreOverlayFocus(to target: String, generation: Int) {
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
    }

    // MARK: - Header + glass search bar

    private var header: some View {
        searchBar
    }

    /// Uses a real tvOS editor so the system keyboard and Siri dictation stay
    /// attached to the search surface. The editor is nearly transparent while
    /// the app-owned glass content preserves the existing visual design.
    private var searchBar: some View {
        ZStack(alignment: .leading) {
            TextField(
                "",
                text: $viewModel.searchText
            )
            .textFieldStyle(.plain)
            .focused($searchBarFocused)
            .focusEffectDisabledIfAvailable()
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .frame(maxWidth: .infinity, minHeight: 72)
            // Keep the native editor focusable without allowing tvOS's white
            // focus platter to cover the custom glass treatment.
            .opacity(0.02)

            // Glass overlay: magnifier + typed text / placeholder + clear.
            HStack(spacing: 18) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))

                Text(
                    viewModel.searchText.isEmpty
                        ? L10n.string("search_placeholder", fallback: "Search movies & series")
                        : viewModel.searchText
                )
                    .font(.system(size: 30, weight: .regular))
                    .foregroundColor(viewModel.searchText.isEmpty ? .white.opacity(0.45) : .white)
                    .lineLimit(1)
                    .allowsHitTesting(false)

                Spacer(minLength: 0)

                if viewModel.hasQuery {
                    Button {
                        viewModel.clear()
                        searchBarFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                }
            }
        }
        .padding(.horizontal, 34)
        .frame(height: 72)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCapsule(focused: searchBarFocused))
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
    }

    // MARK: - Results / states

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
                        fallback: "No results for “%@”",
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
        ScrollView {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: SearchGridMetrics.posterGap) {
                ForEach(visibleResults) { item in
                    PosterGridCard(
                        meta: item,
                        width: SearchGridMetrics.posterWidth,
                        height: SearchGridMetrics.posterHeight,
                        externalFocus: $focusedResultID,
                        retainFocusAppearance: overlayRestoreResultID == item.id,
                        onLongPress: onLongPress.map { cb in { cb(item) } },
                        forceShowLabels: true
                    ) {
                        overlayRestoreResultID = item.id
                        lastFocusedResultID = item.id
                        onContentClick(item.id, item.type)
                    }
                    .disabled(overlayRestoreResultID != nil && overlayRestoreResultID != item.id)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, SearchGridMetrics.gridContentInset)
        }
        .focusSection()
        .defaultFocusIfAvailable($focusedResultID, defaultResultFocusID)
    }

    /// Card the grid should focus when it (re)gains focus: the card the user
    /// left on when armed and still present in the results, else the first one.
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
            .adaptive(minimum: SearchGridMetrics.posterWidth, maximum: SearchGridMetrics.posterWidth),
            spacing: SearchGridMetrics.posterGap,
            alignment: .top
        )]
    }

    // MARK: Recent searches (shown above Discover when idle)

    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.string("search_recent_title", fallback: "Recent searches"))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))
            }

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

// MARK: - Result card

// MARK: - Glass components

struct GlassChip: View {
    let title: String
    let isSelected: Bool
    var leadingSystemImage: String? = nil
    var externalFocus: FocusState<String?>.Binding? = nil
    var focusValue: String = ""
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let leadingSystemImage {
                    Image(systemName: leadingSystemImage)
                        .font(.system(size: 20, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
            }
            .foregroundColor(isSelected || focused ? .black : .white.opacity(0.85))
            .padding(.horizontal, 30)
            .frame(height: 60)
            .modifier(GlassChipBackground(filled: isSelected || focused))
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: focusValue))
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// Liquid Glass capsule for the search bar, with a material fallback for tvOS < 26.
struct GlassCapsule: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        glassed(content)
            .overlay(
                Capsule().stroke(
                    focused ? AppFocusOutline.color : Color.white.opacity(0.18),
                    lineWidth: focused ? AppFocusOutline.width : 1
                )
            )
            .scaleEffect(focused ? 1.012 : 1.0)
            .animation(.easeOut(duration: 0.18), value: focused)
    }

    @ViewBuilder
    private func glassed(_ content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Full-width rounded-rectangle glass field for Search (Netflix-style), with a
/// material fallback for tvOS < 26.
struct GlassSearchBar: ViewModifier {
    let focused: Bool

    func body(content: Content) -> some View {
        glassed(content)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(
                        focused ? AppFocusOutline.color : Color.white.opacity(0.18),
                        lineWidth: focused ? AppFocusOutline.width : 1
                    )
            )
            .scaleEffect(focused ? 1.008 : 1.0)
            .animation(.easeOut(duration: 0.18), value: focused)
    }

    @ViewBuilder
    private func glassed(_ content: Content) -> some View {
        if #available(tvOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }
}

struct GlassChipBackground: ViewModifier {
    let filled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if filled {
            content.background(Color.white, in: Capsule())
        } else if #available(tvOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

extension View {
    /// Disables the system's default tvOS focus highlight (the bloated light
    /// "lift" card) so custom focus styling isn't drawn over. No-op below tvOS 17.
    @ViewBuilder
    func focusEffectDisabledIfAvailable() -> some View {
        if #available(tvOS 17.0, *) {
            focusEffectDisabled()
        } else {
            self
        }
    }

    /// Lets focused content (which scales up 1.06) spill outside the scroll
    /// view's bounds instead of being clipped. No-op below tvOS 17.
    @ViewBuilder
    func scrollClipDisabledIfAvailable() -> some View {
        if #available(tvOS 17.0, *) {
            scrollClipDisabled()
        } else {
            self
        }
    }
}
