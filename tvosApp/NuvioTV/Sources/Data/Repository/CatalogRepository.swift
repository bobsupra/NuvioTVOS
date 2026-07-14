//
//  CatalogRepository.swift
//  NuvioTV
//
//  Created by Claude Code
//  Repository protocol for catalog operations
//

import Foundation

/// Repository protocol for catalog operations
protocol CatalogRepository {
    /// Get catalogs for home screen
    func getHomeCatalogs() async throws -> [NuvioCatalog]

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

/// Live Cinemeta-backed implementation used by the tvOS home prototype.
final class CinemetaCatalogRepository: CatalogRepository {
    static private(set) var homeAddonFetchDiagnostic = "not started"
    private let baseURL = URL(string: "https://v3-cinemeta.strem.io")!
    private var cachedMetaById: [String: NuvioMeta] = [:]
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

    func getHomeCatalogs() async throws -> [NuvioCatalog] {
        let specs: [(id: String, name: String, type: String, catalogId: String)] = [
            ("movie_top", "Popular - Movies", "movie", "top"),
            ("series_top", "Popular - Series", "series", "top"),
            ("movie_rating", "Top Rated - Movies", "movie", "imdbRating"),
            ("series_rating", "Top Rated - Series", "series", "imdbRating")
        ]

        var catalogs: [NuvioCatalog] = []
        for spec in specs {
            let page = try await fetchCatalog(type: spec.type, catalogId: spec.catalogId, skip: nil, search: nil, genre: nil)
            page.forEach { cachedMetaById[$0.id] = $0 }
            catalogs.append(
                NuvioCatalog(
                    id: spec.id,
                    name: spec.name,
                    description: spec.name,
                    itemIds: page.map(\.id),
                    contentType: spec.type,
                    catalogId: spec.catalogId
                )
            )
        }
        catalogs.append(contentsOf: await addonHomeCatalogs())
        return catalogs
    }

