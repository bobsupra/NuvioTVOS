import Foundation
import Combine

/// Content type for the Discover grid (backward compatibility enum).
enum DiscoverType: String, CaseIterable, Identifiable {
    case movie, series
    var id: String { rawValue }
    var title: String {
        switch self {
        case .movie:
            return L10n.string("type_movies", fallback: L10n.string("type_movie", fallback: "Movies"))
        case .series:
            return L10n.string("type_series_plural", fallback: L10n.string("type_series", fallback: "Series"))
        }
    }
}

/// Catalog/sort source (backward compatibility enum).
enum DiscoverSort: String, CaseIterable, Identifiable {
    case popular   // Cinemeta "top"
    case topRated  // Cinemeta "imdbRating"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .popular:
            return L10n.string("tvos_discover_popular", fallback: "Popular")
        case .topRated:
            return L10n.string("tvos_discover_top_rated", fallback: "Top Rated")
        }
    }
    var catalogId: String { self == .popular ? "top" : "imdbRating" }
}

@MainActor
final class DiscoverViewModel: ObservableObject {
    @Published private(set) var items: [NuvioMeta] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var error: String?

    // Dynamic sources mirroring Android DiscoverUiState
    @Published private(set) var discoverSources: [DiscoverCatalogOption] = []
    @Published private(set) var typeOptions: [String] = ["movie", "series"]
    @Published private(set) var selectedType: String = "movie"
    @Published private(set) var catalogOptions: [DiscoverCatalogOption] = []
    @Published private(set) var selectedCatalogKey: String? = nil
    @Published private(set) var selectedGenre: String? = nil   // nil == All Genres

    // Backwards-compatible properties for existing consumers
    var type: DiscoverType {
        DiscoverType(rawValue: selectedType) ?? .movie
    }
    var sort: DiscoverSort {
        if let key = selectedCatalogKey, key.contains("imdbRating") {
            return .topRated
        }
        return .popular
    }
    var genre: String? { selectedGenre }
    var genres: [String] { genreOptions }

    var selectedCatalog: DiscoverCatalogOption? {
        catalogOptions.first(where: { $0.key == selectedCatalogKey }) ?? catalogOptions.first
    }

    var genreOptions: [String] {
        selectedCatalog?.genreOptions ?? []
    }

    var isGenreRequired: Bool {
        selectedCatalog?.genreRequired ?? false
    }

    var currentTypeTitle: String {
        typeTitle(for: selectedType)
    }

    func typeTitle(for type: String) -> String {
        switch type.lowercased() {
        case "movie", "movies":
            return L10n.string("type_movies", fallback: L10n.string("type_movie", fallback: "Movies"))
        case "series", "tv", "show", "shows":
            return L10n.string("type_series_plural", fallback: L10n.string("type_series", fallback: "Series"))
        case "anime":
            return L10n.string("type_anime", fallback: "Anime")
        default:
            return type.capitalized
        }
    }

    private let repository: CatalogRepository
    private(set) var page = 1
    private(set) var hasMore = true
    private var loadTask: Task<Void, Never>?
    private var paginationTask: Task<Void, Never>?
    private var sourcesTask: Task<Void, Never>?
    private var requestGeneration: UInt64 = 0

    init(repository: CatalogRepository = CinemetaCatalogRepository()) {
        self.repository = repository
        loadSourcesAndInitialFeed()
    }

    func loadSourcesAndInitialFeed() {
        sourcesTask?.cancel()
        sourcesTask = Task { @MainActor in
            let sources = await repository.getDiscoverSources()
            if Task.isCancelled { return }
            self.applySources(sources)
        }
    }

    private func applySources(_ sources: [DiscoverCatalogOption]) {
        self.discoverSources = sources
        let types = Array(NSOrderedSet(array: sources.map(\.type)).compactMap { $0 as? String })
            .sorted { lhs, rhs in
                let order: (String) -> Int = {
                    switch $0.lowercased() {
                    case "movie", "movies": return 0
                    case "series", "tv", "show", "shows": return 1
                    case "anime": return 2
                    default: return 9
                    }
                }
                return order(lhs) < order(rhs)
            }
        self.typeOptions = types.isEmpty ? ["movie", "series"] : types

        if !self.typeOptions.contains(self.selectedType) {
            self.selectedType = self.typeOptions.first ?? "movie"
        }

        let catalogs = sources.filter { $0.type.caseInsensitiveCompare(self.selectedType) == .orderedSame || AddonTransportUrls.isTypeEquivalent($0.type, self.selectedType) }
        self.catalogOptions = catalogs

        let currentOption = catalogs.first(where: { $0.key == self.selectedCatalogKey }) ?? catalogs.first
        self.selectedCatalogKey = currentOption?.key

        if let currentOption {
            if let selectedGenre = self.selectedGenre, currentOption.genreOptions.contains(selectedGenre) {
                // Keep selected genre
            } else if currentOption.genreRequired {
                self.selectedGenre = currentOption.genreOptions.first
            } else {
                self.selectedGenre = nil
            }
        }

        reload()
    }

