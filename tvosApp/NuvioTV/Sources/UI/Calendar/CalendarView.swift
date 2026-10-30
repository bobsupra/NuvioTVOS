import Combine
import SwiftUI

// MARK: - View model

/// The calendar shared by the Calendar tab and Home's Today row. The last
/// one is kept on disk, so both open with it while a newer one loads.
@MainActor
final class CalendarViewModel: ObservableObject {
    static let shared = CalendarViewModel()

    enum State {
        case idle
        case loading
        case notConfigured
        case loaded(CalendarResult, loadedAt: Date)
        case failed(String)
    }

    /// What a calendar is made with: the day and the profile's settings.
    private struct Inputs: Equatable, Sendable {
        let day: CalendarDay
        let settings: String
        let sourceItems: String
    }

    @Published private(set) var state: State = .idle
    /// A newer calendar is loading while the last one stays on screen.
    @Published private(set) var isRefreshing = false
    /// The inputs of the calendar shown, and of the one on its way.
    private var loaded: Inputs?
    private var pending: Inputs?
    private var loadTask: Task<Void, Never>?
    private var airTimesTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var watchedSourceSignature = ""
    private var continueWatchingSourceSignature = ""
    private var manualFollowSourceSignature = ""
    private var sourceChangeSubscriptions = Set<AnyCancellable>()
    private var sourceRefreshTask: Task<Void, Never>?
    private var sourceChangedDuringLoad = false
    private var pendingManualFollowSignature: String?
    private var forceSourceRefreshAfterDebounce = false
    private var observedSettingsSignature = ""
    private var restoreTask: Task<Void, Never>?
    private var didRestore = false
    /// Asked for while the saved calendar was being read.
    private var loadAfterRestore: TimeInterval?
    private var snapshotSequence = 0
    private let snapshots: CalendarSnapshotStore

    init(snapshots: CalendarSnapshotStore = .shared) {
        self.snapshots = snapshots
        watchedSourceSignature = Self.currentWatchedSourceSignature()
        continueWatchingSourceSignature = Self.currentContinueWatchingSourceSignature()
        manualFollowSourceSignature = Self.currentManualFollowSourceSignature()
        observedSettingsSignature = Self.settingsSignature()
        observeSourceChanges()
    }

    /// Shows the saved calendar, if any, without loading a new one.
    func showSaved() {
        restoreIfNeeded()
    }

    /// Shows the saved calendar first, then loads a new one when the day,
    /// profile or settings changed, or after `maxAge`.
    func loadIfNeeded(maxAge: TimeInterval = 30 * 60) {
        if restoreIfNeeded() || restoreTask != nil {
            loadAfterRestore = min(loadAfterRestore ?? maxAge, maxAge)
            return
        }
        let inputs = currentInputs()
        // The same calendar is on its way already.
        if loadTask != nil, pending == inputs { return }
        if case .loaded(_, let loadedAt) = state, loaded == inputs,
           Date().timeIntervalSince(loadedAt) < maxAge {
            return
        }
        load()
    }

    /// The shown calendar when it was made for the current profile and
    /// settings: right after a profile switch the last profile's calendar is
    /// still there until the new one loads.
    func currentResult(from state: State) -> CalendarResult? {
        guard case .loaded(let result, _) = state, loaded?.settings == Self.settingsSignature() else { return nil }
        return result
    }

