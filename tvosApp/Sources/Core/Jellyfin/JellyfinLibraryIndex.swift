import Foundation

/// One playable file for a Jellyfin title. For a movie this is the title's
/// only item; for a series it's one episode. The `episode*` fields are the
/// per-episode display data `meta(forContentId:)` turns into `NuvioVideo`
/// entries — nil for a movie's single item.
struct JellyfinIndexedItem: Codable, Equatable {
    let itemId: String
    let container: String?
    let size: Int64?
    var season: Int?
    var episode: Int?
    var episodeName: String?
    var episodeOverview: String?
    var episodePremiereDate: String?
    var episodeImageTag: String?

    /// `{baseURL}/Videos/{itemId}/stream?static=true&api_key=...` — what
    /// playback opens directly, no `AetherEngine` transport needed since
    /// Jellyfin already serves plain HTTP(S).
    func streamURL(baseURL: URL, accessToken: String) -> URL? {
        var components = URLComponents(url: baseURL.appendingPathComponent("Videos/\(itemId)/stream"), resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "api_key", value: accessToken)]
        if let container { query.append(URLQueryItem(name: "container", value: container)) }
        components?.queryItems = query
        return components?.url
    }
}

/// One Jellyfin title (a `Movie` or a `Series`), carrying every field needed
/// to build its own `NuvioMeta` locally — no lookup against Cinemeta/TMDB/
/// MDBList. `contentId` is synthetic (`jellyfin-<serverID>-<itemId>`), not an
/// IMDb id: matching a title to Cinemeta only made sense when Cinemeta was
/// where the metadata came from, and it isn't anymore. `imdbId`/`tmdbId` are
/// still captured when Jellyfin's own metadata agent found one, purely as an
/// identifier other integrations (Trakt/Simkl scrobbling) could use later.
struct JellyfinIndexedTitle: Codable, Equatable {
    let contentId: String
    let serverID: String
    /// The Jellyfin item id itself (Series id, or the Movie's own id) —
    /// needed to build image URLs, kept explicit rather than re-parsed out
    /// of `contentId`.
    let itemId: String
    let type: String
    let name: String
    let overview: String?
    let year: Int?
    let genres: [String]?
    let communityRating: Double?
    let officialRating: String?
    let premiereDate: String?
    let runTimeTicks: Int64?
    let imdbId: String?
    let tmdbId: Int?
    let primaryImageTag: String?
    let backdropImageTag: String?
    let cast: [String]?
    let directors: [String]?
    var items: [JellyfinIndexedItem]
}

/// Persisted record of every server's sync results: `contentId → title`.
/// Mirrors `SMBLibraryIndex`'s storage shape, but — unlike SMB, which only
/// ever indexes ids and file paths and re-fetches metadata through the
/// ordinary `getMetadata` path — this is also the metadata store: everything
/// `meta(forContentId:)` needs is already here after a sync, so Home and
/// Details never hit the network for a Jellyfin title's display data. Stored
/// as JSON in the active profile's `UserDefaults`, alongside the server list.
@MainActor
final class JellyfinLibraryIndex: ObservableObject {
    static let shared = JellyfinLibraryIndex()

    static let changedNotification = Notification.Name("nuvio.tv.jellyfin.library.changed")

    /// `"jellyfin-<serverID>-<itemId>"` — has no `:`, so it survives
    /// `StreamsRepository`'s `contentId:season:episode` videoId embedding
    /// unmangled. `nonisolated`: pure string formatting, called from
    /// `JellyfinLibraryResolver`'s synchronous background grouping.
    nonisolated static func contentId(serverID: String, itemId: String) -> String {
        "jellyfin-\(serverID)-\(itemId)"
    }

    @Published private(set) var titlesByServerID: [String: [JellyfinIndexedTitle]] = [:]

    private init() {
        titlesByServerID = Self.load()
    }

    func reload() {
        titlesByServerID = Self.load()
    }

