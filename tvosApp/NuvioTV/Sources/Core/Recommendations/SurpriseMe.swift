import Foundation

/// What the viewer tends to watch, as a weight per genre.
///
/// Built on the device from the profile's watch history, library and Continue
/// Watching. The watch history is the app's one shared list, which holds what
/// was watched in Nuvio and what every connected tracker (Trakt, Simkl,
/// MDBList, WeTrakr) reports, so all of them count as one history. Nothing new
/// is stored or uploaded: the same tastes are rebuilt on every device.
struct TasteProfile: Equatable {
    /// Normalized genre name -> share of the total weight (0...1).
    let weights: [String: Double]
    /// Display names of the genres, heaviest first.
    let topGenres: [String]
    /// Display name for each normalized genre key.
    var displayNames: [String: String] = [:]
    /// Share of series among the titles the viewer watched, saved or is
    /// watching (0...1), so someone who mostly watches series gets mostly
    /// series. 0.5 when there is no history yet.
    var seriesShare: Double = 0.5

    func displayName(for key: String) -> String { displayNames[key] ?? key }

    static let empty = TasteProfile(weights: [:], topGenres: [])

    var isEmpty: Bool { weights.isEmpty }

    static let watchedWeight = 3.0
    static let libraryWeight = 2.0
    static let continueWatchingWeight = 1.0

    static func normalized(_ genre: String) -> String {
        let key = genre.lowercased().filter { $0.isLetter || $0.isNumber }
        // TMDB says "Science Fiction", Cinemeta "Sci-Fi".
        return key == "sciencefiction" ? "scifi" : key
    }

    /// Each title counts once per source, however many episodes were watched,
    /// so one long series doesn't decide the whole profile.
    /// Suggestions the viewer opened pull their genres up, and ones they
    /// skipped push theirs down (a genre never goes below zero).
    static let likedSuggestionWeight = 2.0
    static let skippedSuggestionWeight = -1.0

    static func build(
        watched: [NuvioMeta],
        library: [NuvioMeta],
        continueWatching: [NuvioMeta],
        feedback: SurpriseMeFeedback = SurpriseMeFeedback()
    ) -> TasteProfile {
        var totals: [String: Double] = [:]
        var names: [String: String] = [:]
        func add(_ metas: [NuvioMeta], weight: Double) {
            // The same title can come from two trackers under different ids.
            for meta in SurpriseMeHistory.unique(metas) {
                for genre in meta.genres ?? [] {
                    let key = normalized(genre)
                    guard !key.isEmpty else { continue }
                    totals[key, default: 0] += weight
                    if names[key] == nil { names[key] = genre }
                }
            }
        }
        add(watched, weight: watchedWeight)
        add(library, weight: libraryWeight)
        add(continueWatching, weight: continueWatchingWeight)
        add(feedback.liked, weight: likedSuggestionWeight)
        add(feedback.skipped, weight: skippedSuggestionWeight)
        totals = totals.filter { $0.value > 0 }

        let titles = SurpriseMeHistory.unique(watched + library + continueWatching)
            .filter { SurpriseMeContent.kind(of: $0) != nil }
        let seriesCount = titles.filter { SurpriseMeContent.kind(of: $0) == .series }.count
        let seriesShare = titles.isEmpty ? 0.5 : Double(seriesCount) / Double(titles.count)

        let sum = totals.values.reduce(0, +)
        guard sum > 0 else { return .empty }
        let ordered = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        return TasteProfile(
            weights: totals.mapValues { $0 / sum },
            topGenres: ordered.prefix(3).compactMap { names[$0.key] },
            displayNames: names,
            seriesShare: seriesShare
        )
    }

    /// How well a title's genres match, 0...1: the average weight of its genres,
    /// relative to the viewer's favourite genre.
    func affinity(for meta: NuvioMeta) -> Double {
        let genres = (meta.genres ?? []).map(Self.normalized).filter { !$0.isEmpty }
        guard !genres.isEmpty, let strongest = weights.values.max(), strongest > 0 else { return 0 }
        let total = genres.reduce(0.0) { $0 + (weights[$1] ?? 0) }
        return min(1, total / Double(genres.count) / strongest)
    }

