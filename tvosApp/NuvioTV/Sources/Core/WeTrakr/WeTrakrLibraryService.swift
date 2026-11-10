import Foundation

@MainActor
enum WeTrakrLibraryService {
    static let mutationNotification = Notification.Name("nuvio.tv.wetrakr.library.mutation")
    private static let client = WeTrakrAPIClient()
    private static var cachedLibraryItems: [LibraryStoreItem]?

    static func fetchLibrary(
        repository: CatalogRepository? = nil,
        store: UserDefaults = ProfileSettings.current,
        updateCachedLibraryItems: Bool = true,
        requireSuccessfulResponses: Bool = false
    ) async -> [LibraryStoreItem]? {
        guard let token = WeTrakrRuntimeSession.authenticatedState(store: store)?.accessToken,
              !token.isEmpty else { return nil }
        let clientID = WeTrakrConfig.clientID(in: store)

        let extendedQuery = [
            URLQueryItem(name: "extended", value: "show_level_1,movie_level_1"),
            URLQueryItem(name: "limit", value: "100")
        ]

        async let moviesRequest: WeTrakrHTTPResult<[WeTrakrTrackingPlayingItemDTO]> = client.get(
            path: "/sync/tracking/planning/movies",
            accessToken: token,
            clientID: clientID,
            queryItems: extendedQuery
        )
        async let showsRequest: WeTrakrHTTPResult<[WeTrakrTrackingPlayingItemDTO]> = client.get(
            path: "/sync/tracking/planning/shows",
            accessToken: token,
            clientID: clientID,
            queryItems: extendedQuery
        )

        let movies = try? await moviesRequest.valueOrThrow()
        let shows = try? await showsRequest.valueOrThrow()
        guard !requireSuccessfulResponses || (movies != nil && shows != nil) else { return nil }

        var items: [LibraryStoreItem] = []

        if let movies {
            for item in movies {
                let media = item.resolvedMedia
                guard media.id != nil || media.ids?.hasUsableIdentifier == true else { continue }
                let meta = WeTrakrProgressService.makeNuvioMeta(from: media, isSeries: false)
                let added = WeTrakrProgressService.dateFromISO8601(item.updatedAt ?? item.trackedAt) ?? Date()
                items.append(LibraryStoreItem(meta: meta, addedAt: added))
            }
        }

        if let shows {
            for item in shows {
                let media = item.resolvedMedia
                guard media.id != nil || media.ids?.hasUsableIdentifier == true else { continue }
                let meta = WeTrakrProgressService.makeNuvioMeta(from: media, isSeries: true)
                let added = WeTrakrProgressService.dateFromISO8601(item.updatedAt ?? item.trackedAt) ?? Date()
                items.append(LibraryStoreItem(meta: meta, addedAt: added))
            }
        }

        if updateCachedLibraryItems {
            cachedLibraryItems = items
        }
        return items
    }

    static func setWatchlist(
        _ meta: NuvioMeta,
        isInWatchlist: Bool,
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        guard let token = WeTrakrRuntimeSession.authenticatedState(store: store)?.accessToken,
              !token.isEmpty else { return false }
        let clientID = WeTrakrConfig.clientID(in: store)
        let ids = WeTrakrProgressService.wetrakrIDs(for: meta)
        guard ids.hasUsableIdentifier else { return false }

        let mediaPayload = WeTrakrMediaPayload(title: meta.name, year: meta.year, ids: ids, status: "planning")

        do {
            if isInWatchlist {
                let payload = WeTrakrTrackingAddPayload(
                    movies: meta.isSeries ? nil : [mediaPayload],
                    shows: meta.isSeries ? [WeTrakrShowTrackingPayload(title: meta.name, year: meta.year, ids: ids, status: "planning", seasons: nil)] : nil
                )
                let result: WeTrakrHTTPResult<Data> = try await client.postRaw(
                    path: "/sync/tracking",
                    body: payload,
                    accessToken: token,
                    clientID: clientID
                )
                _ = try result.valueOrThrow()

                if var current = cachedLibraryItems {
                    if !current.contains(where: { $0.meta.id == meta.id || WatchedStore.sameContent($0.meta, meta) }) {
                        current.insert(LibraryStoreItem(meta: meta, addedAt: Date()), at: 0)
                        cachedLibraryItems = current
                    }
                }
            } else {
                let payload = WeTrakrTrackingRemovePayload(
                    movies: meta.isSeries ? nil : [mediaPayload],
                    shows: meta.isSeries ? [WeTrakrShowTrackingPayload(title: meta.name, year: meta.year, ids: ids, status: "planning", seasons: nil)] : nil
                )
                let result: WeTrakrHTTPResult<Data> = try await client.postRaw(
                    path: "/sync/tracking/remove",
                    body: payload,
                    accessToken: token,
                    clientID: clientID
                )
                _ = try result.valueOrThrow()

                if var current = cachedLibraryItems {
                    current.removeAll(where: { $0.meta.id == meta.id || WatchedStore.sameContent($0.meta, meta) })
                    cachedLibraryItems = current
                }
            }

            NotificationCenter.default.post(
                name: TraktLibraryService.mutationNotification,
                object: TraktLibraryMutation(meta: meta, isInWatchlist: isInWatchlist)
            )
            NotificationCenter.default.post(name: mutationNotification, object: nil)
            return true
        } catch {
            print("[WeTrakrLibraryService] setWatchlist failed: \(error.localizedDescription)")
            return false
        }
    }

    static func isInWatchlist(
        _ meta: NuvioMeta,
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool? {
        guard let token = WeTrakrRuntimeSession.authenticatedState(store: store)?.accessToken,
              !token.isEmpty else { return nil }
        if let cached = cachedLibraryItems {
            return cached.contains { $0.meta.id == meta.id || WatchedStore.sameContent($0.meta, meta) }
        }
        let fetched = await fetchLibrary(repository: nil, store: store)
        if let fetched {
            return fetched.contains { $0.meta.id == meta.id || WatchedStore.sameContent($0.meta, meta) }
        }
        return nil
    }
}
