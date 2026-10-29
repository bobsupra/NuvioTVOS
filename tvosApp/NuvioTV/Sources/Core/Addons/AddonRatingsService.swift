//
//  AddonRatingsService.swift
//  NuvioTV
//
//  External ratings resolution and provider discovery from Stremio add-ons,
//  supporting the 'ratings' resource and 'ratingSources' manifest declarations.
//

import Foundation

/// An external rating source defined in an add-on manifest's `ratingSources` array.
struct AddonRatingSource: Codable, Hashable, Identifiable, Sendable {
    let source: String
    let name: String?
    let icon: String?
    let max: Double?
    let episodes: Bool?

    var id: String { source }
    var displayName: String { name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? source.capitalized }

    init(source: String, name: String? = nil, icon: String? = nil, max: Double? = nil, episodes: Bool? = nil) {
        self.source = source
        self.name = name
        self.icon = icon
        self.max = max
        self.episodes = episodes
    }
}

/// Discovered rating source with add-on context and current user settings for the Settings UI.
struct AddonRatingSourceSummary: Identifiable, Equatable {
    let source: String
    let name: String
    let addonName: String
    let manifestIcon: String?
    let userIconOverride: String?
    let max: Double?
    var isEnabled: Bool
    let episodes: Bool?

    var id: String { source }

    var effectiveIconUrl: String? {
        if let userIconOverride = userIconOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !userIconOverride.isEmpty {
            return userIconOverride
        }
        return manifestIcon
    }

    init(
        source: String,
        name: String,
        addonName: String,
        manifestIcon: String? = nil,
        userIconOverride: String? = nil,
        max: Double? = nil,
        isEnabled: Bool = true,
        episodes: Bool? = nil
    ) {
        self.source = source
        self.name = name
        self.addonName = addonName
        self.manifestIcon = manifestIcon
        self.userIconOverride = userIconOverride
        self.max = max
        self.isEnabled = isEnabled
        self.episodes = episodes
    }
}

/// The portion of a Stremio manifest needed for ratings resolution.
struct AddonRatingsManifest: Decodable, Sendable {
    let id: String
    let name: String?
    let types: [String]?
    let idPrefixes: [String]?
    let resources: [AddonRatingsManifestResource]?
    let ratingSources: [AddonRatingSource]?

    var displayName: String? {
        name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    init(
        id: String,
        name: String? = nil,
        types: [String]? = nil,
        idPrefixes: [String]? = nil,
        resources: [AddonRatingsManifestResource]? = nil,
        ratingSources: [AddonRatingSource]? = nil
    ) {
        self.id = id
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
        self.resources = resources
        self.ratingSources = ratingSources
    }

    func supportsRatings(type: String, id: String) -> Bool {
        guard let resources, !resources.isEmpty else { return false }
        let fallbackTypes = types ?? []
        let fallbackPrefixes = idPrefixes ?? []
        for resource in resources {
            if resource.name.caseInsensitiveCompare("ratings") == .orderedSame,
               resource.supportsType(type, fallbackTypes: fallbackTypes),
               resource.supportsId(id, fallbackPrefixes: fallbackPrefixes) {
                return true
            }
        }
        return false
    }
}

struct AddonRatingsManifestResource: Decodable, Sendable {
    let name: String
    let types: [String]
    let idPrefixes: [String]?

    enum CodingKeys: String, CodingKey {
        case name, types, idPrefixes
    }

