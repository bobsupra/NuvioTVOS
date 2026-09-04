//
//  CatalogRepository.swift
//  NuvioTV
//
//  Repository protocol for catalog operations
//

import Foundation

/// Repository protocol for catalog operations
protocol CatalogRepository {
    /// Get catalogs for home screen
    func getHomeCatalogs() async throws -> [NuvioCatalog]

    /// Progressive Home variant: yields the accumulated catalog list whenever
    /// another provider row becomes available. Repositories that only support
    /// batch loading fall back to one yield from `getHomeCatalogs()`.
    func homeCatalogsProgressively() -> AsyncThrowingStream<[NuvioCatalog], Error>

    /// True when the latest Home request returned usable rows but one or more
    /// expected sources failed. Home uses this to replace a partial cache once.
    var homeCatalogLoadWasPartial: Bool { get }

    /// Stable description of what failed in the latest Home request, or nil
    /// when everything loaded. An unchanged signature across two attempts means
    /// the failure is permanent — a dead add-on URL, or a catalog its host
    /// always rejects — so retrying re-fetches every row to recover nothing.
    var homeCatalogFailureSignature: String? { get }

    /// Signature of the add-on and catalog settings the next Home request would
    /// read. Unchanged between loads means a reload rebuilds the same tree.
    var homeCatalogInputSignature: String { get }

    /// Get metadata for a specific content item. `type` ("movie"/"series") is
    /// carried from the catalog item so the correct meta endpoint is queried —
    /// series ids have no reliable marker to guess from.
    func getMetadata(id: String, type: String) async throws -> NuvioMeta

    /// Fetch current metadata without using an in-memory result from an earlier
    /// Home load. Up-next entries need this because episode guides can gain a
    /// title, overview, and still after the series record was first cached.
    func refreshMetadata(id: String, type: String) async throws -> NuvioMeta

    /// Get available streams for content
    func getStreams(id: String, type: String) async throws -> [NuvioStream]

    /// Fetch subtitle add-ons independently from streams. The player uses this
    /// after it opens so resume playback and early stream picks can keep filling
    /// an already-visible subtitle panel as slower providers finish.
    func subtitlesProgressively(id: String, type: String) -> AsyncStream<[NuvioSubtitle]>

    /// Progressive variant of `getStreams`: yields the accumulated stream list
    /// each time another add-on returns, so the picker can show the first
    /// add-on's results immediately and keep filling in the rest as they land
    /// (mirrors how Stremio/Fusion surface streams). The default falls back to
    /// a single `getStreams` batch for repositories that don't override it.
    func streamsProgressively(id: String, type: String) -> AsyncStream<[NuvioStream]>

    /// Search for content
    func search(query: String) async throws -> [NuvioMeta]

    /// Browse catalog with pagination and filters
    func browseCatalog(
        contentType: String,
        catalogId: String,
        page: Int,
        genre: String?,
        year: Int?,
        sort: String?
    ) async throws -> CatalogPage

    /// Browse catalog using a Stremio skip offset.
    func browseCatalog(
        contentType: String,
        catalogId: String,
        skip: Int,
        genre: String?
    ) async throws -> CatalogPage

    /// Browse a Home catalog from its original add-on. A nil add-on id uses
    /// the built-in Cinemeta base URL.
    func browseCatalog(
        addonId: String?,
        contentType: String,
        catalogId: String,
        skip: Int,
        genre: String?
    ) async throws -> CatalogPage

    /// Get available genres for content type
    func getGenres(contentType: String) async throws -> [String]

    /// Resolve a synced collection folder's add-on catalog sources into items.
    /// Unresolvable sources (unknown add-on ids, TMDB/Trakt) are skipped.
    func getCollectionFolderItems(sources: [NuvioCollectionCatalogSource], limit: Int) async -> [NuvioMeta]
}

extension CatalogRepository {
    var homeCatalogLoadWasPartial: Bool { false }

    var homeCatalogFailureSignature: String? { nil }

    var homeCatalogInputSignature: String { "" }

    func homeCatalogsProgressively() -> AsyncThrowingStream<[NuvioCatalog], Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let catalogs = try await getHomeCatalogs()
                    if !Task.isCancelled {
                        continuation.yield(catalogs)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func browseCatalog(
        addonId: String?,
        contentType: String,
        catalogId: String,
        skip: Int,
        genre: String?
    ) async throws -> CatalogPage {
        try await browseCatalog(
            contentType: contentType,
            catalogId: catalogId,
            skip: skip,
            genre: genre
        )
    }

    func refreshMetadata(id: String, type: String) async throws -> NuvioMeta {
        try await getMetadata(id: id, type: type)
    }

    /// Fallback progressive wrapper: emits the full `getStreams` result as a
    /// single batch. Repositories that fetch from multiple add-ons should
    /// override this to emit results as each add-on returns.
    func streamsProgressively(id: String, type: String) -> AsyncStream<[NuvioStream]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let streams = try await getStreams(id: id, type: type)
                    if !Task.isCancelled { continuation.yield(streams) }
                } catch {
                    print("Failed to load streams: \(error.localizedDescription)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func subtitlesProgressively(id: String, type: String) -> AsyncStream<[NuvioSubtitle]> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }
}

/// One process-wide manifest response per URL. Personalized add-ons can rotate
/// their catalog declarations on every manifest request; Settings and Home
/// must decode the same response or their row identities immediately diverge.
actor StremioManifestDataCache {
    static let shared = StremioManifestDataCache()

    private var cachedData: [URL: Data] = [:]
    private var inFlight: [URL: Task<Data?, Never>] = [:]

    func data(for url: URL) async -> Data? {
        if let data = cachedData[url] { return data }
        if let task = inFlight[url] { return await task.value }

        let task = Task<Data?, Never> {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      200..<300 ~= http.statusCode else { return nil }
                return data
            } catch {
                return nil
            }
        }
        inFlight[url] = task
        let data = await task.value
        inFlight[url] = nil
        if let data { cachedData[url] = data }
        return data
    }
}

/// One selectable add-on catalog, offered by the Collections editor when
/// choosing what a folder shows.
struct AddonCatalogOption: Identifiable {
    let addonId: String
    let addonName: String
    let type: String
    let catalogId: String
    let catalogName: String
    var id: String { "\(addonId)_\(type)_\(catalogId)" }
}

struct StreamAddonPreference: Codable, Equatable {
    let url: String
    var enabled: Bool
}

/// Live Cinemeta-backed catalog and metadata repository for the tvOS app.
final class CinemetaCatalogRepository: CatalogRepository {
    static private(set) var homeAddonFetchDiagnostic = "not started"
    private(set) var homeCatalogLoadWasPartial = false
    private(set) var homeCatalogFailureSignature: String?

    /// Everything a Home request reads before it can decide which rows exist.
    /// Sorted so an unordered set or dictionary cannot produce a spurious
    /// difference between two otherwise identical snapshots.
    var homeCatalogInputSignature: String {
        let cinemetaEnabled = Self.isCinemetaEnabled
        let urls = Self.configuredStreamAddonManifestURLs
            .map(\.absoluteString)
            .joined(separator: "|")
        let disabled = TVHomeCatalogOrder.disabledCatalogKeys()
            .sorted()
            .joined(separator: ",")
        let order = TVHomeCatalogOrder.syncedCatalogOrderIndex()
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        let showType = ProfileSettings.current.object(forKey: SettingsKey.homeCatalogShowType) as? Bool ?? true
        return "cinemeta:\(cinemetaEnabled) urls:[\(urls)] disabled:[\(disabled)] order:[\(order)] showType:\(showType)"
    }
    private let baseURL = URL(string: "https://v3-cinemeta.strem.io")!
    private static var cachedMetaById: [String: NuvioMeta] = [:]
    private static var cachedFullMetaIds: Set<String> = []
    private static let metadataCacheQueue = DispatchQueue(label: "nuvio.catalog.metadata-cache", attributes: .concurrent)
    private let builtInSubtitleAddons = [
        StremioSubtitleAddon(
            name: "OpenSubtitles v3",
            manifestURL: URL(string: "https://opensubtitles-v3.strem.io/manifest.json")!
        )
    ]
    private let genres = [
        "Action", "Adventure", "Animation", "Biography", "Comedy",
        "Crime", "Documentary", "Drama", "Family", "Fantasy",
        "History", "Horror", "Mystery", "Romance", "Sci-Fi",
        "Sport", "Thriller", "War", "Western", "Reality-TV",
        "Talk-Show", "Game-Show"
    ]

    func cachedMetadata(for id: String) -> NuvioMeta? {
        Self.metadataCacheQueue.sync { Self.cachedMetaById[id] }
    }

    func isCachedFullMetadata(id: String) -> Bool {
        Self.metadataCacheQueue.sync {
            Self.cachedFullMetaIds.contains(id) && Self.cachedMetaById[id] != nil
        }
    }

