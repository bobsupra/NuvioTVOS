import Foundation

// MARK: - Shared session

enum SimklRuntimeSession {
    static func profileScope() -> String {
        let value = WatchedStore.activeProfileId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "default" : value
    }

    static func authenticatedState(
        store: UserDefaults = ProfileSettings.current,
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) -> SimklAuthState? {
        let resolvedProfileScope = profileScope ?? self.profileScope()
        let state = SimklAuthStore.state(
            in: store,
            profileScope: resolvedProfileScope,
            tokenStorage: tokenStorage
        )
        return state.isAuthenticated(in: store) ? state : nil
    }
}

// MARK: - API models

struct SimklSyncIDs: Codable, Equatable {
    let simkl: Int?
    let imdb: String?
    let tmdb: Int?
    let tvdb: Int?

    enum CodingKeys: String, CodingKey {
        case simkl, imdb, tmdb, tvdb
    }

    init(simkl: Int? = nil, imdb: String? = nil, tmdb: Int? = nil, tvdb: Int? = nil) {
        self.simkl = simkl
        self.imdb = imdb
        self.tmdb = tmdb
        self.tvdb = tvdb
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        simkl = Self.flexibleInt(in: container, forKey: .simkl)
        tmdb = Self.flexibleInt(in: container, forKey: .tmdb)
        tvdb = Self.flexibleInt(in: container, forKey: .tvdb)
        imdb = try container.decodeIfPresent(String.self, forKey: .imdb)
    }

    private static func flexibleInt(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decode(String.self, forKey: key) {
            return Int(value)
        }
        return nil
    }
}

struct SimklSyncEpisode: Codable {
    let number: Int?
    let episode: Int?
    let watchedAt: String?

    enum CodingKeys: String, CodingKey {
        case number, episode
        case watchedAt = "watched_at"
    }

    var resolvedNumber: Int? { number ?? episode }
}

struct SimklSyncSeason: Codable {
    let number: Int?
    let episodes: [SimklSyncEpisode]?
}

struct SimklSyncItem: Codable {
    let title: String?
    let year: Int?
    let ids: SimklSyncIDs?
    let status: String?
    let addedToWatchlistAt: String?
    let lastWatched: String?
    let watchedAt: String?
    let seasons: [SimklSyncSeason]?

    enum CodingKeys: String, CodingKey {
        case title, year, ids, status, seasons
        case addedToWatchlistAt = "added_to_watchlist_at"
        case lastWatched = "last_watched"
        case watchedAt = "watched_at"
    }
}

struct SimklAllItemsResponse: Codable {
    var shows: [SimklSyncItem]?
    var movies: [SimklSyncItem]?
    var anime: [SimklSyncItem]?

    mutating func merge(_ delta: SimklAllItemsResponse) {
        shows = Self.merged(shows, delta.shows)
        movies = Self.merged(movies, delta.movies)
        anime = Self.merged(anime, delta.anime)
    }

    private static func merged(
        _ existing: [SimklSyncItem]?,
        _ incoming: [SimklSyncItem]?
    ) -> [SimklSyncItem]? {
        guard let incoming else { return existing }
        var result = existing ?? []
        for item in incoming {
            if let index = result.firstIndex(where: { identity($0) == identity(item) }) {
                result[index] = item
            } else {
                result.append(item)
            }
        }
        return result
    }

    static func identity(_ item: SimklSyncItem) -> String {
        if let simkl = item.ids?.simkl { return "simkl:\(simkl)" }
        if let imdb = item.ids?.imdb, !imdb.isEmpty { return "imdb:\(imdb.lowercased())" }
        if let tmdb = item.ids?.tmdb { return "tmdb:\(tmdb)" }
        return "title:\(item.title?.lowercased() ?? ""):\(item.year ?? 0)"
    }
}

struct SimklActivityGroup: Codable, Equatable {
    let all: String?
    let playback: String?
    let removedFromList: String?

    enum CodingKeys: String, CodingKey {
        case all, playback
        case removedFromList = "removed_from_list"
    }
}

struct SimklActivitiesResponse: Codable, Equatable {
    let all: String?
    let tvShows: SimklActivityGroup?
    let movies: SimklActivityGroup?
    let anime: SimklActivityGroup?

    enum CodingKeys: String, CodingKey {
        case all, movies, anime
        case tvShows = "tv_shows"
    }

    var playbackWatermark: String {
        [tvShows?.playback, movies?.playback, anime?.playback]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    func removalsChanged(comparedWith previous: SimklActivitiesResponse?) -> Bool {
        guard let previous else { return false }
        return tvShows?.removedFromList != previous.tvShows?.removedFromList
            || movies?.removedFromList != previous.movies?.removedFromList
            || anime?.removedFromList != previous.anime?.removedFromList
    }
}

struct SimklPlaybackDTO: Codable {
    struct Episode: Codable {
        let season: Int?
        let number: Int?
        let episode: Int?
        let title: String?

        var resolvedNumber: Int? { number ?? episode }
    }

    struct Media: Codable {
        let title: String?
        let year: Int?
        let ids: SimklSyncIDs?
    }

    let id: Int?
    let progress: Double?
    let pausedAt: String?
    let type: String?
    let episode: Episode?
    let show: Media?
    let movie: Media?
    let anime: Media?

