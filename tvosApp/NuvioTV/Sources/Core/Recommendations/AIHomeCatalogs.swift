import Foundation

/// "For You" rows on Home, chosen by the viewer's AI (Settings > Integrations >
/// Surprise Me > For You rows). One row per kind the viewer turns on: movies,
/// series, anime movies and anime series.
///
/// The AI learns from the whole history (watched, every library, Continue
/// Watching) and answers with titles and years. Each title is looked up on
/// TMDB, so the row shows TMDB's data, never text from the AI; anything TMDB
/// can't find or the viewer already watched is dropped.
///
/// Rows are cached per profile and rebuilt at most once a day, or sooner when
/// the viewer has watched or saved 10 more titles, so Home never waits on the
/// AI and a provider's quota isn't spent on every launch.
enum AIHomeCatalogKind: String, CaseIterable, Codable, Sendable {
    case movies
    case series
    case animeMovies
    case animeSeries

    var settingsKey: String {
        switch self {
        case .movies: return SettingsKey.aiCatalogMovies
        case .series: return SettingsKey.aiCatalogSeries
        case .animeMovies: return SettingsKey.aiCatalogAnimeMovies
        case .animeSeries: return SettingsKey.aiCatalogAnimeSeries
        }
    }

    var sectionID: String { "\(AIHomeCatalogs.sectionIDPrefix)\(rawValue)" }

    var title: String {
        switch self {
        case .movies: return L10n.string("ai_catalog_movies", fallback: "✨ For You · Movies")
        case .series: return L10n.string("ai_catalog_series", fallback: "✨ For You · Series")
        case .animeMovies: return L10n.string("ai_catalog_anime_movies", fallback: "✨ For You · Anime Movies")
        case .animeSeries: return L10n.string("ai_catalog_anime_series", fallback: "✨ For You · Anime Series")
        }
    }

    /// Films are looked up as movies on TMDB, the rest as series.
    var isFilm: Bool { self == .movies || self == .animeMovies }

    var contentType: String { isFilm ? "movie" : "series" }

    /// What the AI is asked for.
    var promptNoun: String {
        switch self {
        case .movies: return "movies (no anime)"
        case .series: return "TV series (no anime)"
        case .animeMovies: return "anime films (no series)"
        case .animeSeries: return "anime series (no films)"
        }
    }

    func isEnabled(in defaults: UserDefaults = ProfileSettings.current) -> Bool {
        defaults.bool(forKey: settingsKey)
    }
}

struct AIHomeCatalogSuggestion: Equatable, Sendable {
    let title: String
    let year: Int?
    let isFilm: Bool
}

struct AIHomeCatalogCache: Codable, Equatable {
    struct Row: Codable, Equatable {
        let kind: AIHomeCatalogKind
        let items: [NuvioMeta]
    }

    let rows: [Row]
    let builtAt: Date
    /// How many distinct titles the history had when the rows were built.
    let historyCount: Int
    let provider: String
}

enum AIHomeCatalogs {
    static let sectionIDPrefix = "ai_for_you_"
    /// Titles shown per row: enough to browse, small enough to look up quickly.
    static let rowSize = 30
    /// Titles asked from the AI per row, to have spares when some are dropped.
    static let requestedCount = 40
    static let rebuildInterval: TimeInterval = 24 * 60 * 60
    static let historyChangeForRebuild = 10
    static let lookupConcurrency = 6
    static let cacheKey = "nuvio.tv.aiCatalogs.cache"

    static func isSectionID(_ id: String) -> Bool { id.hasPrefix(sectionIDPrefix) }

    static func enabledKinds(in defaults: UserDefaults = ProfileSettings.current) -> [AIHomeCatalogKind] {
        AIHomeCatalogKind.allCases.filter { $0.isEnabled(in: defaults) }
    }

    // MARK: Cache

    static func loadCache(in defaults: UserDefaults = ProfileSettings.current) -> AIHomeCatalogCache? {
        guard let data = defaults.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(AIHomeCatalogCache.self, from: data)
    }

    static func saveCache(_ cache: AIHomeCatalogCache?, in defaults: UserDefaults = ProfileSettings.current) {
        guard let cache, let data = try? JSONEncoder().encode(cache) else {
            defaults.removeObject(forKey: cacheKey)
            return
        }
        defaults.set(data, forKey: cacheKey)
    }

    static func needsRebuild(
        cache: AIHomeCatalogCache?,
        kinds: [AIHomeCatalogKind],
        historyCount: Int,
        provider: String,
        now: Date = Date()
    ) -> Bool {
        guard !kinds.isEmpty else { return false }
        guard let cache else { return true }
        if cache.provider != provider { return true }
        if Set(kinds) != Set(cache.rows.map(\.kind)) { return true }
        if now.timeIntervalSince(cache.builtAt) >= rebuildInterval { return true }
        return abs(historyCount - cache.historyCount) >= historyChangeForRebuild
    }