    func load() {
        restoreTask?.cancel()
        restoreTask = nil
        loadAfterRestore = nil
        didRestore = true
        loadTask?.cancel()
        airTimesTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        guard CalendarLibrarySource.isTmdbConfigured else {
            finish(generation)
            loaded = nil
            state = .notConfigured
            return
        }
        let inputs = currentInputs()
        // Same profile and settings: the calendar stays on screen while the
        // new one loads (a new day, a refresh).
        let keepsShown: Bool
        if case .loaded = state, loaded?.settings == inputs.settings {
            keepsShown = true
            isRefreshing = true
        } else {
            keepsShown = false
            isRefreshing = false
            state = .loading
        }
        pending = inputs
        sourceRefreshTask?.cancel()
        sourceRefreshTask = nil
        forceSourceRefreshAfterDebounce = false
        sourceChangedDuringLoad = false
        let profileContext = CalendarManualFollowStore.captureProfileContext()
        let manualFollows = CalendarManualFollowStore.items(profileID: profileContext.profileID)
        let manualFollowSignature = CalendarManualFollowStore.signature(profileID: profileContext.profileID)
        pendingManualFollowSignature = manualFollowSignature
        loadTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            guard profileContext.isCurrent else {
                self?.discardStaleProfileLoad(generation)
                return
            }
            let continueWatchingItems = await CalendarLibrarySource.fetchContinueWatchingItems()
            guard !Task.isCancelled else { return }
            guard profileContext.isCurrent else {
                self?.discardStaleProfileLoad(generation)
                return
            }
            let additionalContinueWatchingIDs = CalendarLibrarySource.localContinueWatchingIdentityIDs()
            let additionalContinueWatchingMetas = await CalendarLibrarySource.localContinueWatchingMetas(
                for: additionalContinueWatchingIDs,
                profileContext: profileContext
            )
            guard !Task.isCancelled else { return }
            guard profileContext.isCurrent else {
                self?.discardStaleProfileLoad(generation)
                return
            }
            let watchedItems = WatchedStore.visibleItems()
            let sources = CalendarLibrarySource.calendarItems(
                manualFollows: Array(manualFollows.values),
                watchedItems: watchedItems,
                continueWatchingItems: continueWatchingItems,
                additionalContinueWatchingMetas: additionalContinueWatchingMetas,
                additionalContinueWatchingIDs: additionalContinueWatchingIDs
            )
            let period = CalendarBuilder.period(today: inputs.day)
            let service = CalendarLibrarySource.makeService(metas: sources.metas)
            do {
                let result = try await service.load(
                    items: sources.items,
                    first: period.first,
                    last: period.last,
                    manualFollowItemIDs: sources.manualFollowItemIDs,
                    automaticFollowItemIDs: sources.automaticFollowItemIDs
                )
                guard let self, !Task.isCancelled, self.loadGeneration == generation else { return }
                guard profileContext.isCurrent else {
                    self.discardStaleProfileLoad(generation)
                    return
                }
                let loadedAt = Date()
                // The settings may have changed while it loaded (the TVmaze switch).
                let madeWith = self.pending ?? inputs
                let sourceInputsMatch = self.watchedSourceSignature == sources.watchedSourceSignature
                    && self.continueWatchingSourceSignature == sources.continueWatchingSourceSignature
                let needsSourceRefresh = self.sourceChangedDuringLoad && !sourceInputsMatch
                    || self.forceSourceRefreshAfterDebounce
                    || Self.settingsSignature() != madeWith.settings
                let manualInputsMatch = manualFollowSignature == Self.currentManualFollowSourceSignature()
                if !self.sourceChangedDuringLoad {
                    self.watchedSourceSignature = sources.watchedSourceSignature
                    self.continueWatchingSourceSignature = sources.continueWatchingSourceSignature
                }
                if manualInputsMatch {
                    self.manualFollowSourceSignature = Self.currentManualFollowSourceSignature()
                }
                self.sourceChangedDuringLoad = false
                self.forceSourceRefreshAfterDebounce = false
                self.finish(generation)
                if !manualInputsMatch {
                    self.loaded = nil
                    self.state = .idle
                    self.scheduleSourceRefresh(force: true)
                    return
                }
                // Before the state: Home reads `loaded` when the state changes.
                self.loaded = Inputs(
                    day: madeWith.day,
                    settings: madeWith.settings,
                    sourceItems: "\(sources.watchSourceSignature)|\(manualFollowSignature)"
                )
                self.state = .loaded(result, loadedAt: loadedAt)
                self.saveSnapshot(result, loadedAt: loadedAt)
                self.addAirTimes(to: result, generation: generation)
                if needsSourceRefresh || Self.settingsSignature() != madeWith.settings {
                    self.scheduleSourceRefresh(force: true)
                }
            } catch CalendarLoadError.tmdbNotConfigured {
                guard let self, self.loadGeneration == generation else { return }
                self.finish(generation)
                self.loaded = nil
                self.state = .notConfigured
            } catch CalendarLoadError.invalidApiKey {
                self?.failed(generation, keepsShown: false, message: L10n.string(
                    "calendar_error_tmdb_key",
                    fallback: "TMDB rejected the API key. Check it in Settings → Integrations → TMDB."
                ))
            } catch {
                guard !Task.isCancelled else { return }
                self?.failed(generation, keepsShown: keepsShown, message: error.localizedDescription)
            }
        }
    }

    /// The Exact air times switch: on adds times to what's shown; off loads
    /// again for TMDB's own dates.
    func airTimesChanged(enabled: Bool) {
        let settings = Self.settingsSignature()
        if loadTask != nil {
            // The running load reads the switch when it finishes; what is on
            // screen until then stays the current calendar.
            pending = pending.map { Inputs(day: $0.day, settings: settings, sourceItems: $0.sourceItems) }
            loaded = loaded.map { Inputs(day: $0.day, settings: settings, sourceItems: $0.sourceItems) }
            return
        }
        switch state {
        case .loaded(let result, let loadedAt) where enabled:
            loaded = loaded.map { Inputs(day: $0.day, settings: settings, sourceItems: $0.sourceItems) }
            // Under the new settings, also when no show gets a time.
            saveSnapshot(result, loadedAt: loadedAt)
            addAirTimes(to: result, generation: loadGeneration)
        case .loading:
            // The running load reads the switch when it finishes.
            break
        default:
            load()
        }
    }

    /// Starts reading the saved calendar the first time anything asks for
    /// one; true when it did.
    @discardableResult
    private func restoreIfNeeded() -> Bool {
        guard !didRestore, case .idle = state else { return false }
        didRestore = true
        guard CalendarLibrarySource.isTmdbConfigured else { return false }
        let capturedInputs = currentInputs()
        let snapshotSettings = Self.snapshotSignature(
            settings: capturedInputs.settings,
            sourceItems: capturedInputs.sourceItems
        )
        let snapshots = self.snapshots
        state = .loading
        restoreTask = Task { [weak self] in
            let snapshot = await snapshots.read()
            guard let self, !Task.isCancelled else { return }
            self.restoreTask = nil
            let currentInputs = self.currentInputs()
            if let snapshot,
               currentInputs.settings == capturedInputs.settings,
               currentInputs.sourceItems == capturedInputs.sourceItems,
               snapshot.isUsable(settings: snapshotSettings, now: Date()) {
                self.loaded = Inputs(
                    day: snapshot.day,
                    settings: capturedInputs.settings,
                    sourceItems: capturedInputs.sourceItems
                )
                self.state = .loaded(snapshot.result, loadedAt: snapshot.loadedAt)
            } else {
                self.state = .idle
            }
            if let maxAge = self.loadAfterRestore {
                self.loadAfterRestore = nil
                self.loadIfNeeded(maxAge: maxAge)
            }
        }
        return true
    }

    /// The load is over, whatever its outcome.
    private func finish(_ generation: Int) {
        guard generation == loadGeneration else { return }
        loadTask = nil
        pending = nil
        pendingManualFollowSignature = nil
        isRefreshing = false
    }

    private func failed(_ generation: Int, keepsShown: Bool, message: String) {
        guard generation == loadGeneration else { return }
        let manualFollowsChanged = pendingManualFollowSignature.map {
            $0 != Self.currentManualFollowSourceSignature()
        } ?? false
        let forceProgressRefresh = forceSourceRefreshAfterDebounce
        finish(generation)
        forceSourceRefreshAfterDebounce = false
        if manualFollowsChanged {
            loaded = nil
            state = .idle
            scheduleSourceRefresh(force: true)
            return
        }
        if forceProgressRefresh {
            scheduleSourceRefresh(force: true)
        }
        // A failed refresh leaves the calendar on screen; the next visit tries again.
        guard !keepsShown else { return }
        loaded = nil
        state = .failed(message)
    }

    private func discardStaleProfileLoad(_ generation: Int) {
        guard generation == loadGeneration else { return }
        finish(generation)
        loaded = nil
        state = .idle
        scheduleSourceRefresh(force: true)
    }

    /// Exact broadcast times for regular series (TVmaze), added once the
    /// calendar is already on screen, a few shows at a time on the first
    /// run; a newer load discards them.
    private func addAirTimes(to result: CalendarResult, generation: Int) {
        airTimesTask?.cancel()
        guard CalendarOptions.tvmazeTimes(), result.allEntries.contains(where: CalendarTvmazeTimes.isEligible) else {
            return
        }
        var ids: [Int: CalendarTvmazeTimes.ShowIds] = [:]
        let followedItems = result.manualFollowItems.merging(result.automaticFollowItems) { first, _ in first }
        for (key, item) in followedItems where item.kind == .series {
            guard key.hasPrefix("series:"), let tmdb = Int(key.dropFirst("series:".count)) else { continue }
            if let imdb = item.imdbId ?? NuvioMeta.canonicalImdbID(from: item.id) {
                ids[tmdb] = CalendarTvmazeTimes.ShowIds(imdb: imdb)
            }
        }
        let client = CalendarLibrarySource.makeClient()
        airTimesTask = Task { [weak self] in
            let entries = await CalendarTvmazeTimes().apply(
                to: result.allEntries,
                ids: ids,
                externalIds: { tmdb in
                    guard let external = try? await client.externalIds(tmdbId: tmdb, kind: .series) else { return nil }
                    return CalendarTvmazeTimes.ShowIds(imdb: external.validImdbId, tvdb: external.tvdbId)
                },
                first: result.firstDay,
                last: result.lastDay,
                progress: { [weak self] partial in
                    await self?.showAirTimes(partial, generation: generation)
                }
            )
            guard !Task.isCancelled else { return }
            self?.showAirTimes(entries, generation: generation, isFinal: true)
        }
    }

    private func showAirTimes(_ entries: [CalendarEntry], generation: Int, isFinal: Bool = false) {
        guard loadGeneration == generation, case .loaded(let current, let loadedAt) = state else { return }
        var shown = current
        if Set(entries) != Set(current.allEntries) {
            shown = current.replacingEntries(entries)
            state = .loaded(shown, loadedAt: loadedAt)
        }
        // With the times, so the next start shows them at once.
        if isFinal { saveSnapshot(shown, loadedAt: loadedAt) }
    }

    private func saveSnapshot(_ result: CalendarResult, loadedAt: Date) {
        guard let loaded else { return }
        snapshotSequence += 1
        let sequence = snapshotSequence
        let snapshot = CalendarSnapshot(
            settings: Self.snapshotSignature(settings: loaded.settings, sourceItems: loaded.sourceItems),
            day: loaded.day,
            loadedAt: loadedAt,
            result: result
        )
        let snapshots = self.snapshots
        Task { await snapshots.write(snapshot, sequence: sequence) }
    }

    private var sourceItemsSignature: String {
        "\(watchedSourceSignature)|\(continueWatchingSourceSignature)|\(Self.currentManualFollowSourceSignature())"
    }

    private func currentInputs() -> Inputs {
        Inputs(day: CalendarDay(date: Date()), settings: Self.settingsSignature(), sourceItems: sourceItemsSignature)
    }

    private static func snapshotSignature(settings: String, sourceItems: String) -> String {
        "\(settings)|\(sourceItems)"
    }

    /// Everything besides the day that changes what the calendar holds.
    private static func settingsSignature() -> String {
        return [
            "calendar-sources-v3",
            LibraryStore.activeProfileId ?? "",
            ProfileSettings.activeProfileID ?? "",
            TraktSettingsStore.watchProgressSource.rawValue,
            CalendarLibrarySource.isTmdbConfigured ? "tmdb" : "",
            TmdbDetailsService.currentApiKey ?? "",
            TmdbDetailsService.preferredLanguage,
            String(TraktSettingsStore.continueWatchingDaysCap),
            CalendarOptions.tvmazeTimes() ? "tvmaze" : "",
        ].joined(separator: "|")
    }

    private static func currentWatchedSourceSignature() -> String {
        CalendarLibrarySource.watchedIdentitySignature(WatchedStore.visibleItems())
    }

    private static func currentContinueWatchingSourceSignature() -> String {
        CalendarLibrarySource.currentContinueWatchingSourceSignature()
    }

    private static func currentManualFollowSourceSignature() -> String {
        CalendarManualFollowStore.signature()
    }

    private func observeSourceChanges() {
        observe(ContinueWatchingStore.changedNotification, watched: false, continueWatching: true)
        observe(WatchProgressLedger.changedNotification, watched: false, continueWatching: true)
        observe(ContinueWatchingBuilder.itemsChangedNotification, watched: false, continueWatching: true)
        observe(TraktSettingsStore.continueWatchingChangedNotification, watched: false, continueWatching: true)
        observe(
            TraktSettingsStore.continueWatchingSourceInvalidatedNotification,
            watched: false,
            continueWatching: true,
            forceContinueWatchingRefresh: true
        )
        observe(TraktProgressService.continueWatchingSnapshotChangedNotification, watched: false, continueWatching: true)
        observe(WatchedStore.changedNotification, watched: true, continueWatching: false)
        observe(ProfileSettings.settingsChangedNotification, watched: true, continueWatching: true)
        observe(CalendarManualFollowStore.changedNotification, watched: false, continueWatching: false, manualFollows: true)
    }

    private func observe(
        _ notification: Notification.Name,
        watched: Bool,
        continueWatching: Bool,
        manualFollows: Bool = false,
        forceContinueWatchingRefresh: Bool = false
    ) {
        NotificationCenter.default.publisher(for: notification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.sourceDidChange(
                        watched: watched,
                        continueWatching: continueWatching,
                        manualFollows: manualFollows,
                        forceContinueWatchingRefresh: forceContinueWatchingRefresh
                    )
                }
            }
            .store(in: &sourceChangeSubscriptions)
    }

    private func sourceDidChange(
        watched: Bool,
        continueWatching: Bool,
        manualFollows: Bool,
        forceContinueWatchingRefresh: Bool
    ) {
        var sourceItemsChanged = false
        if watched {
            let next = Self.currentWatchedSourceSignature()
            sourceItemsChanged = sourceItemsChanged || next != watchedSourceSignature
            watchedSourceSignature = next
        }
        if continueWatching {
            let next = Self.currentContinueWatchingSourceSignature()
            sourceItemsChanged = sourceItemsChanged || next != continueWatchingSourceSignature
            continueWatchingSourceSignature = next
        }
        if manualFollows {
            let next = Self.currentManualFollowSourceSignature()
            sourceItemsChanged = sourceItemsChanged || next != manualFollowSourceSignature
            manualFollowSourceSignature = next
        }

        let settings = Self.settingsSignature()
        let settingsChanged = settings != observedSettingsSignature
        observedSettingsSignature = settings
        let inputChanged = loaded.map { $0.settings != settings || $0.sourceItems != sourceItemsSignature }
            ?? pending.map { $0.settings != settings || $0.sourceItems != sourceItemsSignature }
            ?? false
        guard sourceItemsChanged || inputChanged || settingsChanged || forceContinueWatchingRefresh else { return }
        if case .idle = state { return }
        if manualFollows && sourceItemsChanged {
            loaded = nil
            state = .idle
        }
        if loadTask != nil {
            sourceChangedDuringLoad = true
            forceSourceRefreshAfterDebounce = forceSourceRefreshAfterDebounce
                || manualFollows
                || forceContinueWatchingRefresh
            return
        }
        scheduleSourceRefresh(force: manualFollows || forceContinueWatchingRefresh)
    }

    private func scheduleSourceRefresh(force: Bool) {
        forceSourceRefreshAfterDebounce = forceSourceRefreshAfterDebounce || force
        sourceRefreshTask?.cancel()
        sourceRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.sourceRefreshTask = nil
            let force = self.forceSourceRefreshAfterDebounce
            self.forceSourceRefreshAfterDebounce = false
            if self.loadTask != nil {
                self.sourceChangedDuringLoad = true
                self.forceSourceRefreshAfterDebounce = force
                return
            }
            if force {
                self.load()
            } else {
                self.loadIfNeeded()
            }
        }
    }
}