    enum CodingKeys: String, CodingKey {
        case id, progress, type, episode, show, movie, anime
        case pausedAt = "paused_at"
    }
}

// MARK: - Cache and transport

private enum SimklSyncCache {
    private static let itemCacheKey = "nuvio.tv.simkl.sync.items"
    private static let itemActivityKey = "nuvio.tv.simkl.sync.items.activities"
    private static let historyCacheKey = "nuvio.tv.simkl.sync.history"
    private static let historyWatermarkKey = "nuvio.tv.simkl.sync.history.watermark"
    private static let playbackCacheKey = "nuvio.tv.simkl.sync.playback"
    private static let playbackWatermarkKey = "nuvio.tv.simkl.sync.playback.watermark"

    static func items(in store: UserDefaults) -> SimklAllItemsResponse? {
        decode(SimklAllItemsResponse.self, key: itemCacheKey, store: store)
    }

    static func saveItems(
        _ items: SimklAllItemsResponse,
        activities: SimklActivitiesResponse,
        store: UserDefaults
    ) {
        encode(items, key: itemCacheKey, store: store)
        encode(activities, key: itemActivityKey, store: store)
    }

    static func addLibraryItems(_ libraryItems: [LibraryStoreItem], store: UserDefaults) {
        var items = items(in: store) ?? SimklAllItemsResponse()
        let addedAt = iso8601(Date())
        var additions = SimklAllItemsResponse()

        for item in libraryItems {
            guard let ids = simklIDs(item.meta) else { continue }
            let value = SimklSyncItem(
                title: item.meta.name,
                year: item.meta.year,
                ids: ids,
                status: "plantowatch",
                addedToWatchlistAt: addedAt,
                lastWatched: nil,
                watchedAt: nil,
                seasons: nil
            )
            if item.meta.isSeries {
                additions.shows = (additions.shows ?? []) + [value]
            } else {
                additions.movies = (additions.movies ?? []) + [value]
            }
        }

        items.merge(additions)
        encode(items, key: itemCacheKey, store: store)
    }

    static func itemActivities(in store: UserDefaults) -> SimklActivitiesResponse? {
        decode(SimklActivitiesResponse.self, key: itemActivityKey, store: store)
    }

    static func history(in store: UserDefaults) -> [SimklHistoryRecord] {
        decode([SimklHistoryRecord].self, key: historyCacheKey, store: store) ?? []
    }

    static func historyWatermark(in store: UserDefaults) -> String? {
        store.string(forKey: historyWatermarkKey)
    }

    static func saveHistory(
        _ records: [SimklHistoryRecord],
        watermark: String?,
        store: UserDefaults
    ) {
        encode(records, key: historyCacheKey, store: store)
        store.set(watermark, forKey: historyWatermarkKey)
    }

    static func playbacks(in store: UserDefaults) -> [SimklPlaybackDTO]? {
        decode([SimklPlaybackDTO].self, key: playbackCacheKey, store: store)
    }

    static func playbackWatermark(in store: UserDefaults) -> String? {
        store.string(forKey: playbackWatermarkKey)
    }

    static func savePlaybacks(
        _ playbacks: [SimklPlaybackDTO],
        watermark: String,
        store: UserDefaults
    ) {
        encode(playbacks, key: playbackCacheKey, store: store)
        store.set(watermark, forKey: playbackWatermarkKey)
    }

    static func addPlayback(
        _ item: ContinueWatchingItem,
        progress: Double,
        store: UserDefaults
    ) {
        guard let ids = simklIDs(item.meta) else { return }
        let media = SimklPlaybackDTO.Media(
            title: item.meta.name,
            year: item.meta.year,
            ids: ids
        )
        let playback = SimklPlaybackDTO(
            id: nil,
            progress: progress,
            pausedAt: iso8601(Date()),
            type: item.meta.isSeries ? "episode" : "movie",
            episode: item.meta.isSeries
                ? SimklPlaybackDTO.Episode(
                    season: item.season,
                    number: item.episode,
                    episode: nil,
                    title: item.episodeTitleOverride
                )
                : nil,
            show: item.meta.isSeries ? media : nil,
            movie: item.meta.isSeries ? nil : media,
            anime: nil
        )

        var cached = playbacks(in: store) ?? []
        let newIdentity = playbackIdentity(playback)
        cached.removeAll { playbackIdentity($0) == newIdentity }
        cached.append(playback)
        encode(cached, key: playbackCacheKey, store: store)
    }

    private static func playbackIdentity(_ playback: SimklPlaybackDTO) -> String {
        let media = playback.movie ?? playback.show ?? playback.anime
        let item = SimklSyncItem(
            title: media?.title,
            year: media?.year,
            ids: media?.ids,
            status: nil,
            addedToWatchlistAt: nil,
            lastWatched: nil,
            watchedAt: nil,
            seasons: nil
        )
        return [
            playback.movie == nil ? "series" : "movie",
            SimklAllItemsResponse.identity(item),
            String(playback.episode?.season ?? -1),
            String(playback.episode?.resolvedNumber ?? -1)
        ].joined(separator: ":")
    }

    private static func encode<T: Encodable>(_ value: T, key: String, store: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) {
            store.set(data, forKey: key)
        }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        key: String,
        store: UserDefaults
    ) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

private struct SimklAuthorizedClient {
    let client: SimklAPIClient
    let store: UserDefaults
    let clientID: String
    let token: String
    let tokenStorage: SimklTokenStorage
    let profileScope: String

    init?(
        store: UserDefaults,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) {
        let resolvedProfileScope = profileScope ?? SimklRuntimeSession.profileScope()
        guard let state = SimklRuntimeSession.authenticatedState(
            store: store,
            tokenStorage: tokenStorage,
            profileScope: resolvedProfileScope
        ),
              let token = state.accessToken, !token.isEmpty else { return nil }
        self.client = client
        self.store = store
        self.clientID = SimklConfig.clientID(in: store)
        self.token = token
        self.tokenStorage = tokenStorage
        self.profileScope = resolvedProfileScope
    }

