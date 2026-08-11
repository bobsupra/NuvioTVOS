import Foundation
import Combine

/// Netflix-style alternative to `SearchViewModel`. Same catalog search use
/// case (`CatalogRepository.search(query:)`) and the same debounce/cache/
/// recent-search shape, but exposes a couple of small keyboard-input helpers
/// instead of a raw `searchText` binding, since `NetflixSearchView` builds
/// its query from an on-screen key-by-key keyboard rather than a hidden text
/// field.
@MainActor
class NetflixSearchViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var results: [NuvioMeta] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var selectedType: SearchContentType = .all
    @Published var recentSearches: [String] = []

    private let repository: CatalogRepository
    private var allResults: [NuvioMeta] = []
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    /// Small in-memory cache makes repeated queries (including backspacing)
    /// instantaneous without keeping stale search data on disk.
    private var cachedResults: [String: [NuvioMeta]] = [:]
    private var cacheOrder: [String] = []
    // Same UserDefaults key as `SearchViewModel` so a user's search history
    // carries over regardless of which search UI is wired up to navigation.
    private let recentKey = "nuvio.search.recent"

    init(repository: CatalogRepository = CinemetaCatalogRepository()) {
        self.repository = repository
        recentSearches = UserDefaults.standard.stringArray(forKey: recentKey) ?? []

        $searchText
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] text in
                self?.performSearch(query: text)
            }
            .store(in: &cancellables)
    }

    var hasQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func performSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        searchTask?.cancel()

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
            return
        }

        isLoading = true
        error = nil

        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let found = try await self.repository.search(query: trimmed)
                if Task.isCancelled { return }
                self.allResults = found
                self.cache(found, for: cacheKey)
                self.applyFilter()
                if !found.isEmpty { self.commitRecentSearch(trimmed) }
                self.isLoading = false
            } catch {
                if Task.isCancelled { return }
                self.error = "Couldn’t complete search. Check your connection and try again."
                self.isLoading = false
            }
        }
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
        recentSearches = []
        saveRecent()
    }

    /// Re-reads the shared recent-search list. `SearchViewModel` writes the
    /// same key, so whichever search style isn't on screen goes stale until its
    /// view reappears.
    func reloadRecent() {
        recentSearches = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    func clear() {
        searchText = ""
    }

    // MARK: - On-screen keyboard input

    /// Appends one key from the on-screen keyboard. The keyboard has no
    /// shift state, so letters always arrive lowercase.
    func typeCharacter(_ character: String) {
        searchText += character
    }

    func deleteLastCharacter() {
        guard !searchText.isEmpty else { return }
        searchText.removeLast()
    }

    private func commitRecentSearch(_ term: String) {
        var list = recentSearches.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        list.insert(term, at: 0)
        recentSearches = Array(list.prefix(8))
        saveRecent()
    }

    private func saveRecent() {
        UserDefaults.standard.set(recentSearches, forKey: recentKey)
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
