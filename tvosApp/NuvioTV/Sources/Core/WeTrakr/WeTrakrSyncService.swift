import Foundation
import SwiftUI

// MARK: - WeTrakr Identifiers & Payloads

struct WeTrakrSyncIDs: Codable, Equatable {
    let wetrakr: Int?
    let imdb: String?
    let tmdb: Int?
    let tvdb: Int?

    enum CodingKeys: String, CodingKey {
        case wetrakr, imdb, tmdb, tvdb
    }

    init(
        wetrakr: Int? = nil,
        imdb: String? = nil,
        tmdb: Int? = nil,
        tvdb: Int? = nil
    ) {
        self.wetrakr = wetrakr
        self.imdb = imdb
        self.tmdb = tmdb
        self.tvdb = tvdb
    }

    var hasUsableIdentifier: Bool {
        wetrakr != nil || imdb != nil || tmdb != nil || tvdb != nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        wetrakr = Self.flexibleInt(in: container, forKey: .wetrakr)
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

struct WeTrakrMediaPayload: Codable, Equatable {
    let title: String?
    let year: Int?
    let ids: WeTrakrSyncIDs?
    let status: String?
    let trackedAt: String?

    enum CodingKeys: String, CodingKey {
        case title, year, ids, status
        case trackedAt = "tracked_at"
    }

    init(
        title: String? = nil,
        year: Int? = nil,
        ids: WeTrakrSyncIDs? = nil,
        status: String? = nil,
        trackedAt: String? = nil
    ) {
        self.title = title
        self.year = year
        self.ids = ids
        self.status = status
        self.trackedAt = trackedAt
    }
}

struct WeTrakrEpisodePayload: Codable, Equatable {
    let season: Int
    let number: Int

    init(season: Int, number: Int) {
        self.season = season
        self.number = number
    }
}

struct WeTrakrScrobblePayload: Codable {
    let movie: WeTrakrMediaPayload?
    let show: WeTrakrMediaPayload?
    let episode: WeTrakrEpisodePayload?
    let progress: Double
    let appVersion: String?

    enum CodingKeys: String, CodingKey {
        case movie, show, episode, progress
        case appVersion = "app_version"
    }
}

struct WeTrakrCancelPlaybackPayload: Codable {
    let movie: WeTrakrMediaPayload?
    let show: WeTrakrMediaPayload?
    let episode: WeTrakrEpisodePayload?
}

// MARK: - Tracking DTOs

struct WeTrakrMediaDTO: Codable {
    let id: Int?
    let type: String?
    let title: String?
    let originalTitle: String?
    let overview: String?
    let year: Int?
    let releaseDate: String?
    let ids: WeTrakrSyncIDs?
    let posterPath: String?
    let backdropPath: String?
    let runtime: Double?

    enum CodingKeys: String, CodingKey {
        case id, type, title, overview, year, ids
        case originalTitle = "original_title"
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case runtime
    }

    init(
        id: Int? = nil,
        type: String? = nil,
        title: String? = nil,
        originalTitle: String? = nil,
        overview: String? = nil,
        year: Int? = nil,
        releaseDate: String? = nil,
        ids: WeTrakrSyncIDs? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        runtime: Double? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.year = year
        self.releaseDate = releaseDate
        self.ids = ids
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.runtime = runtime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.flexibleInt(in: container, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        year = Self.flexibleInt(in: container, forKey: .year)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        ids = try container.decodeIfPresent(WeTrakrSyncIDs.self, forKey: .ids)
        posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
        backdropPath = try container.decodeIfPresent(String.self, forKey: .backdropPath)
        runtime = Self.flexibleDouble(in: container, forKey: .runtime)
    }

    private static func flexibleInt(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    private static func flexibleDouble(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
        return nil
    }
}

struct WeTrakrEpisodeDTO: Codable {
    let id: Int?
    let seasonNumber: Int?
    let number: Int?
    let season: Int?
    let title: String?
    let overview: String?
    let runtime: Double?
    let seasonPosterPath: String?
    let show: WeTrakrMediaDTO?

    enum CodingKeys: String, CodingKey {
        case id, number, season, title, overview, runtime, show
        case seasonNumber = "season_number"
        case seasonPosterPath = "season_poster_path"
    }

    init(
        id: Int? = nil,
        seasonNumber: Int? = nil,
        number: Int? = nil,
        season: Int? = nil,
        title: String? = nil,
        overview: String? = nil,
        runtime: Double? = nil,
        seasonPosterPath: String? = nil,
        show: WeTrakrMediaDTO? = nil
    ) {
        self.id = id
        self.seasonNumber = seasonNumber
        self.number = number
        self.season = season
        self.title = title
        self.overview = overview
        self.runtime = runtime
        self.seasonPosterPath = seasonPosterPath
        self.show = show
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.flexibleInt(in: container, forKey: .id)
        seasonNumber = Self.flexibleInt(in: container, forKey: .seasonNumber)
        number = Self.flexibleInt(in: container, forKey: .number)
        season = Self.flexibleInt(in: container, forKey: .season)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        runtime = Self.flexibleDouble(in: container, forKey: .runtime)
        seasonPosterPath = try container.decodeIfPresent(String.self, forKey: .seasonPosterPath)
        show = try container.decodeIfPresent(WeTrakrMediaDTO.self, forKey: .show)
    }

    private static func flexibleInt(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    private static func flexibleDouble(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
        return nil
    }
}

struct WeTrakrPlaybackInfoDTO: Codable {
    let status: String?
    let progressPercent: Double?
    let runtimeSeconds: Double?
    let trackedAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case status
        case progressPercent = "progress_percent"
        case runtimeSeconds = "runtime_seconds"
        case trackedAt = "tracked_at"
        case updatedAt = "updated_at"
    }

    init(
        status: String? = nil,
        progressPercent: Double? = nil,
        runtimeSeconds: Double? = nil,
        trackedAt: String? = nil,
        updatedAt: String? = nil
    ) {
        self.status = status
        self.progressPercent = progressPercent
        self.runtimeSeconds = runtimeSeconds
        self.trackedAt = trackedAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        progressPercent = Self.flexibleDouble(in: container, forKey: .progressPercent)
        runtimeSeconds = Self.flexibleDouble(in: container, forKey: .runtimeSeconds)
        trackedAt = try container.decodeIfPresent(String.self, forKey: .trackedAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    }

    private static func flexibleDouble(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
        return nil
    }
}

struct WeTrakrTrackingPlayingItemDTO: Codable {
    // Top-level / Common fields
    let id: Int?
    let type: String?
    let title: String?
    let originalTitle: String?
    let overview: String?
    let year: Int?
    let releaseDate: String?
    let posterPath: String?
    let backdropPath: String?
    let seasonPosterPath: String?
    let runtime: Double?
    let ids: WeTrakrSyncIDs?

    // Episode specifics at top level
    let seasonNumber: Int?
    let number: Int?
    let season: Int?
    let show: WeTrakrMediaDTO?

    // Nested / Wrapped structures
    let media: WeTrakrMediaDTO?
    let episode: WeTrakrEpisodeDTO?
    let playback: WeTrakrPlaybackInfoDTO?

    // Scrobble Playing & Trakt-compatibility fields
    let status: String?
    let target: String?
    let progressPercent: Double?
    let runtimeSeconds: Double?
    let trackedAt: String?
    let updatedAt: String?
    let watchedAt: String?
    let pausedAt: String?
    let progress: Double?
    let movie: WeTrakrMediaDTO?

    enum CodingKeys: String, CodingKey {
        case id, type, title, overview, year, ids, number, season, show, media, episode, playback, status, target, movie, progress
        case originalTitle = "original_title"
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case seasonPosterPath = "season_poster_path"
        case runtime
        case seasonNumber = "season_number"
        case progressPercent = "progress_percent"
        case runtimeSeconds = "runtime_seconds"
        case trackedAt = "tracked_at"
        case updatedAt = "updated_at"
        case watchedAt = "watched_at"
        case pausedAt = "paused_at"
    }

    init(
        id: Int? = nil,
        type: String? = nil,
        title: String? = nil,
        originalTitle: String? = nil,
        overview: String? = nil,
        year: Int? = nil,
        releaseDate: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        seasonPosterPath: String? = nil,
        runtime: Double? = nil,
        ids: WeTrakrSyncIDs? = nil,
        seasonNumber: Int? = nil,
        number: Int? = nil,
        season: Int? = nil,
        show: WeTrakrMediaDTO? = nil,
        media: WeTrakrMediaDTO? = nil,
        episode: WeTrakrEpisodeDTO? = nil,
        playback: WeTrakrPlaybackInfoDTO? = nil,
        status: String? = nil,
        target: String? = nil,
        progressPercent: Double? = nil,
        runtimeSeconds: Double? = nil,
        trackedAt: String? = nil,
        updatedAt: String? = nil,
        watchedAt: String? = nil,
        pausedAt: String? = nil,
        progress: Double? = nil,
        movie: WeTrakrMediaDTO? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.originalTitle = originalTitle
        self.overview = overview
        self.year = year
        self.releaseDate = releaseDate
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.seasonPosterPath = seasonPosterPath
        self.runtime = runtime
        self.ids = ids
        self.seasonNumber = seasonNumber
        self.number = number
        self.season = season
        self.show = show
        self.media = media
        self.episode = episode
        self.playback = playback
        self.status = status
        self.target = target
        self.progressPercent = progressPercent
        self.runtimeSeconds = runtimeSeconds
        self.trackedAt = trackedAt
        self.updatedAt = updatedAt
        self.watchedAt = watchedAt
        self.pausedAt = pausedAt
        self.progress = progress
        self.movie = movie
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = Self.flexibleInt(in: container, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        year = Self.flexibleInt(in: container, forKey: .year)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
        backdropPath = try container.decodeIfPresent(String.self, forKey: .backdropPath)
        seasonPosterPath = try container.decodeIfPresent(String.self, forKey: .seasonPosterPath)
        runtime = Self.flexibleDouble(in: container, forKey: .runtime)
        ids = try container.decodeIfPresent(WeTrakrSyncIDs.self, forKey: .ids)
        seasonNumber = Self.flexibleInt(in: container, forKey: .seasonNumber)
        number = Self.flexibleInt(in: container, forKey: .number)
        season = Self.flexibleInt(in: container, forKey: .season)
        show = try container.decodeIfPresent(WeTrakrMediaDTO.self, forKey: .show)
        media = try container.decodeIfPresent(WeTrakrMediaDTO.self, forKey: .media)
        episode = try container.decodeIfPresent(WeTrakrEpisodeDTO.self, forKey: .episode)
        playback = try container.decodeIfPresent(WeTrakrPlaybackInfoDTO.self, forKey: .playback)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        target = try container.decodeIfPresent(String.self, forKey: .target)
        progressPercent = Self.flexibleDouble(in: container, forKey: .progressPercent)
        runtimeSeconds = Self.flexibleDouble(in: container, forKey: .runtimeSeconds)
        trackedAt = try container.decodeIfPresent(String.self, forKey: .trackedAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        watchedAt = try container.decodeIfPresent(String.self, forKey: .watchedAt)
        pausedAt = try container.decodeIfPresent(String.self, forKey: .pausedAt)
        progress = Self.flexibleDouble(in: container, forKey: .progress)
        movie = try container.decodeIfPresent(WeTrakrMediaDTO.self, forKey: .movie)
    }

    private static func flexibleInt(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decode(Int.self, forKey: key) { return value }
        if let value = try? container.decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    private static func flexibleDouble(
        in container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? container.decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    var resolvedIsSeries: Bool {
        if let type = type?.lowercased(), type == "show" || type == "series" || type == "episode" {
            return true
        }
        if let target = target?.lowercased(), target == "show" || target == "series" || target == "episode" {
            return true
        }
        if show != nil || episode != nil || seasonNumber != nil || number != nil || season != nil {
            return true
        }
        if let mediaType = media?.type?.lowercased(), mediaType == "show" || mediaType == "series" {
            return true
        }
        return false
    }

    var resolvedMedia: WeTrakrMediaDTO {
        if let show { return show }
        if let media { return media }
        if let movie { return movie }
        return WeTrakrMediaDTO(
            id: id,
            type: type,
            title: title,
            originalTitle: originalTitle,
            overview: overview,
            year: year,
            releaseDate: releaseDate,
            ids: ids,
            posterPath: posterPath,
            backdropPath: backdropPath,
            runtime: runtime
        )
    }

    var resolvedSeasonNumber: Int? {
        seasonNumber ?? season ?? episode?.seasonNumber ?? episode?.season
    }

    var resolvedEpisodeNumber: Int? {
        number ?? episode?.number
    }

    var resolvedEpisodeTitle: String? {
        if resolvedIsSeries {
            return episode?.title ?? (seasonNumber != nil ? title : nil)
        }
        return nil
    }

    var resolvedProgressPercent: Double? {
        if let p = playback?.progressPercent, p > 0 { return p }
        if let p = progressPercent, p > 0 { return p }
        if let p = progress, p > 0 {
            return p <= 1.0 ? p * 100.0 : p
        }
        return nil
    }

    var resolvedRuntimeSeconds: Double? {
        if let r = playback?.runtimeSeconds, r > 0 { return r }
        if let r = runtimeSeconds, r > 0 { return r }
        if let r = episode?.runtime, r > 0 {
            return r > 600 ? r : r * 60.0
        }
        if let r = runtime, r > 0 {
            return r > 600 ? r : r * 60.0
        }
        if let r = media?.runtime, r > 0 {
            return r > 600 ? r : r * 60.0
        }
        return nil
    }

    var resolvedLastWatchedAt: Date {
        let dateString = playback?.trackedAt
            ?? playback?.updatedAt
            ?? trackedAt
            ?? updatedAt
            ?? watchedAt
            ?? pausedAt
        if let d = WeTrakrProgressService.dateFromISO8601(dateString) {
            return d
        }
        return Date()
    }
}

struct WeTrakrTrackingHistoryItemDTO: Codable {
    let id: String?
    let playID: String?
    let media: WeTrakrMediaDTO?
    let movie: WeTrakrMediaDTO?
    let episode: WeTrakrEpisodeDTO?
    let watchedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, media, movie, episode
        case playID = "play_id"
        case watchedAt = "watched_at"
    }

    init(
        id: String? = nil,
        playID: String? = nil,
        media: WeTrakrMediaDTO? = nil,
        movie: WeTrakrMediaDTO? = nil,
        episode: WeTrakrEpisodeDTO? = nil,
        watchedAt: String? = nil
    ) {
        self.id = id
        self.playID = playID
        self.media = media
        self.movie = movie
        self.episode = episode
        self.watchedAt = watchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let str = try? container.decode(String.self, forKey: .id) {
            id = str
        } else if let num = try? container.decode(Int.self, forKey: .id) {
            id = String(num)
        } else {
            id = nil
        }
        if let str = try? container.decode(String.self, forKey: .playID) {
            playID = str
        } else if let num = try? container.decode(Int.self, forKey: .playID) {
            playID = String(num)
        } else {
            playID = nil
        }
        media = try container.decodeIfPresent(WeTrakrMediaDTO.self, forKey: .media)
        movie = try container.decodeIfPresent(WeTrakrMediaDTO.self, forKey: .movie)
        episode = try container.decodeIfPresent(WeTrakrEpisodeDTO.self, forKey: .episode)
        watchedAt = try container.decodeIfPresent(String.self, forKey: .watchedAt)
    }
}

// MARK: - Mutate Tracking Payloads

struct WeTrakrTrackingAddPayload: Codable {
    let movies: [WeTrakrMediaPayload]?
    let shows: [WeTrakrShowTrackingPayload]?
    let allowRewatch: Bool?

    enum CodingKeys: String, CodingKey {
        case movies, shows
        case allowRewatch = "allow_rewatch"
    }

    init(
        movies: [WeTrakrMediaPayload]? = nil,
        shows: [WeTrakrShowTrackingPayload]? = nil,
        allowRewatch: Bool? = nil
    ) {
        self.movies = movies
        self.shows = shows
        self.allowRewatch = allowRewatch
    }
}

struct WeTrakrShowTrackingPayload: Codable {
    let title: String?
    let year: Int?
    let ids: WeTrakrSyncIDs?
    let status: String?
    let seasons: [WeTrakrSeasonTrackingPayload]?

    init(
        title: String? = nil,
        year: Int? = nil,
        ids: WeTrakrSyncIDs? = nil,
        status: String? = nil,
        seasons: [WeTrakrSeasonTrackingPayload]? = nil
    ) {
        self.title = title
        self.year = year
        self.ids = ids
        self.status = status
        self.seasons = seasons
    }
}

struct WeTrakrSeasonTrackingPayload: Codable {
    let number: Int
    let status: String?
    let episodes: [WeTrakrEpisodeTrackingPayload]?

    init(
        number: Int,
        status: String? = nil,
        episodes: [WeTrakrEpisodeTrackingPayload]? = nil
    ) {
        self.number = number
        self.status = status
        self.episodes = episodes
    }
}

struct WeTrakrEpisodeTrackingPayload: Codable {
    let number: Int
    let status: String?
    let trackedAt: String?

    enum CodingKeys: String, CodingKey {
        case number, status
        case trackedAt = "tracked_at"
    }

    init(
        number: Int,
        status: String? = nil,
        trackedAt: String? = nil
    ) {
        self.number = number
        self.status = status
        self.trackedAt = trackedAt
    }
}

struct WeTrakrTrackingRemovePayload: Codable {
    let movies: [WeTrakrMediaPayload]?
    let shows: [WeTrakrShowTrackingPayload]?

    init(
        movies: [WeTrakrMediaPayload]? = nil,
        shows: [WeTrakrShowTrackingPayload]? = nil
    ) {
        self.movies = movies
        self.shows = shows
    }
}

struct WeTrakrWatchAllSeasonPayload: Codable {
    let show: WeTrakrMediaPayload
    let seasonNumber: Int

    enum CodingKeys: String, CodingKey {
        case show
        case seasonNumber = "season_number"
    }
}

// MARK: - WeTrakr Progress & Scrobble Service

private actor WeTrakrAccountRequestLane {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isOccupied else {
            isOccupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isOccupied = false
            return
        }
        waiters.removeFirst().resume()
    }
}

private struct WeTrakrRequestContext {
    let accountID: String
    let token: String
    let clientID: String
}

private struct WeTrakrLivePlaybackOwnership {
    let playbackID: String
    let profileId: String?
    let meta: NuvioMeta
    let season: Int?
    let episode: Int?
}

@MainActor
struct WeTrakrProgressService {
    static var client = WeTrakrAPIClient()
    static var tokenStorage: WeTrakrTokenStorage = WeTrakrKeychainTokenStorage()
    private static var accountLanes: [String: WeTrakrAccountRequestLane] = [:]
    private static var livePlaybackOwners: [String: WeTrakrLivePlaybackOwnership] = [:]
    private static var cancelledPlaybackIDs = Set<String>()

    nonisolated static func completionAccountID(
        in store: UserDefaults = ProfileSettings.current,
        profileId: String? = nil,
        tokenStorage: WeTrakrTokenStorage = WeTrakrKeychainTokenStorage()
    ) -> String? {
        guard ProfileSettings.isActiveStore(store),
              let state = WeTrakrRuntimeSession.authenticatedState(
                store: store,
                tokenStorage: tokenStorage,
                profileScope: profileId
              ),
              let accountID = state.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty else {
            return nil
        }
        return accountID
    }

    private static func requestContext(
        in store: UserDefaults,
        profileId: String?,
        expectedAccountID: String? = nil,
        requiresWeTrakrSource: Bool = false
    ) -> WeTrakrRequestContext? {
        guard ProfileSettings.isActiveStore(store),
              !requiresWeTrakrSource || TraktSettingsStore.watchProgressSource(in: store) == .wetrakr,
              let state = WeTrakrRuntimeSession.authenticatedState(
                store: store,
                tokenStorage: tokenStorage,
                profileScope: profileId
              ),
              let token = state.accessToken, !token.isEmpty,
              let accountID = state.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty,
              expectedAccountID == nil || expectedAccountID == accountID,
              !WeTrakrConfig.clientID(in: store).isEmpty else {
            return nil
        }
        return WeTrakrRequestContext(
            accountID: accountID,
            token: token,
            clientID: WeTrakrConfig.clientID(in: store)
        )
    }

    private static func contextIsCurrent(
        _ context: WeTrakrRequestContext,
        in store: UserDefaults,
        profileId: String?,
        requiresWeTrakrSource: Bool
    ) -> Bool {
        guard ProfileSettings.isActiveStore(store),
              !requiresWeTrakrSource || TraktSettingsStore.watchProgressSource(in: store) == .wetrakr,
              completionAccountID(in: store, profileId: profileId, tokenStorage: tokenStorage) == context.accountID else {
            return false
        }
        if let profileId,
           let activeProfileID = ProfileSettings.activeProfileID,
           activeProfileID != profileId {
            return false
        }
        return true
    }

    private static func refreshedContextIfNeeded(
        _ context: WeTrakrRequestContext,
        in store: UserDefaults,
        profileId: String?,
        requiresWeTrakrSource: Bool
    ) async -> WeTrakrRequestContext? {
        guard let current = requestContext(
            in: store,
            profileId: profileId,
            expectedAccountID: context.accountID,
            requiresWeTrakrSource: requiresWeTrakrSource
        ), contextIsCurrent(current, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource) else {
            return nil
        }

        let authProfileScope = profileId
            ?? store.string(forKey: "nuvio.tv.profile.settings.profileID")
            ?? ProfileSettings.activeProfileID
            ?? "default"
        let state = WeTrakrAuthStore.state(
            in: store,
            profileScope: authProfileScope,
            tokenStorage: tokenStorage
        )
        guard state.accountID?.trimmingCharacters(in: .whitespacesAndNewlines) == context.accountID else {
            return nil
        }
        guard let expiresAt = state.tokenExpiresAt,
              expiresAt <= Date().timeIntervalSince1970 * 1000.0 + 60_000 else {
            return current
        }

        let auth = WeTrakrAuthService(
            client: client,
            store: store,
            tokenStorage: tokenStorage,
            profileScope: authProfileScope
        )
        do {
            let refreshedToken = try await auth.refreshAccessToken()
            guard contextIsCurrent(current, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource),
                  let refreshed = requestContext(
                    in: store,
                    profileId: profileId,
                    expectedAccountID: context.accountID,
                    requiresWeTrakrSource: requiresWeTrakrSource
                  ),
                  refreshed.token == refreshedToken else {
                return nil
            }
            return refreshed
        } catch {
            print("[WeTrakrProgressService] access-token refresh failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func withAccountLane(
        _ accountID: String,
        operation: () async -> Bool
    ) async -> Bool {
        let lane = accountLanes[accountID] ?? {
            let lane = WeTrakrAccountRequestLane()
            accountLanes[accountID] = lane
            return lane
        }()
        await lane.acquire()
        let result = await operation()
        await lane.release()
        return result
    }

    static func reportPlayback(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        action: TraktScrobbleAction,
        expectedAccountID: String? = nil,
        playbackID: String? = nil,
        profileId: String? = nil,
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        let profileID = resolvedProfileID(in: store, explicit: profileId)
        guard position.isFinite,
              duration.isFinite,
              duration > 0,
              let accountID = completionAccountID(in: store, profileId: profileID, tokenStorage: tokenStorage),
              expectedAccountID == nil || expectedAccountID == accountID else {
            return false
        }

        return await withAccountLane(accountID) {
            // The account was authenticated through this service's token storage above.
            // Read the toggle directly so injected token stores follow the same routing.
            let isScrobble = store.bool(forKey: SettingsKey.wetrakrScrobbleEnabled)
            let requiresWeTrakrSource = !isScrobble
            guard let context = requestContext(
                in: store,
                profileId: profileID,
                expectedAccountID: expectedAccountID ?? accountID,
                requiresWeTrakrSource: requiresWeTrakrSource
            ),
                  contextIsCurrent(context, in: store, profileId: profileID, requiresWeTrakrSource: requiresWeTrakrSource) else {
                return false
            }
            return await reportPlaybackUnlocked(
                meta: meta,
                position: position,
                duration: duration,
                season: season,
                episode: episode,
                action: action,
                store: store,
                profileId: profileID,
                context: context,
                requiresWeTrakrSource: requiresWeTrakrSource,
                playbackID: playbackID
            )
        }
    }

    private static func reportPlaybackUnlocked(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        action: TraktScrobbleAction,
        store: UserDefaults,
        profileId: String?,
        context: WeTrakrRequestContext,
        requiresWeTrakrSource: Bool,
        playbackID: String? = nil
    ) async -> Bool {
        guard position.isFinite, duration.isFinite, duration > 0,
              contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource) else {
            return false
        }
        let ids = wetrakrIDs(for: meta)
        guard ids.hasUsableIdentifier else { return false }
        let progress = min(max(position / duration * 100.0, 0.01), 100.0)
        let endpoint: String
        switch action {
        case .start:
            endpoint = "/scrobble/start"
        case .pause:
            endpoint = "/scrobble/pause"
        case .stop:
            endpoint = "/scrobble/stop"
        }

        let payload: WeTrakrScrobblePayload
        if meta.isSeries {
            guard let s = season, s >= 0, let ep = episode, ep > 0 else { return false }
            payload = WeTrakrScrobblePayload(
                movie: nil,
                show: WeTrakrMediaPayload(title: meta.name, year: meta.year, ids: ids),
                episode: WeTrakrEpisodePayload(season: s, number: ep),
                progress: progress,
                appVersion: WeTrakrConfig.appVersion
            )
        } else {
            payload = WeTrakrScrobblePayload(
                movie: WeTrakrMediaPayload(title: meta.name, year: meta.year, ids: ids),
                show: nil,
                episode: nil,
                progress: progress,
                appVersion: WeTrakrConfig.appVersion
            )
        }

        do {
            let result: WeTrakrHTTPResult<Data> = try await client.postRaw(
                path: endpoint,
                body: payload,
                accessToken: context.token,
                clientID: context.clientID
            )
            _ = try result.valueOrThrow()
            guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource) else {
                return false
            }
            if let playbackID = playbackID?.trimmingCharacters(in: .whitespacesAndNewlines),
               !playbackID.isEmpty {
                switch action {
                case .start, .pause:
                    livePlaybackOwners[context.accountID] = WeTrakrLivePlaybackOwnership(
                        playbackID: playbackID,
                        profileId: profileId,
                        meta: meta.persistenceSnapshot,
                        season: season,
                        episode: episode
                    )
                case .stop:
                    if livePlaybackOwners[context.accountID]?.playbackID == playbackID {
                        livePlaybackOwners.removeValue(forKey: context.accountID)
                    }
                }
            } else {
                switch action {
                case .start:
                    livePlaybackOwners.removeValue(forKey: context.accountID)
                case .pause, .stop:
                    break
                }
            }
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            return true
        } catch {
            print("[WeTrakrProgressService] reportPlayback failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    static func removePlayback(
        for item: ContinueWatchingItem,
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        guard let accountID = completionAccountID(in: store, tokenStorage: tokenStorage) else { return false }
        return await withAccountLane(accountID) {
            guard let context = requestContext(in: store, profileId: nil, expectedAccountID: accountID, requiresWeTrakrSource: true),
                  contextIsCurrent(context, in: store, profileId: nil, requiresWeTrakrSource: true) else {
                return false
            }
            return await removePlaybackUnlocked(for: item, store: store, profileId: nil, context: context)
        }
    }

    private static func removePlaybackUnlocked(
        for item: ContinueWatchingItem,
        store: UserDefaults,
        profileId: String?,
        context: WeTrakrRequestContext
    ) async -> Bool {
        let meta = item.meta
        let ids = wetrakrIDs(for: meta)

        guard ids.hasUsableIdentifier else {
            return false
        }

        let seasonNum = item.season ?? item.episodeNumbers?.season
        let epNum = item.episode ?? item.episodeNumbers?.episode

        // 1. Cancel playback session in scrobble engine: DELETE /scrobble/playing
        let cancelPayload: WeTrakrCancelPlaybackPayload
        if meta.isSeries {
            let s = seasonNum ?? 1
            let ep = epNum ?? 1
            cancelPayload = WeTrakrCancelPlaybackPayload(
                movie: nil,
                show: WeTrakrMediaPayload(title: meta.name, year: meta.year, ids: ids),
                episode: WeTrakrEpisodePayload(season: s, number: ep)
            )
        } else {
            cancelPayload = WeTrakrCancelPlaybackPayload(
                movie: WeTrakrMediaPayload(title: meta.name, year: meta.year, ids: ids),
                show: nil,
                episode: nil
            )
        }

        do {
            _ = try await client.deleteRaw(
                path: "/scrobble/playing",
                body: cancelPayload,
                accessToken: context.token,
                clientID: context.clientID,
                idempotencyKey: UUID().uuidString
            )
        } catch {
            print("[WeTrakrProgressService] cancel scrobble session failed: \(error.localizedDescription)")
        }
        guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: true) else {
            return false
        }

        // 2. Remove item from "playing" tracking list: POST /sync/tracking/remove with status: "playing"
        let removePayload: WeTrakrTrackingRemovePayload
        if meta.isSeries {
            if let seasonNum, let epNum {
                let showPayload = WeTrakrShowTrackingPayload(
                    title: meta.name,
                    year: meta.year,
                    ids: ids,
                    status: "playing",
                    seasons: [
                        WeTrakrSeasonTrackingPayload(
                            number: seasonNum,
                            status: "playing",
                            episodes: [
                                WeTrakrEpisodeTrackingPayload(number: epNum, status: "playing")
                            ]
                        )
                    ]
                )
                removePayload = WeTrakrTrackingRemovePayload(
                    movies: nil,
                    shows: [showPayload]
                )
            } else {
                let showPayload = WeTrakrShowTrackingPayload(
                    title: meta.name,
                    year: meta.year,
                    ids: ids,
                    status: "playing"
                )
                removePayload = WeTrakrTrackingRemovePayload(
                    movies: nil,
                    shows: [showPayload]
                )
            }
        } else {
            let moviePayload = WeTrakrMediaPayload(
                title: meta.name,
                year: meta.year,
                ids: ids,
                status: "playing"
            )
            removePayload = WeTrakrTrackingRemovePayload(
                movies: [moviePayload],
                shows: nil
            )
        }

        do {
            let result: WeTrakrHTTPResult<Data> = try await client.postRaw(
                path: "/sync/tracking/remove",
                body: removePayload,
                accessToken: context.token,
                clientID: context.clientID,
                idempotencyKey: UUID().uuidString
            )
            _ = try result.valueOrThrow()
            guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: true) else {
                return false
            }
        } catch {
            print("[WeTrakrProgressService] remove from playing tracking list failed: \(error.localizedDescription)")
        }

        NotificationCenter.default.post(
            name: TraktSettingsStore.continueWatchingChangedNotification,
            object: nil
        )
        TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .wetrakr, in: store)
        guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: true) else {
            return false
        }
        return true
    }

    static func finishPlaybackForHistory(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        store: UserDefaults = ProfileSettings.current,
        profileId: String? = nil,
        completionID: String,
        accountID expectedAccountID: String?
    ) async -> Bool {
        let stableCompletionID = completionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let profileID = resolvedProfileID(in: store, explicit: profileId)
        guard UUID(uuidString: stableCompletionID) != nil,
              let expectedAccountID = expectedAccountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expectedAccountID.isEmpty,
              position.isFinite, duration.isFinite, duration > 0,
              let event = WatchedStore.pendingPlaybackCompletions(provider: .wetrakr, profileId: profileID)
                .first(where: { $0.completionID == stableCompletionID }),
              event.accountID == expectedAccountID,
              WatchedStore.sameContent(event.meta, meta),
              event.season == season, event.episode == episode,
              let context = requestContext(
                in: store,
                profileId: profileID,
                expectedAccountID: expectedAccountID,
                requiresWeTrakrSource: true
              ) else {
            return false
        }

        return await withAccountLane(expectedAccountID) {
            guard let currentContext = await refreshedContextIfNeeded(
                context,
                in: store,
                profileId: profileID,
                requiresWeTrakrSource: true
            ),
                  contextIsCurrent(currentContext, in: store, profileId: profileID, requiresWeTrakrSource: true),
                  let currentEvent = WatchedStore.pendingPlaybackCompletions(provider: .wetrakr, profileId: profileID)
                    .first(where: { $0.completionID == stableCompletionID }),
                  currentEvent.accountID == expectedAccountID else {
                return false
            }

            let cancellationKey = cancelledPlaybackKey(
                accountID: expectedAccountID,
                profileId: profileID,
                playbackID: stableCompletionID
            )
            if !cancelledPlaybackIDs.contains(cancellationKey) {
                guard await cancelOwnedLivePlayback(
                    currentEvent,
                    completionID: stableCompletionID,
                    store: store,
                    profileId: profileID,
                    context: currentContext
                ) else { return false }
            }
            let didFlush = await flushPendingPlaybackCompletionsLocked(
                store: store,
                profileId: profileID,
                context: currentContext
            )
            if !WatchedStore.pendingPlaybackCompletions(provider: .wetrakr, profileId: profileID)
                .contains(where: { $0.completionID == stableCompletionID }) {
                cancelledPlaybackIDs.remove(cancellationKey)
            }
            return didFlush
        }
    }

    private static func cancelOwnedLivePlayback(
        _ completion: WatchedPlaybackCompletionUpload,
        completionID: String,
        store: UserDefaults,
        profileId: String?,
        context: WeTrakrRequestContext
    ) async -> Bool {
        guard let owner = livePlaybackOwners[context.accountID],
              owner.playbackID == completionID,
              owner.profileId == profileId,
              owner.season == completion.season,
              owner.episode == completion.episode,
              WatchedStore.sameContent(owner.meta, completion.meta),
              contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: true),
              let idempotencyKey = cancellationIdempotencyKey(for: completionID) else {
            return false
        }

        let ids = wetrakrIDs(for: completion.meta)
        guard ids.hasUsableIdentifier else { return false }
        let payload: WeTrakrCancelPlaybackPayload
        if completion.meta.isSeries {
            guard let season = completion.season, season >= 0,
                  let episode = completion.episode, episode > 0 else { return false }
            payload = WeTrakrCancelPlaybackPayload(
                movie: nil,
                show: WeTrakrMediaPayload(title: completion.meta.name, year: completion.meta.year, ids: ids),
                episode: WeTrakrEpisodePayload(season: season, number: episode)
            )
        } else {
            payload = WeTrakrCancelPlaybackPayload(
                movie: WeTrakrMediaPayload(title: completion.meta.name, year: completion.meta.year, ids: ids),
                show: nil,
                episode: nil
            )
        }

        do {
            let response = try await client.deleteRaw(
                path: "/scrobble/playing",
                body: payload,
                accessToken: context.token,
                clientID: context.clientID,
                idempotencyKey: idempotencyKey
            )
            _ = try response.valueOrThrow()
            guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: true),
                  livePlaybackOwners[context.accountID]?.playbackID == completionID else {
                return false
            }
            livePlaybackOwners.removeValue(forKey: context.accountID)
            cancelledPlaybackIDs.insert(cancelledPlaybackKey(
                accountID: context.accountID,
                profileId: profileId,
                playbackID: completionID
            ))
            return true
        } catch {
            print("[WeTrakrProgressService] owned playback cancellation failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func cancelledPlaybackKey(
        accountID: String,
        profileId: String?,
        playbackID: String
    ) -> String {
        "\(accountID)|\(profileId ?? "default")|\(playbackID)"
    }

    private static func cancellationIdempotencyKey(for playbackID: String) -> String? {
        guard let uuid = UUID(uuidString: playbackID) else { return nil }
        let bytes = uuid.uuid
        var value: [UInt8] = [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15
        ]
        value[0] ^= 0x57
        value[6] = (value[6] & 0x0f) | 0x50
        value[8] = (value[8] & 0x3f) | 0x80
        return UUID(uuid: (
            value[0], value[1], value[2], value[3], value[4], value[5], value[6], value[7],
            value[8], value[9], value[10], value[11], value[12], value[13], value[14], value[15]
        )).uuidString
    }

    private static func cancelOwnedLivePlaybackIfPresent(
        _ completion: WatchedPlaybackCompletionUpload,
        store: UserDefaults,
        profileId: String?,
        context: WeTrakrRequestContext
    ) async -> Bool {
        guard let owner = livePlaybackOwners[context.accountID] else { return true }
        guard owner.playbackID == completion.completionID else { return true }
        guard owner.profileId == profileId,
              owner.season == completion.season,
              owner.episode == completion.episode,
              WatchedStore.sameContent(owner.meta, completion.meta) else {
            return false
        }
        if cancelledPlaybackIDs.contains(cancelledPlaybackKey(
            accountID: context.accountID,
            profileId: profileId,
            playbackID: completion.completionID
        )) {
            return true
        }
        return await cancelOwnedLivePlayback(
            completion,
            completionID: completion.completionID,
            store: store,
            profileId: profileId,
            context: context
        )
    }

    static func flushPendingPlaybackCompletions(
        store: UserDefaults = ProfileSettings.current,
        profileId: String? = nil
    ) async -> Bool {
        let profileID = resolvedProfileID(in: store, explicit: profileId)
        guard let context = requestContext(
                in: store,
                profileId: profileID,
                requiresWeTrakrSource: false
              ) else {
            return false
        }
        return await withAccountLane(context.accountID) {
            guard let currentContext = await refreshedContextIfNeeded(
                context,
                in: store,
                profileId: profileID,
                requiresWeTrakrSource: false
            ) else {
                return false
            }
            return await flushPendingPlaybackCompletionsLocked(
                store: store,
                profileId: profileID,
                context: currentContext,
                requiresWeTrakrSource: false
            )
        }
    }

    private static func flushPendingPlaybackCompletionsLocked(
        store: UserDefaults,
        profileId: String?,
        context: WeTrakrRequestContext,
        requiresWeTrakrSource: Bool = true
    ) async -> Bool {
        let mutations = WatchedStore.pendingProviderMutations(provider: .wetrakr, profileId: profileId)
        for mutation in mutations {
            guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource) else {
                return false
            }
            guard let mutationAccountID = mutation.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !mutationAccountID.isEmpty else {
                continue
            }
            guard mutationAccountID == context.accountID else { continue }
            guard let mutationContext = requestContext(
                in: store,
                profileId: profileId,
                expectedAccountID: mutationAccountID,
                requiresWeTrakrSource: requiresWeTrakrSource
            ), await sendProviderMutation(
                mutation,
                store: store,
                profileId: profileId,
                context: mutationContext,
                requiresWeTrakrSource: requiresWeTrakrSource
            ),
                  contextIsCurrent(mutationContext, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource),
                  WatchedStore.acknowledgeProviderMutation(
                    id: mutation.id,
                    provider: .wetrakr,
                    profileId: profileId
                  ) else {
                return false
            }
        }

        let libraryMutations = WatchedStore.pendingLibraryMutations(
            provider: .wetrakr,
            profileId: profileId,
            readyOnly: true
        )
        for mutation in libraryMutations {
            guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource) else {
                return false
            }
            guard let accountID = mutation.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !accountID.isEmpty,
                  mutation.profileID == profileId else {
                continue
            }
            guard accountID == context.accountID else { continue }
            let didSend = await sendLibraryMutation(
                mutation,
                store: store,
                profileId: profileId,
                context: context,
                requiresWeTrakrSource: requiresWeTrakrSource
            )
            guard didSend else {
                _ = WatchedStore.deferLibraryMutation(
                    id: mutation.id,
                    provider: .wetrakr,
                    accountID: accountID,
                    profileId: profileId
                )
                return false
            }
            guard contextIsCurrent(
                    context,
                    in: store,
                    profileId: profileId,
                    requiresWeTrakrSource: requiresWeTrakrSource
                  ),
                  WatchedStore.acknowledgeLibraryMutation(
                    id: mutation.id,
                    provider: .wetrakr,
                    accountID: accountID,
                    profileId: profileId
                  ) else {
                return false
            }
        }

        let completions = WatchedStore.pendingPlaybackCompletions(provider: .wetrakr, profileId: profileId)
        for completion in completions {
            guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource) else {
                return false
            }
            guard let completionAccountID = completion.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !completionAccountID.isEmpty else {
                continue
            }
            guard completionAccountID == context.accountID else { continue }
            let cancelledLivePlayback: Bool
            if requiresWeTrakrSource {
                cancelledLivePlayback = await cancelOwnedLivePlaybackIfPresent(
                    completion,
                    store: store,
                    profileId: profileId,
                    context: context
                )
            } else {
                cancelledLivePlayback = true
            }
            guard cancelledLivePlayback,
                  await sendPlaybackCompletion(
                    completion,
                    store: store,
                    profileId: profileId,
                    context: context,
                    requiresWeTrakrSource: requiresWeTrakrSource
                  ),
                  contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource),
                  WatchedStore.acknowledgePlaybackCompletion(
                    completionID: completion.completionID,
                    provider: .wetrakr,
                    accountID: completionAccountID,
                    profileId: profileId
                  ) else {
                return false
            }
            cancelledPlaybackIDs.remove(cancelledPlaybackKey(
                accountID: completionAccountID,
                profileId: profileId,
                playbackID: completion.completionID
            ))
        }
        return true
    }

    private static func sendProviderMutation(
        _ mutation: WatchedStore.PendingProviderMutation,
        store: UserDefaults,
        profileId: String?,
        context: WeTrakrRequestContext,
        requiresWeTrakrSource: Bool
    ) async -> Bool {
        do {
            let response: WeTrakrHTTPResult<Data>
            if mutation.isWatched {
                response = try await client.postRaw(
                    path: "/sync/tracking",
                    body: trackingAddPayload(
                        meta: mutation.meta,
                        season: mutation.season,
                        episode: mutation.episode,
                        allowRewatch: false,
                        trackedAt: nil
                    ),
                    accessToken: context.token,
                    clientID: context.clientID,
                    idempotencyKey: mutation.id
                )
            } else {
                response = try await client.postRaw(
                    path: "/sync/tracking/remove/all",
                    body: trackingRemovePayload(
                        meta: mutation.meta,
                        season: mutation.season,
                        episode: mutation.episode
                    ),
                    accessToken: context.token,
                    clientID: context.clientID,
                    idempotencyKey: mutation.id
                )
            }
            _ = try response.valueOrThrow()
            guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource),
                  responseConfirmsProviderMutation(response.rawData, mutation: mutation) else {
                print("[WeTrakrProgressService] provider mutation \(mutation.id) is not yet confirmed")
                return false
            }
            return true
        } catch {
            print("[WeTrakrProgressService] provider mutation \(mutation.id) failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func sendLibraryMutation(
        _ mutation: WatchedLibraryMutationUpload,
        store: UserDefaults,
        profileId: String?,
        context: WeTrakrRequestContext,
        requiresWeTrakrSource: Bool
    ) async -> Bool {
        guard wetrakrIDs(for: mutation.meta).hasUsableIdentifier else { return false }
        let episodes = mutation.episodes.isEmpty
            ? mutation.episode.map { [$0] } ?? []
            : mutation.episodes
        let confirmation = WatchedStore.PendingProviderMutation(
            id: mutation.id,
            provider: .wetrakr,
            accountID: mutation.accountID,
            meta: mutation.meta,
            season: mutation.season,
            episode: episodes.count == 1 ? episodes[0] : nil,
            isWatched: mutation.isWatched,
            changedAt: mutation.changedAt
        )
        do {
            let response: WeTrakrHTTPResult<Data>
            if mutation.isWatched {
                response = try await client.postRaw(
                    path: "/sync/tracking",
                    body: trackingAddPayload(
                        meta: mutation.meta,
                        season: mutation.season,
                        episode: mutation.episode,
                        episodes: mutation.episodes,
                        allowRewatch: false,
                        trackedAt: nil
                    ),
                    accessToken: context.token,
                    clientID: context.clientID,
                    idempotencyKey: mutation.id
                )
            } else {
                response = try await client.postRaw(
                    path: "/sync/tracking/remove/all",
                    body: trackingRemovePayload(
                        meta: mutation.meta,
                        season: mutation.season,
                        episode: mutation.episode,
                        episodes: mutation.episodes
                    ),
                    accessToken: context.token,
                    clientID: context.clientID,
                    idempotencyKey: mutation.id
                )
            }
            _ = try response.valueOrThrow()
            guard contextIsCurrent(
                context,
                in: store,
                profileId: profileId,
                requiresWeTrakrSource: requiresWeTrakrSource
            ), responseConfirmsProviderMutation(response.rawData, mutation: confirmation) else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private static func sendPlaybackCompletion(
        _ completion: WatchedPlaybackCompletionUpload,
        store: UserDefaults,
        profileId: String?,
        context: WeTrakrRequestContext,
        requiresWeTrakrSource: Bool
    ) async -> Bool {
        guard let trackedAt = iso8601String(completion.watchedAt),
              let payload = completionTrackingPayload(completion, trackedAt: trackedAt) else {
            return false
        }

        do {
            let response = try await client.postRaw(
                path: "/sync/tracking",
                body: payload,
                accessToken: context.token,
                clientID: context.clientID,
                idempotencyKey: completion.completionID
            )
            _ = try response.valueOrThrow()
            guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource) else {
                return false
            }

            if matchingAddedPlayID(in: response.rawData, for: completion) != nil {
                return true
            }
            guard isCompletionDuplicate(in: response.rawData, for: completion) else {
                print("[WeTrakrProgressService] completion \(completion.completionID) returned no matching play")
                return false
            }

            guard WatchedStore.acknowledgePlaybackCompletion(
                completionID: completion.completionID,
                provider: .wetrakr,
                accountID: completion.accountID,
                profileId: profileId
            ) else { return false }
            _ = await syncWatchedHistoryLocked(
                store: store,
                profileId: profileId,
                context: context,
                drainPendingBeforeSnapshot: false
            )
            return true
        } catch {
            print("[WeTrakrProgressService] completion \(completion.completionID) failed: \(error.localizedDescription)")
            return false
        }
    }

    private static func trackingAddPayload(
        meta: NuvioMeta,
        season: Int?,
        episode: Int?,
        episodes: [Int] = [],
        allowRewatch: Bool,
        trackedAt: String?
    ) -> WeTrakrTrackingAddPayload {
        let ids = wetrakrIDs(for: meta)
        guard meta.isSeries else {
            return WeTrakrTrackingAddPayload(
                movies: [WeTrakrMediaPayload(
                    title: meta.name,
                    year: meta.year,
                    ids: ids,
                    status: "watched",
                    trackedAt: trackedAt
                )],
                allowRewatch: allowRewatch
            )
        }

        let episodePayload: [WeTrakrEpisodeTrackingPayload]? = {
            let numbers = episodes.isEmpty ? episode.map { [$0] } ?? [] : episodes
            guard !numbers.isEmpty, numbers.allSatisfy({ $0 > 0 }) else { return nil }
            return numbers.sorted().map {
                WeTrakrEpisodeTrackingPayload(number: $0, status: "watched", trackedAt: trackedAt)
            }
        }()
        let seasonPayload: [WeTrakrSeasonTrackingPayload]? = {
            guard let season, season >= 0 else { return nil }
            return [WeTrakrSeasonTrackingPayload(
                number: season,
                status: episodePayload == nil ? "watched" : nil,
                episodes: episodePayload
            )]
        }()
        let showStatus = seasonPayload == nil ? "watched" : nil
        return WeTrakrTrackingAddPayload(
            shows: [WeTrakrShowTrackingPayload(
                title: meta.name,
                year: meta.year,
                ids: ids,
                status: showStatus,
                seasons: seasonPayload
            )],
            allowRewatch: allowRewatch
        )
    }

    private static func completionTrackingPayload(
        _ completion: WatchedPlaybackCompletionUpload,
        trackedAt: String
    ) -> WeTrakrTrackingAddPayload? {
        guard wetrakrIDs(for: completion.meta).hasUsableIdentifier else { return nil }
        if completion.meta.isSeries {
            guard let season = completion.season, season >= 0,
                  let episode = completion.episode, episode > 0 else { return nil }
        }
        return trackingAddPayload(
            meta: completion.meta,
            season: completion.season,
            episode: completion.episode,
            allowRewatch: true,
            trackedAt: trackedAt
        )
    }

    private static func trackingRemovePayload(
        meta: NuvioMeta,
        season: Int?,
        episode: Int?,
        episodes: [Int] = []
    ) -> WeTrakrTrackingRemovePayload {
        let ids = wetrakrIDs(for: meta)
        guard meta.isSeries else {
            return WeTrakrTrackingRemovePayload(movies: [WeTrakrMediaPayload(
                title: meta.name,
                year: meta.year,
                ids: ids,
                status: "watched"
            )])
        }
        let episodeNumbers = episodes.isEmpty ? episode.map { [$0] } ?? [] : episodes
        let episodePayload: [WeTrakrEpisodeTrackingPayload]? = episodeNumbers.isEmpty
            ? nil
            : episodeNumbers.sorted().map { WeTrakrEpisodeTrackingPayload(number: $0, status: "watched") }
        let seasons: [WeTrakrSeasonTrackingPayload]? = season.map {
            [WeTrakrSeasonTrackingPayload(
                number: $0,
                status: episodePayload == nil ? "watched" : nil,
                episodes: episodePayload
            )]
        }
        return WeTrakrTrackingRemovePayload(shows: [WeTrakrShowTrackingPayload(
            title: meta.name,
            year: meta.year,
            ids: ids,
            status: seasons == nil ? "watched" : nil,
            seasons: seasons
        )])
    }

    private static func resolvedProfileID(in store: UserDefaults, explicit profileId: String?) -> String? {
        if let profileId {
            let value = profileId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        if let value = store.string(forKey: "nuvio.tv.profile.settings.profileID")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if let value = ProfileSettings.activeProfileID,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return nil
    }

    private static func iso8601String(_ date: Date) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func scalarString(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func hasEntries(_ value: Any?) -> Bool {
        if let values = value as? [Any] { return !values.isEmpty }
        guard let object = value as? [String: Any] else { return false }
        if let total = object["total"] as? NSNumber, total.intValue > 0 { return true }
        return object.values.contains { hasEntries($0) }
    }

    private static func errorMessages(in value: Any?) -> [String] {
        if let values = value as? [Any] { return values.flatMap { errorMessages(in: $0) } }
        guard let object = value as? [String: Any] else { return [] }
        var messages = (object["error"] as? String).map { [$0] } ?? []
        for (key, child) in object where key != "error" {
            messages.append(contentsOf: errorMessages(in: child))
        }
        return messages
    }

    private static func responseConfirmsProviderMutation(
        _ data: Data,
        mutation: WatchedStore.PendingProviderMutation
    ) -> Bool {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              !hasEntries(json["notFound"]) else { return false }
        let errors = errorMessages(in: json["errored"])
        if !errors.isEmpty {
            if mutation.isWatched {
                return errors.allSatisfy { $0.caseInsensitiveCompare("Already watched!") == .orderedSame }
            }
            return errors.allSatisfy { $0.caseInsensitiveCompare("Nothing to remove") == .orderedSame }
        }
        return hasEntries(json[mutation.isWatched ? "added" : "removed"])
            || (mutation.isWatched && hasEntries(json["existing"]))
    }

    private static func matchingAddedPlayID(
        in data: Data,
        for completion: WatchedPlaybackCompletionUpload
    ) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let added = json["added"] as? [String: Any],
              let plays = added["plays"] as? [[String: Any]] else { return nil }
        for play in plays {
            guard let playID = scalarString(play["play_id"]), !playID.isEmpty,
                  playMatchesCompletion(play, completion: completion) else { continue }
            return playID
        }
        return nil
    }

    private static func playMatchesCompletion(
        _ play: [String: Any],
        completion: WatchedPlaybackCompletionUpload
    ) -> Bool {
        let expectedType = completion.meta.isSeries ? "episode" : "movie"
        guard (play["type"] as? String)?.lowercased() == expectedType,
              let watchedAtText = play["watched_at"] as? String,
              let watchedAt = dateFromISO8601(watchedAtText),
              abs(watchedAt.timeIntervalSince(completion.watchedAt)) < 1 else { return false }

        let ids = wetrakrIDs(for: completion.meta)
        if completion.meta.isSeries {
            guard let season = completion.season, let episode = completion.episode,
                  (play["season_number"] as? NSNumber)?.intValue == season,
                  (play["number"] as? NSNumber)?.intValue == episode else { return false }
            if let expectedShowID = ids.wetrakr,
               (play["show_id"] as? NSNumber)?.intValue != expectedShowID { return false }
        } else if let expectedMovieID = ids.wetrakr,
                  (play["id"] as? NSNumber)?.intValue != expectedMovieID {
            return false
        }
        return true
    }

    private static func isCompletionDuplicate(
        in data: Data,
        for completion: WatchedPlaybackCompletionUpload
    ) -> Bool {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let errored = json["errored"] else { return false }
        let expectedBucket = completion.meta.isSeries ? "episodes" : "movies"
        let entries = entries(in: errored, under: expectedBucket)
        return entries.contains { entry in
            let error = (entry["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard error == "already added!"
                    || error == "already added! a play within the hour counts as the same watch"
                    || error == "already added! a play within the hour counts as the same watch (on the same day, for a date without a time of day)" else {
                return false
            }
            if let type = entry["type"] as? String {
                let expectedType = completion.meta.isSeries ? "episode" : "movie"
                guard type.lowercased() == expectedType else { return false }
            }
            if completion.meta.isSeries {
                if let expectedSeason = completion.season,
                   let season = entry["season"] as? NSNumber,
                   season.intValue != expectedSeason { return false }
                if let expectedEpisode = completion.episode,
                   let number = entry["number"] as? NSNumber,
                   number.intValue != expectedEpisode { return false }
            }
            if let trackedAt = entry["tracked_at"] as? String,
               let date = dateFromISO8601(trackedAt),
               abs(date.timeIntervalSince(completion.watchedAt)) >= 1 { return false }
            return true
        }
    }

    private static func entries(in value: Any, under key: String) -> [[String: Any]] {
        if let object = value as? [String: Any] {
            var found = object[key] as? [[String: Any]] ?? []
            for child in object.values {
                found.append(contentsOf: entries(in: child, under: key))
            }
            return found
        }
        if let array = value as? [Any] {
            return array.flatMap { entries(in: $0, under: key) }
        }
        return []
    }

    private static var externalIDCache: [String: String] = [:]
    private static let externalIDLock = NSLock()

    static func resolveExternalID(
        wetrakrID: String,
        isSeries: Bool,
        token: String,
        clientID: String
    ) async -> String? {
        let cacheKey = "\(isSeries ? "series" : "movie"):\(wetrakrID)"
        let cached = externalIDLock.withLock { externalIDCache[cacheKey] }
        if let cached {
            return cached
        }

        let endpoint = isSeries ? "/shows/\(wetrakrID)" : "/movies/\(wetrakrID)"
        let result: WeTrakrHTTPResult<WeTrakrMediaDTO> = (try? await client.get(
            path: endpoint,
            accessToken: token,
            clientID: clientID
        )) ?? WeTrakrHTTPResult(statusCode: 500, value: nil, rawData: Data(), errorMessage: nil)

        if let media = try? result.valueOrThrow() {
            let resolved: String? = {
                if let imdb = media.ids?.imdb, !imdb.isEmpty { return imdb }
                if let tmdb = media.ids?.tmdb { return "tmdb:\(tmdb)" }
                if let tvdb = media.ids?.tvdb { return "tvdb:\(tvdb)" }
                return nil
            }()
            if let resolved {
                externalIDLock.withLock {
                    externalIDCache[cacheKey] = resolved
                }
                return resolved
            }
        }
        return nil
    }

    static func fetchContinueWatching(
        repository: CatalogRepository,
        store: UserDefaults = ProfileSettings.current
    ) async -> [ContinueWatchingItem]? {
        guard let token = WeTrakrRuntimeSession.authenticatedState(store: store)?.accessToken,
              !token.isEmpty else {
            return []
        }

        let clientID = WeTrakrConfig.clientID(in: store)
        let extendedQuery = [URLQueryItem(name: "extended", value: "show_level_1,episode_level_1,movie_level_1")]

        async let moviesResult: WeTrakrHTTPResult<[WeTrakrTrackingPlayingItemDTO]> = client.get(
            path: "/sync/tracking/playing/movies",
            accessToken: token,
            clientID: clientID,
            queryItems: extendedQuery
        )
        async let episodesResult: WeTrakrHTTPResult<[WeTrakrTrackingPlayingItemDTO]> = client.get(
            path: "/sync/tracking/playing/episodes",
            accessToken: token,
            clientID: clientID,
            queryItems: extendedQuery
        )
        async let playingNowResult: WeTrakrHTTPResult<WeTrakrTrackingPlayingItemDTO> = client.get(
            path: "/scrobble/playing",
            accessToken: token,
            clientID: clientID
        )

        var rawItems: [WeTrakrTrackingPlayingItemDTO] = []
        var hadSuccessfulRequest = false

        if let movies = try? await moviesResult.valueOrThrow() {
            rawItems.append(contentsOf: movies)
            hadSuccessfulRequest = true
        }
        if let episodes = try? await episodesResult.valueOrThrow() {
            rawItems.append(contentsOf: episodes)
            hadSuccessfulRequest = true
        }
        if let playingNow = try? await playingNowResult.valueOrThrow(),
           let status = playingNow.status, status != "none" {
            rawItems.append(playingNow)
            hadSuccessfulRequest = true
        }

        guard hadSuccessfulRequest else {
            return nil
        }

        struct PlaybackPlan {
            let index: Int
            let placeholder: NuvioMeta
            let isSeries: Bool
            let season: Int?
            let episode: Int?
            let episodeTitle: String?
            let progressPercent: Double
            let runtimeSeconds: Double?
            let lastWatchedAt: Date
            let identity: String
        }

        var plans: [PlaybackPlan] = []
        var seenIdentities = Set<String>()
        var seenTitleKeys = Set<String>()

        for item in rawItems {
            let media = item.resolvedMedia
            guard media.id != nil || media.ids?.hasUsableIdentifier == true else { continue }
            guard let progress = item.resolvedProgressPercent,
                  progress > 0, progress < 90 else { continue }

            let isSeries = item.resolvedIsSeries
            let placeholder = makeNuvioMeta(from: media, isSeries: isSeries)
            let season = item.resolvedSeasonNumber
            let episode = item.resolvedEpisodeNumber
            let identity = "\(isSeries ? "series" : "movie"):\(placeholder.id):\(season ?? -1):\(episode ?? -1)"

            guard seenIdentities.insert(identity).inserted else { continue }

            let titleKey = WatchedStore.normalizedCatalogTitle(placeholder.name)
            if !titleKey.isEmpty {
                let dedupeTitleKey = "\(isSeries ? "series" : "movie"):\(titleKey):\(season ?? -1):\(episode ?? -1)"
                guard seenTitleKeys.insert(dedupeTitleKey).inserted else { continue }
            }

            plans.append(
                PlaybackPlan(
                    index: plans.count,
                    placeholder: placeholder,
                    isSeries: isSeries,
                    season: season,
                    episode: episode,
                    episodeTitle: item.resolvedEpisodeTitle,
                    progressPercent: progress,
                    runtimeSeconds: item.resolvedRuntimeSeconds,
                    lastWatchedAt: item.resolvedLastWatchedAt,
                    identity: identity
                )
            )
        }

        let sortedPlans = plans.sorted { $0.lastWatchedAt > $1.lastWatchedAt }
        let plansToResolve = Array(sortedPlans.prefix(25))

        let resolvedItems = await withTaskGroup(of: (Int, ContinueWatchingItem?).self) { group in
            for (orderIndex, plan) in plansToResolve.enumerated() {
                group.addTask { @MainActor in
                    var targetId = plan.placeholder.id
                    if targetId.hasPrefix("wetrakr:") {
                        let rawNum = String(targetId.dropFirst("wetrakr:".count))
                        if let resolved = await resolveExternalID(
                            wetrakrID: rawNum,
                            isSeries: plan.isSeries,
                            token: token,
                            clientID: clientID
                        ) {
                            targetId = resolved
                        }
                    }

                    let loaded: NuvioMeta?
                    if targetId.hasPrefix("wetrakr:") {
                        loaded = nil
                    } else {
                        loaded = try? await repository.getMetadata(
                            id: targetId,
                            type: plan.isSeries ? "series" : "movie"
                        )
                    }

                    let meta: NuvioMeta = {
                        guard let loaded else { return plan.placeholder }
                        let loadedNameIsFallback = loaded.name.isEmpty
                            || loaded.name == targetId
                            || loaded.name == plan.placeholder.id
                            || loaded.name.allSatisfy { $0.isNumber || $0 == " " }
                        var result = loaded
                        if loadedNameIsFallback,
                           !plan.placeholder.name.isEmpty,
                           !plan.placeholder.name.allSatisfy({ $0.isNumber || $0 == " " }) {
                            result = NuvioMeta(
                                id: result.id,
                                name: plan.placeholder.name,
                                description: result.description ?? plan.placeholder.description,
                                posterUrl: result.posterUrl ?? plan.placeholder.posterUrl,
                                backgroundUrl: result.backgroundUrl ?? plan.placeholder.backgroundUrl,
                                logoUrl: result.logoUrl ?? plan.placeholder.logoUrl,
                                imdbId: result.imdbId ?? plan.placeholder.imdbId,
                                tmdbId: result.tmdbId ?? plan.placeholder.tmdbId,
                                type: result.type,
                                year: result.year ?? plan.placeholder.year,
                                genres: result.genres ?? plan.placeholder.genres,
                                rating: result.rating ?? plan.placeholder.rating,
                                releaseInfo: result.releaseInfo ?? plan.placeholder.releaseInfo,
                                runtime: result.runtime ?? plan.placeholder.runtime,
                                cast: result.cast ?? plan.placeholder.cast,
                                director: result.director ?? plan.placeholder.director,
                                writer: result.writer ?? plan.placeholder.writer,
                                certification: result.certification ?? plan.placeholder.certification,
                                country: result.country ?? plan.placeholder.country,
                                language: result.language ?? plan.placeholder.language,
                                released: result.released ?? plan.placeholder.released,
                                status: result.status ?? plan.placeholder.status,
                                videos: result.videos ?? plan.placeholder.videos,
                                trailerYtIds: result.trailerYtIds ?? plan.placeholder.trailerYtIds,
                                externalRatings: result.externalRatings ?? plan.placeholder.externalRatings,
                                posterShape: result.posterShape ?? plan.placeholder.posterShape
                            )
                        } else if (result.posterUrl == nil || result.posterUrl?.isEmpty == true),
                                  let placeholderPoster = plan.placeholder.posterUrl, !placeholderPoster.isEmpty {
                            result = NuvioMeta(
                                id: result.id,
                                name: result.name,
                                description: result.description,
                                posterUrl: placeholderPoster,
                                backgroundUrl: result.backgroundUrl ?? plan.placeholder.backgroundUrl,
                                logoUrl: result.logoUrl,
                                imdbId: result.imdbId,
                                tmdbId: result.tmdbId,
                                type: result.type,
                                year: result.year,
                                genres: result.genres,
                                rating: result.rating,
                                releaseInfo: result.releaseInfo,
                                runtime: result.runtime,
                                cast: result.cast,
                                director: result.director,
                                writer: result.writer,
                                certification: result.certification,
                                country: result.country,
                                language: result.language,
                                released: result.released,
                                status: result.status,
                                videos: result.videos,
                                trailerYtIds: result.trailerYtIds,
                                externalRatings: result.externalRatings,
                                posterShape: result.posterShape
                            )
                        }
                        return result
                    }()

                    let duration: Double = {
                        if let r = loaded?.runtime, let rNum = Double(r), rNum > 0 {
                            return rNum > 600 ? rNum : rNum * 60.0
                        }
                        if let r = plan.runtimeSeconds, r > 0 {
                            return r
                        }
                        return plan.isSeries ? 2700.0 : 7200.0
                    }()
                    let position = max(1.0, min(duration * (plan.progressPercent / 100.0), max(duration - 5.0, 1.0)))

                    let item = ContinueWatchingItem(
                        meta: meta,
                        streamUrl: "",
                        position: position,
                        duration: duration,
                        lastWatchedAt: plan.lastWatchedAt,
                        season: plan.season,
                        episode: plan.episode,
                        released: nil,
                        episodeTitleOverride: plan.episodeTitle,
                        episodeOverviewOverride: nil,
                        episodeThumbnailOverride: nil,
                        isUpNext: false
                    )
                    return (orderIndex, item)
                }
            }

            var rows: [(Int, ContinueWatchingItem)] = []
            for await (idx, item) in group {
                if let item {
                    rows.append((idx, item))
                }
            }
            return rows.sorted { $0.0 < $1.0 }.map(\.1)
        }

        return resolvedItems
    }

    static func markWatched(
        meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil,
        episodes: [Int]? = nil,
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        guard let token = WeTrakrRuntimeSession.authenticatedState(store: store)?.accessToken,
              !token.isEmpty else { return false }
        let clientID = WeTrakrConfig.clientID(in: store)
        let ids = wetrakrIDs(for: meta)
        guard ids.hasUsableIdentifier else { return false }

        let payload: WeTrakrTrackingAddPayload
        if meta.isSeries {
            let episodeList: [Int]? = {
                if let episodes, !episodes.isEmpty { return episodes }
                if let ep = episode { return [ep] }
                return nil
            }()

            let seasonsPayload: [WeTrakrSeasonTrackingPayload]? = {
                guard let s = season else { return nil }
                if let eps = episodeList {
                    return [
                        WeTrakrSeasonTrackingPayload(
                            number: s,
                            status: "watched",
                            episodes: eps.map { WeTrakrEpisodeTrackingPayload(number: $0, status: "watched") }
                        )
                    ]
                } else {
                    return [
                        WeTrakrSeasonTrackingPayload(
                            number: s,
                            status: "watched",
                            episodes: nil
                        )
                    ]
                }
            }()

            payload = WeTrakrTrackingAddPayload(
                movies: nil,
                shows: [
                    WeTrakrShowTrackingPayload(
                        title: meta.name,
                        year: meta.year,
                        ids: ids,
                        status: "watched",
                        seasons: seasonsPayload
                    )
                ],
                allowRewatch: false
            )
        } else {
            payload = WeTrakrTrackingAddPayload(
                movies: [WeTrakrMediaPayload(title: meta.name, year: meta.year, ids: ids, status: "watched")],
                shows: nil,
                allowRewatch: false
            )
        }

        do {
            let result: WeTrakrHTTPResult<Data> = try await client.postRaw(
                path: "/sync/tracking",
                body: payload,
                accessToken: token,
                clientID: clientID
            )
            _ = try result.valueOrThrow()
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .wetrakr, in: store)
            return true
        } catch {
            print("[WeTrakrProgressService] markWatched failed: \(error.localizedDescription)")
            return false
        }
    }

    static func markUnwatched(
        meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil,
        episodes: [Int]? = nil,
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        guard let token = WeTrakrRuntimeSession.authenticatedState(store: store)?.accessToken,
              !token.isEmpty else { return false }
        let clientID = WeTrakrConfig.clientID(in: store)
        let ids = wetrakrIDs(for: meta)
        guard ids.hasUsableIdentifier else { return false }

        let payload: WeTrakrTrackingRemovePayload
        if meta.isSeries {
            let episodeList: [Int]? = {
                if let episodes, !episodes.isEmpty { return episodes }
                if let ep = episode { return [ep] }
                return nil
            }()

            let seasonsPayload: [WeTrakrSeasonTrackingPayload]? = {
                guard let s = season else { return nil }
                if let eps = episodeList {
                    return [
                        WeTrakrSeasonTrackingPayload(
                            number: s,
                            status: "watched",
                            episodes: eps.map { WeTrakrEpisodeTrackingPayload(number: $0, status: "watched") }
                        )
                    ]
                } else {
                    return [
                        WeTrakrSeasonTrackingPayload(
                            number: s,
                            status: "watched",
                            episodes: nil
                        )
                    ]
                }
            }()

            payload = WeTrakrTrackingRemovePayload(
                movies: nil,
                shows: [
                    WeTrakrShowTrackingPayload(
                        title: meta.name,
                        year: meta.year,
                        ids: ids,
                        status: "watched",
                        seasons: seasonsPayload
                    )
                ]
            )
        } else {
            payload = WeTrakrTrackingRemovePayload(
                movies: [WeTrakrMediaPayload(title: meta.name, year: meta.year, ids: ids, status: "watched")],
                shows: nil
            )
        }

        do {
            let result: WeTrakrHTTPResult<Data> = try await client.postRaw(
                path: "/sync/tracking/remove/all",
                body: payload,
                accessToken: token,
                clientID: clientID
            )
            _ = try result.valueOrThrow()
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .wetrakr, in: store)
            return true
        } catch {
            print("[WeTrakrProgressService] markUnwatched failed: \(error.localizedDescription)")
            return false
        }
    }

    static func markSeasonWatched(
        meta: NuvioMeta,
        season: Int,
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        await markWatched(meta: meta, season: season, episode: nil, episodes: nil, store: store)
    }

    static func markSeasonUnwatched(
        meta: NuvioMeta,
        season: Int,
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        await markUnwatched(meta: meta, season: season, episode: nil, episodes: nil, store: store)
    }

    private static var previousWatchedSnapshots: [String: [WatchedStoreItem]] = [:]

    private static func fetchHistoryPages<Item: Decodable>(
        path: String,
        extended: String,
        store: UserDefaults,
        profileId: String?,
        context: WeTrakrRequestContext,
        requiresWeTrakrSource: Bool = true,
        identity: (Item) -> String?
    ) async -> (items: [Item], complete: Bool) {
        var items: [Item] = []
        var seenItems = Set<String>()
        var reportedPageCount: Int?
        var complete = true
        var page = 1

        while true {
            guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource) else {
                return (items, false)
            }
            let query = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "extended", value: extended)
            ]
            let response: WeTrakrHTTPResult<[Item]>
            do {
                response = try await client.get(
                    path: path,
                    accessToken: context.token,
                    clientID: context.clientID,
                    queryItems: query
                )
            } catch {
                return (items, false)
            }
            guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource),
                  let pageItems = try? response.valueOrThrow() else {
                return (items, false)
            }

            if let headerPage = response.headers["x-pagination-page"].flatMap({ Int($0) }), headerPage != page {
                return (items, false)
            }
            if let pageCount = response.headers["x-pagination-page-count"].flatMap({ Int($0) }) {
                guard pageCount >= page,
                      reportedPageCount == nil || reportedPageCount == pageCount else {
                    return (items, false)
                }
                reportedPageCount = pageCount
            }

            var newlySeenCount = 0
            for item in pageItems {
                if let itemID = identity(item)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !itemID.isEmpty {
                    if seenItems.insert(itemID).inserted { newlySeenCount += 1 }
                } else {
                    complete = false
                }
            }
            items.append(contentsOf: pageItems)
            if !pageItems.isEmpty, newlySeenCount == 0 {
                return (items, false)
            }
            if pageItems.isEmpty {
                if let reportedPageCount, page < reportedPageCount { complete = false }
                return (items, complete)
            }
            if let reportedPageCount, page >= reportedPageCount {
                return (items, complete)
            }
            let effectiveLimit = response.headers["x-pagination-limit"]
                .flatMap { Int($0) }
                .map { min(max($0, 1), 100) } ?? 100
            if pageItems.count < effectiveLimit {
                if let reportedPageCount, page < reportedPageCount { return (items, false) }
                return (items, complete)
            }
            guard page < Int.max else { return (items, false) }
            page += 1
        }
    }

