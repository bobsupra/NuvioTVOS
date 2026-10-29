import Foundation
import Combine

@MainActor
public class LibraryViewModel: ObservableObject {
    typealias LibraryHistorySyncHandler = @MainActor (TraktLibrarySourceMode, String?) async -> Bool

    @Published public var items: [StremioMeta] = []
    @Published public var sortOption: SortOption = .dateAdded
    @Published public var groupOption: GroupOption = .none
    @Published public var contentTypeFilter: String?
    @Published public var genreFilter: String?
    @Published private(set) var mdbListLists: [MdbListUserList] = []
    @Published private(set) var selectedMdbListListID: Int?
    @Published private(set) var displayedWatchedContext: LibraryWatchedContext?
    /// Last focused card, kept here (outside the view, like
    /// `TVHomeStore.lastFocusedCardID`) so it survives the details push and
    /// returning restores that card instead of snapping to the top.
    public var lastFocusedItemID: String?
    private var libraryObserver: NSObjectProtocol?
    private var watchedOwnerObserver: NSObjectProtocol?
    private var watchedTargetsObserver: NSObjectProtocol?
    private var traktAuthObserver: NSObjectProtocol?
    private var simklAuthObserver: NSObjectProtocol?
    private var mdbListAuthObserver: NSObjectProtocol?
    private var traktSettingsObserver: NSObjectProtocol?
    private var traktMutationObserver: NSObjectProtocol?
    private var mdbListMutationObserver: NSObjectProtocol?
    private var wetrakrAuthObserver: NSObjectProtocol?
    private var wetrakrMutationObserver: NSObjectProtocol?
    private var displayedSource: TraktLibrarySourceMode?
    private var refreshGeneration = 0
    private var lastLibraryHistorySyncRequest: [String: Date] = [:]
    private let libraryHistorySyncHandler: LibraryHistorySyncHandler
    private let repository: CatalogRepository = CinemetaCatalogRepository()
    
    public enum SortOption: String, CaseIterable, Identifiable {
        case dateAdded = "Date Added"
        case title = "Title"
        case year = "Year"
        
        public var id: String { self.rawValue }

        /// Localized label for menus; `rawValue` stays English for identity/storage.
        public var localizedTitle: String {
            switch self {
            case .dateAdded:
                return L10n.string("library_sort_added_desc", fallback: "Date Added")
            case .title:
                return L10n.string("library_sort_title_asc", fallback: "Title")
            case .year:
                return L10n.string("library_filter_year", fallback: "Year")
            }
        }
    }
    
    public enum GroupOption: String, CaseIterable, Identifiable {
        case none = "None"
        case type = "Type"
        
        public var id: String { self.rawValue }

        public var localizedTitle: String {
            switch self {
            case .none:
                return L10n.string("action_none", fallback: "None")
            case .type:
                return L10n.string("library_filter_type", fallback: "Type")
            }
        }
    }
    
    public convenience init() {
        self.init(libraryHistorySyncHandler: { source, profileID in
            await WatchedStore.syncLibraryHistory(for: source, profileId: profileID)
        })
    }

