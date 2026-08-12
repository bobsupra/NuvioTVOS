import Foundation

/// Outcome of resolving a scan's candidate files against Cinemeta.
struct SMBLibraryResolution {
    var titles: [SMBIndexedTitle]
    /// Filenames that failed to parse, or parsed but found no confident
    /// Cinemeta match — surfaced in the scan report rather than silently
    /// dropped.
    var unmatched: [String]
    var completedAt: Date
}

/// Matches scanned filenames to real content ids via the same Cinemeta search
/// remote catalog rows use (`CatalogRepository.search`), so a resolved title
/// flows through the ordinary `getMetadata` path with full TMDB/MDBList
/// enrichment instead of caching the filename's guess. Bounded concurrency
/// plus in-run memoization keep a 24-episode season down to one search
/// instead of one per episode.
enum SMBLibraryResolver {
    private static let maxConcurrentSearches = 4
    /// Below this, a candidate is treated as no match at all — better to leave
    /// a file unmatched than attach it to the wrong title. Internal (not
    /// private) so `SMBLibraryResolverTests` can test the score/accept
    /// boundary without a live Cinemeta call.
    static let minimumScore = 60

    static func resolve(_ files: [SMBMediaFile], serverID: String) async -> SMBLibraryResolution {
        var unmatched: [String] = []
        var candidates: [(file: SMBMediaFile, name: ParsedMediaName)] = []
        for file in files {
            guard let name = file.parsed else {
                unmatched.append(file.filename)
                continue
            }
            candidates.append((file, name))
        }

        // Memoize by title|year|isSeries so a season's worth of episodes costs
        // one Cinemeta search, not one per file.
        let uniqueQueries = Array(Set(candidates.map { QueryKey(name: $0.name) }))
        let matchesByQuery = await searchAll(uniqueQueries)

        var titlesByContentId: [String: SMBIndexedTitle] = [:]
        for (file, name) in candidates {
            guard let match = matchesByQuery[QueryKey(name: name)] else {
                unmatched.append(file.filename)
                continue
            }
            let indexedFile = SMBIndexedFile(
                serverID: serverID,
                share: file.share,
                path: file.path,
                filename: file.filename,
                size: file.size,
                season: name.season,
                episode: name.episode
            )
            if var existing = titlesByContentId[match.id] {
                existing.files.append(indexedFile)
                titlesByContentId[match.id] = existing
            } else {
                titlesByContentId[match.id] = SMBIndexedTitle(
                    contentId: match.id,
                    type: match.type,
                    year: match.year,
                    files: [indexedFile]
                )
            }
        }

        return SMBLibraryResolution(
            titles: Array(titlesByContentId.values),
            unmatched: unmatched,
            completedAt: Date()
        )
    }

    /// Internal (not private) so `SMBLibraryResolverTests` can drive `score`
    /// directly with fixture data, without a live Cinemeta call.
    struct QueryKey: Hashable {
        let title: String
        let year: Int?
        let isSeries: Bool

        init(name: ParsedMediaName) {
            title = name.title.lowercased()
            year = name.year
            isSeries = name.isSeries
        }

        init(title: String, year: Int?, isSeries: Bool) {
            self.title = title.lowercased()
            self.year = year
            self.isSeries = isSeries
        }
    }

    private static func searchAll(_ queries: [QueryKey]) async -> [QueryKey: NuvioMeta] {
        var results: [QueryKey: NuvioMeta] = [:]
        var iterator = queries.makeIterator()

        await withTaskGroup(of: (QueryKey, NuvioMeta?).self) { group in
            func startNext() {
                guard let query = iterator.next() else { return }
                group.addTask { (query, await bestMatch(for: query)) }
            }
            for _ in 0..<maxConcurrentSearches { startNext() }
            while let (query, match) = await group.next() {
                if let match { results[query] = match }
                startNext()
            }
        }
        return results
    }

    private static func bestMatch(for query: QueryKey) async -> NuvioMeta? {
        let repository = CinemetaCatalogRepository()
        guard let candidates = try? await repository.search(query: query.title), !candidates.isEmpty else {
            return nil
        }
        return candidates
            .map { (meta: $0, score: score(meta: $0, query: query)) }
            .max { $0.score < $1.score }
            .flatMap { $0.score >= minimumScore ? $0.meta : nil }
    }

    /// Title equality/prefix dominates; type match and year proximity refine
    /// among same-title candidates (a search can return both a movie and a
    /// series with the same name).
    static func score(meta: NuvioMeta, query: QueryKey) -> Int {
        let metaTitle = meta.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let queryTitle = query.title.trimmingCharacters(in: .whitespacesAndNewlines)

        var score: Int
        if metaTitle == queryTitle {
            score = 60
        } else if metaTitle.hasPrefix(queryTitle) || queryTitle.hasPrefix(metaTitle) {
            score = 35
        } else {
            return 0
        }

        score += meta.isSeries == query.isSeries ? 30 : -30

        if let queryYear = query.year, let metaYear = meta.year {
            switch abs(queryYear - metaYear) {
            case 0: score += 20
            case 1: score += 5
            default: score -= 15
            }
        }

        return score
    }
}
