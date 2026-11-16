import Foundation
import Combine

/// The titles synced from the user's own servers (Plex, Jellyfin, SMB), for
/// Library's Servers tab. They come from the same local indexes that feed the
/// server rows on Home.
@MainActor
final class ServerLibraryViewModel: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case plex, jellyfin, smb

        var id: String { rawValue }

        var title: String {
            switch self {
            case .plex: return "Plex"
            case .jellyfin: return "Jellyfin"
            case .smb: return "SMB"
            }
        }
    }

    enum SortOption: String, CaseIterable, Identifiable {
        case title, newest

        var id: String { rawValue }

        var localizedTitle: String {
            switch self {
            case .title: return L10n.string("server_library_sort_title", fallback: "Title")
            case .newest: return L10n.string("server_library_sort_newest", fallback: "Newest")
            }
        }
    }

    /// One library on one server, as it is named there.
    struct Group: Identifiable, Equatable {
        let id: String
        let source: Source
        let title: String
        var items: [NuvioMeta]
    }

    @Published private(set) var groups: [Group] = []
    @Published private(set) var isLoading = false
    @Published var sourceFilter: Source?
    /// `movie` or `series`; nil shows both.
    @Published var contentTypeFilter: String?
    @Published var sortOption: SortOption = .title

    private let resolveSMBMeta: (String, String) async -> NuvioMeta?
    private var observers: [NSObjectProtocol] = []
    private var loadGeneration = 0

    init(resolveSMBMeta: @escaping (String, String) async -> NuvioMeta? = { id, type in
        try? await CinemetaCatalogRepository().getMetadata(id: id, type: type)
    }) {
        self.resolveSMBMeta = resolveSMBMeta
        let names = [
            PlexLibraryIndex.changedNotification,
            JellyfinLibraryIndex.changedNotification,
            SMBLibraryIndex.changedNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.load() }
            }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Whether any server has synced titles; the tab is hidden otherwise.
    var isAvailable: Bool {
        !PlexLibraryIndex.shared.titles().isEmpty
            || !JellyfinLibraryIndex.shared.titles().isEmpty
            || !SMBLibraryIndex.shared.titles().isEmpty
    }

    var availableSources: [Source] {
        Source.allCases.filter { source in groups.contains { $0.source == source } }
    }

    /// The groups after the source and type filters, sorted, without empty ones.
    /// A title synced into two libraries keeps its first card, so ids stay unique.
    var visibleGroups: [Group] {
        var seen = Set<String>()
        return groups.compactMap { group -> Group? in
            if let sourceFilter, group.source != sourceFilter { return nil }
            var items = group.items.filter { meta in
                (contentTypeFilter == nil || Self.normalizedType(meta.type) == contentTypeFilter)
                    && seen.insert(meta.id).inserted
            }
            guard !items.isEmpty else { return nil }
            items = Self.sorted(items, by: sortOption)
            return Group(id: group.id, source: group.source, title: group.title, items: items)
        }
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = groups.isEmpty
        var loaded = Self.plexGroups() + Self.jellyfinGroups()
        groups = loaded
        // SMB titles are stored as ids only; their metadata is looked up.
        if let smb = await smbGroup(), generation == loadGeneration {
            loaded.append(smb)
            groups = loaded
        }
        if generation == loadGeneration { isLoading = false }
    }

    // MARK: - Sources

    private static func plexGroups() -> [Group] {
        let index = PlexLibraryIndex.shared
        let grouped = Dictionary(grouping: index.titles()) { "\($0.serverID):\($0.libraryID)" }
        let serverOrder = Dictionary(uniqueKeysWithValues: PlexServerStore.shared.servers.enumerated().map {
            ($0.element.id, $0.offset)
        })
        return grouped.keys
            .sorted { lhs, rhs in
                let l = grouped[lhs]!.first!, r = grouped[rhs]!.first!
                let lo = serverOrder[l.serverID] ?? Int.max, ro = serverOrder[r.serverID] ?? Int.max
                if lo != ro { return lo < ro }
                return (l.libraryName, lhs) < (r.libraryName, rhs)
            }
            .compactMap { key -> Group? in
                guard let titles = grouped[key], let first = titles.first else { return nil }
                let metas = titles.compactMap { index.meta(for: $0) }
                guard !metas.isEmpty else { return nil }
                return Group(id: "plex:\(key)", source: .plex, title: first.libraryName, items: metas)
            }
    }

    private static func jellyfinGroups() -> [Group] {
        let index = JellyfinLibraryIndex.shared
        let fallbackTitle = L10n.string("home_jellyfin_titles", fallback: "Jellyfin")
        let titles = index.titles()
        let grouped = Dictionary(grouping: titles) { "\($0.serverID):\($0.libraryID ?? "")" }
        let serverOrder = Dictionary(uniqueKeysWithValues: JellyfinServerStore.shared.servers.enumerated().map {
            ($0.element.id, $0.offset)
        })
        return grouped.keys
            .sorted { lhs, rhs in
                let l = grouped[lhs]!.first!, r = grouped[rhs]!.first!
                let lo = serverOrder[l.serverID] ?? Int.max, ro = serverOrder[r.serverID] ?? Int.max
                if lo != ro { return lo < ro }
                return (l.libraryName ?? fallbackTitle, lhs) < (r.libraryName ?? fallbackTitle, rhs)
            }
            .compactMap { key -> Group? in
                guard let titles = grouped[key], let first = titles.first else { return nil }
                let metas = titles.compactMap { index.meta(for: $0) }
                guard !metas.isEmpty else { return nil }
                return Group(
                    id: "jellyfin:\(key)",
                    source: .jellyfin,
                    title: first.libraryName ?? fallbackTitle,
                    items: metas
                )
            }
    }

    private func smbGroup() async -> Group? {
        let indexed = SMBLibraryIndex.shared.titles()
        guard !indexed.isEmpty else { return nil }
        var metasByContentId: [String: NuvioMeta] = [:]
        var iterator = indexed.makeIterator()
        let resolve = resolveSMBMeta
        await withTaskGroup(of: (String, NuvioMeta?).self) { group in
            func startNext() {
                guard let title = iterator.next() else { return }
                group.addTask { (title.contentId, await resolve(title.contentId, title.type)) }
            }
            for _ in 0..<6 { startNext() }
            while let (contentId, meta) = await group.next() {
                if let meta { metasByContentId[contentId] = meta }
                startNext()
            }
        }
        let metas = indexed.compactMap { metasByContentId[$0.contentId] }
        guard !metas.isEmpty else { return nil }
        return Group(
            id: "smb",
            source: .smb,
            title: L10n.string("home_local_titles", fallback: "Local titles"),
            items: metas
        )
    }

    // MARK: - Filtering and sorting

    static func normalizedType(_ type: String) -> String {
        ["series", "tv", "show", "tvshow"].contains(type.lowercased()) ? "series" : "movie"
    }

    static func sorted(_ items: [NuvioMeta], by option: SortOption) -> [NuvioMeta] {
        items.sorted { lhs, rhs in
            if option == .newest, lhs.year != rhs.year {
                return (lhs.year ?? Int.min) > (rhs.year ?? Int.min)
            }
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