    /// Home rows from the cache, in Movies, Series, Anime order, only for the
    /// kinds turned on and only with titles still unwatched.
    static func sections(
        from cache: AIHomeCatalogCache?,
        kinds: [AIHomeCatalogKind],
        isWatched: (NuvioMeta) -> Bool
    ) -> [TVHomeSection] {
        guard let cache else { return [] }
        return kinds.compactMap { kind in
            guard let row = cache.rows.first(where: { $0.kind == kind }) else { return nil }
            let items = row.items.filter { !isWatched($0) }
            guard !items.isEmpty else { return nil }
            return TVHomeSection(
                id: kind.sectionID,
                title: kind.title,
                items: items,
                contentType: kind.contentType,
                addonName: L10n.string("ai_catalog_source", fallback: "AI")
            )
        }
    }

    // MARK: Prompt

    static func prompt(
        kind: AIHomeCatalogKind,
        context: SurpriseMeAIContext,
        excludedTitles: [NuvioMeta],
        language: String
    ) -> String {
        let base = SurpriseMeAI.prompt(context: context, candidates: [], language: language)
        // Reuse what the viewer is (everything up to the Surprise Me task).
        let profile = base.components(separatedBy: "\n\n1. ").first ?? base
        let avoid = SurpriseMeHistory.unique(excludedTitles).prefix(60)
            .map { meta in meta.year.map { "\(meta.name) (\($0))" } ?? meta.name }
            .joined(separator: "; ")
        return """
        \(profile)

        Build a personal row of \(requestedCount) \(kind.promptNoun) for this viewer's home screen, \
        best match first. Mix close matches with a few discoveries they wouldn't find themselves. \
        Never include anything they already watched\(avoid.isEmpty ? "" : " or these titles: \(avoid)"). \
        Only real, released titles, with the exact original title and the release year.

        Answer with JSON only: {"titles":[{"title":"...","year":2016}]}.
        """
    }

    static func parse(_ text: String, kind: AIHomeCatalogKind) -> [AIHomeCatalogSuggestion] {
        struct Answer: Decodable {
            struct Title: Decodable {
                let title: String
                let year: Int?
            }
            let titles: [Title]
        }
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let answer = try? JSONDecoder().decode(Answer.self, from: Data(text[start...end].utf8)) else { return [] }
        var seen = Set<String>()
        return answer.titles.compactMap { item in
            let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, seen.insert("\(title.lowercased())|\(item.year ?? 0)").inserted else { return nil }
            return AIHomeCatalogSuggestion(title: title, year: item.year, isFilm: kind.isFilm)
        }
        .prefix(requestedCount)
        .map { $0 }
    }

    // MARK: Building

    /// Asks the AI for one row and looks every title up on TMDB.
    static func buildRow(
        kind: AIHomeCatalogKind,
        context: SurpriseMeAIContext,
        configuration: SurpriseMeAIConfiguration,
        language: String,
        isWatched: @escaping @Sendable (NuvioMeta) -> Bool,
        session: URLSession = .shared
    ) async -> [NuvioMeta] {
        let text = prompt(
            kind: kind,
            context: context,
            // The prompt already lists the latest watched titles; name the older ones too.
            excludedTitles: Array(context.history.watched.dropFirst(SurpriseMeAI.maxWatchedTitles)),
            language: language
        )
        guard let request = SurpriseMeAI.request(for: text, configuration: configuration),
              let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let answer = SurpriseMeAI.responseText(from: data, provider: configuration.provider) else { return [] }
        let suggestions = parse(answer, kind: kind)
        let found = await lookUp(suggestions)
        var seen = Set<String>()
        var row: [NuvioMeta] = []
        for meta in found where !isWatched(meta) {
            let keys = SurpriseMeHistory.keys(for: meta)
            guard seen.isDisjoint(with: keys) else { continue }
            seen.formUnion(keys)
            row.append(meta)
            if row.count == rowSize { break }
        }
        return row
    }

    /// TMDB lookups, a few at a time, keeping the AI's order.
    static func lookUp(_ suggestions: [AIHomeCatalogSuggestion]) async -> [NuvioMeta] {
        guard !suggestions.isEmpty else { return [] }
        var results = [NuvioMeta?](repeating: nil, count: suggestions.count)
        var next = 0
        await withTaskGroup(of: (Int, NuvioMeta?).self) { group in
            func add(_ index: Int) {
                let suggestion = suggestions[index]
                group.addTask {
                    let meta = suggestion.isFilm
                        ? await TmdbDetailsService.surpriseMeFindMovie(title: suggestion.title, year: suggestion.year)
                        : await TmdbDetailsService.surpriseMeFindSeries(title: suggestion.title, year: suggestion.year)
                    return (index, meta)
                }
            }
            while next < min(lookupConcurrency, suggestions.count) {
                add(next)
                next += 1
            }
            for await (index, meta) in group {
                results[index] = meta
                if next < suggestions.count {
                    add(next)
                    next += 1
                }
            }
        }
        return results.compactMap { $0 }
    }
}

/// Keeps the For You rows for the active profile and rebuilds them when needed.
@MainActor
final class AIHomeCatalogStore: ObservableObject {
    static let shared = AIHomeCatalogStore()

