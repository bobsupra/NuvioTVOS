import Foundation

// App-only: builds shelf entries from the app's metadata, and gives the shelf
// the app's ratings. The extension target compiles only TopShelfFeed.swift and
// TopShelfLayout.swift, which stay free of app model types.

extension TopShelfEntry {
    /// A shelf entry for `meta`, carrying what the carousel details show.
    /// `screen`: where the title comes from in the app, for the Custom
    /// Posters setting's per-screen choice.
    init(meta: NuvioMeta, subtitle: String?, progress: Double?, action: TopShelfEntryAction,
         screen: CustomPosterScreen, airDate: String? = nil, homeOrder: Int? = nil) {
        let custom = TopShelfCustomPosters.artwork(for: meta, screen: screen)
        self.init(
            contentId: meta.id,
            contentType: meta.type,
            title: meta.name,
            subtitle: subtitle,
            imageURL: meta.posterUrl,
            backdropURL: meta.backdropUrl,
            progress: progress,
            action: action,
            summary: Self.nonEmpty(meta.description),
            genres: meta.genres.map { Array($0.prefix(3)) }.flatMap { $0.isEmpty ? nil : $0 },
            year: meta.year,
            releaseDate: Self.nonEmpty(meta.released),
            runtimeMinutes: Self.runtimeMinutes(meta.runtime),
            logoURL: Self.nonEmpty(meta.logoUrl),
            cast: meta.cast.map { Array($0.prefix(4)) }.flatMap { $0.isEmpty ? nil : $0 },
            directors: meta.director.map { Array($0.prefix(2)) }.flatMap { $0.isEmpty ? nil : $0 },
            airDate: airDate,
            imdbId: meta.imdbId,
            tmdbId: meta.tmdbId,
            imdbRating: meta.rating.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            homeOrder: homeOrder,
            customPosterURL: custom.poster,
            customLandscapeURL: custom.landscape
        )
    }

    /// Minutes from the metadata's runtime text: "142 min", "2h 22m",
    /// "2 hr 22 min", "1:58" or a bare number of minutes.
    static func runtimeMinutes(_ runtime: String?) -> Int? {
        guard let text = runtime?.lowercased(), !text.isEmpty else { return nil }
        let numbers = text.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .compactMap(Int.init)
        guard let first = numbers.first else { return nil }
        let hasHours = text.contains("h") || text.contains(":")
        let minutes = hasHours ? first * 60 + (numbers.dropFirst().first ?? 0) : first
        return minutes > 0 ? minutes : nil
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The Custom Posters setting (Settings → Layout) applied to the shelf, so its
/// posters and cards match the app's own: the active profile's URL pattern,
/// for the screens it is turned on for.
enum TopShelfCustomPosters {
    static func artwork(for meta: NuvioMeta, screen: CustomPosterScreen) -> (poster: String?, landscape: String?) {
        let store = ProfileSettings.current
        let pattern = store.string(forKey: SettingsKey.customPosterURLPattern) ?? ""
        guard !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, nil) }
        let screens = store.string(forKey: SettingsKey.customPosterEnabledScreens)
        func resolved(_ shape: String) -> String? {
            CustomPosterURLResolver.resolve(
                pattern: pattern, meta: meta, screen: screen, enabledScreens: screens, shape: shape)
        }
        return (resolved("poster"), resolved("landscape"))
    }
}

/// Mirrors the library titles into the App Group for the Top Shelf Library row.
/// Pulls from the active library provider (Simkl, Trakt, MDBList, WeTrakr, or Nuvio Local)
/// or from the user's explicitly selected Top Shelf Library source.
enum TopShelfLibraryFeed {
    private static let lock = NSLock()
    private static let prefetchLock = NSLock()
    private enum PrefetchOutcome: Equatable {
        case published
        case revisionConflict
        case failed
    }
    private static var inFlightPrefetchTasks: [String: Task<PrefetchOutcome, Never>] = [:]
    private static var pendingPrefetchKeys = Set<String>()
    private static var pendingForcedPrefetchKeys = Set<String>()

    /// Resolves the effective library mode based on user configuration and authentication.
    static func effectiveSourceMode(
        for configSource: TopShelfConfiguration.LibrarySource = TopShelfConfigurationStore.load().librarySource,
        profileId: String? = ProfileSettings.activeProfileID,
        store: UserDefaults = ProfileSettings.current
    ) -> TraktLibrarySourceMode {
        switch configSource {
        case .active:
            let activeMode = TraktSettingsStore.librarySourceMode(in: store)
            return isSourceAvailable(activeMode, profileId: profileId, store: store) ? activeMode : .local
        case .local:
            return .local
        case .simkl:
            return isSourceAvailable(.simkl, profileId: profileId, store: store) ? .simkl : .local
        case .trakt:
            return isSourceAvailable(.trakt, profileId: profileId, store: store) ? .trakt : .local
        case .mdblist:
            return isSourceAvailable(.mdblist, profileId: profileId, store: store) ? .mdblist : .local
        case .wetrakr:
            return isSourceAvailable(.wetrakr, profileId: profileId, store: store) ? .wetrakr : .local
        }
    }