    func cacheMetadata(_ meta: NuvioMeta, requestedID: String? = nil) {
        Self.metadataCacheQueue.sync(flags: .barrier) {
            if let requestedID {
                Self.cachedMetaById[requestedID] = meta
                Self.cachedFullMetaIds.insert(requestedID)
            }
            Self.cachedMetaById[meta.id] = meta
            Self.cachedFullMetaIds.insert(meta.id)
        }
    }

    static func isFullMetadata(_ meta: NuvioMeta) -> Bool {
        let isMovieOrSeries = meta.isSeries || meta.type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "movie"
        if isMovieOrSeries && !hasCanonicalIMDbStreamIdentity(meta) {
            return false
        }
        if meta.isSeries {
            return meta.videos?.isEmpty == false
        } else {
            return (meta.tmdbId != nil && meta.tmdbId! > 0) || (meta.director != nil && !meta.director!.isEmpty) || (meta.trailerYtIds != nil && !meta.trailerYtIds!.isEmpty)
        }
    }

    private static func hasCanonicalIMDbStreamIdentity(_ meta: NuvioMeta) -> Bool {
        NuvioMeta.canonicalImdbID(from: meta.streamId) != nil
    }

    private func cacheCatalogMetadata(_ meta: NuvioMeta) {
        Self.metadataCacheQueue.sync(flags: .barrier) {
            if Self.cachedFullMetaIds.contains(meta.id) {
                return
            }
            Self.cachedMetaById[meta.id] = meta
        }
    }

    private func cacheMetadata(_ items: [NuvioMeta]) {
        Self.metadataCacheQueue.sync(flags: .barrier) {
            for item in items {
                if Self.cachedFullMetaIds.contains(item.id) {
                    continue
                }
                Self.cachedMetaById[item.id] = item
            }
        }
    }

    private func removeCachedMetadata(for id: String) {
        Self.metadataCacheQueue.sync(flags: .barrier) {
            _ = Self.cachedMetaById.removeValue(forKey: id)
            Self.cachedFullMetaIds.remove(id)
        }
    }

    func getHomeCatalogs() async throws -> [NuvioCatalog] {
        try await loadHomeCatalogs()
    }

    func homeCatalogsProgressively() -> AsyncThrowingStream<[NuvioCatalog], Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    _ = try await self.loadHomeCatalogs { catalogs in
                        guard !Task.isCancelled else { return }
                        continuation.yield(catalogs)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func loadHomeCatalogs(
        onUpdate: (([NuvioCatalog]) -> Void)? = nil
    ) async throws -> [NuvioCatalog] {
        homeCatalogLoadWasPartial = false
        homeCatalogFailureSignature = nil
        let cinemetaEnabled = Self.isCinemetaEnabled
        let specs: [(id: String, name: String, type: String, catalogId: String)] = [
            ("movie_top", "Popular - Movies", "movie", "top"),
            ("series_top", "Popular - Series", "series", "top"),
            ("movie_rating", "Top Rated - Movies", "movie", "imdbRating"),
            ("series_rating", "Top Rated - Series", "series", "imdbRating")
        ]

        // Load the independent Cinemeta rows concurrently. Previously one
        // transient failure aborted the complete Home request, leaving the
        // screen empty until switching profiles happened to start it again.
        var pages = Array<[NuvioMeta]?>(repeating: nil, count: specs.count)
        if cinemetaEnabled {
            await withTaskGroup(of: (Int, [NuvioMeta]?).self) { group in
                for (index, spec) in specs.enumerated() {
                    group.addTask {
                        let page = try? await self.fetchCatalog(
                            type: spec.type,
                            catalogId: spec.catalogId,
                            skip: nil,
                            search: nil,
                            genre: nil
                        )
                        return (index, page?.isEmpty == false ? page : nil)
                    }
                }
                for await (index, page) in group {
                    pages[index] = page
                }
            }
        }
        try Task.checkCancellation()

        // The built-in rows are Cinemeta catalogs, so they answer to the same
        // hidden-catalog keys as every add-on row — both the account's and the
        // ones Settings writes locally. Without this, hiding "Popular - Movies"
        // was the one toggle Home ignored.
        let disabledBuiltInKeys = TVHomeCatalogOrder.disabledCatalogKeys()

        func builtInCatalogs() -> [NuvioCatalog] {
            guard cinemetaEnabled else { return [] }
            var result: [NuvioCatalog] = []
            for (index, spec) in specs.enumerated() {
                guard let page = pages[index] else { continue }
                guard !disabledBuiltInKeys.contains(
                    TVHomeCatalogOrder.catalogSettingsKey(
                        addonId: Self.cinemetaAddonId,
                        contentType: spec.type,
                        catalogId: spec.catalogId
                    )
                ) else { continue }
                cacheMetadata(page)
                result.append(
                    NuvioCatalog(
                        id: spec.id,
                        name: spec.name,
                        description: spec.name,
                        itemIds: page.map(\.id),
                        items: page,
                        contentType: spec.type,
                        catalogId: spec.catalogId,
                        addonId: Self.cinemetaAddonId,
                        addonName: Self.cinemetaDisplayName
                    )
                )
            }
            return result
        }

        // Publish the base rows now. Add-on catalogs can be slow or numerous;
        // they must not hold already-loaded rows off Home.
        var catalogs = builtInCatalogs()
        if !catalogs.isEmpty {
            onUpdate?(catalogs)
        }

        // Retry only missing rows once after a short backoff. Successful rows
        // remain usable and are never discarded because a sibling host request
        // failed.
        let missing = pages.indices.filter { pages[$0] == nil }
        if cinemetaEnabled && !missing.isEmpty {
            try await Task.sleep(nanoseconds: 600_000_000)
            try Task.checkCancellation()
            await withTaskGroup(of: (Int, [NuvioMeta]?).self) { group in
                for index in missing {
                    let spec = specs[index]
                    group.addTask {
                        let page = try? await self.fetchCatalog(
                            type: spec.type,
                            catalogId: spec.catalogId,
                            skip: nil,
                            search: nil,
                            genre: nil
                        )
                        return (index, page?.isEmpty == false ? page : nil)
                    }
                }
                for await (index, page) in group where page != nil {
                    pages[index] = page
                }
            }
            try Task.checkCancellation()
        }

        let retriedBuiltIns = builtInCatalogs()
        if retriedBuiltIns.count != catalogs.count {
            catalogs = retriedBuiltIns
            onUpdate?(catalogs)
        }

        // Each successful add-on row is appended and published immediately.
        // A failed sibling no longer prevents later catalogs from appearing.
        var progressiveAddonCatalogs: [NuvioCatalog] = []
        let addonResult = await addonHomeCatalogs { [weak self] catalog in
            guard let self else { return }
            progressiveAddonCatalogs.append(catalog)
            onUpdate?(catalogs + self.orderedAddonCatalogs(progressiveAddonCatalogs))
        }
        try Task.checkCancellation()
        catalogs.append(contentsOf: addonResult.catalogs)
        let missingBuiltIns = pages.indices
            .filter { pages[$0] == nil }
            .map(String.init)
            .joined(separator: ",")
        homeCatalogLoadWasPartial = !missingBuiltIns.isEmpty || addonResult.hadFailures
        // Built from the same per-add-on report the diagnostic uses, so the
        // signature changes whenever any row's outcome changes -- and only then.
        homeCatalogFailureSignature = homeCatalogLoadWasPartial
            ? "builtin:[\(missingBuiltIns)] addons:[\(Self.homeAddonFetchDiagnostic)]"
            : nil
        guard !catalogs.isEmpty else { throw URLError(.cannotLoadFromNetwork) }
        return catalogs
    }

    /// Home rows from the configured add-ons' manifest catalogs, mirroring the
    /// Android app: user-configured add-ons (MDBList, AIOStreams, …) expose
    /// custom catalogs — Marvel, actors, lists — that belong on Home. Search-
    /// only catalogs and ones needing unsupported extras are skipped; a
    /// required genre is satisfied with the catalog's first declared option.
    private func addonHomeCatalogs(
        onCatalogLoaded: ((NuvioCatalog) -> Void)? = nil
    ) async -> (catalogs: [NuvioCatalog], hadFailures: Bool) {
        // Catalogs the user hid from Home on another device (synced from the
        // account). Their key format matches the tvOS catalog id sans `addon_`.
        let disabledCatalogKeys = TVHomeCatalogOrder.disabledCatalogKeys()
        let syncedHomeKeys = Set(TVHomeCatalogOrder.syncedCatalogOrderIndex().keys)
        let collectionSources: [CatalogHomeVisibilityResolver.Source] = CollectionsStore.collections().flatMap { collection in
            collection.folders.flatMap { $0.resolvedSources }
                .filter { $0.normalizedProvider == "addon" }
                .compactMap { source in
                    guard let addonId = source.addonId, let type = source.type, let catalogId = source.catalogId else { return nil }
                    return CatalogHomeVisibilityResolver.Source(addonIdentifier: addonId, contentType: type, catalogID: catalogId, collectionID: collection.id)
                }
        }
        var catalogs: [NuvioCatalog] = []
        var reports: [String] = []
        var hadFailures = false
        Self.homeAddonFetchDiagnostic = "loading"

        for manifestURL in Self.configuredStreamAddonManifestURLs {
            guard !Task.isCancelled else { break }
            guard let manifest = await manifest(for: manifestURL) else {
                guard !Task.isCancelled else { break }
                hadFailures = true
                reports.append("\(manifestURL.host ?? "unknown"): manifest failed")
                continue
            }
            guard manifest.id != Self.cinemetaAddonId else { continue }

            let base = manifestURL.deletingLastPathComponent()
            let eligible = (manifest.catalogs ?? []).filter { catalog in
                guard catalog.eligibleForHome else { return false }
                let key = "\(manifest.id)_\(catalog.type)_\(catalog.id)"
                guard CatalogHomeVisibilityResolver.shouldInclude(
                    addonID: manifest.id,
                    contentType: catalog.type,
                    catalogID: catalog.id,
                    collectionSources: collectionSources,
                    manifestURL: manifestURL,
                    explicitHomeKeys: syncedHomeKeys
                ) else { return false }
                guard !disabledCatalogKeys.contains(key) else {
                    return false
                }
                return !catalog.requiresGenre || catalog.firstGenreOption != nil
            }

            func load(_ catalog: AddonManifestCatalog) async -> NuvioCatalog? {
                do {
                    let catalogGenre = catalog.requiresGenre ? catalog.firstGenreOption : nil
                    let url = try StremioCatalogURLBuilder.url(
                        baseURL: base,
                        type: catalog.type,
                        catalogId: catalog.id,
                        genre: catalogGenre
                    )
                    let response: CinemetaCatalogResponse = try await fetch(
                        url
                    )
                    let items = response.metas.map { $0.toMeta(fallbackType: catalog.type) }
                    guard !items.isEmpty else { return nil }
                    cacheMetadata(items)
                    let catalogName = TVHomeCatalogOrder.catalogDisplayTitle(
                        catalog.name ?? catalog.id,
                        contentType: catalog.type,
                        showType: ProfileSettings.current.object(forKey: SettingsKey.homeCatalogShowType) as? Bool ?? true
                    )
                    return NuvioCatalog(
                        id: "addon_\(manifest.id)_\(catalog.type)_\(catalog.id)",
                        name: catalogName,
                        description: catalogName,
                        itemIds: items.map(\.id),
                        items: items,
                        contentType: catalog.type,
                        catalogId: catalog.id,
                        addonId: manifest.id,
                        addonName: manifest.displayName ?? Self.streamAddonName(for: manifestURL),
                        catalogGenre: catalogGenre
                    )
                } catch {
                    return nil
                }
            }

            // BetterPosters rejects/limits a burst of all 13 catalog requests
            // on some Apple TV networks, so keep requests ordered and serial.
            // Publish each success, then retry only this manifest's missing rows.
            var loadedForManifest = 0
            var missingForManifest: [AddonManifestCatalog] = []
            for catalog in eligible {
                guard !Task.isCancelled else { break }
                if let loaded = await load(catalog) {
                    catalogs.append(loaded)
                    loadedForManifest += 1
                    onCatalogLoaded?(loaded)
                } else if !Task.isCancelled {
                    missingForManifest.append(catalog)
                }
            }

            if !missingForManifest.isEmpty, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 600_000_000)
                var stillMissing: [AddonManifestCatalog] = []
                for catalog in missingForManifest {
                    guard !Task.isCancelled else { break }
                    if let loaded = await load(catalog) {
                        catalogs.append(loaded)
                        loadedForManifest += 1
                        onCatalogLoaded?(loaded)
                    } else if !Task.isCancelled {
                        stillMissing.append(catalog)
                    }
                }
                missingForManifest = stillMissing
            }

            hadFailures = hadFailures || !missingForManifest.isEmpty
            reports.append(
                "\(manifest.id): \(loadedForManifest)/\(eligible.count) loaded"
                    + ", \((manifest.catalogs ?? []).count) declared"
                    + ", failed \(missingForManifest.count)"
            )
        }

