import Foundation

/// Background enrichment for compact Cinemeta search records.
///
/// `CatalogRepository.search(query:)` intentionally returns fast, compact
/// records: Cinemeta search results carry an id (usually IMDb), name, type and
/// a poster, but omit the aliases (IMDb/TMDB ids), backdrop, and logo that
/// Discovery/collection cards have. That leaves Search artwork behind and can
/// hide watched-state checkmarks when the watch history only knows the title
/// by its TMDB id.
///
/// This helper refreshes the leading results with their full `/meta` records
/// *after* the raw grid is already on screen, merging the missing fields while
/// preserving each result's original id (so focus identity and navigation are
/// unchanged). Requests run in small waves so a long result list never fans
/// out into one request per card, and the caller cancels the task when the
/// query changes so a stale enrichment can never be applied.
@MainActor
enum SearchResultEnrichment {
    /// Upper bound on how many leading results get a full `/meta` refresh.
    /// Covers the visible grid plus a row or two of scroll; anything further
    /// down is refreshed if the user keeps scrolling and re-searches.
    static let maxResultsToEnrich = 24

    /// Refresh requests run in waves of this size (about four at a time).
    static let maxConcurrentRequests = 4

    static func hasIncompleteLeadingResults(_ results: [NuvioMeta]) -> Bool {
        results
            .prefix(maxResultsToEnrich)
            .contains { $0.needsSearchMetadataEnrichment }
    }

    /// Returns `results` with the leading entries merged with their refreshed
    /// `/meta` records. Order, ids, and names are untouched; refreshed artwork
    /// wins over stale compact search artwork, while aliases and other missing
    /// metadata are filled. Skipping a record that is already complete keeps
    /// repeated queries from re-fetching what the cache already enriched.
    static func enrich(
        _ results: [NuvioMeta],
        repository: CatalogRepository
    ) async -> [NuvioMeta] {
        guard !results.isEmpty else { return results }

        let candidateIndices = Array(results.indices.prefix(maxResultsToEnrich))
            .filter { results[$0].needsSearchMetadataEnrichment }
        guard !candidateIndices.isEmpty else { return results }

        var enriched = results
        var cursor = 0
        while cursor < candidateIndices.count {
            guard !Task.isCancelled else { break }
            let end = min(cursor + maxConcurrentRequests, candidateIndices.count)
            let slice = Array(candidateIndices[cursor..<end])

            // Child tasks inherit cancellation, so in-flight refreshes abort
            // when the caller cancels (query changed) instead of completing.
            let refreshed: [(index: Int, full: NuvioMeta?)] = await withTaskGroup(
                of: (Int, NuvioMeta?).self
            ) { group in
                for index in slice {
                    group.addTask {
                        let meta = results[index]
                        let full = try? await repository.refreshMetadata(
                            id: meta.id,
                            type: meta.type
                        )
                        return (index, full)
                    }
                }
                var collected: [(Int, NuvioMeta?)] = []
                for await pair in group {
                    collected.append(pair)
                }
                return collected
            }

            for (index, full) in refreshed {
                guard let full, !Task.isCancelled else { continue }
                enriched[index] = results[index].mergingSearchMetadata(from: full)
            }
            cursor = end
        }
        return enriched
    }
}
