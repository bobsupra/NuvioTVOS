import Foundation
import Combine

@MainActor
public class LibraryViewModel: ObservableObject {
    @Published public var items: [StremioMeta] = []
    @Published public var sortOption: SortOption = .dateAdded
    @Published public var groupOption: GroupOption = .none
    @Published public var contentTypeFilter: String?
    @Published public var genreFilter: String?
    /// Last focused card, kept here (outside the view, like
    /// `TVHomeStore.lastFocusedCardID`) so it survives the details push and
    /// returning restores that card instead of snapping to the top.
    public var lastFocusedItemID: String?
    private var libraryObserver: NSObjectProtocol?
    
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
    
    public init() {
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
    }

    deinit {
        if let libraryObserver {
            NotificationCenter.default.removeObserver(libraryObserver)
        }
    }
    
    public func loadLibrary() {
        self.items = LibraryStore.items().map(\.stremioMeta)
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