        Self.homeAddonFetchDiagnostic = reports.isEmpty ? "no add-on catalogs" : reports.joined(separator: "; ")
        return (orderedAddonCatalogs(catalogs), hadFailures)
    }

    private func orderedAddonCatalogs(_ catalogs: [NuvioCatalog]) -> [NuvioCatalog] {
        // Order the add-on rows to match the account's Home layout. Rows the
        // account hasn't placed keep their natural (manifest) order, after the
        // placed ones — mirroring the phone/Google-TV apps.
        let orderIndex = TVHomeCatalogOrder.syncedCatalogOrderIndex()
        guard !orderIndex.isEmpty else { return catalogs }
        return catalogs
            .enumerated()
            .sorted { lhs, rhs in
                let lKey = Self.accountCatalogKey(fromCatalogId: lhs.element.id)
                let rKey = Self.accountCatalogKey(fromCatalogId: rhs.element.id)
                let lRank = orderIndex[lKey] ?? Int.max
                let rRank = orderIndex[rKey] ?? Int.max
                return lRank != rRank ? lRank < rRank : lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Maps an add-on catalog's tvOS id (`addon_<addonId>_<type>_<catalogId>`)
    /// back to the account key format (`<addonId>_<type>_<catalogId>`) used by
    /// the synced Home layout.
    private static func accountCatalogKey(fromCatalogId id: String) -> String {
        id.hasPrefix("addon_") ? String(id.dropFirst("addon_".count)) : id
    }

    func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        if let jellyfinMeta = await JellyfinLibraryIndex.shared.meta(forContentId: id) {
            return jellyfinMeta
        }
        let cached = cachedMetadata(for: id)
        if let cached, isCachedFullMetadata(id: id) {
            return await TmdbDetailsService.localizedMetadata(for: cached)
        }

        return try await loadMetadata(id: id, type: type, cachedIsSeriesHint: cached?.isSeries)
    }

    func refreshMetadata(id: String, type: String) async throws -> NuvioMeta {
        if let jellyfinMeta = await JellyfinLibraryIndex.shared.meta(forContentId: id) {
            return jellyfinMeta
        }
        // A catalog can report `type: movie` while its nonempty videos prove
        // that it is a series. Keep that inference while replacing the cache,
        // otherwise refresh falls back to the wrong Cinemeta endpoint.
        let cachedIsSeriesHint = cachedMetadata(for: id)?.isSeries
        removeCachedMetadata(for: id)
        return try await loadMetadata(id: id, type: type, cachedIsSeriesHint: cachedIsSeriesHint)
    }

    private func loadMetadata(id: String, type: String, cachedIsSeriesHint: Bool? = nil) async throws -> NuvioMeta {
        // Query the correct endpoint based on the caller-provided type. The
        // Details screen uses a fresh repository (empty cache) so this always
        // fetches the full /meta payload — real episodes and per-episode ratings.
        let isSeries = Self.isSeriesType(type) || cachedIsSeriesHint == true
        let isLive = Self.isLiveContentType(type)
        let metaType = isSeries ? "series" : "movie"
        var lastError: Error?
        var resolvedId = NuvioMeta.canonicalImdbID(from: id) ?? id

        // Map tmdb:123 → imdb when TMDB is configured so Cinemeta can resolve.
        if id.hasPrefix("tmdb:"),
           let tmdbNum = Int(id.dropFirst(5)),
           let imdb = await Self.resolveImdbFromTmdb(tmdbId: tmdbNum, type: metaType) {
            resolvedId = imdb
        }

        // Same for simkl:123. Simkl's recommendation payload carries only its
        // own id, so the trade happens here — once, for the card the user
        // opened — instead of for every card in the More Like This row.
        if id.hasPrefix("simkl:"),
           let imdb = await SimklDetailsService.resolveImdbID(
               simklID: String(id.dropFirst(6)),
               type: metaType
           ) {
            resolvedId = imdb
        }

        let resolvedCanonicalImdbID = NuvioMeta.canonicalImdbID(from: resolvedId)

        // Cinemeta only resolves IMDb ids; other id spaces synced from the
        // phone app (tmdb:, kitsu:, ...) must come from the configured add-ons.
        if !isLive, let resolvedCanonicalImdbID {
            for candidateType in Self.cinemetaMetadataTypesToTry(
                primaryType: metaType,
                canonicalImdbID: resolvedCanonicalImdbID
            ) {
                do {
                    let url = baseURL
                        .appendingPathComponent("meta")
                        .appendingPathComponent(candidateType)
                        .appendingPathComponent("\(resolvedId).json")
                    let response: CinemetaMetaResponse = try await fetch(url)
                    let rawMeta = response.meta.toMeta(fallbackType: candidateType)

                    // If Cinemeta returns a movie record with 0 videos for an IMDb ID, but it
                    // has series markers or Cinemeta's series endpoint has episodes, adopt the
                    // real series metadata instead of getting trapped by the hollow movie stub.
                    let looksLikeSeries = rawMeta.isSeries
                        || Self.isSeriesType(rawMeta.type)
                        || isSeries
                        || (rawMeta.releaseInfo?.contains("–") == true || rawMeta.releaseInfo?.contains("-") == true)
                    if candidateType == "movie" && (rawMeta.videos?.isEmpty ?? true) && looksLikeSeries {
                        let seriesURL = baseURL
                            .appendingPathComponent("meta")
                            .appendingPathComponent("series")
                            .appendingPathComponent("\(resolvedId).json")
                        if let seriesResponse: CinemetaMetaResponse = try? await fetch(seriesURL),
                           let seriesVideos = seriesResponse.meta.videos, !seriesVideos.isEmpty {
                            let seriesMeta = await TmdbDetailsService.localizedMetadata(
                                for: seriesResponse.meta.toMeta(fallbackType: "series")
                            )
                            cacheMetadata(seriesMeta, requestedID: id)
                            return seriesMeta
                        }
                    }

                    let meta = await TmdbDetailsService.localizedMetadata(for: rawMeta)
                    cacheMetadata(meta, requestedID: id)
                    return meta
                } catch {
                    lastError = error
                }
            }
        }

        let typesToTry: [String]
        if isLive {
            typesToTry = [type]
        } else if type.lowercased() == metaType {
            typesToTry = [type]
        } else {
            typesToTry = [type, metaType]
        }

        for candidateType in typesToTry {
            for addon in await configuredAddons(supporting: "meta", type: candidateType, id: resolvedId) {
                guard let metaURL = addon.metaURL(type: candidateType, id: resolvedId) else { continue }
                do {
                    let response: CinemetaMetaResponse = try await fetch(metaURL)
                    let meta = await TmdbDetailsService.localizedMetadata(
                        for: response.meta.toMeta(fallbackType: candidateType)
                    )
                    // Cache under the requested id too in case the addon
                    // canonicalizes to a different id space.
                    cacheMetadata(meta, requestedID: id)
                    return meta
                } catch {
                    if lastError == nil { lastError = error }
                }
            }
        }

        // If no /meta endpoint returned a response, check if the item was already cached from a catalog
        if let cached = cachedMetadata(for: id) ?? cachedMetadata(for: resolvedId) {
            return await TmdbDetailsService.localizedMetadata(for: cached)
        }

        // For Live TV / channel items or non-IMDb streams where the add-on provides streams
        // but no dedicated /meta endpoint, synthesize a fallback NuvioMeta so details and playback can proceed.
        if isLive || !resolvedId.hasPrefix("tt") {
            let fallbackMeta = NuvioMeta(
                id: id,
                name: Self.fallbackTitle(forId: id),
                description: nil,
                posterUrl: nil,
                backgroundUrl: nil,
                logoUrl: nil,
                imdbId: resolvedId.hasPrefix("tt") ? resolvedId : nil,
                tmdbId: nil,
                type: type,
                year: nil,
                genres: nil,
                rating: nil,
                releaseInfo: nil,
                runtime: nil,
                cast: nil,
                director: nil,
                writer: nil,
                certification: nil,
                country: nil,
                released: nil,
                status: nil,
                videos: nil,
                trailerYtIds: nil,
                externalRatings: nil
            )
            cacheMetadata(fallbackMeta, requestedID: id)
            return fallbackMeta
        }

        throw lastError ?? URLError(.badServerResponse)
    }

    static func cinemetaMetadataTypesToTry(primaryType: String, canonicalImdbID: String?) -> [String] {
        guard let canonicalImdbID,
              NuvioMeta.canonicalImdbID(from: canonicalImdbID) != nil else {
            return [primaryType]
        }

        let normalizedType = primaryType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalizedType {
        case "series": return ["series", "movie"]
        case "movie": return ["movie", "series"]
        default: return [primaryType]
        }
    }

    /// Best-effort TMDB external_ids lookup so More Like This / production
    /// browse cards that only have `tmdb:` ids can still open in Cinemeta.
    private static func resolveImdbFromTmdb(tmdbId: Int, type: String) async -> String? {
        let apiKey = ProfileSettings.current.string(forKey: SettingsKey.tmdbApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A TMDB-backed collection is an explicit source choice, independent
        // of whether optional Details enrichment is enabled.
        guard !apiKey.isEmpty else { return nil }
        let primaryMedia = isSeriesType(type) ? "tv" : "movie"
        let fallbackMedia = primaryMedia == "tv" ? "movie" : "tv"
        for media in [primaryMedia, fallbackMedia] {
            var components = URLComponents(string: "https://api.themoviedb.org/3/\(media)/\(tmdbId)/external_ids")!
            components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
            guard let url = components.url,
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let imdb = json["imdb_id"] as? String,
                  imdb.hasPrefix("tt") else {
                continue
            }
            return imdb
        }
        return nil
    }

    private static func isSeriesType(_ type: String) -> Bool {
        NuvioMeta.isSeriesType(type)
    }

    static func isLiveContentType(_ type: String) -> Bool {
        switch type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "channel", "live", "livetv", "live-tv", "iptv", "radio":
            return true
        default:
            return false
        }
    }

    static func fallbackTitle(forId id: String) -> String {
        var title = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colonIndex = title.lastIndex(of: ":") {
            title = String(title[title.index(after: colonIndex)...])
        }
        if title.lowercased().hasPrefix("usatv_") {
            title = String(title.dropFirst("usatv_".count))
        } else if title.lowercased().hasPrefix("iptv_") {
            title = String(title.dropFirst("iptv_".count))
        } else if title.lowercased().hasPrefix("channel_") {
            title = String(title.dropFirst("channel_".count))
        }
        title = title.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return id }
        let words = title.split(separator: " ")
        return words.map { word -> String in
            let lower = word.lowercased()
            if ["hd", "sd", "4k", "uhd", "tv", "fhd", "usa", "uk", "espn", "cnn", "hbo", "bbc", "tnt", "tbs", "cbs", "nbc", "abc", "fox"].contains(lower) {
                return word.uppercased()
            }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// Every enabled manifest URL — the manually entered one plus the list synced
    /// from the account — deduplicated in priority order.
    static var configuredStreamAddonManifestURLs: [URL] {
        configuredStreamAddonPreferences.compactMap { preference in
            guard preference.enabled else { return nil }
            return normalizedManifestURL(from: preference.url)
        }
    }

    static func configuredStreamAddonPreferences(in defaults: UserDefaults = ProfileSettings.current) -> [StreamAddonPreference] {
        var preferences: [StreamAddonPreference] = []
        if let json = defaults.string(forKey: SettingsKey.streamAddonManifestStates),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([StreamAddonPreference].self, from: data) {
            preferences.append(contentsOf: decoded)
        }
        preferences.append(contentsOf: legacyStreamAddonURLs(in: defaults).map {
            StreamAddonPreference(url: $0.absoluteString, enabled: true)
        })
        return normalizedPreferences(preferences)
    }

    /// Full ordered add-on state for Settings. The legacy URL fields are still
    /// merged in so manually pasted add-ons appear even before a state blob exists.
    static var configuredStreamAddonPreferences: [StreamAddonPreference] {
        configuredStreamAddonPreferences(in: ProfileSettings.current)
    }

    static func setConfiguredStreamAddonPreferences(
        _ preferences: [StreamAddonPreference],
        in defaults: UserDefaults = ProfileSettings.current
    ) {
        let normalized = normalizedPreferences(preferences)
        let enabledURLs = normalized
            .filter(\.enabled)
            .map(\.url)

        if let data = try? JSONEncoder().encode(normalized),
           let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: SettingsKey.streamAddonManifestStates)
        } else {
            defaults.removeObject(forKey: SettingsKey.streamAddonManifestStates)
        }
        defaults.set(enabledURLs.first ?? "", forKey: SettingsKey.streamAddonManifestURL)
        defaults.set(enabledURLs.joined(separator: "\n"), forKey: SettingsKey.streamAddonManifestURLs)
    }