    /// All indexed titles across every server, ordered by
    /// `JellyfinServerStore.servers` when possible — same fallback rationale
    /// as `SMBLibraryIndex.titles()`.
    func titles() -> [JellyfinIndexedTitle] {
        let orderedServerIDs = JellyfinServerStore.shared.servers.map(\.id)
        let ordered = orderedServerIDs.flatMap { titlesByServerID[$0] ?? [] }
        let knownIDs = Set(orderedServerIDs)
        let unordered = titlesByServerID
            .filter { !knownIDs.contains($0.key) }
            .values
            .flatMap { $0 }
        return ordered + unordered
    }

    /// Builds a `NuvioMeta` straight from the synced title — this is the
    /// only metadata Home or Details ever show for a Jellyfin-sourced id.
    /// `nil` only when the title isn't indexed or its server has since been
    /// removed (so there's nowhere to point an image URL).
    func meta(forContentId contentId: String) -> NuvioMeta? {
        guard let title = titles().first(where: { $0.contentId == contentId }),
              let server = JellyfinServerStore.shared.server(id: title.serverID),
              let baseURL = server.baseURL else { return nil }
        let token = JellyfinCredentialStore.token(forServerID: server.id)

        func imageURL(itemId: String, type: String, tag: String?) -> String? {
            guard let tag else { return nil }
            return JellyfinClient.imageURL(baseURL: baseURL, itemId: itemId, imageType: type, tag: tag, accessToken: token)?.absoluteString
        }

        let isSeries = title.type == "series"
        let videos: [NuvioVideo]? = isSeries
            ? title.items
                .compactMap { file -> NuvioVideo? in
                    guard let season = file.season, let episode = file.episode else { return nil }
                    return NuvioVideo(
                        id: "\(contentId):\(season):\(episode)",
                        title: file.episodeName ?? L10n.format("jellyfin_episode_fallback_title", fallback: "Episode %d", episode),
                        season: season,
                        episode: episode,
                        thumbnail: imageURL(itemId: file.itemId, type: "Primary", tag: file.episodeImageTag),
                        overview: file.episodeOverview,
                        released: file.episodePremiereDate,
                        rating: nil
                    )
                }
                .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
            : nil

        return NuvioMeta(
            id: title.contentId,
            name: title.name,
            description: title.overview,
            posterUrl: imageURL(itemId: title.itemId, type: "Primary", tag: title.primaryImageTag),
            backgroundUrl: imageURL(itemId: title.itemId, type: "Backdrop", tag: title.backdropImageTag),
            logoUrl: nil,
            imdbId: title.imdbId,
            tmdbId: title.tmdbId,
            type: title.type,
            year: title.year,
            genres: title.genres,
            rating: title.communityRating,
            releaseInfo: title.year.map(String.init),
            runtime: title.runTimeTicks.map(Self.formattedRuntime),
            cast: title.cast,
            director: title.directors,
            writer: nil,
            certification: title.officialRating,
            country: nil,
            released: title.premiereDate,
            status: nil,
            videos: videos,
            trailerYtIds: nil,
            externalRatings: nil
        )
    }

    private static func formattedRuntime(ticks: Int64) -> String {
        let minutes = Int(ticks / 10_000_000 / 60)
        guard minutes > 0 else { return "" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return hours > 0 ? "\(hours)h \(remainder)m" : "\(minutes)m"
    }

    func replace(titles: [JellyfinIndexedTitle], forServerID serverID: String) {
        titlesByServerID[serverID] = titles
        persist()
    }

    func removeAll(forServerID serverID: String) {
        titlesByServerID.removeValue(forKey: serverID)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(titlesByServerID) else { return }
        ProfileSettings.current.set(data, forKey: SettingsKey.jellyfinLibraryIndex)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    private static func load() -> [String: [JellyfinIndexedTitle]] {
        guard let data = ProfileSettings.current.data(forKey: SettingsKey.jellyfinLibraryIndex),
              let decoded = try? JSONDecoder().decode([String: [JellyfinIndexedTitle]].self, from: data) else {
            return [:]
        }
        return decoded
    }
}
