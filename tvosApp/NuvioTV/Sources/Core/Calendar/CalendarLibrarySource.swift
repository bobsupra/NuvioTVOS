import Foundation

/// Connects manual calendar follows and watched sources to TMDB resolution.
enum CalendarLibrarySource {
    struct CalendarItems: Sendable {
        let metas: [NuvioMeta]
        let items: [CalendarItem]
        let manualFollowItemIDs: Set<String>
        let automaticFollowItemIDs: Set<String>
        let watchedSourceSignature: String
        let continueWatchingSourceSignature: String

        var watchSourceSignature: String {
            "\(watchedSourceSignature)|\(continueWatchingSourceSignature)"
        }
    }

    static func item(for meta: NuvioMeta) -> CalendarItem {
        CalendarItem(
            id: meta.id,
            kind: meta.isSeries ? .series : .movie,
            type: meta.type,
            name: meta.name,
            posterURL: meta.posterUrl,
            year: meta.year,
            imdbId: NuvioMeta.canonicalImdbID(from: meta.imdbId ?? ""),
            tmdbId: meta.tmdbId
        )
    }

    private static func meta(for item: CalendarItem) -> NuvioMeta {
        NuvioMeta(
            id: item.id,
            name: item.name ?? item.id,
            posterUrl: item.posterURL,
            imdbId: NuvioMeta.canonicalImdbID(from: item.imdbId ?? item.id),
            tmdbId: item.tmdbId ?? tmdbID(from: item.id),
            type: item.type.isEmpty ? (item.kind == .series ? "series" : "movie") : item.type,
            year: item.year
        )
    }

    private static func tmdbID(from id: String) -> Int? {
        guard id.hasPrefix("tmdb:") else { return nil }
        return Int(id.dropFirst("tmdb:".count))
    }

    /// Keeps manual follows first so their metadata wins when another source
    /// has the same item id; watched and progress rows are auto-followed.
    static func calendarItems(
        manualFollows: [CalendarItem],
        watchedItems: [WatchedStoreItem],
        continueWatchingItems: [ContinueWatchingItem],
        additionalContinueWatchingMetas: [NuvioMeta] = [],
        additionalContinueWatchingIDs: [String] = []
    ) -> CalendarItems {
        let manualMetas = manualFollows.map(meta(for:))
        let watchedMetas = watchedItems.compactMap { $0.meta.isSeries ? $0.meta : nil }
        let inProgressMetas = continueWatchingItems.compactMap { $0.meta.isSeries ? $0.meta : nil }
            + additionalContinueWatchingMetas.filter(\.isSeries)
        let manualIDs = Set(manualFollows.map(\.sourceIdentityKey))
        let automaticIDs = Set((watchedMetas + inProgressMetas).map { item(for: $0).sourceIdentityKey })
        let watchedSourceSignature = watchedIdentitySignature(watchedItems)
        let continueWatchingSourceSignature = continueWatchingIdentitySignature(
            continueWatchingItems,
            additionalIDs: additionalContinueWatchingIDs
        )

        var metas: [NuvioMeta] = []
        var items: [CalendarItem] = []
        var indicesByIdentity: [String: Int] = [:]
        for meta in manualMetas + watchedMetas + inProgressMetas {
            let calendarItem = item(for: meta)
            let key = calendarItem.sourceIdentityKey
            if let index = indicesByIdentity[key] {
                // Keep the first source's title/artwork, while recovering ids
                // that a richer watched/progress copy may have.
                let merged = metas[index].fillingMissingHeroMetadata(from: meta)
                metas[index] = merged
                items[index] = item(for: merged)
            } else {
                indicesByIdentity[key] = metas.count
                metas.append(meta)
                items.append(calendarItem)
            }
        }
        return CalendarItems(
            metas: metas,
            items: items,
            manualFollowItemIDs: manualIDs,
            automaticFollowItemIDs: automaticIDs,
            watchedSourceSignature: watchedSourceSignature,
            continueWatchingSourceSignature: continueWatchingSourceSignature
        )
    }

    static func sourceIdentitySignature(
        watchedItems: [WatchedStoreItem],
        continueWatchingItems: [ContinueWatchingItem]
    ) -> String {
        "\(watchedIdentitySignature(watchedItems))|\(continueWatchingIdentitySignature(continueWatchingItems))"
    }

    static func watchedIdentitySignature(_ watchedItems: [WatchedStoreItem]) -> String {
        let keys = watchedItems
            .filter { $0.meta.isSeries }
            .map { sourceIdentity(for: $0.meta) }
        return Set(keys).sorted().joined(separator: ",")
    }

    static func continueWatchingIdentitySignature(_ continueWatchingItems: [ContinueWatchingItem]) -> String {
        continueWatchingIdentitySignature(continueWatchingItems, additionalIDs: [])
    }

    static func continueWatchingIdentitySignature(
        _ continueWatchingItems: [ContinueWatchingItem],
        additionalIDs: [String]
    ) -> String {
        let itemKeys = continueWatchingItems
            .filter { $0.meta.isSeries }
            .map { sourceIdentity(for: $0.meta) }
        let recordKeys = additionalIDs.map { id in
            let item = CalendarItem(id: id, kind: .series)
            let imdb = NuvioMeta.canonicalImdbID(from: id) ?? ""
            return "\(item.sourceIdentityKey):\(imdb):"
        }
        return Set(itemKeys + recordKeys).sorted().joined(separator: ",")
    }