    private static func historyIdentityKeys(
        for meta: NuvioMeta,
        season: Int?,
        episode: Int?
    ) -> [String] {
        let ids = wetrakrIDs(for: meta)
        var aliases: [String] = []
        if let imdb = ids.imdb, !imdb.isEmpty { aliases.append("imdb:\(imdb.lowercased())") }
        if let tmdb = ids.tmdb { aliases.append("tmdb:\(tmdb)") }
        if let tvdb = ids.tvdb { aliases.append("tvdb:\(tvdb)") }
        if let wetrakr = ids.wetrakr { aliases.append("wetrakr:\(wetrakr)") }
        guard !aliases.isEmpty else { return [] }
        let type = meta.isSeries ? "series" : "movie"
        let coordinates = meta.isSeries ? ":s\(season ?? -1)e\(episode ?? -1)" : ""
        return Array(Set(aliases.map { "\(type):\($0)\(coordinates)" })).sorted()
    }

    @discardableResult
    private static func addHistoryItem(
        meta: NuvioMeta,
        season: Int?,
        episode: Int?,
        watchedAt: Date,
        incrementsPlayCount: Bool,
        groups: inout [String: WatchedStoreItem],
        aliasToGroup: inout [String: String]
    ) -> Bool {
        let keys = historyIdentityKeys(for: meta, season: season, episode: episode)
        guard let firstKey = keys.first else { return false }
        let matchingGroups = Set(keys.compactMap { aliasToGroup[$0] })
        let groupKey = matchingGroups.sorted().first ?? firstKey
        var item = groups[groupKey] ?? WatchedStoreItem(
            meta: meta.persistenceSnapshot,
            watchedAt: watchedAt,
            season: season,
            episode: episode,
            sources: [TraktWatchProgressSource.wetrakr.rawValue],
            watchCountsBySource: [TraktWatchProgressSource.wetrakr.rawValue: 0]
        )
        var latestMeta = item.meta
        var latestWatchedAt = item.watchedAt

        for otherKey in matchingGroups where otherKey != groupKey {
            guard let other = groups.removeValue(forKey: otherKey) else { continue }
            let source = TraktWatchProgressSource.wetrakr.rawValue
            item.watchCountsBySource[source, default: 0] += other.watchCountsBySource[source] ?? 0
            item.sources.formUnion(other.sources)
            if other.watchedAt > latestWatchedAt {
                latestWatchedAt = other.watchedAt
                latestMeta = other.meta
            }
        }

        let source = TraktWatchProgressSource.wetrakr.rawValue
        if incrementsPlayCount {
            item.watchCountsBySource[source, default: 0] += 1
        } else {
            item.watchCountsBySource[source] = max(1, item.watchCountsBySource[source] ?? 0)
        }
        item.sources.insert(source)
        if watchedAt >= latestWatchedAt {
            latestMeta = meta.persistenceSnapshot
            latestWatchedAt = watchedAt
        }
        groups[groupKey] = WatchedStoreItem(
            meta: latestMeta,
            watchedAt: latestWatchedAt,
            season: item.season,
            episode: item.episode,
            sources: item.sources,
            watchCountsBySource: item.watchCountsBySource,
            lastCountedPlaybackIDsBySource: item.lastCountedPlaybackIDsBySource,
            pendingPlaybackCompletions: item.pendingPlaybackCompletions
        )

        let aliasesToRepoint = aliasToGroup.compactMap { alias, group in
            matchingGroups.contains(group) ? alias : nil
        }
        for alias in aliasesToRepoint { aliasToGroup[alias] = groupKey }
        for key in keys { aliasToGroup[key] = groupKey }
        return true
    }

