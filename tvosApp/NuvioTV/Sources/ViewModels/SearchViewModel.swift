import Foundation
import Combine
import OSLog

private let searchViewLogger = Logger(subsystem: "com.pyksel.nuviotvos", category: "search")

/// Content-type filter for the search screen.
enum SearchContentType: String, CaseIterable, Identifiable {
    case all, movie, series
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return L10n.string("library_type_all", fallback: "All")
        case .movie:
            return L10n.string("type_movies", fallback: L10n.string("type_movie", fallback: "Movies"))
        case .series:
            return L10n.string("type_series_plural", fallback: L10n.string("type_series", fallback: "Series"))
        }
    }
}

@MainActor
class SearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [NuvioMeta] = [] {
        didSet { resultsRevision &+= 1 }
    }
    /// Changes whenever `results` is set (see `ReleasedTitlesMemo`).
    private(set) var resultsRevision = 0
    @Published var isLoading = false
    @Published var error: String?
    @Published var emptyStateReason: CatalogSearchReason?
    @Published var selectedType: SearchContentType = .all
    @Published var recentSearches: [String] = []
    /// Last focused result card, kept here (outside the view, like
    /// `TVHomeStore.lastFocusedCardID`) so it survives the details push and
    /// returning restores that card instead of snapping to the first result.
    var lastFocusedResultID: String?

    private let repository: CatalogRepository
    private let searchTimeout: TimeInterval
    private var allResults: [NuvioMeta] = []
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    private var searchTimeoutTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    /// Runs after the raw search grid is visible: refreshes the top results'
    /// full `/meta` records so artwork and watched state match Discovery.
    /// Cancelled on every new query so stale enrichment can never be applied.
    private var enrichmentTask: Task<Void, Never>?
    /// Small in-memory cache makes repeated queries (including backspacing)
    /// instantaneous without keeping stale search data on disk. Stores the
    /// enriched results once the background enrichment finishes.
    private var cachedResults: [String: CatalogSearchOutcome] = [:]
    private var cacheOrder: [String] = []
    private var cachedSourceSignature = CinemetaCatalogRepository.searchSourceSignature
    private var sessionCommittedQuery: String?

    init(
        repository: CatalogRepository = CinemetaCatalogRepository(),
        searchTimeout: TimeInterval = 10
    ) {
        self.repository = repository
        self.searchTimeout = searchTimeout
        recentSearches = SearchHistoryStore.load()

        $searchText
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] text in
                self?.handleQueryChange(text)
            }
            .store(in: &cancellables)

        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self] text in
                self?.performSearch(query: text)
            }
            .store(in: &cancellables)

        // Source changes alter the enabled search targets; Home-only visibility
        // changes are harmless because Search does not filter by Home rows.
        for name in [
            TVHomeCatalogOrder.changedNotification,
            TVHomeCatalogOrder.snapshotChangedNotification,
            NuvioSyncManager.addonOrderChangedNotification
        ] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.searchSourcesDidChange() }
                .store(in: &cancellables)
        }
    }

    var hasQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handleQueryChange(_ query: String) {
        invalidateSourceCacheIfNeeded()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchGeneration &+= 1
            sessionCommittedQuery = nil
            searchTask?.cancel()
            enrichmentTask?.cancel()
            allResults = []
            results = []
            error = nil
            emptyStateReason = nil
            isLoading = false
            return
        }

        let cacheKey = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let cached = cachedResults[cacheKey] {
            searchGeneration &+= 1
            searchTask?.cancel()
            enrichmentTask?.cancel()
            allResults = cached.results
            applyFilter()
            error = nil
            emptyStateReason = cached.results.isEmpty ? cached.reason : nil
            isLoading = false
            return
        }

        // Cancel pending tasks and immediately enter loading state while debouncing
        // so the UI does not flash "No Results" before the search runs.
        searchGeneration &+= 1
        searchTask?.cancel()
        enrichmentTask?.cancel()
        isLoading = true
        error = nil
        emptyStateReason = nil
    }

    func performSearch(query: String) {
        invalidateSourceCacheIfNeeded()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        searchGeneration &+= 1
        let generation = searchGeneration
        searchTimeoutTask?.cancel()
        searchTask?.cancel()
        enrichmentTask?.cancel()

        guard !trimmed.isEmpty else {
            allResults = []
            results = []
            error = nil
            emptyStateReason = nil
            isLoading = false
            return
        }

        if let cached = cachedResults[cacheKey] {
            searchViewLogger.notice(
                "search cache_hit=\(true, privacy: .public) results=\(cached.results.count, privacy: .public) complete=\(true, privacy: .public)"
            )
            allResults = cached.results
            applyFilter()
            error = nil
            emptyStateReason = cached.results.isEmpty ? cached.reason : nil
            isLoading = false
            if !cached.results.isEmpty { commitRecentSearch(trimmed) }
            if SearchResultEnrichment.hasIncompleteLeadingResults(cached.results) {
                enrich(cached.results, cacheKey: cacheKey, generation: generation, cacheable: true)
            }
            return
        }

        isLoading = true
        error = nil
        emptyStateReason = nil

        let timeoutSeconds = self.searchTimeout
        searchTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleSearchTimeout(generation: generation)
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.repository.searchWithOutcome(query: trimmed)
                guard !Task.isCancelled, self.searchGeneration == generation else { return }
                self.searchTimeoutTask?.cancel()
                let found = outcome.results
                self.allResults = found
                if outcome.isComplete {
                    self.cache(outcome, for: cacheKey)
                }
                self.applyFilter()
                if !found.isEmpty { self.commitRecentSearch(trimmed) }
                self.emptyStateReason = outcome.isComplete
                    ? (found.isEmpty ? outcome.reason : nil)
                    : .requestFailed
                if self.emptyStateReason == .requestFailed && found.isEmpty {
                    self.error = L10n.string(
                        "search_error_network",
                        fallback: "Couldn’t complete search. Check your connection and try again."
                    )
                } else {
                    self.error = nil
                }
                self.isLoading = false
                if SearchResultEnrichment.hasIncompleteLeadingResults(found) {
                    self.enrich(
                        found,
                        cacheKey: cacheKey,
                        generation: generation,
                        cacheable: outcome.isComplete
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.searchGeneration == generation else { return }
                self.searchTimeoutTask?.cancel()
                self.emptyStateReason = .requestFailed
                self.error = CatalogSearchReason.requestFailed.title
                self.isLoading = false
            }
        }
    }

    private func handleSearchTimeout(generation: UInt64) {
        guard self.searchGeneration == generation, self.isLoading else { return }
        self.searchTask?.cancel()
        self.emptyStateReason = .requestFailed
        self.error = L10n.string(
            "search_error_timeout",
            fallback: "Search timed out. Check your connection and try again."
        )
        self.isLoading = false
    }

    /// Refreshes the top raw results with their full `/meta` records without
    /// blocking the grid already on screen, then swaps them into `allResults`
    /// and the filter. Complete outcomes may also update the query cache. Cancelled whenever the query
    /// changes; the query-key guard is a second line of defense against a
    /// stale enrichment landing on a newer result list.
    @MainActor
    private func enrich(_ found: [NuvioMeta], cacheKey: String, generation: UInt64, cacheable: Bool) {
        enrichmentTask?.cancel()
        enrichmentTask = Task { [weak self] in
            guard let self else { return }
            let enriched = await SearchResultEnrichment.enrich(
                found,
                repository: self.repository
            )
            guard !Task.isCancelled,
                  self.searchGeneration == generation,
                  self.normalizedQuery() == cacheKey else { return }
            self.allResults = enriched
            if cacheable {
                self.cache(CatalogSearchOutcome(results: enriched, isComplete: true), for: cacheKey)
            }
            self.applyFilter()
        }
    }

    private func normalizedQuery() -> String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    func setType(_ type: SearchContentType) {
        selectedType = type
        applyFilter()
    }

    private func applyFilter() {
        switch selectedType {
        case .all: results = allResults
        case .movie: results = allResults.filter { $0.type == "movie" }
        case .series: results = allResults.filter { $0.type == "series" }
        }
    }

    func applyRecent(_ term: String) {
        searchText = term
    }

    func clearRecent() {
        sessionCommittedQuery = nil
        recentSearches = []
        SearchHistoryStore.save([])
    }

    /// Re-reads the shared recent-search list. `NetflixSearchViewModel` writes
    /// the same key, so whichever search style isn't on screen goes stale until
    /// its view reappears.
    func reloadRecent() {
        recentSearches = SearchHistoryStore.load()
    }

    func clear() {
        sessionCommittedQuery = nil
        emptyStateReason = nil
        searchText = ""
    }

    func commitCurrentSearch() {
        guard hasQuery else { return }
        commitRecentSearch(searchText)
    }

    private func commitRecentSearch(_ term: String) {
        let (updated, newSession) = SearchHistoryStore.commit(
            term,
            current: recentSearches,
            sessionQuery: sessionCommittedQuery
        )
        guard updated != recentSearches else { return }
        sessionCommittedQuery = newSession
        recentSearches = updated
        SearchHistoryStore.save(updated)
    }

    private func searchSourcesDidChange() {
        guard invalidateSourceCacheIfNeeded() else { return }
        if hasQuery { performSearch(query: searchText) }
    }

    @discardableResult
    private func invalidateSourceCacheIfNeeded() -> Bool {
        let signature = CinemetaCatalogRepository.searchSourceSignature
        guard signature != cachedSourceSignature else { return false }
        cachedSourceSignature = signature
        searchGeneration &+= 1
        searchTimeoutTask?.cancel()
        searchTask?.cancel()
        enrichmentTask?.cancel()
        cachedResults.removeAll()
        cacheOrder.removeAll()
        allResults = []
        results = []
        error = nil
        emptyStateReason = nil
        isLoading = false
        return true
    }

    private func cache(_ outcome: CatalogSearchOutcome, for key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        cachedResults[key] = outcome

        while cacheOrder.count > 12 {
            cachedResults.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
