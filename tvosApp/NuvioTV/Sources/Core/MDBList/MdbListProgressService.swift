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
        let scope = profileScope ?? MdbListRuntimeSession.profileScope()
        if MdbListAuthStore.state(in: store, profileScope: scope, tokenStorage: tokenStorage).hasOAuthTokens {
            return true
        }
        return !(store.string(forKey: SettingsKey.mdbListApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
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
        guard ProfileSettings.isActiveStore(store),
              (TraktSettingsStore.watchProgressSource(in: store) == .mdblist
                || RemoteTrackingState.isScrobbleEnabled(
                    for: .mdblist,
                    in: store,
                    mdbListTokenStorage: tokenStorage,
                    profileScope: profileScope
                )),
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
            guard (200..<300).contains(response.statusCode),
                  ProfileSettings.isActiveStore(store) else { return false }
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
            var results = indexed.map(\.1)
            let playbackMetas = results.map(\.meta)

            if results.count < maxContinueWatchingItems {
                let watchedItems = WatchedStore.items().filter {
                    $0.isVisible(under: .mdblist)
                }
                let upNextSeeds = nextUpSeeds(
                    from: watchedItems,
                    preferFurthestEpisode: UpNextEpisodeSelectionPolicy.prefersFurthestEpisode
                )
                let candidateSeeds = upNextSeeds.filter { seed in
                    !playbackMetas.contains(where: {
                        WatchedStore.sameContent($0, seed.meta)
                    })
                }
                let needed = maxContinueWatchingItems - results.count
                let seedsToInspect = Array(candidateSeeds.prefix(min(needed * 2, 24)))

                let upNextRows = await withTaskGroup(of: (Int, ContinueWatchingItem?).self) { group in
                    for (index, seed) in seedsToInspect.enumerated() {
                        group.addTask { @MainActor in
                            let item = await makeUpNextItem(from: seed, repository: repository)
                            return (index, item)
                        }
                    }
                    var taskResults: [(Int, ContinueWatchingItem)] = []
                    for await (index, item) in group {
                        if let item { taskResults.append((index, item)) }
                    }
                    return taskResults.sorted { $0.0 < $1.0 }.map(\.1)
                }

                for item in upNextRows {
                    guard results.count < maxContinueWatchingItems else { break }
                    results.append(item)
                }
            }

            return results
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
        guard ProfileSettings.isActiveStore(store),
              (TraktSettingsStore.watchProgressSource(in: store) == .mdblist
                || RemoteTrackingState.isScrobbleEnabled(
                    for: .mdblist,
                    in: store,
                    mdbListTokenStorage: tokenStorage,
                    profileScope: scope
                )),
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
            guard ((200..<300).contains(response.statusCode) || response.statusCode == 404),
                  ProfileSettings.isActiveStore(store) else {
                return false
            }
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .mdblist, in: store)
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
        let accountID = MdbListAuthStore.accountBindingID(in: store)
        guard ProfileSettings.isActiveStore(store),
              !accountID.isEmpty,
              (TraktSettingsStore.watchProgressSource(in: store) == .mdblist
                || TraktSettingsStore.librarySourceMode(in: store) == .mdblist
                || RemoteTrackingState.isScrobbleEnabled(
                    for: .mdblist,
                    in: store,
                    mdbListTokenStorage: tokenStorage,
                    profileScope: scope
                )),
              isAvailable(in: store, tokenStorage: tokenStorage, profileScope: scope) else {
            return false
        }

        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: scope,
            tokenStorage: tokenStorage
        )
        _ = await flushPendingLibraryMutations(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: scope
        )
        guard isCurrentWatchedHistoryContext(
            store: store,
            scope: scope,
            profileId: startingProfile.1,
            expectedProfileID: startingProfile.0,
            accountID: accountID,
            tokenStorage: tokenStorage
        ) else { return false }
        let syncStartedAt = Date()
        do {
            var remoteItems: [WatchedStoreItem] = []
            var snapshotComplete = true
            let mediaTypes = ["movie", "show", "episode", "season"]

            for mediaType in mediaTypes {
                var query = [
                    URLQueryItem(name: "limit", value: "1000"),
                    URLQueryItem(name: "mediatype", value: mediaType)
                ]
                var visitedCursors = Set<String>()
                var receivedResponse = false
                var reachedEnd = false

                for pageIndex in 0..<1_000 {
                    let response = try await service.authorizedRequest(
                        path: "/sync/watched",
                        method: .get,
                        queryItems: query
                    )
                    guard isCurrentWatchedHistoryContext(
                        store: store,
                        scope: scope,
                        profileId: startingProfile.1,
                        expectedProfileID: startingProfile.0,
                        accountID: accountID,
                        tokenStorage: tokenStorage
                    ) else { return false }
                    guard (200..<300).contains(response.statusCode) else {
                        snapshotComplete = false
                        break
                    }
                    guard let json = try? JSONSerialization.jsonObject(with: response.data) else {
                        snapshotComplete = false
                        break
                    }
                    receivedResponse = true
                    let items = watchedItems(from: json)
                    remoteItems.append(contentsOf: items)

                    var nextCursor: String?
                    if let object = json as? [String: Any],
                       let pagination = object["pagination"] as? [String: Any] {
                        nextCursor = string(pagination["next_cursor"])
                    }
                    guard let cursor = nextCursor, !cursor.isEmpty else {
                        reachedEnd = true
                        break
                    }
                    guard visitedCursors.insert(cursor).inserted else {
                        snapshotComplete = false
                        break
                    }
                    if pageIndex == 999 { snapshotComplete = false }
                    query = [
                        URLQueryItem(name: "limit", value: "1000"),
                        URLQueryItem(name: "mediatype", value: mediaType),
                        URLQueryItem(name: "cursor", value: cursor)
                    ]
                }
                if !receivedResponse || !reachedEnd { snapshotComplete = false }
            }

            if remoteItems.isEmpty {
                var query = [URLQueryItem(name: "limit", value: "1000")]
                var visitedCursors = Set<String>()
                var fallbackComplete = false
                for pageIndex in 0..<1_000 {
                    let response = try await service.authorizedRequest(
                        path: "/sync/watched",
                        method: .get,
                        queryItems: query
                    )
                    guard isCurrentWatchedHistoryContext(
                        store: store,
                        scope: scope,
                        profileId: startingProfile.1,
                        expectedProfileID: startingProfile.0,
                        accountID: accountID,
                        tokenStorage: tokenStorage
                    ) else { return false }
                    guard (200..<300).contains(response.statusCode),
                          let json = try? JSONSerialization.jsonObject(with: response.data) else {
                        break
                    }
                    remoteItems.append(contentsOf: watchedItems(from: json))
                    var nextCursor: String?
                    if let object = json as? [String: Any],
                       let pagination = object["pagination"] as? [String: Any] {
                        nextCursor = string(pagination["next_cursor"])
                    }
                    guard let cursor = nextCursor, !cursor.isEmpty, visitedCursors.insert(cursor).inserted else {
                        fallbackComplete = nextCursor == nil || nextCursor?.isEmpty == true
                        break
                    }
                    if pageIndex == 999 { break }
                    query = [
                        URLQueryItem(name: "limit", value: "1000"),
                        URLQueryItem(name: "cursor", value: cursor)
                    ]
                }
                snapshotComplete = fallbackComplete
            }

            // The global watch stores follow the active profile. Do not apply
            // a response that started for one profile after the user switched
            // to another while pagination was in flight.
            guard startingProfile.0 == ProfileSettings.activeProfileID,
                  startingProfile.1 == WatchedStore.activeProfileId,
                  MdbListAuthStore.accountBindingID(in: store) == accountID else {
                return false
            }

            let snapshotKey = "\(scope)|\(accountID)"
            let previous = previousWatchedSnapshots[snapshotKey]
                ?? WatchedStore.items(profileId: startingProfile.1).filter {
                    $0.isLibraryVisible(under: .mdblist, accountID: accountID)
                }
            let merged = WatchedStore.mergedByIdentity(remoteItems)
            if !snapshotComplete {
                guard !merged.isEmpty,
                      WatchedStore.mergeMdbListPartialSnapshot(
                        merged,
                        syncStartedAt: syncStartedAt,
                        currentAccountID: accountID,
                        profileId: startingProfile.1
                      ) else { return false }
                NotificationCenter.default.post(name: WatchedStore.changedNotification, object: nil)
                return true
            }
            guard WatchedStore.reconcileMdbListSnapshot(
                merged,
                previousRemoteItems: previous,
                syncStartedAt: syncStartedAt,
                currentAccountID: accountID
            ) else { return false }
            previousWatchedSnapshots[snapshotKey] = merged
            NotificationCenter.default.post(name: WatchedStore.changedNotification, object: nil)
            return true
        } catch {
            return false
        }
    }

    /// Drains account-bound manual library changes. Playback scrobble remains
    /// on its existing endpoints and never shares this outbox.
    static func flushPendingLibraryMutations(
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        let scope = profileScope ?? MdbListRuntimeSession.profileScope()
        let profileId = WatchedStore.activeProfileId
        let expectedProfileID = ProfileSettings.activeProfileID
        let accountID = MdbListAuthStore.accountBindingID(in: store)
        guard expectedProfileID == profileId,
              ProfileSettings.isActiveStore(store),
              RemoteTrackingState.isProgressSourceAuthenticated(
                .mdblist,
                in: store,
                mdbListTokenStorage: tokenStorage,
                profileScope: scope
              ) else { return false }

        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: scope,
            tokenStorage: tokenStorage
        )
        let mutations = WatchedStore.pendingLibraryMutations(
            provider: .mdblist,
            profileId: profileId,
            readyOnly: true
        )
            .filter { $0.accountID == accountID && $0.profileID == profileId }
        for mutation in mutations {
            guard isCurrentWatchedHistoryContext(
                store: store,
                scope: scope,
                profileId: profileId,
                expectedProfileID: expectedProfileID,
                accountID: accountID,
                tokenStorage: tokenStorage
            ) else { return false }
            let episodes = mutation.episodes.isEmpty
                ? mutation.episode.map { [$0] } ?? []
                : mutation.episodes
            guard let body = historyBody(
                meta: mutation.meta,
                season: mutation.season,
                episodes: episodes,
                watchedAt: mutation.isWatched ? iso8601(mutation.changedAt) : nil
            ) else { return false }
            do {
                let response = try await service.authorizedRequest(
                    path: mutation.isWatched ? "/sync/watched" : "/sync/watched/remove",
                    method: .post,
                    body: try jsonData(body)
                )
                guard (200..<300).contains(response.statusCode) else {
                    _ = WatchedStore.deferLibraryMutation(
                        id: mutation.id,
                        provider: .mdblist,
                        accountID: accountID,
                        profileId: profileId
                    )
                    return false
                }
                guard isCurrentWatchedHistoryContext(
                        store: store,
                        scope: scope,
                        profileId: profileId,
                        expectedProfileID: expectedProfileID,
                        accountID: accountID,
                        tokenStorage: tokenStorage
                      ),
                      WatchedStore.acknowledgeLibraryMutation(
                        id: mutation.id,
                        provider: .mdblist,
                        accountID: accountID,
                        profileId: profileId
                      ) else { return false }
            } catch {
                _ = WatchedStore.deferLibraryMutation(
                    id: mutation.id,
                    provider: .mdblist,
                    accountID: accountID,
                    profileId: profileId
                )
                return false
            }
        }
        return true
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
        guard ProfileSettings.isActiveStore(store),
              (TraktSettingsStore.watchProgressSource(in: store) == .mdblist
                || RemoteTrackingState.isScrobbleEnabled(
                    for: .mdblist,
                    in: store,
                    mdbListTokenStorage: tokenStorage,
                    profileScope: scope
                )),
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
            TraktSettingsStore.notifyContinueWatchingSourceInvalidated(for: .mdblist, in: store)
            return true
        } catch {
            return false
        }
    }

    static func invalidateWatchedSnapshot(for profileScope: String = MdbListRuntimeSession.profileScope()) {
        previousWatchedSnapshots = previousWatchedSnapshots.filter {
            !$0.key.hasPrefix("\(profileScope)|")
        }
    }

    private static func isCurrentWatchedHistoryContext(
        store: UserDefaults,
        scope: String,
        profileId: String?,
        expectedProfileID: String?,
        accountID: String,
        tokenStorage: MdbListTokenStorage
    ) -> Bool {
        ProfileSettings.isActiveStore(store)
            && ProfileSettings.activeProfileID == expectedProfileID
            && WatchedStore.activeProfileId == profileId
            && profileId == expectedProfileID
            && MdbListAuthStore.accountBindingID(in: store) == accountID
            && RemoteTrackingState.isProgressSourceAuthenticated(
                .mdblist,
                in: store,
                mdbListTokenStorage: tokenStorage,
                profileScope: scope
            )
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
        iso8601(Date())
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
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

    // MARK: Up Next generation

    private struct UpNextSeed {
        let meta: NuvioMeta
        let season: Int
        let episode: Int
        let watchedAt: Date
    }

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

            let key = item.meta.imdbId?.lowercased()
                ?? item.meta.type.lowercased() + ":" + item.meta.id.lowercased()
            let candidate = UpNextSeed(
                meta: item.meta,
                season: season,
                episode: episode,
                watchedAt: item.watchedAt
            )
            guard let current = selectedByContentID[key] else {
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
                selectedByContentID[key] = candidate
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
        let duration = max(runtimeSeconds(for: meta) ?? 45 * 60, 120)
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

    // MARK: Watched decoding

    private static func watchedItems(from json: Any) -> [WatchedStoreItem] {
        if let object = json as? [String: Any] {
            var items = watchedItems(fromObject: object)
            if let list = object["items"] as? [[String: Any]] ?? object["data"] as? [[String: Any]] ?? object["results"] as? [[String: Any]] {
                items.append(contentsOf: watchedItems(fromRows: list))
            }
            return items
        } else if let rows = json as? [[String: Any]] {
            return watchedItems(fromRows: rows)
        }
        return []
    }

    private static func watchedItems(fromObject object: [String: Any]) -> [WatchedStoreItem] {
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

    private static func watchedItems(fromRows rows: [[String: Any]]) -> [WatchedStoreItem] {
        var result: [WatchedStoreItem] = []
        for row in rows {
            let rawType = string(row["type"] ?? row["mediatype"])?.lowercased()
            let isMovie = rawType == "movie" || row["movie"] != nil
            let isEpisode = rawType == "episode" || row["episode"] != nil
            let isSeason = rawType == "season" || (row["season"] != nil && !isEpisode && !isMovie)
            let isShow = rawType == "show" || rawType == "series" || row["show"] != nil

            if isMovie {
                let target = dictionary(row["movie"]) ?? row
                if let media = mediaPayload(target), let contentID = media.ids.contentID {
                    result.append(
                        WatchedStoreItem(
                            meta: media.meta(contentID: contentID, type: "movie"),
                            watchedAt: watchedDate(row: row, target: target) ?? .distantPast,
                            sources: [TraktWatchProgressSource.mdblist.rawValue]
                        )
                    )
                }
            } else if isEpisode {
                let episodeObject = dictionary(row["episode"]) ?? row
                let showObject = dictionary(row["show"]) ?? dictionary(episodeObject["show"]) ?? row
                if let media = mediaPayload(showObject),
                   let contentID = media.ids.contentID,
                   let season = integer(episodeObject["season"] ?? row["season"]),
                   season >= 0,
                   let number = integer(episodeObject["number"] ?? episodeObject["episode"] ?? row["number"] ?? row["episode_number"]),
                   number > 0,
                   let watchedAt = watchedDate(row: row, target: episodeObject) {
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
            } else if isSeason {
                let seasonObject = dictionary(row["season"]) ?? row
                let showObject = dictionary(row["show"]) ?? dictionary(seasonObject["show"]) ?? row
                if let media = mediaPayload(showObject),
                   let contentID = media.ids.contentID,
                   let seasonNumber = integer(seasonObject["number"] ?? seasonObject["season"] ?? row["season"]),
                   seasonNumber >= 0 {
                    let seasonDate = watchedDate(row: row, target: seasonObject) ?? .distantPast
                    let episodes = array(seasonObject["episodes"] ?? row["episodes"]).compactMap(dictionary)
                    var emitted = false
                    for ep in episodes {
                        if let number = integer(ep["number"] ?? ep["episode"]), number > 0 {
                            emitted = true
                            result.append(
                                WatchedStoreItem(
                                    meta: media.meta(contentID: contentID, type: "series"),
                                    watchedAt: watchedDate(row: ep, target: ep) ?? seasonDate,
                                    season: seasonNumber,
                                    episode: number,
                                    sources: [TraktWatchProgressSource.mdblist.rawValue]
                                )
                            )
                        }
                    }
                    if !emitted {
                        result.append(
                            WatchedStoreItem(
                                meta: media.meta(contentID: contentID, type: "series"),
                                watchedAt: seasonDate,
                                sources: [TraktWatchProgressSource.mdblist.rawValue]
                            )
                        )
                    }
                }
            } else if isShow {
                let target = dictionary(row["show"]) ?? row
                if let media = mediaPayload(target), let contentID = media.ids.contentID {
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
                    if !emittedEpisode {
                        result.append(
                            WatchedStoreItem(
                                meta: meta,
                                watchedAt: showDate,
                                sources: [TraktWatchProgressSource.mdblist.rawValue]
                            )
                        )
                    }
                }
            }
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