    init(libraryHistorySyncHandler: @escaping LibraryHistorySyncHandler) {
        self.libraryHistorySyncHandler = libraryHistorySyncHandler
        loadLibrary()
        libraryObserver = NotificationCenter.default.addObserver(
            forName: LibraryStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.loadLibrary()
            }
        }
        watchedOwnerObserver = NotificationCenter.default.addObserver(
            forName: WatchedStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDisplayedWatchedOwnerAfterStoreChange()
            }
        }
        watchedTargetsObserver = NotificationCenter.default.addObserver(
            forName: TraktSettingsStore.continueWatchingChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebindDisplayedWatchedOwner()
            }
        }
        traktAuthObserver = NotificationCenter.default.addObserver(
            forName: TraktAuthStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAfterWatchedOwnerChange()
            }
        }
        simklAuthObserver = NotificationCenter.default.addObserver(
            forName: SimklAuthStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAfterWatchedOwnerChange()
            }
        }
        mdbListAuthObserver = NotificationCenter.default.addObserver(
            forName: MdbListAuthStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAfterWatchedOwnerChange()
            }
        }
        traktSettingsObserver = NotificationCenter.default.addObserver(
            forName: TraktSettingsStore.libraryChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAfterWatchedOwnerChange()
            }
        }
        traktMutationObserver = NotificationCenter.default.addObserver(
            forName: TraktLibraryService.mutationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let mutation = notification.object as? TraktLibraryMutation else { return }
            Task { @MainActor in
                self?.applyTraktMutation(mutation)
            }
        }
        mdbListMutationObserver = NotificationCenter.default.addObserver(
            forName: MdbListLibraryService.mutationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let mutation = notification.object as? MdbListLibraryMutation else { return }
            Task { @MainActor in
                self?.applyMdbListMutation(mutation)
            }
        }
        wetrakrAuthObserver = NotificationCenter.default.addObserver(
            forName: WeTrakrAuthStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshAfterWatchedOwnerChange()
            }
        }
        wetrakrMutationObserver = NotificationCenter.default.addObserver(
            forName: WeTrakrLibraryService.mutationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshSelectedLibrary()
            }
        }
    }

    private func refreshAfterWatchedOwnerChange() async {
        invalidateStaleDisplayedLibrary()
        await refreshSelectedLibrary(syncWatchedHistory: true)
    }

    private func invalidateStaleDisplayedLibrary() {
        guard let displayedWatchedContext,
              !displayedWatchedContext.isCurrentScope else { return }
        items = []
        self.displayedWatchedContext = nil
        mdbListLists = []
        selectedMdbListListID = nil
        validateFilters()
    }

    private func refreshDisplayedWatchedOwnerAfterStoreChange() {
        guard let displayedWatchedContext,
              displayedWatchedContext.source == .local,
              displayedWatchedContext.mutationContext != nil,
              !displayedWatchedContext.nuvioSyncMutationTargetIsCurrent else { return }
        let previousAccountID = displayedWatchedContext.mutationContext?.targets
            .first(where: { $0.provider == .nuvioSync })?.accountID
        rebindDisplayedWatchedOwner()
        guard let reboundContext = self.displayedWatchedContext,
              reboundContext.source == .local,
              reboundContext.mutationContext?.targets
                .first(where: { $0.provider == .nuvioSync })?.accountID != previousAccountID else { return }
        scheduleLibraryHistorySync(for: reboundContext)
    }

    private func rebindDisplayedWatchedOwner() {
        guard let displayedWatchedContext else { return }
        let refreshedContext = LibraryWatchedContext.capture(
            source: displayedWatchedContext.source,
            profileId: displayedWatchedContext.profileId
        )
        if displayedWatchedContext.source == .local {
            guard displayedWatchedContext.profileId == refreshedContext.profileId else {
                invalidateStaleDisplayedLibrary()
                return
            }
            guard displayedWatchedContext.mutationContext != refreshedContext.mutationContext else { return }
            self.displayedWatchedContext = refreshedContext
            return
        }
        guard displayedWatchedContext.hasSameDisplayOwner(as: refreshedContext) else {
            invalidateStaleDisplayedLibrary()
            return
        }
        guard displayedWatchedContext.mutationContext != refreshedContext.mutationContext else { return }
        self.displayedWatchedContext = refreshedContext
    }

    @discardableResult
    func applyFetchedLibraryItems(
        _ items: [StremioMeta],
        source: TraktLibrarySourceMode,
        watchedContext: LibraryWatchedContext
    ) -> Bool {
        guard watchedContext.isCurrentScope else {
            self.items = []
            self.displayedWatchedContext = nil
            mdbListLists = []
            selectedMdbListListID = nil
            validateFilters()
            return false
        }
        displayedSource = source
        displayedWatchedContext = watchedContext
        self.items = items
        validateFilters()
        return true
    }

    deinit {
        for observer in [
            libraryObserver, watchedOwnerObserver, watchedTargetsObserver,
            traktAuthObserver, simklAuthObserver, mdbListAuthObserver,
            wetrakrAuthObserver, traktSettingsObserver, traktMutationObserver,
            mdbListMutationObserver, wetrakrMutationObserver
        ].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    public func loadLibrary() {
        guard !usesRemoteLibrary else {
            if displayedSource != TraktSettingsStore.librarySourceMode {
                displayedSource = TraktSettingsStore.librarySourceMode
                items = []
                displayedWatchedContext = nil
                if TraktSettingsStore.librarySourceMode != .mdblist {
                    mdbListLists = []
                    selectedMdbListListID = nil
                }
                validateFilters()
            }
            return
        }

        displayedSource = .local
        displayedWatchedContext = LibraryWatchedContext.capture(
            source: .local,
            profileId: LibraryStore.activeProfileId
        )
        mdbListLists = []
        selectedMdbListListID = nil
        let storeItems = LibraryStore.items()
        storeItems.forEach { CinemetaCatalogRepository.cacheCatalogMetadata($0.meta) }
        items = storeItems.map(\.stremioMeta)
        validateFilters()
    }

    public func refreshSelectedLibrary(syncWatchedHistory: Bool = false) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let profileID = LibraryStore.activeProfileId
        let settingsProfileID = ProfileSettings.activeProfileID
        let settingsStore = ProfileSettings.current
        let source = TraktSettingsStore.librarySourceMode(in: settingsStore)
        let traktContext = source == .trakt ? TraktLibraryMutationContext() : nil
        let watchedContext = LibraryWatchedContext.capture(source: source, profileId: profileID)

        guard usesRemoteLibrary else {
            loadLibrary()
            if syncWatchedHistory, let watchedContext = displayedWatchedContext {
                scheduleLibraryHistorySync(for: watchedContext)
            }
            return
        }

        if syncWatchedHistory {
            scheduleLibraryHistorySync(for: watchedContext)
        }

        if displayedSource != TraktSettingsStore.librarySourceMode {
            displayedSource = TraktSettingsStore.librarySourceMode
            items = []
            displayedWatchedContext = nil
            validateFilters()
        }

        let onSnapshot: LibraryMetadataHydrator.SnapshotHandler = { [weak self] snapshot in
            guard let self,
                  self.isCurrentRemoteRefresh(
                    generation: generation,
                    profileID: profileID,
                    settingsProfileID: settingsProfileID,
                    store: settingsStore,
                    source: source,
                    traktContext: traktContext,
                    watchedContext: watchedContext
                  ) else { return false }
            return self.applyFetchedLibraryItems(
                snapshot.map(\.stremioMeta),
                source: source,
                watchedContext: watchedContext
            )
        }

        guard let remoteItems = await SelectedLibraryService.fetchLibrary(
            repository: repository,
            onSnapshot: onSnapshot
        ), isCurrentRemoteRefresh(
            generation: generation,
            profileID: profileID,
            settingsProfileID: settingsProfileID,
            store: settingsStore,
            source: source,
            traktContext: traktContext,
            watchedContext: watchedContext
        ) else {
            invalidateStaleDisplayedLibrary()
            return
        }

        remoteItems.forEach { CinemetaCatalogRepository.cacheCatalogMetadata($0.meta) }
        guard applyFetchedLibraryItems(
            remoteItems.map(\.stremioMeta),
            source: source,
            watchedContext: watchedContext
        ) else { return }
        if source == .mdblist {
            let lists = await MdbListListService.fetchUserLists()
            guard !Task.isCancelled,
                  generation == refreshGeneration,
                  profileID == LibraryStore.activeProfileId,
                  settingsProfileID == ProfileSettings.activeProfileID,
                  ProfileSettings.isActiveStore(settingsStore),
                  TraktSettingsStore.librarySourceMode(in: settingsStore) == source,
                  SelectedLibraryService.isSelectedAndAuthenticated,
                  watchedContext.isCurrentScope else {
                invalidateStaleDisplayedLibrary()
                return
            }
            mdbListLists = lists ?? []
            if let selectedMdbListListID,
               mdbListLists.contains(where: { $0.id == selectedMdbListListID }) {
                await loadMdbListListItems(
                    selectedMdbListListID,
                    generation: generation,
                    profileID: profileID,
                    watchedContext: watchedContext
                )
            } else {
                selectedMdbListListID = nil
            }
        } else {
            mdbListLists = []
            selectedMdbListListID = nil
        }
        validateFilters()
    }

    /// Pull the selected Library provider's watched history once per visible
    /// owner refresh. This is intentionally independent of the Continue
    /// Watching source and does not block the Library fetch or replace its
    /// current contents. WatchedStore coalesces concurrent provider requests;
    /// the local throttle covers repeated auth/settings notifications and
    /// view task restarts for the same owner.
    func scheduleLibraryHistorySync(for context: LibraryWatchedContext) {
        let capturedLocalSyncAccountID = context.source == .local
            ? WatchedStore.nuvioSyncAccountBinding(profileId: context.profileId)
            : nil
        Task { @MainActor [weak self] in
            guard let self,
                  context.isCurrentScope,
                  context.source != .local
                    || WatchedStore.nuvioSyncAccountBinding(profileId: context.profileId) == capturedLocalSyncAccountID else { return }
            let localAccountKey = context.source == .local
                ? (capturedLocalSyncAccountID ?? "no-sync-account")
                : ""
            let key = "\(context.cacheIdentity)\u{1f}\(localAccountKey)"
            let now = Date()
            if let previousRequest = self.lastLibraryHistorySyncRequest[key],
               now.timeIntervalSince(previousRequest) < 30 {
                return
            }
            self.lastLibraryHistorySyncRequest[key] = now
            if self.lastLibraryHistorySyncRequest.count > 16 {
                self.lastLibraryHistorySyncRequest = self.lastLibraryHistorySyncRequest.filter {
                    now.timeIntervalSince($0.value) < 300
                }
            }
            guard context.isCurrentScope,
                  context.source != .local
                    || WatchedStore.nuvioSyncAccountBinding(profileId: context.profileId) == capturedLocalSyncAccountID else { return }
            _ = await self.libraryHistorySyncHandler(context.source, context.profileId)
        }
    }

    private func isCurrentRemoteRefresh(
        generation: Int,
        profileID: String?,
        settingsProfileID: String?,
        store: UserDefaults,
        source: TraktLibrarySourceMode,
        traktContext: TraktLibraryMutationContext?,
        watchedContext: LibraryWatchedContext
    ) -> Bool {
        !Task.isCancelled
            && generation == refreshGeneration
            && profileID == LibraryStore.activeProfileId
            && settingsProfileID == ProfileSettings.activeProfileID
            && ProfileSettings.isActiveStore(store)
            && TraktSettingsStore.librarySourceMode(in: store) == source
            && TraktSettingsStore.librarySourceMode == source
            && (source != .trakt || traktContext?.isCurrent == true)
            && watchedContext.isCurrentScope
            && source != .local
            && SelectedLibraryService.isSelectedAndAuthenticated
    }

    public func selectMdbListList(_ listID: Int?) async {
        guard TraktSettingsStore.librarySourceMode == .mdblist,
              usesRemoteLibrary,
              let watchedContext = displayedWatchedContext,
              watchedContext.source == .mdblist,
              watchedContext.isCurrentScope else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let profileID = LibraryStore.activeProfileId
        selectedMdbListListID = listID
        guard let listID else {
            await refreshSelectedLibrary()
            return
        }
        await loadMdbListListItems(
            listID,
            generation: generation,
            profileID: profileID,
            watchedContext: watchedContext
        )
    }

    private func loadMdbListListItems(
        _ listID: Int,
        generation: Int,
        profileID: String?,
        watchedContext: LibraryWatchedContext
    ) async {
        guard let listItems = await MdbListListService.fetchItems(
            listID: listID,
            repository: repository
        ),
        !Task.isCancelled,
        generation == refreshGeneration,
        profileID == LibraryStore.activeProfileId,
        TraktSettingsStore.librarySourceMode == .mdblist,
        usesRemoteLibrary,
        watchedContext.isCurrentScope else {
            invalidateStaleDisplayedLibrary()
            return
        }
        _ = applyFetchedLibraryItems(
            listItems.map(\.stremioMeta),
            source: .mdblist,
            watchedContext: watchedContext
        )
    }

    private var usesRemoteLibrary: Bool {
        SelectedLibraryService.isSelectedAndAuthenticated
    }

    /// The Android TV library updates its Trakt snapshot immediately after a
    /// validated watchlist mutation. Do the same here so navigation into
    /// Library never waits on a second network pull to reveal the title.
    func applyTraktMutation(_ mutation: TraktLibraryMutation) {
        // The observer queues a MainActor task. Ownership may have changed
        // since the service posted this notification, so check again here.
        guard displayedWatchedContext?.isCurrentScope == true else { return }
        if let context = mutation.context {
            guard context.isCurrent, displayedSource == .trakt else { return }
        } else {
            // These providers share the historical Trakt notification payload.
            // Unscoped events must never be applied to the Trakt library.
            let source = TraktSettingsStore.librarySourceMode
            guard source == .simkl || source == .wetrakr else { return }
        }
        applyLibraryMutation(meta: mutation.meta, isInWatchlist: mutation.isInWatchlist)
    }

    private func applyMdbListMutation(_ mutation: MdbListLibraryMutation) {
        guard TraktSettingsStore.librarySourceMode == .mdblist,
              usesRemoteLibrary,
              displayedWatchedContext?.isCurrentScope == true else { return }
        guard selectedMdbListListID == nil else {
            Task { @MainActor in await refreshSelectedLibrary() }
            return
        }
        if mutation.isInWatchlist {
            applyLibraryMutation(meta: mutation.meta, isInWatchlist: true)
        } else {
            Task { @MainActor in await refreshSelectedLibrary() }
        }
    }

    private func applyLibraryMutation(meta: NuvioMeta, isInWatchlist: Bool) {
        guard usesRemoteLibrary,
              displayedWatchedContext?.isCurrentScope == true else { return }
        let item = LibraryStoreItem(meta: meta, addedAt: Date()).stremioMeta
        if isInWatchlist {
            items = [item] + items.filter { !matchesLibraryMutation($0, meta: meta) }
        } else {
            items.removeAll { matchesLibraryMutation($0, meta: meta) }
        }
        displayedSource = TraktSettingsStore.librarySourceMode
        validateFilters()
    }

    private func matchesLibraryMutation(_ item: StremioMeta, meta: NuvioMeta) -> Bool {
        LibraryMutationIdentity.matches(
            itemID: item.id,
            itemType: item.contentType,
            cachedMetadata: repository.cachedMetadata(for: item.id),
            mutation: meta
        )
    }

    private func validateFilters() {
        if let contentTypeFilter, !availableContentTypes.contains(contentTypeFilter) {
            self.contentTypeFilter = nil
        }
        if let genreFilter, !availableGenres.contains(genreFilter) {
            self.genreFilter = nil
        }
    }

    public var availableContentTypes: [String] {
        Array(Set(items.map(\.contentType)))
            .filter { !$0.isEmpty }
            .sorted { typeLabel($0) < typeLabel($1) }
    }

    public var availableGenres: [String] {
        Array(Set(items.flatMap { $0.genres ?? [] }))
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func typeLabel(_ type: String) -> String {
        switch type.lowercased() {
        case "movie":
            return L10n.string("type_movies", fallback: L10n.string("type_movie", fallback: "Movies"))
        case "series", "tv":
            return L10n.string("type_series_plural", fallback: L10n.string("type_series", fallback: "Series"))
        default:
            return type.capitalized
        }
    }
    
    public var sortedAndGroupedItems: [String: [StremioMeta]] {
        var result: [String: [StremioMeta]] = [:]
        
        let filtered = items.filter { item in
            let matchesType = contentTypeFilter == nil || item.contentType == contentTypeFilter
            let matchesGenre = genreFilter == nil || item.genres?.contains(where: {
                $0.caseInsensitiveCompare(genreFilter ?? "") == .orderedSame
            }) == true
            return matchesType && matchesGenre
        }

        let sorted: [StremioMeta]
        switch sortOption {
        case .dateAdded:
            sorted = filtered
        case .title:
            sorted = filtered.sorted { $0.name < $1.name }
        case .year:
            sorted = filtered.sorted { ($0.releaseInfo ?? "") > ($1.releaseInfo ?? "") }
        }
        
        switch groupOption {
        case .none:
            result["All"] = sorted
        case .type:
            result = Dictionary(grouping: sorted, by: { $0.contentType })
        }
        
        return result
    }
}

