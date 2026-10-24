import Foundation
import Combine

/// Netflix-style alternative to `SearchViewModel`. Same catalog search use
/// case (`CatalogRepository.search(query:)`) and the same debounce/cache/
/// recent-search shape. Its `searchText` binding is shared directly with the
/// tvOS `.searchable` host used by `NetflixSearchView`.
@MainActor
class NetflixSearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [NuvioMeta] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var selectedType: SearchContentType = .all
    @Published var recentSearches: [String] = []

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
    private var cachedResults: [String: [NuvioMeta]] = [:]
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

        // Home toggles and incoming profile sync must invalidate in-memory
        // search results rather than reusing posters from disabled catalogs.
        for name in [TVHomeCatalogOrder.changedNotification, TVHomeCatalogOrder.snapshotChangedNotification] {
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
            searchTimeoutTask?.cancel()
            searchTask?.cancel()
            enrichmentTask?.cancel()
            allResults = []
            results = []
            error = nil
            isLoading = false
            return
        }

        let cacheKey = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if let cached = cachedResults[cacheKey] {
            searchGeneration &+= 1
            searchTimeoutTask?.cancel()
            searchTask?.cancel()
            enrichmentTask?.cancel()
            allResults = cached
            applyFilter()
            error = nil
            isLoading = false
            return
        }

        // Cancel pending tasks and immediately enter loading state while debouncing
        // so the UI does not flash "No Results" before the search runs.
        searchGeneration &+= 1
        searchTimeoutTask?.cancel()
        searchTask?.cancel()
        enrichmentTask?.cancel()
        isLoading = true
        error = nil
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
            isLoading = false
            return
        }

        if let cached = cachedResults[cacheKey] {
            allResults = cached
            applyFilter()
            error = nil
            isLoading = false
            if !cached.isEmpty { commitRecentSearch(trimmed) }
            if SearchResultEnrichment.hasIncompleteLeadingResults(cached) {
                enrich(cached, cacheKey: cacheKey, generation: generation)
            }
            return
        }

        isLoading = true
        error = nil

        let timeoutSeconds = self.searchTimeout
        searchTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleSearchTimeout(generation: generation)
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await self.repository.search(query: trimmed)
                guard !Task.isCancelled, self.searchGeneration == generation else { return }
                self.searchTimeoutTask?.cancel()
                self.allResults = found
                self.cache(found, for: cacheKey)
                self.applyFilter()
                if !found.isEmpty { self.commitRecentSearch(trimmed) }
                self.isLoading = false
                if SearchResultEnrichment.hasIncompleteLeadingResults(found) {
                    self.enrich(found, cacheKey: cacheKey, generation: generation)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.searchGeneration == generation else { return }
                self.searchTimeoutTask?.cancel()
                self.error = L10n.string(
                    "search_error_network",
                    fallback: "Couldn’t complete search. Check your connection and try again."
                )
                self.isLoading = false
            }
        }
    }

    private func handleSearchTimeout(generation: UInt64) {
        guard self.searchGeneration == generation, self.isLoading else { return }
        self.searchTask?.cancel()
        self.error = L10n.string(
            "search_error_timeout",
            fallback: "Search timed out. Check your connection and try again."
        )
        self.isLoading = false
    }

    /// Refreshes the top raw results with their full `/meta` records without
    /// blocking the grid already on screen, then swaps them into `allResults`
    /// (and the filter) and the query cache. Cancelled whenever the query
    /// changes; the query-key guard is a second line of defense against a
    /// stale enrichment landing on a newer result list.
    @MainActor
    private func enrich(_ found: [NuvioMeta], cacheKey: String, generation: UInt64) {
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
            self.cache(enriched, for: cacheKey)
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

    /// Re-reads the shared recent-search list. `SearchViewModel` writes the
    /// same key, so whichever search style isn't on screen goes stale until its
    /// view reappears.
    func reloadRecent() {
        recentSearches = SearchHistoryStore.load()
    }

    func clear() {
        sessionCommittedQuery = nil
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
        isLoading = false
        return true
    }

    private func cache(_ results: [NuvioMeta], for key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        cachedResults[key] = results

        while cacheOrder.count > 12 {
            cachedResults.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}
