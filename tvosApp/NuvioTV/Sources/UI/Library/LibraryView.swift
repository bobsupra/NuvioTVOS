import SwiftUI

/// Same poster geometry as the See All catalog, Grid Home, and Search. Seven
/// columns fit only because of `pageInset` — the old 80pt inset left room for six.
enum LibraryGridMetrics {
    static let posterWidth: CGFloat = 210
    static let posterHeight: CGFloat = 315
    static let posterGap: CGFloat = 28
    /// Leading/trailing inset for the whole screen. With the grid's own 12pt
    /// (which keeps a focused card's 1.06 scale from clipping) this is the 61pt
    /// gutter (141pt from screen edge with safe area) to center the 7-column grid symmetrically.
    static let pageInset: CGFloat = 49
}

enum LibrarySourceMode: String, CaseIterable, Identifiable {
    case saved
    case cloud

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .saved:
            return L10n.string("library_source_saved", fallback: "Saved")
        case .cloud:
            return L10n.string("library_source_cloud", fallback: "Cloud")
        }
    }
}

/// Captures the watched-history scope that produced a Library card. The account
/// binding travels with the navigation so a delayed action can reject a write
/// after the selected provider is relinked.
@MainActor
struct LibraryWatchedDisplayOwner: Equatable {
    let source: TraktLibrarySourceMode
    let profileId: String?
    let accountBindingId: String?

    static func capture(source: TraktLibrarySourceMode, profileId: String?) -> LibraryWatchedDisplayOwner {
        let store = ProfileSettings.store(for: profileId)
        return LibraryWatchedDisplayOwner(
            source: source,
            profileId: profileId,
            accountBindingId: accountBindingID(for: source, profileId: profileId, in: store)
        )
    }

    var isCurrent: Bool {
        guard LibraryStore.activeProfileId == profileId,
              ProfileSettings.activeProfileID == profileId else { return false }
        let configuredSource = TraktSettingsStore.librarySourceMode
        let effectiveSource = SelectedLibraryService.isSelectedAndAuthenticated
            ? configuredSource
            : .local
        guard effectiveSource == source else { return false }
        return Self.capture(source: source, profileId: profileId).accountBindingId == accountBindingId
    }

    var cacheIdentity: String {
        "\(source.rawValue)\u{1f}\(profileId ?? "legacy")\u{1f}\(accountBindingId ?? "no-account")"
    }

    static func accountBindingID(
        for source: TraktLibrarySourceMode,
        profileId: String?,
        in store: UserDefaults
    ) -> String? {
        RemoteLibraryStore.accountBindingID(for: source, profileId: profileId, in: store)
    }
}

@MainActor
struct LibraryWatchedContext {
    let source: TraktLibrarySourceMode
    let profileId: String?
    let displayOwner: LibraryWatchedDisplayOwner
    let mutationContext: WatchedLibraryMutationContext?

    private init(
        source: TraktLibrarySourceMode,
        profileId: String?,
        displayOwner: LibraryWatchedDisplayOwner,
        mutationContext: WatchedLibraryMutationContext?
    ) {
        self.source = source
        self.profileId = profileId
        self.displayOwner = displayOwner
        self.mutationContext = mutationContext
    }

    static func currentScope() -> LibraryWatchedContext {
        let selectedSource = TraktSettingsStore.librarySourceMode
        let isRemoteLibraryAvailable = SelectedLibraryService.isSelectedAndAuthenticated
        let source = isRemoteLibraryAvailable ? selectedSource : .local
        return LibraryWatchedContext(
            source: source,
            profileId: LibraryStore.activeProfileId,
            displayOwner: LibraryWatchedDisplayOwner.capture(
                source: source,
                profileId: LibraryStore.activeProfileId
            ),
            mutationContext: nil
        )
    }

    static func captureCurrent() -> LibraryWatchedContext {
        let scope = currentScope()
        return capture(source: scope.source, profileId: scope.profileId)
    }