    /// Home rows from the configured add-ons' manifest catalogs, mirroring the
    /// Android app: user-configured add-ons (MDBList, AIOStreams, …) expose
    /// custom catalogs — Marvel, actors, lists — that belong on Home. Search-
    /// only catalogs and ones needing unsupported extras are skipped; a
    /// required genre is satisfied with the catalog's first declared option.
    private func addonHomeCatalogs() async -> [NuvioCatalog] {
        // Catalogs the user hid from Home on another device (synced from the
        // account). Their key format matches the tvOS catalog id sans `addon_`.
        let disabledCatalogKeys = TVHomeCatalogOrder.disabledCatalogKeys()
        let maxRows = 24
        var catalogs: [NuvioCatalog] = []
        var reports: [String] = []
        Self.homeAddonFetchDiagnostic = "loading"

        for manifestURL in Self.configuredStreamAddonManifestURLs {
            guard catalogs.count < maxRows else { break }
            guard let manifest = await manifest(for: manifestURL) else {
                reports.append("\(manifestURL.host ?? "unknown"): manifest failed")
                continue
            }
            guard manifest.id != Self.cinemetaAddonId else { continue }

            let base = manifestURL.deletingLastPathComponent()
            let remaining = maxRows - catalogs.count
            let eligible = (manifest.catalogs ?? []).filter { catalog in
                guard catalog.eligibleForHome else { return false }
                guard !disabledCatalogKeys.contains("\(manifest.id)_\(catalog.type)_\(catalog.id)") else {
                    return false
                }
                return !catalog.requiresGenre || catalog.firstGenreOption != nil
            }

            // BetterPosters rejects/limits a burst of all 13 catalog requests
            // on some Apple TV networks. Its proven path is ordered serial
            // fetching (the same behavior triggered by disabling/re-enabling
            // the add-on). Continue Watching remains visible during this work.
            var loadedForManifest = 0
            var failedForManifest = 0
            for catalog in eligible.prefix(remaining) {
                do {
                    var path = "catalog/\(catalog.type)/\(catalog.id)"
                    let catalogGenre = catalog.requiresGenre ? catalog.firstGenreOption : nil
                    if let genre = catalogGenre,
                       let genreExtra = encodedExtra(name: "genre", value: genre) {
                        path += "/" + genreExtra
                    }
                    path += ".json"
                    let response: CinemetaCatalogResponse = try await fetch(
                        base.appendingPathComponent(path)
                    )
                    let items = response.metas.map { $0.toMeta(fallbackType: catalog.type) }
                    guard !items.isEmpty else {
                        failedForManifest += 1
                        continue
                    }
                    let catalogName = catalog.name ?? catalog.id
                    catalogs.append(
                        NuvioCatalog(
                            id: "addon_\(manifest.id)_\(catalog.type)_\(catalog.id)",
                            name: catalogName,
                            description: catalogName,
                            itemIds: items.map(\.id),
                            items: items,
                            contentType: catalog.type,
                            catalogId: catalog.id,
                            addonId: manifest.id,
                            catalogGenre: catalogGenre
                        )
                    )
                    loadedForManifest += 1
                } catch {
                    failedForManifest += 1
                }
            }
            reports.append("\(manifest.id): \(loadedForManifest)/\(eligible.prefix(remaining).count), failed \(failedForManifest)")
        }

        Self.homeAddonFetchDiagnostic = reports.isEmpty ? "no add-on catalogs" : reports.joined(separator: "; ")

        // Order the add-on rows to match the account's Home layout. Rows the
        // account hasn't placed keep their natural (manifest) order, after the
        // placed ones — mirroring the phone/Google-TV apps.
        let orderIndex = TVHomeCatalogOrder.syncedCatalogOrderIndex()
        if !orderIndex.isEmpty {
            catalogs = catalogs
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
        return catalogs
    }

    /// Maps an add-on catalog's tvOS id (`addon_<addonId>_<type>_<catalogId>`)
    /// back to the account key format (`<addonId>_<type>_<catalogId>`) used by
    /// the synced Home layout.
    private static func accountCatalogKey(fromCatalogId id: String) -> String {
        id.hasPrefix("addon_") ? String(id.dropFirst("addon_".count)) : id
    }

    func getMetadata(id: String, type: String) async throws -> NuvioMeta {
        if let cached = cachedMetaById[id] {
            return cached
        }

        return try await loadMetadata(id: id, type: type)
    }

    func refreshMetadata(id: String, type: String) async throws -> NuvioMeta {
        cachedMetaById.removeValue(forKey: id)
        return try await loadMetadata(id: id, type: type)
    }

    private func loadMetadata(id: String, type: String) async throws -> NuvioMeta {

        // Query the correct endpoint based on the caller-provided type. The
        // Details screen uses a fresh repository (empty cache) so this always
        // fetches the full /meta payload — real episodes and per-episode ratings.
        let metaType = Self.isSeriesType(type) ? "series" : "movie"
        var lastError: Error?

        // Cinemeta only resolves IMDb ids; other id spaces synced from the
        // phone app (tmdb:, kitsu:, ...) must come from the configured add-ons.
        if id.hasPrefix("tt") {
            do {
                let url = baseURL.appendingPathComponent("meta/\(metaType)/\(id).json")
                let response: CinemetaMetaResponse = try await fetch(url)
                let meta = response.meta.toMeta(fallbackType: metaType)
                cachedMetaById[meta.id] = meta
                return meta
            } catch {
                lastError = error
            }
        }

        for addon in await configuredAddons(supporting: "meta", type: metaType, id: id) {
            do {
                let response: CinemetaMetaResponse = try await fetch(addon.metaURL(type: metaType, id: id))
                let meta = response.meta.toMeta(fallbackType: metaType)
                // Cache under the requested id too in case the addon
                // canonicalizes to a different id space.
                cachedMetaById[id] = meta
                cachedMetaById[meta.id] = meta
                return meta
            } catch {
                if lastError == nil { lastError = error }
            }
        }

        throw lastError ?? URLError(.badServerResponse)
    }

    private static func isSeriesType(_ type: String) -> Bool {
        ["series", "show", "tv", "tvshow"].contains(type.lowercased())
    }

    /// Every enabled manifest URL — the manually entered one plus the list synced
    /// from the account — deduplicated in priority order.
    static var configuredStreamAddonManifestURLs: [URL] {
        configuredStreamAddonPreferences.compactMap { preference in
            guard preference.enabled else { return nil }
            return normalizedManifestURL(from: preference.url)
        }
    }

    /// Full ordered add-on state for Settings. The legacy URL fields are still
    /// merged in so manually pasted add-ons appear even before a state blob exists.
    static var configuredStreamAddonPreferences: [StreamAddonPreference] {
        let defaults = ProfileSettings.current
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
        var addons: [StremioStreamAddon] = []
        for manifestURL in Self.configuredStreamAddonManifestURLs {
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
        let addons = await configuredAddons(supporting: "stream", type: type, id: id)
        // Fan the add-on requests out concurrently: total latency is the
        // slowest add-on, not the sum of them all. A slow or dead add-on no
        // longer starves the ones that respond quickly.
        var addonStreams: [NuvioStream] = []
        await withTaskGroup(of: [NuvioStream].self) { group in
            for addon in addons {
                let url = addon.streamURL(type: type, id: id)
                let name = addon.name
                let manifestURL = addon.manifestURL
                group.addTask { await Self.fetchStreams(from: url, addonName: name, manifestURL: manifestURL) }
            }
            for await streams in group {
                addonStreams += streams
            }
        }

        guard !addonStreams.isEmpty else { return [Self.sampleStream] }
        let subtitleAddons = await configuredSubtitleAddons(id: id, type: type)
        let addonSubtitles = await fetchSubtitleAddons(id: id, type: type, addons: subtitleAddons)
        return Self.decorate(addonStreams, with: addonSubtitles)
    }

    func streamsProgressively(id: String, type: String) -> AsyncStream<[NuvioStream]> {
        let subtitleType = Self.isSeriesType(type) ? "series" : "movie"

        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                let addons = await self.configuredAddons(supporting: "stream", type: type, id: id)
                let subtitleAddons = await self.configuredSubtitleAddons(id: id, type: type)
                var accumulated: [NuvioStream] = []
                var subtitles: [NuvioSubtitle] = []

                await withTaskGroup(of: StreamFetchResult.self) { group in
                    for addon in addons {
                        let url = addon.streamURL(type: type, id: id)
                        let name = addon.name
                        let manifestURL = addon.manifestURL
                        group.addTask { .streams(await Self.fetchStreams(from: url, addonName: name, manifestURL: manifestURL)) }
                    }
                    for addon in subtitleAddons {
                        let url = addon.subtitleURL(type: subtitleType, id: id)
                        let name = addon.name
                        group.addTask { .subtitles(await Self.fetchSubtitles(from: url, source: name)) }
                    }

                    for await result in group {
                        if Task.isCancelled { break }
                        switch result {
                        case .streams(let new):
                            guard !new.isEmpty else { continue }
                            accumulated += new
                            continuation.yield(Self.decorate(accumulated, with: subtitles))
                        case .subtitles(let subs):
                            guard !subs.isEmpty else { continue }
                            subtitles = Self.mergedSubtitles(subtitles, subs)
                            // Re-emit so already-shown streams pick up subtitles.
                            if !accumulated.isEmpty {
                                continuation.yield(Self.decorate(accumulated, with: subtitles))
                            }
                        }
                    }
                }

                // No add-on produced anything: fall back to the sample stream so
                // the picker never dead-ends on "No playable streams found".
                if !Task.isCancelled && accumulated.isEmpty {
                    continuation.yield([Self.sampleStream])
                }
                continuation.finish()
            }
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
                        let url = addon.subtitleURL(type: subtitleType, id: id)
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

    /// Fetch and decode one stream add-on's response, mapping to NuvioStreams.
    /// A failure (timeout, bad payload, dead endpoint) yields an empty list so
    /// it can't block the other add-ons.
    private static func fetchStreams(from url: URL, addonName: String) async -> [NuvioStream] {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return [] }
            let decoded = try JSONDecoder().decode(StremioStreamResponse.self, from: data)
            return decoded.streams.compactMap { $0.toNuvioStream(addonName: addonName) }
        } catch {
            print("Failed to load streams from \(addonName): \(error.localizedDescription)")
            return []
        }
    }