enum LibraryMutationIdentity {
    static func matches(
        itemID: String,
        itemType: String,
        cachedMetadata: NuvioMeta?,
        mutation: NuvioMeta
    ) -> Bool {
        guard itemType.caseInsensitiveCompare(mutation.type) == .orderedSame else { return false }
        let itemKeys = keys(id: itemID, metadata: cachedMetadata)
        let mutationKeys = keys(id: mutation.id, metadata: mutation)
        return !itemKeys.isDisjoint(with: mutationKeys)
    }

    private static func keys(id: String, metadata: NuvioMeta?) -> Set<String> {
        var keys = Set<String>()

        func addID(_ value: String) {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { return }
            keys.insert("id:\(normalized)")
            if normalized.hasPrefix("tmdb:"), let tmdb = Int(normalized.dropFirst("tmdb:".count)) {
                keys.insert("tmdb:\(tmdb)")
            } else if normalized.hasPrefix("tt") {
                keys.insert("imdb:\(normalized)")
            }
        }

        addID(id)
        if let metadata {
            addID(metadata.id)
            if let imdbID = metadata.imdbId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !imdbID.isEmpty {
                keys.insert("imdb:\(imdbID.lowercased())")
            }
            if let tmdbID = metadata.tmdbId {
                keys.insert("tmdb:\(tmdbID)")
            }
        }
        return keys
    }
}