    func get<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        let result: SimklHTTPResult<T> = try await client.get(
            path: path,
            clientID: clientID,
            accessToken: token,
            queryItems: query
        )
        if result.statusCode == 401 {
            SimklAuthStore.clearAuth(
                profileScope: profileScope,
                store: store,
                tokenStorage: tokenStorage
            )
        }
        return try result.valueOrThrow()
    }

    func post<B: Encodable>(
        path: String,
        query: [URLQueryItem] = [],
        body: B
    ) async throws -> Int {
        let result = try await client.post(
            path: path,
            clientID: clientID,
            accessToken: token,
            queryItems: query,
            body: body
        )
        if result.statusCode == 401 {
            SimklAuthStore.clearAuth(
                profileScope: profileScope,
                store: store,
                tokenStorage: tokenStorage
            )
        }
        return result.statusCode
    }
}

private enum SimklSyncLoader {
    static func activities(
        using service: SimklAuthorizedClient
    ) async throws -> SimklActivitiesResponse {
        try await service.get(SimklActivitiesResponse.self, path: "sync/activities")
    }

    static func libraryItems(
        store: UserDefaults,
        force: Bool = false
    ) async -> SimklAllItemsResponse? {
        guard let service = SimklAuthorizedClient(store: store),
              let activities = try? await activities(using: service) else { return nil }

        let cached = SimklSyncCache.items(in: store)
        let previousActivities = SimklSyncCache.itemActivities(in: store)
        if !force, cached != nil, previousActivities?.all == activities.all {
            return cached
        }

        let shouldBootstrap = cached == nil || activities.removalsChanged(comparedWith: previousActivities)
        var result = cached ?? SimklAllItemsResponse()

        if shouldBootstrap {
            result = SimklAllItemsResponse()
            for type in ["shows", "movies", "anime"] {
                guard let response = try? await service.get(
                    SimklAllItemsResponse.self,
                    path: "sync/all-items/\(type)"
                ) else { return nil }
                result.merge(response)
            }
        } else if let watermark = previousActivities?.all, !watermark.isEmpty {
            guard let delta = try? await service.get(
                SimklAllItemsResponse.self,
                path: "sync/all-items",
                query: [URLQueryItem(name: "date_from", value: watermark)]
            ) else { return nil }
            result.merge(delta)
        }

        SimklSyncCache.saveItems(result, activities: activities, store: store)
        return result
    }
}

// MARK: - Watched history

struct SimklHistoryRecord: Codable {
    let key: String
    let items: [WatchedStoreItem]
}

struct SimklHistoryService {
    @MainActor
    static func syncWatchedHistory(
        store: UserDefaults = ProfileSettings.current,
        force: Bool = false
    ) async -> Bool {
        let syncStartedAt = Date()
        guard let service = SimklAuthorizedClient(store: store),
              let activities = try? await SimklSyncLoader.activities(using: service) else {
            return false
        }

        let previousRecords = SimklSyncCache.history(in: store)
        let oldWatermark = SimklSyncCache.historyWatermark(in: store)
        if !force, !previousRecords.isEmpty, oldWatermark == activities.all {
            return true
        }

        var records = previousRecords
        if previousRecords.isEmpty || oldWatermark == nil {
            records = []
            for type in ["shows", "movies", "anime"] {
                guard let response = try? await service.get(
                    SimklAllItemsResponse.self,
                    path: "sync/all-items/\(type)",
                    query: historyQuery()
                ) else { return false }
                records = mergeHistory(records, response: response)
            }
        } else {
            var query = historyQuery()
            query.append(URLQueryItem(name: "date_from", value: oldWatermark))
            guard let delta = try? await service.get(
                SimklAllItemsResponse.self,
                path: "sync/all-items",
                query: query
            ) else { return false }
            records = mergeHistory(records, response: delta)
        }

        let previousItems = previousRecords.flatMap(\.items)
        let remoteItems = records.flatMap(\.items)
        guard WatchedStore.reconcileSimklSnapshot(
            remoteItems,
            previousRemoteItems: previousItems,
            syncStartedAt: syncStartedAt
        ) else { return false }
        SimklSyncCache.saveHistory(records, watermark: activities.all, store: store)
        return true
    }

    static func setWatched(
        _ meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil,
        isWatched: Bool,
        store: UserDefaults = ProfileSettings.current,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        guard let service = SimklAuthorizedClient(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ),
              let body = historyMutation(
                meta: meta,
                season: season,
                episode: episode,
                watchedAt: isWatched ? iso8601(Date()) : nil
              ) else { return false }
        do {
            let status = try await service.post(
                path: isWatched ? "sync/history" : "sync/history/remove",
                query: [URLQueryItem(name: "skip_auto_watching", value: "yes")],
                body: body
            )
            guard (200..<300).contains(status) else { return false }
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            return true
        } catch {
            return false
        }
    }

    private static func historyQuery() -> [URLQueryItem] {
        [
            URLQueryItem(name: "extended", value: "full"),
            URLQueryItem(name: "episode_watched_at", value: "yes"),
            URLQueryItem(name: "include_all_episodes", value: "yes")
        ]
    }