    @discardableResult
    static func syncWatchedHistory(
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        let profileId = resolvedProfileID(in: store, explicit: nil)
        let selectedForPlayback = TraktSettingsStore.watchProgressSource(in: store) == .wetrakr
        let selectedForLibrary = TraktSettingsStore.librarySourceMode(in: store) == .wetrakr
        let enabledForScrobble = RemoteTrackingState.isScrobbleEnabled(for: .wetrakr, in: store)
        guard selectedForPlayback || selectedForLibrary || enabledForScrobble else { return false }
        guard let context = requestContext(
            in: store,
            profileId: profileId,
            requiresWeTrakrSource: false
        ) else { return false }
        return await withAccountLane(context.accountID) {
            guard let currentContext = await refreshedContextIfNeeded(
                context,
                in: store,
                profileId: profileId,
                requiresWeTrakrSource: false
            ) else {
                return false
            }
            return await syncWatchedHistoryLocked(
                store: store,
                profileId: profileId,
                context: currentContext,
                requiresWeTrakrSource: false
            )
        }
    }

    private static func syncWatchedHistoryLocked(
        store: UserDefaults,
        profileId: String?,
        context: WeTrakrRequestContext,
        drainPendingBeforeSnapshot: Bool = true,
        requiresWeTrakrSource: Bool = true
    ) async -> Bool {
        if drainPendingBeforeSnapshot {
            _ = await flushPendingPlaybackCompletionsLocked(
                store: store,
                profileId: profileId,
                context: context,
                requiresWeTrakrSource: requiresWeTrakrSource
            )
            guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource) else {
                return false
            }
        }
        let syncStartedAt = Date()
        let movieHistory = await fetchHistoryPages(
            path: "/sync/tracking/watched/history/movies",
            extended: "movie_level_1",
            store: store,
            profileId: profileId,
            context: context,
            requiresWeTrakrSource: requiresWeTrakrSource,
            identity: { $0.playID ?? $0.id }
        ) as (items: [WeTrakrTrackingHistoryItemDTO], complete: Bool)
        let movieList = await fetchHistoryPages(
            path: "/sync/tracking/watched/movies",
            extended: "movie_level_1",
            store: store,
            profileId: profileId,
            context: context,
            requiresWeTrakrSource: requiresWeTrakrSource,
            identity: { item in
                let meta = makeNuvioMeta(from: item.resolvedMedia, isSeries: false)
                return historyIdentityKeys(for: meta, season: nil, episode: nil).first
            }
        ) as (items: [WeTrakrTrackingPlayingItemDTO], complete: Bool)
        let episodeHistory = await fetchHistoryPages(
            path: "/sync/tracking/watched/history/episodes",
            extended: "show_level_1,episode_level_1",
            store: store,
            profileId: profileId,
            context: context,
            requiresWeTrakrSource: requiresWeTrakrSource,
            identity: { $0.playID ?? $0.id }
        ) as (items: [WeTrakrTrackingHistoryItemDTO], complete: Bool)

