import SwiftUI

/// Same poster geometry as the See All catalog, Grid Home, and Search. Seven
/// columns fit only because of `pageInset` — the old 80pt inset left room for six.
private enum LibraryGridMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28
    /// Leading/trailing inset for the whole screen. With the grid's own 12pt
    /// (which keeps a focused card's 1.06 scale from clipping) this is the 48pt
    /// gutter Grid Home uses, so posters line up across the two screens.
    static let pageInset: CGFloat = 36
}

public struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    let onContentClick: (String, String) -> Void
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    /// Opens the debrid Cloud Library screen; shown only when a supported
    /// provider (Premiumize / TorBox) with an API key is configured.
    var onOpenCloudLibrary: (() -> Void)? = nil
    @FocusState private var focusedItemID: String?
    /// Last card focused in the grid, kept so returning from details (which
    /// steals focus and nils `focusedItemID`) restores that card instead of
    /// snapping back to the top of the grid.
    @State private var lastFocusedItemID: String?
    @State private var shouldRestoreFocus = false
    /// Debounced arming of the restore flag: a rapid vertical move blips
    /// `focusedItemID` to nil while the next lazy cell materializes, and
    /// arming instantly on that blip bounces focus back to the previous card.
    @State private var restoreArmTask: Task<Void, Never>?
    /// Card to actively re-focus once the Details overlay dismisses; captured
    /// when the tab view gets disabled (overlay up), consumed on re-enable.
    @State private var overlayRestoreItemID: String?
    @State private var overlayRestoreGeneration = 0
    @Environment(\.isEnabled) private var isEnabled
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.debridProvider) private var debridProvider = "None"
    @AppStorage(SettingsKey.debridApiKey) private var debridApiKey = ""
    @AppStorage(SettingsKey.torboxAccessToken) private var torboxAccessToken = ""
    @AppStorage(SettingsKey.premiumizeAccessToken) private var premiumizeAccessToken = ""

    init(viewModel: LibraryViewModel, onContentClick: @escaping (String, String) -> Void, onLongPress: ((NuvioMeta) -> Void)? = nil, onOpenCloudLibrary: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onContentClick = onContentClick
        self.onLongPress = onLongPress
        self.onOpenCloudLibrary = onOpenCloudLibrary
    }

    /// Cloud Library is only reachable for the providers that expose one.
    private var cloudLibraryAvailable: Bool {
        switch DebridProviderKind(settingsValue: debridProvider) {
        case .torbox:
            return !torboxAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !debridApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .premiumize:
            return !premiumizeAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !debridApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .none, .realDebrid, .allDebrid, .debridLink:
            return false
        }
    }
    
    public var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text(L10n.string("library_title", fallback: "Library"))
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(.white)

                // Controls
                HStack(spacing: 16) {
                    FilterMenu(
                        label: "\(L10n.string("library_filter_sort", fallback: "Sort")): \(viewModel.sortOption.localizedTitle)"
                    ) {
                        ForEach(LibraryViewModel.SortOption.allCases) { option in
                            Button { viewModel.sortOption = option } label: {
                                menuItem(option.localizedTitle, selected: viewModel.sortOption == option)
                            }
                        }
                    }

                    FilterMenu(
                        label: "\(L10n.string("tvos_library_group", fallback: "Group")): \(viewModel.groupOption.localizedTitle)"
                    ) {
                        ForEach(LibraryViewModel.GroupOption.allCases) { option in
                            Button { viewModel.groupOption = option } label: {
                                menuItem(option.localizedTitle, selected: viewModel.groupOption == option)
                            }
                        }
                    }

                    FilterMenu(
                        label: "\(L10n.string("tvos_library_content", fallback: "Content")): \(selectedTypeLabel)"
                    ) {
                        Button { viewModel.contentTypeFilter = nil } label: {
                            menuItem(
                                L10n.string("library_type_all", fallback: "All"),
                                selected: viewModel.contentTypeFilter == nil
                            )
                        }
                        ForEach(viewModel.availableContentTypes, id: \.self) { type in
                            Button { viewModel.contentTypeFilter = type } label: {
                                menuItem(
                                    viewModel.typeLabel(type),
                                    selected: viewModel.contentTypeFilter == type
                                )
                            }
                        }
                    }

                    FilterMenu(
                        label: "\(L10n.string("library_filter_genre", fallback: "Genre")): \(viewModel.genreFilter ?? L10n.string("library_type_all", fallback: "All"))"
                    ) {
                        Button { viewModel.genreFilter = nil } label: {
                            menuItem(
                                L10n.string("library_type_all", fallback: "All"),
                                selected: viewModel.genreFilter == nil
                            )
                        }
                        ForEach(viewModel.availableGenres, id: \.self) { genre in
                            Button { viewModel.genreFilter = genre } label: {
                                menuItem(genre, selected: viewModel.genreFilter == genre)
                            }
                        }
                    }

                    if cloudLibraryAvailable, let onOpenCloudLibrary {
                        Button(action: onOpenCloudLibrary) {
                            Label(
                                L10n.string("library_source_cloud", fallback: "Cloud"),
                                systemImage: "cloud"
                            )
                        }
                    }
                }
                .disabled(overlayRestoreItemID != nil)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(viewModel.sortedAndGroupedItems.keys.sorted(), id: \.self) { group in
                            if viewModel.groupOption != .none {
                                Text(group.capitalized)
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: LibraryGridMetrics.posterGap) {
                                ForEach(viewModel.sortedAndGroupedItems[group] ?? [], id: \.id) { item in
                                    LibraryItemButton(
                                        item: item,
                                        externalFocus: $focusedItemID,
                                        retainFocusAppearance: overlayRestoreItemID == item.id,
                                        onLongPress: onLongPress.map { cb in { cb(item.asNuvioMeta) } }
                                    ) {
                                        overlayRestoreItemID = item.id
                                        lastFocusedItemID = item.id
                                        onContentClick(item.id, item.contentType)
                                    }
                                    .disabled(overlayRestoreItemID != nil && overlayRestoreItemID != item.id)
                                }
                            }
                        }
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 90)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focusSection()
                .defaultFocusIfAvailable($focusedItemID, shouldRestoreFocus ? lastFocusedItemID : nil)
            }
            .padding(.horizontal, LibraryGridMetrics.pageInset)
            .padding(.top, 56)
        }
        .onChange(of: focusedItemID) { _, newValue in
            if let newValue {
                restoreArmTask?.cancel()
                lastFocusedItemID = newValue
                shouldRestoreFocus = false
                // Restoration complete -- lift the focus restriction.
                if isEnabled, newValue == overlayRestoreItemID { overlayRestoreItemID = nil }
            } else if lastFocusedItemID != nil {
                scheduleRestoreArm()
            }
        }
        // Overlay dismissal re-places focus geometrically without consulting
        // `defaultFocus`. While `overlayRestoreItemID` is set every other card
        // is unfocusable, so the engine can only land back on the saved card
        // -- no scroll-to-top flash. See TVHomeView for the full story.
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                overlayRestoreGeneration &+= 1
                overlayRestoreItemID = focusedItemID ?? lastFocusedItemID
            } else if let target = overlayRestoreItemID {
                restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
            }
        }
        .task {
            await viewModel.refreshSelectedLibrary()
        }
    }

    /// Arms the restore flag only after focus has stayed off the cards long
    /// enough that the nil is a real departure (menu/tab) instead of the
    /// one-frame blip of a rapid vertical move between lazy cells.
    private func scheduleRestoreArm() {
        guard lastFocusedItemID != nil, focusedItemID == nil else { return }
        restoreArmTask?.cancel()
        restoreArmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, focusedItemID == nil else { return }
            shouldRestoreFocus = true
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

    @ViewBuilder
    private func menuItem(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private var gridColumns: [GridItem] {
        [GridItem(
            .adaptive(minimum: LibraryGridMetrics.posterWidth, maximum: LibraryGridMetrics.posterWidth),
            spacing: LibraryGridMetrics.posterGap,
            alignment: .top
        )]
    }

    private var selectedTypeLabel: String {
        guard let type = viewModel.contentTypeFilter else {
            return L10n.string("library_type_all", fallback: "All")
        }
        return viewModel.typeLabel(type)
    }
}

struct LibraryItemButton: View {
    let item: StremioMeta
    var externalFocus: FocusState<String?>.Binding? = nil
    var retainFocusAppearance = false
    var onLongPress: (() -> Void)? = nil
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                AsyncImage(url: URL(string: item.poster ?? "")) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            Rectangle()
                                .fill(Color.white.opacity(0.07))
                            Image(systemName: item.contentType == "series" ? "tv" : "film")
                                .font(.system(size: 40))
                                .foregroundColor(.white.opacity(0.25))
                        }
                    }
                }
                .frame(width: LibraryGridMetrics.posterWidth, height: LibraryGridMetrics.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    WatchedCheckmarkBadge(metaId: item.id, type: item.contentType)
                }
                .overlay(
                    RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                        .stroke(showsFocusedAppearance ? focusBorderColor : Color.clear, lineWidth: focusHighlighter ? AppFocusOutline.emphasizedWidth : AppFocusOutline.width)
                )
                .shadow(color: .black.opacity(showsFocusedAppearance ? 0.5 : 0.2), radius: showsFocusedAppearance ? 16 : 6)
                
                if posterLabels {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(showsFocusedAppearance ? .white : .white.opacity(0.78))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(width: LibraryGridMetrics.posterWidth, alignment: .leading)
                }
            }
            .scaleEffect(showsFocusedAppearance ? 1.06 : 1.0)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .modifier(ExternalFocusBinding(binding: externalFocus, id: item.id))
        .focusEffectDisabledIfAvailable()
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in onLongPress?() }
        )
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: showsFocusedAppearance)
        .zIndex(showsFocusedAppearance ? 1 : 0)
    }

    private var subtitle: String {
        let typeLabel = item.contentType == "series"
            ? L10n.string("type_series", fallback: "Series")
            : L10n.string("type_movie", fallback: "Movie")
        var parts = [typeLabel]
        if let year = item.year { parts.append(String(year)) }
        if let rating = item.imdbRating.flatMap(Double.init), rating > 0 {
            parts.append(String(format: "★ %.1f", rating))
        }
        return parts.joined(separator: "  ·  ")
    }

    private var focusBorderColor: Color {
        AppFocusOutline.color
    }

    private var showsFocusedAppearance: Bool {
        isFocused || retainFocusAppearance
    }

    private var cardCornerRadius: CGFloat {
        16
    }
}

extension StremioMeta {
    /// Minimal NuvioMeta for the quick-actions menu (title + library/watched
    /// toggles key off id/type/name; the richer fields aren't needed here).
    var asNuvioMeta: NuvioMeta {
        NuvioMeta(
            id: id,
            name: name,
            description: description,
            posterUrl: poster,
            backgroundUrl: background,
            logoUrl: logo,
            imdbId: id.hasPrefix("tt") ? id : nil,
            tmdbId: nil,
            type: contentType,
            year: year.map(Int.init),
            genres: genres,
            rating: imdbRating.flatMap(Double.init),
            releaseInfo: releaseInfo,
            runtime: runtime,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }
}
