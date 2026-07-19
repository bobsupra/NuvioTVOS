import Foundation
import Combine

/// Content type for the Discover grid.
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

/// Catalog/sort source. Maps to the Cinemeta catalog IDs that actually return data.
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
    @Published private(set) var genres: [String] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var error: String?

    @Published private(set) var type: DiscoverType = .movie
    @Published private(set) var sort: DiscoverSort = .popular
    @Published private(set) var genre: String? = nil   // nil == All Genres

    private let repository: CatalogRepository
    private var page = 1
    private var hasMore = true
    private var loadTask: Task<Void, Never>?

    init(repository: CatalogRepository = CinemetaCatalogRepository()) {
        self.repository = repository
        loadGenres()
        reload()
    }

    func setType(_ newType: DiscoverType) {
        guard type != newType else { return }
        type = newType
        genre = nil
        loadGenres()
        reload()
    }

    func setSort(_ newSort: DiscoverSort) {
        guard sort != newSort else { return }
        sort = newSort
        reload()
    }

    func setGenre(_ newGenre: String?) {
        guard genre != newGenre else { return }
        genre = newGenre
        reload()
    }

    func reload() {
        loadTask?.cancel()
        page = 1
        hasMore = true
        isLoading = true
        isLoadingMore = false
        error = nil
        loadTask = Task { await load(reset: true) }
    }

    /// Loads the next page when the grid scrolls near its end.
    func loadMoreIfNeeded(currentItem: NuvioMeta) {
        guard hasMore, !isLoading, !isLoadingMore else { return }
        guard items.suffix(8).contains(where: { $0.id == currentItem.id }) else { return }
        isLoadingMore = true
        Task { await load(reset: false) }
    }

    private func load(reset: Bool) async {
        do {
            let result = try await repository.browseCatalog(
                contentType: type.rawValue,
                catalogId: sort.catalogId,
                page: page,
                genre: genre,
                year: nil,
                sort: nil
            )
            if Task.isCancelled { return }
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
            if Task.isCancelled { return }
            self.error = "Couldn’t load Discover. Check your connection and try again."
            isLoading = false
            isLoadingMore = false
        }
    }

    private func loadGenres() {
        Task {
            let loaded = (try? await repository.getGenres(contentType: type.rawValue)) ?? []
            if !Task.isCancelled { genres = loaded }
        }
    }
}
