import Foundation

/// MDBList playback and watched-history integration.
///
/// The selected progress source is the only provider that receives playback
/// writes. Nuvio Sync remains independent, just as it is for Trakt and Simkl.
@MainActor
enum MdbListProgressService {
    static let completionPercent = 80.0
    private static let maxContinueWatchingItems = 20
    private static var previousWatchedSnapshots: [String: [WatchedStoreItem]] = [:]

    static func isAvailable(
        in store: UserDefaults = ProfileSettings.current,
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) -> Bool {
        MdbListRuntimeSession.isAuthenticated(
            in: store,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        )
    }

    static func reportPlayback(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        action: TraktScrobbleAction,
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        guard TraktSettingsStore.watchProgressSource(in: store) == .mdblist,
              position.isFinite,
              duration.isFinite,
              position > 0,
              duration > 0,
              let body = scrobbleBody(
                meta: meta,
                progress: min(max(position / duration * 100, 0.01), 100),
                season: season,
                episode: episode
              ) else {
            return false
        }

        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: profileScope ?? MdbListRuntimeSession.profileScope(),
            tokenStorage: tokenStorage
        )
        do {
            let response = try await service.authorizedRequest(
                path: "/scrobble/\(action.rawValue)",
                method: .post,
                body: try jsonData(body)
            )
            guard (200..<300).contains(response.statusCode) else { return false }
            invalidateWatchedSnapshot(for: profileScope ?? MdbListRuntimeSession.profileScope())
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            return true
        } catch {
            return false
        }
    }

    static func fetchContinueWatching(
        repository: CatalogRepository,
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> [ContinueWatchingItem]? {
        let scope = profileScope ?? MdbListRuntimeSession.profileScope()
        guard TraktSettingsStore.watchProgressSource(in: store) == .mdblist,
              isAvailable(in: store, tokenStorage: tokenStorage, profileScope: scope) else {
            return []
        }

        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: scope,
            tokenStorage: tokenStorage
        )
        do {
            let response = try await service.authorizedRequest(
                path: "/sync/playback",
                method: .get
            )
            guard (200..<300).contains(response.statusCode),
                  let rows = try JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] else {
                return nil
            }

            let seeds = rows.compactMap(playbackSeed)
                .filter { $0.progress > 0 && $0.progress < completionPercent }
                .sorted { $0.updatedAt > $1.updatedAt }
            var seen = Set<String>()
            let uniqueSeeds = seeds.filter { seed in
                seen.insert(seed.identity).inserted
            }

            let plans = Array(uniqueSeeds.prefix(maxContinueWatchingItems))
            let indexed = await withTaskGroup(of: (Int, ContinueWatchingItem?).self) { group in
                for (index, seed) in plans.enumerated() {
                    group.addTask { @MainActor in
                        let loaded = try? await repository.getMetadata(
                            id: seed.contentID,
                            type: seed.type
                        )
                        let meta = loaded ?? seed.placeholderMeta
                        let duration = loaded.flatMap(runtimeSeconds)
                            ?? seed.runtimeMinutes.map { Double($0) * 60 }
                            ?? fallbackRuntimeSeconds(for: seed.type)
                        let position = max(1, duration * seed.progress / 100)
                        return (
                            index,
                            ContinueWatchingItem(
                                meta: meta,
                                streamUrl: "",
                                position: position,
                                duration: duration,
                                lastWatchedAt: seed.updatedAt,
                                season: seed.season,
                                episode: seed.episode,
                                episodeTitleOverride: seed.episodeTitle,
                                isUpNext: false
                            )
                        )
                    }
                }

                var result: [(Int, ContinueWatchingItem)] = []
                for await item in group {
                    if let value = item.1 { result.append((item.0, value)) }
                }
                return result.sorted { $0.0 < $1.0 }
            }
            return indexed.map(\.1)
        } catch {
            return nil
        }
    }

    /// Removes the account-side paused row behind a Continue Watching card.
    /// MDBList identifies scrobble sessions by the media target rather than a
    /// public delete-by-session endpoint, so `/scrobble/clear` is the canonical
    /// operation here.
    @discardableResult
    static func removePlayback(
        for item: ContinueWatchingItem,
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        let scope = profileScope ?? MdbListRuntimeSession.profileScope()
        guard TraktSettingsStore.watchProgressSource(in: store) == .mdblist,
              let body = scrobbleBody(
                meta: item.meta,
                progress: min(max(item.progress * 100, 0), 100),
                season: item.season,
                episode: item.episode
              ) else {
            return false
        }

        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: scope,
            tokenStorage: tokenStorage
        )
        do {
            let response = try await service.authorizedRequest(
                path: "/scrobble/clear",
                method: .post,
                body: try jsonData(body)
            )
            guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
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

    // MARK: Watched history

    static func syncWatchedHistory(
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        let scope = profileScope ?? MdbListRuntimeSession.profileScope()
        let startingProfile = (ProfileSettings.activeProfileID, WatchedStore.activeProfileId)
        guard TraktSettingsStore.watchProgressSource(in: store) == .mdblist,
              isAvailable(in: store, tokenStorage: tokenStorage, profileScope: scope) else {
            return false
        }

        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: scope,
            tokenStorage: tokenStorage
        )
        let syncStartedAt = Date()
        do {
            var query = [URLQueryItem(name: "limit", value: "1000")]
            var remoteItems: [WatchedStoreItem] = []
            var visitedCursors = Set<String>()
            var completed = false

            for _ in 0..<1_000 {
                let response = try await service.authorizedRequest(
                    path: "/sync/watched",
                    method: .get,
                    queryItems: query
                )
                guard (200..<300).contains(response.statusCode),
                      let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                    return false
                }
                guard ["movies", "shows", "seasons", "episodes"].contains(where: object.keys.contains) else {
                    return false
                }
                remoteItems.append(contentsOf: watchedItems(from: object))

                guard let pagination = object["pagination"] as? [String: Any],
                      let cursor = string(pagination["next_cursor"]),
                      !cursor.isEmpty else {
                    completed = true
                    break
                }
                guard visitedCursors.insert(cursor).inserted else { return false }
                query = [
                    URLQueryItem(name: "limit", value: "1000"),
                    URLQueryItem(name: "cursor", value: cursor)
                ]
            }

            guard completed else { return false }

            // The global watch stores follow the active profile. Do not apply
            // a response that started for one profile after the user switched
            // to another while pagination was in flight.
            guard startingProfile.0 == ProfileSettings.activeProfileID,
                  startingProfile.1 == WatchedStore.activeProfileId else {
                return false
            }

            let previous = previousWatchedSnapshots[scope]
                ?? WatchedStore.items().filter { $0.sources.contains(TraktWatchProgressSource.mdblist.rawValue) }
            let merged = WatchedStore.mergedByIdentity(remoteItems)
            guard WatchedStore.reconcileMdbListSnapshot(
                merged,
                previousRemoteItems: previous,
                syncStartedAt: syncStartedAt
            ) else { return false }
            previousWatchedSnapshots[scope] = merged
            NotificationCenter.default.post(name: WatchedStore.changedNotification, object: nil)
            return true
        } catch {
            return false
        }
    }

    static func setWatched(
        _ meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil,
        isWatched: Bool,
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
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

    static func setWatched(
        _ meta: NuvioMeta,
        season: Int?,
        episodes: [Int],
        isWatched: Bool,
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        let scope = profileScope ?? MdbListRuntimeSession.profileScope()
        guard TraktSettingsStore.watchProgressSource(in: store) == .mdblist,
              let body = historyBody(
                meta: meta,
                season: season,
                episodes: episodes,
                watchedAt: isWatched ? iso8601Now() : nil
              ) else {
            return false
        }

        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: scope,
            tokenStorage: tokenStorage
        )
        do {
            let response = try await service.authorizedRequest(
                path: isWatched ? "/sync/watched" : "/sync/watched/remove",
                method: .post,
                body: try jsonData(body)
            )
            guard (200..<300).contains(response.statusCode) else { return false }
            invalidateWatchedSnapshot(for: scope)
            NotificationCenter.default.post(name: WatchedStore.changedNotification, object: nil)
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            return true
        } catch {
            return false
        }
    }

    static func invalidateWatchedSnapshot(for profileScope: String = MdbListRuntimeSession.profileScope()) {
        previousWatchedSnapshots.removeValue(forKey: profileScope)
    }

    // MARK: Request bodies

    private static func scrobbleBody(
        meta: NuvioMeta,
        progress: Double,
        season: Int?,
        episode: Int?
    ) -> [String: Any]? {
        guard progress.isFinite, progress >= 0, progress <= 100,
              let ids = ids(for: meta) else { return nil }
        if meta.isSeries {
            guard let season, season >= 0, let episode, episode > 0 else { return nil }
            return [
                "show": [
                    "ids": ids,
                    "season": season,
                    "episode": episode
                ],
                "progress": roundedProgress(progress)
            ]
        }
        return [
            "movie": ["ids": ids],
            "progress": roundedProgress(progress)
        ]
    }

    private static func historyBody(
        meta: NuvioMeta,
        season: Int?,
        episodes: [Int],
        watchedAt: String?
    ) -> [String: Any]? {
        guard let ids = ids(for: meta) else { return nil }
        if meta.isSeries {
            var show: [String: Any] = ["ids": ids]
            if let season {
                guard season >= 0 else { return nil }
                var seasonBody: [String: Any] = ["number": season]
                if !episodes.isEmpty {
                    guard episodes.allSatisfy({ $0 > 0 }) else { return nil }
                    seasonBody["episodes"] = episodes.map { episode in
                        var episodeBody: [String: Any] = ["number": episode]
                        if let watchedAt { episodeBody["watched_at"] = watchedAt }
                        return episodeBody
                    }
                } else if let watchedAt {
                    seasonBody["watched_at"] = watchedAt
                }
                show["seasons"] = [seasonBody]
            } else if let watchedAt {
                show["watched_at"] = watchedAt
            }
            return ["shows": [show]]
        }

        var movie: [String: Any] = ["ids": ids]
        if let watchedAt { movie["watched_at"] = watchedAt }
        return ["movies": [movie]]
    }

    private static func ids(for meta: NuvioMeta) -> [String: Any]? {
        let first = meta.id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? meta.id
        func prefixed(_ prefix: String) -> String? {
            guard meta.id.lowercased().hasPrefix("\(prefix.lowercased()):") else { return nil }
            let value = meta.id.dropFirst(prefix.count + 1).split(separator: ":").first.map(String.init) ?? ""
            return value.isEmpty ? nil : value
        }
        func integer(_ value: String?) -> Int? {
            guard let value, let result = Int(value), result > 0 else { return nil }
            return result
        }

        var result: [String: Any] = [:]
        let imdb = NuvioMeta.canonicalImdbID(from: meta.imdbId ?? first)
        if let imdb { result["imdb"] = imdb }
        if let tmdb = meta.tmdbId ?? integer(prefixed("tmdb")) { result["tmdb"] = tmdb }
        if let trakt = integer(prefixed("trakt")) { result["trakt"] = trakt }
        if let tvdb = integer(prefixed("tvdb")) { result["tvdb"] = tvdb }
        if let mdblist = prefixed("mdblist") { result["mdblist"] = mdblist }
        return result.isEmpty ? nil : result
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw MdbListServiceError.message("Invalid MDBList request body.")
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func roundedProgress(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    // MARK: Playback decoding

    private struct PlaybackSeed {
        let identity: String
        let contentID: String
        let type: String
        let media: MediaPayload
        let progress: Double
        let updatedAt: Date
        let season: Int?
        let episode: Int?
        let episodeTitle: String?
        let runtimeMinutes: Int?

        var placeholderMeta: NuvioMeta {
            NuvioMeta(
                id: contentID,
                name: media.title ?? contentID,
                description: nil,
                posterUrl: media.poster,
                backgroundUrl: media.backdrop,
                logoUrl: nil,
                imdbId: media.ids.imdb,
                tmdbId: media.ids.tmdb,
                type: type,
                year: media.year,
                genres: nil,
                rating: nil,
                releaseInfo: media.year.map(String.init),
                runtime: runtimeMinutes.map { "\($0) min" },
                cast: nil,
                director: nil,
                writer: nil,
                certification: nil,
                country: nil,
                released: nil
            )
        }
    }

    struct MediaPayload {
        let title: String?
        let year: Int?
        let poster: String?
        let backdrop: String?
        let ids: MediaIDs
    }

    struct MediaIDs {
        let imdb: String?
        let tmdb: Int?
        let trakt: Int?
        let tvdb: Int?
        let mdblist: String?

        var contentID: String? {
            if let imdb, !imdb.isEmpty { return imdb }
            if let tmdb { return "tmdb:\(tmdb)" }
            if let trakt { return "trakt:\(trakt)" }
            if let tvdb { return "tvdb:\(tvdb)" }
            if let mdblist, !mdblist.isEmpty { return "mdblist:\(mdblist)" }
            return nil
        }
    }

    private static func playbackSeed(_ row: [String: Any]) -> PlaybackSeed? {
        let rawType = string(row["type"])?.lowercased()
        let isMovie = rawType == "movie"
        let isEpisode = rawType == "episode" || rawType == "show" || rawType == "series"
        guard isMovie || isEpisode else { return nil }

        let episodeObject = dictionary(row["episode"])
        let parentObject = dictionary(row[isMovie ? "movie" : "show"])
            ?? dictionary(episodeObject?["show"])
        guard let parentObject,
              let media = mediaPayload(parentObject),
              let contentID = media.ids.contentID else { return nil }

        let progress = number(row["progress"])
            ?? number(row["progress_at_update"])
        guard let progress, progress.isFinite, progress >= 0, progress <= 100 else { return nil }

        let season = isEpisode
            ? integer(episodeObject?["season"] ?? row["season"])
            : nil
        let episode = isEpisode
            ? integer(episodeObject?["number"] ?? episodeObject?["episode"] ?? row["number"] ?? row["episode_number"])
            : nil
        guard !isEpisode || (season != nil && season! >= 0 && episode != nil && episode! > 0) else {
            return nil
        }

        let date = parseDate(
            string(row["paused_at"])
                ?? string(row["updated_at"])
                ?? string(row["started_at"])
        ) ?? Date()
        let runtime = integer(row["runtime"])?.takeIfPositive
        return PlaybackSeed(
            identity: "\(contentID.lowercased()):\(season ?? -1):\(episode ?? -1)",
            contentID: contentID,
            type: isMovie ? "movie" : "series",
            media: media,
            progress: progress,
            updatedAt: date,
            season: season,
            episode: episode,
            episodeTitle: string(episodeObject?["title"] ?? episodeObject?["name"]),
            runtimeMinutes: runtime
        )
    }

    private static func mediaPayload(_ object: [String: Any]) -> MediaPayload? {
        let idsObject = dictionary(object["ids"]) ?? object
        let ids = MediaIDs(
            imdb: string(idsObject["imdb"]).flatMap { NuvioMeta.canonicalImdbID(from: $0) },
            tmdb: integer(idsObject["tmdb"] ?? idsObject["tmdbid"]),
            trakt: integer(idsObject["trakt"] ?? idsObject["traktid"]),
            tvdb: integer(idsObject["tvdb"] ?? idsObject["tvdbid"]),
            mdblist: string(idsObject["mdblist"])
        )
        guard ids.contentID != nil else { return nil }
        return MediaPayload(
            title: string(object["title"] ?? object["name"]),
            year: integer(object["year"] ?? object["release_year"]),
            poster: imageURL(string(object["poster"])),
            backdrop: imageURL(string(object["backdrop"] ?? object["background"])),
            ids: ids
        )
    }

    private static func runtimeSeconds(for meta: NuvioMeta) -> Double? {
        guard let raw = meta.runtime?.lowercased(), !raw.isEmpty else { return nil }
        let values = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
        guard let first = values.first else { return nil }
        if raw.contains("h") {
            let minutes = values.count > 1 ? values[1] : 0
            return max((first * 60 + minutes) * 60, 60)
        }
        return max(first * 60, 60)
    }

    private static func fallbackRuntimeSeconds(for type: String) -> Double {
        type == "movie" ? 120 * 60 : 45 * 60
    }

    // MARK: Watched decoding

    private static func watchedItems(from object: [String: Any]) -> [WatchedStoreItem] {
        var result: [WatchedStoreItem] = []

        for row in array(object["movies"]) {
            guard let row = dictionary(row) else { continue }
            let target = dictionary(row["movie"]) ?? row
            guard
                  let media = mediaPayload(target),
                  let contentID = media.ids.contentID else { continue }
            result.append(
                WatchedStoreItem(
                    meta: media.meta(contentID: contentID, type: "movie"),
                    watchedAt: watchedDate(row: row, target: target) ?? .distantPast,
                    sources: [TraktWatchProgressSource.mdblist.rawValue]
                )
            )
        }

        for row in array(object["shows"]) {
            guard let row = dictionary(row) else { continue }
            let target = dictionary(row["show"]) ?? row
            guard
                  let media = mediaPayload(target),
                  let contentID = media.ids.contentID else { continue }
            let meta = media.meta(contentID: contentID, type: "series")
            let showDate = watchedDate(row: row, target: target) ?? .distantPast
            let seasons = array(row["seasons"]).compactMap(dictionary)
            var emittedEpisode = false
            for season in seasons {
                guard let seasonNumber = integer(season["number"] ?? season["season"]), seasonNumber >= 0 else { continue }
                let seasonDate = watchedDate(row: season, target: season) ?? showDate
                for episode in array(season["episodes"]).compactMap(dictionary) {
                    guard let number = integer(episode["number"] ?? episode["episode"]), number > 0 else { continue }
                    emittedEpisode = true
                    result.append(
                        WatchedStoreItem(
                            meta: meta,
                            watchedAt: watchedDate(row: episode, target: episode) ?? seasonDate,
                            season: seasonNumber,
                            episode: number,
                            sources: [TraktWatchProgressSource.mdblist.rawValue]
                        )
                    )
                }
            }
            if !emittedEpisode, showDate != .distantPast {
                result.append(
                    WatchedStoreItem(
                        meta: meta,
                        watchedAt: showDate,
                        sources: [TraktWatchProgressSource.mdblist.rawValue]
                    )
                )
            }
        }

        // MDBList also exposes season rows. The tvOS watched model has no
        // season-only representation, so retain the show-level mark when a
        // season is the only state returned; nested episode rows remain the
        // authoritative representation whenever they are available.
        for row in array(object["seasons"]) {
            guard let row = dictionary(row) else { continue }
            let seasonObject = dictionary(row["season"]) ?? row
            guard let showObject = dictionary(row["show"]) ?? dictionary(seasonObject["show"]),
                  let media = mediaPayload(showObject),
                  let contentID = media.ids.contentID,
                  watchedDate(row: row, target: seasonObject) != nil else { continue }
            result.append(
                WatchedStoreItem(
                    meta: media.meta(contentID: contentID, type: "series"),
                    watchedAt: watchedDate(row: row, target: seasonObject) ?? .distantPast,
                    sources: [TraktWatchProgressSource.mdblist.rawValue]
                )
            )
        }

        for row in array(object["episodes"]) {
            guard let row = dictionary(row) else { continue }
            let episodeObject = dictionary(row["episode"]) ?? row
            let showObject = dictionary(row["show"])
                ?? dictionary(episodeObject["show"])
            guard let showObject,
                  let media = mediaPayload(showObject),
                  let contentID = media.ids.contentID,
                  let season = integer(episodeObject["season"] ?? row["season"]),
                  season >= 0,
                  let number = integer(episodeObject["number"] ?? episodeObject["episode"] ?? row["number"]),
                  number > 0,
                  let watchedAt = watchedDate(row: row, target: episodeObject) else { continue }
            result.append(
                WatchedStoreItem(
                    meta: media.meta(contentID: contentID, type: "series"),
                    watchedAt: watchedAt,
                    season: season,
                    episode: number,
                    sources: [TraktWatchProgressSource.mdblist.rawValue]
                )
            )
        }

        return result
    }

    private static func watchedDate(row: [String: Any], target: [String: Any]) -> Date? {
        parseDate(
            string(row["last_watched_at"])
                ?? string(row["watched_at"])
                ?? string(target["last_watched_at"])
                ?? string(target["watched_at"])
        )
    }

    private static func imageURL(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        if value.hasPrefix("http://") || value.hasPrefix("https://") { return value }
        if value.hasPrefix("/") { return "https://image.tmdb.org/t/p/w500\(value)" }
        return nil
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func array(_ value: Any?) -> [Any] {
        value as? [Any] ?? []
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Int {
    var takeIfPositive: Int? { self > 0 ? self : nil }
}

private extension MdbListProgressService.MediaPayload {
    func meta(contentID: String, type: String) -> NuvioMeta {
        NuvioMeta(
            id: contentID,
            name: title ?? contentID,
            description: nil,
            posterUrl: poster,
            backgroundUrl: backdrop,
            logoUrl: nil,
            imdbId: ids.imdb,
            tmdbId: ids.tmdb,
            type: type,
            year: year,
            genres: nil,
            rating: nil,
            releaseInfo: year.map(String.init),
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }
}