    private static func mergeHistory(
        _ existing: [SimklHistoryRecord],
        response: SimklAllItemsResponse
    ) -> [SimklHistoryRecord] {
        var records = existing
        let typedItems: [(String, SimklSyncItem)] =
            (response.movies ?? []).map { ("movie", $0) }
            + (response.shows ?? []).map { ("series", $0) }
            + (response.anime ?? []).map { ("series", $0) }

        for (type, item) in typedItems {
            let key = "\(type):\(SimklAllItemsResponse.identity(item))"
            let record = SimklHistoryRecord(
                key: key,
                items: watchedItems(from: item, type: type)
            )
            records.removeAll { $0.key == key }
            records.append(record)
        }
        return records
    }

    private static func watchedItems(
        from item: SimklSyncItem,
        type: String
    ) -> [WatchedStoreItem] {
        guard let meta = placeholderMeta(item: item, type: type) else { return [] }
        if type == "movie" {
            guard item.status?.lowercased() == "completed"
                    || item.watchedAt != nil
                    || item.lastWatched != nil else { return [] }
            return [
                WatchedStoreItem(
                    meta: meta,
                    watchedAt: parseDate(item.watchedAt ?? item.lastWatched) ?? .distantPast
                )
            ]
        }

        return (item.seasons ?? []).flatMap { season -> [WatchedStoreItem] in
            guard let seasonNumber = season.number else { return [] }
            return (season.episodes ?? []).compactMap { episode in
                guard let episodeNumber = episode.resolvedNumber,
                      let watchedAt = episode.watchedAt else { return nil }
                return WatchedStoreItem(
                    meta: meta,
                    watchedAt: parseDate(watchedAt) ?? .distantPast,
                    season: seasonNumber,
                    episode: episodeNumber
                )
            }
        }
    }
}

enum SimklHistoryTransferSource: String, CaseIterable {
    case nuvioSync
    case trakt

    var label: String {
        switch self {
        case .nuvioSync: return "Nuvio Sync"
        case .trakt: return "Trakt"
        }
    }
}

struct SimklHistoryTransferResult {
    let total: Int
    let transferred: Int
    let skipped: Int
    let failed: Int

    var isComplete: Bool {
        total == transferred && skipped == 0 && failed == 0
    }
}

struct SimklHistoryTransferService {
    private static let batchSize = 100

    static func transfer(
        _ items: [WatchedStoreItem],
        store: UserDefaults = ProfileSettings.current,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil,
        progress: @escaping (Int) async -> Void
    ) async -> SimklHistoryTransferResult {
        await progress(1)

        let sourceItems = WatchedStore.mergedByIdentity(items)
        let total = sourceItems.count
        guard total > 0 else {
            await progress(100)
            return SimklHistoryTransferResult(
                total: 0,
                transferred: 0,
                skipped: 0,
                failed: 0
            )
        }

        guard let service = SimklAuthorizedClient(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ) else {
            return SimklHistoryTransferResult(
                total: total,
                transferred: 0,
                skipped: 0,
                failed: total
            )
        }

        let entries: [SimklHistoryMutation] = sourceItems.compactMap { item in
            historyMutation(
                meta: item.meta,
                season: item.season,
                episode: item.episode,
                watchedAt: iso8601(item.watchedAt)
            )
        }
        let skipped = total - entries.count
        var transferred = 0

        for start in stride(from: 0, to: entries.count, by: batchSize) {
            guard !Task.isCancelled else {
                return result(
                    total: total,
                    transferred: transferred,
                    skipped: skipped,
                    validCount: entries.count
                )
            }
            let end = min(start + batchSize, entries.count)
            let batch = Array(entries[start..<end])
            let body = combinedMutation(batch)

            do {
                let status = try await service.post(
                    path: "sync/history",
                    query: [URLQueryItem(name: "skip_auto_watching", value: "yes")],
                    body: body
                )
                guard (200..<300).contains(status) else {
                    return result(
                        total: total,
                        transferred: transferred,
                        skipped: skipped,
                        validCount: entries.count
                    )
                }
            } catch {
                return result(
                    total: total,
                    transferred: transferred,
                    skipped: skipped,
                    validCount: entries.count
                )
            }

            transferred += batch.count
            let percentage = min(
                100,
                max(1, Int((Double(transferred) / Double(total) * 100).rounded(.down)))
            )
            await progress(percentage)
        }

        if transferred == total {
            await progress(100)
        }
        NotificationCenter.default.post(
            name: TraktSettingsStore.continueWatchingChangedNotification,
            object: nil
        )
        return result(
            total: total,
            transferred: transferred,
            skipped: skipped,
            validCount: entries.count
        )
    }

    private static func combinedMutation(
        _ mutations: [SimklHistoryMutation]
    ) -> SimklHistoryMutation {
        let movies = mutations.flatMap { $0.movies ?? [] }
        var groupedShows: [String: SimklWriteMedia] = [:]
        for show in mutations.flatMap({ $0.shows ?? [] }) {
            let key = transferKey(show)
            if let existing = groupedShows[key] {
                groupedShows[key] = merge(existing, show)
            } else {
                groupedShows[key] = show
            }
        }
        let shows = Array(groupedShows.values)
        return SimklHistoryMutation(
            movies: movies.isEmpty ? nil : movies,
            shows: shows.isEmpty ? nil : shows
        )
    }

    private static func transferKey(_ media: SimklWriteMedia) -> String {
        if let imdb = media.ids.imdb { return "imdb:\(imdb.lowercased())" }
        if let tmdb = media.ids.tmdb { return "tmdb:\(tmdb)" }
        if let simkl = media.ids.simkl { return "simkl:\(simkl)" }
        return "title:\(media.title.lowercased()):\(media.year ?? 0)"
    }