    private static func legacyStreamAddonURLs(in defaults: UserDefaults) -> [URL] {
        var rawValues = defaults
            .string(forKey: SettingsKey.streamAddonManifestURLs)?
            .components(separatedBy: .newlines) ?? []

        if let single = defaults.string(forKey: SettingsKey.streamAddonManifestURL),
           !single.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawValues.insert(single, at: 0)
        }

        return normalizedURLs(from: rawValues)
    }

    private static func normalizedPreferences(_ preferences: [StreamAddonPreference]) -> [StreamAddonPreference] {
        var seen: Set<String> = []
        return preferences.compactMap { preference -> StreamAddonPreference? in
            guard let url = normalizedManifestURL(from: preference.url) else { return nil }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return nil }
            return StreamAddonPreference(url: key, enabled: preference.enabled)
        }
    }

    private static func normalizedURLs(from rawValues: [String]) -> [URL] {
        var seen: Set<String> = []
        return rawValues.compactMap { rawValue -> URL? in
            guard let url = normalizedManifestURL(from: rawValue) else { return nil }
            guard seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    private func configuredAddons(supporting resource: String, type: String, id: String) async -> [StremioStreamAddon] {
        let urls = Self.configuredStreamAddonManifestURLs
        // Load missing manifests concurrently so a slow host cannot serialize
        // compatibility checks for every other add-on.
        await withTaskGroup(of: Void.self) { group in
            for manifestURL in urls {
                group.addTask { _ = await self.manifest(for: manifestURL) }
            }
        }

        var addons: [StremioStreamAddon] = []
        for manifestURL in urls {
            guard let manifest = await manifest(for: manifestURL),
                  manifest.supportsResource(resource, type: type, id: id) else { continue }
            addons.append(
                StremioStreamAddon(
                    name: manifest.displayName ?? Self.streamAddonName(for: manifestURL),
                    manifestURL: manifestURL
                )
            )
        }
        return addons
    }

    static func normalizedManifestURL(from rawValue: String) -> URL? {
        var normalizedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else { return nil }

        if normalizedValue.lowercased().hasPrefix("stremio://") {
            normalizedValue = "https://\(String(normalizedValue.dropFirst("stremio://".count)))"
        } else if !normalizedValue.contains("://") {
            normalizedValue = "https://\(normalizedValue)"
        }

        guard let url = URL(string: normalizedValue),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            return nil
        }

        if url.lastPathComponent.lowercased().hasSuffix(".json") {
            return url
        }
        return url.appendingPathComponent("manifest.json")
    }

    static func streamAddonName(for manifestURL: URL) -> String {
        guard let host = manifestURL.host?.replacingOccurrences(of: "www.", with: ""),
              !host.isEmpty else {
            return "Custom Stream Add-on"
        }
        if host.localizedCaseInsensitiveContains("aiostreams") {
            return "AIOStreams"
        }
        return host
    }

    func getStreams(id: String, type: String) async throws -> [NuvioStream] {
        // Shared discovery: request-key cache, per-add-on groups, timeouts.
        // Does not use the Big Buck Bunny sample fallback.
        await StreamsRepository.shared.collectStreams(type: type, videoId: id)
    }

    func streamsProgressively(id: String, type: String) -> AsyncStream<[NuvioStream]> {
        // Bridge shared discovery into a progressive flat list for callers that
        // still observe AsyncStream. Observation cancel must NOT cancel the
        // shared job (returning from playback reuses it).
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @MainActor in
                let se = StreamsRepository.seasonEpisode(fromVideoId: id)
                let key = StreamsRepository.requestKey(
                    type: type,
                    videoId: id,
                    season: se.season,
                    episode: se.episode
                )
                StreamsRepository.shared.load(
                    type: type,
                    videoId: id,
                    season: se.season,
                    episode: se.episode,
                    forceRefresh: false
                )

                var lastCount = -1
                var lastLoading = true
                while !Task.isCancelled {
                    let snapshot = StreamsRepository.shared.state
                    guard snapshot.requestKey == key || snapshot.requestKey == nil else {
                        // A different title/episode took over; stop bridging.
                        break
                    }
                    if snapshot.hasResolvedTargets {
                        let streams = snapshot.allStreams
                        if streams.count != lastCount || snapshot.isAnyLoading != lastLoading {
                            lastCount = streams.count
                            lastLoading = snapshot.isAnyLoading
                            continuation.yield(streams)
                        }
                        if !snapshot.isAnyLoading {
                            break
                        }
                    }
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
                continuation.finish()
            }
            // Intentionally do not cancel StreamsRepository — only end observation.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func subtitlesProgressively(id: String, type: String) -> AsyncStream<[NuvioSubtitle]> {
        let subtitleType = Self.isSeriesType(type) ? "series" : "movie"

        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                let addons = await self.configuredSubtitleAddons(id: id, type: type)
                var accumulated: [NuvioSubtitle] = []

                await withTaskGroup(of: [NuvioSubtitle].self) { group in
                    for addon in addons {
                        guard let url = addon.subtitleURL(type: subtitleType, id: id) else { continue }
                        let name = addon.name
                        group.addTask { await Self.fetchSubtitles(from: url, source: name) }
                    }

                    for await subtitles in group {
                        guard !Task.isCancelled else { break }
                        accumulated = Self.mergedSubtitles(accumulated, subtitles)
                        continuation.yield(accumulated)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func fetchSubtitles(from url: URL, source: String) async -> [NuvioSubtitle] {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return [] }
            let decoded = try JSONDecoder().decode(StremioSubtitleResponse.self, from: data)
            return decoded.subtitles.compactMap { $0.toNuvioSubtitle(source: source) }
        } catch {
            print("Failed to load subtitles from \(source): \(error.localizedDescription)")
            return []
        }
    }

    /// Built-in subtitles plus every enabled installed add-on whose manifest
    /// advertises the Stremio `subtitles` resource.
    private func configuredSubtitleAddons(id: String, type: String) async -> [StremioSubtitleAddon] {
        let subtitleType = Self.isSeriesType(type) ? "series" : "movie"
        var addons = builtInSubtitleAddons
        var seenURLs = Set(addons.map(\.manifestURL))

        for manifestURL in Self.configuredStreamAddonManifestURLs {
            guard seenURLs.insert(manifestURL).inserted,
                  let manifest = await manifest(for: manifestURL),
                  manifest.supportsResource("subtitles", type: subtitleType, id: id) else { continue }
            addons.append(
                StremioSubtitleAddon(
                    name: manifest.displayName ?? Self.streamAddonName(for: manifestURL),
                    manifestURL: manifestURL
                )
            )
        }
        return addons
    }

    private func fetchSubtitleAddons(
        id: String,
        type: String,
        addons: [StremioSubtitleAddon]
    ) async -> [NuvioSubtitle] {
        let subtitleType = Self.isSeriesType(type) ? "series" : "movie"
        var subtitles: [NuvioSubtitle] = []

        for addon in addons {
            guard let subtitleURL = addon.subtitleURL(type: subtitleType, id: id) else { continue }
            do {
                let response: StremioSubtitleResponse = try await fetch(subtitleURL)
                subtitles += response.subtitles.compactMap { $0.toNuvioSubtitle(source: addon.name) }
            } catch {
                print("Failed to load subtitles from \(addon.name): \(error.localizedDescription)")
            }
        }

        return Self.uniqueSubtitles(subtitles)
    }

    private static func mergedSubtitles(_ lhs: [NuvioSubtitle], _ rhs: [NuvioSubtitle]) -> [NuvioSubtitle] {
        uniqueSubtitles(lhs + rhs)
    }

    private static func uniqueSubtitles(_ subtitles: [NuvioSubtitle]) -> [NuvioSubtitle] {
        var seen: Set<String> = []
        return subtitles.filter { subtitle in
            seen.insert(subtitle.url).inserted
        }
    }

    func search(query: String) async throws -> [NuvioMeta] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        async let movies = fetchCatalog(type: "movie", catalogId: "top", skip: nil, search: query, genre: nil)
        async let series = fetchCatalog(type: "series", catalogId: "top", skip: nil, search: query, genre: nil)
        let results = try await movies + series
        let localized = await TmdbDetailsService.localizedMetadata(for: results)
        cacheMetadata(localized)
        return localized
    }

    func browseCatalog(
        contentType: String,
        catalogId: String,
        page: Int,
        genre: String?,
        year: Int?,
        sort: String?
    ) async throws -> CatalogPage {
        let resolvedCatalogId = sort ?? catalogId
        let skip = max(page - 1, 0) * 100
        let items = await TmdbDetailsService.localizedMetadata(for: try await fetchCatalog(
            type: contentType,
            catalogId: resolvedCatalogId,
            skip: skip == 0 ? nil : skip,
            search: nil,
            genre: genre
        ))
        cacheMetadata(items)
        return CatalogPage(
            items: items,
            hasMore: !items.isEmpty,
            page: page,
            nextSkip: skip + items.count
        )
    }

    func browseCatalog(
        addonId: String?,
        contentType: String,
        catalogId: String,
        skip: Int,
        genre: String?
    ) async throws -> CatalogPage {
        let sourceBaseURL: URL
        if let addonId, !addonId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let resolved = await baseURL(
                forAddonId: addonId,
                contentType: contentType,
                catalogId: catalogId
            ) else {
                throw CollectionSourceError.invalidResponse(
                    "The add-on “\(addonId)” for “\(catalogId)” is not installed or available."
                )
            }
            sourceBaseURL = resolved
        } else if let resolved = await baseURL(
            forAddonId: nil,
            contentType: contentType,
            catalogId: catalogId
        ) {
            sourceBaseURL = resolved
        } else {
            sourceBaseURL = baseURL
        }

        let items = await TmdbDetailsService.localizedMetadata(for: try await fetchCatalog(
            sourceBaseURL: sourceBaseURL,
            type: contentType,
            catalogId: catalogId,
            skip: skip == 0 ? nil : skip,
            search: nil,
            genre: genre
        ))
        cacheMetadata(items)
        return CatalogPage(
            items: items,
            hasMore: !items.isEmpty,
            page: 1,
            nextSkip: skip + items.count
        )
    }

    func browseCatalog(
        contentType: String,
        catalogId: String,
        skip: Int,
        genre: String?
    ) async throws -> CatalogPage {
        let items = await TmdbDetailsService.localizedMetadata(for: try await fetchCatalog(
            type: contentType,
            catalogId: catalogId,
            skip: skip == 0 ? nil : skip,
            search: nil,
            genre: genre
        ))
        cacheMetadata(items)
        return CatalogPage(
            items: items,
            hasMore: !items.isEmpty,
            page: 1,
            nextSkip: skip + items.count
        )
    }

    func getGenres(contentType: String) async throws -> [String] {
        genres
    }

    /// Every selectable add-on catalog (Cinemeta's plus the configured
    /// add-ons'), for the Collections editor's source picker.
    func availableAddonCatalogs() async -> [AddonCatalogOption] {
        var options: [AddonCatalogOption] = []
        var manifestURLs: [URL] = []
        if Self.isCinemetaEnabled {
            manifestURLs.append(baseURL.appendingPathComponent("manifest.json"))
        }
        manifestURLs.append(contentsOf: Self.configuredStreamAddonManifestURLs)
        var seenAddonIds = Set<String>()

        for manifestURL in manifestURLs {
            guard let manifest = await manifest(for: manifestURL) else { continue }
            guard seenAddonIds.insert(manifest.id).inserted else { continue }
            let addonName = (manifest.name ?? "").isEmpty ? (manifestURL.host ?? manifest.id) : manifest.name!
            for catalog in manifest.catalogs ?? [] where catalog.eligibleForHome {
                options.append(
                    AddonCatalogOption(
                        addonId: manifest.id,
                        addonName: addonName,
                        type: catalog.type,
                        catalogId: catalog.id,
                        catalogName: catalog.name ?? catalog.id
                    )
                )
            }
        }
        return options
    }

    // MARK: - Synced collection folders

    /// Cinemeta's manifest id as it appears in the Android app's collection
    /// sources; resolves to the built-in `baseURL` without a manifest fetch.
    static let cinemetaAddonId = "com.linvo.cinemeta"
    /// Label for the built-in rows, which are served from `baseURL` rather than
    /// from a configured manifest that could supply a name.
    static let cinemetaDisplayName = "Cinemeta"

    /// A missing preference means Cinemeta is still the built-in default for
    /// existing installs. Once the account/local add-on list contains the
    /// Cinemeta manifest, its enabled flag is authoritative.
    static var isCinemetaEnabled: Bool {
        let manifestURL = "https://v3-cinemeta.strem.io/manifest.json"
        guard let preference = configuredStreamAddonPreferences.first(where: {
            normalizedManifestURL(from: $0.url)?.absoluteString == manifestURL
        }) else {
            return true
        }
        return preference.enabled
    }

    private func manifest(for url: URL) async -> AddonManifest? {
        guard let data = await StremioManifestDataCache.shared.data(for: url) else {
            return nil
        }
        return try? JSONDecoder().decode(AddonManifest.self, from: data)
    }

    func getCollectionFolderItems(sources: [NuvioCollectionCatalogSource], limit: Int) async -> [NuvioMeta] {
        var items: [NuvioMeta] = []
        var seen = Set<String>()

        for source in sources {
            guard items.count < limit else { break }
            guard let base = await baseURL(
                forAddonId: source.addonId,
                contentType: source.type,
                catalogId: source.catalogId
            ) else { continue }
            do {
                let url = try StremioCatalogURLBuilder.url(
                    baseURL: base,
                    type: source.type,
                    catalogId: source.catalogId,
                    genre: source.genre
                )
                let response: CinemetaCatalogResponse = try await fetch(url)
                for meta in response.metas.map({ $0.toMeta(fallbackType: source.type) }) {
                    guard items.count < limit else { break }
                    guard seen.insert(meta.id).inserted else { continue }
                    cacheCatalogMetadata(meta)
                    items.append(meta)
                }
            } catch {
                // One dead source must not empty the whole folder row.
                continue
            }
        }
        return items
    }

    private func baseURL(
        forAddonId addonId: String?,
        contentType: String? = nil,
        catalogId: String? = nil
    ) async -> URL? {
        let raw = addonId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // 1. Direct URL provided as addonId (e.g. "https://example.com/manifest.json" or "https://example.com")
        if raw.hasPrefix("http://") || raw.hasPrefix("https://"),
           let directURL = URL(string: raw) {
            return directURL.lastPathComponent.lowercased() == "manifest.json"
                ? directURL.deletingLastPathComponent()
                : directURL
        }

        // 2. Composite ID provided (e.g. "addon:manifestId:https://example.com/manifest.json")
        var extractedManifestId: String?
        if raw.hasPrefix("addon:") {
            let components = raw.components(separatedBy: ":")
            if components.count >= 3,
               let schemeIndex = components.firstIndex(where: { $0 == "http" || $0 == "https" }) {
                let urlString = components[schemeIndex...].joined(separator: ":")
                if let url = URL(string: urlString) {
                    return url.lastPathComponent.lowercased() == "manifest.json"
                        ? url.deletingLastPathComponent()
                        : url
                }
            }
            if components.count >= 2 {
                extractedManifestId = components[1]
            }
        }

        // 3. Cinemeta shortcuts
        if raw.isEmpty ||
           raw == Self.cinemetaAddonId ||
           raw.caseInsensitiveCompare("cinemeta") == .orderedSame ||
           raw.caseInsensitiveCompare("com.linvo.cinemeta") == .orderedSame {
            return baseURL
        }

        // 4. Candidate manifest URLs from settings & preferences
        var candidateManifestURLs: [URL] = []
        candidateManifestURLs.append(contentsOf: Self.configuredStreamAddonManifestURLs)
        let allPrefURLs = Self.configuredStreamAddonPreferences.compactMap {
            Self.normalizedManifestURL(from: $0.url)
        }
        for u in allPrefURLs where !candidateManifestURLs.contains(u) {
            candidateManifestURLs.append(u)
        }

        // 5. Match by manifest.id or manifest URL
        for manifestURL in candidateManifestURLs {
            if manifestURL.absoluteString == raw ||
               manifestURL.deletingLastPathComponent().absoluteString == raw {
                return manifestURL.deletingLastPathComponent()
            }
            if let manifest = await manifest(for: manifestURL) {
                if !raw.isEmpty,
                   (manifest.id == raw ||
                    manifest.id.caseInsensitiveCompare(raw) == .orderedSame ||
                    (extractedManifestId != nil && manifest.id.caseInsensitiveCompare(extractedManifestId!) == .orderedSame)) {
                    return manifestURL.deletingLastPathComponent()
                }
            }
        }

        // 6. Match by catalogId and contentType in manifest.catalogs (Fallback for custom/recs/synced catalogs)
        if let catalogId, !catalogId.isEmpty {
            let baseCatalogId = catalogId.components(separatedBy: ",").first ?? catalogId
            for manifestURL in candidateManifestURLs {
                if let manifest = await manifest(for: manifestURL),
                   let catalogs = manifest.catalogs {
                    let hasMatchingCatalog = catalogs.contains { cat in
                        let idMatches = cat.id == catalogId ||
                                        cat.id == baseCatalogId ||
                                        cat.id.caseInsensitiveCompare(catalogId) == .orderedSame ||
                                        cat.id.caseInsensitiveCompare(baseCatalogId) == .orderedSame
                        let typeMatches = (contentType == nil ||
                                           cat.type.caseInsensitiveCompare(contentType!) == .orderedSame)
                        return idMatches && typeMatches
                    }
                    if hasMatchingCatalog {
                        return manifestURL.deletingLastPathComponent()
                    }
                }
            }
        }

        // 7. Fallback to Cinemeta if raw is empty or cinemeta
        if raw.isEmpty ||
           raw == Self.cinemetaAddonId ||
           raw.caseInsensitiveCompare("cinemeta") == .orderedSame ||
           raw.caseInsensitiveCompare("com.linvo.cinemeta") == .orderedSame {
            return baseURL
        }

        return nil
    }

    private func fetchCatalog(
        sourceBaseURL: URL? = nil,
        type: String,
        catalogId: String,
        skip: Int?,
        search: String?,
        genre: String?
    ) async throws -> [NuvioMeta] {
        let url = try StremioCatalogURLBuilder.url(
            baseURL: sourceBaseURL ?? baseURL,
            type: type,
            catalogId: catalogId,
            skip: skip,
            search: search,
            genre: genre
        )
        let response: CinemetaCatalogResponse = try await fetch(url)
        return response.metas.map { $0.toMeta(fallbackType: type) }
    }

    private func fetch<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        // Each concurrent add-on request gets its own decoder.
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Not `private`: the test target reaches the Stremio catalog/metas decoder
/// through `@testable import` to verify field mapping (e.g. `logo` → logoUrl).
struct CinemetaCatalogResponse: Decodable {
    let metas: [CinemetaMeta]
}