/// Owns the status model without making the whole calendar observe it:
/// only the day panel redraws when watched or availability change.
@MainActor
final class CalendarStatusHolder: ObservableObject {
    let model = CalendarEntryStatusModel()
}

// MARK: - Screen

/// Month grid on the left, the episodes of the focused day on the right
/// (modelled on Stremio's calendar).
struct CalendarView: View {
    let onOpenEntry: (CalendarEntry) -> Void
    let onOpenSettings: () -> Void

    @ObservedObject private var model = CalendarViewModel.shared
    @StateObject private var statusHolder = CalendarStatusHolder()
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue
    @AppStorage(SettingsKey.calendarFilter) private var filterRaw = CalendarFilter.all.rawValue
    @AppStorage(SettingsKey.calendarHideSpoilers) private var hideSpoilers = CalendarOptions.defaultHideSpoilers
    @AppStorage(SettingsKey.calendarCheckAvailability) private var checkAvailability = CalendarOptions.defaultCheckAvailability
    @AppStorage(SettingsKey.calendarTvmazeTimes) private var tvmazeTimes = CalendarOptions.defaultTvmazeTimes

    private var accent: Color { SettingsAccent.color(for: theme) }
    private var filter: CalendarFilter { CalendarFilter(stored: filterRaw) }
    private var status: CalendarEntryStatusModel { statusHolder.model }