    static func capture(
        source: TraktLibrarySourceMode,
        profileId: String?
    ) -> LibraryWatchedContext {
        return LibraryWatchedContext(
            source: source,
            profileId: profileId,
            displayOwner: LibraryWatchedDisplayOwner.capture(source: source, profileId: profileId),
            mutationContext: WatchedStore.captureLibraryMutationContext(
                for: source,
                profileId: profileId
            )
        )
    }

    var cacheIdentity: String {
        displayOwner.cacheIdentity
    }

    func hasSameDisplayOwner(as other: LibraryWatchedContext) -> Bool {
        displayOwner == other.displayOwner
    }

    var isCurrentScope: Bool {
        displayOwner.isCurrent
    }

    var hasMutationContext: Bool {
        mutationContext != nil
    }

    var isCurrent: Bool {
        guard isCurrentScope else { return false }
        guard let mutationContext,
              let current = WatchedStore.captureLibraryMutationContext(for: source, profileId: profileId) else {
            return false
        }
        return Self.hasSamePrimaryTarget(mutationContext, current)
    }

    var nuvioSyncMutationTargetIsCurrent: Bool {
        guard let mutationContext else { return false }
        let shouldIncludeTarget = source == .local
            || RemoteTrackingState.isNuvioSyncScrobbleEnabled(in: ProfileSettings.store(for: profileId))
        let target = mutationContext.targets.first(where: { $0.provider == .nuvioSync })
        guard shouldIncludeTarget else { return target == nil }
        return target?.accountID == WatchedStore.nuvioSyncAccountBinding(profileId: profileId)
    }

    static func hasSamePrimaryTarget(
        _ original: WatchedLibraryMutationContext,
        _ current: WatchedLibraryMutationContext
    ) -> Bool {
        guard original.librarySource == current.librarySource,
              original.profileID == current.profileID else { return false }
        let primary = WatchedStore.watchedSource(for: original.librarySource)
        let originalPrimary = original.targets.first { $0.provider == primary }
        let currentPrimary = current.targets.first { $0.provider == primary }
        return originalPrimary != nil && originalPrimary == currentPrimary
    }

    func recaptureForCurrentAction() -> LibraryWatchedContext? {
        let current = Self.captureCurrent()
        guard current.source == source,
              current.profileId == profileId,
              current.displayOwner == displayOwner else { return nil }
        if let mutationContext {
            guard let currentMutationContext = current.mutationContext,
                  Self.hasSamePrimaryTarget(mutationContext, currentMutationContext) else { return nil }
        }
        return current
    }

    @discardableResult
    func setWatched(
        _ meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil,
        isWatched: Bool
    ) -> Bool {
        guard let mutationContext = currentMutationContextForImmediateAction() else { return false }
        return WatchedStore.setLibraryWatched(
            meta,
            season: season,
            episode: episode,
            isWatched: isWatched,
            context: mutationContext
        )
    }

    @discardableResult
    func setSeasonWatched(
        _ meta: NuvioMeta,
        season: Int,
        episodes: [Int],
        isWatched: Bool
    ) -> Bool {
        guard let mutationContext = currentMutationContextForImmediateAction() else { return false }
        return WatchedStore.setLibrarySeasonWatched(
            meta,
            season: season,
            episodes: episodes,
            isWatched: isWatched,
            context: mutationContext
        )
    }

    @discardableResult
    func setWatchedUpTo(_ meta: NuvioMeta, season: Int, episode: Int) -> Bool {
        guard let mutationContext = currentMutationContextForImmediateAction() else { return false }
        return WatchedStore.setLibraryWatchedUpTo(
            meta,
            season: season,
            episode: episode,
            context: mutationContext
        )
    }

    @discardableResult
    func setWatchedUsingCapturedAction(
        _ meta: NuvioMeta,
        isWatched: Bool
    ) -> Bool {
        guard isCurrentScope, let mutationContext else { return false }
        return WatchedStore.setLibraryWatched(
            meta,
            isWatched: isWatched,
            context: mutationContext
        )
    }

    private func currentMutationContextForImmediateAction() -> WatchedLibraryMutationContext? {
        guard isCurrent,
              let current = WatchedStore.captureLibraryMutationContext(for: source, profileId: profileId),
              let mutationContext,
              Self.hasSamePrimaryTarget(mutationContext, current) else { return nil }
        return current
    }
}