        var authoritative = movieHistory.complete && movieList.complete && episodeHistory.complete
        var groups: [String: WatchedStoreItem] = [:]
        var aliasToGroup: [String: String] = [:]
        var seenMoviePlays = Set<String>()
        var seenEpisodePlays = Set<String>()

        for play in movieHistory.items {
            guard let playID = (play.playID ?? play.id)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !playID.isEmpty else {
                authoritative = false
                continue
            }
            guard seenMoviePlays.insert(playID).inserted else { continue }
            guard let media = play.movie ?? play.media,
                  media.id != nil || media.ids?.hasUsableIdentifier == true,
                  let watchedAt = dateFromISO8601(play.watchedAt) else {
                authoritative = false
                continue
            }
            let meta = makeNuvioMeta(from: media, isSeries: false)
            guard addHistoryItem(
                meta: meta,
                season: nil,
                episode: nil,
                watchedAt: watchedAt,
                incrementsPlayCount: true,
                groups: &groups,
                aliasToGroup: &aliasToGroup
            ) else { authoritative = false; continue }
        }

        for item in movieList.items {
            let media = item.resolvedMedia
            guard media.id != nil || media.ids?.hasUsableIdentifier == true,
                  let watchedAt = dateFromISO8601(item.watchedAt ?? item.trackedAt ?? item.updatedAt) else {
                authoritative = false
                continue
            }
            let meta = makeNuvioMeta(from: media, isSeries: false)
            guard addHistoryItem(
                meta: meta,
                season: nil,
                episode: nil,
                watchedAt: watchedAt,
                incrementsPlayCount: false,
                groups: &groups,
                aliasToGroup: &aliasToGroup
            ) else { authoritative = false; continue }
        }