    @State private var displayedMonth = CalendarDay(date: Date()).firstOfMonth
    @State private var selectedDay = CalendarDay(date: Date())
    @State private var showingSkipped = false
    @State private var showingSuggestions = false
    @State private var showingOptions = false
    @State private var didFocusToday = false
    @FocusState private var focus: CalendarFocus?

    private var today: CalendarDay { CalendarDay(date: Date()) }

    private var isFocusInPanel: Bool {
        if case .entry = focus { return true }
        return false
    }

    private var manualFollowItems: [String: CalendarItem] {
        CalendarManualFollowStore.items()
    }

    private var automaticFollowItems: [String: CalendarItem] {
        guard case .loaded(let result, _) = model.state else { return [:] }
        return result.automaticFollowItems
    }

    private var resolvedManualFollowItems: [String: CalendarItem] {
        guard case .loaded(let result, _) = model.state else { return [:] }
        return result.manualFollowItems
    }

    private var skippedByKey: [String: CalendarSkippedItem] {
        guard case .loaded(let result, _) = model.state else { return [:] }
        return Dictionary(result.skipped.map { (CalendarSuggestions.skippedKey($0), $0) },
                          uniquingKeysWith: { first, _ in first })
    }

    /// The next day (today or later) each placed title has something on.
    private var nextDates: [String: CalendarDay] {
        guard case .loaded(let result, _) = model.state else { return [:] }
        var dates: [String: CalendarDay] = [:]
        for section in result.days where section.date >= today {
            for entry in section.entries {
                let key = "\(entry.kind.rawValue):\(entry.tmdbId)"
                if dates[key] == nil || section.date < dates[key]! { dates[key] = section.date }
            }
        }
        return dates
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea()
            content
        }
        #if os(tvOS)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        #endif
        .onAppear { model.loadIfNeeded() }
        .sheet(isPresented: $showingSkipped) {
            if case .loaded(let result, _) = model.state {
                CalendarSkippedList(skipped: result.skipped)
            }
        }
        .fullScreenCover(isPresented: $showingSuggestions) {
            CalendarSuggestionsView(
                manualFollowItems: manualFollowItems,
                automaticFollowItems: automaticFollowItems,
                resolvedManualFollowItems: resolvedManualFollowItems,
                nextDates: nextDates,
                skipped: skippedByKey,
                profileContext: CalendarManualFollowStore.captureProfileContext(),
                accent: accent
            ) { changed in
                showingSuggestions = false
                if changed > 0 { model.load() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            VStack(spacing: 24) {
                ProgressView()
                Text(L10n.string("calendar_loading", fallback: "Loading your calendar…"))
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .notConfigured:
            CalendarMessage(
                symbol: "calendar.badge.exclamationmark",
                text: L10n.string(
                    "calendar_tmdb_required",
                    fallback: "The calendar uses TMDB. Turn on TMDB and add your API key in Settings → Integrations."
                ),
                actionTitle: L10n.string("nav_settings", fallback: "Settings"),
                action: onOpenSettings
            )

        case .failed(let message):
            CalendarMessage(
                symbol: "exclamationmark.triangle",
                text: message,
                actionTitle: L10n.string("calendar_retry", fallback: "Try again"),
                action: { model.load() }
            )

        case .loaded(let result, let loadedAt):
            // Right after a profile switch the last profile's calendar is
            // still there until the new one starts loading.
            if model.currentResult(from: model.state) != nil {
                loadedContent(result: result, loadedAt: loadedAt)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func loadedContent(result: CalendarResult, loadedAt: Date) -> some View {
        let shown = result.filtered(filter)
        return HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 18) {
                header(result: result, loadedAt: loadedAt)
                monthGrid(result: shown)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            CalendarDayPanel(
                result: shown,
                month: displayedMonth,
                selectedDay: selectedDay,
                today: today,
                accent: accent,
                hideSpoilers: hideSpoilers,
                status: status,
                focus: $focus,
                onOpen: onOpenEntry
            )
            .frame(width: 610)
        }
        .modifier(CalendarStatusUpdates(
            status: status,
            monthEntries: shown.days.filter { $0.date.isSameMonth(as: displayedMonth) }.flatMap(\.entries),
            dayEntries: shown.entries(on: selectedDay),
            today: today,
            checkAvailability: checkAvailability
        ))
        .frame(maxHeight: .infinity, alignment: .top)
        // Use the screen's width: the system's side safe area (and the
        // collapsed sidebar) left a wide empty band on the left.
        .padding(.horizontal, 49)
        .padding(.top, 56)
        .padding(.bottom, 30)
        .defaultFocusIfAvailable($focus, didFocusToday ? nil : .day(today))
        .onAppear(perform: focusTodayOnFirstOpen)
        // Back from the episode list returns to the selected day instead
        // of jumping to the sidebar (which slides the whole grid over).
        // Elsewhere nil keeps the system's own Back.
        .onExitCommand(perform: isFocusInPanel ? { focus = .day(selectedDay) } : nil)
    }

    /// The first time the calendar shows, start on today's cell.
    private func focusTodayOnFirstOpen() {
        guard !didFocusToday else { return }
        didFocusToday = true
        displayedMonth = today.firstOfMonth
        selectedDay = today
        // After the focus engine's own first pass, as Details does for Play.
        DispatchQueue.main.async { focus = .day(today) }
    }

    // MARK: Header

    private func header(result: CalendarResult, loadedAt: Date) -> some View {
        let canGoBack = displayedMonth.addingMonths(-1) >= result.firstDay.firstOfMonth
        let canGoForward = displayedMonth.addingMonths(1) <= result.lastDay.firstOfMonth
        return HStack(spacing: 24) {
            Button {
                displayedMonth = displayedMonth.addingMonths(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .accessibilityLabel(L10n.string("calendar_previous_month", fallback: "Previous month"))
            }
            .buttonStyle(CalendarHeaderButtonStyle())
            .disabled(!canGoBack)
            .focused($focus, equals: .previousMonth)

            VStack(alignment: .leading, spacing: 2) {
                Text(CalendarFormat.year(displayedMonth))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                Text(CalendarFormat.month(displayedMonth))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(minWidth: 260, alignment: .leading)

            Button {
                displayedMonth = displayedMonth.addingMonths(1)
            } label: {
                Image(systemName: "chevron.right")
                    .accessibilityLabel(L10n.string("calendar_next_month", fallback: "Next month"))
            }
            .buttonStyle(CalendarHeaderButtonStyle())
            .disabled(!canGoForward)
            .focused($focus, equals: .nextMonth)

            Spacer()

            // Short labels, one line each: the grid's column leaves the
            // header little room.
            Button {
                showingOptions = true
            } label: {
                Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    .accessibilityLabel(filter.title)
            }
            .buttonStyle(CalendarHeaderButtonStyle())
            .confirmationDialog(
                L10n.string("calendar_options_title", fallback: "Show in the calendar"),
                isPresented: $showingOptions,
                titleVisibility: .visible
            ) {
                optionButtons
            } message: {
                Text(L10n.format(
                    "calendar_updated_at", fallback: "Updated %@",
                    Calendar.current.isDateInToday(loadedAt)
                        ? loadedAt.formatted(date: .omitted, time: .shortened)
                        : loadedAt.formatted(date: .abbreviated, time: .shortened)
                ))
            }

            Button {
                showingSuggestions = true
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .accessibilityLabel(L10n.string("calendar_add_to_calendar", fallback: "Add to calendar"))
            }
            .buttonStyle(CalendarHeaderButtonStyle())

            if !result.skipped.isEmpty {
                Button {
                    showingSkipped = true
                } label: {
                    Image(systemName: "eye.slash")
                        .accessibilityLabel(L10n.format(
                            "calendar_not_shown", fallback: "%d not shown", result.skipped.count
                        ))
                }
                .buttonStyle(CalendarHeaderButtonStyle())
            }

            Button {
                model.load()
            } label: {
                // The calendar stays on screen while a newer one loads.
                Image(systemName: model.isRefreshing ? "hourglass" : "arrow.clockwise")
                    .accessibilityLabel(L10n.string("calendar_refresh", fallback: "Refresh"))
            }
            .buttonStyle(CalendarHeaderButtonStyle())
        }
        .font(.system(size: 24, weight: .semibold))
    }

    /// The filter choices, then the switches (each press flips one and
    /// closes the menu).
    @ViewBuilder
    private var optionButtons: some View {
        ForEach(CalendarFilter.allCases) { option in
            Button(option == filter ? "✓ " + option.title : option.title) {
                filterRaw = option.rawValue
            }
        }
        Button(CalendarFormat.option(
            L10n.string("calendar_option_hide_spoilers", fallback: "Hide spoilers"), isOn: hideSpoilers
        )) {
            hideSpoilers.toggle()
        }
        Button(CalendarFormat.option(
            L10n.string("calendar_option_availability", fallback: "Check availability"), isOn: checkAvailability
        )) {
            checkAvailability.toggle()
        }
        Button(CalendarFormat.option(
            L10n.string("calendar_option_tvmaze", fallback: "Exact air times (TVmaze)"), isOn: tvmazeTimes
        )) {
            tvmazeTimes.toggle()
            model.airTimesChanged(enabled: tvmazeTimes)
        }
        Button(L10n.string("calendar_cancel", fallback: "Cancel"), role: .cancel) {}
    }

    // MARK: Grid

    private func monthGrid(result: CalendarResult) -> some View {
        let firstWeekday = Calendar.current.firstWeekday
        let cells = CalendarBuilder.monthGrid(for: displayedMonth, firstWeekday: firstWeekday)
        let rows = max(1, cells.count / 7)
        // Minimum height; cells grow to fill the screen's height.
        let cellHeight: CGFloat = rows > 5 ? 110 : 130

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(CalendarBuilder.weekdayOrder(firstWeekday: firstWeekday), id: \.self) { weekday in
                    Text(CalendarFormat.weekdayName(weekday))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 8)
                }
            }
            // Plain stacks instead of LazyVGrid: zIndex on the focused row and
            // cell is what lets the grown card cover its neighbours, and lazy
            // grids don't honour it.
            VStack(spacing: 10) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(0..<7, id: \.self) { column in
                            let index = row * 7 + column
                            let day = index < cells.count ? cells[index] : nil
                            dayCell(day, result: result, column: column, row: row, rows: rows, height: cellHeight)
                        }
                    }
                    .zIndex(focusedRow(in: cells) == row ? 1 : 0)
                }
            }
        }
        .onChange(of: focus) { _, newValue in
            if case .day(let day) = newValue {
                selectedDay = day
                didFocusToday = true
            }
        }
        .onChange(of: displayedMonth) { _, month in
            selectedDay = month.isSameMonth(as: today) ? today : month
        }
    }