    init(name: String, types: [String] = [], idPrefixes: [String]? = nil) {
        self.name = name
        self.types = types
        self.idPrefixes = idPrefixes
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

struct AddonRatingsResponse: Decodable {
    let ratings: [AddonRatingItem]?

    init(ratings: [AddonRatingItem]?) {
        self.ratings = ratings
    }
}

struct AddonRatingItem: Decodable {
    let source: String
    let value: Double
    let url: String?

    enum CodingKeys: String, CodingKey {
        case source, value, url
    }

    init(source: String, value: Double, url: String? = nil) {
        self.source = source
        self.value = value
        self.url = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(String.self, forKey: .source)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        if let doubleVal = try? container.decode(Double.self, forKey: .value) {
            value = doubleVal
        } else if let stringVal = try? container.decode(String.self, forKey: .value),
                  let doubleVal = Double(stringVal) {
            value = doubleVal
        } else {
            value = 0.0
        }
    }
}

enum AddonRatingsService {
    /// UserDefaults supports concurrent access. Keep the caller's profile store
    /// when the shared cache runs its fetch closure in a detached task.
    private struct SendableDefaultsStore: @unchecked Sendable {
        let value: UserDefaults
    }

    /// Built-in providers that cannot be spoofed by add-ons.
    static let builtInProviders: Set<String> = [
        "imdb", "tmdb", "tomatoes", "metacritic", "trakt",
        "letterboxd", "audience", "myanimelist", "mal", "tvdb"
    ]

    static func deduplicatedRatings(_ ratings: [NuvioExternalRating]) -> [NuvioExternalRating] {
        var seenSources = Set<String>()
        return ratings.filter { rating in
            let source = rating.source.lowercased()
            return !builtInProviders.contains(source) && seenSources.insert(source).inserted
        }
    }

    static func formatRating(value: Double, max: Double?) -> String {
        guard value.isFinite else { return "—" }
        if let max, max.isFinite, max > 10 {
            let fraction = value / max
            let percent = fraction * 100
            guard fraction.isFinite, percent.isFinite else {
                return "\(formattedRatingNumber(value))/\(formattedRatingNumber(max))"
            }
            return formattedRatingPercent(percent)
        }
        if max == nil, value > 10 {
            return formattedRatingPercent(value)
        }
        return String(format: "%.1f", value)
    }

    private static func formattedRatingPercent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if abs(value) >= 1_000_000_000 {
            return String(format: "%.3g%%", value)
        }
        return String(format: "%.0f%%", value)
    }

    private static func formattedRatingNumber(_ value: Double) -> String {
        if abs(value) >= 1_000_000_000 || (value != 0 && abs(value) < 0.001) {
            return String(format: "%.3g", value)
        }
        return String(format: "%.1f", value)
    }

    private static let enabledKeyPrefix = "nuvio.tv.settings.ratings.addon_enabled."
    private static let iconOverrideKeyPrefix = "nuvio.tv.settings.ratings.addon_icon_override."
    private static let ratingOrderKey = "nuvio.tv.settings.ratings.order"
    static let ratingOrderChangedNotification = Notification.Name("nuvio.tv.settings.ratings.orderChanged")

    static func isSourceEnabled(_ source: String, defaults: UserDefaults = ProfileSettings.current) -> Bool {
        let key = enabledKeyPrefix + source.lowercased()
        return defaults.object(forKey: key) as? Bool ?? true
    }

    static func setSourceEnabled(_ source: String, enabled: Bool, defaults: UserDefaults = ProfileSettings.current) {
        let key = enabledKeyPrefix + source.lowercased()
        defaults.set(enabled, forKey: key)
    }

    static func iconOverride(for source: String, defaults: UserDefaults = ProfileSettings.current) -> String? {
        let key = iconOverrideKeyPrefix + source.lowercased()
        return defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func setIconOverride(for source: String, urlString: String?, defaults: UserDefaults = ProfileSettings.current) {
        let key = iconOverrideKeyPrefix + source.lowercased()
        let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let trimmed {
            defaults.set(trimmed, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static let defaultRatingOrder: [String] = [
        "imdb", "tmdb", "tomatoes", "metacritic", "trakt",
        "letterboxd", "audience", "myanimelist", "tvdb"
    ]

    static func savedRatingOrder(defaults: UserDefaults = ProfileSettings.current) -> [String] {
        guard let data = defaults.string(forKey: ratingOrderKey)?.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data),
              !list.isEmpty else {
            return defaultRatingOrder
        }
        let clean = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        return clean.isEmpty ? defaultRatingOrder : clean
    }

    static func setRatingOrder(_ order: [String], defaults: UserDefaults = ProfileSettings.current) {
        let clean = order.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard !clean.isEmpty else { return }
        if let data = try? JSONEncoder().encode(clean), let str = String(data: data, encoding: .utf8) {
            defaults.set(str, forKey: ratingOrderKey)
            NotificationCenter.default.post(name: ratingOrderChangedNotification, object: nil)
        }
    }

    static func normalizedSourceKey(_ source: String) -> String {
        let lower = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "mal" {
            return "myanimelist"
        }
        return lower
    }

    static func sortRatings<T>(
        _ items: [T],
        by sourceGetter: (T) -> String,
        defaults: UserDefaults = ProfileSettings.current
    ) -> [T] {
        let order = savedRatingOrder(defaults: defaults)
        guard !order.isEmpty else { return items }
        let orderMap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element.lowercased(), $0.offset) })

        return items.enumerated().sorted { a, b in
            let sourceA = normalizedSourceKey(sourceGetter(a.element))
            let sourceB = normalizedSourceKey(sourceGetter(b.element))
            let rankA = orderMap[sourceA] ?? Int.max
            let rankB = orderMap[sourceB] ?? Int.max
            if rankA != rankB {
                return rankA < rankB
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func loadManifestsConcurrently(urls: [URL]) async -> [URL: AddonRatingsManifest] {
        await withTaskGroup(of: (URL, AddonRatingsManifest?).self) { group in
            for url in urls {
                group.addTask {
                    guard let data = await StremioManifestDataCache.shared.data(for: url) else {
                        return (url, nil)
                    }
                    let manifest = try? JSONDecoder().decode(AddonRatingsManifest.self, from: data)
                    return (url, manifest)
                }
            }
            var result: [URL: AddonRatingsManifest] = [:]
            for await (url, manifest) in group {
                if let manifest {
                    result[url] = manifest
                }
            }
            return result
        }
    }

    static func availableRatingSources(
        manifestURLs: [URL]? = nil,
        defaults: UserDefaults = ProfileSettings.current
    ) async -> [AddonRatingSourceSummary] {
        let urls = manifestURLs ?? CinemetaCatalogRepository.configuredStreamAddonManifestURLs(in: defaults)
        let manifests = await loadManifestsConcurrently(urls: urls)
        var summaries: [AddonRatingSourceSummary] = []
        var seenSources = Set<String>()

        for url in urls {
            guard let manifest = manifests[url],
                  let sources = manifest.ratingSources, !sources.isEmpty else { continue }
            let addonName = manifest.displayName ?? CinemetaCatalogRepository.streamAddonName(for: url)
            for source in sources {
                let lower = source.source.lowercased()
                guard !builtInProviders.contains(lower) else { continue }
                guard seenSources.insert(lower).inserted else { continue }
                summaries.append(
                    AddonRatingSourceSummary(
                        source: source.source,
                        name: source.displayName,
                        addonName: addonName,
                        manifestIcon: source.icon,
                        userIconOverride: iconOverride(for: source.source, defaults: defaults),
                        max: source.max,
                        isEnabled: isSourceEnabled(source.source, defaults: defaults),
                        episodes: source.episodes
                    )
                )
            }
        }
        return summaries
    }

    static func hasEpisodeRatingProviders(
        manifestURLs: [URL]? = nil,
        defaults: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        let urls = manifestURLs ?? CinemetaCatalogRepository.configuredStreamAddonManifestURLs(in: defaults)
        guard !urls.isEmpty else { return false }
        let manifests = await loadManifestsConcurrently(urls: urls)
        for url in urls {
            guard let manifest = manifests[url],
                  let sources = manifest.ratingSources, !sources.isEmpty else { continue }
            for source in sources {
                let lower = source.source.lowercased()
                guard !builtInProviders.contains(lower) else { continue }
                guard isSourceEnabled(source.source, defaults: defaults) else { continue }
                if source.episodes == true {
                    return true
                }
            }
        }
        return false
    }

    static func fetchRatings(
        for meta: NuvioMeta,
        manifestURLs: [URL]? = nil,
        session: URLSession = .shared,
        defaults: UserDefaults = ProfileSettings.current
    ) async -> [NuvioExternalRating] {
        let urls = manifestURLs ?? CinemetaCatalogRepository.configuredStreamAddonManifestURLs(in: defaults)
        guard !urls.isEmpty else { return [] }

        let mediaType = meta.isSeries ? "series" : "movie"
        let contentID = meta.id

        let manifests = await loadManifestsConcurrently(urls: urls)
        var eligible: [(url: URL, manifest: AddonRatingsManifest)] = []
        for url in urls {
            guard let manifest = manifests[url],
                  manifest.supportsRatings(type: mediaType, id: contentID) else { continue }
            eligible.append((url, manifest))
        }
        guard !eligible.isEmpty else { return [] }

        return await withTaskGroup(of: (Int, [NuvioExternalRating]).self) { group in
            for (index, item) in eligible.enumerated() {
                group.addTask {
                    (
                        index,
                        await fetchRatingsFromAddon(
                            manifestURL: item.url,
                            manifest: item.manifest,
                            type: mediaType,
                            id: contentID,
                            session: session,
                            defaults: defaults
                        )
                    )
                }
            }
            var ratingsByAddon: [Int: [NuvioExternalRating]] = [:]
            for await (index, ratings) in group {
                ratingsByAddon[index] = ratings
            }
            let orderedRatings = eligible.indices.flatMap { ratingsByAddon[$0] ?? [] }
            return deduplicatedRatings(orderedRatings)
        }
    }

    static func fetchRatingsForEpisode(
        episodeId: String,
        seriesType: String = "series",
        manifestURLs: [URL]? = nil,
        session: URLSession = .shared,
        defaults: UserDefaults = ProfileSettings.current
    ) async -> [NuvioExternalRating] {
        let cleanId = episodeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanId.isEmpty else { return [] }

        if let cached = await AddonEpisodeRatingsCache.shared.cachedRatings(for: cleanId) {
            return cached
        }

        let urls = manifestURLs ?? CinemetaCatalogRepository.configuredStreamAddonManifestURLs(in: defaults)
        guard !urls.isEmpty else {
            await AddonEpisodeRatingsCache.shared.setRatings([], for: cleanId)
            return []
        }

        let manifests = await loadManifestsConcurrently(urls: urls)
        var eligible: [(url: URL, manifest: AddonRatingsManifest)] = []
        for url in urls {
            guard let manifest = manifests[url],
                  manifest.supportsRatings(type: seriesType, id: cleanId),
                  let sources = manifest.ratingSources,
                  sources.contains(where: { ($0.episodes == true) && isSourceEnabled($0.source, defaults: defaults) && !builtInProviders.contains($0.source.lowercased()) })
            else { continue }
            eligible.append((url, manifest))
        }

        guard !eligible.isEmpty else {
            await AddonEpisodeRatingsCache.shared.setRatings([], for: cleanId)
            return []
        }

        let ratings = await withTaskGroup(of: (Int, [NuvioExternalRating]).self) { group in
            for (index, item) in eligible.enumerated() {
                group.addTask {
                    (
                        index,
                        await fetchRatingsFromAddon(
                            manifestURL: item.url,
                            manifest: item.manifest,
                            type: seriesType,
                            id: cleanId,
                            session: session,
                            defaults: defaults,
                            episodesOnly: true
                        )
                    )
                }
            }
            var ratingsByAddon: [Int: [NuvioExternalRating]] = [:]
            for await (index, ratings) in group {
                ratingsByAddon[index] = ratings
            }
            let ordered = eligible.indices.flatMap { ratingsByAddon[$0] ?? [] }
            return deduplicatedRatings(ordered)
        }

        await AddonEpisodeRatingsCache.shared.setRatings(ratings, for: cleanId)
        return ratings
    }

    static func fetchRatingsForEpisodes(
        episodeIds: [String],
        seriesType: String = "series",
        manifestURLs: [URL]? = nil,
        session: URLSession = .shared,
        defaults: UserDefaults = ProfileSettings.current
    ) async -> [String: [NuvioExternalRating]] {
        guard !episodeIds.isEmpty else { return [:] }

        var missing: [String] = []
        var results: [String: [NuvioExternalRating]] = [:]

        for id in episodeIds {
            let cleanId = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanId.isEmpty else { continue }
            if let cached = await AddonEpisodeRatingsCache.shared.cachedRatings(for: cleanId) {
                results[cleanId] = cached
            } else {
                missing.append(cleanId)
            }
        }

        guard !missing.isEmpty else { return results }

        let hasProviders = await hasEpisodeRatingProviders(manifestURLs: manifestURLs, defaults: defaults)
        if !hasProviders {
            for id in missing {
                await AddonEpisodeRatingsCache.shared.setRatings([], for: id)
                results[id] = []
            }
            return results
        }

        await withTaskGroup(of: (String, [NuvioExternalRating]).self) { group in
            for id in missing {
                group.addTask {
                    let ratings = await fetchRatingsForEpisode(
                        episodeId: id,
                        seriesType: seriesType,
                        manifestURLs: manifestURLs,
                        session: session,
                        defaults: defaults
                    )
                    return (id, ratings)
                }
            }
            for await (id, ratings) in group {
                results[id] = ratings
            }
        }

        return results
    }

    static func fetchRatingsFromAddon(
        manifestURL: URL,
        manifest: AddonRatingsManifest,
        type: String,
        id: String,
        session: URLSession = .shared,
        defaults: UserDefaults = ProfileSettings.current,
        episodesOnly: Bool = false
    ) async -> [NuvioExternalRating] {
        guard let endpointURL = AddonTransportUrls.buildResourceURL(
            manifestURL: manifestURL,
            resource: "ratings",
            type: type,
            id: id
        ) else { return [] }

        var request = URLRequest(url: endpointURL)
        request.timeoutInterval = 8
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }
            let payload = try JSONDecoder().decode(AddonRatingsResponse.self, from: data)
            guard let items = payload.ratings, !items.isEmpty else { return [] }

            let sourceLookup = Dictionary(
                (manifest.ratingSources ?? []).map { ($0.source.lowercased(), $0) },
                uniquingKeysWith: { first, _ in first }
            )

            var results: [NuvioExternalRating] = []
            for item in items {
                let lower = item.source.lowercased()
                // Anti-spoofing: prevent overriding built-in providers
                guard !builtInProviders.contains(lower) else { continue }
                // User disabled toggle check
                guard isSourceEnabled(item.source, defaults: defaults) else { continue }

                let declared = sourceLookup[lower]
                if episodesOnly {
                    guard declared?.episodes == true else { continue }
                }

                let displayName = declared?.name ?? item.source
                let manifestIcon = declared?.icon
                let overrideIcon = iconOverride(for: item.source, defaults: defaults)
                let effectiveIcon = (overrideIcon?.isEmpty == false) ? overrideIcon : manifestIcon
                let max = declared?.max

                results.append(
                    NuvioExternalRating(
                        source: item.source,
                        value: item.value,
                        url: item.url,
                        name: displayName,
                        iconUrl: effectiveIcon,
                        max: max
                    )
                )
            }
            return results
        } catch {
            return []
        }
    }

    // MARK: - Home Hero Rating Source & Resolution

    /// Hero rating source that shows the full Details ratings row (icons, up
    /// to five providers) instead of a single "IMDb 7.4" label.
    static let heroAllRatingsSource = "all"

    /// Computed so the "All" label follows an in-app language change.
    static var builtInHeroRatingSources: [HeroRatingSourceOption] {
        [
            HeroRatingSourceOption(
                id: heroAllRatingsSource,
                displayName: L10n.string("tvos_layout_hero_rating_all", fallback: "All (as in Details)"),
                addonName: nil
            ),
            HeroRatingSourceOption(id: "imdb", displayName: "IMDb", addonName: nil),
            HeroRatingSourceOption(id: "tmdb", displayName: "TMDB", addonName: nil),
            HeroRatingSourceOption(id: "tomatoes", displayName: "Rotten Tomatoes", addonName: nil),
            HeroRatingSourceOption(id: "metacritic", displayName: "Metacritic", addonName: nil),
            HeroRatingSourceOption(id: "trakt", displayName: "Trakt", addonName: nil),
            HeroRatingSourceOption(id: "letterboxd", displayName: "Letterboxd", addonName: nil),
            HeroRatingSourceOption(id: "audience", displayName: "Audience Score", addonName: nil),
            HeroRatingSourceOption(id: "myanimelist", displayName: "MyAnimeList", addonName: nil),
            HeroRatingSourceOption(id: "tvdb", displayName: "TVDB", addonName: nil)
        ]
    }

    static func availableHeroRatingSources(
        defaults: UserDefaults = ProfileSettings.current
    ) async -> [HeroRatingSourceOption] {
        var options = builtInHeroRatingSources
        let addonSources = await availableRatingSources(defaults: defaults)
        for addon in addonSources {
            let id = addon.source.lowercased()
            if !options.contains(where: { $0.id == id }) {
                options.append(
                    HeroRatingSourceOption(
                        id: id,
                        displayName: addon.name,
                        addonName: addon.addonName
                    )
                )
            }
        }
        return options
    }

    static func heroRatingDisplayName(for sourceId: String, customName: String? = nil) -> String {
        switch sourceId.lowercased() {
        case "imdb": return "IMDb"
        case "tmdb": return "TMDB"
        case "tomatoes", "rotten_tomatoes": return "Rotten Tomatoes"
        case "metacritic": return "Metacritic"
        case "trakt": return "Trakt"
        case "letterboxd": return "Letterboxd"
        case "audience": return "Audience"
        case "myanimelist", "mal": return "MAL"
        case "tvdb": return "TVDB"
        default: return customName ?? sourceId.capitalized
        }
    }

    static func heroRatingString(
        for meta: NuvioMeta,
        source: String,
        ratings: [NuvioExternalRating]? = nil
    ) -> String? {
        let cleanSource = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedRatings = ratings ?? meta.externalRatings ?? []

        if cleanSource.isEmpty || cleanSource == "imdb" {
            if let match = resolvedRatings.first(where: { $0.source.lowercased() == "imdb" }) {
                return "IMDb \(formatRating(value: match.value, max: match.max))"
            }
            return meta.rating.map { String(format: "IMDb %.1f", $0) }
        }

        if let match = resolvedRatings.first(where: { isSourceMatch(requested: cleanSource, actual: $0.source) }) {
            let label = heroRatingDisplayName(for: match.source, customName: match.name)
            let formatted = formatRating(value: match.value, max: match.max)
            return "\(label) \(formatted)"
        }

        if cleanSource == "tmdb", let rating = meta.rating, meta.tmdbId != nil, meta.imdbId == nil {
            return String(format: "TMDB %.1f", rating)
        }

        return meta.rating.map { String(format: "IMDb %.1f", $0) }
    }

    static func sampleRatingString(for source: String) -> String {
        switch source.lowercased() {
        case heroAllRatingsSource: return "IMDb 8.6  ·  TMDB 86  ·  RT 92%"
        case "tmdb": return "TMDB 8.6"
        case "tomatoes", "rotten_tomatoes": return "Rotten Tomatoes 92%"
        case "metacritic": return "Metacritic 79"
        case "trakt": return "Trakt 8.4"
        case "letterboxd": return "Letterboxd 4.2"
        case "audience": return "Audience 95%"
        case "myanimelist", "mal": return "MAL 8.7"
        case "tvdb": return "TVDB 8.8"
        case "csfd": return "ČSFD 86%"
        case "douban": return "Douban 8.4"
        case "kinopoisk": return "Кинопоиск 8.3"
        default:
            if source.lowercased() == "imdb" || source.isEmpty {
                return "IMDb 8.6"
            }
            return "\(heroRatingDisplayName(for: source)) 8.6"
        }
    }

    static func fetchHomeHeroRatings(
        for meta: NuvioMeta,
        defaults: UserDefaults = ProfileSettings.current
    ) async -> [NuvioExternalRating] {
        let key = homeHeroRatingsKey(for: meta)
        if let cached = HomeHeroRatingsCache.shared.cachedRatings(for: key) {
            return cached
        }

        // The hero, a prefetch of the next slide and Details can ask for the
        // same title at once; they share one request.
        let defaultsStore = SendableDefaultsStore(value: defaults)
        let combined = await HomeHeroRatingsCache.shared.load(key: key) {
            async let addonRatingsTask = fetchRatings(for: meta, defaults: defaultsStore.value)
            async let mdbRatingsTask = MdbListDetailsService.fetchRatings(for: meta)
            let (addonRatings, mdbRatings) = await (addonRatingsTask, mdbRatingsTask)

            var seen = Set<String>()
            return (mdbRatings + addonRatings).filter { seen.insert($0.source.lowercased()).inserted }
        }
        return combined
    }

    /// Cache key shared by the hero and Details for one title.
    static func homeHeroRatingsKey(for meta: NuvioMeta) -> String {
        NuvioMeta.canonicalImdbID(from: meta.imdbId ?? meta.id) ?? meta.id
    }

    /// Ratings already fetched for this title, read synchronously so a view
    /// can show them in the same frame it switches to the title.
    static func cachedHomeHeroRatings(for meta: NuvioMeta) -> [NuvioExternalRating]? {
        HomeHeroRatingsCache.shared.cachedRatings(for: homeHeroRatingsKey(for: meta))
    }

    /// Details fetches the same providers; keep its result for the hero.
    static func storeHomeHeroRatings(_ ratings: [NuvioExternalRating], for meta: NuvioMeta) {
        guard !ratings.isEmpty else { return }
        var seen = Set<String>()
        let unique = ratings.filter { seen.insert($0.source.lowercased()).inserted }
        HomeHeroRatingsCache.shared.setRatings(unique, for: homeHeroRatingsKey(for: meta))
    }

    /// Warms the cache for titles about to be shown (the next hero slide).
    static func prefetchHomeHeroRatings(for metas: [NuvioMeta]) {
        for meta in metas where cachedHomeHeroRatings(for: meta) == nil {
            Task.detached(priority: .utility) {
                _ = await fetchHomeHeroRatings(for: meta)
            }
        }
    }

    static func heroShowsAllRatings(_ source: String) -> Bool {
        source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == heroAllRatingsSource
    }

    /// Whether the hero needs MDBList/add-on ratings for this title, beyond
    /// the IMDb score every catalog item carries.
    static func heroNeedsFetchedRatings(source: String, meta: NuvioMeta) -> Bool {
        let clean = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if clean == heroAllRatingsSource { return true }
        guard !clean.isEmpty, clean != "imdb" else { return false }
        return meta.externalRatings?.isEmpty ?? true
    }

    /// The ratings the hero's "All" row shows: fetched ones first, then any
    /// the catalog item carried, then the catalog IMDb score so the row is
    /// never empty while the rest load.
    static func heroDisplayRatings(
        for meta: NuvioMeta,
        fetched: [NuvioExternalRating]?
    ) -> [NuvioExternalRating] {
        var result: [NuvioExternalRating] = []
        var seen = Set<String>()
        func add(_ rating: NuvioExternalRating) {
            guard rating.value.isFinite,
                  seen.insert(normalizedSourceKey(rating.source)).inserted else { return }
            result.append(rating)
        }
        (fetched ?? cachedHomeHeroRatings(for: meta) ?? []).forEach(add)
        (meta.externalRatings ?? []).forEach(add)
        if let imdb = meta.rating, imdb > 0 {
            add(NuvioExternalRating(source: MdbListDetailsService.providerIMDb, value: imdb, max: 10))
        }
        return result
    }

    private static func isSourceMatch(requested: String, actual: String) -> Bool {
        let req = requested.lowercased()
        let act = actual.lowercased()
        if req == act { return true }
        if (req == "myanimelist" || req == "mal") && (act == "myanimelist" || act == "mal") { return true }
        if (req == "tomatoes" || req == "rotten_tomatoes") && (act == "tomatoes" || act == "rotten_tomatoes") { return true }
        return false
    }
}

/// An option representing a rating source selectable for the Home hero info.
struct HeroRatingSourceOption: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let addonName: String?

    var selectionLabel: String {
        if let addonName, !addonName.isEmpty {
            return "\(displayName) (\(addonName))"
        }
        return displayName
    }
}

/// Thread-safe in-memory cache for Home Hero external ratings, shared with
/// Details. A lock instead of an actor so views read it synchronously while
/// they render; entries expire so scores do not go stale over a long session.
final class HomeHeroRatingsCache: @unchecked Sendable {
    static let shared = HomeHeroRatingsCache()

