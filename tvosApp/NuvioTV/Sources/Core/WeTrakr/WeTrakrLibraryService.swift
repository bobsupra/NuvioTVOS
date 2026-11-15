import Foundation

@MainActor
enum WeTrakrLibraryService {
    static let mutationNotification = Notification.Name("nuvio.tv.wetrakr.library.mutation")
    static let client = WeTrakrAPIClient()
    /// The last fetched library, for the profile it was fetched for. One cache
    /// for every profile would let one profile's mutation, or its list, show
    /// under another.
    private static var cachedLibrary: (owner: String, items: [LibraryStoreItem])?

    /// The profile a settings store belongs to and its linked WeTrakr account:
    /// a relink on the same profile is another owner.
    static func cacheOwner(for store: UserDefaults) -> String {
        let id = store.string(forKey: "nuvio.tv.profile.settings.profileID")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(id.isEmpty ? "default" : id)|\(WeTrakrAuthStore.accountBindingID(in: store))"
    }

    /// Replaces the cache with `store`'s profile's items.
    static func replaceCachedItems(_ items: [LibraryStoreItem], for store: UserDefaults) {
        cachedLibrary = (cacheOwner(for: store), items)
    }

    /// The cached items, only if they belong to `store`'s profile.
    static func cachedItems(for store: UserDefaults) -> [LibraryStoreItem]? {
        guard let cachedLibrary, cachedLibrary.owner == cacheOwner(for: store) else { return nil }
        return cachedLibrary.items
    }

    static func fetchLibrary(
        repository: CatalogRepository? = nil,
        store: UserDefaults = ProfileSettings.current,
        updateCachedLibraryItems: Bool = true,
        requireSuccessfulResponses: Bool = false,
        tokenStorage: WeTrakrTokenStorage = WeTrakrKeychainTokenStorage(),
        profileScope: String? = nil,
        client: WeTrakrAPIClient = WeTrakrLibraryService.client
    ) async -> [LibraryStoreItem]? {
        guard let token = WeTrakrRuntimeSession.authenticatedState(
            store: store, tokenStorage: tokenStorage, profileScope: profileScope
        )?.accessToken,
              !token.isEmpty else { return nil }
        let clientID = WeTrakrConfig.clientID(in: store)
        // Whose list this is: the profile and the account linked when the token
        // was read. Checked again once the answers arrive (below).
        let owner = cacheOwner(for: store)

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
        // The profile was relinked to another account while these were out: this is
        // the previous account's list, so it is neither cached nor returned as the
        // current one's. A late answer can't replace the new account's cache either.
        guard cacheOwner(for: store) == owner else { return nil }
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
            cachedLibrary = (owner, items)
        }
        return items
    }

    static func setWatchlist(
        _ meta: NuvioMeta,
        isInWatchlist: Bool,
        store: UserDefaults = ProfileSettings.current,
        profileScope: String? = nil,
        tokenStorage: WeTrakrTokenStorage = WeTrakrKeychainTokenStorage(),
        client: WeTrakrAPIClient = WeTrakrLibraryService.client
    ) async -> Bool {
        guard let token = WeTrakrRuntimeSession.authenticatedState(
            store: store, tokenStorage: tokenStorage, profileScope: profileScope
        )?.accessToken,
              !token.isEmpty else { return false }
        let clientID = WeTrakrConfig.clientID(in: store)
        let ids = WeTrakrProgressService.wetrakrIDs(for: meta)
        guard ids.hasUsableIdentifier else { return false }
        // Who this write is for: the profile and the account linked now. Once the
        // answer arrives, its cache and UI are only touched if both still hold.
        let owner = cacheOwner(for: store)
        func ownerIsCurrent() -> Bool {
            ProfileSettings.isActiveStore(store) && cacheOwner(for: store) == owner
        }

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

                // Only this profile's and account's cache, never another's.
                if ownerIsCurrent(), var current = cachedItems(for: store),
                   !current.contains(where: { $0.meta.id == meta.id || WatchedStore.sameContent($0.meta, meta) }) {
                    current.insert(LibraryStoreItem(meta: meta, addedAt: Date()), at: 0)
                    cachedLibrary = (owner, current)
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

                if ownerIsCurrent(), var current = cachedItems(for: store) {
                    current.removeAll(where: { $0.meta.id == meta.id || WatchedStore.sameContent($0.meta, meta) })
                    cachedLibrary = (owner, current)
                }
            }

            // WeTrakr applied it: that's the result. The visible library is only
            // told while this profile and this account are still the current ones.
            if ownerIsCurrent() {
                NotificationCenter.default.post(
                    name: TraktLibraryService.mutationNotification,
                    object: TraktLibraryMutation(meta: meta, isInWatchlist: isInWatchlist)
                )
                NotificationCenter.default.post(name: mutationNotification, object: nil)
            }
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
        if let cached = cachedItems(for: store) {
            return cached.contains { $0.meta.id == meta.id || WatchedStore.sameContent($0.meta, meta) }
        }
        let fetched = await fetchLibrary(repository: nil, store: store)
        if let fetched {
            return fetched.contains { $0.meta.id == meta.id || WatchedStore.sameContent($0.meta, meta) }
        }
        return nil
    }
}