    @ViewBuilder
    private func dayCell(
        _ day: CalendarDay?, result: CalendarResult, column: Int, row: Int, rows: Int, height: CGFloat
    ) -> some View {
        if let day {
            CalendarDayCell(
                day: day,
                entries: result.entries(on: day),
                isToday: day == today,
                isSelected: day == selectedDay,
                accent: accent,
                height: height,
                growth: CalendarDayCellGrowth(column: column, row: row, rows: rows)
            ) {
                if let first = result.entries(on: day).first {
                    focus = .entry(first.id)
                }
            }
            .frame(maxWidth: .infinity)
            .focused($focus, equals: .day(day))
            // The focused cell grows over its neighbours.
            .zIndex(focus == .day(day) ? 1 : 0)
        } else {
            Color.clear.frame(maxWidth: .infinity).frame(minHeight: height, maxHeight: .infinity)
        }
    }

    private func focusedRow(in cells: [CalendarDay?]) -> Int? {
        guard case .day(let day) = focus, let index = cells.firstIndex(of: day) else { return nil }
        return index / 7
    }
}

enum CalendarFocus: Hashable {
    case previousMonth
    case nextMonth
    case day(CalendarDay)
    case entry(String)
}

/// Keeps the watched state and the add-on check in step with what the
/// calendar shows.
private struct CalendarStatusUpdates: ViewModifier {
    let status: CalendarEntryStatusModel
    /// Everything the panel lists for the displayed month.
    let monthEntries: [CalendarEntry]
    /// The selected day's entries.
    let dayEntries: [CalendarEntry]
    let today: CalendarDay
    let checkAvailability: Bool