    private static func merge(
        _ lhs: SimklWriteMedia,
        _ rhs: SimklWriteMedia
    ) -> SimklWriteMedia {
        var seasons: [Int: [Int: SimklWriteEpisode]] = [:]
        for season in (lhs.seasons ?? []) + (rhs.seasons ?? []) {
            var episodes = seasons[season.number] ?? [:]
            for episode in season.episodes {
                if let existing = episodes[episode.number] {
                    episodes[episode.number] = newest(existing, episode)
                } else {
                    episodes[episode.number] = episode
                }
            }
            seasons[season.number] = episodes
        }
        let mergedSeasons = seasons.keys.sorted().map { number in
            SimklWriteSeason(
                number: number,
                episodes: (seasons[number] ?? [:]).values.sorted { $0.number < $1.number }
            )
        }
        return SimklWriteMedia(
            to: nil,
            title: lhs.title,
            year: lhs.year ?? rhs.year,
            ids: lhs.ids,
            watchedAt: newest(lhs.watchedAt, rhs.watchedAt),
            seasons: mergedSeasons.isEmpty ? nil : mergedSeasons
        )
    }

    private static func newest(
        _ lhs: SimklWriteEpisode,
        _ rhs: SimklWriteEpisode
    ) -> SimklWriteEpisode {
        (lhs.watchedAt ?? "") >= (rhs.watchedAt ?? "") ? lhs : rhs
    }

    private static func newest(_ lhs: String?, _ rhs: String?) -> String? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return max(lhs, rhs)
    }

    private static func result(
        total: Int,
        transferred: Int,
        skipped: Int,
        validCount: Int
    ) -> SimklHistoryTransferResult {
        SimklHistoryTransferResult(
            total: total,
            transferred: transferred,
            skipped: skipped,
            failed: max(validCount - transferred, 0)
        )
    }
}

enum SimklLibraryTransferSource: String, CaseIterable {
    case nuvioLibrary
    case trakt

    var label: String {
        switch self {
        case .nuvioLibrary: return "Nuvio Library"
        case .trakt: return "Trakt"
        }
    }
}

struct SimklLibraryTransferResult {
    let total: Int
    let transferred: Int
    let skipped: Int
    let failed: Int

    var isComplete: Bool {
        total == transferred && skipped == 0 && failed == 0
    }
}

struct SimklLibraryTransferService {
    private static let batchSize = 100

    static func transfer(
        _ items: [LibraryStoreItem],
        store: UserDefaults = ProfileSettings.current,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil,
        progress: @escaping (Int) async -> Void
    ) async -> SimklLibraryTransferResult {
        await progress(1)

        var identities = Set<String>()
        let sourceItems = items.filter {
            identities.insert("\($0.meta.type):\($0.meta.id)").inserted
        }
        let total = sourceItems.count
        guard total > 0 else {
            await progress(100)
            return SimklLibraryTransferResult(total: 0, transferred: 0, skipped: 0, failed: 0)
        }

        guard let service = SimklAuthorizedClient(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ) else {
            return SimklLibraryTransferResult(
                total: total,
                transferred: 0,
                skipped: 0,
                failed: total
            )
        }

        let entries: [(item: LibraryStoreItem, media: SimklWriteMedia)] = sourceItems.compactMap {
            guard let media = syncMedia($0.meta, to: "plantowatch") else { return nil }
            return ($0, media)
        }
        let skipped = total - entries.count
        var transferred = 0

        for start in stride(from: 0, to: entries.count, by: batchSize) {
            guard !Task.isCancelled else {
                return result(
                    total: total,
                    transferred: transferred,
                    skipped: skipped,
                    validCount: entries.count
                )
            }
            let end = min(start + batchSize, entries.count)
            let batch = Array(entries[start..<end])
            let body = SimklListMutation(
                movies: batch.filter { !$0.item.meta.isSeries }.map(\.media),
                shows: batch.filter { $0.item.meta.isSeries }.map(\.media)
            )

            do {
                let status = try await service.post(path: "sync/add-to-list", body: body)
                guard (200..<300).contains(status) else {
                    return result(
                        total: total,
                        transferred: transferred,
                        skipped: skipped,
                        validCount: entries.count
                    )
                }
            } catch {
                return result(
                    total: total,
                    transferred: transferred,
                    skipped: skipped,
                    validCount: entries.count
                )
            }

            transferred += batch.count
            SimklSyncCache.addLibraryItems(batch.map(\.item), store: store)
            await progress(
                min(100, max(1, Int((Double(transferred) / Double(total) * 100).rounded(.down))))
            )
        }

        if transferred == total {
            await progress(100)
        }
        NotificationCenter.default.post(
            name: TraktSettingsStore.libraryChangedNotification,
            object: nil
        )
        return result(
            total: total,
            transferred: transferred,
            skipped: skipped,
            validCount: entries.count
        )
    }

    private static func result(
        total: Int,
        transferred: Int,
        skipped: Int,
        validCount: Int
    ) -> SimklLibraryTransferResult {
        SimklLibraryTransferResult(
            total: total,
            transferred: transferred,
            skipped: skipped,
            failed: max(validCount - transferred, 0)
        )
    }
}

// MARK: - Library

struct SimklLibraryService {
    static let mutationNotification = Notification.Name("nuvio.tv.simkl.library.mutation")