/// The slice of a Stremio manifest the home screen needs: identity plus the
/// catalog list (user-configured add-ons like MDBList expose their custom
/// catalogs — Marvel, actors, lists — here).
private struct AddonManifest: Decodable {
    let id: String
    let name: String?
    let types: [String]?
    let idPrefixes: [String]?
    let resources: [AddonManifestResource]?
    let catalogs: [AddonManifestCatalog]?

    var displayName: String? {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    // Work around an Xcode 27 beta LICM optimizer crash in this small manifest loop.
    @_optimize(none)
    func supportsResource(_ name: String, type: String, id: String) -> Bool {
        guard let resources, !resources.isEmpty else { return false }
        let fallbackTypes = types ?? []
        let fallbackPrefixes = idPrefixes ?? []
        for resource in resources {
            if resource.name.caseInsensitiveCompare(name) == .orderedSame,
               resource.supportsType(type, fallbackTypes: fallbackTypes),
               resource.supportsId(id, fallbackPrefixes: fallbackPrefixes) {
                return true
            }
        }
        return false
    }
}

private struct AddonManifestResource: Decodable {
    let name: String
    let types: [String]
    let idPrefixes: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case types
        case idPrefixes
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let value = try? singleValue.decode(String.self) {
            name = value
            types = []
            idPrefixes = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        types = (try? container.decode([String].self, forKey: .types)) ?? []
        idPrefixes = try? container.decode([String].self, forKey: .idPrefixes)
    }

