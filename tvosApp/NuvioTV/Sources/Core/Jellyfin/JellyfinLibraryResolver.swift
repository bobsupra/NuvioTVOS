import Foundation

/// Outcome of grouping a sync's items into titles.
struct JellyfinLibraryResolution {
    var titles: [JellyfinIndexedTitle]
    /// Episode names whose `SeriesId` didn't match any `Series` item this
    /// sync also fetched — shouldn't normally happen (an episode's series is
    /// always in the same library), but surfaced rather than silently
    /// dropped.
    var unmatched: [String]
    var completedAt: Date
}

/// Groups one server's synced items into titles, purely locally — no
/// network round trip and no matching against Cinemeta or any other source.
/// A `Movie` item is its own title and its own single playable file; a
/// `Series` item supplies a title's display metadata, and each `Episode`
/// naming that series as its `SeriesId` becomes one of that title's files.
enum JellyfinLibraryResolver {
    static func resolve(_ items: [JellyfinMediaItem], serverID: String) -> JellyfinLibraryResolution {
        var titlesByContentId: [String: JellyfinIndexedTitle] = [:]
        var seriesItemIdByJellyfinId: [String: String] = [:]
        var unmatched: [String] = []

        for item in items where item.type == "Series" {
            let contentId = JellyfinLibraryIndex.contentId(serverID: serverID, itemId: item.id)
            seriesItemIdByJellyfinId[item.id] = contentId
            titlesByContentId[contentId] = JellyfinIndexedTitle(
                contentId: contentId,
                serverID: serverID,
                itemId: item.id,
                type: "series",
                name: item.name,
                overview: item.overview,
                year: item.productionYear,
                genres: item.genres,
                communityRating: item.communityRating,
                officialRating: item.officialRating,
                premiereDate: item.premiereDate,
                runTimeTicks: item.runTimeTicks,
                imdbId: item.imdbId,
                tmdbId: item.tmdbId,
                primaryImageTag: item.primaryImageTag,
                backdropImageTag: item.backdropImageTag,
                cast: item.cast,
                directors: item.directors,
                items: []
            )
        }

        for item in items where item.type == "Movie" {
            let contentId = JellyfinLibraryIndex.contentId(serverID: serverID, itemId: item.id)
            titlesByContentId[contentId] = JellyfinIndexedTitle(
                contentId: contentId,
                serverID: serverID,
                itemId: item.id,
                type: "movie",
                name: item.name,
                overview: item.overview,
                year: item.productionYear,
                genres: item.genres,
                communityRating: item.communityRating,
                officialRating: item.officialRating,
                premiereDate: item.premiereDate,
                runTimeTicks: item.runTimeTicks,
                imdbId: item.imdbId,
                tmdbId: item.tmdbId,
                primaryImageTag: item.primaryImageTag,
                backdropImageTag: item.backdropImageTag,
                cast: item.cast,
                directors: item.directors,
                items: [
                    JellyfinIndexedItem(itemId: item.id, container: item.container, size: item.sizeBytes)
                ]
            )
        }

        for item in items where item.type == "Episode" {
            guard let seriesId = item.seriesId, let contentId = seriesItemIdByJellyfinId[seriesId] else {
                unmatched.append(item.name)
                continue
            }
            let file = JellyfinIndexedItem(
                itemId: item.id,
                container: item.container,
                size: item.sizeBytes,
                season: item.parentIndexNumber,
                episode: item.indexNumber,
                episodeName: item.name,
                episodeOverview: item.overview,
                episodePremiereDate: item.premiereDate,
                episodeImageTag: item.primaryImageTag
            )
            titlesByContentId[contentId]?.items.append(file)
        }

        // A series with no episodes yet resolved (all orphaned, or the
        // library genuinely has none) isn't worth a Home card with no
        // playable file.
        let titles = titlesByContentId.values.filter { $0.type == "movie" || !$0.items.isEmpty }

        return JellyfinLibraryResolution(titles: Array(titles), unmatched: unmatched, completedAt: Date())
    }
}