    private static let timeToLive: TimeInterval = 30 * 60
    /// A title with no ratings may simply have hit a timeout; retry sooner.
    private static let emptyTimeToLive: TimeInterval = 2 * 60
    private static let maxEntries = 400

    private struct Entry {
        let ratings: [NuvioExternalRating]
        let storedAt: Date
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<[NuvioExternalRating], Never>] = [:]

    func cachedRatings(for key: String) -> [NuvioExternalRating]? {
        let key = key.lowercased()
        return lock.withLock {
            guard let entry = cache[key] else { return nil }
            let lifetime = entry.ratings.isEmpty ? Self.emptyTimeToLive : Self.timeToLive
            guard Date().timeIntervalSince(entry.storedAt) < lifetime else {
                cache[key] = nil
                return nil
            }
            return entry.ratings
        }
    }

    func setRatings(_ ratings: [NuvioExternalRating], for key: String) {
        let key = key.lowercased()
        lock.withLock {
            if cache[key] == nil, cache.count >= Self.maxEntries {
                // Drop the oldest quarter rather than one entry per insert.
                let oldest = cache.sorted { $0.value.storedAt < $1.value.storedAt }
                    .prefix(Self.maxEntries / 4)
                    .map(\.key)
                oldest.forEach { cache[$0] = nil }
            }
            cache[key] = Entry(ratings: ratings, storedAt: Date())
        }
    }

