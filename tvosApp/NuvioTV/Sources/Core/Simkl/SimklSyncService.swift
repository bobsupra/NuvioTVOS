import Foundation

// MARK: - Shared session

enum SimklRuntimeSession {
    static func profileScope() -> String {
        let value = ProfileSettings.activeProfileScope.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty && value != "default" {
            return value
        }
        let watchedValue = WatchedStore.activeProfileId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return watchedValue.isEmpty ? (value.isEmpty ? "default" : value) : watchedValue
    }

    static func authenticatedState(
        store: UserDefaults = ProfileSettings.current,
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) -> SimklAuthState? {
        let storeProfileId = store.string(forKey: "nuvio.tv.profile.settings.profileID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedProfileScope: String
        if let profileScope, !profileScope.isEmpty {
            resolvedProfileScope = profileScope
        } else if let storeProfileId, !storeProfileId.isEmpty {
            resolvedProfileScope = storeProfileId
        } else {
            resolvedProfileScope = self.profileScope()
        }
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
    /// Anime id spaces. Simkl accepts all of these on `/sync/history` and
    /// `/scrobble/*`; omitting them is what made anime carrying only a `kitsu:`
    /// or `mal:` id impossible to sync or scrobble.
    let mal: Int?
    let anidb: Int?
    let anilist: Int?
    let kitsu: Int?

    enum CodingKeys: String, CodingKey {
        case simkl, imdb, tmdb, tvdb, mal, anidb, anilist, kitsu
    }

    init(
        simkl: Int? = nil,
        imdb: String? = nil,
        tmdb: Int? = nil,
        tvdb: Int? = nil,
        mal: Int? = nil,
        anidb: Int? = nil,
        anilist: Int? = nil,
        kitsu: Int? = nil
    ) {
        self.simkl = simkl
        self.imdb = imdb
        self.tmdb = tmdb
        self.tvdb = tvdb
        self.mal = mal
        self.anidb = anidb
        self.anilist = anilist
        self.kitsu = kitsu
    }

    /// Any identifier Simkl can match on.
    var hasUsableIdentifier: Bool {
        simkl != nil || imdb != nil || tmdb != nil || tvdb != nil
            || mal != nil || anidb != nil || anilist != nil || kitsu != nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        simkl = Self.flexibleInt(in: container, forKey: .simkl)
        tmdb = Self.flexibleInt(in: container, forKey: .tmdb)
        tvdb = Self.flexibleInt(in: container, forKey: .tvdb)
        mal = Self.flexibleInt(in: container, forKey: .mal)
        anidb = Self.flexibleInt(in: container, forKey: .anidb)
        anilist = Self.flexibleInt(in: container, forKey: .anilist)
        kitsu = Self.flexibleInt(in: container, forKey: .kitsu)
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

/// One row of `/sync/all-items`.
///
/// The row is *not* flat. Watch state — `status`, `last_watched_at`,
/// `added_to_watchlist_at`, `seasons` — sits at the top level, but the title
/// itself is nested under whichever of `movie` / `show` / `anime` applies
/// (anime uses `show`, matching the cross-catalog data model):
///
/// ```json
/// { "status": "completed", "last_watched_at": "2026-05-15T00:13:09Z",
///   "movie": { "title": "Pulp Fiction", "year": 1994, "ids": { … } } }
/// ```
///
/// Reading `title` / `year` / `ids` flat yields nil for every row, which
/// collapses every item to the identity `title::0` and leaves it with no
/// resolvable content id — so nothing Simkl holds ever reaches the app. The
/// decoder accepts the flat shape too, because that is how this type is
/// re-read from its own cache.
struct SimklSyncItem: Codable {
    let title: String?
    let year: Int?
    let ids: SimklSyncIDs?
    let status: String?
    let addedToWatchlistAt: String?
    /// Simkl's name for "when this was last watched". There is no `watched_at`
    /// at this level, and the sibling `last_watched` field is a different thing
    /// that reads null on every row.
    let lastWatchedAt: String?
    let seasons: [SimklSyncSeason]?

    enum CodingKeys: String, CodingKey {
        case title, year, ids, status, seasons
        case movie, show, anime
        case addedToWatchlistAt = "added_to_watchlist_at"
        case lastWatchedAt = "last_watched_at"
    }

    private struct Media: Decodable {
        let title: String?
        let year: Int?
        let ids: SimklSyncIDs?
    }

    init(
        title: String?,
        year: Int?,
        ids: SimklSyncIDs?,
        status: String?,
        addedToWatchlistAt: String?,
        lastWatchedAt: String?,
        seasons: [SimklSyncSeason]?
    ) {
        self.title = title
        self.year = year
        self.ids = ids
        self.status = status
        self.addedToWatchlistAt = addedToWatchlistAt
        self.lastWatchedAt = lastWatchedAt
        self.seasons = seasons
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        addedToWatchlistAt = try container.decodeIfPresent(
            String.self,
            forKey: .addedToWatchlistAt
        )
        lastWatchedAt = try container.decodeIfPresent(String.self, forKey: .lastWatchedAt)
        seasons = try container.decodeIfPresent([SimklSyncSeason].self, forKey: .seasons)

        let media = try [CodingKeys.movie, .show, .anime]
            .lazy
            .compactMap { try container.decodeIfPresent(Media.self, forKey: $0) }
            .first
        if let media {
            title = media.title
            year = media.year
            ids = media.ids
        } else {
            // Cache round-trip, which this type encodes flat.
            title = try container.decodeIfPresent(String.self, forKey: .title)
            year = try container.decodeIfPresent(Int.self, forKey: .year)
            ids = try container.decodeIfPresent(SimklSyncIDs.self, forKey: .ids)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(year, forKey: .year)
        try container.encodeIfPresent(ids, forKey: .ids)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(addedToWatchlistAt, forKey: .addedToWatchlistAt)
        try container.encodeIfPresent(lastWatchedAt, forKey: .lastWatchedAt)
        try container.encodeIfPresent(seasons, forKey: .seasons)
    }
}

struct SimklAllItemsResponse: Codable {
    var shows: [SimklSyncItem]?
    var movies: [SimklSyncItem]?
    var anime: [SimklSyncItem]?

    init(
        shows: [SimklSyncItem]? = nil,
        movies: [SimklSyncItem]? = nil,
        anime: [SimklSyncItem]? = nil
    ) {
        self.shows = shows
        self.movies = movies
        self.anime = anime
    }

    enum CodingKeys: String, CodingKey {
        case shows, movies, anime
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            shows = try container.decodeIfPresent([SimklSyncItem].self, forKey: .shows)
            movies = try container.decodeIfPresent([SimklSyncItem].self, forKey: .movies)
            anime = try container.decodeIfPresent([SimklSyncItem].self, forKey: .anime)
        } else if let single = try? decoder.singleValueContainer(),
                  let items = try? single.decode([SimklSyncItem].self) {
            shows = items.filter { $0.seasons != nil }
            movies = items.filter { $0.seasons == nil }
            anime = nil
        } else {
            shows = nil
            movies = nil
            anime = nil
        }
    }

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

struct SimklSettingsActivity: Codable, Equatable {
    let all: String?
}

struct SimklActivitiesResponse: Codable, Equatable {
    let all: String?
    let tvShows: SimklActivityGroup?
    let movies: SimklActivityGroup?
    let anime: SimklActivityGroup?
    /// Bumps when the account's own preferences change. Simkl asks callers to
    /// gate `POST /users/settings` on this instead of refetching on launch.
    let settings: SimklSettingsActivity?

    enum CodingKeys: String, CodingKey {
        case all, movies, anime, settings
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

/// Internal rather than file-private so the playback-cache invalidation that
/// keeps Continue Watching correct after a scrobble is directly testable.
enum SimklSyncCache {
    // v2: everything written under the v1 keys was decoded from a misread row
    // shape — every entry collapsed to the identity `title::0` with no ids, so
    // the caches hold nothing usable. Moving the key retires that content and
    // forces one full re-pull instead of a delta that would only ever recover
    // titles touched after the stale watermark.
    private static let itemCacheKey = "nuvio.tv.simkl.sync.items.v2"
    private static let itemActivityKey = "nuvio.tv.simkl.sync.items.activities.v2"
    private static let historyCacheKey = "nuvio.tv.simkl.sync.history.v2"
    private static let historySnapshotKey = "nuvio.tv.simkl.sync.history.snapshot.v3"
    private static let playbackCacheKey = "nuvio.tv.simkl.sync.playback"
    private static let playbackSnapshotKey = "nuvio.tv.simkl.sync.playback.snapshot.v3"
    private static let playbackInvalidatedKey = "nuvio.tv.simkl.sync.playback.invalidated.v3"
    private static let storageDirectoryName = "SimklSyncCache"

    // Split v2 payloads cannot prove that their activity watermark belongs to
    // the same item list. Start a fresh namespace and bootstrap once.
    private static let itemSnapshotKey = "nuvio.tv.simkl.sync.items.snapshot.v3"
    struct ItemSnapshot: Codable {
        let items: SimklAllItemsResponse
        let activities: SimklActivitiesResponse?
    }

    static func itemSnapshot(in store: UserDefaults) -> ItemSnapshot? {
        decode(ItemSnapshot.self, key: itemSnapshotKey, store: store)
    }

    /// Removes cache blobs earlier builds wrote into preferences.
    ///
    /// Lazy migration in ``encode(_:key:store:)`` is not enough on a device that
    /// is already over the limit: the next unrelated `UserDefaults` write aborts
    /// the process before the Simkl cache is ever touched. This has to run at
    /// startup, before anything else writes. Removing keys only shrinks the
    /// plist, so it is safe even at the edge.
    static func purgeLegacyPreferenceBlobs(in store: UserDefaults) {
        let retired = [
            itemCacheKey, historyCacheKey, playbackCacheKey,
            // Pre-v2 names, which the key rename orphaned.
            "nuvio.tv.simkl.sync.items",
            "nuvio.tv.simkl.sync.history",
            "nuvio.tv.simkl.sync.items.activities"
        ]
        for key in retired where store.object(forKey: key) != nil {
            store.removeObject(forKey: key)
        }
    }

    /// Sign-out cleanup. These caches used to live in the per-profile settings
    /// suite, so removing that suite took them with it. They are files now and
    /// have to be dropped explicitly or the next account inherits them.
    static func eraseAll() {
        LargePayloadStore.removeDirectory(storageDirectoryName)
    }

    static func items(in store: UserDefaults) -> SimklAllItemsResponse? {
        itemSnapshot(in: store)?.items
    }

    static func saveItems(
        _ items: SimklAllItemsResponse,
        activities: SimklActivitiesResponse,
        store: UserDefaults
    ) {
        encode(ItemSnapshot(items: items, activities: activities), key: itemSnapshotKey, store: store)
    }

    static func addLibraryItems(_ libraryItems: [LibraryStoreItem], store: UserDefaults) {
        let snapshot = itemSnapshot(in: store)
        var items = snapshot?.items ?? SimklAllItemsResponse()
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
                lastWatchedAt: nil,
                seasons: nil
            )
            if item.meta.isSeries {
                additions.shows = (additions.shows ?? []) + [value]
            } else {
                additions.movies = (additions.movies ?? []) + [value]
            }
        }

        items.merge(additions)
        encode(ItemSnapshot(items: items, activities: snapshot?.activities), key: itemSnapshotKey, store: store)
    }

    static func itemActivities(in store: UserDefaults) -> SimklActivitiesResponse? {
        itemSnapshot(in: store)?.activities
    }

    struct HistorySnapshot: Codable {
        let records: [SimklHistoryRecord]
        let watermark: String?
        let activities: SimklActivitiesResponse?
    }

    static func historySnapshot(in store: UserDefaults) -> HistorySnapshot? {
        if let snapshot = decode(HistorySnapshot.self, key: historySnapshotKey, store: store) {
            return snapshot
        }
        // Keep legacy records for watched-state reconciliation, but do not trust
        // separately saved watermarks or activities. A nil watermark forces a
        // full reload before the cache can be used for incremental history sync.
        guard let records = decode([SimklHistoryRecord].self, key: historyCacheKey, store: store) else {
            return nil
        }
        return HistorySnapshot(records: records, watermark: nil, activities: nil)
    }

    static func history(in store: UserDefaults) -> [SimklHistoryRecord] {
        historySnapshot(in: store)?.records ?? []
    }

    static func historyWatermark(in store: UserDefaults) -> String? {
        historySnapshot(in: store)?.watermark
    }

    static func historyActivities(in store: UserDefaults) -> SimklActivitiesResponse? {
        historySnapshot(in: store)?.activities
    }

    static func saveHistory(
        _ records: [SimklHistoryRecord],
        watermark: String?,
        activities: SimklActivitiesResponse?,
        store: UserDefaults
    ) {
        let snapshot = HistorySnapshot(records: records, watermark: watermark, activities: activities)
        encode(snapshot, key: historySnapshotKey, store: store)
    }

    /// Seasons Simkl currently holds watched episodes in for a title. Used to
    /// scope a whole-title unwatch so it clears episodes instead of deleting
    /// the library row.
    static func watchedSeasons(matching ids: SimklSyncIDs, in store: UserDefaults) -> [Int] {
        let seasons = history(in: store)
            .filter { $0.key.hasPrefix("series:") }
            .flatMap(\.items)
            .filter { sameTitle($0.meta, ids) }
            .compactMap(\.season)
        return Array(Set(seasons)).sorted()
    }

    /// Cached history rows carry the ids Simkl answered with, which is rarely
    /// the same id space the local meta uses — match on any shared identifier.
    private static func sameTitle(_ meta: NuvioMeta, _ ids: SimklSyncIDs) -> Bool {
        if let imdb = ids.imdb?.lowercased(), !imdb.isEmpty,
           meta.imdbId?.lowercased() == imdb {
            return true
        }
        if let tmdb = ids.tmdb, meta.tmdbId == tmdb { return true }
        if let simkl = ids.simkl,
           meta.id.caseInsensitiveCompare("simkl:\(simkl)") == .orderedSame {
            return true
        }
        return false
    }

    struct PlaybackSnapshot: Codable {
        let playbacks: [SimklPlaybackDTO]
        let watermark: String?
    }

    static func playbackSnapshot(in store: UserDefaults) -> PlaybackSnapshot? {
        if let snapshot = decode(PlaybackSnapshot.self, key: playbackSnapshotKey, store: store) {
            // Invalidation only makes a snapshot less reusable. Keep it separate
            // so a failed payload replacement cannot undo a successful scrobble.
            return PlaybackSnapshot(
                playbacks: snapshot.playbacks,
                watermark: store.bool(forKey: playbackInvalidatedKey) ? nil : snapshot.watermark
            )
        }
        guard let playbacks = decode([SimklPlaybackDTO].self, key: playbackCacheKey, store: store) else {
            return nil
        }
        // Legacy records remain available to removePlayback, but the separate
        // legacy watermark cannot establish that they are a consistent pair.
        return PlaybackSnapshot(playbacks: playbacks, watermark: nil)
    }

    static func playbacks(in store: UserDefaults) -> [SimklPlaybackDTO]? {
        playbackSnapshot(in: store)?.playbacks
    }

    static func playbackWatermark(in store: UserDefaults) -> String? {
        playbackSnapshot(in: store)?.watermark
    }

    static func savePlaybacks(
        _ playbacks: [SimklPlaybackDTO],
        watermark: String,
        store: UserDefaults
    ) {
        let snapshot = PlaybackSnapshot(playbacks: playbacks, watermark: watermark)
        if encode(snapshot, key: playbackSnapshotKey, store: store) {
            store.removeObject(forKey: playbackInvalidatedKey)
        }
    }

    /// Forces the next Continue Watching read to re-fetch `sync/playback`.
    ///
    /// The cache is keyed on Simkl's account watermark, which lags a scrobble we
    /// just sent — Simkl holds a 20-second per-user lock, and the request is in
    /// flight while Home is already refreshing. Without dropping the watermark
    /// here, that refresh is served the list from *before* the current viewing
    /// session, and the title vanishes as soon as the optimistic local
    /// checkpoint stops masking it.
    static func invalidatePlaybacks(in store: UserDefaults) {
        store.set(true, forKey: playbackInvalidatedKey)
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

        let snapshot = playbackSnapshot(in: store)
        var cached = snapshot?.playbacks ?? []
        let newIdentity = playbackIdentity(playback)
        cached.removeAll { playbackIdentity($0) == newIdentity }
        cached.append(playback)
        encode(
            PlaybackSnapshot(playbacks: cached, watermark: snapshot?.watermark),
            key: playbackSnapshotKey,
            store: store
        )
    }

    private static func playbackIdentity(_ playback: SimklPlaybackDTO) -> String {
        let media = playback.movie ?? playback.show ?? playback.anime
        let item = SimklSyncItem(
            title: media?.title,
            year: media?.year,
            ids: media?.ids,
            status: nil,
            addedToWatchlistAt: nil,
            lastWatchedAt: nil,
            seasons: nil
        )
        return [
            playback.movie == nil ? "series" : "movie",
            SimklAllItemsResponse.identity(item),
            String(playback.episode?.season ?? -1),
            String(playback.episode?.resolvedNumber ?? -1)
        ].joined(separator: ":")
    }

    /// These blobs are far too large for `UserDefaults`.
    ///
    /// tvOS aborts the process outright once an app's preferences exceed its
    /// limit — `__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__`,
    /// a `SIGABRT` with nothing to catch. The history cache carries a full
    /// `NuvioMeta` per watched episode, so a real account reaches megabytes.
    /// `WatchedStore` moved to files for exactly this reason; this is the same
    /// treatment. Small scalars (watermarks, activity timestamps) stay in
    /// `UserDefaults`, which is what it is for.
    @discardableResult
    private static func encode<T: Encodable>(_ value: T, key: String, store: UserDefaults) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        guard LargePayloadStore.write(
            data,
            key: scopedKey(key, store: store),
            directory: storageDirectoryName
        ) else {
            // Deliberately no preferences fallback. Losing the cache costs one
            // full re-pull on the next sync; writing a payload this size to
            // preferences is the abort this whole path exists to avoid.
            return false
        }
        // An older build's copy would otherwise keep counting against the
        // preferences budget forever.
        store.removeObject(forKey: key)
        return true
    }

    /// Profile-scoped: the `UserDefaults` key is shared across profiles and only
    /// the suite differed, so the filename has to carry the scope instead.
    /// Use the captured store's identity, not whichever profile is active when
    /// a suspended request resumes. Unmarked stores use the stable legacy
    /// default namespace rather than borrowing another profile's identity.
    private static func scopedKey(_ key: String, store: UserDefaults) -> String {
        let storeProfileID = store.string(forKey: "nuvio.tv.profile.settings.profileID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = storeProfileID.flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        return "\(key).\(scope)"
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        key: String,
        store: UserDefaults
    ) -> T? {
        if let data = LargePayloadStore.read(
            key: scopedKey(key, store: store),
            directory: storageDirectoryName
        ) {
            return try? JSONDecoder().decode(type, from: data)
        }
        // Written by a build that still used preferences: read it once — the
        // next `encode` moves it to a file and clears the key.
        guard let data = store.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Copies of one client share only tokens adopted by that client's refreshes.
/// All mutable state is accessed through synchronous lock helpers.
final class SimklAuthorizationOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var accessToken: String
    private var pendingRefresh: (id: UUID, token: String, task: Task<String?, Never>)?

    init(token: String) { accessToken = token }

    var token: String {
        lock.lock()
        defer { lock.unlock() }
        return accessToken
    }

    @discardableResult
    func adopt(_ token: String, replacing previous: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard accessToken == previous else { return false }
        accessToken = token
        return true
    }

    func refresh(using operation: @escaping () async -> String?) async -> String? {
        let (id, task) = refreshTask(using: operation)
        let value = await task.value
        finishRefresh(id)
        return value
    }

    private func refreshTask(using operation: @escaping () async -> String?) -> (UUID, Task<String?, Never>) {
        lock.lock()
        defer { lock.unlock() }
        if let pendingRefresh, pendingRefresh.token == accessToken {
            return (pendingRefresh.id, pendingRefresh.task)
        }
        let id = UUID()
        let task = Task { await operation() }
        pendingRefresh = (id, accessToken, task)
        return (id, task)
    }

    private func finishRefresh(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if pendingRefresh?.id == id { pendingRefresh = nil }
    }
}

struct SimklAuthorizedClient {
    let client: SimklAPIClient
    let store: UserDefaults
    let clientID: String
    private let owner: SimklAuthorizationOwner
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
        self.owner = SimklAuthorizationOwner(token: token)
        self.tokenStorage = tokenStorage
        self.profileScope = resolvedProfileScope
    }

    private func tryRefreshToken(rejectedToken: String) async -> String? {
        guard isCurrentAuthorization() else { return nil }
        if owner.token != rejectedToken { return owner.token }
        let refreshed = await owner.refresh {
            guard self.isCurrentAuthorization() else { return nil }
            let previous = self.owner.token
            if previous != rejectedToken { return previous }
            let authService = SimklAuthService(
                client: self.client, store: self.store,
                profileScope: self.profileScope, tokenStorage: self.tokenStorage
            )
            let succeeded = await authService.refreshTokenIfNeeded(
                force: true,
                shouldCommit: { self.owner.token == previous && self.isCurrentAuthorization() },
                didRefreshToken: { _ = self.owner.adopt($0, replacing: previous) }
            )
            guard succeeded, self.isCurrentAuthorization() else { return nil }
            return self.owner.token
        }
        guard isCurrentAuthorization() else { return nil }
        return refreshed
    }

    func get<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = []
    ) async throws -> T {
        let requestToken = owner.token
        var rejectedToken = requestToken
        let result: SimklHTTPResult<T> = try await client.get(
            path: path,
            clientID: clientID,
            accessToken: requestToken,
            queryItems: query
        )
        if result.statusCode == 401 {
            if let refreshedToken = await tryRefreshToken(rejectedToken: requestToken) {
                rejectedToken = refreshedToken
                let retry: SimklHTTPResult<T> = try await client.get(
                    path: path,
                    clientID: clientID,
                    accessToken: refreshedToken,
                    queryItems: query
                )
                if retry.statusCode != 401 {
                    return try retry.valueOrThrow()
                }
            }
            clearAuthIfCurrent(rejectedToken: rejectedToken)
        }
        return try result.valueOrThrow()
    }

    func getOptional<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = [],
        noContentValue: T? = nil
    ) async -> T? {
        let requestToken = owner.token
        guard let result: SimklHTTPResult<T> = try? await client.get(
            path: path,
            clientID: clientID,
            accessToken: requestToken,
            queryItems: query
        ) else { return nil }
        if result.statusCode == 401 {
            if let refreshedToken = await tryRefreshToken(rejectedToken: requestToken) {
                guard let retry: SimklHTTPResult<T> = try? await client.get(
                    path: path,
                    clientID: clientID,
                    accessToken: refreshedToken,
                    queryItems: query
                ) else { return nil }
                if retry.statusCode == 401 {
                    clearAuthIfCurrent(rejectedToken: refreshedToken)
                }
                if retry.statusCode == 204 { return noContentValue }
                return (200..<300).contains(retry.statusCode) ? retry.value : nil
            }
            clearAuthIfCurrent(rejectedToken: requestToken)
        }
        if result.statusCode == 204 { return noContentValue }
        guard (200..<300).contains(result.statusCode) else { return nil }
        return result.value
    }

    func post<B: Encodable>(
        path: String,
        query: [URLQueryItem] = [],
        body: B
    ) async throws -> Int {
        try await postReturningBody(path: path, query: query, body: body).status
    }

    func delete(path: String, query: [URLQueryItem] = []) async throws -> Int {
        let requestToken = owner.token
        var rejectedToken = requestToken
        let result = try await client.delete(
            path: path,
            clientID: clientID,
            accessToken: requestToken,
            queryItems: query
        )
        if result.statusCode == 401 {
            if let refreshedToken = await tryRefreshToken(rejectedToken: requestToken) {
                rejectedToken = refreshedToken
                let retry = try await client.delete(
                    path: path,
                    clientID: clientID,
                    accessToken: refreshedToken,
                    queryItems: query
                )
                if retry.statusCode != 401 {
                    return retry.statusCode
                }
            }
            clearAuthIfCurrent(rejectedToken: rejectedToken)
        }
        return result.statusCode
    }

    /// `/sync/history` always answers 201, even when it resolved nothing, and
    /// reports the rejects in a `not_found` object. Callers that need to know
    /// what actually landed have to read the body.
    func postReturningBody<B: Encodable>(
        path: String,
        query: [URLQueryItem] = [],
        body: B
    ) async throws -> (status: Int, data: Data) {
        let requestToken = owner.token
        var rejectedToken = requestToken
        let result = try await client.post(
            path: path,
            clientID: clientID,
            accessToken: requestToken,
            queryItems: query,
            body: body
        )
        if result.statusCode == 401 {
            if let refreshedToken = await tryRefreshToken(rejectedToken: requestToken) {
                rejectedToken = refreshedToken
                let retry = try await client.post(
                    path: path,
                    clientID: clientID,
                    accessToken: refreshedToken,
                    queryItems: query,
                    body: body
                )
                if retry.statusCode != 401 {
                    return (retry.statusCode, retry.rawData)
                }
            }
            clearAuthIfCurrent(rejectedToken: rejectedToken)
        }
        return (result.statusCode, result.rawData)
    }
    func isCurrentAuthorization() -> Bool {
        guard !Task.isCancelled, ProfileSettings.isActiveStore(store),
              SimklConfig.clientID(in: store) == clientID,
              let state = SimklRuntimeSession.authenticatedState(
                  store: store, tokenStorage: tokenStorage, profileScope: profileScope
              ) else { return false }
        return state.accessToken == owner.token && state.credentialClientID == clientID
    }

    private func clearAuthIfCurrent(rejectedToken: String) {
        guard owner.token == rejectedToken, isCurrentAuthorization() else { return }
        SimklAuthStore.clearAuth(
            profileScope: profileScope, store: store, tokenStorage: tokenStorage
        )
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
        force: Bool = false,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> SimklAllItemsResponse? {
        guard let service = SimklAuthorizedClient(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ) else { return nil }
        return await libraryItems(using: service, force: force)
    }

    static func libraryItems(
        using service: SimklAuthorizedClient,
        force: Bool = false
    ) async -> SimklAllItemsResponse? {
        let store = service.store
        let sourceAtStart = TraktSettingsStore.librarySourceMode(in: store)
        guard let activities = try? await activities(using: service) else { return nil }
        guard service.isCurrentAuthorization(),
              TraktSettingsStore.librarySourceMode(in: store) == sourceAtStart else { return nil }

        let snapshot = SimklSyncCache.itemSnapshot(in: store)
        let cached = snapshot?.items
        let previousActivities = snapshot?.activities
        if !force, cached != nil, previousActivities?.all == activities.all {
            return cached
        }

        let shouldBootstrap = cached == nil || previousActivities == nil || activities.removalsChanged(comparedWith: previousActivities)
        var result = cached ?? SimklAllItemsResponse()

        if shouldBootstrap {
            result = SimklAllItemsResponse()
            for type in ["shows", "movies", "anime"] {
                guard service.isCurrentAuthorization(),
                      TraktSettingsStore.librarySourceMode(in: store) == sourceAtStart else { return nil }
                if let response = await service.getOptional(
                    SimklAllItemsResponse.self,
                    path: "sync/all-items/\(type)"
                ) {
                    result.merge(response)
                }
            }
        } else if let watermark = previousActivities?.all, !watermark.isEmpty {
            if let delta = await service.getOptional(
                SimklAllItemsResponse.self,
                path: "sync/all-items",
                query: [URLQueryItem(name: "date_from", value: watermark)]
            ) {
                result.merge(delta)
            }
        }

        guard service.isCurrentAuthorization(),
              TraktSettingsStore.librarySourceMode(in: store) == sourceAtStart else { return nil }
        SimklSyncCache.saveItems(result, activities: activities, store: store)
        return result
    }
}

// MARK: - Watched history

struct SimklHistoryRecord: Codable {
    let key: String
    let items: [WatchedStoreItem]
    let category: String?

    init(key: String, items: [WatchedStoreItem], category: String? = nil) {
        self.key = key
        self.items = items
        self.category = category
    }
}

struct SimklHistoryService {
    @MainActor
    static func syncWatchedHistory(
        store: UserDefaults = ProfileSettings.current,
        force: Bool = false,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        guard ProfileSettings.isActiveStore(store),
              TraktSettingsStore.watchProgressSource(in: store) == .simkl
                || TraktSettingsStore.librarySourceMode(in: store) == .simkl
                || RemoteTrackingState.isScrobbleEnabled(
                    for: .simkl,
                    in: store,
                    simklTokenStorage: tokenStorage,
                    profileScope: profileScope
                ) else { return false }
        let expectedProfileID = ProfileSettings.activeProfileID
        let expectedWatchedProfileID = WatchedStore.activeProfileId
        let accountID = SimklAuthStore.accountBindingID(in: store)
        let syncStartedAt = Date()
        guard let service = SimklAuthorizedClient(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ) else { return false }
        _ = await flushPendingLibraryMutations(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        )
        guard isCurrentWatchedHistoryContext(
                store: store,
                profileScope: profileScope,
                expectedProfileID: expectedProfileID,
                expectedWatchedProfileID: expectedWatchedProfileID,
                accountID: accountID,
                tokenStorage: tokenStorage
              ),
              let activities = try? await SimklSyncLoader.activities(using: service),
              isCurrentWatchedHistoryContext(
                store: store,
                profileScope: profileScope,
                expectedProfileID: expectedProfileID,
                expectedWatchedProfileID: expectedWatchedProfileID,
                accountID: accountID,
                tokenStorage: tokenStorage
              ) else { return false }
        guard service.isCurrentAuthorization() else { return false }

        let previousSnapshot = SimklSyncCache.historySnapshot(in: store)
        let previousRecords = previousSnapshot?.records ?? []
        let oldWatermark = previousSnapshot?.watermark
        let previousActivities = previousSnapshot?.activities
        if !force, !previousRecords.isEmpty, oldWatermark == activities.all {
            return true
        }

        // `date_from` never reports items the user deleted outright — only the
        // `removed_from_list` watermark moves. Without a full re-read here the
        // deleted title keeps its cached record forever and stays watched
        // locally. The library loader already does this; history needs it too.
        let hadRemovals = activities.removalsChanged(comparedWith: previousActivities)

        var records = previousRecords
        if previousRecords.isEmpty || oldWatermark == nil || hadRemovals {
            async let showsResponse = service.getOptional(
                SimklAllItemsResponse.self,
                path: "sync/all-items/shows",
                query: historyQuery(),
                noContentValue: SimklAllItemsResponse()
            )
            async let moviesResponse = service.getOptional(
                SimklAllItemsResponse.self,
                path: "sync/all-items/movies",
                query: historyQuery(),
                noContentValue: SimklAllItemsResponse()
            )
            async let animeResponse = service.getOptional(
                SimklAllItemsResponse.self,
                path: "sync/all-items/anime",
                query: historyQuery(),
                noContentValue: SimklAllItemsResponse()
            )
            let (shows, movies, anime) = await (showsResponse, moviesResponse, animeResponse)
            let fullSnapshotSucceeded = shows != nil && movies != nil && anime != nil
            guard shows != nil || movies != nil || anime != nil else { return false }
            if fullSnapshotSucceeded {
                // All three endpoints are authoritative, so they can replace
                // the old snapshot, including rows from older cache formats.
                records = []
            }
            if let shows {
                records = fullSnapshotSucceeded
                    ? mergeHistory(records, response: shows, onlyCategory: "shows")
                    : replacingHistoryCategory("shows", in: records, response: shows)
            }
            if let movies {
                records = fullSnapshotSucceeded
                    ? mergeHistory(records, response: movies, onlyCategory: "movies")
                    : replacingHistoryCategory("movies", in: records, response: movies)
            }
            if let anime {
                records = fullSnapshotSucceeded
                    ? mergeHistory(records, response: anime, onlyCategory: "anime")
                    : replacingHistoryCategory("anime", in: records, response: anime)
            }

            // A partial read may still contribute useful categories, but its
            // watermark must remain invalid so the missing category is retried
            // on the next sync instead of becoming a permanent omission.
            if !fullSnapshotSucceeded {
                guard service.isCurrentAuthorization(),
                      isCurrentWatchedHistoryContext(
                        store: store,
                        profileScope: profileScope,
                        expectedProfileID: expectedProfileID,
                        expectedWatchedProfileID: expectedWatchedProfileID,
                        accountID: accountID,
                        tokenStorage: tokenStorage
                      ) else { return false }
                let previousItems = previousRecords.flatMap(\.items)
                let remoteItems = records.flatMap(\.items)
                guard WatchedStore.reconcileSimklSnapshot(
                    remoteItems,
                    previousRemoteItems: previousItems,
                    syncStartedAt: syncStartedAt,
                    currentAccountID: accountID
                ) else { return false }
                SimklSyncCache.saveHistory(
                    records,
                    watermark: nil,
                    activities: previousActivities,
                    store: store
                )
                return true
            }
        } else {
            var query = historyQuery()
            query.append(URLQueryItem(name: "date_from", value: oldWatermark))
            if let delta = await service.getOptional(
                SimklAllItemsResponse.self,
                path: "sync/all-items",
                query: query
            ) {
                records = mergeHistory(records, response: delta)
            } else {
                return false
            }
        }

        guard service.isCurrentAuthorization(),
              isCurrentWatchedHistoryContext(
                store: store,
                profileScope: profileScope,
                expectedProfileID: expectedProfileID,
                expectedWatchedProfileID: expectedWatchedProfileID,
                accountID: accountID,
                tokenStorage: tokenStorage
              ) else { return false }
        let previousItems = previousRecords.flatMap(\.items)
        let remoteItems = records.flatMap(\.items)
        guard WatchedStore.reconcileSimklSnapshot(
            remoteItems,
            previousRemoteItems: previousItems,
            syncStartedAt: syncStartedAt,
            currentAccountID: accountID
        ) else { return false }
        SimklSyncCache.saveHistory(
            records,
            watermark: activities.all,
            activities: activities,
            store: store
        )
        return true
    }

    @MainActor
    static func flushPendingLibraryMutations(
        store: UserDefaults = ProfileSettings.current,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        let expectedProfileID = ProfileSettings.activeProfileID
        let profileId = WatchedStore.activeProfileId
        let accountID = SimklAuthStore.accountBindingID(in: store)
        guard ProfileSettings.isActiveStore(store),
              expectedProfileID == profileId,
              RemoteTrackingState.isProgressSourceAuthenticated(
                .simkl,
                in: store,
                simklTokenStorage: tokenStorage,
                profileScope: profileScope
              ),
              let service = SimklAuthorizedClient(
                store: store,
                client: client,
                tokenStorage: tokenStorage,
                profileScope: profileScope
              ) else { return false }

        let mutations = WatchedStore.pendingLibraryMutations(
            provider: .simkl,
            profileId: profileId,
            readyOnly: true
        )
            .filter { $0.accountID == accountID && $0.profileID == profileId }
        var allMutationsAcknowledged = true
        for mutation in mutations {
            guard isCurrentWatchedHistoryContext(
                store: store,
                profileScope: profileScope,
                expectedProfileID: expectedProfileID,
                expectedWatchedProfileID: profileId,
                accountID: accountID,
                tokenStorage: tokenStorage
            ) else { return false }
            let episodes = mutation.episodes.isEmpty
                ? mutation.episode.map { [$0] } ?? []
                : mutation.episodes
            guard let body = mutation.isWatched
                ? historyMutation(
                    meta: mutation.meta,
                    season: mutation.season,
                    episodes: episodes,
                    watchedAt: iso8601(mutation.changedAt)
                )
                : historyRemoval(
                    meta: mutation.meta,
                    season: mutation.season,
                    episodes: episodes,
                    store: store
                ) else { return false }
            do {
                let response = try await service.postReturningBody(
                    path: mutation.isWatched ? "sync/history" : "sync/history/remove",
                    body: body
                )
                guard (200..<300).contains(response.status) else {
                    _ = WatchedStore.deferLibraryMutation(
                        id: mutation.id,
                        provider: .simkl,
                        accountID: accountID,
                        profileId: profileId
                    )
                    return false
                }
                var unresolvedEpisodes: [Int]?
                if mutation.isWatched {
                    switch libraryMutationOutcome(in: response.data, mutation: mutation) {
                    case .accepted:
                        break
                    case .rejected, .unverifiable:
                        _ = WatchedStore.deferLibraryMutation(
                            id: mutation.id,
                            provider: .simkl,
                            accountID: accountID,
                            profileId: profileId
                        )
                        return false
                    case .partiallyAccepted(let unresolved):
                        unresolvedEpisodes = unresolved
                    }
                }
                guard service.isCurrentAuthorization(),
                      isCurrentWatchedHistoryContext(
                        store: store,
                        profileScope: profileScope,
                        expectedProfileID: expectedProfileID,
                        expectedWatchedProfileID: profileId,
                        accountID: accountID,
                        tokenStorage: tokenStorage
                      ),
                      (unresolvedEpisodes.map { unresolved in
                        WatchedStore.acknowledgeLibraryMutationPartial(
                            id: mutation.id,
                            provider: .simkl,
                            accountID: accountID,
                            profileId: profileId,
                            unresolvedEpisodes: unresolved
                        )
                      } ?? WatchedStore.acknowledgeLibraryMutation(
                        id: mutation.id,
                        provider: .simkl,
                        accountID: accountID,
                        profileId: profileId
                      )) else { return false }
                if unresolvedEpisodes != nil { allMutationsAcknowledged = false }
            } catch {
                _ = WatchedStore.deferLibraryMutation(
                    id: mutation.id,
                    provider: .simkl,
                    accountID: accountID,
                    profileId: profileId
                )
                return false
            }
        }
        return allMutationsAcknowledged
    }

    private enum LibraryMutationOutcome {
        case accepted
        case rejected
        case partiallyAccepted(unresolvedEpisodes: [Int])
        case unverifiable
    }

    /// `/sync/history` can return 201 even when the title or some episodes
    /// could not be resolved. A missing or malformed `not_found` report is
    /// ambiguous, so keep the outbox event durable instead of acknowledging it.
    private static func libraryMutationOutcome(
        in data: Data,
        mutation: WatchedLibraryMutationUpload
    ) -> LibraryMutationOutcome {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notFound = object["not_found"] as? [String: Any] else {
            return .unverifiable
        }

        func rows(_ key: String) -> [[String: Any]]? {
            guard let value = notFound[key] else { return [] }
            guard let values = value as? [Any] else { return nil }
            var rows: [[String: Any]] = []
            for value in values {
                guard let row = value as? [String: Any] else { return nil }
                rows.append(row)
            }
            return rows
        }

        guard let rejectedMovies = rows("movies"),
              let rejectedShows = rows("shows"),
              let rejectedEpisodes = rows("episodes") else {
            return .unverifiable
        }
        for (key, value) in notFound where !["movies", "shows", "episodes"].contains(key) {
            guard let rows = value as? [Any], rows.isEmpty else { return .unverifiable }
        }

        if !mutation.meta.isSeries {
            return rejectedMovies.isEmpty && rejectedShows.isEmpty && rejectedEpisodes.isEmpty
                ? .accepted : .rejected
        }
        if !rejectedMovies.isEmpty || !rejectedShows.isEmpty {
            return .rejected
        }
        guard !rejectedEpisodes.isEmpty else { return .accepted }

        let requestedEpisodes = mutation.episodes.isEmpty
            ? mutation.episode.map { [$0] } ?? []
            : mutation.episodes
        guard let season = mutation.season, !requestedEpisodes.isEmpty else { return .rejected }
        var unresolved = Set<Int>()
        for row in rejectedEpisodes {
            guard Self.responseInteger(row["season"]) == season,
                  let episode = Self.responseInteger(row["number"] ?? row["episode"]),
                  requestedEpisodes.contains(episode) else {
                return .unverifiable
            }
            unresolved.insert(episode)
        }
        guard !unresolved.isEmpty else { return .unverifiable }
        guard unresolved.count < Set(requestedEpisodes).count else { return .rejected }
        return .partiallyAccepted(unresolvedEpisodes: unresolved.sorted())
    }

    private static func responseInteger(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let string = value as? String { return Int(string) }
        return nil
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
        await setWatched(
            meta,
            season: season,
            episodes: episode.map { [$0] } ?? [],
            isWatched: isWatched,
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        )
    }

    /// Season-wide counterpart: one `sync/history` write for every episode
    /// listed, because Simkl serialises writes behind a 20-second per-user lock
    /// and a season sent one episode at a time would spend minutes in it.
    static func setWatched(
        _ meta: NuvioMeta,
        season: Int?,
        episodes: [Int],
        isWatched: Bool,
        store: UserDefaults = ProfileSettings.current,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        guard ProfileSettings.isActiveStore(store) else { return false }
        guard let service = SimklAuthorizedClient(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ) else { return false }

        let body: SimklHistoryMutation?
        if isWatched {
            body = historyMutation(
                meta: meta,
                season: season,
                episodes: episodes,
                watchedAt: iso8601(Date())
            )
        } else {
            body = historyRemoval(meta: meta, season: season, episodes: episodes, store: store)
        }
        guard let body else { return false }

        do {
            let status = try await service.post(
                path: isWatched ? "sync/history" : "sync/history/remove",
                body: body
            )
            guard (200..<300).contains(status), service.isCurrentAuthorization() else { return false }
            // A mark does not move Simkl's *playback* watermark, so the cached
            // paused list would keep serving this episode's old position for as
            // long as it stayed valid. Force the next fetch to re-read it.
            SimklSyncCache.invalidatePlaybacks(in: store)
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .simkl, in: store)
            return true
        } catch {
            return false
        }
    }

    private static func isCurrentWatchedHistoryContext(
        store: UserDefaults,
        profileScope: String?,
        expectedProfileID: String?,
        expectedWatchedProfileID: String?,
        accountID: String,
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage()
    ) -> Bool {
        ProfileSettings.isActiveStore(store)
            && ProfileSettings.activeProfileID == expectedProfileID
            && WatchedStore.activeProfileId == expectedWatchedProfileID
            && expectedProfileID == expectedWatchedProfileID
            && SimklAuthStore.accountBindingID(in: store) == accountID
            && SimklRuntimeSession.authenticatedState(
                store: store,
                tokenStorage: tokenStorage,
                profileScope: profileScope
            ) != nil
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
        response: SimklAllItemsResponse,
        onlyCategory: String? = nil
    ) -> [SimklHistoryRecord] {
        var records = existing
        let typedItems: [(String, String, SimklSyncItem)] =
            (response.movies ?? []).map { ("movies", "movie", $0) }
            + (response.shows ?? []).map { ("shows", "series", $0) }
            + (response.anime ?? []).map { ("anime", "series", $0) }

        for (category, type, item) in typedItems where onlyCategory == nil || onlyCategory == category {
            let key = "\(type):\(SimklAllItemsResponse.identity(item))"
            let record = SimklHistoryRecord(
                key: key,
                items: watchedItems(from: item, type: type),
                category: category
            )
            records.removeAll { $0.key == key }
            records.append(record)
        }
        return records
    }

    private static func replacingHistoryCategory(
        _ category: String,
        in records: [SimklHistoryRecord],
        response: SimklAllItemsResponse
    ) -> [SimklHistoryRecord] {
        let preserved = records.filter { record in
            if record.category == category { return false }
            // Legacy cache rows did not remember whether a series came from
            // Simkl's shows or anime endpoint. Keep those ambiguous rows when
            // only one endpoint succeeds; a complete three-category read can
            // safely replace them all.
            if record.category == nil, category == "movies", record.key.hasPrefix("movie:") {
                return false
            }
            return true
        }
        return mergeHistory(preserved, response: response, onlyCategory: category)
    }

    static func watchedItems(
        from item: SimklSyncItem,
        type: String
    ) -> [WatchedStoreItem] {
        guard let meta = placeholderMeta(item: item, type: type) else { return [] }
        if type == "movie" {
            guard item.status?.lowercased() == "completed"
                    || item.lastWatchedAt != nil else { return [] }
            // A movie marked watched in one action can come back completed with
            // no timestamp; fall back to when it entered the list rather than
            // stamping `.distantPast`, which sorts wrong and loses to any
            // tombstone it collides with.
            let watchedAt = parseDate(item.lastWatchedAt)
                ?? parseDate(item.addedToWatchlistAt)
                ?? .distantPast
            return [WatchedStoreItem(meta: meta, watchedAt: watchedAt)]
        }

        let fallbackWatchedAt = parseDate(item.lastWatchedAt)
            ?? parseDate(item.addedToWatchlistAt)
            ?? .distantPast

        return (item.seasons ?? []).flatMap { season -> [WatchedStoreItem] in
            guard let seasonNumber = season.number else { return [] }
            return (season.episodes ?? []).compactMap { episode in
                guard let episodeNumber = episode.resolvedNumber else { return nil }
                let watchedAt = episode.watchedAt.flatMap(parseDate) ?? fallbackWatchedAt
                return WatchedStoreItem(
                    meta: meta,
                    watchedAt: watchedAt,
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
                episodes: item.episode.map { [$0] } ?? [],
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

            let rejected: Int
            do {
                let response = try await service.postReturningBody(
                    path: "sync/history",
                    body: body
                )
                guard (200..<300).contains(response.status) else {
                    return result(
                        total: total,
                        transferred: transferred,
                        skipped: skipped,
                        validCount: entries.count
                    )
                }
                // Simkl answers 201 even when it matched nothing, listing what it
                // could not resolve under `not_found`. Counting the batch as
                // transferred on status alone is what made this report success
                // while the account stayed empty.
                rejected = Self.notFoundCount(in: response.data, batch: batch)
            } catch {
                return result(
                    total: total,
                    transferred: transferred,
                    skipped: skipped,
                    validCount: entries.count
                )
            }

            transferred += max(batch.count - rejected, 0)
            let percentage = min(
                100,
                max(1, Int((Double(transferred) / Double(total) * 100).rounded(.down)))
            )
            await progress(percentage)
        }

        if transferred == total {
            await progress(100)
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
        }
        return result(
            total: total,
            transferred: transferred,
            skipped: skipped,
            validCount: entries.count
        )
    }

    /// Source entries in this batch that Simkl said it could not resolve.
    ///
    /// `/sync/history` reports rejects in three arrays — `movies`, `shows`,
    /// `episodes` — and a show that resolves fine can still have unmatched
    /// episodes, so the show never appears in `not_found.shows`. Reading only
    /// the first two counts those episodes as transferred. Each rejected movie
    /// or episode is one source entry; a rejected *show* takes down every entry
    /// this batch grouped under it, so those are counted back by identity.
    private static func notFoundCount(in data: Data, batch: [SimklHistoryMutation]) -> Int {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let notFound = object["not_found"] as? [String: Any] else {
            return 0
        }

        func rows(_ key: String) -> [[String: Any]] {
            (notFound[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }

        var entriesPerShow: [String: Int] = [:]
        for show in batch.flatMap({ $0.shows ?? [] }) {
            guard let key = transferKey(show) else { continue }
            entriesPerShow[key, default: 0] += 1
        }

        let rejectedShows = rows("shows").reduce(0) { partial, row in
            guard let key = responseTransferKey(row) else { return partial + 1 }
            return partial + (entriesPerShow[key] ?? 1)
        }

        return rows("movies").count + rows("episodes").count + rejectedShows
    }

    /// `not_found` rows are verbatim echoes of what was sent, so the same
    /// identity rule that grouped the batch re-identifies them.
    private static func responseTransferKey(_ row: [String: Any]) -> String? {
        let ids = row["ids"] as? [String: Any]
        if let imdb = ids?["imdb"] as? String, !imdb.isEmpty {
            return "imdb:\(imdb.lowercased())"
        }
        if let tmdb = intValue(ids?["tmdb"]) { return "tmdb:\(tmdb)" }
        if let simkl = intValue(ids?["simkl"]) { return "simkl:\(simkl)" }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func combinedMutation(
        _ mutations: [SimklHistoryMutation]
    ) -> SimklHistoryMutation {
        let movies = mutations.flatMap { $0.movies ?? [] }
        var groupedShows: [String: SimklWriteMedia] = [:]
        var ungroupedShows: [SimklWriteMedia] = []
        for show in mutations.flatMap({ $0.shows ?? [] }) {
            guard let key = transferKey(show) else {
                ungroupedShows.append(show)
                continue
            }
            if let existing = groupedShows[key] {
                groupedShows[key] = merge(existing, show)
            } else {
                groupedShows[key] = show
            }
        }
        let shows = Array(groupedShows.values) + ungroupedShows
        return SimklHistoryMutation(
            movies: movies.isEmpty ? nil : movies,
            shows: shows.isEmpty ? nil : shows
        )
    }

    private static func transferKey(_ media: SimklWriteMedia) -> String? {
        if let imdb = media.ids.imdb, !imdb.isEmpty { return "imdb:\(imdb.lowercased())" }
        if let tmdb = media.ids.tmdb { return "tmdb:\(tmdb)" }
        if let simkl = media.ids.simkl { return "simkl:\(simkl)" }
        return nil
    }

    private static func merge(
        _ lhs: SimklWriteMedia,
        _ rhs: SimklWriteMedia
    ) -> SimklWriteMedia {
        var seasons: [Int: [Int: SimklWriteEpisode]] = [:]
        for season in (lhs.seasons ?? []) + (rhs.seasons ?? []) {
            var episodes = seasons[season.number] ?? [:]
            for episode in season.episodes ?? [] {
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
        guard ProfileSettings.isActiveStore(store),
              TraktSettingsStore.librarySourceMode(in: store) == .simkl,
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
            guard (200..<300).contains(status), service.isCurrentAuthorization(),
                  TraktSettingsStore.librarySourceMode(in: store) == .simkl else { return false }
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
        force: Bool = false,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil,
        onSnapshot: LibraryMetadataHydrator.SnapshotHandler? = nil
    ) async -> [LibraryStoreItem]? {
        let resolvedProfile = profileScope ?? SimklRuntimeSession.profileScope()
        guard TraktSettingsStore.librarySourceMode(in: store) == .simkl,
              let owner = SimklAuthorizedClient(
                  store: store, client: client,
                  tokenStorage: tokenStorage, profileScope: resolvedProfile
              ),
              let response = await SimklSyncLoader.libraryItems(
                  using: owner,
                  force: force
              ) else {
            return []
        }
        guard owner.isCurrentAuthorization(),
              TraktSettingsStore.librarySourceMode(in: store) == .simkl else { return nil }

        let seeds: [(String, SimklSyncItem)] =
            (response.movies ?? []).filter(isLibraryItem).map { ("movie", $0) }
            + (response.shows ?? []).filter(isLibraryItem).map { ("series", $0) }
            + (response.anime ?? []).filter(isLibraryItem).map { ("series", $0) }

        var results: [LibraryStoreItem] = []
        var seen = Set<String>()
        for (type, item) in seeds {
            guard owner.isCurrentAuthorization(),
              TraktSettingsStore.librarySourceMode(in: store) == .simkl else { return [] }
            guard !Task.isCancelled,
                  let placeholder = placeholderMeta(item: item, type: type),
                  seen.insert("\(type):\(placeholder.id)").inserted else { continue }
            let meta = repository.cachedMetadata(for: placeholder.id)
                .map { LibraryMetadataHydrator.merging($0, into: placeholder) }
                ?? placeholder
            results.append(
                LibraryStoreItem(
                    meta: meta,
                    addedAt: parseDate(item.addedToWatchlistAt) ?? .distantPast
                )
            )
        }
        let sortedResults = results.enumerated().sorted {
            if $0.element.addedAt == $1.element.addedAt { return $0.offset < $1.offset }
            return $0.element.addedAt > $1.element.addedAt
        }.map(\.element)
        return await LibraryMetadataHydrator.hydrate(
            seeds: sortedResults,
            repository: repository,
            onSnapshot: onSnapshot,
            isCurrent: {
                !Task.isCancelled && owner.isCurrentAuthorization()
                    && TraktSettingsStore.librarySourceMode(in: store) == .simkl
            }
        )
    }

    private static func isLibraryItem(_ item: SimklSyncItem) -> Bool {
        item.status?.lowercased() == "plantowatch"
    }

    static func fetchPlanToWatchItems(
        type: String,
        repository: CatalogRepository,
        store: UserDefaults = ProfileSettings.current,
        force: Bool = false
    ) async -> [NuvioMeta] {
        guard SimklRuntimeSession.authenticatedState(store: store) != nil,
              let response = await SimklSyncLoader.libraryItems(store: store, force: force) else {
            return []
        }

        let isMovie = type == "movie"
        let items: [SimklSyncItem]
        if isMovie {
            items = (response.movies ?? []).filter(isLibraryItem)
        } else {
            items = (response.shows ?? []).filter(isLibraryItem)
                + (response.anime ?? []).filter(isLibraryItem)
        }

        let sortedItems = items.sorted {
            (parseDate($0.addedToWatchlistAt) ?? .distantPast) > (parseDate($1.addedToWatchlistAt) ?? .distantPast)
        }

        var seeds: [(item: SimklSyncItem, placeholder: NuvioMeta, index: Int)] = []
        seeds.reserveCapacity(sortedItems.count)
        var seen = Set<String>()
        for (index, item) in sortedItems.enumerated() {
            guard let placeholder = placeholderMeta(item: item, type: type),
                  seen.insert("\(type):\(placeholder.id)").inserted else { continue }
            seeds.append((item: item, placeholder: placeholder, index: index))
        }

        let metadataConcurrency = 8
        return await withTaskGroup(of: (Int, NuvioMeta?).self) { group in
            var results: [Int: NuvioMeta] = [:]
            results.reserveCapacity(seeds.count)
            var iterator = seeds.makeIterator()
            var inFlight = 0

            func addNext() {
                guard let entry = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    let meta = (try? await repository.getMetadata(
                        id: entry.placeholder.id,
                        type: type
                    )) ?? entry.placeholder
                    return (entry.index, meta)
                }
            }

            for _ in 0..<min(metadataConcurrency, seeds.count) { addNext() }
            while inFlight > 0 {
                guard let (index, meta) = await group.next() else { break }
                inFlight -= 1
                if let meta { results[index] = meta }
                addNext()
            }

            return seeds.compactMap { results[$0.index] }
        }
    }
}

/// Publishes the lightweight library snapshot first, then fills its metadata
/// with a small number of concurrent lookups. The item ID and watchlist date
/// always come from the provider seed so SwiftUI keeps stable card identity.
enum LibraryMetadataHydrator {
    typealias SnapshotHandler = @MainActor ([LibraryStoreItem]) -> Bool

    private static let maximumConcurrency = 4

    static func hydrate(
        seeds: [LibraryStoreItem],
        repository: CatalogRepository,
        onSnapshot: SnapshotHandler? = nil,
        isCurrent: @MainActor () -> Bool
    ) async -> [LibraryStoreItem]? {
        guard await isCurrent() else { return nil }
        var results = seeds
        if let onSnapshot, !(await onSnapshot(results)) { return nil }
        guard !Task.isCancelled else { return nil }

        return await withTaskGroup(of: (Int, NuvioMeta?).self) { group in
            var nextIndex = 0
            var inFlight = 0

            func addNext() {
                guard nextIndex < seeds.count else { return }
                let index = nextIndex
                let seed = seeds[index]
                nextIndex += 1
                inFlight += 1
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    return (index, try? await repository.getMetadata(
                        id: seed.meta.id,
                        type: seed.meta.type
                    ))
                }
            }

            for _ in 0..<min(Self.maximumConcurrency, seeds.count) { addNext() }
            while inFlight > 0 {
                guard let (index, metadata) = await group.next() else { break }
                inFlight -= 1
                guard await isCurrent(), !Task.isCancelled else {
                    group.cancelAll()
                    return nil
                }
                if let metadata {
                    let seed = results[index]
                    results[index] = LibraryStoreItem(
                        meta: Self.merging(metadata, into: seed.meta),
                        addedAt: seed.addedAt
                    )
                    if let onSnapshot, !(await onSnapshot(results)) {
                        group.cancelAll()
                        return nil
                    }
                }
                guard await isCurrent(), !Task.isCancelled else {
                    group.cancelAll()
                    return nil
                }
                addNext()
            }
            guard await isCurrent(), !Task.isCancelled else { return nil }
            return results
        }
    }

    static func merging(_ metadata: NuvioMeta, into seed: NuvioMeta) -> NuvioMeta {
        func nonEmpty(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }

        return NuvioMeta(
            id: seed.id,
            name: nonEmpty(metadata.name) ?? seed.name,
            description: nonEmpty(metadata.description) ?? seed.description,
            posterUrl: nonEmpty(metadata.posterUrl) ?? seed.posterUrl,
            backgroundUrl: nonEmpty(metadata.backgroundUrl) ?? seed.backgroundUrl,
            logoUrl: nonEmpty(metadata.logoUrl) ?? seed.logoUrl,
            imdbId: metadata.imdbId ?? seed.imdbId,
            tmdbId: metadata.tmdbId ?? seed.tmdbId,
            type: seed.type,
            year: metadata.year ?? seed.year,
            genres: metadata.genres ?? seed.genres,
            rating: metadata.rating ?? seed.rating,
            releaseInfo: nonEmpty(metadata.releaseInfo) ?? seed.releaseInfo,
            runtime: nonEmpty(metadata.runtime) ?? seed.runtime,
            cast: metadata.cast ?? seed.cast,
            director: metadata.director ?? seed.director,
            writer: metadata.writer ?? seed.writer,
            certification: metadata.certification ?? seed.certification,
            country: metadata.country ?? seed.country,
            language: metadata.language ?? seed.language,
            released: metadata.released ?? seed.released,
            status: metadata.status ?? seed.status,
            videos: metadata.videos ?? seed.videos,
            trailerYtIds: metadata.trailerYtIds ?? seed.trailerYtIds,
            externalRatings: metadata.externalRatings ?? seed.externalRatings,
            posterShape: metadata.posterShape ?? seed.posterShape,
            isFromAddon: metadata.isFromAddon ?? seed.isFromAddon,
            landscapePosterUrl: nonEmpty(metadata.landscapePosterUrl) ?? seed.landscapePosterUrl
        )
    }
}

enum SimklSettingsStore {
    static func isPlanToWatchHomeCatalogsEnabled(in store: UserDefaults = ProfileSettings.current) -> Bool {
        store.bool(forKey: SettingsKey.simklPlanToWatchHomeCatalogs)
    }

    static var isPlanToWatchHomeCatalogsEnabled: Bool {
        isPlanToWatchHomeCatalogsEnabled(in: ProfileSettings.current)
    }

    static func setPlanToWatchHomeCatalogsEnabled(_ enabled: Bool, store: UserDefaults = ProfileSettings.current) {
        store.set(enabled, forKey: SettingsKey.simklPlanToWatchHomeCatalogs)
        NotificationCenter.default.post(name: TVHomeCatalogOrder.changedNotification, object: nil)
        NotificationCenter.default.post(name: TVHomeCatalogOrder.snapshotChangedNotification, object: nil)
    }
}

enum SelectedLibraryService {
    static var isSelectedAndAuthenticated: Bool {
        switch TraktSettingsStore.librarySourceMode {
        case .local:
            return false
        case .trakt:
            return TraktAuthStore.isAuthenticated
        case .simkl:
            return SimklRuntimeSession.authenticatedState() != nil
        case .mdblist:
            return MdbListRuntimeSession.isAuthenticated()
        case .wetrakr:
            return WeTrakrRuntimeSession.isAuthenticated()
        }
    }

    @MainActor
    static func setWatchlist(_ meta: NuvioMeta, isInWatchlist: Bool) async -> Bool {
        switch TraktSettingsStore.librarySourceMode {
        case .local:
            return false
        case .trakt:
            return await TraktLibraryService.setWatchlist(meta, isInWatchlist: isInWatchlist)
        case .simkl:
            return await SimklLibraryService.setWatchlist(meta, isInWatchlist: isInWatchlist)
        case .mdblist:
            return await MdbListLibraryService.setWatchlist(meta, isInWatchlist: isInWatchlist)
        case .wetrakr:
            return await WeTrakrLibraryService.setWatchlist(meta, isInWatchlist: isInWatchlist)
        }
    }

    static func fetchLibrary(
        repository: CatalogRepository,
        onSnapshot: LibraryMetadataHydrator.SnapshotHandler? = nil
    ) async -> [LibraryStoreItem]? {
        switch TraktSettingsStore.librarySourceMode {
        case .local:
            return []
        case .trakt:
            return await TraktLibraryService.fetchLibrary(
                repository: repository,
                onSnapshot: onSnapshot
            )
        case .simkl:
            return await SimklLibraryService.fetchLibrary(
                repository: repository,
                onSnapshot: onSnapshot
            )
        case .mdblist:
            return await MdbListLibraryService.fetchLibrary(repository: repository)
        case .wetrakr:
            return await WeTrakrLibraryService.fetchLibrary(repository: repository)
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
    /// Simkl's documented write ceiling is 1 POST/sec per access token; a
    /// little headroom keeps a slow-clock device from crowding the boundary.
    private static let writeIntervalNanoseconds: UInt64 = 1_200_000_000

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
        var isFirstWrite = true

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

            // `/scrobble/*` takes one item per request — there is no batch form
            // — and Simkl caps writes at 1 POST/sec per access token, with
            // overage answered by a throttling block on the token or client_id
            // rather than a retryable 429. Pace the loop instead of racing it.
            if !isFirstWrite {
                try? await Task.sleep(nanoseconds: writeIntervalNanoseconds)
                guard !Task.isCancelled else {
                    return SimklProgressTransferResult(
                        total: total,
                        transferred: transferred,
                        skipped: skipped,
                        failed: total - transferred - skipped
                    )
                }
            }
            isFirstWrite = false

            let body = scrobbleRequest(
                meta: item.meta,
                media: media,
                progress: percentage,
                season: item.season,
                episode: item.episode
            )

            do {
                var response = try await service.postReturningBody(
                    path: "scrobble/pause",
                    body: body
                )
                if isLockCollision(status: response.status, data: response.data) {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    guard !Task.isCancelled else {
                        return SimklProgressTransferResult(
                            total: total,
                            transferred: transferred,
                            skipped: skipped,
                            failed: total - transferred - skipped
                        )
                    }
                    response = try await service.postReturningBody(
                        path: "scrobble/pause",
                        body: body
                    )
                }
                guard !Task.isCancelled else {
                    return SimklProgressTransferResult(
                        total: total,
                        transferred: transferred,
                        skipped: skipped,
                        failed: total - transferred - skipped
                    )
                }
                if (200..<300).contains(response.status) {
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
        await MainActor.run {
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
        }
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
    /// Outcome of the most recent scrobble attempt, for the Settings diagnostics
    /// row. Every failure path here returns `false` to a caller that ignores it,
    /// so without this a rejected scrobble is indistinguishable from a sent one.
    static private(set) var scrobbleDiagnostic = "not attempted"

    /// Bounded metadata fetch concurrency. Matches the Continue Watching
    /// builder's limit so a large paused list fans out without flooding the
    /// upstream metadata hosts with one request per title at once.
    private static let metadataConcurrency = 6

    static func fetchContinueWatching(
        repository: CatalogRepository,
        store: UserDefaults = ProfileSettings.current,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> [ContinueWatchingItem]? {
        guard let service = SimklAuthorizedClient(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ),
              let activities = try? await SimklSyncLoader.activities(using: service) else {
            return nil
        }

        let watermark = activities.playbackWatermark
        let playbacks: [SimklPlaybackDTO]
        let playbackSnapshot = SimklSyncCache.playbackSnapshot(in: store)
        if !watermark.isEmpty,
           let playbackSnapshot,
           playbackSnapshot.watermark == watermark {
            playbacks = playbackSnapshot.playbacks
        } else {
            let fetched = await service.getOptional(
                [SimklPlaybackDTO].self,
                path: "sync/playback"
            )
            playbacks = fetched ?? []
            SimklSyncCache.savePlaybacks(playbacks, watermark: watermark, store: store)
        }

        // Simkl has no separate "next up" playback feed. Build the same
        // display-only suggestions Nuvio Sync builds from the provider's
        // watched episode history. Refresh that history before reading the
        // cache so a first Home load is not one refresh behind.
        let historySnapshot = SimklSyncCache.historySnapshot(in: store)
        if historySnapshot?.watermark != activities.all
            || (historySnapshot?.records.isEmpty ?? true) {
            _ = await SimklHistoryService.syncWatchedHistory(
                store: store,
                client: client,
                tokenStorage: tokenStorage,
                profileScope: profileScope
            )
        }
        let watchedItems = SimklSyncCache.history(in: store).flatMap(\.items)
        let upNextSeeds = nextUpSeeds(
            from: watchedItems,
            preferFurthestEpisode: UpNextEpisodeSelectionPolicy.prefersFurthestEpisode
        )

        // Simkl keeps a paused row until its own rules retire it (an 80%
        // `scrobble/stop`), and marking an episode watched writes history
        // without touching it. Judged here against the local marks, newest
        // wins — the same rule `ContinueWatchingStore.removeWatched` applies to
        // local rows, so a re-watch started after the mark still comes back.
        // Read once: `visibleItems()` decodes the watched file on every call.
        let watchedDates = WatchedStore.newestWatchedDatesByIdentity(WatchedStore.visibleItems())
        let playbackMetas = playbacks.compactMap { playback -> NuvioMeta? in
            guard let progress = playback.progress,
                  progress > 0,
                  progress < 90,
                  let seed = progressSeed(playback),
                  let meta = placeholderMeta(item: seed.item, type: seed.type),
                  !isRetiredByWatchedMark(
                      playback,
                      meta: meta,
                      type: seed.type,
                      watchedDates: watchedDates
                  ) else { return nil }
            return meta
        }

        let sortedPlaybacks = playbacks.sorted(by: {
            (parseDate($0.pausedAt) ?? .distantPast) > (parseDate($1.pausedAt) ?? .distantPast)
        })

        // Resolve metadata in parallel: a large paused list used to fetch one
        // title at a time, which turned many paused rows into the same number
        // of sequential network round-trips before the row could appear. The
        // index keeps the pausedAt ordering stable no matter which request
        // finishes first.
        struct PlaybackPlan {
            let index: Int
            let progress: Double
            let seed: (item: SimklSyncItem, type: String)
            let placeholder: NuvioMeta
            let pausedAt: Date?
            let season: Int?
            let episode: Int?
            let episodeTitle: String?
        }
        var plan: [PlaybackPlan] = []
        plan.reserveCapacity(sortedPlaybacks.count)
        for (index, playback) in sortedPlaybacks.enumerated() where !Task.isCancelled {
            // Cut at the same percentage the rest of the app calls "finished".
            // Simkl's own resumable window is wider (it only auto-completes at
            // 80% on `/scrobble/stop`), but admitting 90-100% here surfaces rows
            // every other screen already treats as watched.
            guard !Task.isCancelled,
                  let progress = playback.progress,
                  progress > 0, progress < 90,
                  let seed = progressSeed(playback),
                  let placeholder = placeholderMeta(item: seed.item, type: seed.type) else { continue }
            // Checked before metadata resolution so a retired row costs nothing.
            guard !isRetiredByWatchedMark(
                playback,
                meta: placeholder,
                type: seed.type,
                watchedDates: watchedDates
            ) else { continue }
            plan.append(
                PlaybackPlan(
                    index: index,
                    progress: progress,
                    seed: seed,
                    placeholder: placeholder,
                    pausedAt: parseDate(playback.pausedAt),
                    season: playback.episode?.season,
                    episode: playback.episode?.resolvedNumber,
                    episodeTitle: playback.episode?.title
                )
            )
        }

        let rows = await withTaskGroup(of: (Int, ContinueWatchingItem?).self) { group in
            var results: [Int: ContinueWatchingItem] = [:]
            results.reserveCapacity(plan.count)
            var iterator = plan.makeIterator()
            var inFlight = 0

            func addNext() {
                guard let entry = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    let meta = (try? await repository.getMetadata(
                        id: entry.placeholder.id,
                        type: entry.seed.type
                    )) ?? entry.placeholder
                    let duration = runtimeSeconds(for: meta)
                    let position = max(1.0, min(duration * entry.progress / 100, max(duration - 5, 1.0)))
                    let item = ContinueWatchingItem(
                        meta: meta,
                        streamUrl: "",
                        position: position,
                        duration: duration,
                        lastWatchedAt: entry.pausedAt ?? .distantPast,
                        season: entry.season,
                        episode: entry.episode,
                        released: nil,
                        episodeTitleOverride: entry.episodeTitle,
                        episodeOverviewOverride: nil,
                        episodeThumbnailOverride: nil,
                        isUpNext: false
                    )
                    return (entry.index, item)
                }
            }

            for _ in 0..<min(metadataConcurrency, plan.count) { addNext() }
            while inFlight > 0 {
                guard let (index, item) = await group.next() else { break }
                inFlight -= 1
                if let item { results[index] = item }
                addNext()
            }
            return results.sorted { $0.key < $1.key }.map(\.value)
        }

        var results = rows
        if results.count > 20 { results = Array(results.prefix(20)) }

        // A real paused row wins over a generated suggestion for the same
        // title. This also keeps the one-card-per-title rule in Home from
        // hiding a resume row behind its Up Next counterpart.
        if results.count < 20 {
            let needed = 20 - results.count
            let candidateSeeds = upNextSeeds.filter { seed in
                !playbackMetas.contains(where: {
                    WatchedStore.sameContent($0, seed.meta)
                })
            }
            let seedsToInspect = Array(candidateSeeds.prefix(min(needed * 2, 24)))

            let upNextRows = await withTaskGroup(of: (Int, ContinueWatchingItem?).self) { group in
                var taskResults: [Int: ContinueWatchingItem] = [:]
                var iterator = seedsToInspect.enumerated().makeIterator()
                var inFlight = 0

                func addNext() {
                    guard let (index, seed) = iterator.next() else { return }
                    inFlight += 1
                    group.addTask {
                        guard !Task.isCancelled else { return (index, nil) }
                        let item = await makeUpNextItem(from: seed, repository: repository)
                        return (index, item)
                    }
                }

                for _ in 0..<min(metadataConcurrency, seedsToInspect.count) { addNext() }
                while inFlight > 0 {
                    guard let (index, item) = await group.next() else { break }
                    inFlight -= 1
                    if let item { taskResults[index] = item }
                    addNext()
                }
                return taskResults.sorted { $0.key < $1.key }.compactMap(\.value)
            }

            for item in upNextRows {
                guard results.count < 20 else { break }
                results.append(item)
            }
        }
        return results
    }

    private struct UpNextSeed {
        let meta: NuvioMeta
        let season: Int
        let episode: Int
        let watchedAt: Date
    }

    /// Selects one completed episode per series using the same preference as
    /// Nuvio Sync and Trakt. The following episode is resolved from the fresh
    /// catalog guide below, so skipped episodes and season rollovers behave
    /// consistently across all three progress sources.
    private static func nextUpSeeds(
        from items: [WatchedStoreItem],
        preferFurthestEpisode: Bool
    ) -> [UpNextSeed] {
        var selectedByContentID: [String: UpNextSeed] = [:]

        for item in items {
            guard item.meta.isSeries,
                  let season = item.season,
                  let episode = item.episode,
                  season > 0,
                  episode > 0 else { continue }

            let key = item.meta.type.lowercased() + ":" + item.meta.id.lowercased()
            let candidate = UpNextSeed(
                meta: item.meta,
                season: season,
                episode: episode,
                watchedAt: item.watchedAt
            )
            let matchingKey = selectedByContentID.first {
                WatchedStore.sameContent($0.value.meta, item.meta)
            }?.key ?? key
            guard let current = selectedByContentID[matchingKey] else {
                selectedByContentID[key] = candidate
                continue
            }
            if UpNextEpisodeSelectionPolicy.prefers(
                candidateSeason: season,
                candidateEpisode: episode,
                candidateWatchedAt: item.watchedAt,
                over: current.season,
                currentEpisode: current.episode,
                currentWatchedAt: current.watchedAt,
                preferFurthestEpisode: preferFurthestEpisode
            ) {
                selectedByContentID[matchingKey] = candidate
            }
        }

        return selectedByContentID.values.sorted { $0.watchedAt > $1.watchedAt }
    }

    private static func makeUpNextItem(
        from seed: UpNextSeed,
        repository: CatalogRepository
    ) async -> ContinueWatchingItem? {
        var meta = (try? await repository.getMetadata(
            id: seed.meta.id,
            type: "series"
        )) ?? seed.meta

        var next = nextEpisode(
            after: (season: seed.season, episode: seed.episode),
            in: meta
        )
        if next == nil, let refreshed = try? await repository.refreshMetadata(
            id: seed.meta.id,
            type: "series"
        ) {
            meta = refreshed
            next = nextEpisode(
                after: (season: seed.season, episode: seed.episode),
                in: meta
            )
        }
        guard let next, EpisodeReleasePolicy.shouldSurfaceNextEpisode(
            watchedSeason: seed.season,
            candidateSeason: next.season,
            released: next.released
        ) else {
            return nil
        }

        let enriched = await EpisodeMetadataEnrichment.fetch(
            meta: meta,
            season: next.season,
            episode: next.episode
        )
        let duration = max(runtimeSeconds(for: meta), 120)
        return ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: 1,
            duration: duration,
            lastWatchedAt: seed.watchedAt,
            season: next.season,
            episode: next.episode,
            released: enriched?.released ?? next.released,
            episodeTitleOverride: enriched?.title ?? next.title,
            episodeOverviewOverride: enriched?.overview ?? next.overview,
            episodeThumbnailOverride: enriched?.thumbnail ?? next.thumbnail,
            isUpNext: true,
            upNextSeedSeason: seed.season
        )
    }

    private static func nextEpisode(
        after current: (season: Int, episode: Int),
        in meta: NuvioMeta
    ) -> NuvioVideo? {
        let episodes = (meta.videos ?? [])
            .filter { $0.season > 0 }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        guard let index = episodes.firstIndex(where: {
            $0.season == current.season && $0.episode == current.episode
        }) else { return nil }
        let nextIndex = episodes.index(after: index)
        return episodes.indices.contains(nextIndex) ? episodes[nextIndex] : nil
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
        guard ProfileSettings.isActiveStore(store) else {
            scrobbleDiagnostic = "skipped: inactive profile store"
            return false
        }
        guard TraktSettingsStore.watchProgressSource(in: store) == .simkl
            || RemoteTrackingState.isScrobbleEnabled(
                for: .simkl,
                in: store,
                simklTokenStorage: tokenStorage,
                profileScope: profileScope
            ) else {
            scrobbleDiagnostic = "skipped: Simkl scrobble is not enabled or authenticated"
            return false
        }
        guard let service = SimklAuthorizedClient(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ) else {
            scrobbleDiagnostic = "skipped: no Simkl access token"
            return false
        }
        guard duration > 0, position.isFinite, duration.isFinite else {
            scrobbleDiagnostic = "skipped: no usable playback timeline"
            return false
        }
        guard let media = scrobbleMedia(meta) else {
            // Simkl matches on simkl/imdb/tmdb ids. Content carrying only an id
            // space Simkl does not accept (kitsu, for example) cannot be
            // scrobbled at all, so say so rather than failing mutely.
            scrobbleDiagnostic = "skipped: \(meta.id) has no Simkl-usable id (needs simkl, imdb, or tmdb)"
            return false
        }
        if meta.isSeries {
            guard let season, season >= 0, let episode, episode > 0 else {
                scrobbleDiagnostic = "skipped: \(meta.id) is a series with no season/episode"
                return false
            }
        }

        // Simkl accepts at most two decimal places on `progress`; an unrounded
        // Double serialises with full precision and risks a 400.
        let rawProgress = min(max(position / duration * 100, 0), 100)
        let progress = (rawProgress * 100).rounded() / 100
        let body = scrobbleRequest(
            meta: meta,
            media: media,
            progress: progress,
            season: season,
            episode: episode
        )
        do {
            let path = "scrobble/\(action.rawValue)"
            var response = try await service.postReturningBody(path: path, body: body)
            // A collision with Simkl's 20-second per-user scrobble lock comes
            // back as 400 `rate_limit`, not 429 — the documented handling is to
            // wait a moment and retry once. Without this a play/pause in quick
            // succession drops the second event on the floor.
            if isLockCollision(status: response.status, data: response.data) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, ProfileSettings.isActiveStore(store),
                  (TraktSettingsStore.watchProgressSource(in: store) == .simkl
                    || RemoteTrackingState.isScrobbleEnabled(for: .simkl, in: store, simklTokenStorage: tokenStorage, profileScope: profileScope)) else { return false }
                response = try await service.postReturningBody(path: path, body: body)
            }
            guard !Task.isCancelled, ProfileSettings.isActiveStore(store),
                  (TraktSettingsStore.watchProgressSource(in: store) == .simkl
                    || RemoteTrackingState.isScrobbleEnabled(for: .simkl, in: store, simklTokenStorage: tokenStorage, profileScope: profileScope)) else { return false }
            let status = response.status
            // Simkl documents 409 stop as idempotent success for a recently
            // completed session.
            guard (200..<300).contains(status) || (action == .stop && status == 409) else {
                scrobbleDiagnostic = "\(action.rawValue) \(meta.id) failed: HTTP \(status)"
                print("Simkl scrobble \(action.rawValue) failed for \(meta.id): HTTP \(status)")
                return false
            }
            scrobbleDiagnostic = "\(action.rawValue) \(meta.id) ok (\(String(format: "%.2f", progress))%)"
            // The account now holds progress the cached playback list predates.
            SimklSyncCache.invalidatePlaybacks(in: store)
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .simkl, in: store)
            return true
        } catch {
            scrobbleDiagnostic = "\(action.rawValue) \(meta.id) failed: \(error.localizedDescription)"
            print("Simkl scrobble \(action.rawValue) failed for \(meta.id): \(error.localizedDescription)")
            return false
        }
    }

    /// Deletes the account-side paused row behind a Continue Watching card.
    ///
    /// Removing a card only writes a local dismiss record, which hides it on
    /// this device alone — the row belongs to the Simkl account, so every other
    /// client keeps showing it. `DELETE /sync/playback/{id}` retires it for
    /// real; the id comes from the same playback list the card was built from.
    ///
    /// Scoped to the episode the card was showing, matching the dismiss record:
    /// a different paused episode of the same show is its own card and is not
    /// what the user removed.
    @discardableResult
    static func removePlayback(
        for item: ContinueWatchingItem,
        store: UserDefaults = ProfileSettings.current,
        client: SimklAPIClient = SimklAPIClient(),
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        let ownerScope = profileScope ?? ProfileSettings.activeProfileScope
        guard !Task.isCancelled, ProfileSettings.isActiveStore(store),
              (TraktSettingsStore.watchProgressSource(in: store) == .simkl
                || RemoteTrackingState.isScrobbleEnabled(for: .simkl, in: store, simklTokenStorage: tokenStorage, profileScope: ownerScope)) else { return false }
        guard ownerScope == ProfileSettings.activeProfileScope else { return false }
        guard let service = SimklAuthorizedClient(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: ownerScope
        ) else { return false }

        // The cache is what the removed card was rendered from, so it names the
        // right row without another round trip. Re-read only when it is gone.
        let playbacks: [SimklPlaybackDTO]
        if let cached = SimklSyncCache.playbacks(in: store), !cached.isEmpty {
            playbacks = cached
        } else if let fetched = try? await service.get(
            [SimklPlaybackDTO].self,
            path: "sync/playback"
        ) {
            playbacks = fetched
        } else {
            return false
        }

        guard !Task.isCancelled, ProfileSettings.isActiveStore(store),
              ownerScope == ProfileSettings.activeProfileScope,
              (TraktSettingsStore.watchProgressSource(in: store) == .simkl
                || RemoteTrackingState.isScrobbleEnabled(for: .simkl, in: store, simklTokenStorage: tokenStorage, profileScope: ownerScope)) else { return false }

        let targets = playbacks.filter { playbackMatches($0, card: item) }
        guard !targets.isEmpty else { return false }

        var removedAny = false
        for id in targets.compactMap(\.id) {
            guard !Task.isCancelled, ProfileSettings.isActiveStore(store),
                  ownerScope == ProfileSettings.activeProfileScope,
                  (TraktSettingsStore.watchProgressSource(in: store) == .simkl
                    || RemoteTrackingState.isScrobbleEnabled(for: .simkl, in: store, simklTokenStorage: tokenStorage, profileScope: ownerScope)) else { return false }
            guard let status = try? await service.delete(path: "sync/playback/\(id)"),
                  (200..<300).contains(status) else { continue }
            guard !Task.isCancelled, ProfileSettings.isActiveStore(store),
                  ownerScope == ProfileSettings.activeProfileScope,
                  (TraktSettingsStore.watchProgressSource(in: store) == .simkl
                    || RemoteTrackingState.isScrobbleEnabled(for: .simkl, in: store, simklTokenStorage: tokenStorage, profileScope: ownerScope)) else { return false }
            removedAny = true
        }
        guard removedAny else { return false }

        SimklSyncCache.invalidatePlaybacks(in: store)
        NotificationCenter.default.post(
            name: TraktSettingsStore.continueWatchingChangedNotification,
            object: nil
        )
        TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .simkl, in: store)
        return true
    }

    static func playbackMatches(_ playback: SimklPlaybackDTO, card: ContinueWatchingItem) -> Bool {
        guard let seed = progressSeed(playback),
              let meta = placeholderMeta(item: seed.item, type: seed.type),
              WatchedStore.sameContent(meta, card.meta) else { return false }
        // A card that never named its episode cannot be narrowed any further;
        // removing every paused row for the title is what the user asked for.
        guard let season = card.season, let episode = card.episode else { return true }
        return playback.episode?.season == season
            && playback.episode?.resolvedNumber == episode
    }

    /// Whether a watched mark supersedes this paused row.
    ///
    /// `watchedDates` is keyed by content identity, so a row Simkl returns
    /// under a different id space than the mark was written with still matches.
    /// A row Simkl never dated is treated as older than any mark: without a
    /// timestamp there is nothing to argue it happened after one.
    static func isRetiredByWatchedMark(
        _ playback: SimklPlaybackDTO,
        meta: NuvioMeta,
        type: String,
        watchedDates: [String: Date]
    ) -> Bool {
        let pausedAt = parseDate(playback.pausedAt) ?? .distantPast
        let keys = WatchedStore.watchedIdentityKeys(
            metaId: meta.id,
            imdbId: meta.imdbId,
            tmdbId: meta.tmdbId,
            contentType: type,
            season: playback.episode?.season,
            episode: playback.episode?.resolvedNumber
        )
        return keys.contains { key in
            guard let watchedAt = watchedDates[key] else { return false }
            return watchedAt >= pausedAt
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
                lastWatchedAt: nil,
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
    /// Omitted — not empty — when the whole season is the unit. Simkl reads a
    /// season without `episodes` as "every episode in it"; an empty array is
    /// not the same instruction.
    let episodes: [SimklWriteEpisode]?
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
    let anime: SimklScrobbleMedia?
    let episode: SimklScrobbleEpisode?
}

/// Builds a `/scrobble/*` body with the item under the container Simkl keys on.
///
/// `mal` / `anidb` / `anilist` / `kitsu` exist only on the `anime` object — sent
/// under `show` they ride along as extra properties the matcher never looks at,
/// so a title carrying nothing but an anime-catalog id silently fails to
/// resolve. Anything with a cross-catalog id (simkl / imdb / tmdb / tvdb) stays
/// under `show` or `movie`, which is what Simkl recommends when the caller
/// can't tell whether a title is anime.
private func scrobbleRequest(
    meta: NuvioMeta,
    media: SimklScrobbleMedia,
    progress: Double,
    season: Int?,
    episode: Int?
) -> SimklScrobbleRequest {
    let ids = media.ids
    let hasCrossCatalogID = ids.simkl != nil || ids.imdb != nil
        || ids.tmdb != nil || ids.tvdb != nil
    // The `anime` container is only valid paired with an episode, so an anime
    // *film* known solely by a MAL id still goes out as a movie — best effort.
    let useAnimeContainer = meta.isSeries && !hasCrossCatalogID

    return SimklScrobbleRequest(
        progress: progress,
        movie: meta.isSeries ? nil : media,
        show: meta.isSeries && !useAnimeContainer ? media : nil,
        anime: useAnimeContainer ? media : nil,
        episode: meta.isSeries
            ? SimklScrobbleEpisode(season: season, number: episode)
            : nil
    )
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
    guard let ids = simklIDs(meta) else {
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

/// `episodes` carries every episode being marked in one season, so a whole
/// season is one request rather than one per episode.
private func historyMutation(
    meta: NuvioMeta,
    season: Int?,
    episodes: [Int],
    watchedAt: String?
) -> SimklHistoryMutation? {
    guard let ids = simklIDs(meta) else {
        return nil
    }
    let seasons: [SimklWriteSeason]?
    if meta.isSeries, let season, !episodes.isEmpty {
        seasons = [
            SimklWriteSeason(
                number: season,
                episodes: episodes.map { SimklWriteEpisode(number: $0, watchedAt: watchedAt) }
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

/// Body for `/sync/history/remove`.
///
/// Granularity is load-bearing here: a show sent with neither `seasons` nor
/// `episodes` means "delete this title from the library entirely" — every
/// episode *and* the watchlist row. A whole-title unwatch in Nuvio does not
/// mean that, so a series without an explicit episode is scoped to the seasons
/// Simkl actually holds watched episodes in, which unmarks them and leaves the
/// library row alone. With nothing watched there is nothing to unmark, and the
/// write is skipped rather than sent in its destructive form.
///
/// Movies have no narrower form — the bare shape is the only way to unmark one.
private func historyRemoval(
    meta: NuvioMeta,
    season: Int?,
    episodes: [Int],
    store: UserDefaults
) -> SimklHistoryMutation? {
    guard let ids = simklIDs(meta) else { return nil }

    func media(_ seasons: [SimklWriteSeason]?) -> SimklWriteMedia {
        SimklWriteMedia(
            to: nil,
            title: meta.name,
            year: meta.year,
            ids: ids,
            watchedAt: nil,
            seasons: seasons
        )
    }

    guard meta.isSeries else {
        return SimklHistoryMutation(movies: [media(nil)], shows: nil)
    }

    if let season, !episodes.isEmpty {
        return SimklHistoryMutation(
            movies: nil,
            shows: [
                media([
                    SimklWriteSeason(
                        number: season,
                        episodes: episodes.map { SimklWriteEpisode(number: $0, watchedAt: nil) }
                    )
                ])
            ]
        )
    }

    var seasonNumbers = SimklSyncCache.watchedSeasons(matching: ids, in: store)
    if seasonNumbers.isEmpty {
        // Never-synced profile: fall back to what this device knows is watched.
        seasonNumbers = Array(
            Set(
                WatchedStore.watchedEpisodeKeys(meta: meta).compactMap {
                    Int($0.split(separator: ":").first ?? "")
                }
            )
        ).sorted()
    }
    guard !seasonNumbers.isEmpty else { return nil }

    return SimklHistoryMutation(
        movies: nil,
        shows: [media(seasonNumbers.map { SimklWriteSeason(number: $0, episodes: nil) })]
    )
}

/// Simkl reports its 20-second per-user write lock as `400 rate_limit` rather
/// than `429`, so the status alone can't be told apart from a malformed body.
private func isLockCollision(status: Int, data: Data) -> Bool {
    guard status == 400, !data.isEmpty,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = object["error"] as? String else {
        return false
    }
    return error.caseInsensitiveCompare("rate_limit") == .orderedSame
}

private func scrobbleMedia(_ meta: NuvioMeta) -> SimklScrobbleMedia? {
    guard let ids = simklIDs(meta) else {
        return nil
    }
    return SimklScrobbleMedia(title: meta.name, year: meta.year, ids: ids)
}

private func simklIDs(_ meta: NuvioMeta) -> SimklSyncIDs? {
    let first = meta.id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? meta.id
    /// Leading numeric id for a `prefix:1234` style meta id, e.g. `kitsu:42` → 42.
    func prefixedInt(_ prefix: String) -> Int? {
        guard meta.id.hasPrefix("\(prefix):") else { return nil }
        let value = meta.id.dropFirst(prefix.count + 1)
        // Some spaces append an episode segment (`kitsu:42:7`); keep the title id.
        return Int(value.split(separator: ":").first ?? "")
    }

    let ids = SimklSyncIDs(
        simkl: prefixedInt("simkl"),
        imdb: meta.imdbId ?? (first.hasPrefix("tt") ? first : nil),
        tmdb: meta.tmdbId ?? prefixedInt("tmdb"),
        tvdb: prefixedInt("tvdb"),
        mal: prefixedInt("mal"),
        anidb: prefixedInt("anidb"),
        anilist: prefixedInt("anilist"),
        kitsu: prefixedInt("kitsu")
    )
    guard ids.hasUsableIdentifier else { return nil }
    return ids
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

func runtimeSeconds(for meta: NuvioMeta) -> Double {
    if let stored = ContinueWatchingStore.item(for: meta.id)?.duration, stored >= 60 {
        return stored
    }
    let fallback = meta.isSeries ? 45.0 * 60.0 : 120.0 * 60.0
    guard let raw = meta.runtime?.lowercased(), !raw.isEmpty else { return fallback }
    let values = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
    guard let first = values.first else { return fallback }
    if raw.contains("h") {
        let minutes = values.count > 1 ? values[1] : 0
        return max((first * 60 + minutes) * 60, 60)
    }
    return max(first * 60, 60)
}