    /// Fetches an add-on's streams and its manifest `logo` concurrently, then
    /// tags the streams with the logo. Running them in parallel (and bounding the
    /// logo fetch with a short timeout) means the cosmetic logo never delays the
    /// streams themselves — important since stream loading is the critical path.
    private static func fetchStreams(from url: URL, addonName: String, manifestURL: URL) async -> [NuvioStream] {
        async let logo = addonLogo(for: manifestURL)
        let streams = await fetchStreams(from: url, addonName: addonName)
        guard let resolvedLogo = await logo else { return streams }
        return streams.map { $0.withAddonLogoURL(resolvedLogo) }
    }

    /// One-time-per-manifest fetch of an add-on's `logo`, cached for the app's
    /// lifetime so the stream picker can show each source's real branding. A
    /// missing/failed logo caches `nil` so we don't refetch on every open. A tight
    /// timeout keeps a slow manifest from ever holding up stream loading.
    private static let addonLogoCacheLock = NSLock()
    private static var addonLogoCache: [URL: String?] = [:]

    private static func addonLogo(for manifestURL: URL) async -> String? {
        addonLogoCacheLock.lock()
        if let cached = addonLogoCache[manifestURL] {
            addonLogoCacheLock.unlock()
            return cached
        }
        addonLogoCacheLock.unlock()

        var request = URLRequest(url: manifestURL)
        request.timeoutInterval = 5

        var logo: String?
        if let (data, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
           let manifest = try? JSONDecoder().decode(StremioManifestLogo.self, from: data) {
            logo = manifest.logo?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }

        addonLogoCacheLock.lock()
        addonLogoCache[manifestURL] = logo
        addonLogoCacheLock.unlock()
        return logo
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

    /// Cap the list at 80 and merge in any subtitle-add-on results.
    private static func decorate(_ streams: [NuvioStream], with subtitles: [NuvioSubtitle]) -> [NuvioStream] {
        let capped = Array(streams.prefix(80))
        guard !subtitles.isEmpty else { return capped }
        return capped.map { stream in
            NuvioStream(
                url: stream.url,
                name: stream.name,
                description: stream.description,
                addonName: stream.addonName,
                subtitles: mergedSubtitles(stream.subtitles, subtitles)
            )
        }
    }

    private static let sampleStream = NuvioStream(
        url: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
        name: "Sample Stream",
        description: "Direct 1080p fallback stream",
        addonName: "Nuvio Sample"
    )

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
            do {
                let response: StremioSubtitleResponse = try await fetch(addon.subtitleURL(type: subtitleType, id: id))
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
        results.forEach { cachedMetaById[$0.id] = $0 }
        return results
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
        let items = try await fetchCatalog(
            type: contentType,
            catalogId: resolvedCatalogId,
            skip: skip == 0 ? nil : skip,
            search: nil,
            genre: genre
        )
        items.forEach { cachedMetaById[$0.id] = $0 }
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
        if let addonId {
            guard let resolved = await baseURL(forAddonId: addonId) else {
                throw URLError(.badURL)
            }
            sourceBaseURL = resolved
        } else {
            sourceBaseURL = baseURL
        }

        let items = try await fetchCatalog(
            sourceBaseURL: sourceBaseURL,
            type: contentType,
            catalogId: catalogId,
            skip: skip == 0 ? nil : skip,
            search: nil,
            genre: genre
        )
        items.forEach { cachedMetaById[$0.id] = $0 }
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
        let items = try await fetchCatalog(
            type: contentType,
            catalogId: catalogId,
            skip: skip == 0 ? nil : skip,
            search: nil,
            genre: genre
        )
        items.forEach { cachedMetaById[$0.id] = $0 }
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
        var manifestURLs = [baseURL.appendingPathComponent("manifest.json")]
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
    private static let cinemetaAddonId = "com.linvo.cinemeta"

    /// Manifest cache for the configured stream add-ons, shared by the home
    /// catalog rows and the collection-folder resolver.
    private var manifestByURL: [URL: AddonManifest] = [:]

    private func manifest(for url: URL) async -> AddonManifest? {
        if let cached = manifestByURL[url] { return cached }
        guard let manifest: AddonManifest = try? await fetch(url) else { return nil }
        manifestByURL[url] = manifest
        return manifest
    }

    func getCollectionFolderItems(sources: [NuvioCollectionCatalogSource], limit: Int) async -> [NuvioMeta] {
        var items: [NuvioMeta] = []
        var seen = Set<String>()

        for source in sources {
            guard items.count < limit else { break }
            guard let base = await baseURL(forAddonId: source.addonId) else { continue }
            do {
                var path = "catalog/\(source.type)/\(source.catalogId)"
                if let genreExtra = source.genre.flatMap({ encodedExtra(name: "genre", value: $0) }) {
                    path += "/" + genreExtra
                }
                path += ".json"
                let response: CinemetaCatalogResponse = try await fetch(base.appendingPathComponent(path))
                for meta in response.metas.map({ $0.toMeta(fallbackType: source.type) }) {
                    guard items.count < limit else { break }
                    guard seen.insert(meta.id).inserted else { continue }
                    cachedMetaById[meta.id] = meta
                    items.append(meta)
                }
            } catch {
                // One dead source must not empty the whole folder row.
                continue
            }
        }
        return items
    }

    private func baseURL(forAddonId addonId: String) async -> URL? {
        if addonId == Self.cinemetaAddonId { return baseURL }

        for manifestURL in Self.configuredStreamAddonManifestURLs {
            if let manifest = await manifest(for: manifestURL),
               manifest.id == addonId {
                return manifestURL.deletingLastPathComponent()
            }
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
        var path = "catalog/\(type)/\(catalogId)"
        let extras = [
            search.flatMap { encodedExtra(name: "search", value: $0) },
            genre.flatMap { encodedExtra(name: "genre", value: $0) },
            skip.map { "skip=\($0)" }
        ].compactMap { $0 }

        if !extras.isEmpty {
            path += "/" + extras.joined(separator: "&")
        }
        path += ".json"

        let response: CinemetaCatalogResponse = try await fetch((sourceBaseURL ?? baseURL).appendingPathComponent(path))
        return response.metas.map { $0.toMeta(fallbackType: type) }
    }

    private func encodedExtra(name: String, value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return "\(name)=\(encoded)"
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

private struct CinemetaCatalogResponse: Decodable {
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
        return supportedTypes.contains { $0.caseInsensitiveCompare(type) == .orderedSame }
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

private struct CinemetaMetaResponse: Decodable {
    let meta: CinemetaMeta
}

/// One result arriving from the progressive stream fetch task group — either a
/// stream add-on's streams or the subtitle add-ons' subtitles.
private enum StreamFetchResult {
    case streams([NuvioStream])
    case subtitles([NuvioSubtitle])
}

private struct StremioStreamAddon {
    let name: String
    let manifestURL: URL

    func streamURL(type: String, id: String) -> URL {
        manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("stream")
            .appendingPathComponent(type)
            .appendingPathComponent("\(id).json")
    }

    func metaURL(type: String, id: String) -> URL {
        manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("meta")
            .appendingPathComponent(type)
            .appendingPathComponent("\(id).json")
    }
}

private struct StremioSubtitleAddon {
    let name: String
    let manifestURL: URL

    func subtitleURL(type: String, id: String) -> URL {
        manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("subtitles")
            .appendingPathComponent(type)
            .appendingPathComponent("\(id).json")
    }
}

private struct StremioStreamResponse: Decodable {
    let streams: [StremioStream]
}

private struct StremioSubtitleResponse: Decodable {
    let subtitles: [StremioStreamSubtitle]
}

private struct StremioStream: Decodable {
    let url: String?
    let externalUrl: String?
    let name: String?
    let title: String?
    let description: String?
    let subtitles: [StremioStreamSubtitle]?
    let behaviorHints: StremioStreamBehaviorHints?
    /// Torrent fields used by debrid resolution. Add-ons like Torrentio return
    /// these instead of a `url`; the debrid layer converts them to a link.
    let infoHash: String?
    let fileIdx: Int?
    let sources: [String]?

    func toNuvioStream(addonName: String) -> NuvioStream? {
        let streamURL = cleaned(url) ?? cleaned(externalUrl)
        let hash = cleaned(infoHash)?.lowercased()
        // Keep torrent-only streams (no URL but an info-hash) so debrid can
        // resolve them later; drop only streams that have neither.
        guard streamURL != nil || hash != nil else { return nil }

        let displayName = cleaned(name) ?? cleaned(title) ?? "Stream"
        var detailLines: [String] = []

        if let title = cleaned(title), title != displayName {
            detailLines.append(title)
        }
        if let description = cleaned(description) {
            detailLines.append(description)
        } else if let size = behaviorHints?.videoSize {
            detailLines.append("Size \(Self.sizeFormatter.string(fromByteCount: size))")
        }

        return NuvioStream(
            url: streamURL,
            name: displayName,
            description: detailLines.joined(separator: "\n"),
            addonName: addonName,
            subtitles: subtitles?.compactMap { $0.toNuvioSubtitle(source: addonName) } ?? [],
            infoHash: hash,
            fileIdx: fileIdx,
            sources: sources ?? [],
            filename: cleaned(behaviorHints?.filename)
        )
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()
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

private struct StremioStreamBehaviorHints: Decodable {
    let videoSize: Int64?
    let filename: String?
    let bingeGroup: String?
}

/// Minimal manifest decode for just the add-on `logo` shown on stream cards.
private struct StremioManifestLogo: Decodable {
    let logo: String?
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

private struct CinemetaMeta: Decodable {
    let id: String
    let name: String
    let type: String?
    let description: String?
    let poster: String?
    let background: String?
    let logo: String?
    let imdbRating: String?
    let genres: [String]?
    let genre: [String]?
    let releaseInfo: String?
    let year: String?
    let runtime: String?
    let cast: [String]?
    let director: [String]?
    let writer: [String]?
    let country: String?
    let released: String?
    let moviedbId: Int?
    let status: String?
    let videos: [CinemetaVideo]?
    let trailers: [CinemetaTrailer]?
    let trailerStreams: [CinemetaTrailerStream]?

    enum CodingKeys: String, CodingKey {
        case id, name, type, description, poster, background, logo, imdbRating
        case genres, genre, releaseInfo, year, runtime, cast, director, writer, country, released
        case status, videos, trailers, trailerStreams
        case moviedbId = "moviedb_id"
    }

    func toMeta(fallbackType: String) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: name,
            description: description,
            posterUrl: poster,
            backgroundUrl: background,
            logoUrl: logo,
            imdbId: id.hasPrefix("tt") ? id : nil,
            tmdbId: moviedbId,
            type: type ?? fallbackType,
            year: parsedYear,
            genres: genres ?? genre,
            rating: parsedImdbRating,
            releaseInfo: releaseInfo ?? year,
            runtime: runtime,
            cast: cast,
            director: director,
            writer: writer,
            certification: nil,
            country: country,
            released: released,
            status: status,
            videos: videos?.compactMap { $0.toVideo() },
            trailerYtIds: trailerYtIds
        )
    }

    private var parsedImdbRating: Double? {
        guard let value = imdbRating.flatMap(Double.init), value.isFinite else { return nil }
        return value
    }

    private var trailerYtIds: [String] {
        var seen: Set<String> = []
        return ((trailers?.compactMap { $0.youtubeId } ?? []) +
                (trailerStreams?.compactMap { $0.ytId?.trimmedNonEmpty } ?? []))
            .filter { seen.insert($0).inserted }
    }

    private var parsedYear: Int? {
        let source = releaseInfo ?? year ?? released
        guard let source else { return nil }
        let digits = source.prefix(4)
        return Int(digits)
    }
}

private struct CinemetaTrailer: Decodable {
    let source: String?
    let ytId: String?

    var youtubeId: String? {
        (source ?? ytId)?.trimmedNonEmpty
    }
}

private struct CinemetaTrailerStream: Decodable {
    let ytId: String?
}

private struct CinemetaVideo: Decodable {
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
private struct FlexibleString: Decodable {
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

/// Mock implementation for testing without Rust SDK
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