    static func isSourceAvailable(
        _ mode: TraktLibrarySourceMode,
        profileId: String? = ProfileSettings.activeProfileID,
        store: UserDefaults = ProfileSettings.current
    ) -> Bool {
        switch mode {
        case .local:
            return true
        case .simkl:
            return SimklRuntimeSession.authenticatedState(store: store, profileScope: profileId) != nil
        case .trakt:
            return TraktAuthStore.isAuthenticated(in: store)
        case .mdblist:
            return MdbListRuntimeSession.isAuthenticated(in: store, profileScope: profileId)
        case .wetrakr:
            return WeTrakrRuntimeSession.isAuthenticated(in: store, profileScope: profileId)
        }
    }

    /// Items for the chosen library source.
    static func items(
        configSource: TopShelfConfiguration.LibrarySource = TopShelfConfigurationStore.load().librarySource,
        profileId: String? = ProfileSettings.activeProfileID,
        store: UserDefaults = ProfileSettings.current
    ) -> [LibraryStoreItem] {
        let mode = effectiveSourceMode(for: configSource, profileId: profileId, store: store)
        if mode == .local {
            return LibraryStore.items()
        }
        let bindingId = RemoteLibraryStore.accountBindingID(for: mode, profileId: profileId, in: store)
        return RemoteLibraryStore.load(source: mode, profileId: profileId, accountBindingId: bindingId) ?? []
    }

    /// Prefetches remote library items in the background if the selected remote source
    /// is authenticated but its on-device cache hasn't been loaded yet.
    static func prefetchRemoteLibraryIfNeeded(force: Bool = false) {
        startPrefetch(force: force)
    }

    private static func startPrefetch(force: Bool, conflictRetryBudget: Int = 1) {
        guard TopShelfFeedStore.isAvailable else { return }
        let store = ProfileSettings.current
        let profileId = ProfileSettings.activeProfileID
        let configuration = TopShelfConfigurationStore.load()
        guard configuration.isEnabled, configuration.includesLibrary else { return }
        let mode = effectiveSourceMode(for: configuration.librarySource, profileId: profileId, store: store)
        guard mode != .local else { return }
        guard let bindingId = RemoteLibraryStore.accountBindingID(for: mode, profileId: profileId, in: store),
              !bindingId.isEmpty else { return }
        let expectedRevision = RemoteLibraryStore.revision(
            source: mode,
            profileId: profileId,
            accountBindingId: bindingId
        )
        let cached = RemoteLibraryStore.load(source: mode, profileId: profileId, accountBindingId: bindingId)
        // An empty array is a successfully loaded empty library; source changes can force a refresh.
        guard force || cached == nil else { return }

        let cacheKey = RemoteLibraryStore.storageKey(
            source: mode,
            profileId: profileId,
            accountBindingId: bindingId
        )
        prefetchLock.lock()
        if let task = inFlightPrefetchTasks[cacheKey] {
            pendingPrefetchKeys.insert(cacheKey)
            if force {
                pendingForcedPrefetchKeys.insert(cacheKey)
            }
            prefetchLock.unlock()
            return
        }

        let task = Task { @MainActor in
            var outcome: PrefetchOutcome = .failed
            defer {
                finishPrefetch(
                    for: cacheKey,
                    outcome: outcome,
                    conflictRetryBudget: conflictRetryBudget,
                    mode: mode,
                    profileId: profileId,
                    store: store,
                    bindingId: bindingId
                )
            }
            outcome = await fetchAndPublishRemoteLibrary(
                mode: mode,
                profileId: profileId,
                store: store,
                bindingId: bindingId,
                expectedRevision: expectedRevision
            )
            return outcome
        }
        // The task's cleanup takes this lock, so it cannot finish before its
        // handle is installed in the in-flight table.
        inFlightPrefetchTasks[cacheKey] = task
        prefetchLock.unlock()
    }