    func supportsType(_ type: String, fallbackTypes: [String]) -> Bool {
        let supportedTypes = types.isEmpty ? fallbackTypes : types
        guard !supportedTypes.isEmpty else { return true }
        if supportedTypes.contains(where: { AddonTransportUrls.isTypeEquivalent($0, type) }) {
            return true
        }
        if CinemetaCatalogRepository.isLiveContentType(type) {
            return supportedTypes.contains(where: { CinemetaCatalogRepository.isLiveContentType($0) })
        }
        return false
    }

    func supportsId(_ id: String, fallbackPrefixes: [String]) -> Bool {
        let prefixes = (idPrefixes?.isEmpty == false) ? (idPrefixes ?? []) : fallbackPrefixes
        guard !prefixes.isEmpty else { return true }
        return prefixes.contains { id.lowercased().hasPrefix($0.lowercased()) }
    }
}

private struct AddonManifestCatalog: Decodable {
    let type: String
    let id: String
    let name: String?
    let extra: [AddonManifestCatalogExtra]?
    /// Legacy manifest field predating the structured `extra` array.
    let extraRequired: [String]?

    /// Mirrors the Android app's `shouldShowOnHome()`: search-only catalogs
    /// belong to the Search tab, and a catalog whose required extras we can't
    /// supply (anything beyond `genre`) can't be fetched for Home either.
    var eligibleForHome: Bool {
        let required = requiredExtraNames
        if required.contains("search") { return false }
        return required.allSatisfy { $0 == "genre" }
    }

