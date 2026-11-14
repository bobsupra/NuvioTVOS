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

    static let empty = TasteProfile(weights: [:], topGenres: [])

    var isEmpty: Bool { weights.isEmpty }

    static let watchedWeight = 3.0
    static let libraryWeight = 2.0
    static let continueWatchingWeight = 1.0

    static func normalized(_ genre: String) -> String {
        genre.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Each title counts once per source, however many episodes were watched,
    /// so one long series doesn't decide the whole profile.
    static func build(
        watched: [NuvioMeta],
        library: [NuvioMeta],
        continueWatching: [NuvioMeta]
    ) -> TasteProfile {
        var totals: [String: Double] = [:]
        var names: [String: String] = [:]
        func add(_ metas: [NuvioMeta], weight: Double) {
            // The same title can come from two trackers under different ids.
            var seen = Set<String>()
            for meta in metas where seen.insert(meta.imdbId ?? meta.id).inserted {
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

        let sum = totals.values.reduce(0, +)
        guard sum > 0 else { return .empty }
        let ordered = totals.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        return TasteProfile(
            weights: totals.mapValues { $0 / sum },
            topGenres: ordered.prefix(3).compactMap { names[$0.key] }
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

enum SurpriseMe {
    /// Random among this many of the best matches, so the pick varies.
    static let shortlistSize = 12

    static func isMovie(_ meta: NuvioMeta) -> Bool {
        AddonTransportUrls.isTypeEquivalent(meta.type, "movie")
    }

    /// Taste match first, the title's rating as a smaller part.
    static func score(_ meta: NuvioMeta, profile: TasteProfile) -> Double {
        let rating = min(max((meta.rating ?? 0) / 10, 0), 1)
        return profile.isEmpty ? rating : profile.affinity(for: meta) * 0.75 + rating * 0.25
    }

    /// A movie the viewer hasn't watched and wasn't just offered, picked at
    /// random among the best matches for their tastes. With no history yet,
    /// the best rated ones.
    static func pick(
        from candidates: [NuvioMeta],
        profile: TasteProfile,
        isWatched: (NuvioMeta) -> Bool,
        excluding offered: Set<String> = [],
        random: () -> Double = { Double.random(in: 0..<1) }
    ) -> NuvioMeta? {
        var seen = Set<String>()
        let movies = candidates.filter { isMovie($0) && seen.insert($0.id).inserted && !isWatched($0) }
        guard !movies.isEmpty else { return nil }
        let fresh = movies.filter { !offered.contains($0.id) }
        let pool = fresh.isEmpty ? movies : fresh
        let shortlist = pool
            .map { (meta: $0, score: score($0, profile: profile)) }
            .sorted { $0.score == $1.score ? $0.meta.id < $1.meta.id : $0.score > $1.score }
            .prefix(shortlistSize)
        let index = min(shortlist.count - 1, Int(random() * Double(shortlist.count)))
        return shortlist[shortlist.startIndex + index].meta
    }
}