    /// Runs `fetch` once per key at a time; later callers wait for the same
    /// result. The result is stored before anyone is answered.
    func load(
        key: String,
        fetch: @escaping @Sendable () async -> [NuvioExternalRating]
    ) async -> [NuvioExternalRating] {
        let key = key.lowercased()
        let task: Task<[NuvioExternalRating], Never> = lock.withLock {
            if let existing = inFlight[key] { return existing }
            let task = Task.detached(priority: .userInitiated) { [weak self] () -> [NuvioExternalRating] in
                let ratings = await fetch()
                self?.finish(key: key, ratings: ratings)
                return ratings
            }
            inFlight[key] = task
            return task
        }
        return await task.value
    }

    private func finish(key: String, ratings: [NuvioExternalRating]) {
        setRatings(ratings, for: key)
        lock.withLock { inFlight[key] = nil }
    }

    func clear() {
        lock.withLock { cache.removeAll() }
    }
}

/// Thread-safe in-memory cache for per-episode external ratings.
actor AddonEpisodeRatingsCache {
    static let shared = AddonEpisodeRatingsCache()
    private var cache: [String: [NuvioExternalRating]] = [:]

    func cachedRatings(for episodeId: String) -> [NuvioExternalRating]? {
        cache[episodeId.lowercased()]
    }

    func setRatings(_ ratings: [NuvioExternalRating], for episodeId: String) {
        cache[episodeId.lowercased()] = ratings
    }

    func clear() {
        cache.removeAll()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