    var requiresGenre: Bool { requiredExtraNames.contains("genre") }

    /// First declared genre option, used to satisfy a required-genre catalog.
    var firstGenreOption: String? {
        extra?.first { $0.name.lowercased() == "genre" }?.options?.first
    }

    private var requiredExtraNames: [String] {
        let structured = (extra ?? []).filter { $0.isRequired == true }.map { $0.name.lowercased() }
        let legacy = (extraRequired ?? []).map { $0.lowercased() }
        return structured + legacy
    }
}

private struct AddonManifestCatalogExtra: Decodable {
    let name: String
    let isRequired: Bool?
    let options: [String]?
}

struct CinemetaMetaResponse: Decodable {
    let meta: CinemetaMeta
}

private struct StremioStreamAddon {
    let name: String
    let manifestURL: URL

    func streamURL(type: String, id: String) -> URL? {
        AddonTransportUrls.buildResourceURL(
            manifestURL: manifestURL,
            resource: "stream",
            type: type,
            id: id
        )
    }

    func metaURL(type: String, id: String) -> URL? {
        AddonTransportUrls.buildResourceURL(
            manifestURL: manifestURL,
            resource: "meta",
            type: type,
            id: id
        )
    }
}

private struct StremioSubtitleAddon {
    let name: String
    let manifestURL: URL

    func subtitleURL(type: String, id: String) -> URL? {
        AddonTransportUrls.buildResourceURL(
            manifestURL: manifestURL,
            resource: "subtitles",
            type: type,
            id: id
        )
    }
}

private struct StremioSubtitleResponse: Decodable {
    let subtitles: [StremioStreamSubtitle]
}

private struct StremioStreamSubtitle: Decodable {
    let url: String?
    let language: String?
    let lang: String?
    let title: String?
    let name: String?
    let id: String?

    func toNuvioSubtitle(source: String? = nil) -> NuvioSubtitle? {
        guard let subtitleURL = cleaned(url) else { return nil }
        let subtitleLanguage = cleaned(language) ?? cleaned(lang) ?? "Unknown"
        return NuvioSubtitle(
            url: subtitleURL,
            language: subtitleLanguage,
            label: cleaned(title) ?? cleaned(name) ?? cleaned(id),
            source: source
        )
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct CinemetaMeta: Decodable {
    let id: String
    let name: String
    let type: String?
    let description: String?
    let poster: String?
    let background: String?
    let logo: String?
    let imdbRating: FlexibleString?
    let genres: [String]?
    let genre: [String]?
    let releaseInfo: String?
    let year: String?
    let runtime: String?
    let cast: FlexibleStringArray?
    let director: FlexibleStringArray?
    let writer: FlexibleStringArray?
    let country: String?
    let released: String?
    let moviedbId: Int?
    let status: String?
    let videos: [CinemetaVideo]?
    let trailers: [CinemetaTrailer]?
    let trailerStreams: [CinemetaTrailerStream]?
    let imdbId: String?

    enum CodingKeys: String, CodingKey {
        case id, name, type, description, poster, background, logo, imdbRating
        case genres, genre, releaseInfo, year, runtime, cast, director, writer, country, released
        case status, videos, trailers, trailerStreams
        case moviedbId = "moviedb_id"
        case imdbId = "imdb_id"
    }

    func toMeta(fallbackType: String) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: name,
            description: description,
            posterUrl: poster,
            backgroundUrl: background,
            logoUrl: logo,
            imdbId: canonicalImdbId,
            tmdbId: moviedbId,
            type: type ?? fallbackType,
            year: parsedYear,
            genres: genres ?? genre,
            rating: parsedImdbRating,
            releaseInfo: releaseInfo ?? year,
            runtime: runtime,
            cast: cast?.values,
            director: director?.values,
            writer: writer?.values,
            certification: nil,
            country: country,
            released: released,
            status: status,
            videos: videos?.compactMap { $0.toVideo() },
            trailerYtIds: trailerYtIds
        )
    }

    private var canonicalImdbId: String? {
        NuvioMeta.canonicalImdbID(from: imdbId ?? "")
            ?? NuvioMeta.canonicalImdbID(from: id)
    }

    private var parsedImdbRating: Double? {
        guard let value = imdbRating.flatMap({ Double($0.value) }), value.isFinite, value > 0 else { return nil }
        return value
    }

    private var trailerYtIds: [String] {
        var seen: Set<String> = []
        return ((trailers?.compactMap { $0.youtubeId } ?? []) +
                (trailerStreams?.compactMap { $0.ytId?.trimmedNonEmpty } ?? []))
            .filter { YouTubeTrailerResolver.isYouTubeVideoId($0) && seen.insert($0).inserted }
    }

    private var parsedYear: Int? {
        let source = releaseInfo ?? year ?? released
        guard let source else { return nil }
        let digits = source.prefix(4)
        return Int(digits)
    }
}

/// Stremio add-ons disagree on the shape of the people fields. The spec — and
/// Cinemeta itself — sends `cast`/`director`/`writer` as string arrays, while
/// AIO Metadata sends a single comma-separated string. Because
/// `CinemetaCatalogResponse` decodes a whole page of metas at once, and a
/// Swift optional tolerates a missing value but not a mismatched type, one
/// non-conforming entry used to throw and drop the entire catalog row from
/// Home. Accepting both shapes keeps one optional field from invalidating the
/// complete response.
///
/// Not `private`: the test target reaches it through `@testable import`.
struct FlexibleStringArray: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let array = try? container.decode([String].self) {
            // Spec-compliant data passes through untouched. Anything that
            // decoded before this type existed must still decode identically,
            // down to padding: CastCrewSection keys its rows by the name
            // itself, so silently normalising entries here could collide two
            // rows that are distinct today.
            values = array
            return
        }