    static func setWatchlist(
        _ meta: NuvioMeta,
        isInWatchlist: Bool,
        store: UserDefaults = ProfileSettings.current,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        guard TraktSettingsStore.librarySourceMode(in: store) == .simkl,
              let service = SimklAuthorizedClient(
                store: store,
                client: client,
                tokenStorage: tokenStorage,
                profileScope: profileScope
              ),
              let media = syncMedia(meta, to: isInWatchlist ? "plantowatch" : nil) else {
            return false
        }

        let body = SimklListMutation(
            movies: meta.isSeries ? nil : [media],
            shows: meta.isSeries ? [media] : nil
        )

        do {
            let status = try await service.post(
                path: isInWatchlist ? "sync/add-to-list" : "sync/history/remove",
                body: body
            )
            guard (200..<300).contains(status) else { return false }
            NotificationCenter.default.post(
                name: TraktLibraryService.mutationNotification,
                object: TraktLibraryMutation(meta: meta, isInWatchlist: isInWatchlist)
            )
            NotificationCenter.default.post(
                name: TraktSettingsStore.libraryChangedNotification,
                object: nil
            )
            return true
        } catch {
            return false
        }
    }

    static func fetchLibrary(
        repository: CatalogRepository,
        store: UserDefaults = ProfileSettings.current,
        force: Bool = false
    ) async -> [LibraryStoreItem]? {
        guard TraktSettingsStore.librarySourceMode(in: store) == .simkl,
              SimklRuntimeSession.authenticatedState(store: store) != nil,
              let response = await SimklSyncLoader.libraryItems(store: store, force: force) else {
            return []
        }

        let seeds: [(String, SimklSyncItem)] =
            (response.movies ?? []).filter(isLibraryItem).map { ("movie", $0) }
            + (response.shows ?? []).filter(isLibraryItem).map { ("series", $0) }
            + (response.anime ?? []).filter(isLibraryItem).map { ("series", $0) }

        var results: [LibraryStoreItem] = []
        var seen = Set<String>()
        for (type, item) in seeds {
            guard !Task.isCancelled,
                  let placeholder = placeholderMeta(item: item, type: type),
                  seen.insert("\(type):\(placeholder.id)").inserted else { continue }
            let meta = (try? await repository.getMetadata(id: placeholder.id, type: type))
                ?? placeholder
            results.append(
                LibraryStoreItem(
                    meta: meta,
                    addedAt: parseDate(item.addedToWatchlistAt) ?? .distantPast
                )
            )
        }
        return results.sorted { $0.addedAt > $1.addedAt }
    }

    private static func isLibraryItem(_ item: SimklSyncItem) -> Bool {
        item.status?.lowercased() == "plantowatch"
    }
}

enum SelectedLibraryService {
    static var isSelectedAndAuthenticated: Bool {
        switch TraktSettingsStore.librarySourceMode {
        case .local:
            return false
        case .trakt:
            return TraktAuthStore.state.isAuthenticated
        case .simkl:
            return SimklRuntimeSession.authenticatedState() != nil
        }
    }

    static func setWatchlist(_ meta: NuvioMeta, isInWatchlist: Bool) async -> Bool {
        switch TraktSettingsStore.librarySourceMode {
        case .local:
            return false
        case .trakt:
            return await TraktLibraryService.setWatchlist(meta, isInWatchlist: isInWatchlist)
        case .simkl:
            return await SimklLibraryService.setWatchlist(meta, isInWatchlist: isInWatchlist)
        }
    }

    static func fetchLibrary(repository: CatalogRepository) async -> [LibraryStoreItem]? {
        switch TraktSettingsStore.librarySourceMode {
        case .local:
            return []
        case .trakt:
            return await TraktLibraryService.fetchLibrary(repository: repository)
        case .simkl:
            return await SimklLibraryService.fetchLibrary(repository: repository)
        }
    }
}

enum SimklProgressTransferSource: String, CaseIterable {
    case nuvioSync
    case trakt

    var label: String {
        switch self {
        case .nuvioSync: return "Nuvio Sync"
        case .trakt: return "Trakt"
        }
    }
}

struct SimklProgressTransferResult {
    let total: Int
    let transferred: Int
    let skipped: Int
    let failed: Int

    var isComplete: Bool {
        total == transferred && skipped == 0 && failed == 0
    }
}