    private struct AvailabilityRequest: Equatable {
        let entries: [CalendarEntry]
        let enabled: Bool
    }

    func body(content: Content) -> some View {
        content
            .task(id: monthEntries) { status.updateWatched(for: monthEntries) }
            // Asked once the cursor rests on the day (the model waits).
            .task(id: AvailabilityRequest(entries: dayEntries, enabled: checkAvailability)) {
                if checkAvailability {
                    status.checkAvailability(for: dayEntries, today: today)
                } else {
                    status.clearAvailability()
                }
            }
            .onDisappear { status.cancelAvailability() }
    }
}

private struct CalendarHeaderButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 36, weight: .bold))
            .foregroundColor(isFocused ? .black : .white)
            .frame(width: 98, height: 98)
            .modifier(TvDetailsGlassBackground(filled: isFocused, shape: Circle()))
            .shadow(color: .black.opacity(isFocused ? 0.35 : 0.18), radius: isFocused ? 18 : 7, y: 8)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.985 : (isFocused ? 1.08 : 1))
            .animation(.easeOut(duration: 0.14), value: isFocused)
            .focusEffectDisabledIfAvailable()
    }
}

// MARK: - Day cell

/// Which way a focused cell grows, so cells at the edges of the grid grow
/// inwards instead of off the grid.
struct CalendarDayCellGrowth: Equatable {
    let column: Int
    let row: Int
    let rows: Int

    var alignment: Alignment {
        let horizontal: HorizontalAlignment = column == 0 ? .leading : (column == 6 ? .trailing : .center)
        let vertical: VerticalAlignment = row == 0 ? .top : (row >= rows - 1 ? .bottom : .center)
        return Alignment(horizontal: horizontal, vertical: vertical)
    }
}

private struct CalendarDayCell: View {
    let day: CalendarDay
    let entries: [CalendarEntry]
    let isToday: Bool
    let isSelected: Bool
    let accent: Color
    let height: CGFloat
    let growth: CalendarDayCellGrowth
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CalendarDayCellBody(
                day: day, entries: entries, isToday: isToday, isSelected: isSelected,
                accent: accent, height: height, growth: growth
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
    }
}

private struct CalendarDayCellBody: View {
    static let focusedScale: CGFloat = 1.7
    /// Posters shown side by side in a cell that isn't expanded.
    static let rowCapacity = 3
    /// How long the cursor has to rest on a day before it opens.
    static let expandDelay: Duration = .seconds(3)

    @Environment(\.isFocused) private var isFocused
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    @State private var isExpanded = false
    @State private var expandTask: Task<Void, Never>?
    let day: CalendarDay
    let entries: [CalendarEntry]
    let isToday: Bool
    let isSelected: Bool
    let accent: Color
    let height: CGFloat
    let growth: CalendarDayCellGrowth

    private var posters: [CalendarEntry] {
        // One poster per title per day.
        var seen = Set<String>()
        return entries.filter { seen.insert("\($0.kind.rawValue):\($0.tmdbId)").inserted }
    }

    private var hiddenCount: Int { max(0, posters.count - Self.rowCapacity) }
    private var cardCornerRadius: CGFloat { AppCardStyle.cornerRadius(for: cardCornerRadiusSetting) }

    var body: some View {
        // The cell keeps its grid slot; the visible card is drawn on top of
        // it and grows past it once expanded.
        GeometryReader { proxy in
            let scale = isExpanded ? Self.focusedScale : 1
            ZStack(alignment: growth.alignment) {
                Color.clear
                card
                    .frame(width: proxy.size.width * scale, height: proxy.size.height * scale)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: growth.alignment)
        }
        .frame(minHeight: height, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: isExpanded)
        .onChange(of: isFocused) { _, focused in
            expandTask?.cancel()
            expandTask = nil
            guard focused else {
                isExpanded = false
                return
            }
            // Only days with hidden titles open, and only when the cursor
            // stays, so moving across the grid doesn't make cells jump.
            guard hiddenCount > 0 else { return }
            expandTask = Task { @MainActor in
                try? await Task.sleep(for: Self.expandDelay)
                // Losing focus cancels this task (onChange above).
                guard !Task.isCancelled else { return }
                isExpanded = true
            }
        }
        .onDisappear {
            expandTask?.cancel()
            isExpanded = false
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(day.day)")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(isToday ? CalendarFormat.textColor(on: accent) : .white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(isToday ? accent : Color.clear))
                if isToday {
                    Text(L10n.string("calendar_today", fallback: "Today").uppercased())
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(accent)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isExpanded, entries.count > 0 {
                    Text(CalendarFormat.entryCount(entries.count))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            if isExpanded {
                CalendarPosterMosaic(entries: posters, columns: 4, rows: 3)
                Spacer(minLength: 0)
            } else if !posters.isEmpty {
                CalendarPosterRow(entries: Array(posters.prefix(Self.rowCapacity)), slots: Self.rowCapacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                if hiddenCount > 0 {
                    Text("+\(hiddenCount)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Opaque fills, so a grown card hides the cells under it and posters
        // can't spill out of their own cell.
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .fill(Color(white: isExpanded ? 0.2 : (isToday ? 0.15 : (isSelected ? 0.12 : 0.09))))
        )
        .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(isExpanded ? 0.7 : 0), radius: 24)
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.white : (isToday ? accent : Color.clear),
                    lineWidth: isFocused ? 4 : 3
                )
        )
    }
}

/// Whole posters (2:3) side by side, sized to fit the space they're given.
private struct CalendarPosterRow: View {
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    let entries: [CalendarEntry]
    let slots: Int

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(0..<slots, id: \.self) { index in
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .overlay {
                        if index < entries.count {
                            let entry = entries[index]
                            CalendarImage(url: entry.posterURL, symbol: entry.kind == .movie ? "film" : "tv")
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: AppCardStyle.cornerRadius(for: cardCornerRadiusSetting), style: .continuous))
            }
        }
    }
}

/// Up to `columns × rows` cropped poster tiles; when there are more titles
/// the last tile shows how many are left.
private struct CalendarPosterMosaic: View {
    @AppStorage(SettingsKey.cardCornerRadius) private var cardCornerRadiusSetting = AppCardStyle.defaultCornerRadiusRaw
    let entries: [CalendarEntry]
    let columns: Int
    let rows: Int