    @MainActor
    private static func fetchAndPublishRemoteLibrary(
        mode: TraktLibrarySourceMode,
        profileId: String?,
        store: UserDefaults,
        bindingId: String,
        expectedRevision: UInt64
    ) async -> PrefetchOutcome {
        guard !Task.isCancelled else { return .failed }
        let repo = CinemetaCatalogRepository()
        let fetched: [LibraryStoreItem]?
        switch mode {
        case .local:
            return .failed
        case .trakt:
            fetched = await TraktLibraryService.fetchLibrary(
                repository: repo,
                requireSelectedSource: false,
                requireCompleteSnapshot: true
            )
        case .simkl:
            fetched = await SimklLibraryService.fetchLibrary(
                repository: repo,
                store: store,
                force: true,
                profileScope: profileId,
                requireSelectedSource: false
            )
        case .mdblist:
            fetched = await MdbListLibraryService.fetchLibrary(
                repository: repo,
                store: store,
                profileScope: profileId,
                requireCompleteSnapshot: true
            )
        case .wetrakr:
            fetched = await WeTrakrLibraryService.fetchLibrary(
                repository: repo,
                store: store,
                updateCachedLibraryItems: false,
                requireSuccessfulResponses: true
            )
        }

        guard !Task.isCancelled,
              let fetched,
              ProfileSettings.activeProfileID == profileId,
              ProfileSettings.isActiveStore(store) else { return .failed }
        let currentConfiguration = TopShelfConfigurationStore.load()
        guard currentConfiguration.isEnabled,
              currentConfiguration.includesLibrary,
              effectiveSourceMode(
                for: currentConfiguration.librarySource,
                profileId: profileId,
                store: store
              ) == mode,
              RemoteLibraryStore.accountBindingID(
                for: mode,
                profileId: profileId,
                in: store
              ) == bindingId else { return .failed }

        switch RemoteLibraryStore.saveIfUnchanged(
            items: fetched,
            source: mode,
            profileId: profileId,
            accountBindingId: bindingId,
            expectedRevision: expectedRevision
        ) {
        case .saved:
            return .published
        case .revisionChanged:
            return .revisionConflict
        case .failed:
            return .failed
        }
    }

    @MainActor
    private static func finishPrefetch(
        for cacheKey: String,
        outcome: PrefetchOutcome,
        conflictRetryBudget: Int,
        mode: TraktLibrarySourceMode,
        profileId: String?,
        store: UserDefaults,
        bindingId: String
    ) {
        prefetchLock.lock()
        inFlightPrefetchTasks.removeValue(forKey: cacheKey)
        let hadPendingRequest = pendingPrefetchKeys.remove(cacheKey) != nil
        let shouldForce = pendingForcedPrefetchKeys.remove(cacheKey) != nil
        prefetchLock.unlock()

        let shouldRetryConflict = outcome == .revisionConflict
            && conflictRetryBudget > 0
            && isCurrentPrefetchTarget(mode: mode, profileId: profileId, store: store, bindingId: bindingId)
        let shouldRetryPending = shouldForce || (hadPendingRequest && outcome != .published)
        guard shouldRetryConflict || shouldRetryPending else { return }

        let retryForce = shouldForce || shouldRetryConflict
        let nextConflictRetryBudget = shouldRetryConflict && !shouldForce
            ? conflictRetryBudget - 1
            : 1
        startPrefetch(force: retryForce, conflictRetryBudget: nextConflictRetryBudget)
    }

    @MainActor
    private static func isCurrentPrefetchTarget(
        mode: TraktLibrarySourceMode,
        profileId: String?,
        store: UserDefaults,
        bindingId: String
    ) -> Bool {
        guard ProfileSettings.activeProfileID == profileId,
              ProfileSettings.isActiveStore(store) else { return false }
        let configuration = TopShelfConfigurationStore.load()
        return configuration.isEnabled
            && configuration.includesLibrary
            && effectiveSourceMode(for: configuration.librarySource, profileId: profileId, store: store) == mode
            && RemoteLibraryStore.accountBindingID(for: mode, profileId: profileId, in: store) == bindingId
    }