    /// The genres of `meta` the viewer watches most, for "Because you watch …".
    func matchingGenres(for meta: NuvioMeta, limit: Int = 2) -> [String] {
        (meta.genres ?? [])
            .filter { (weights[Self.normalized($0)] ?? 0) > 0 }
            .sorted { (weights[Self.normalized($0)] ?? 0) > (weights[Self.normalized($1)] ?? 0) }
            .prefix(limit)
            .map { $0 }
    }
}

/// Brings the connected trackers' watch histories up to date, so tastes are
/// learned from all of them. Each tracker's own sync decides whether it runs
/// (connected, and selected or enabled in Settings); nothing is pulled from an
/// account the user hasn't set up for this profile.
@MainActor
enum SurpriseMeTrackers {
    static let refreshInterval: TimeInterval = 30 * 60
    private static var lastRefreshByProfile: [String: Date] = [:]

    static func needsRefresh(lastRefresh: Date?, now: Date = Date()) -> Bool {
        guard let lastRefresh else { return true }
        return now.timeIntervalSince(lastRefresh) >= refreshInterval
    }

    static func refreshHistoriesIfNeeded() async {
        let profileID = ProfileSettings.activeProfileID ?? ""
        guard needsRefresh(lastRefresh: lastRefreshByProfile[profileID]) else { return }
        lastRefreshByProfile[profileID] = Date()
        async let trakt = TraktHistoryService.syncWatchedHistory()
        async let simkl = SimklHistoryService.syncWatchedHistory()
        async let mdblist = MdbListProgressService.syncWatchedHistory()
        async let wetrakr = WeTrakrProgressService.syncWatchedHistory()
        _ = await (trakt, simkl, mdblist, wetrakr)
    }

    /// Names of the places the watch history came from, e.g. ["Trakt", "Simkl"].
    static func sourceLabels(of items: [WatchedStoreItem]) -> [String] {
        let present = Set(items.flatMap(\.sources).map { $0.uppercased() })
        return TraktWatchProgressSource.allCases
            .filter { present.contains($0.rawValue.uppercased()) }
            .map(\.label)
    }
}

/// What Surprise Me may suggest: movies and series (the default), or only one
/// of them. Chosen in Settings > Integrations > Surprise Me.
enum SurpriseMeContent: String, CaseIterable, Identifiable {
    case all = "All"
    case movies = "Movies"
    case series = "Series"

    enum Kind { case movie, series }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return L10n.string("surprise_me_content_all", fallback: "Movies and series")
        case .movies: return L10n.string("surprise_me_content_movies", fallback: "Movies")
        case .series: return L10n.string("surprise_me_content_series", fallback: "Series")
        }
    }

    /// Movie or series; nil for anything else (channels, TV, events).
    static func kind(of meta: NuvioMeta) -> Kind? {
        if AddonTransportUrls.isTypeEquivalent(meta.type, "movie") { return .movie }
        if NuvioMeta.isSeriesType(meta.type) { return .series }
        return nil
    }

    func allows(_ meta: NuvioMeta) -> Bool {
        guard let kind = Self.kind(of: meta) else { return false }
        switch self {
        case .all: return true
        case .movies: return kind == .movie
        case .series: return kind == .series
        }
    }

    var includesMovies: Bool { self != .series }
    var includesSeries: Bool { self != .movies }

    static func current(defaults: UserDefaults = ProfileSettings.current) -> SurpriseMeContent {
        SurpriseMeContent(rawValue: defaults.string(forKey: SettingsKey.surpriseMeContent) ?? "") ?? .all
    }
}

enum SurpriseMe {
    /// Random among this many of the best matches, so the pick varies.
    static let shortlistSize = 12

    /// Taste match first, then the title's rating, then whether it is the kind
    /// the viewer watches more (movies or series).
    static func score(_ meta: NuvioMeta, profile: TasteProfile) -> Double {
        let rating = min(max((meta.rating ?? 0) / 10, 0), 1)
        guard !profile.isEmpty else { return rating }
        let kindFit = SurpriseMeContent.kind(of: meta) == .series ? profile.seriesShare : 1 - profile.seriesShare
        return profile.affinity(for: meta) * 0.65 + rating * 0.2 + kindFit * 0.15
    }