    private static func sourceIdentity(for meta: NuvioMeta) -> String {
        let item = item(for: meta)
        let imdb = NuvioMeta.canonicalImdbID(from: meta.imdbId ?? "") ?? ""
        let tmdb = meta.tmdbId.map(String.init) ?? ""
        return "\(item.sourceIdentityKey):\(imdb):\(tmdb)"
    }

    /// Continue Watching follows the selected progress source. Remote providers
    /// own their snapshot; local ledger pages are only used for Nuvio Sync.
    @MainActor
    static func cachedContinueWatchingItems() -> [ContinueWatchingItem] {
        if RemoteTrackingState.isProgressSourceAuthenticated {
            return TraktProgressService.currentContinueWatchingItems(
                source: TraktSettingsStore.watchProgressSource
            ) ?? []
        }
        return ContinueWatchingBuilder.mergeMemoryOnlyItems(
            ContinueWatchingBuilder.memoryOnlyPagedItems,
            with: ContinueWatchingStore.items()
        )
    }

    /// Raw local progress includes every eligible series in the ledger, even
    /// when the Home row has only materialized its first pages.
    @MainActor
    static func localContinueWatchingIdentityIDs() -> [String] {
        guard !RemoteTrackingState.isProgressSourceAuthenticated else { return [] }
        let records = WatchProgressLedger.continueWatchingCandidates()
            + WatchProgressLedger.upNextSeeds()
        var seen = Set<String>()
        return records.compactMap { record in
            guard record.isSeries, seen.insert(record.contentId).inserted else { return nil }
            return record.contentId
        }
    }

    /// Resolves add-on and provider IDs in the local ledger before handing
    /// them to TMDB. IMDb/TMDB IDs already resolve directly and need no lookup.
    @MainActor
    static func localContinueWatchingMetas(
        for identityIDs: [String],
        profileContext: CalendarManualFollowStore.ProfileContext,
        repository: CatalogRepository = CinemetaCatalogRepository()
    ) async -> [NuvioMeta] {
        guard profileContext.isCurrent,
              !RemoteTrackingState.isProgressSourceAuthenticated else { return [] }
        var result = [NuvioMeta?](repeating: nil, count: identityIDs.count)
        var unresolved: [(Int, String)] = []
        for (index, id) in identityIDs.enumerated() {
            let imdb = NuvioMeta.canonicalImdbID(from: id)
            let tmdb = tmdbID(from: id)
            if imdb != nil || tmdb != nil {
                result[index] = NuvioMeta(id: id, name: "", imdbId: imdb, tmdbId: tmdb, type: "series")
            } else {
                unresolved.append((index, id))
            }
        }

        let batchSize = 6
        var start = 0
        while start < unresolved.count {
            guard !Task.isCancelled, profileContext.isCurrent else { return [] }
            let end = min(start + batchSize, unresolved.count)
            let batch = Array(unresolved[start..<end])
            let resolvedBatch = await withTaskGroup(of: (Int, NuvioMeta?).self) { group in
                for (index, id) in batch {
                    group.addTask { @MainActor in
                        guard !Task.isCancelled, profileContext.isCurrent else { return (index, nil) }
                        let meta = try? await repository.getMetadata(id: id, type: "series")
                        guard !Task.isCancelled, profileContext.isCurrent else { return (index, nil) }
                        return (index, meta?.isSeries == true ? meta : nil)
                    }
                }
                var values: [(Int, NuvioMeta?)] = []
                for await value in group { values.append(value) }
                return values
            }
            for (index, meta) in resolvedBatch { result[index] = meta }
            start = end
        }
        guard !Task.isCancelled, profileContext.isCurrent else { return [] }
        return result.compactMap { $0 }
    }

    @MainActor
    static func currentContinueWatchingSourceSignature() -> String {
        continueWatchingIdentitySignature(
            cachedContinueWatchingItems(),
            additionalIDs: localContinueWatchingIdentityIDs()
        )
    }

    @MainActor
    static func fetchContinueWatchingItems(
        repository: CatalogRepository = CinemetaCatalogRepository()
    ) async -> [ContinueWatchingItem] {
        guard RemoteTrackingState.isProgressSourceAuthenticated else {
            return cachedContinueWatchingItems()
        }
        let source = TraktSettingsStore.watchProgressSource
        guard let fetched = await TraktProgressService.fetchContinueWatching(
            repository: repository,
            source: source,
            replaceSnapshot: false
        ) else {
            return cachedContinueWatchingItems()
        }
        return fetched
    }

    /// TMDB must be switched on and have a key, as for every other TMDB
    /// feature in Nuvio.
    static var isTmdbConfigured: Bool {
        let store = ProfileSettings.current
        let enabled = (store.object(forKey: SettingsKey.tmdbEnabled) as? Bool) ?? false
        return enabled && !(TmdbDetailsService.currentApiKey ?? "").isEmpty
    }

    static func makeClient() -> CalendarTmdb.Client {
        CalendarTmdb.Client(
            apiKey: TmdbDetailsService.currentApiKey ?? "",
            language: TmdbDetailsService.preferredLanguage
        )
    }

    /// Region for movie release dates, from the device locale.
    static var region: String {
        Locale.current.region?.identifier ?? "US"
    }

    static func makeService(metas: [NuvioMeta]) -> CalendarService {
        let byKey = Dictionary(
            metas.map { ("\(item(for: $0).kind.rawValue):\($0.id)", $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return CalendarService(
            client: makeClient(), region: region, animeTimes: CalendarAnimeTimes(), aniList: CalendarAniList.live()
        ) { item in
            guard let meta = byKey["\(item.kind.rawValue):\(item.id)"] else { return nil }
            return await TmdbDetailsService.resolveTmdbId(for: meta)?.id
        }
    }
}