struct SimklProgressTransferService {
    static func transfer(
        _ items: [ContinueWatchingItem],
        store: UserDefaults = ProfileSettings.current,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil,
        progress: @escaping (Int) async -> Void
    ) async -> SimklProgressTransferResult {
        await progress(1)

        var identities = Set<String>()
        let sourceItems = items
            .filter { item in
                let percentage = item.duration > 0
                    ? item.position / item.duration * 100
                    : 0
                guard percentage.isFinite, percentage > 0, percentage < 90 else {
                    return false
                }
                return identities.insert(
                    "\(item.meta.type):\(item.meta.id):\(item.season ?? -1):\(item.episode ?? -1)"
                ).inserted
            }
            // Simkl assigns the pause time when each request arrives. Submit
            // oldest first so the source's newest item is submitted last and
            // remains first in Continue Watching.
            .sorted { $0.lastWatchedAt < $1.lastWatchedAt }
        let total = sourceItems.count
        guard total > 0 else {
            await progress(100)
            return SimklProgressTransferResult(total: 0, transferred: 0, skipped: 0, failed: 0)
        }

        guard let service = SimklAuthorizedClient(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ) else {
            return SimklProgressTransferResult(
                total: total,
                transferred: 0,
                skipped: 0,
                failed: total
            )
        }

        var transferred = 0
        var skipped = 0
        var failed = 0

        for item in sourceItems {
            guard !Task.isCancelled else {
                return SimklProgressTransferResult(
                    total: total,
                    transferred: transferred,
                    skipped: skipped,
                    failed: failed + total - transferred - skipped - failed
                )
            }

            let percentage = item.duration > 0
                ? item.position / item.duration * 100
                : 0
            guard let media = scrobbleMedia(item.meta),
                  !item.meta.isSeries
                    || (item.season != nil && item.episode != nil) else {
                skipped += 1
                continue
            }

            let body = SimklScrobbleRequest(
                progress: percentage,
                movie: item.meta.isSeries ? nil : media,
                show: item.meta.isSeries ? media : nil,
                episode: item.meta.isSeries
                    ? SimklScrobbleEpisode(season: item.season, number: item.episode)
                    : nil
            )

            do {
                let status = try await service.post(path: "scrobble/pause", body: body)
                if (200..<300).contains(status) {
                    transferred += 1
                    SimklSyncCache.addPlayback(item, progress: percentage, store: store)
                    await TraktProgressService.recordLocalPlayback(
                        meta: item.meta,
                        position: item.position,
                        duration: item.duration,
                        season: item.season,
                        episode: item.episode,
                        source: .simkl,
                        notify: false
                    )
                } else {
                    failed += 1
                }
            } catch {
                failed += 1
            }

            await progress(
                min(
                    99,
                    max(
                        1,
                        Int(
                            Double(transferred) / Double(total) * 100
                        )
                    )
                )
            )
        }

        if transferred == total {
            await progress(100)
        }
        NotificationCenter.default.post(
            name: TraktSettingsStore.continueWatchingChangedNotification,
            object: nil
        )
        return SimklProgressTransferResult(
            total: total,
            transferred: transferred,
            skipped: skipped,
            failed: failed
        )
    }
}

// MARK: - Playback progress and scrobbling

struct SimklProgressService {
    static func fetchContinueWatching(
        repository: CatalogRepository,
        store: UserDefaults = ProfileSettings.current
    ) async -> [ContinueWatchingItem]? {
        guard let service = SimklAuthorizedClient(store: store),
              let activities = try? await SimklSyncLoader.activities(using: service) else {
            return nil
        }

        let watermark = activities.playbackWatermark
        let playbacks: [SimklPlaybackDTO]
        if !watermark.isEmpty,
           SimklSyncCache.playbackWatermark(in: store) == watermark,
           let cached = SimklSyncCache.playbacks(in: store) {
            playbacks = cached
        } else {
            guard let fetched = try? await service.get(
                [SimklPlaybackDTO].self,
                path: "sync/playback"
            ) else { return nil }
            playbacks = fetched
            SimklSyncCache.savePlaybacks(fetched, watermark: watermark, store: store)
        }

        var results: [ContinueWatchingItem] = []
        for playback in playbacks.sorted(by: {
            (parseDate($0.pausedAt) ?? .distantPast) > (parseDate($1.pausedAt) ?? .distantPast)
        }) {
            guard !Task.isCancelled,
                  let progress = playback.progress,
                  progress > 0, progress < 90,
                  let seed = progressSeed(playback),
                  let placeholder = placeholderMeta(item: seed.item, type: seed.type) else { continue }
            let meta = (try? await repository.getMetadata(id: placeholder.id, type: seed.type))
                ?? placeholder
            let duration = runtimeSeconds(meta.runtime) ?? 100
            results.append(
                ContinueWatchingItem(
                    meta: meta,
                    streamUrl: "",
                    position: duration * progress / 100,
                    duration: duration,
                    lastWatchedAt: parseDate(playback.pausedAt) ?? Date(),
                    season: playback.episode?.season,
                    episode: playback.episode?.resolvedNumber,
                    released: nil,
                    episodeTitleOverride: playback.episode?.title,
                    episodeOverviewOverride: nil,
                    episodeThumbnailOverride: nil,
                    isUpNext: false
                )
            )
        }
        return Array(results.prefix(20))
    }

    static func reportPlayback(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        action: TraktScrobbleAction,
        store: UserDefaults = ProfileSettings.current,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        guard TraktSettingsStore.watchProgressSource(in: store) == .simkl,
              let service = SimklAuthorizedClient(
                store: store,
                client: client,
                tokenStorage: tokenStorage,
                profileScope: profileScope
              ),
              let media = scrobbleMedia(meta),
              duration > 0, position.isFinite, duration.isFinite else { return false }
        if meta.isSeries {
            guard let season, season >= 0, let episode, episode > 0 else { return false }
        }

        let progress = min(max(position / duration * 100, 0), 100)
        let body = SimklScrobbleRequest(
            progress: progress,
            movie: meta.isSeries ? nil : media,
            show: meta.isSeries ? media : nil,
            episode: meta.isSeries
                ? SimklScrobbleEpisode(season: season, number: episode)
                : nil
        )
        do {
            let status = try await service.post(path: "scrobble/\(action.rawValue)", body: body)
            // Simkl documents 409 stop as idempotent success for a recently
            // completed session.
            guard (200..<300).contains(status) || (action == .stop && status == 409) else {
                return false
            }
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            return true
        } catch {
            return false
        }
    }

    private static func progressSeed(
        _ playback: SimklPlaybackDTO
    ) -> (item: SimklSyncItem, type: String)? {
        let media = playback.movie ?? playback.show ?? playback.anime
        guard let media else { return nil }
        return (
            SimklSyncItem(
                title: media.title,
                year: media.year,
                ids: media.ids,
                status: nil,
                addedToWatchlistAt: nil,
                lastWatched: nil,
                watchedAt: nil,
                seasons: nil
            ),
            playback.movie == nil ? "series" : "movie"
        )
    }
}