        for play in episodeHistory.items {
            guard let playID = (play.playID ?? play.id)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !playID.isEmpty else {
                authoritative = false
                continue
            }
            guard seenEpisodePlays.insert(playID).inserted else { continue }
            guard let episode = play.episode,
                  let show = episode.show ?? play.media,
                  show.id != nil || show.ids?.hasUsableIdentifier == true,
                  let season = episode.seasonNumber ?? episode.season,
                  season >= 0,
                  let number = episode.number,
                  number > 0,
                  let watchedAt = dateFromISO8601(play.watchedAt) else {
                authoritative = false
                continue
            }
            let meta = makeNuvioMeta(from: show, isSeries: true)
            guard addHistoryItem(
                meta: meta,
                season: season,
                episode: number,
                watchedAt: watchedAt,
                incrementsPlayCount: true,
                groups: &groups,
                aliasToGroup: &aliasToGroup
            ) else { authoritative = false; continue }
        }

        guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource) else {
            return false
        }
        let remoteItems = groups.values.sorted { $0.id < $1.id }
        guard authoritative else { return false }
        let snapshotKey = "\(profileId ?? "default")|\(context.accountID)"
        let previous = previousWatchedSnapshots[snapshotKey]
            ?? WatchedStore.items(profileId: profileId).filter { $0.isLibraryVisible(under: .wetrakr) }
        guard contextIsCurrent(context, in: store, profileId: profileId, requiresWeTrakrSource: requiresWeTrakrSource) else {
            return false
        }
        guard WatchedStore.reconcileWeTrakrSnapshot(
            remoteItems,
            previousRemoteItems: previous,
            syncStartedAt: syncStartedAt,
            currentAccountID: context.accountID
        ) else { return false }

        previousWatchedSnapshots[snapshotKey] = remoteItems
        NotificationCenter.default.post(name: WatchedStore.changedNotification, object: nil)
        return true
    }

    nonisolated static func wetrakrIDs(for meta: NuvioMeta) -> WeTrakrSyncIDs {
        let rawID = meta.id
        let parts = rawID.split(separator: ":").map(String.init)
        let imdb = meta.imdbId ?? (rawID.hasPrefix("tt") ? (parts.first ?? rawID) : nil)
        let tmdb: Int? = {
            if let tmdbId = meta.tmdbId { return tmdbId }
            if rawID.hasPrefix("tmdb:"), parts.count >= 2 {
                return Int(parts[1])
            }
            return nil
        }()
        let tvdb: Int? = {
            if rawID.hasPrefix("tvdb:"), parts.count >= 2 {
                return Int(parts[1])
            }
            return nil
        }()
        let wetrakr: Int? = {
            if rawID.hasPrefix("wetrakr:"), parts.count >= 2 {
                return Int(parts[1])
            }
            return nil
        }()
        return WeTrakrSyncIDs(wetrakr: wetrakr, imdb: imdb, tmdb: tmdb, tvdb: tvdb)
    }

    nonisolated static func makeNuvioMeta(from media: WeTrakrMediaDTO, isSeries: Bool) -> NuvioMeta {
        let metaId: String = {
            if let imdb = media.ids?.imdb, !imdb.isEmpty { return imdb }
            if let tmdb = media.ids?.tmdb { return "tmdb:\(tmdb)" }
            if let tvdb = media.ids?.tvdb { return "tvdb:\(tvdb)" }
            if let id = media.id { return "wetrakr:\(id)" }
            return UUID().uuidString
        }()

        let posterURL: String? = {
            guard let path = media.posterPath, !path.isEmpty else { return nil }
            if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
            return "https://image.tmdb.org/t/p/w500\(path)"
        }()

        let backdropURL: String? = {
            guard let path = media.backdropPath, !path.isEmpty else { return nil }
            if path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
            return "https://image.tmdb.org/t/p/original\(path)"
        }()

        return NuvioMeta(
            id: metaId,
            name: media.title ?? "",
            description: media.overview,
            posterUrl: posterURL,
            backgroundUrl: backdropURL,
            logoUrl: nil,
            imdbId: media.ids?.imdb,
            tmdbId: media.ids?.tmdb,
            type: isSeries ? "series" : "movie",
            year: media.year,
            genres: nil,
            rating: nil,
            releaseInfo: media.year.map(String.init),
            runtime: media.runtime.map { "\($0)" },
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            language: nil,
            released: media.releaseDate,
            status: nil,
            videos: nil,
            trailerYtIds: nil,
            externalRatings: nil,
            posterShape: nil
        )
    }

    nonisolated static func dateFromISO8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