    /// A movie or series the viewer hasn't watched and wasn't just offered,
    /// picked at random among the best matches for their tastes. With no
    /// history yet, the best rated ones.
    static func pick(
        from candidates: [NuvioMeta],
        profile: TasteProfile,
        isWatched: (NuvioMeta) -> Bool,
        excluding offered: Set<String> = [],
        content: SurpriseMeContent = .all,
        random: () -> Double = { Double.random(in: 0..<1) }
    ) -> NuvioMeta? {
        let shortlist = shortlist(
            from: candidates, profile: profile, isWatched: isWatched, excluding: offered,
            content: content, limit: shortlistSize
        )
        guard !shortlist.isEmpty else { return nil }
        let index = min(shortlist.count - 1, Int(random() * Double(shortlist.count)))
        return shortlist[index]
    }

    /// Unwatched titles of the allowed kinds, best matches first, one per
    /// title. Titles not offered yet come first; offered ones only when nothing
    /// else is left.
    static func shortlist(
        from candidates: [NuvioMeta],
        profile: TasteProfile,
        isWatched: (NuvioMeta) -> Bool,
        excluding offered: Set<String>,
        content: SurpriseMeContent = .all,
        limit: Int
    ) -> [NuvioMeta] {
        var seen = Set<String>()
        let titles = candidates.filter {
            content.allows($0) && seen.insert(SurpriseMeHistory.titleKey($0)).inserted && !isWatched($0)
        }
        let fresh = titles.filter { !offered.contains($0.id) }
        let pool = fresh.isEmpty ? titles : fresh
        // Typed in steps: as one chained expression, this exceeds the type
        // checker's time limit on Xcode 27.1 and fails the build.
        let scored: [(meta: NuvioMeta, score: Double)] = pool.map { meta in
            (meta: meta, score: score(meta, profile: profile))
        }
        let ranked = scored.sorted { (lhs: (meta: NuvioMeta, score: Double), rhs: (meta: NuvioMeta, score: Double)) -> Bool in
            lhs.score == rhs.score ? lhs.meta.id < rhs.meta.id : lhs.score > rhs.score
        }
        return ranked.prefix(limit).map(\.meta)
    }
}

/// Everything the viewer watched or saved, for leaving those titles out. A
/// title can carry an IMDb id from one source and a TMDB id from another, so
/// it is matched by each id and by name and year.
struct SurpriseMeHistory {
    let watched: [NuvioMeta]
    let library: [NuvioMeta]
    let continueWatching: [NuvioMeta]
    private let keys: Set<String>

    static let empty = SurpriseMeHistory(watched: [], library: [], continueWatching: [])

    init(watched: [NuvioMeta], library: [NuvioMeta], continueWatching: [NuvioMeta]) {
        self.watched = watched
        self.library = library
        self.continueWatching = continueWatching
        keys = Set((watched + continueWatching).flatMap(Self.keys(for:)))
    }

    /// Changes whenever a title is added to, removed from or moved within any
    /// of the three lists (most recent first), even if the count stays the
    /// same, and whenever a title's genres change (the taste profile, and so
    /// TMDB's genre candidates and the AI's genre shares, come from them).
    /// In-memory only: not stable across launches.
    var signature: Int {
        var hasher = Hasher()
        for (index, list) in [watched, library, continueWatching].enumerated() {
            hasher.combine(index)
            for meta in list {
                hasher.combine(Self.titleKey(meta))
                // Normalized and sorted: only which genres, not their order or spelling.
                let genres = Set((meta.genres ?? []).map(TasteProfile.normalized).filter { !$0.isEmpty })
                hasher.combine(genres.sorted())
            }
        }
        return hasher.finalize()
    }

    /// Distinct titles across the three lists.
    var titleCount: Int {
        Self.unique(watched + library + continueWatching).count
    }

    /// Most recent first as stored; movies and shows, for the AI prompt.
    var recentTitles: [NuvioMeta] {
        Self.unique(watched + continueWatching + library)
    }

    /// Titles from the history to ask TMDB for recommendations about, most
    /// recent first, of the kinds Surprise Me may suggest.
    func seeds(for content: SurpriseMeContent) -> [NuvioMeta] {
        Self.unique(watched + library).filter(content.allows)
    }