public struct LibraryView: View {
    @StateObject private var viewModel: LibraryViewModel
    @StateObject private var cloudViewModel: CloudLibraryViewModel
    let onContentClick: (String, String) -> Void
    var onLibraryContentClick: ((String, String, LibraryWatchedContext) -> Void)? = nil
    var onLongPress: ((NuvioMeta) -> Void)? = nil
    /// Opens the debrid Cloud Library screen; kept for external callers.
    var onOpenCloudLibrary: (() -> Void)? = nil
    var onPlayCloudFile: ((URL, NuvioMeta) -> Void)? = nil

    @State private var sourceMode: LibrarySourceMode = .saved
    @State private var openCloudItem: CloudItem? = nil
    @FocusState private var cloudFocusedKey: String?
    @State private var lastFocusedCloudItemID: String?
    @State private var shouldRestoreCloudFocus = false
    @State private var restoreCloudArmTask: Task<Void, Never>?
    @State private var overlayRestoreCloudItemID: String?

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

    init(
        viewModel: LibraryViewModel,
        store: UserDefaults = ProfileSettings.current,
        onContentClick: @escaping (String, String) -> Void,
        onLibraryContentClick: ((String, String, LibraryWatchedContext) -> Void)? = nil,
        onLongPress: ((NuvioMeta) -> Void)? = nil,
        onOpenCloudLibrary: (() -> Void)? = nil,
        onPlayCloudFile: ((URL, NuvioMeta) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        _cloudViewModel = StateObject(wrappedValue: CloudLibraryViewModel(store: store))
        self.onContentClick = onContentClick
        self.onLibraryContentClick = onLibraryContentClick
        self.onLongPress = onLongPress
        self.onOpenCloudLibrary = onOpenCloudLibrary
        self.onPlayCloudFile = onPlayCloudFile
    }

    /// Cloud Library is only reachable for the providers that expose one.
    private var cloudLibraryAvailable: Bool {
        cloudViewModel.isAvailable
    }
    
    public var body: some View {
        ZStack(alignment: .top) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text(L10n.string("library_title", fallback: "Library"))
                    .font(.system(size: 46, weight: .bold))
                    .foregroundColor(.white)

                // Source switch: Saved | Cloud
                if cloudLibraryAvailable {
                    HStack(spacing: 16) {
                        ForEach(LibrarySourceMode.allCases) { mode in
                            SourceModeChip(
                                title: mode.localizedTitle,
                                isSelected: sourceMode == mode
                            ) {
                                if sourceMode != mode {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        sourceMode = mode
                                    }
                                    if mode == .cloud {
                                        Task { await cloudViewModel.load() }
                                    }
                                }
                            }
                        }
                    }
                    .disabled(overlayRestoreItemID != nil || overlayRestoreCloudItemID != nil)
                }

                // Controls row (Dynamic based on Saved vs Cloud)
                HStack(spacing: 16) {
                    if sourceMode == .saved {
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

                        if TraktSettingsStore.librarySourceMode == .mdblist,
                           !viewModel.mdbListLists.isEmpty {
                            FilterMenu(
                                label: "MDBList: \(selectedMdbListListLabel)"
                            ) {
                                Button {
                                    Task { await viewModel.selectMdbListList(nil) }
                                } label: {
                                    menuItem(
                                        "Library",
                                        selected: viewModel.selectedMdbListListID == nil
                                    )
                                }
                                ForEach(viewModel.mdbListLists) { list in
                                    Button {
                                        Task { await viewModel.selectMdbListList(list.id) }
                                    } label: {
                                        menuItem(
                                            list.name,
                                            selected: viewModel.selectedMdbListListID == list.id
                                        )
                                    }
                                }
                            }
                        }
                    } else {
                        // Cloud filters: Select provider & Select type
                        FilterMenu(
                            label: "\(L10n.string("cloud_library_select_provider", fallback: "Select provider")): \(cloudSelectedProviderLabel)"
                        ) {
                            Button {
                                cloudViewModel.selectedProviderId = nil
                            } label: {
                                menuItem(
                                    L10n.string("cloud_library_provider_all", fallback: L10n.string("library_type_all", fallback: "All")),
                                    selected: cloudViewModel.selectedProviderId == nil
                                )
                            }
                            ForEach(cloudViewModel.availableProviders) { prov in
                                Button {
                                    cloudViewModel.selectedProviderId = prov.id
                                } label: {
                                    menuItem(
                                        prov.displayName,
                                        selected: cloudViewModel.selectedProviderId == prov.id
                                    )
                                }
                            }
                        }

                        FilterMenu(
                            label: "\(L10n.string("cloud_library_select_type", fallback: "Select type")): \(cloudSelectedTypeLabel)"
                        ) {
                            Button {
                                cloudViewModel.selectedType = nil
                            } label: {
                                menuItem(
                                    L10n.string("cloud_library_type_all", fallback: L10n.string("library_type_all", fallback: "All")),
                                    selected: cloudViewModel.selectedType == nil
                                )
                            }
                            ForEach(cloudViewModel.availableTypes) { type in
                                Button {
                                    cloudViewModel.selectedType = type
                                } label: {
                                    menuItem(
                                        type.localizedTitle,
                                        selected: cloudViewModel.selectedType == type
                                    )
                                }
                            }
                        }
                    }
                }
                .disabled(overlayRestoreItemID != nil || overlayRestoreCloudItemID != nil)
                .zIndex(1)

                if sourceMode == .saved {
                    savedContent
                } else {
                    cloudContent
                }
            }
            .padding(.horizontal, LibraryGridMetrics.pageInset)
            .padding(.top, 56)
            .ignoresSafeArea(edges: .bottom)
        }
        .onExitCommand(perform: openCloudItem == nil ? nil : closeCloudItem)
        .onChange(of: focusedItemID) { _, newValue in
            if let newValue {
                restoreArmTask?.cancel()
                lastFocusedItemID = newValue
                shouldRestoreFocus = false
            } else if lastFocusedItemID != nil {
                scheduleRestoreArm()
            }
        }
        .onChange(of: cloudFocusedKey) { _, newValue in
            if let newValue {
                restoreCloudArmTask?.cancel()
                lastFocusedCloudItemID = newValue
                shouldRestoreCloudFocus = false
                if isEnabled, newValue == overlayRestoreCloudItemID { overlayRestoreCloudItemID = nil }
            } else if lastFocusedCloudItemID != nil {
                scheduleRestoreCloudArm()
            }
        }
        // Overlay dismissal re-places focus geometrically without consulting
        // `defaultFocus`. While `overlayRestoreItemID` / `overlayRestoreCloudItemID`
        // is set every other card is unfocusable, so the engine can only land back
        // on the saved item -- no scroll-to-top flash.
        .onChange(of: isEnabled) { _, enabled in
            if !enabled {
                overlayRestoreGeneration &+= 1
                overlayRestoreItemID = focusedItemID ?? lastFocusedItemID
                overlayRestoreCloudItemID = cloudFocusedKey ?? lastFocusedCloudItemID
            } else {
                if let target = overlayRestoreItemID {
                    restoreOverlayFocus(to: target, generation: overlayRestoreGeneration)
                }
                if let cloudTarget = overlayRestoreCloudItemID {
                    restoreCloudOverlayFocus(to: cloudTarget, generation: overlayRestoreGeneration)
                }
            }
        }
        .task {
            await viewModel.refreshSelectedLibrary(syncWatchedHistory: true)
            if cloudViewModel.isAvailable {
                await cloudViewModel.load()
            }
        }
        .onChange(of: cloudLibraryAvailable) { _, available in
            if !available && sourceMode == .cloud {
                sourceMode = .saved
            }
        }
    }

    private var cloudSelectedProviderLabel: String {
        if let id = cloudViewModel.selectedProviderId,
           let prov = cloudViewModel.availableProviders.first(where: { $0.id == id }) {
            return prov.displayName
        }
        return L10n.string("cloud_library_provider_all", fallback: L10n.string("library_type_all", fallback: "All"))
    }

    private var cloudSelectedTypeLabel: String {
        if let type = cloudViewModel.selectedType {
            return type.localizedTitle
        }
        return L10n.string("cloud_library_type_all", fallback: L10n.string("library_type_all", fallback: "All"))
    }

    private var selectedMdbListListLabel: String {
        guard let selected = viewModel.selectedMdbListListID,
              let list = viewModel.mdbListLists.first(where: { $0.id == selected }) else {
            return "Library"
        }
        return list.name
    }

    @ViewBuilder
    private var savedContent: some View {
        let watchedContext = viewModel.displayedWatchedContext ?? LibraryWatchedContext.currentScope()
        let watchedContextIsCurrent = watchedContext.isCurrentScope
        if viewModel.isLoading && viewModel.items.isEmpty {
            centeredMessage {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.6)
            }
        } else if viewModel.items.isEmpty {
            centeredMessage {
                VStack(spacing: 16) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 56))
                        .foregroundColor(.white.opacity(0.4))
                    Text(L10n.string("library_empty_title", fallback: "Your library is empty"))
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                    Text(L10n.string("library_empty_message", fallback: "Titles you add to your library will appear here."))
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                }
            }
        } else if viewModel.sortedAndGroupedItems.values.allSatisfy(\.isEmpty) {
            centeredMessage {
                VStack(spacing: 16) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 56))
                        .foregroundColor(.white.opacity(0.4))
                    Text(L10n.string("library_filter_empty_title", fallback: "No matching titles"))
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                    Text(L10n.string("library_filter_empty_message", fallback: "Try changing or clearing your filters."))
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                }
            }
        } else {
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
                                    watchedContext: watchedContext,
                                    watchedContextIsCurrent: watchedContextIsCurrent,
                                    onLibraryContentClick: onLibraryContentClick,
                                    externalFocus: $focusedItemID,
                                    retainFocusAppearance: overlayRestoreItemID == item.id,
                                    onFocus: {
                                        if overlayRestoreItemID == item.id {
                                            overlayRestoreItemID = nil
                                        }
                                    },
                                    onLongPress: onLongPress.map { cb in { cb(item.asNuvioMeta) } }
                                ) {
                                    overlayRestoreItemID = item.id
                                    lastFocusedItemID = item.id
                                    if let onLibraryContentClick {
                                        guard watchedContextIsCurrent,
                                              let capturedContext = watchedContext.recaptureForCurrentAction() else { return }
                                        onLibraryContentClick(item.id, item.contentType, capturedContext)
                                    } else {
                                        onContentClick(item.id, item.contentType)
                                    }
                                }
                                .disabled(
                                    (overlayRestoreItemID != nil && overlayRestoreItemID != item.id)
                                        || !watchedContextIsCurrent
                                )
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
    }

    @ViewBuilder
    private var cloudContent: some View {
        if cloudViewModel.isLoading && cloudViewModel.items.isEmpty {
            centeredMessage {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.6)
            }
        } else if let openItem = openCloudItem {
            cloudFileList(for: openItem)
        } else if !cloudViewModel.isAvailable {
            centeredMessage {
                VStack(spacing: 16) {
                    Image(systemName: "cloud.slash")
                        .font(.system(size: 56))
                        .foregroundColor(.white.opacity(0.4))
                    Text(L10n.string("cloud_library_connect_title", fallback: "No cloud account connected"))
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                    Text(L10n.string("cloud_library_connect_message", fallback: "Connect an account in Connected Services settings to browse playable files from your cloud library."))
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                }
            }
        } else if let error = cloudViewModel.errorMessage, cloudViewModel.items.isEmpty {
            centeredMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 56))
                        .foregroundColor(.white.opacity(0.4))
                    Text(error)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                }
            }
        } else if cloudViewModel.filteredItems.isEmpty {
            centeredMessage {
                VStack(spacing: 16) {
                    Image(systemName: "tray")
                        .font(.system(size: 56))
                        .foregroundColor(.white.opacity(0.4))
                    Text(cloudViewModel.errorMessage ?? L10n.string("cloud_library_empty_title", fallback: "Nothing here yet"))
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                    Text(L10n.string("cloud_library_empty_message", fallback: "No playable cloud files match the current filters."))
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                }
            }
        } else {
            cloudItemList
        }
    }

    private var cloudItemList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(cloudViewModel.filteredItems, id: \.stableKey) { item in
                    CloudRow(
                        title: item.name,
                        subtitle: cloudItemSubtitle(for: item),
                        externalFocus: $cloudFocusedKey,
                        focusId: item.stableKey,
                        retainFocusAppearance: overlayRestoreCloudItemID == item.stableKey,
                        isBusy: false
                    ) {
                        overlayRestoreCloudItemID = item.stableKey
                        lastFocusedCloudItemID = item.stableKey
                        openCloudItemEntry(item)
                    }
                    .disabled(overlayRestoreCloudItemID != nil && overlayRestoreCloudItemID != item.stableKey)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 24)
            .padding(.bottom, 90)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
        .defaultFocusIfAvailable($cloudFocusedKey, lastFocusedCloudItemID ?? cloudViewModel.filteredItems.first?.stableKey)
    }

    private func cloudFileList(for item: CloudItem) -> some View {
        let defaultFileKey = item.playableFiles.first.map { "\(item.stableKey):\($0.id)" }
        return ScrollView {
            LazyVStack(spacing: 16) {
                HStack {
                    Button {
                        closeCloudItem()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .semibold))
                            Text(item.name)
                                .font(.system(size: 24, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .frame(height: 52)
                        .modifier(GlassChipBackground(filled: false))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                    Spacer()
                }
                .padding(.bottom, 8)

                ForEach(item.playableFiles) { file in
                    let key = "\(item.stableKey):\(file.id)"
                    CloudRow(
                        title: file.name,
                        subtitle: CloudLibraryView.sizeText(file.sizeBytes),
                        externalFocus: $cloudFocusedKey,
                        focusId: key,
                        retainFocusAppearance: overlayRestoreCloudItemID == key,
                        isBusy: cloudViewModel.resolvingKey == key
                    ) {
                        overlayRestoreCloudItemID = key
                        lastFocusedCloudItemID = key
                        cloudViewModel.play(item: item, file: file) { url, meta in
                            onPlayCloudFile?(url, meta)
                        }
                    }
                    .disabled(overlayRestoreCloudItemID != nil && overlayRestoreCloudItemID != key)
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, 24)
            .padding(.bottom, 90)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focusSection()
        .defaultFocusIfAvailable($cloudFocusedKey, lastFocusedCloudItemID ?? defaultFileKey)
    }

    private func cloudItemSubtitle(for item: CloudItem) -> String {
        var parts: [String] = []
        let count = item.playableFiles.count
        if count > 1 { parts.append("\(count) files") }
        if let size = CloudLibraryView.sizeText(item.sizeBytes) { parts.append(size) }
        if let status = item.status, !status.isEmpty { parts.append(status.capitalized) }
        return parts.joined(separator: "  ·  ")
    }

    private func centeredMessage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openCloudItemEntry(_ item: CloudItem) {
        let playable = item.playableFiles
        if playable.count == 1 {
            cloudViewModel.play(item: item, file: playable[0]) { url, meta in
                onPlayCloudFile?(url, meta)
            }
        } else if !playable.isEmpty {
            openCloudItem = item
            let firstKey = "\(item.stableKey):\(playable[0].id)"
            overlayRestoreCloudItemID = firstKey
            lastFocusedCloudItemID = firstKey
            shouldRestoreCloudFocus = true
            cloudFocusedKey = firstKey
            for delay in [0.05, 0.15, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if openCloudItem?.stableKey == item.stableKey {
                        cloudFocusedKey = firstKey
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if overlayRestoreCloudItemID == firstKey {
                    overlayRestoreCloudItemID = nil
                }
            }
        }
    }

    private func closeCloudItem() {
        let key = openCloudItem?.stableKey
        openCloudItem = nil
        if let key {
            overlayRestoreCloudItemID = key
            lastFocusedCloudItemID = key
            shouldRestoreCloudFocus = true
            cloudFocusedKey = key
            for delay in [0.05, 0.15, 0.35] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if openCloudItem == nil {
                        cloudFocusedKey = key
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if overlayRestoreCloudItemID == key {
                    overlayRestoreCloudItemID = nil
                }
            }
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

    private func scheduleRestoreCloudArm() {
        guard lastFocusedCloudItemID != nil, cloudFocusedKey == nil else { return }
        restoreCloudArmTask?.cancel()
        restoreCloudArmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, cloudFocusedKey == nil else { return }
            shouldRestoreCloudFocus = true
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

    private func restoreCloudOverlayFocus(to target: String, generation: Int) {
        for delay in [0.12, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if overlayRestoreGeneration == generation, overlayRestoreCloudItemID == target {
                    cloudFocusedKey = target
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if overlayRestoreGeneration == generation, overlayRestoreCloudItemID == target {
                overlayRestoreCloudItemID = nil
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
    var watchedContext: LibraryWatchedContext? = nil
    var watchedContextIsCurrent = true
    var onLibraryContentClick: ((String, String, LibraryWatchedContext) -> Void)? = nil
    var externalFocus: FocusState<String?>.Binding? = nil
    var retainFocusAppearance = false
    var onFocus: (() -> Void)? = nil
    var onLongPress: (() -> Void)? = nil
    let action: () -> Void

    @FocusState private var isFocused: Bool
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
            meta: item.asNuvioMeta,
            screen: .library,
            enabledScreens: customPosterEnabledScreens,
            shape: "poster"
        )
    }
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                CachedPosterArtwork(
                    urlString: customPosterArtworkURL ?? item.poster,
                    fallbackURLString: customPosterArtworkURL == nil ? nil : item.poster,
                    width: LibraryGridMetrics.posterWidth,
                    height: LibraryGridMetrics.posterHeight,
                    maximumWidth: LibraryGridMetrics.posterWidth
                ) {
                    ZStack {
                        Rectangle()
                            .fill(Color.white.opacity(0.07))
                        Image(systemName: item.contentType == "series" ? "tv" : "film")
                            .font(.system(size: 40))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
                .frame(width: LibraryGridMetrics.posterWidth, height: LibraryGridMetrics.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
                .modifier(
                    LiquidGlassCardModifier(
                        cornerRadius: cardCornerRadius,
                        isFocused: showsFocusedAppearance,
                        isEnabled: liquidGlassCards
                    )
                )
                .overlay(alignment: .topTrailing) {
                    WatchedCheckmarkBadge(
                        meta: item.asNuvioMeta,
                        libraryWatchedContext: watchedContext,
                        isLibraryContextCurrent: watchedContextIsCurrent
                    )
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
        .titleActionsContextMenu(
            meta: item.asNuvioMeta,
            libraryWatchedContext: watchedContext,
            onOpenLibraryDetails: onLibraryContentClick.map { callback in
                { context in callback(item.id, item.contentType, context) }
            },
            onOpenDetails: action,
            isEnabled: watchedContextIsCurrent
        )
        .onChange(of: isFocused) { _, focused in
            if focused {
                onFocus?()
            }
        }
        .animation(smoothFocus ? .spring(response: 0.28, dampingFraction: 0.75) : nil, value: showsFocusedAppearance)
        .disabled(!watchedContextIsCurrent)
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
        AppCardStyle.cornerRadius(for: cardCornerRadiusSetting, fallback: 16)
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

struct SourceModeChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(isSelected || focused ? .black : .white.opacity(0.9))
                .padding(.horizontal, 32)
                .frame(height: 60)
                .modifier(GlassChipBackground(filled: isSelected || focused))
                .overlay(
                    Capsule()
                        .strokeBorder(focused ? AppFocusOutline.color : .clear, lineWidth: focused ? AppFocusOutline.width : 0)
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.05 : 1.0)
        .animation(.easeOut(duration: 0.14), value: focused)
    }
}