        if let joined = try? container.decode(String.self) {
            // A scalar here is a joined list, so split it back apart rather
            // than surfacing "A, B, C" as one cast member.
            values = joined.split(separator: ",").compactMap {
                String($0).trimmedNonEmpty
            }
            return
        }

        // Any other shape (numbers, objects) is dropped rather than thrown: a
        // malformed optional field must never cost us the catalog row.
        values = []
    }
}

// Internal so `CinemetaMeta` can stay Decodable for the test target.
struct CinemetaTrailer: Decodable {
    let source: String?
    let ytId: String?

    var youtubeId: String? {
        (source ?? ytId)?.trimmedNonEmpty
    }
}

struct CinemetaTrailerStream: Decodable {
    let ytId: String?
}

struct CinemetaVideo: Decodable {
    let id: String?
    let name: String?
    let title: String?
    let season: Int?
    let episode: Int?
    let number: Int?
    let thumbnail: String?
    let overview: String?
    let description: String?
    let released: String?
    let firstAired: String?
    // Cinemeta's /meta endpoint sends rating as a String ("7.7"), but its
    // catalog endpoint sends it as a number — decode either form.
    let rating: FlexibleString?

    func toVideo() -> NuvioVideo? {
        // Skip entries without a usable season/episode (e.g. malformed extras).
        guard let season, let episodeNumber = episode ?? number else { return nil }
        return NuvioVideo(
            id: id ?? "\(season):\(episodeNumber)",
            title: name ?? title ?? "Episode \(episodeNumber)",
            season: season,
            episode: episodeNumber,
            thumbnail: thumbnail,
            overview: overview ?? description,
            released: released ?? firstAired,
            rating: normalizedRating
        )
    }

    /// Drop empty / zero ratings (catalog entries report "0") so the UI can fall
    /// back to the series-level rating instead of showing a meaningless 0.
    private var normalizedRating: String? {
        guard let raw = rating?.value.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let numeric = Double(raw), numeric <= 0 { return nil }
        return raw
    }
}

/// Decodes a JSON value that may arrive as either a string or a number.
/// Internal so `CinemetaVideo` can expose it to the test target.
struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let double = try? container.decode(Double.self) {
            value = double == double.rounded() ? String(Int(double)) : String(double)
        } else {
            value = ""
        }
    }
}

/// In-memory mock catalog for unit tests and SwiftUI previews
class MockCatalogRepository: CatalogRepository {
    func getCollectionFolderItems(sources: [NuvioCollectionCatalogSource], limit: Int) async -> [NuvioMeta] {
        []
    }


    // Mock data
    private let mockGenres = [
        "action", "adventure", "animation", "biography", "comedy",
        "crime", "documentary", "drama", "family", "fantasy",
        "film-noir", "history", "horror", "music", "musical",
        "mystery", "romance", "sci-fi", "sport", "thriller",
        "war", "western"
    ]

    private func generateMockMeta(id: String, type: String) -> NuvioMeta {
        let genres = mockGenres.shuffled().prefix(Int.random(in: 2...4))
        return NuvioMeta(
            id: id,
            name: "Sample \(type.capitalized) \(id)",
            description: "This is a sample \(type) with ID \(id). Lorem ipsum dolor sit amet, consectetur adipiscing elit.",
            posterUrl: "https://via.placeholder.com/300x450/1a1a1a/ffffff?text=\(type)+\(id)",
            backgroundUrl: "https://via.placeholder.com/1920x1080/1a1a1a/ffffff?text=BG",
            logoUrl: nil,
            imdbId: "tt\(String(format: "%07d", Int.random(in: 1...9999999)))",
            tmdbId: Int.random(in: 1...999999),
            type: type,
            year: Int.random(in: 2010...2024),
            genres: Array(genres),
            rating: Double.random(in: 6.0...9.5),
            releaseInfo: nil,
            runtime: "\(Int.random(in: 90...180)) min",
            cast: ["Actor 1", "Actor 2", "Actor 3"],
            director: ["Director Name"],
            writer: ["Writer Name"],
            certification: "PG-13",
            country: "USA",
            released: nil
        )
    }

    func getHomeCatalogs() async throws -> [NuvioCatalog] {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

        return [
            NuvioCatalog(
                id: "trending_movies",
                name: "Trending Movies",
                description: "Popular movies right now",
                itemIds: (1...20).map { "movie_\($0)" },
                contentType: "movie",
                catalogId: "top"
            ),
            NuvioCatalog(
                id: "trending_series",
                name: "Trending Series",
                description: "Popular series right now",
                itemIds: (1...20).map { "series_\($0)" },
                contentType: "series",
                catalogId: "top"
            )
        ]
    }

    func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 300_000_000) // 0.3 seconds

        let resolvedType = type.isEmpty ? (id.hasPrefix("movie") ? "movie" : "series") : type
        return generateMockMeta(id: id, type: resolvedType)
    }

    // Declared in the class body (rather than relying on the protocol-extension
    // default) so test stubs can override it to answer specific /meta records.
    func refreshMetadata(id: String, type: String) async throws -> NuvioMeta {
        try await getMetadata(id: id, type: type)
    }

    func getStreams(id: String, type: String) async throws -> [NuvioStream] {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

        return [
            NuvioStream(
                url: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
                name: "HD Stream",
                description: "1080p",
                addonName: "Sample Addon"
            ),
            NuvioStream(
                url: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
                name: "4K Stream",
                description: "2160p",
                addonName: "Sample Addon"
            )
        ]
    }

    func search(query: String) async throws -> [NuvioMeta] {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 400_000_000) // 0.4 seconds

        guard !query.isEmpty else { return [] }

        // Return mock search results
        let movieResults = (1...5).map { generateMockMeta(id: "search_movie_\($0)", type: "movie") }
        let seriesResults = (1...5).map { generateMockMeta(id: "search_series_\($0)", type: "series") }

        return movieResults + seriesResults
    }

    func browseCatalog(
        contentType: String,
        catalogId: String,
        page: Int,
        genre: String?,
        year: Int?,
        sort: String?
    ) async throws -> CatalogPage {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 600_000_000) // 0.6 seconds

        // Generate 20 items per page (standard pagination size)
        let startIndex = (page - 1) * 20 + 1
        let endIndex = page * 20

        let items = (startIndex...endIndex).map { index in
            var meta = generateMockMeta(id: "\(contentType)_\(index)", type: contentType)

            // Filter by genre if specified
            if let genre = genre {
                meta = NuvioMeta(
                    id: meta.id,
                    name: meta.name,
                    description: meta.description,
                    posterUrl: meta.posterUrl,
                    backgroundUrl: meta.backgroundUrl,
                    logoUrl: meta.logoUrl,
                    imdbId: meta.imdbId,
                    tmdbId: meta.tmdbId,
                    type: meta.type,
                    year: meta.year,
                    genres: [genre] + (meta.genres?.filter { $0 != genre } ?? []),
                    rating: meta.rating,
                    releaseInfo: meta.releaseInfo,
                    runtime: meta.runtime,
                    cast: meta.cast,
                    director: meta.director,
                    writer: meta.writer,
                    certification: meta.certification,
                    country: meta.country,
                    released: meta.released
                )
            }

            // Filter by year if specified
            if let year = year {
                meta = NuvioMeta(
                    id: meta.id,
                    name: meta.name,
                    description: meta.description,
                    posterUrl: meta.posterUrl,
                    backgroundUrl: meta.backgroundUrl,
                    logoUrl: meta.logoUrl,
                    imdbId: meta.imdbId,
                    tmdbId: meta.tmdbId,
                    type: meta.type,
                    year: year,
                    genres: meta.genres,
                    rating: meta.rating,
                    releaseInfo: meta.releaseInfo,
                    runtime: meta.runtime,
                    cast: meta.cast,
                    director: meta.director,
                    writer: meta.writer,
                    certification: meta.certification,
                    country: meta.country,
                    released: meta.released
                )
            }

            return meta
        }

        // Simulate having more pages (limit to 5 pages for demo)
        let hasMore = page < 5

        return CatalogPage(
            items: items,
            hasMore: hasMore,
            page: page,
            nextSkip: page * 20
        )
    }

    func browseCatalog(
        contentType: String,
        catalogId: String,
        skip: Int,
        genre: String?
    ) async throws -> CatalogPage {
        try await Task.sleep(nanoseconds: 600_000_000)

        let startIndex = skip + 1
        let endIndex = skip + 20
        let items = (startIndex...endIndex).map { index in
            generateMockMeta(id: "\(contentType)_\(index)", type: contentType)
        }

        return CatalogPage(
            items: items,
            hasMore: skip + items.count < 100,
            page: (skip / 20) + 1,
            nextSkip: skip + items.count
        )
    }

    func getGenres(contentType: String) async throws -> [String] {
        // Simulate network delay
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds

        return mockGenres
    }
}