    /// Mirrors the most recently added library titles into the App Group for
    /// the Top Shelf Library row.
    static func write(prefetchOnCacheMiss: Bool = true) {
        guard TopShelfFeedStore.isAvailable else { return }
        lock.lock()

        let store = ProfileSettings.current
        let profileId = ProfileSettings.activeProfileID
        let config = TopShelfConfigurationStore.load()
        let mode = effectiveSourceMode(for: config.librarySource, profileId: profileId, store: store)
        let bindingId = RemoteLibraryStore.accountBindingID(for: mode, profileId: profileId, in: store)
        let remoteItems = mode == .local
            ? nil
            : RemoteLibraryStore.load(source: mode, profileId: profileId, accountBindingId: bindingId)
        let shouldPrefetch = mode != .local && remoteItems == nil
        let libraryItems = items(configSource: config.librarySource, profileId: profileId, store: store)
        let entries = libraryItems
            .sorted { $0.addedAt > $1.addedAt }
            .prefix(15)
            .map { item in
                TopShelfEntry(meta: item.meta, subtitle: nil, progress: nil, action: .details, screen: .library)
            }
        TopShelfFeedStore.write(
            Array(entries),
            section: .library,
            title: L10n.string("nav_library", fallback: "Library")
        )
        lock.unlock()

        if prefetchOnCacheMiss && shouldPrefetch {
            prefetchRemoteLibraryIfNeeded()
        }
    }
}

/// Mirrors Home's Today row (the calendar's titles coming out today) for the
/// shelf. Library metadata supplies the backdrop, logo and summary the
/// calendar's compact cards lack.
enum TopShelfTodayFeed {
    private static let lock = NSLock()
    private static var lastWritten: [String]?

    static func write(_ row: CalendarHomeToday) {
        guard TopShelfFeedStore.isAvailable else { return }
        let library = Dictionary(
            TopShelfLibraryFeed.items().map { ($0.meta.id, $0.meta) },
            uniquingKeysWith: { first, _ in first })
        let entries: [TopShelfEntry] = row.metas.prefix(15).compactMap { compact in
            guard let calendarEntry = row.entries[compact.id] else { return nil }
            let label = row.labels[compact.id]
            let subtitle = [label?.episode, label?.badge].compactMap { $0 }.joined(separator: "  ·  ")
            return TopShelfEntry(
                meta: library[compact.id] ?? compact,
                subtitle: subtitle.isEmpty ? nil : subtitle,
                progress: nil,
                action: .details,
                screen: .home,
                airDate: calendarEntry.date.iso)
        }
        // The calendar republishes often; write only what changed.
        let signature = entries.map { "\($0.contentId)|\($0.subtitle ?? "")|\($0.airDate ?? "")|\($0.backdropURL ?? "")" }
        lock.lock()
        let isNew = signature != lastWritten
        lastWritten = signature
        lock.unlock()
        guard isNew else { return }
        TopShelfFeedStore.write(
            entries, section: .today,
            title: L10n.string("tvos_settings_topshelf_today", fallback: "Today"))
    }
}

/// The carousel's ratings: the ones the Home hero shows (its rating setting),
/// from the providers enabled in Settings, in the user's order, with the
/// icons Details uses.
enum TopShelfRatingsBridge {
    static let maximumBadges = 5

    static func install() {
        TopShelfFeedStore.ratingsProvider = { entry in
            await badges(for: entry)
        }
    }

    static func badges(for entry: TopShelfEntry) async -> [TopShelfRatingBadge] {
        let source = (ProfileSettings.current.string(forKey: SettingsKey.homeHeroRatingSource) ?? "imdb")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let meta = NuvioMeta(
            id: entry.contentId,
            name: entry.title,
            imdbId: entry.imdbId,
            tmdbId: entry.tmdbId,
            type: entry.contentType,
            rating: entry.imdbRating)
        let fetched = AddonRatingsService.heroNeedsFetchedRatings(source: source, meta: meta)
            ? await AddonRatingsService.fetchHomeHeroRatings(for: meta)
            : nil
        let ratings = AddonRatingsService.heroDisplayRatings(for: meta, fetched: fetched)
            .filter { AddonRatingsService.isSourceEnabled($0.source) }
        var badges = TvRatingBadge.badges(from: ratings)
        if !AddonRatingsService.heroShowsAllRatings(source) {
            // One score, as the hero: the chosen source, else IMDb.
            let wanted = AddonRatingsService.normalizedSourceKey(source.isEmpty ? "imdb" : source)
            let imdb = AddonRatingsService.normalizedSourceKey(MdbListDetailsService.providerIMDb)
            let chosen = badges.first { AddonRatingsService.normalizedSourceKey($0.rating.source) == wanted }
                ?? badges.first { AddonRatingsService.normalizedSourceKey($0.rating.source) == imdb }
            badges = chosen.map { [$0] } ?? []
        }
        return badges.prefix(maximumBadges).map { badge in
            TopShelfRatingBadge(
                source: badge.rating.source,
                name: badge.visual.displayName,
                value: badge.formattedValue,
                iconAssetName: badge.visual.assetName,
                iconURL: badge.visual.iconUrl?.absoluteString,
                iconWidth: Double(badge.visual.iconWidth))
        }
    }
}