    var body: some View {
        let layout = CalendarFormat.mosaicLayout(count: entries.count, capacity: columns * rows)
        VStack(spacing: 4) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<columns, id: \.self) { column in
                        tile(at: row * columns + column, shown: layout.shown, overflow: layout.overflow)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tile(at index: Int, shown: Int, overflow: Int) -> some View {
        if index < shown {
            let entry = entries[index]
            CalendarImage(url: entry.posterURL, symbol: entry.kind == .movie ? "film" : "tv")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: AppCardStyle.cornerRadius(for: cardCornerRadiusSetting), style: .continuous))
        } else if overflow > 0, index == shown {
            Text("+\(overflow)")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: AppCardStyle.cornerRadius(for: cardCornerRadiusSetting), style: .continuous).fill(Color.white.opacity(0.08)))
        } else {
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Side panel

private struct CalendarDayPanel: View {
    let result: CalendarResult
    let month: CalendarDay
    let selectedDay: CalendarDay
    let today: CalendarDay
    let accent: Color
    let hideSpoilers: Bool
    @ObservedObject var status: CalendarEntryStatusModel
    var focus: FocusState<CalendarFocus?>.Binding
    let onOpen: (CalendarEntry) -> Void

    @State private var scrolledSectionID: String?

    private var sections: [CalendarDaySection] {
        result.days.filter { $0.date.isSameMonth(as: month) }
    }

    /// TVmaze's data has to be credited where its times are shown.
    private var showsTvmazeTimes: Bool {
        sections.contains { $0.entries.contains { $0.airTimeSource == .tvmaze } }
    }

    /// The section to bring into view: the selected day, or the next day
    /// after it that has something.
    private var anchorID: String? {
        (sections.first { $0.date >= selectedDay } ?? sections.last)?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if sections.isEmpty {
                        Text(L10n.string("calendar_month_no_followed_titles", fallback: "No followed titles air this month."))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.top, 40)
                    }
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(CalendarFormat.dayHeader(section.date, today: today))
                                .font(.system(size: 22, weight: section.date == today ? .heavy : .semibold))
                                .foregroundColor(section.date == today ? accent : .white.opacity(section.date == selectedDay ? 1 : 0.7))
                            ForEach(section.entries) { entry in
                                let watched = status.watched[entry.id]
                                Button { onOpen(entry) } label: {
                                    CalendarEntryCard(
                                        entry: entry,
                                        accent: accent,
                                        watched: watched,
                                        availability: status.availability[entry.id],
                                        hidesSpoilers: CalendarEntryRules.hidesSpoilers(
                                            entry, hideSpoilers: hideSpoilers, watched: watched
                                        )
                                    )
                                }
                                .buttonStyle(PosterCardButtonStyle())
                                .focusEffectDisabledIfAvailable()
                                .focused(focus, equals: .entry(entry.id))
                            }
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.white.opacity(section.date == selectedDay ? 0.1 : 0.04))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(section.date == today ? accent.opacity(0.8) : Color.clear, lineWidth: 2)
                        )
                        .id(section.id)
                    }
                    if showsTvmazeTimes {
                        Text(L10n.string("calendar_tvmaze_credit", fallback: "Series air times: TVmaze (CC BY-SA)"))
                            .font(.system(size: 17))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.top, 6)
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 12)
            }
            .scrollPosition(id: $scrolledSectionID, anchor: .top)
            .scrollClipDisabledIfAvailable()
            .onAppear {
                scrolledSectionID = anchorID
                scroll(proxy)
            }
            .onChange(of: selectedDay) { _, _ in
                scrolledSectionID = anchorID
                scroll(proxy)
            }
            .onChange(of: month) { _, _ in
                scrolledSectionID = anchorID
                scroll(proxy)
            }
            .onChange(of: focus.wrappedValue) { _, _ in
                scrolledSectionID = anchorID
                scroll(proxy)
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let anchorID else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(anchorID, anchor: .top)
        }
    }
}

private struct CalendarEntryCard: View {
    @Environment(\.isFocused) private var isFocused
    let entry: CalendarEntry
    let accent: Color
    var watched: Bool? = nil
    var availability: CalendarAvailability? = nil
    /// Show the series poster and "Episode 5" instead of the episode's
    /// picture and name.
    var hidesSpoilers = false

    private var imageURL: URL? {
        hidesSpoilers ? entry.posterURL : (entry.stillURL ?? entry.posterURL)
    }

    private var subtitle: String? {
        hidesSpoilers ? CalendarFormat.spoilerFreeSubtitle(entry) : CalendarFormat.subtitle(entry)
    }