    /// One entry per title, first occurrence kept. Two entries are the same
    /// title when they share any id (Nuvio, IMDb, TMDB) or the same name and
    /// year, so a movie saved in Trakt under its IMDb id and in Simkl under its
    /// TMDB id counts once.
    ///
    /// Sameness carries over: if A has an IMDb id, B a TMDB id, and a later
    /// entry has both, all three are one title and only A is kept.
    static func unique(_ metas: [NuvioMeta]) -> [NuvioMeta] {
        // Union-find over entries that share a key. Each group's root is its
        // earliest entry, so the first occurrence is the one kept.
        var parent = Array(metas.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        var firstEntryForKey: [String: Int] = [:]
        for (index, meta) in metas.enumerated() {
            for key in Self.keys(for: meta) {
                guard let other = firstEntryForKey[key] else {
                    firstEntryForKey[key] = index
                    continue
                }
                let a = root(other), b = root(index)
                if a != b { parent[max(a, b)] = min(a, b) }
            }
        }
        return metas.indices.filter { root($0) == $0 }.map { metas[$0] }
    }

    func contains(_ meta: NuvioMeta) -> Bool {
        !keys.isDisjoint(with: Self.keys(for: meta))
    }

    static func titleKey(_ meta: NuvioMeta) -> String {
        if let imdb = meta.imdbId, !imdb.isEmpty { return imdb }
        if meta.id.hasPrefix("tt") { return meta.id }
        if let tmdb = meta.tmdbId, tmdb > 0 { return "tmdb:\(tmdb)" }
        return meta.id
    }

    static func keys(for meta: NuvioMeta) -> [String] {
        var result = [meta.id]
        if let imdb = meta.imdbId, !imdb.isEmpty { result.append(imdb) }
        if let tmdb = meta.tmdbId, tmdb > 0 { result.append("tmdb:\(tmdb)") }
        let name = meta.name.lowercased().filter { $0.isLetter || $0.isNumber }
        if !name.isEmpty, let year = meta.year { result.append("name:\(name):\(year)") }
        return result
    }
}

/// Every library the viewer has: Nuvio's own and the watchlists of Trakt,
/// Simkl, MDBList and WeTrakr, whichever one Settings shows as the library.
///
/// Read only, from the copies this Apple TV already keeps of each account's
/// list (per profile and account), so nothing is requested, changed or synced
/// back, and one account's list never shows under another's.
enum SurpriseMeLibraries {
    static func allItems() -> [NuvioMeta] {
        let profileID = WatchedStore.activeProfileId
        var metas = LibraryStore.items().map(\.meta)
        for source in TraktLibrarySourceMode.allCases where source != .local {
            let binding = RemoteLibraryStore.accountBindingID(for: source, profileId: profileID)
            guard let items = RemoteLibraryStore.load(
                source: source, profileId: profileID, accountBindingId: binding
            ) else { continue }
            metas += items.map(\.meta)
        }
        return SurpriseMeHistory.unique(metas)
    }
}

/// Candidates from TMDB: its recommendations for the viewer's latest movies
/// and series, and well-rated ones in their favourite genres. Needs TMDB turned
/// on in Settings > Integrations; otherwise Surprise Me uses the catalogs on
/// Home only.
enum SurpriseMeOnline {
    static let seedCount = 6

    static func candidates(
        history: SurpriseMeHistory,
        profile: TasteProfile,
        content: SurpriseMeContent = .all
    ) async -> [NuvioMeta] {
        guard TmdbDetailsService.isAvailableForSurpriseMe else { return [] }
        let seeds = Array(history.seeds(for: content).prefix(seedCount))
        let genres = Array(profile.topGenres.prefix(3))
        return await withTaskGroup(of: [NuvioMeta].self) { group in
            for seed in seeds {
                group.addTask { await TmdbDetailsService.surpriseMeRecommendations(for: seed) }
            }
            if !genres.isEmpty {
                if content.includesMovies {
                    group.addTask { await TmdbDetailsService.surpriseMeDiscover(genres: genres) }
                    group.addTask { await TmdbDetailsService.surpriseMeDiscover(genres: genres, page: 2) }
                }
                if content.includesSeries {
                    group.addTask { await TmdbDetailsService.surpriseMeDiscover(genres: genres, series: true) }
                    group.addTask { await TmdbDetailsService.surpriseMeDiscover(genres: genres, page: 2, series: true) }
                }
            }
            var all: [NuvioMeta] = []
            for await batch in group { all += batch }
            return all
        }
    }
}