    func setType(_ newType: DiscoverType) {
        setType(newType.rawValue)
    }

    func setType(_ newType: String) {
        guard selectedType != newType else { return }
        selectedType = newType
        let catalogs = discoverSources.filter { $0.type.caseInsensitiveCompare(newType) == .orderedSame || AddonTransportUrls.isTypeEquivalent($0.type, newType) }
        catalogOptions = catalogs
        let currentOption = catalogs.first
        selectedCatalogKey = currentOption?.key
        selectedGenre = currentOption?.genreRequired == true ? currentOption?.genreOptions.first : nil
        reload()
    }

    func setSort(_ newSort: DiscoverSort) {
        if let matching = catalogOptions.first(where: { $0.catalogId.caseInsensitiveCompare(newSort.catalogId) == .orderedSame }) {
            setCatalog(matching)
        } else if let matchingKey = catalogOptions.first(where: { $0.key.localizedCaseInsensitiveContains(newSort.catalogId) }) {
            setCatalog(matchingKey)
        } else if let first = catalogOptions.first {
            setCatalog(first)
        }
    }

    func setCatalog(_ catalog: DiscoverCatalogOption) {
        guard selectedCatalogKey != catalog.key else { return }
        selectedCatalogKey = catalog.key
        if let selectedGenre, catalog.genreOptions.contains(selectedGenre) {
            // Keep selected genre
        } else if catalog.genreRequired {
            selectedGenre = catalog.genreOptions.first
        } else {
            selectedGenre = nil
        }
        reload()
    }

    func setGenre(_ newGenre: String?) {
        guard selectedGenre != newGenre else { return }
        selectedGenre = newGenre
        reload()
    }

    func reload() {
        requestGeneration &+= 1
        let generation = requestGeneration
        loadTask?.cancel()
        paginationTask?.cancel()
        page = 1
        hasMore = true
        isLoading = true
        isLoadingMore = false
        error = nil
        loadTask = Task { await load(reset: true, generation: generation) }
    }

    /// Loads the next page when the grid scrolls near its end.
    func loadMoreIfNeeded(currentItem: NuvioMeta) {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        guard items.suffix(8).contains(where: { $0.id == currentItem.id }) else { return }
        isLoadingMore = true
        let generation = requestGeneration
        paginationTask = Task { await load(reset: false, generation: generation) }
    }

    private func load(reset: Bool, generation: UInt64) async {
        guard let catalog = selectedCatalog else {
            // Fallback load if sources haven't resolved yet
            do {
                let result = try await repository.browseCatalog(
                    contentType: selectedType,
                    catalogId: "top",
                    page: page,
                    genre: selectedGenre,
                    year: nil,
                    sort: nil
                )
                guard !Task.isCancelled, self.requestGeneration == generation else { return }
                if reset {
                    items = result.items
                } else {
                    let existing = Set(items.map(\.id))
                    items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
                }
                hasMore = result.hasMore
                page = result.page + 1
                isLoading = false
                isLoadingMore = false
            } catch {
                guard !Task.isCancelled, self.requestGeneration == generation else { return }
                self.error = "Couldn’t load Discover. Check your connection and try again."
                isLoading = false
                isLoadingMore = false
            }
            return
        }

        do {
            let result = try await repository.browseDiscover(
                option: catalog,
                page: page,
                genre: selectedGenre
            )
            guard !Task.isCancelled, self.requestGeneration == generation else { return }
            if reset {
                items = result.items
            } else {
                let existing = Set(items.map(\.id))
                items.append(contentsOf: result.items.filter { !existing.contains($0.id) })
            }
            hasMore = result.hasMore
            page = result.page + 1
            isLoading = false
            isLoadingMore = false
        } catch {
            guard !Task.isCancelled, self.requestGeneration == generation else { return }
            self.error = "Couldn’t load Discover. Check your connection and try again."
            isLoading = false
            isLoadingMore = false
        }
    }
}
