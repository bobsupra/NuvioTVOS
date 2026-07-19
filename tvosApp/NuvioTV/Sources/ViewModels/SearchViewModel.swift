import Foundation
import Combine

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
    @Published var results: [NuvioMeta] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var selectedType: SearchContentType = .all
    @Published var recentSearches: [String] = []
    /// Last focused result card, kept here (outside the view, like
    /// `TVHomeStore.lastFocusedCardID`) so it survives the details push and
    /// returning restores that card instead of snapping to the first result.
    var lastFocusedResultID: String?

    private let repository: CatalogRepository
    private var allResults: [NuvioMeta] = []
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    private let recentKey = "nuvio.search.recent"

    init(repository: CatalogRepository = CinemetaCatalogRepository()) {
        self.repository = repository
        recentSearches = UserDefaults.standard.stringArray(forKey: recentKey) ?? []

        $searchText
            .debounce(for: .milliseconds(450), scheduler: DispatchQueue.main)
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
        searchTask?.cancel()

        guard !trimmed.isEmpty else {
            allResults = []
            results = []
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

    func clear() {
        searchText = ""
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
}
