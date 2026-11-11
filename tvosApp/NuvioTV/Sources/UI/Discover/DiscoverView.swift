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
    let isBesideKeyboard: Bool
    let columnCount: Int?
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    /// Lets an embedded host react to moving into a card or out of the
    /// Discover controls entirely (the Netflix Search host uses this to
    /// collapse/restore its keyboard).
    var onCardFocus: (() -> Void)? = nil
    var onFilterFocus: (() -> Void)? = nil
    var onFocusExit: (() -> Void)? = nil
    @StateObject private var viewModel = DiscoverViewModel()
    @FocusState private var focusedCardID: String?
    @FocusState private var focusedFilterID: String?
    @State private var focusedElementID: String?
    /// Cards can briefly blur while a rapid remote swipe realizes the next
    /// grid cell. Only treat it as leaving Discover if it remains unfocused.
    @State private var focusChangeGeneration = 0
    /// Last card focused in the grid, kept so returning from details (which
    /// steals focus and nils `focusedCardID`) restores that card instead of
    /// snapping back to the top of the grid.
    @State private var lastFocusedCardID: String?
    @State private var shouldRestoreFocus = false
    /// Debounced arming of the restore flag: a rapid vertical move blips
    /// `focusedCardID` to nil while the next lazy cell materializes, and
    /// arming instantly on that blip bounces focus back to the previous card.
    @State private var restoreArmTask: Task<Void, Never>?
    /// Card to actively re-focus once the Details overlay dismisses; captured
    /// when the tab view gets disabled (overlay up), consumed on re-enable.
    @State private var overlayRestoreCardID: String?
    @State private var overlayRestoreGeneration = 0
    @State private var scrollToTopGeneration = 0
    @State private var filterResultHandoffGeneration = 0
    /// The items without unreleased titles, worked out once per list.
    @State private var itemsMemo = ReleasedTitlesMemo()
    @Environment(\.isEnabled) private var isEnabled
    @Binding private var parentTransitionActive: Bool
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false

    init(
        onContentClick: @escaping (String, String) -> Void,
        isBesideKeyboard: Bool = false,
        columnCount: Int? = nil,
        onLongPress: ((NuvioMeta) -> Void)? = nil,
        onCardFocus: (() -> Void)? = nil,
        onFilterFocus: (() -> Void)? = nil,
        onFocusExit: (() -> Void)? = nil,
        parentTransitionActive: Binding<Bool>
    ) {
        self.onContentClick = onContentClick
        self.isBesideKeyboard = isBesideKeyboard
        self.columnCount = columnCount
        self.onLongPress = onLongPress
        self.onCardFocus = onCardFocus
        self.onFilterFocus = onFilterFocus
        self.onFocusExit = onFocusExit
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
        .onChange(of: focusedCardID) { _, newValue in
            if let newValue {
                restoreArmTask?.cancel()
                lastFocusedCardID = newValue
                shouldRestoreFocus = false
            } else if lastFocusedCardID != nil {
                scheduleRestoreArm()
            }
        }
        .onChange(of: focusedElementID) { oldValue, newValue in
            if newValue?.hasPrefix("card:") == true {
                onCardFocus?()
            } else if newValue?.hasPrefix("filter:") == true {
                onFilterFocus?()
            } else if oldValue?.hasPrefix("filter:") == true,
                      newValue == nil,
                      !isBesideKeyboard {
                // Lazy grid cells can briefly disappear from the focus tree
                // during a rapid scroll. A card blur is therefore not proof
                // that focus left Discover; only the fixed filter bar can
                // reliably hand focus back to the host keyboard.
                onFocusExit?()
            }
        }
        // Overlay dismissal re-places focus geometrically without consulting
        // `defaultFocus`. While `overlayRestoreCardID` is set every other card
        // is unfocusable, so the engine can only land back on the saved card
        // -- no scroll-to-top flash. See TVHomeView for the full story.
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                overlayRestoreGeneration &+= 1
                overlayRestoreCardID = focusedCardID ?? lastFocusedCardID
            } else if let target = overlayRestoreCardID {
                restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
            }
        }
        .onExitCommand(perform: canHandleExitCommand ? scrollDiscoverToTop : nil)
    }

    /// Arms the restore flag only after focus has stayed off the cards long
    /// enough that the nil is a real departure (menu/tab) instead of the
    /// one-frame blip of a rapid vertical move between lazy cells.
    private func scheduleRestoreArm() {
        guard lastFocusedCardID != nil, focusedCardID == nil else { return }
        restoreArmTask?.cancel()
        restoreArmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, focusedCardID == nil else { return }
            shouldRestoreFocus = true
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

    /// Consume Menu only while Discover has something to back out of. Once the
    /// first card is focused, leaving the handler nil lets the enclosing tab
    /// view reveal its sidebar on the next Menu press.
    private var canHandleExitCommand: Bool {
        guard isEnabled,
              overlayRestoreCardID == nil,
              !parentTransitionActive,
              let first = visibleItems.first else { return false }
        return focusedCardID != first.id || focusedElementID?.hasPrefix("filter:") == true
    }

    /// Back on Discover keeps the keyboard state unchanged and returns the
    /// vertical grid/focus to its first card.
    private func scrollDiscoverToTop() {
        scrollToTopGeneration &+= 1
        shouldRestoreFocus = false
        guard let first = visibleItems.first else { return }
        focusedCardID = first.id
        focusedElementID = "card:\(first.id)"
    }

    private func transferFilterFocusToFirstResult() {
        guard isEnabled,
              isBesideKeyboard,
              !parentTransitionActive,
              overlayRestoreCardID == nil,
              !viewModel.isLoading,
              let firstItem = visibleItems.first else { return }

        filterResultHandoffGeneration &+= 1
        let generation = filterResultHandoffGeneration
        restoreArmTask?.cancel()
        shouldRestoreFocus = false
        scrollToTopGeneration &+= 1

        focusedFilterID = nil
        focusedElementID = "card:\(firstItem.id)"
        focusedCardID = firstItem.id

        DispatchQueue.main.async {
            guard filterResultHandoffGeneration == generation,
                  isEnabled,
                  isBesideKeyboard,
                  !parentTransitionActive,
                  overlayRestoreCardID == nil,
                  !viewModel.isLoading,
                  visibleItems.first?.id == firstItem.id else { return }
            focusedFilterID = nil
            focusedElementID = "card:\(firstItem.id)"
            focusedCardID = firstItem.id
        }
    }

    // MARK: - Filters (dropdown menus)

    private var filterBar: some View {
        HStack(spacing: 16) {
            FilterMenu(
                label: viewModel.currentTypeTitle,
                onFocusChange: { updateDiscoverFocus("filter:type", isFocused: $0) },
                externalFocus: $focusedFilterID,
                focusValue: "filter:type"
            ) {
                ForEach(viewModel.typeOptions, id: \.self) { type in
                    Button { viewModel.setType(type) } label: {
                        menuItem(viewModel.typeTitle(for: type), selected: viewModel.selectedType == type)
                    }
                }
            }

            if !viewModel.catalogOptions.isEmpty {
                FilterMenu(
                    label: viewModel.selectedCatalog?.catalogName ?? L10n.string("tvos_discover_popular", fallback: "Popular"),
                    onFocusChange: { updateDiscoverFocus("filter:sort", isFocused: $0) },
                    externalFocus: $focusedFilterID,
                    focusValue: "filter:sort"
                ) {
                    ForEach(viewModel.catalogOptions) { catalog in
                        Button { viewModel.setCatalog(catalog) } label: {
                            menuItem(catalog.catalogName, selected: viewModel.selectedCatalog?.key == catalog.key)
                        }
                    }
                }
            }

            if !viewModel.genreOptions.isEmpty {
                FilterMenu(
                    label: viewModel.selectedGenre ?? L10n.string("tvos_discover_all_genres", fallback: "All Genres"),
                    onFocusChange: { updateDiscoverFocus("filter:genre", isFocused: $0) },
                    externalFocus: $focusedFilterID,
                    focusValue: "filter:genre"
                ) {
                    if !viewModel.isGenreRequired {
                        Button { viewModel.setGenre(nil) } label: {
                            menuItem(
                                L10n.string("tvos_discover_all_genres", fallback: "All Genres"),
                                selected: viewModel.selectedGenre == nil
                            )
                        }
                    }
                    ForEach(viewModel.genreOptions, id: \.self) { genre in
                        Button { viewModel.setGenre(genre) } label: {
                            menuItem(genre, selected: viewModel.selectedGenre == genre)
                        }
                    }
                }
            }
        }
        .onMoveCommand { direction in
            guard isBesideKeyboard else { return }
            let isTypeFilter = focusedFilterID == "filter:type" || focusedElementID == "filter:type"
            if direction == .left, isTypeFilter {
                onFocusExit?()
            } else if direction == .down, isTypeFilter {
                transferFilterFocusToFirstResult()
            }
        }
    }

    private func menuItem(_ title: String, selected: Bool) -> some View {
        Text(selected ? "✓  \(title)" : title)
    }

    // MARK: - Content

    private var visibleItems: [NuvioMeta] {
        itemsMemo.update(viewModel.items, revision: viewModel.itemsRevision, hideUnreleased: hideUnreleased)
        return itemsMemo.titles
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
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 1)
                    .id("discover-grid-top")

                LazyVGrid(columns: columns, alignment: .leading, spacing: posterGap) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        DiscoverCard(
                            posterWidth: posterWidth,
                            meta: item,
                            externalFocus: $focusedCardID,
                            onFocusChange: { updateDiscoverFocus("card:\(item.id)", isFocused: $0) },
                            retainFocusAppearance: overlayRestoreCardID == item.id,
                            onLongPress: onLongPress.map { cb in { cb(item) } },
                            onMove: { direction in
                                if isBesideKeyboard {
                                    let colCount = columnCount ?? 5
                                    if index % colCount == 0, direction == .left {
                                        focusedCardID = nil
                                        onFocusExit?()
                                    }
                                }
                            }
                        ) {
                            parentTransitionActive = true
                            overlayRestoreCardID = item.id
                            lastFocusedCardID = item.id
                            onContentClick(item.id, item.type)
                        }
                        // Kept as it was while it shows the same: every move in the grid redraws
                        // Discover, which rebuilt every card on screen. The lock for putting
                        // focus back stays outside it.
                        .cardSnapshot(GridCardSnapshotKey(
                            meta: item,
                            index: index,
                            columns: columnCount ?? 0,
                            mode: isBesideKeyboard ? 1 : 0,
                            retainsFocusAppearance: overlayRestoreCardID == item.id,
                            width: posterWidth
                        ))
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
            .onChange(of: scrollToTopGeneration) { _, _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo("discover-grid-top", anchor: .top)
                }
            }
        }
        // This is a vertical grid beneath fixed controls. Its focused cards
        // must remain inside the viewport instead of spilling upward over the
        // Movies / Popular / All Genres menus.
        .scrollClipDisabled(false)
        .focusSection()
        .defaultFocusIfAvailable($focusedCardID, defaultCardFocusID)
    }

    private var defaultCardFocusID: String? {
        if shouldRestoreFocus,
           let saved = lastFocusedCardID,
           visibleItems.contains(where: { $0.id == saved }) {
            return saved
        }
        return visibleItems.first?.id
    }

    private var posterWidth: CGFloat { DiscoverGridMetrics.posterWidth }
    private var posterGap: CGFloat { isBesideKeyboard || columnCount != nil ? 28 : DiscoverGridMetrics.posterGap }

    private var columns: [GridItem] {
        let count = columnCount ?? (isBesideKeyboard ? 5 : nil)
        if let count {
            return Array(repeating: GridItem(.fixed(posterWidth), spacing: posterGap, alignment: .top), count: count)
        }
        return [GridItem(
            .adaptive(minimum: posterWidth, maximum: posterWidth),
            spacing: posterGap,
            alignment: .top
        )]
    }

    /// Adjacent controls report blur/focus separately. Defer a blur by one
    /// focus pass so a card-to-filter move remains inside Discover rather than
    /// briefly looking like focus left the section altogether.
    private func updateDiscoverFocus(_ id: String, isFocused: Bool) {
        if isFocused {
            focusChangeGeneration &+= 1
            focusedElementID = id
            if id.hasPrefix("card:") {
                let cardID = String(id.dropFirst(5))
                if overlayRestoreCardID == cardID {
                    overlayRestoreCardID = nil
                    parentTransitionActive = false
                }
            }
        } else if focusedElementID == id {
            let generation = focusChangeGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                if focusChangeGeneration == generation, focusedElementID == id {
                    focusedElementID = nil
                }
            }
        }
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
    var onFocusChange: ((Bool) -> Void)? = nil
    var externalFocus: FocusState<String?>.Binding? = nil
    var focusValue: String = ""
    @ViewBuilder var menu: () -> MenuContent
    @State private var showOptions = false
    @FocusState private var focused: Bool

    var body: some View {
        Button { showOptions = true } label: { chipLabel }
            .buttonStyle(PosterCardButtonStyle())
            .focused($focused)
            .modifier(ExternalFocusBinding(binding: externalFocus, id: focusValue))
            .focusEffectDisabledIfAvailable()
            .scaleEffect(focused ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.14), value: focused)
            .confirmationDialog(label, isPresented: $showOptions, titleVisibility: .visible, actions: menu)
            .onChange(of: focused) { _, isFocused in onFocusChange?(isFocused) }
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
    var posterWidth: CGFloat = DiscoverGridMetrics.posterWidth
    private var posterHeight: CGFloat { posterWidth * 1.5 }
    let meta: NuvioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
    var onFocusChange: ((Bool) -> Void)? = nil
    var retainFocusAppearance = false
    var onLongPress: (() -> Void)? = nil
    var onMove: ((MoveCommandDirection) -> Void)? = nil
    let action: () -> Void
    @FocusState private var focused: Bool
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @AppStorage(SettingsKey.liquidGlassCards) private var liquidGlassCards = true
    @AppStorage(SettingsKey.customPosterURLPattern) private var customPosterURLPattern = ""
    @AppStorage(SettingsKey.customPosterEnabledScreens) private var customPosterEnabledScreens = "all"

    private var customPosterArtworkURL: String? {
        CustomPosterURLResolver.resolve(
            pattern: customPosterURLPattern,
            meta: meta,
            screen: .search,
            enabledScreens: customPosterEnabledScreens,
            shape: meta.tileShape == .square ? "square" : "poster"
        )
    }

    private var cardCornerRadius: CGFloat {
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
    }

    private var fallbackMediaSymbol: String {
        let type = DiscoverViewModel.discoverSelectionType(meta.type)
        return type == "series" || type == "tv" ? "tv" : "film"
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                CachedPosterArtwork(
                    urlString: customPosterArtworkURL ?? meta.posterUrl,
                    fallbackURLString: customPosterArtworkURL == nil ? nil : meta.posterUrl,
                    width: posterWidth,
                    height: posterHeight,
                    maximumWidth: posterWidth
                ) {
                    ZStack {
                        Rectangle().fill(Color.white.opacity(0.07))
                        Image(systemName: fallbackMediaSymbol)
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
                .frame(width: posterWidth, height: posterHeight)
                .clipShape(shape)
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: cardCornerRadius,
                        isFocused: showsFocusedAppearance,
                        isEnabled: liquidGlassCards,
                        coveredByArtwork: true
                    )
                )
                .overlay(alignment: .topTrailing) {
                    WatchedCheckmarkBadge(meta: meta)
                }
                .overlay(
                    shape.stroke(showsFocusedAppearance ? focusBorderColor : .clear, lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width)
                )
                .shadow(color: .black.opacity(showsFocusedAppearance ? 0.5 : 0.2), radius: showsFocusedAppearance ? 16 : 6)

                if posterLabels {
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(meta.name, size: 20, weight: .semibold,
                                    color: showsFocusedAppearance ? .white : .white.opacity(0.78),
                                    isActive: showsFocusedAppearance)
                        if let year = meta.year {
                            Text(String(year))
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    }
                    .frame(width: posterWidth, alignment: .leading)
                }
            }
            .scaleEffect(showsFocusedAppearance ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: meta.id))
        .focusEffectDisabledIfAvailable()
        .modifier(OptionalMoveCommandHandler(handler: onMove))
        .titleActionsContextMenu(
            meta: meta,
            onOpenDetails: action
        )
        .onChange(of: focused) { _, isFocused in onFocusChange?(isFocused) }
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: showsFocusedAppearance)
    }

    private var focusBorderColor: Color {
        AppFocusOutline.color
    }

    private var showsFocusedAppearance: Bool {
        focused || retainFocusAppearance
    }
}