    var body: some View {
        HStack(spacing: 16) {
            CalendarImage(url: imageURL, symbol: entry.kind == .movie ? "film" : "tv")
                .frame(width: 200, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(watched == true ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 4) {
                let time = entry.airTime.map(CalendarFormat.time)
                if CalendarFormat.tag(entry) != nil || time != nil {
                    HStack(spacing: 10) {
                        if let time {
                            Label(time, systemImage: "clock")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                        }
                        if let tag = CalendarFormat.tag(entry) {
                            Text(tag)
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(accent)
                        }
                    }
                }
                Text(entry.title)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                }
                CalendarEntryStatusLine(watched: watched == true, availability: availability, accent: accent)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(isFocused ? 0.2 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 3)
        )
        .scaleEffect(isFocused ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

/// "Watched" and "Available" (or "Checking…") under an entry; nothing when
/// there's nothing to say.
private struct CalendarEntryStatusLine: View {
    let watched: Bool
    let availability: CalendarAvailability?
    let accent: Color

    var body: some View {
        if watched || availability == .available || availability == .checking {
            HStack(spacing: 14) {
                if watched {
                    Label(L10n.string("calendar_watched", fallback: "Watched"), systemImage: "checkmark.circle.fill")
                        .foregroundColor(.white.opacity(0.8))
                }
                switch availability {
                case .available:
                    Label(L10n.string("calendar_available", fallback: "Available"), systemImage: "play.circle.fill")
                        .foregroundColor(accent)
                case .checking:
                    Label(L10n.string("calendar_checking", fallback: "Checking…"), systemImage: "hourglass")
                        .foregroundColor(.white.opacity(0.5))
                case .unavailable, nil:
                    EmptyView()
                }
            }
            .font(.system(size: 18, weight: .semibold))
            .lineLimit(1)
        }
    }
}

// MARK: - Small pieces

private struct CalendarImage: View {
    let url: URL?
    let symbol: String

    var body: some View {
        AsyncImage(url: url) { phase in
            if case .success(let image) = phase {
                image.resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: symbol).foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }
}

private struct CalendarMessage: View {
    let symbol: String
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: symbol)
                .font(.system(size: 70))
                .foregroundColor(.white.opacity(0.7))
            Text(text)
                .font(.system(size: 28))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            Button(actionTitle, action: action)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CalendarSkippedList: View {
    let skipped: [CalendarSkippedItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.string("calendar_not_shown_title", fallback: "Not shown in the calendar"))
                    .font(.system(size: 36, weight: .bold))
                ForEach(skipped) { item in
                    Button {} label: {
                        HStack {
                            Text(item.item.name ?? item.item.id)
                            Spacer()
                            Text(CalendarFormat.skipReason(item.reason))
                                .foregroundColor(.secondary)
                        }
                        .font(.system(size: 22))
                    }
                }
            }
            .padding(60)
        }
    }
}

enum CalendarFormat {
    /// Local broadcast time, e.g. "16:00" or "4:00 PM" depending on the app locale.
    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLocaleManager.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: date)
    }

    /// How many posters fit and how many are left for the "+N" tile.
    static func mosaicLayout(count: Int, capacity: Int) -> (shown: Int, overflow: Int) {
        guard capacity > 0 else { return (0, count) }
        if count <= capacity { return (count, 0) }
        let shown = capacity - 1
        return (shown, count - shown)
    }

    static func entryCount(_ count: Int) -> String {
        count == 1
            ? L10n.string("calendar_one_entry", fallback: "1 episode")
            : L10n.format("calendar_entries", fallback: "%d episodes", count)
    }

    /// Black on the white accent, white on the coloured ones.
    static func textColor(on accent: Color) -> Color {
        accent == .white ? .black : .white
    }

    private static var locale: Locale { AppLocaleManager.shared.locale }

    private static func formatter(_ template: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    static func month(_ day: CalendarDay) -> String {
        formatter("LLLL").string(from: day.noonDate).capitalized(with: locale)
    }

    static func year(_ day: CalendarDay) -> String {
        String(day.year)
    }

    static func weekdayName(_ weekday: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.standaloneWeekdaySymbols
        guard (1...symbols.count).contains(weekday) else { return "" }
        return symbols[weekday - 1].capitalized(with: locale)
    }

    static func dayHeader(_ day: CalendarDay, today: CalendarDay) -> String {
        let name = formatter("EEEE MMMM d").string(from: day.noonDate).capitalized(with: locale)
        switch today.days(until: day) {
        case 0: return L10n.string("calendar_today", fallback: "Today") + " · " + name
        case 1: return L10n.string("calendar_tomorrow", fallback: "Tomorrow") + " · " + name
        default: return name
        }
    }

    /// "S2E6", or a release label for movies and premieres.
    static func tag(_ entry: CalendarEntry) -> String? {
        var parts: [String] = []
        if let s = entry.seasonNumber, let e = entry.episodeNumber {
            parts.append("S\(s)E\(e)")
        }
        if let label = releaseLabel(entry.releaseKind) {
            parts.append(label)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func subtitle(_ entry: CalendarEntry) -> String? {
        switch entry.kind {
        case .series: return entry.episodeName
        case .movie: return L10n.string("calendar_movie", fallback: "Movie")
        }
    }

    /// The line under the title when the episode's name is a spoiler.
    static func spoilerFreeSubtitle(_ entry: CalendarEntry) -> String? {
        guard entry.kind == .series, let number = entry.episodeNumber else { return subtitle(entry) }
        return L10n.format("calendar_episode_number", fallback: "Episode %d", number)
    }

    /// "Hide spoilers: On".
    static func option(_ title: String, isOn: Bool) -> String {
        let state = isOn
            ? L10n.string("calendar_option_on", fallback: "On")
            : L10n.string("calendar_option_off", fallback: "Off")
        return "\(title): \(state)"
    }

    static func releaseLabel(_ kind: CalendarReleaseKind) -> String? {
        switch kind {
        case .episode: return nil
        case .seasonPremiere: return L10n.string("calendar_season_premiere", fallback: "Season premiere")
        case .seriesPremiere: return L10n.string("calendar_series_premiere", fallback: "Series premiere")
        case .seasonFinale: return L10n.string("calendar_season_finale", fallback: "Season finale")
        case .theatrical: return L10n.string("calendar_in_theaters", fallback: "In theaters")
        case .digital: return L10n.string("calendar_digital", fallback: "Digital release")
        case .physical: return L10n.string("calendar_physical", fallback: "Blu-ray / DVD")
        case .release: return L10n.string("calendar_release", fallback: "Release")
        }
    }

    /// "Today", "Tomorrow" or "Next: 21 Oct".
    static func nextDate(_ day: CalendarDay, today: CalendarDay) -> String {
        if day == today { return L10n.string("calendar_today", fallback: "Today") }
        if day == today.adding(days: 1) { return L10n.string("calendar_tomorrow", fallback: "Tomorrow") }
        let formatter = DateFormatter()
        formatter.locale = AppLocaleManager.shared.locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return L10n.format("calendar_suggest_next", fallback: "Next: %@", formatter.string(from: day.noonDate))
    }

    static func skipReason(_ reason: CalendarSkipReason) -> String {
        switch reason {
        case .unsupportedId:
            return L10n.string("calendar_skip_unsupported", fallback: "No TMDB match")
        case .failed(let message):
            return message
        }
    }
}