// MARK: - Write payloads and common helpers

private struct SimklWriteMedia: Encodable {
    let to: String?
    let title: String
    let year: Int?
    let ids: SimklSyncIDs
    let watchedAt: String?
    let seasons: [SimklWriteSeason]?

    enum CodingKeys: String, CodingKey {
        case to, title, year, ids, seasons
        case watchedAt = "watched_at"
    }
}

private struct SimklWriteSeason: Encodable {
    let number: Int
    let episodes: [SimklWriteEpisode]
}

private struct SimklWriteEpisode: Encodable {
    let number: Int
    let watchedAt: String?

    enum CodingKeys: String, CodingKey {
        case number
        case watchedAt = "watched_at"
    }
}

private struct SimklHistoryMutation: Encodable {
    let movies: [SimklWriteMedia]?
    let shows: [SimklWriteMedia]?
}

private struct SimklListMutation: Encodable {
    let movies: [SimklWriteMedia]?
    let shows: [SimklWriteMedia]?
}

private struct SimklScrobbleRequest: Encodable {
    let progress: Double
    let movie: SimklScrobbleMedia?
    let show: SimklScrobbleMedia?
    let episode: SimklScrobbleEpisode?
}

private struct SimklScrobbleMedia: Encodable {
    let title: String
    let year: Int?
    let ids: SimklSyncIDs
}

private struct SimklScrobbleEpisode: Encodable {
    let season: Int?
    let number: Int?
}

private func syncMedia(_ meta: NuvioMeta, to: String?) -> SimklWriteMedia? {
    guard let ids = simklIDs(meta), ids.imdb != nil || ids.tmdb != nil || ids.simkl != nil else {
        return nil
    }
    return SimklWriteMedia(
        to: to,
        title: meta.name,
        year: meta.year,
        ids: ids,
        watchedAt: nil,
        seasons: nil
    )
}

private func historyMutation(
    meta: NuvioMeta,
    season: Int?,
    episode: Int?,
    watchedAt: String?
) -> SimklHistoryMutation? {
    guard let ids = simklIDs(meta), ids.imdb != nil || ids.tmdb != nil || ids.simkl != nil else {
        return nil
    }
    let seasons: [SimklWriteSeason]?
    if meta.isSeries, let season, let episode {
        seasons = [
            SimklWriteSeason(
                number: season,
                episodes: [SimklWriteEpisode(number: episode, watchedAt: watchedAt)]
            )
        ]
    } else {
        seasons = nil
    }
    let media = SimklWriteMedia(
        to: nil,
        title: meta.name,
        year: meta.year,
        ids: ids,
        watchedAt: watchedAt,
        seasons: seasons
    )
    return meta.isSeries
        ? SimklHistoryMutation(movies: nil, shows: [media])
        : SimklHistoryMutation(movies: [media], shows: nil)
}

private func scrobbleMedia(_ meta: NuvioMeta) -> SimklScrobbleMedia? {
    guard let ids = simklIDs(meta), ids.imdb != nil || ids.tmdb != nil || ids.simkl != nil else {
        return nil
    }
    return SimklScrobbleMedia(title: meta.name, year: meta.year, ids: ids)
}

private func simklIDs(_ meta: NuvioMeta) -> SimklSyncIDs? {
    let first = meta.id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? meta.id
    let simkl = meta.id.hasPrefix("simkl:") ? Int(meta.id.dropFirst("simkl:".count)) : nil
    let imdb = meta.imdbId ?? (first.hasPrefix("tt") ? first : nil)
    let tmdb = meta.tmdbId ?? (meta.id.hasPrefix("tmdb:")
        ? Int(meta.id.dropFirst("tmdb:".count))
        : nil)
    guard simkl != nil || imdb != nil || tmdb != nil else { return nil }
    return SimklSyncIDs(simkl: simkl, imdb: imdb, tmdb: tmdb)
}

private func placeholderMeta(item: SimklSyncItem, type: String) -> NuvioMeta? {
    guard let id = contentID(item.ids) else { return nil }
    return NuvioMeta(
        id: id,
        name: item.title ?? id,
        description: nil,
        posterUrl: nil,
        backgroundUrl: nil,
        logoUrl: nil,
        imdbId: item.ids?.imdb,
        tmdbId: item.ids?.tmdb,
        type: type,
        year: item.year,
        genres: nil,
        rating: nil,
        releaseInfo: item.year.map(String.init),
        runtime: nil,
        cast: nil,
        director: nil,
        writer: nil,
        certification: nil,
        country: nil,
        released: nil
    )
}

private func contentID(_ ids: SimklSyncIDs?) -> String? {
    if let imdb = ids?.imdb?.trimmingCharacters(in: .whitespacesAndNewlines), !imdb.isEmpty {
        return imdb
    }
    if let tmdb = ids?.tmdb { return "tmdb:\(tmdb)" }
    if let simkl = ids?.simkl { return "simkl:\(simkl)" }
    return nil
}

private func parseDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let withFractional = ISO8601DateFormatter()
    withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractional.date(from: value) { return date }
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    return standard.date(from: value)
}

private func iso8601(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func runtimeSeconds(_ runtime: String?) -> Double? {
    guard let runtime else { return nil }
    let value = runtime.split(whereSeparator: { !$0.isNumber }).first.flatMap { Double($0) }
    return value.map { $0 * 60 }
}