    @Published private(set) var cache: AIHomeCatalogCache? {
        didSet { revision &+= 1 }
    }
    @Published private(set) var isBuilding = false
    /// Changes whenever Home should redraw the For You rows.
    @Published private(set) var revision = 0
    private var hasLoadedCache = false
    private var loadedProfileID: String?
    /// Bumped when what a running build was for no longer holds (rows or the
    /// AI turned off, settings changed, another profile). A build only saves
    /// its rows if the generation it started with is still current.
    private(set) var generation = 0
    private var buildTask: Task<Void, Never>?
    /// A refresh asked for while a build was running (true when forced), run
    /// once it ends.
    private var pendingRefresh: Bool?

    /// Home rows to show now, from the cache.
    func sections() -> [TVHomeSection] {
        reloadIfProfileChanged()
        let kinds = AIHomeCatalogs.enabledKinds()
        guard !kinds.isEmpty, SurpriseMeAIConfiguration.current().isUsable else { return [] }
        let history = Self.currentHistory()
        return AIHomeCatalogs.sections(from: cache, kinds: kinds) { meta in
            history.contains(meta) || WatchedStore.contains(meta: meta)
        }
    }

    /// Rebuilds the rows in the background when they are missing, a day old,
    /// or the history moved on. `force` rebuilds now (Settings > Refresh).
    func refreshIfNeeded(force: Bool = false) {
        reloadIfProfileChanged()
        guard !isBuilding else {
            pendingRefresh = force || pendingRefresh == true
            return
        }
        let configuration = SurpriseMeAIConfiguration.current()
        let kinds = AIHomeCatalogs.enabledKinds()
        guard configuration.isUsable, !kinds.isEmpty, TmdbDetailsService.isAvailableForSurpriseMe else { return }
        let history = Self.currentHistory()
        guard force || AIHomeCatalogs.needsRebuild(
            cache: cache,
            kinds: kinds,
            historyCount: history.titleCount,
            provider: configuration.provider.rawValue
        ) else { return }

        isBuilding = true
        let feedback = SurpriseMeFeedback.load()
        let profile = TasteProfile.build(
            watched: history.watched,
            library: history.library,
            continueWatching: history.continueWatching,
            feedback: feedback
        )
        let context = SurpriseMeAIContext(profile: profile, history: history, feedback: feedback)
        let language = Locale(identifier: "en").localizedString(forIdentifier: AppLocaleManager.shared.locale.identifier) ?? "English"
        let profileID = loadedProfileID
        let buildGeneration = generation
        let isWatched: @Sendable (NuvioMeta) -> Bool = { meta in
            history.contains(meta) || WatchedStore.contains(meta: meta)
        }
        buildTask = Task {
            var rows: [AIHomeCatalogCache.Row] = []
            for kind in kinds {
                guard !Task.isCancelled, buildGeneration == generation else { break }
                let items = await AIHomeCatalogs.buildRow(
                    kind: kind,
                    context: context,
                    configuration: configuration,
                    language: language,
                    isWatched: isWatched
                )
                // A failed row keeps what the cache had, so a hiccup doesn't empty Home.
                if !items.isEmpty {
                    rows.append(.init(kind: kind, items: items))
                } else if let previous = cache?.rows.first(where: { $0.kind == kind }) {
                    rows.append(previous)
                }
            }
            isBuilding = false
            buildTask = nil
            defer { runPendingRefresh() }
            guard buildGeneration == generation, !Task.isCancelled,
                  profileID == ProfileSettings.activeProfileID, !rows.isEmpty else { return }
            let built = AIHomeCatalogCache(
                rows: rows,
                builtAt: Date(),
                historyCount: history.titleCount,
                provider: configuration.provider.rawValue
            )
            AIHomeCatalogs.saveCache(built)
            cache = built
        }
    }

    /// Settings changed which rows are on: redraw Home, and build what's missing.
    func settingsChanged() {
        invalidateRunningBuild()
        revision &+= 1
        refreshIfNeeded()
    }

    /// Settings turned a kind off or the AI off: forget rows that no longer apply.
    /// A build already running is dropped, so it can't bring them back.
    func clear() {
        invalidateRunningBuild()
        AIHomeCatalogs.saveCache(nil)
        cache = nil
    }

    private func reloadIfProfileChanged() {
        let profileID = ProfileSettings.activeProfileID
        guard !hasLoadedCache || loadedProfileID != profileID else { return }
        if hasLoadedCache && loadedProfileID != profileID { invalidateRunningBuild() }
        hasLoadedCache = true
        loadedProfileID = profileID
        cache = AIHomeCatalogs.loadCache()
    }

    private func invalidateRunningBuild() {
        generation &+= 1
        buildTask?.cancel()
    }

    private func runPendingRefresh() {
        guard let pending = pendingRefresh else { return }
        pendingRefresh = nil
        refreshIfNeeded(force: pending)
    }

    private static func currentHistory() -> SurpriseMeHistory {
        SurpriseMeHistory(
            watched: WatchedStore.items().map(\.meta),
            library: SurpriseMeLibraries.allItems(),
            continueWatching: ContinueWatchingStore.items().map(\.meta)
        )
    }
}
