import CryptoKit
import Foundation
import OSLog

/// Production company / network shown on the details Production row.
struct MetaCompany: Identifiable, Equatable, Hashable {
    var id: String { "\(kind.rawValue)-\(tmdbId ?? name.hashValue)" }
    let name: String
    let logoURL: String?
    let tmdbId: Int?
    let kind: Kind

    enum Kind: String, Equatable, Hashable {
        case production
        case network
    }
}

struct TmdbPersonMetadata: Identifiable, Equatable, Hashable {
    var id: String { tmdbId.map(String.init) ?? name }
    let name: String
    let role: String?
    let profileURL: String?
    let tmdbId: Int?
}

struct TmdbCreditMetadata {
    let cast: [String]
    let directors: [String]
    let writers: [String]
    let people: [TmdbPersonMetadata]

    var isEmpty: Bool {
        cast.isEmpty && directors.isEmpty && writers.isEmpty
    }

    func applying(to meta: NuvioMeta) -> NuvioMeta {
        NuvioMeta(
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
            genres: meta.genres,
            rating: meta.rating,
            releaseInfo: meta.releaseInfo,
            runtime: meta.runtime,
            cast: cast.isEmpty ? meta.cast : cast,
            director: directors.isEmpty ? meta.director : directors,
            writer: writers.isEmpty ? meta.writer : writers,
            certification: meta.certification,
            country: meta.country,
            language: meta.language,
            released: meta.released,
            status: meta.status,
            videos: meta.videos,
            trailerYtIds: meta.trailerYtIds,
            externalRatings: meta.externalRatings,
            posterShape: meta.posterShape,
            isFromAddon: meta.isFromAddon,
            landscapePosterUrl: meta.landscapePosterUrl
        )
    }
}
/// Lightweight related-title card for More Like This / production browse.
struct RelatedTitle: Identifiable, Equatable {
    let id: String
    let type: String
    let name: String
    let posterURL: String?
    let year: String?
    let rating: Double?
    let overview: String?
    let backdropURL: String?

    init(
        id: String,
        type: String,
        name: String,
        posterURL: String?,
        year: String?,
        rating: Double?,
        overview: String?,
        backdropURL: String? = nil
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.posterURL = posterURL
        self.year = year
        self.rating = rating
        self.overview = overview
        self.backdropURL = backdropURL
    }

    var asMeta: NuvioMeta {
        NuvioMeta(
            id: id,
            name: name,
            description: overview,
            // Trakt's related endpoint often returns the IMDb id but no usable
            // `images` payload. Cinemeta/Metahub exposes a stable poster URL
            // for every IMDb id, so use it immediately instead of showing an
            // empty poster while optional metadata enrichment runs.
            posterUrl: resolvedPosterURL,
            backgroundUrl: backdropURL,
            logoUrl: nil,
            imdbId: id.hasPrefix("tt") ? id : nil,
            tmdbId: id.hasPrefix("tmdb:") ? Int(id.dropFirst(5)) : nil,
            type: type,
            year: year.flatMap(Int.init),
            genres: nil,
            rating: rating,
            releaseInfo: year,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil,
            videos: nil,
            trailerYtIds: nil
        )
    }

    private static func cinemetaPosterURL(for id: String) -> String? {
        let imdbID = id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? id
        guard imdbID.hasPrefix("tt") else { return nil }
        return "https://images.metahub.space/poster/small/\(imdbID)/img"
    }

    private var resolvedPosterURL: String? {
        // Prefer the same stable IMDb poster host used by the primary catalog.
        // Trakt often supplies a non-empty image path without a URL scheme,
        // which Swift's image loader must reject.
        if let cinemetaPosterURL = RelatedTitle.cinemetaPosterURL(for: id) {
            return cinemetaPosterURL
        }
        guard let posterURL,
              !posterURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return posterURL
    }
}

/// Network metadata and the sorted TV rails shown by the network catalog.
struct TmdbNetworkBrowseData: Equatable {
    let name: String
    let logoURL: String?
    let originCountry: String?
    let headquarters: String?
    let rails: [TmdbNetworkBrowseRail]
}

struct TmdbNetworkBrowseRail: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [RelatedTitle]
}

/// TMDB helpers for details enrichment: production companies, more-like-this,
/// and discovering everything a company/network has made.
enum TmdbDetailsService {
    private static let apiBase = URL(string: "https://api.themoviedb.org/3")!
    private static let imageBase = "https://image.tmdb.org/t/p/"
    private static let localizedDetailsCache = TmdbLocalizedDetailsCache()
    private static let findCache = TmdbFindCache()
    private static let detailsCache = TmdbDetailsCache()

    private struct RequestContext: Sendable {
        let apiKey: String?
        let isEnabled: Bool
        let language: String
        let flags: [String: Bool]
    }

    @TaskLocal private static var requestContext: RequestContext?

    // A value snapshot, inherited by structured child tasks and nested calls.
    // The optional store lets regression tests exercise it without network I/O.
    static func withRequestContext<T>(
        defaults: UserDefaults? = nil,
        _ operation: () async -> T
    ) async -> T {
        if requestContext != nil { return await operation() }
        let store = defaults ?? ProfileSettings.current
        let rawKey = store.string(forKey: SettingsKey.tmdbApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let keys = [
            SettingsKey.tmdbUseTrailers, SettingsKey.tmdbUseArtwork,
            SettingsKey.tmdbUseBasicInfo, SettingsKey.tmdbUseDetails,
            SettingsKey.tmdbUseCredits, SettingsKey.tmdbUseProductions,
            SettingsKey.tmdbUseNetworks, SettingsKey.tmdbUseEpisodes,
            SettingsKey.tmdbUseSeasonPosters, SettingsKey.tmdbUseMoreLikeThis,
            SettingsKey.tmdbUseCollections, SettingsKey.tmdbApplyToHome
        ]
        let flags = Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, (store.object(forKey: key) as? Bool) ?? (key != SettingsKey.tmdbApplyToHome))
        })
        let context = RequestContext(
            apiKey: rawKey.isEmpty ? nil : rawKey,
            isEnabled: (store.object(forKey: SettingsKey.tmdbEnabled) as? Bool) ?? false,
            language: TmdbMetadataLanguage.resolvedLanguage(in: store),
            flags: flags
        )
        return await $requestContext.withValue(context) { await operation() }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpMaximumConnectionsPerHost = 10
        config.waitsForConnectivity = false
        config.requestCachePolicy = .useProtocolCachePolicy
        let totalRam = ProcessInfo.processInfo.physicalMemory
        let isLegacyDevice = totalRam <= 2_500_000_000 // <= 2.5 GB (Apple TV HD)
        config.urlCache = URLCache(
            memoryCapacity: isLegacyDevice ? (10 * 1024 * 1024) : (30 * 1024 * 1024),
            diskCapacity: isLegacyDevice ? (50 * 1024 * 1024) : (150 * 1024 * 1024),
            diskPath: "nuvio_tmdb_urlcache"
        )
        return URLSession(configuration: config)
    }()

    static func clearCache() async {
        await findCache.clear()
        await localizedDetailsCache.clear()
        await detailsCache.clear()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    private static func data(for url: URL, timeout: TimeInterval = 8) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        return try await session.data(for: request)
    }

    static var currentApiKey: String? { apiKey }
    private static var apiKey: String? {
        if let requestContext { return requestContext.apiKey }
        let key = ProfileSettings.current.string(forKey: SettingsKey.tmdbApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    private static var isEnabled: Bool {
        if let requestContext { return requestContext.isEnabled }
        return (ProfileSettings.current.object(forKey: SettingsKey.tmdbEnabled) as? Bool) ?? false
    }

    static var preferredLanguage: String {
        if let requestContext { return requestContext.language }
        return TmdbMetadataLanguage.resolvedLanguage(in: ProfileSettings.current)
    }

    /// Opaque cache discriminator for trailer lookups. The key itself must
    /// never become part of a cache key or diagnostic string.
    static var trailerResolutionConfigurationIdentity: String {
        let keyFingerprint = currentApiKey.map {
            SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        } ?? "no-key"
        return "\(isEnabled)|\(useTrailers)|\(keyFingerprint)"
    }

    static var useTrailers: Bool { tmdbBoolean(SettingsKey.tmdbUseTrailers) }
    static var useArtwork: Bool { tmdbBoolean(SettingsKey.tmdbUseArtwork) }
    static var useBasicInfo: Bool { tmdbBoolean(SettingsKey.tmdbUseBasicInfo) }
    static var useDetails: Bool { tmdbBoolean(SettingsKey.tmdbUseDetails) }
    static var useCredits: Bool { tmdbBoolean(SettingsKey.tmdbUseCredits) }
    static var useProductions: Bool { tmdbBoolean(SettingsKey.tmdbUseProductions) }
    static var useNetworks: Bool { tmdbBoolean(SettingsKey.tmdbUseNetworks) }
    static var useEpisodes: Bool { tmdbBoolean(SettingsKey.tmdbUseEpisodes) }
    static var useSeasonPosters: Bool { tmdbBoolean(SettingsKey.tmdbUseSeasonPosters) }
    static var useMoreLikeThis: Bool { tmdbBoolean(SettingsKey.tmdbUseMoreLikeThis) }
    static var useCollections: Bool { tmdbBoolean(SettingsKey.tmdbUseCollections) }
    static var useHomeEnrichment: Bool { tmdbBoolean(SettingsKey.tmdbApplyToHome, defaultValue: false) }

    // MARK: - Public

    static func resolveTmdbId(for meta: NuvioMeta) async -> (id: Int, mediaType: String)? {
        if requestContext == nil {
            return await withRequestContext { await resolveTmdbId(for: meta) }
        }
        guard isEnabled, apiKey != nil else { return nil }
        let mediaType = (meta.isSeries || isSeries(meta.type)) ? "tv" : "movie"

        // 1. Direct fast-path: if tmdbId is already known or id has tmdb: prefix, resolve in 0ms without network call
        if let tmdbId = meta.tmdbId, tmdbId > 0 {
            return (tmdbId, mediaType)
        }
        if meta.id.hasPrefix("tmdb:") {
            let stripped = meta.id.dropFirst(5)
            let idPart = stripped.split(separator: ":").first.map(String.init) ?? String(stripped)
            if let parsedId = Int(idPart), parsedId > 0 {
                return (parsedId, mediaType)
            }
        }

        // 2. If IMDb id is available, resolve via TMDB's /find/ endpoint with in-flight deduplication
        let imdb = meta.imdbId ?? (meta.id.hasPrefix("tt") ? meta.id.split(separator: ":").first.map(String.init) : nil)
        if let imdb, imdb.hasPrefix("tt"), let resolved = await findByImdb(imdb, mediaTypeHint: mediaType) {
            return resolved
        }

        return nil
    }

    static func fetchCompanies(for meta: NuvioMeta) async -> [MetaCompany] {
        if requestContext == nil {
            return await withRequestContext { await fetchCompanies(for: meta) }
        }
        guard useProductions || useNetworks else { return [] }
        guard let resolved = await resolveTmdbId(for: meta) else { return [] }
        return await fetchCompanies(tmdbId: resolved.id, mediaType: resolved.mediaType)
    }

    static func fetchTrailerYouTubeId(for meta: NuvioMeta) async -> String? {
        if requestContext == nil {
            return await withRequestContext { await fetchTrailerYouTubeId(for: meta) }
        }
        guard useTrailers,
              apiKey != nil,
              let resolved = await resolveTmdbId(for: meta) else {
            return nil
        }
        return await fetchTrailerYouTubeId(tmdbId: resolved.id, mediaType: resolved.mediaType)
    }

    static func fetchTrailerYouTubeId(tmdbId: Int, mediaType: String) async -> String? {
        if requestContext == nil {
            return await withRequestContext { await fetchTrailerYouTubeId(tmdbId: tmdbId, mediaType: mediaType) }
        }
        guard let apiKey else { return nil }

        // 1. Try preferred language first
        if let key = await fetchVideosKey(tmdbId: tmdbId, mediaType: mediaType, language: preferredLanguage, apiKey: apiKey) {
            return key
        }

        // 2. Fallback to en-US if preferred language differs
        if preferredLanguage.caseInsensitiveCompare("en-US") != .orderedSame {
            if let key = await fetchVideosKey(tmdbId: tmdbId, mediaType: mediaType, language: "en-US", apiKey: apiKey) {
                return key
            }
        }

        // 3. Fallback to unlocalized / all languages
        return await fetchVideosKey(tmdbId: tmdbId, mediaType: mediaType, language: nil, apiKey: apiKey)
    }

    private static func fetchVideosKey(tmdbId: Int, mediaType: String, language: String?, apiKey: String) async -> String? {
        var components = URLComponents(
            url: apiBase.appendingPathComponent("\(mediaType)/\(tmdbId)/videos"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        if let language, !language.isEmpty {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }
        components.queryItems = queryItems
        guard let url = components.url,
              let (data, response) = try? await data(for: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TmdbVideosResponse.self, from: data) else {
            return nil
        }

        return decoded.results
            .filter { $0.site?.caseInsensitiveCompare("YouTube") == .orderedSame }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank > rhs.rank }
                return (lhs.publishedAt ?? "") > (rhs.publishedAt ?? "")
            }
            .first?
            .key
    }

    static func fetchCredits(for meta: NuvioMeta) async -> TmdbCreditMetadata? {
        if requestContext == nil {
            return await withRequestContext { await fetchCredits(for: meta) }
        }
        guard useCredits,
              let apiKey,
              let resolved = await resolveTmdbId(for: meta) else {
            return nil
        }

        var components = URLComponents(
            url: apiBase.appendingPathComponent("\(resolved.mediaType)/\(resolved.id)/credits"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: preferredLanguage)
        ]
        guard let url = components.url,
              let (data, response) = try? await data(for: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TmdbCreditsResponse.self, from: data) else {
            return nil
        }

        func distinctNames(_ values: [String?]) -> [String] {
            var seen = Set<String>()
            return values.compactMap { value in
                guard let value = nonEmpty(value), seen.insert(value).inserted else { return nil }
                return value
            }
        }

        let cast = distinctNames(
            (decoded.cast ?? [])
                .sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
                .map(\.name)
        )
        let directors = distinctNames(
            (decoded.crew ?? [])
                .filter { $0.job?.caseInsensitiveCompare("Director") == .orderedSame }
                .map(\.name)
        )
        let writers = distinctNames(
            (decoded.crew ?? [])
                .filter {
                    let job = $0.job?.lowercased() ?? ""
                    return job.contains("writer") || job.contains("screenplay")
                }
                .map(\.name)
        )

        let creatorPeople = await fetchCreators(for: resolved)
        let directorPeople = (decoded.crew ?? [])
            .filter { $0.job?.caseInsensitiveCompare("Director") == .orderedSame }
            .compactMap { person -> TmdbPersonMetadata? in
                guard let name = nonEmpty(person.name) else { return nil }
                return TmdbPersonMetadata(
                    name: name,
                    role: "Director",
                    profileURL: imageURL(person.profilePath, size: "w500"),
                    tmdbId: person.id
                )
            }
        let castPeople = (decoded.cast ?? [])
            .sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
            .compactMap { person -> TmdbPersonMetadata? in
                guard let name = nonEmpty(person.name) else { return nil }
                return TmdbPersonMetadata(
                    name: name,
                    role: nonEmpty(person.character),
                    profileURL: imageURL(person.profilePath, size: "w500"),
                    tmdbId: person.id
                )
            }

        var seenPeople = Set<String>()
        let people = (creatorPeople + directorPeople + castPeople).filter {
            seenPeople.insert($0.id).inserted
        }

        return TmdbCreditMetadata(
            cast: cast,
            directors: directors,
            writers: writers,
            people: people
        )
    }

    private static func fetchCreators(
        for resolved: (id: Int, mediaType: String)
    ) async -> [TmdbPersonMetadata] {
        guard resolved.mediaType == "tv", apiKey != nil else { return [] }
        guard let decoded = await fetchDetailsResponse(tmdbId: resolved.id, mediaType: resolved.mediaType) else {
            return []
        }
        return (decoded.createdBy ?? []).compactMap { creator in
            guard let name = nonEmpty(creator.name) else { return nil }
            return TmdbPersonMetadata(
                name: name,
                role: "Creator",
                profileURL: imageURL(creator.profilePath, size: "w500"),
                tmdbId: creator.id
            )
        }
    }

    static func fetchMoreLikeThis(for meta: NuvioMeta, limit: Int = 16) async -> [RelatedTitle] {
        if requestContext == nil {
            return await withRequestContext { await fetchMoreLikeThis(for: meta, limit: limit) }
        }
        guard useMoreLikeThis else { return [] }
        guard let resolved = await resolveTmdbId(for: meta) else { return [] }
        return await fetchRecommendations(
            tmdbId: resolved.id,
            mediaType: resolved.mediaType,
            limit: limit
        )
    }

    /// Fetches full season and episode listings from TMDB, enabling unreleased/TBD episodes
    /// and accurate episode thumbnails/titles for ongoing and announced TV series.
    static func fetchEpisodes(for meta: NuvioMeta) async -> [NuvioVideo]? {
        if requestContext == nil {
            return await withRequestContext { await fetchEpisodes(for: meta) }
        }
        guard useEpisodes,
              let apiKey,
              let resolved = await resolveTmdbId(for: meta),
              resolved.mediaType == "tv" else {
            return nil
        }

        var components = URLComponents(
            url: apiBase.appendingPathComponent("tv/\(resolved.id)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: preferredLanguage)
        ]
        guard let url = components.url,
              let (data, response) = try? await data(for: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let showDetails = try? JSONDecoder().decode(TmdbTvShowDetailsResponse.self, from: data) else {
            return nil
        }

        let seasonNumbers = (showDetails.seasons ?? []).compactMap { season -> Int? in
            guard let num = season.seasonNumber, num >= 0 else { return nil }
            return num
        }

        // Bounded batching (max 4 seasons at a time) to prevent memory spikes on massive series (e.g. 20-40 seasons)
        var allVideos: [NuvioVideo] = []
        let batchSize = 4
        for i in stride(from: 0, to: seasonNumbers.count, by: batchSize) {
            let chunk = Array(seasonNumbers[i..<min(i + batchSize, seasonNumbers.count)])
            let chunkVideos = await withTaskGroup(of: [NuvioVideo].self) { group in
                for seasonNum in chunk {
                    group.addTask {
                        await fetchSeasonEpisodes(
                            parentId: meta.streamId,
                            tmdbId: resolved.id,
                            seasonNumber: seasonNum,
                            apiKey: apiKey
                        )
                    }
                }
                var batchResult: [NuvioVideo] = []
                for await seasonVideos in group {
                    batchResult.append(contentsOf: seasonVideos)
                }
                return batchResult
            }
            allVideos.append(contentsOf: chunkVideos)
        }
        return allVideos.isEmpty ? nil : allVideos
    }

    private static func fetchSeasonEpisodes(
        parentId: String,
        tmdbId: Int,
        seasonNumber: Int,
        apiKey: String
    ) async -> [NuvioVideo] {
        let requestedCode = preferredLanguage.split(separator: "-").first.map(String.init) ?? "en"
        var components = URLComponents(
            url: apiBase.appendingPathComponent("tv/\(tmdbId)/season/\(seasonNumber)"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: preferredLanguage)
        ]
        // Only request translations payload if non-English, avoiding massive redundant translation matrices
        if requestedCode.caseInsensitiveCompare("en") != .orderedSame {
            queryItems.append(URLQueryItem(name: "append_to_response", value: "translations"))
        }
        components.queryItems = queryItems
        guard let url = components.url,
              let (data, response) = try? await data(for: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let seasonDetails = try? JSONDecoder().decode(TmdbSeasonDetailsResponse.self, from: data) else {
            return []
        }

        let baseParentId = parentId.hasPrefix("tt") ? parentId : "tmdb:\(tmdbId)"
        return (seasonDetails.episodes ?? []).compactMap { ep -> NuvioVideo? in
            guard let epNum = ep.episodeNumber else { return nil }
            let epSeason = ep.seasonNumber ?? seasonNumber
            let ratingStr = ep.voteAverage.flatMap { $0 > 0 ? String(format: "%.1f", $0) : nil }

            let matchingTrans = ep.translations?.translations?.first(where: { item in
                guard let iso = item.iso6391, iso.caseInsensitiveCompare(requestedCode) == .orderedSame else {
                    return false
                }
                let hasName = !(item.data?.name?.isEmpty ?? true)
                let hasOverview = !(item.data?.overview?.isEmpty ?? true)
                return hasName || hasOverview
            })

            let epName = nonEmpty(matchingTrans?.data?.name) ?? nonEmpty(ep.name) ?? "Episode \(epNum)"
            let epOverview = nonEmpty(matchingTrans?.data?.overview) ?? nonEmpty(ep.overview)

            return NuvioVideo(
                id: "\(baseParentId):\(epSeason):\(epNum)",
                title: epName,
                season: epSeason,
                episode: epNum,
                thumbnail: imageURL(ep.stillPath, size: "w500"),
                overview: epOverview,
                released: nonEmpty(ep.airDate),
                rating: ratingStr
            )
        }
    }

    /// Applies the selected TMDB language to user-facing text while retaining
    /// Cinemeta/add-on values wherever TMDB has no translation.
    static func localizedMetadata(for meta: NuvioMeta) async -> NuvioMeta {
        if requestContext == nil {
            return await withRequestContext { await localizedMetadata(for: meta) }
        }
        guard useBasicInfo || useArtwork else { return meta }
        guard let resolved = await resolveTmdbId(for: meta),
              let details = await fetchLocalizedDetails(
                tmdbId: resolved.id,
                mediaType: resolved.mediaType
              ) else {
            return meta
        }

        let requestedCode = preferredLanguage.split(separator: "-").first.map(String.init) ?? "en"

        let matchingTranslation = details.translations?.translations?.first(where: {
            $0.iso6391?.caseInsensitiveCompare(requestedCode) == .orderedSame
                && (!($0.data?.title?.isEmpty ?? true) || !($0.data?.name?.isEmpty ?? true) || !($0.data?.overview?.isEmpty ?? true))
        })

        let translatedTitle = nonEmpty(matchingTranslation?.data?.title ?? matchingTranslation?.data?.name)
        let translatedOverview = nonEmpty(matchingTranslation?.data?.overview)

        let rawTitle = nonEmpty(details.title ?? details.name)
        let originalTitle = nonEmpty(details.originalTitle ?? details.originalName)

        let localizedTitle: String?
        if let translatedTitle {
            localizedTitle = translatedTitle
        } else if requestedCode != "en",
                  rawTitle == originalTitle,
                  let originalLanguage = nonEmpty(details.originalLanguage),
                  originalLanguage.caseInsensitiveCompare(requestedCode) != .orderedSame {
            localizedTitle = nil
        } else {
            localizedTitle = rawTitle
        }

        let localizedOverview = translatedOverview ?? nonEmpty(details.overview)

        let localizedGenres = details.genres?
            .compactMap { nonEmpty($0.name) }
            .nilIfEmpty
        let tmdbPosterURL = useArtwork ? imageURL(details.posterPath, size: "w500") : nil
        let tmdbBackgroundURL = useArtwork ? imageURL(details.backdropPath, size: "w1280") : nil
        let tmdbLogoPath = useArtwork
            ? preferredLogoPath(from: details.images?.logos)
            : nil
        let tmdbLogoURL = imageURL(tmdbLogoPath, size: "w500")

        let keepAddonArtwork = meta.isFromAddon == true
        let resolvedBackground = (keepAddonArtwork && nonEmpty(meta.backgroundUrl) != nil)
            ? meta.backgroundUrl
            : (tmdbBackgroundURL ?? meta.backgroundUrl)

        let resolvedCertification: String? = {
            if let cert = nonEmpty(meta.certification) {
                return cert
            }
            if resolved.mediaType == "tv" {
                return selectTvAgeRating(from: details.contentRatings?.results, language: preferredLanguage)
            } else {
                return selectMovieAgeRating(from: details.releaseDates?.results, language: preferredLanguage)
            }
        }()

        let resolvedType = (!meta.isSeries && resolved.mediaType == "tv") ? "series" : meta.type
        return NuvioMeta(
            id: meta.id,
            name: localizedTitle ?? meta.name,
            description: localizedOverview ?? meta.description,
            posterUrl: nonEmpty(meta.posterUrl) ?? tmdbPosterURL,
            backgroundUrl: resolvedBackground,
            logoUrl: tmdbLogoURL ?? meta.logoUrl,
            imdbId: meta.imdbId,
            tmdbId: meta.tmdbId ?? resolved.id,
            type: resolvedType,
            year: meta.year,
            genres: localizedGenres ?? meta.genres,
            rating: meta.rating,
            releaseInfo: meta.releaseInfo,
            runtime: meta.runtime,
            cast: meta.cast,
            director: meta.director,
            writer: meta.writer,
            certification: resolvedCertification,
            country: meta.country,
            language: nonEmpty(details.originalLanguage) ?? meta.language,
            released: meta.released,
            status: meta.status,
            videos: meta.videos,
            trailerYtIds: meta.trailerYtIds,
            externalRatings: meta.externalRatings,
            posterShape: meta.posterShape,
            isFromAddon: meta.isFromAddon,
            landscapePosterUrl: nonEmpty(meta.landscapePosterUrl)
        )
    }

    /// Applies the lightweight TMDB title/description/artwork enrichment to
    /// catalog cards while preserving their source order. The details screen
    /// remains the only place that requests credits and episode data.
    static func localizedMetadata(for metas: [NuvioMeta]) async -> [NuvioMeta] {
        if requestContext == nil {
            return await withRequestContext { await localizedMetadata(for: metas) }
        }
        guard isEnabled, useHomeEnrichment, useBasicInfo || useArtwork, !metas.isEmpty else { return metas }

        var localized = metas
        let chunkSize = 6
        for chunkStart in stride(from: 0, to: metas.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, metas.count)
            let chunkIndices = Array(chunkStart..<chunkEnd)
            let chunkResults = await withTaskGroup(of: (Int, NuvioMeta).self) { group in
                for index in chunkIndices {
                    let item = metas[index]
                    group.addTask {
                        (index, await localizedMetadata(for: item))
                    }
                }
                var results: [(Int, NuvioMeta)] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            for (index, item) in chunkResults {
                localized[index] = item
            }
        }
        return localized
    }

    /// All titles from a production company or network (movies + TV when applicable).
    static func discoverTitles(
        company: MetaCompany,
        page: Int = 1
    ) async -> [RelatedTitle] {
        if requestContext == nil {
            return await withRequestContext { await discoverTitles(company: company, page: page) }
        }
        let moduleEnabled = company.kind == .production ? useProductions : useNetworks
        guard moduleEnabled,
              isEnabled,
              let apiKey,
              let companyId = company.tmdbId,
              companyId > 0 else {
            return []
        }

        switch company.kind {
        case .production:
            async let movies = discover(
                endpoint: "discover/movie",
                companyParam: "with_companies",
                companyId: companyId,
                mediaType: "movie",
                page: page,
                apiKey: apiKey
            )
            async let shows = discover(
                endpoint: "discover/tv",
                companyParam: "with_companies",
                companyId: companyId,
                mediaType: "series",
                page: page,
                apiKey: apiKey
            )
            let combined = await movies + shows
            return dedupe(combined)
        case .network:
            return await discover(
                endpoint: "discover/tv",
                companyParam: "with_networks",
                companyId: companyId,
                mediaType: "series",
                page: page,
                apiKey: apiKey
            )
        }
    }

    /// Loads the network identity plus the same sorted rails used by Android TV.
    /// Networks are TV-only in TMDB, so this intentionally does not request movie
    /// results or make a separate request for each title.
    static func fetchNetworkBrowse(company: MetaCompany) async -> TmdbNetworkBrowseData? {
        if requestContext == nil {
            return await withRequestContext { await fetchNetworkBrowse(company: company) }
        }
        guard company.kind == .network,
              isEnabled,
              let apiKey,
              let networkId = company.tmdbId,
              networkId > 0 else {
            return nil
        }

        async let header = fetchNetworkHeader(networkId: networkId, fallback: company)
        async let popular = discover(
            endpoint: "discover/tv",
            companyParam: "with_networks",
            companyId: networkId,
            mediaType: "series",
            page: 1,
            apiKey: apiKey,
            sortBy: "popularity.desc"
        )
        async let topRated = discover(
            endpoint: "discover/tv",
            companyParam: "with_networks",
            companyId: networkId,
            mediaType: "series",
            page: 1,
            apiKey: apiKey,
            sortBy: "vote_average.desc",
            voteCountFloor: 100
        )
        async let recent = discover(
            endpoint: "discover/tv",
            companyParam: "with_networks",
            companyId: networkId,
            mediaType: "series",
            page: 1,
            apiKey: apiKey,
            sortBy: "first_air_date.desc"
        )

        let resolvedHeader = await header
        let popularTitles = await popular
        let topRatedTitles = await topRated
        let recentTitles = await recent
        let rails = [
            TmdbNetworkBrowseRail(id: "popular", title: "Series • Popular", items: popularTitles),
            TmdbNetworkBrowseRail(id: "top-rated", title: "Series • Top Rated", items: topRatedTitles),
            TmdbNetworkBrowseRail(id: "recent", title: "Series • Recent", items: recentTitles)
        ].filter { !$0.items.isEmpty }

        guard resolvedHeader != nil || !rails.isEmpty else { return nil }
        return TmdbNetworkBrowseData(
            name: resolvedHeader?.name ?? company.name,
            logoURL: resolvedHeader?.logoURL ?? company.logoURL,
            originCountry: resolvedHeader?.originCountry,
            headquarters: resolvedHeader?.headquarters,
            rails: rails
        )
    }

    static func discoverTitles(person: TmdbPersonMetadata) async -> [RelatedTitle] {
        if requestContext == nil {
            return await withRequestContext { await discoverTitles(person: person) }
        }
        guard useCredits,
              isEnabled,
              let apiKey,
              let personId = person.tmdbId,
              personId > 0 else {
            return []
        }

        var components = URLComponents(
            url: apiBase.appendingPathComponent("person/\(personId)/combined_credits"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: preferredLanguage)
        ]
        guard let url = components.url,
              let (data, response) = try? await data(for: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TmdbPersonCreditsResponse.self, from: data) else {
            return []
        }

        var seen = Set<String>()
        return (decoded.cast + decoded.crew)
            .filter {
                let mediaType = $0.mediaType?.lowercased()
                return mediaType == "movie" || mediaType == "tv"
            }
            .sorted { ($0.voteAverage ?? 0) > ($1.voteAverage ?? 0) }
            .compactMap { item in
                guard seen.insert("\(item.mediaType ?? ""):\(item.id)").inserted else { return nil }
                return mapDiscoverItemFast(
                    item,
                    defaultType: item.mediaType?.lowercased() == "tv" ? "series" : "movie"
                )
            }
    }

    // MARK: - Private

    private static func isSeries(_ type: String) -> Bool {
        NuvioMeta.isSeriesType(type)
    }

    private static func findByImdb(_ imdbId: String, mediaTypeHint: String? = nil) async -> (id: Int, mediaType: String)? {
        await findCache.resolve(for: imdbId) {
            guard let apiKey else { return nil }
            var components = URLComponents(
                url: apiBase.appendingPathComponent("find/\(imdbId)"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "external_source", value: "imdb_id"),
                URLQueryItem(name: "language", value: preferredLanguage)
            ]
            guard let url = components.url,
                  let (data, response) = try? await data(for: url),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let decoded = try? JSONDecoder().decode(TmdbFindResponse.self, from: data) else {
                return nil
            }
            if mediaTypeHint == "tv" {
                if let show = decoded.tvResults?.first {
                    return (show.id, "tv")
                }
                if let movie = decoded.movieResults?.first {
                    return (movie.id, "movie")
                }
            } else {
                if let movie = decoded.movieResults?.first {
                    return (movie.id, "movie")
                }
                if let show = decoded.tvResults?.first {
                    return (show.id, "tv")
                }
            }
            return nil
        }
    }

    private static func fetchDetailsResponse(tmdbId: Int, mediaType: String) async -> TmdbDetailsResponse? {
        guard let apiKey else { return nil }
        let cacheKey = "\(mediaType):\(tmdbId):\(preferredLanguage)"
        return await detailsCache.resolve(for: cacheKey) {
            var components = URLComponents(
                url: apiBase.appendingPathComponent("\(mediaType)/\(tmdbId)"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "language", value: preferredLanguage)
            ]
            guard let url = components.url,
                  let (data, response) = try? await data(for: url),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let decoded = try? JSONDecoder().decode(TmdbDetailsResponse.self, from: data) else {
                return nil
            }
            return decoded
        }
    }

    private static func fetchCompanies(tmdbId: Int, mediaType: String) async -> [MetaCompany] {
        guard let decoded = await fetchDetailsResponse(tmdbId: tmdbId, mediaType: mediaType) else {
            return []
        }

        var companies: [MetaCompany] = []
        if useProductions {
            for company in decoded.productionCompanies ?? [] {
                guard let name = company.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { continue }
                companies.append(
                    MetaCompany(
                        name: name,
                        logoURL: imageURL(company.logoPath, size: "w500"),
                        tmdbId: company.id,
                        kind: .production
                    )
                )
            }
        }
        if useNetworks {
            for network in decoded.networks ?? [] {
                guard let name = network.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { continue }
                companies.append(
                    MetaCompany(
                        name: name,
                        logoURL: imageURL(network.logoPath, size: "w500"),
                        tmdbId: network.id,
                        kind: .network
                    )
                )
            }
        }
        return companies
    }

    private static func fetchRecommendations(
        tmdbId: Int,
        mediaType: String,
        limit: Int
    ) async -> [RelatedTitle] {
        guard let apiKey else { return [] }
        var components = URLComponents(
            url: apiBase.appendingPathComponent("\(mediaType)/\(tmdbId)/recommendations"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: preferredLanguage)
        ]
        guard let url = components.url,
              let (data, response) = try? await data(for: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TmdbPagedResults.self, from: data) else {
            return []
        }

        let defaultType = mediaType == "tv" ? "series" : "movie"
        // Skip per-item IMDb lookup here for speed; CatalogRepository maps tmdb: → imdb on open.
        return decoded.results.prefix(limit).compactMap {
            mapDiscoverItemFast($0, defaultType: defaultType)
        }
    }

    private static func discover(
        endpoint: String,
        companyParam: String,
        companyId: Int,
        mediaType: String,
        page: Int,
        apiKey: String,
        sortBy: String = "popularity.desc",
        voteCountFloor: Int? = nil
    ) async -> [RelatedTitle] {
        var components = URLComponents(
            url: apiBase.appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: companyParam, value: String(companyId)),
            URLQueryItem(name: "sort_by", value: sortBy),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "language", value: preferredLanguage)
        ]
        if let voteCountFloor {
            components.queryItems?.append(URLQueryItem(name: "vote_count.gte", value: String(voteCountFloor)))
        }
        guard let url = components.url,
              let (data, response) = try? await data(for: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TmdbPagedResults.self, from: data) else {
            return []
        }

        return decoded.results.prefix(40).compactMap {
            mapDiscoverItemFast($0, defaultType: mediaType)
        }
    }

    private static func fetchNetworkHeader(
        networkId: Int,
        fallback: MetaCompany
    ) async -> TmdbNetworkHeader? {
        guard let apiKey else { return nil }
        var components = URLComponents(
            url: apiBase.appendingPathComponent("network/\(networkId)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: preferredLanguage)
        ]
        guard let url = components.url,
              let (data, response) = try? await data(for: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TmdbNetworkDetailsResponse.self, from: data) else {
            return TmdbNetworkHeader(
                name: fallback.name,
                logoURL: fallback.logoURL,
                originCountry: nil,
                headquarters: nil
            )
        }
        return TmdbNetworkHeader(
            name: nonEmpty(decoded.name) ?? fallback.name,
            logoURL: imageURL(decoded.logoPath, size: "w500") ?? fallback.logoURL,
            originCountry: nonEmpty(decoded.originCountry),
            headquarters: nonEmpty(decoded.headquarters)
        )
    }

    /// Fast mapping without per-item external_ids network calls.
    private static func mapDiscoverItemFast(
        _ item: TmdbListItem,
        defaultType: String
    ) -> RelatedTitle? {
        guard item.id > 0 else { return nil }
        let name = (item.title ?? item.name)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }

        let mediaType = (item.mediaType?.lowercased() == "tv") ? "tv"
            : (item.mediaType?.lowercased() == "movie") ? "movie"
            : (defaultType == "series" ? "tv" : "movie")
        let nuvioType = mediaType == "tv" ? "series" : "movie"
        let year = (item.releaseDate ?? item.firstAirDate).flatMap { String($0.prefix(4)) }
        let poster = imageURL(item.posterPath, size: "w500")
            ?? imageURL(item.backdropPath, size: "w780")

        return RelatedTitle(
            id: "tmdb:\(item.id)",
            type: nuvioType,
            name: name,
            posterURL: poster,
            year: year,
            rating: item.voteAverage.flatMap { $0 > 0 ? $0 : nil },
            overview: item.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
            backdropURL: imageURL(item.backdropPath, size: "w1280")
        )
    }

    private static func imageURL(_ path: String?, size: String) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        if path.lowercased().hasPrefix("http") { return path }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return imageBase + size + normalizedPath
    }

    private static func preferredLogoPath(from logos: [TmdbLogoDTO]?) -> String? {
        guard let logos, !logos.isEmpty else { return nil }
        let requestedCode = preferredLanguage
            .split(separator: "-")
            .first
            .map(String.init)
            ?? "en"

        return logos.first(where: {
            $0.iso6391?.caseInsensitiveCompare(requestedCode) == .orderedSame
        })?.filePath
            ?? logos.first(where: {
                $0.iso6391?.caseInsensitiveCompare("en") == .orderedSame
            })?.filePath
            ?? logos.first(where: { $0.iso6391 == nil })?.filePath
            ?? logos.first?.filePath
    }

    private static func fetchLocalizedDetails(
        tmdbId: Int,
        mediaType: String
    ) async -> TmdbLocalizedDetailsResponse? {
        guard let apiKey else { return nil }
        let cacheKey = "\(mediaType):\(tmdbId):\(preferredLanguage)"
        let cacheGeneration = await localizedDetailsCache.snapshotGeneration()
        if let cached = await localizedDetailsCache.value(for: cacheKey) {
            return cached
        }
        var components = URLComponents(
            url: apiBase.appendingPathComponent("\(mediaType)/\(tmdbId)"),
            resolvingAgainstBaseURL: false
        )!
        var appendItems = ["images", "translations"]
        if mediaType == "tv" {
            appendItems.append("content_ratings")
        } else {
            appendItems.append("release_dates")
        }
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: preferredLanguage),
            URLQueryItem(name: "append_to_response", value: appendItems.joined(separator: ",")),
            URLQueryItem(
                name: "include_image_language",
                value: "\(preferredLanguage),en,null"
            )
        ]
        guard let url = components.url,
              let (data, response) = try? await data(for: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(TmdbLocalizedDetailsResponse.self, from: data) else {
            return nil
        }
        await localizedDetailsCache.insert(decoded, for: cacheKey, ifGeneration: cacheGeneration)
        return decoded
    }

    private static func preferredRegions(for language: String) -> [String] {
        var regions: [String] = []
        let parts = language.split(separator: "-")
        if parts.count > 1, parts[1].count == 2 {
            regions.append(parts[1].uppercased())
        }
        let currentRegion = Locale.current.region?.identifier.uppercased()
        if let currentRegion, currentRegion.count == 2, !regions.contains(currentRegion) {
            regions.append(currentRegion)
        }
        if !regions.contains("US") {
            regions.append("US")
        }
        if !regions.contains("GB") {
            regions.append("GB")
        }
        return regions
    }

    private static func selectTvAgeRating(
        from contentRatings: [TmdbTvContentRatingDTO]?,
        language: String
    ) -> String? {
        guard let contentRatings, !contentRatings.isEmpty else { return nil }
        let regions = preferredRegions(for: language)
        let byRegion = Dictionary(
            contentRatings.compactMap { item -> (String, String)? in
                guard let code = item.iso31661?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                      let rating = item.rating?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rating.isEmpty else { return nil }
                return (code, rating)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for region in regions {
            if let rating = byRegion[region] {
                return rating
            }
        }
        return contentRatings
            .compactMap { $0.rating?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func selectMovieAgeRating(
        from releaseDates: [TmdbMovieReleaseDateCountryDTO]?,
        language: String
    ) -> String? {
        guard let releaseDates, !releaseDates.isEmpty else { return nil }
        let regions = preferredRegions(for: language)
        let byRegion = Dictionary(
            releaseDates.compactMap { item -> (String, TmdbMovieReleaseDateCountryDTO)? in
                guard let code = item.iso31661?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else { return nil }
                return (code, item)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for region in regions {
            if let country = byRegion[region] {
                let rating = country.releaseDates?
                    .compactMap { $0.certification?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let rating, !rating.isEmpty {
                    return rating
                }
            }
        }
        return releaseDates
            .flatMap { $0.releaseDates ?? [] }
            .compactMap { $0.certification?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    static func fetchCertification(for meta: NuvioMeta) async -> String? {
        if requestContext == nil {
            return await withRequestContext { await fetchCertification(for: meta) }
        }
        if let cert = nonEmpty(meta.certification) {
            return cert
        }
        guard let resolved = await resolveTmdbId(for: meta) else { return nil }
        let cacheKey = "\(resolved.mediaType):\(resolved.id):\(preferredLanguage)"
        if let cached = await localizedDetailsCache.value(for: cacheKey) {
            let rating = (resolved.mediaType == "tv")
                ? selectTvAgeRating(from: cached.contentRatings?.results, language: preferredLanguage)
                : selectMovieAgeRating(from: cached.releaseDates?.results, language: preferredLanguage)
            if let rating = nonEmpty(rating) {
                return rating
            }
        }
        guard let apiKey else { return nil }
        let endpoint = (resolved.mediaType == "tv")
            ? "tv/\(resolved.id)/content_ratings"
            : "movie/\(resolved.id)/release_dates"
        var components = URLComponents(
            url: apiBase.appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey)
        ]
        guard let url = components.url,
              let (data, response) = try? await data(for: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        if resolved.mediaType == "tv" {
            let decoded = try? JSONDecoder().decode(TmdbTvContentRatingsContainer.self, from: data)
            return selectTvAgeRating(from: decoded?.results, language: preferredLanguage)
        } else {
            let decoded = try? JSONDecoder().decode(TmdbMovieReleaseDatesContainer.self, from: data)
            return selectMovieAgeRating(from: decoded?.results, language: preferredLanguage)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func tmdbBoolean(_ key: String, defaultValue: Bool = true) -> Bool {
        if let value = requestContext?.flags[key] { return value }
        guard let value = ProfileSettings.current.object(forKey: key) else {
            // All Android TV TMDB modules default to enabled. Keep that same
            // behavior for existing tvOS profiles that predate these keys.
            return defaultValue
        }
        return (value as? Bool) ?? defaultValue
    }

    private static func dedupe(_ items: [RelatedTitle]) -> [RelatedTitle] {
        var seen = Set<String>()
        var result: [RelatedTitle] = []
        for item in items {
            guard seen.insert(item.id).inserted else { continue }
            result.append(item)
        }
        return result
    }
}

// MARK: - DTOs

private struct TmdbFindResponse: Decodable {
    let movieResults: [TmdbIdOnly]?
    let tvResults: [TmdbIdOnly]?

    enum CodingKeys: String, CodingKey {
        case movieResults = "movie_results"
        case tvResults = "tv_results"
    }
}

private struct TmdbIdOnly: Decodable {
    let id: Int
}

private struct TmdbDetailsResponse: Decodable {
    let productionCompanies: [TmdbCompanyDTO]?
    let networks: [TmdbCompanyDTO]?
    let createdBy: [TmdbCreatorDTO]?

    enum CodingKeys: String, CodingKey {
        case productionCompanies = "production_companies"
        case networks
        case createdBy = "created_by"
    }
}

private struct TmdbTvShowDetailsResponse: Decodable {
    let seasons: [TmdbSeasonOverviewDTO]?
}

private struct TmdbSeasonOverviewDTO: Decodable {
    let id: Int?
    let seasonNumber: Int?
    let episodeCount: Int?
    let airDate: String?

    enum CodingKeys: String, CodingKey {
        case id
        case seasonNumber = "season_number"
        case episodeCount = "episode_count"
        case airDate = "air_date"
    }
}

private struct TmdbSeasonDetailsResponse: Decodable {
    let id: Int?
    let seasonNumber: Int?
    let posterPath: String?
    let episodes: [TmdbEpisodeDTO]?

    enum CodingKeys: String, CodingKey {
        case id
        case seasonNumber = "season_number"
        case posterPath = "poster_path"
        case episodes
    }
}

private struct TmdbEpisodeDTO: Decodable {
    let id: Int?
    let name: String?
    let overview: String?
    let airDate: String?
    let episodeNumber: Int?
    let seasonNumber: Int?
    let stillPath: String?
    let voteAverage: Double?
    let translations: TmdbEpisodeTranslationsContainer?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, translations
        case airDate = "air_date"
        case episodeNumber = "episode_number"
        case seasonNumber = "season_number"
        case stillPath = "still_path"
        case voteAverage = "vote_average"
    }
}

private struct TmdbEpisodeTranslationsContainer: Decodable {
    let translations: [TmdbEpisodeTranslationItemDTO]?
}

private struct TmdbEpisodeTranslationItemDTO: Decodable {
    let iso6391: String?
    let iso31661: String?
    let data: TmdbEpisodeTranslationDataDTO?

    enum CodingKeys: String, CodingKey {
        case iso6391 = "iso_639_1"
        case iso31661 = "iso_3166_1"
        case data
    }
}

private struct TmdbEpisodeTranslationDataDTO: Decodable {
    let name: String?
    let overview: String?
}

private struct TmdbNetworkDetailsResponse: Decodable {
    let name: String?
    let headquarters: String?
    let originCountry: String?
    let logoPath: String?

    enum CodingKeys: String, CodingKey {
        case name, headquarters
        case originCountry = "origin_country"
        case logoPath = "logo_path"
    }
}

private struct TmdbNetworkHeader {
    let name: String
    let logoURL: String?
    let originCountry: String?
    let headquarters: String?
}

private struct TmdbCreditsResponse: Decodable {
    let cast: [TmdbCastDTO]?
    let crew: [TmdbCrewDTO]?
}

private struct TmdbCastDTO: Decodable {
    let id: Int?
    let name: String?
    let character: String?
    let profilePath: String?
    let order: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, character, order
        case profilePath = "profile_path"
    }
}

private struct TmdbCrewDTO: Decodable {
    let id: Int?
    let name: String?
    let job: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name, job
        case profilePath = "profile_path"
    }
}

private struct TmdbCreatorDTO: Decodable {
    let id: Int?
    let name: String?
    let profilePath: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case profilePath = "profile_path"
    }
}

/// A bounded working set of reusable responses. Accesses keep recently used
/// entries warm; eviction only discards data that can be fetched again.
/// The limit counts responses, not bytes or an exact memory budget.
struct TmdbResponseCache<Value> {
    private let capacity: Int
    private var values: [String: Value] = [:]
    private var recency: [String] = []

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    var count: Int { values.count }

    mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        recency.removeAll { $0 == key }
        recency.append(key)
        return value
    }

    mutating func insert(_ value: Value, for key: String) {
        guard capacity > 0 else { return }
        recency.removeAll { $0 == key }
        values[key] = value
        recency.append(key)
        if recency.count > capacity {
            values.removeValue(forKey: recency.removeFirst())
        }
    }

    mutating func removeAll() {
        values.removeAll()
        recency.removeAll()
    }
}

private actor TmdbDetailsCache {
    private var values = TmdbResponseCache<TmdbDetailsResponse>(capacity: 256)
    private var inFlight: [String: Task<TmdbDetailsResponse?, Never>] = [:]

    func resolve(
        for key: String,
        fetcher: @Sendable @escaping () async -> TmdbDetailsResponse?
    ) async -> TmdbDetailsResponse? {
        if let cached = values.value(for: key) {
            return cached
        }
        if let existingTask = inFlight[key] {
            return await existingTask.value
        }
        let task = Task {
            await fetcher()
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        if let result {
            values.insert(result, for: key)
        }
        return result
    }

    func clear() {
        values.removeAll()
        inFlight.removeAll()
    }
}

private actor TmdbFindCache {
    private var values = TmdbResponseCache<(id: Int, mediaType: String)>(capacity: 1024)
    private var inFlight: [String: Task<(id: Int, mediaType: String)?, Never>] = [:]

    func value(for key: String) -> (id: Int, mediaType: String)? {
        values.value(for: key)
    }

    func insert(_ value: (id: Int, mediaType: String), for key: String) {
        values.insert(value, for: key)
    }

    func resolve(
        for key: String,
        fetcher: @Sendable @escaping () async -> (id: Int, mediaType: String)?
    ) async -> (id: Int, mediaType: String)? {
        if let cached = values.value(for: key) {
            return cached
        }
        if let existingTask = inFlight[key] {
            return await existingTask.value
        }
        let task = Task {
            await fetcher()
        }
        inFlight[key] = task
        let result = await task.value
        inFlight.removeValue(forKey: key)
        if let result {
            values.insert(result, for: key)
        }
        return result
    }

    func clear() {
        values.removeAll()
        inFlight.removeAll()
    }
}

private actor TmdbLocalizedDetailsCache {
    private var values = TmdbResponseCache<TmdbLocalizedDetailsResponse>(capacity: 256)
    private var generation: UInt64 = 0

    func snapshotGeneration() -> UInt64 {
        generation
    }

    func value(for key: String) -> TmdbLocalizedDetailsResponse? {
        values.value(for: key)
    }

    func insert(
        _ value: TmdbLocalizedDetailsResponse,
        for key: String,
        ifGeneration expectedGeneration: UInt64
    ) {
        guard generation == expectedGeneration else { return }
        values.insert(value, for: key)
    }

    func clear() {
        generation &+= 1
        values.removeAll()
    }
}

private struct TmdbLocalizedDetailsResponse: Decodable {
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let originalLanguage: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let images: TmdbImageCollection?
    let translations: TmdbTranslationsContainer?
    let genres: [TmdbGenreDTO]?
    let contentRatings: TmdbTvContentRatingsContainer?
    let releaseDates: TmdbMovieReleaseDatesContainer?

    enum CodingKeys: String, CodingKey {
        case title, name, overview, genres, translations
        case originalTitle = "original_title"
        case originalName = "original_name"
        case originalLanguage = "original_language"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case images
        case contentRatings = "content_ratings"
        case releaseDates = "release_dates"
    }
}

private struct TmdbTvContentRatingsContainer: Decodable {
    let results: [TmdbTvContentRatingDTO]?
}

private struct TmdbTvContentRatingDTO: Decodable {
    let iso31661: String?
    let rating: String?

    enum CodingKeys: String, CodingKey {
        case iso31661 = "iso_3166_1"
        case rating
    }
}

private struct TmdbMovieReleaseDatesContainer: Decodable {
    let results: [TmdbMovieReleaseDateCountryDTO]?
}

private struct TmdbMovieReleaseDateCountryDTO: Decodable {
    let iso31661: String?
    let releaseDates: [TmdbMovieReleaseDateItemDTO]?

    enum CodingKeys: String, CodingKey {
        case iso31661 = "iso_3166_1"
        case releaseDates = "release_dates"
    }
}

private struct TmdbMovieReleaseDateItemDTO: Decodable {
    let certification: String?
}

private struct TmdbTranslationsContainer: Decodable {
    let translations: [TmdbTranslationItemDTO]?
}

private struct TmdbTranslationItemDTO: Decodable {
    let iso6391: String?
    let iso31661: String?
    let data: TmdbTranslationDataDTO?

    enum CodingKeys: String, CodingKey {
        case iso6391 = "iso_639_1"
        case iso31661 = "iso_3166_1"
        case data
    }
}

private struct TmdbTranslationDataDTO: Decodable {
    let title: String?
    let name: String?
    let overview: String?
}

private struct TmdbImageCollection: Decodable {
    let logos: [TmdbLogoDTO]?
}

private struct TmdbLogoDTO: Decodable {
    let filePath: String?
    let iso6391: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case iso6391 = "iso_639_1"
    }
}

private struct TmdbGenreDTO: Decodable {
    let name: String?
}

private struct TmdbCompanyDTO: Decodable {
    let id: Int?
    let name: String?
    let logoPath: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case logoPath = "logo_path"
    }
}

private struct TmdbPagedResults: Decodable {
    let results: [TmdbListItem]
}

private struct TmdbPersonCreditsResponse: Decodable {
    let cast: [TmdbListItem]
    let crew: [TmdbListItem]
}

private struct TmdbListItem: Decodable {
    let id: Int
    let title: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let mediaType: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case mediaType = "media_type"
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}

/// MDBList rating enrichment ported from the Android TV client. Each provider
/// is requested independently so one unavailable rating source does not hide
/// the others.
enum MdbListDetailsService {
    static let providerIMDb = "imdb"
    static let providerTMDB = "tmdb"
    static let providerTomatoes = "tomatoes"
    static let providerMetacritic = "metacritic"
    static let providerTrakt = "trakt"
    static let providerLetterboxd = "letterboxd"
    static let providerAudience = "audience"
    static let providerMyAnimeList = "myanimelist"
    static let providerTVDB = "tvdb"

    static let providerPriorityOrder = [
        providerIMDb,
        providerTMDB,
        providerTomatoes,
        providerMetacritic,
        providerTrakt,
        providerLetterboxd,
        providerAudience,
        providerMyAnimeList,
        providerTVDB
    ]

    static func apiProvider(for provider: String) -> String {
        switch provider {
        case providerMyAnimeList:
            return "mal"
        default:
            return provider
        }
    }

    private static let providerSettings: [String: String] = [
        providerIMDb: SettingsKey.mdbListUseImdb,
        providerTMDB: SettingsKey.mdbListUseTmdb,
        providerTomatoes: SettingsKey.mdbListUseTomatoes,
        providerMetacritic: SettingsKey.mdbListUseMetacritic,
        providerTrakt: SettingsKey.mdbListUseTrakt,
        providerLetterboxd: SettingsKey.mdbListUseLetterboxd,
        providerAudience: SettingsKey.mdbListUseAudience,
        providerMyAnimeList: SettingsKey.mdbListUseMyAnimeList,
        providerTVDB: SettingsKey.mdbListUseTvdb
    ]

    /// The title response: every provider's rating in one list.
    private struct TitleResponse: Decodable {
        let ratings: [TitleRating]?
        let error: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ratings = try? container.decodeIfPresent([TitleRating].self, forKey: .ratings)
            error = try? container.decodeIfPresent(String.self, forKey: .error)
        }

        private enum CodingKeys: String, CodingKey { case ratings, error }
    }

    private struct TitleRating: Decodable {
        let source: String?
        let value: Double?
        let score: Double?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            source = try? container.decodeIfPresent(String.self, forKey: .source)
            value = try? container.decodeIfPresent(Double.self, forKey: .value)
            score = try? container.decodeIfPresent(Double.self, forKey: .score)
        }

        private enum CodingKeys: String, CodingKey { case source, value, score }
    }

    /// Our provider for a source name in MDBList's title response.
    static func provider(forSource source: String) -> String? {
        switch source.lowercased() {
        case "imdb": return providerIMDb
        case "tmdb": return providerTMDB
        case "tomatoes": return providerTomatoes
        case "popcorn", "audience", "tomatoesaudience": return providerAudience
        case "metacritic": return providerMetacritic
        case "trakt": return providerTrakt
        case "letterboxd": return providerLetterboxd
        case "myanimelist", "mal": return providerMyAnimeList
        case "tvdb": return providerTVDB
        default: return nil
        }
    }

    /// The scale each provider's badge expects: IMDb and MAL out of 10,
    /// Letterboxd out of 5, the rest out of 100 (as NuvioTV on Android).
    static func maximumValue(for provider: String) -> Double {
        switch provider {
        case providerIMDb, providerMyAnimeList: return 10
        case providerLetterboxd: return 5
        default: return 100
        }
    }

    /// What one title request came back with.
    enum TitleResult: Equatable, Sendable {
        /// Every rating MDBList has for the title, by provider.
        case ratings([String: Double])
        /// MDBList doesn't know the title.
        case notFound
        /// The API key's daily request limit is used up.
        case limitReached
        /// A network or server error: try again later.
        case failed
    }

    /// Reads a title response. Unknown sources, missing values and values
    /// off their provider's scale are left out; zero means "no rating".
    static func titleResult(status: Int, data: Data) -> TitleResult {
        let response = try? JSONDecoder().decode(TitleResponse.self, from: data)
        let error = response?.error?.lowercased()
        if status == 429 || error?.contains("limit") == true { return .limitReached }
        guard status == 200 else {
            // Only an error body is searched for the limit message; a title's
            // own text (a description) never is.
            let body = String(data: data.prefix(512), encoding: .utf8)?.lowercased() ?? ""
            if body.contains("limit") { return .limitReached }
            return status == 404 ? .notFound : .failed
        }
        guard let response else { return .failed }
        if let error { return error.contains("not found") ? .notFound : .failed }
        var values: [String: Double] = [:]
        for rating in response.ratings ?? [] {
            guard let source = rating.source, let mapped = Self.provider(forSource: source),
                  values[mapped] == nil else { continue }
            var candidate = rating.value
            if mapped == providerLetterboxd, let score = rating.score { candidate = score / 20 }
            guard let value = candidate, value.isFinite, value > 0,
                  value <= maximumValue(for: mapped) else { continue }
            values[mapped] = value
        }
        return .ratings(values)
    }

    /// One request for every rating of a title (the per-provider endpoint
    /// cost up to nine requests per title against the daily limit).
    static func requestTitleRatings(imdbID: String, mediaType: String, apiKey: String) async -> TitleResult {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.mdblist.com"
        components.path = "/imdb/\(mediaType)/\(imdbID)"
        components.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
        guard let url = components.url else { return .failed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return titleResult(status: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch {
            return .failed
        }
    }

    static func fetchRatings(for meta: NuvioMeta) async -> [NuvioExternalRating] {
        let defaults = ProfileSettings.current
        guard defaults.bool(forKey: SettingsKey.mdbListEnabled),
              let apiKey = defaults.string(forKey: SettingsKey.mdbListApiKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            return []
        }

        let providers = providerPriorityOrder.filter { provider in
            guard let key = providerSettings[provider] else { return false }
            return defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
        }
        guard !providers.isEmpty, let imdbID = extractImdbID(from: meta) else {
            return []
        }

        let mediaType = meta.isSeries ? "show" : "movie"
        // Rating badges are optional enrichment: a failed request leaves the
        // rest of the page usable and simply shows fewer badges.
        guard let all = await MdbListRatingsStore.shared.ratings(imdbID: imdbID, mediaType: mediaType, apiKey: apiKey) else {
            return []
        }
        return providerPriorityOrder.compactMap { provider in
            guard providers.contains(provider), let value = all[provider] else { return nil }
            return NuvioExternalRating(source: provider, value: value)
        }
    }

    private static func extractImdbID(from meta: NuvioMeta) -> String? {
        let candidates = [meta.imdbId, meta.id].compactMap { $0 }
        for candidate in candidates {
            guard let range = candidate.range(of: #"tt\d+"#, options: .regularExpression) else { continue }
            return String(candidate[range])
        }
        return nil
    }
}

private let mdbListLog = Logger(subsystem: "com.pyksel.nuviotvos", category: "mdblist")

/// MDBList ratings by title, shared by the hero and Details:
/// - one request per title for every provider;
/// - kept on disk for a day (a title MDBList doesn't know for six hours),
///   so browsing the same rows again costs nothing;
/// - one request at a time per title;
/// - after the API reports its daily limit, no requests for an hour; older
///   ratings still on disk are shown meanwhile.
actor MdbListRatingsStore {
    static let shared = MdbListRatingsStore()

    static let lifetime: TimeInterval = 24 * 60 * 60
    static let notFoundLifetime: TimeInterval = 6 * 60 * 60
    static let limitPause: TimeInterval = 60 * 60
    static let maxEntries = 4_000

    struct Entry: Codable, Equatable, Sendable {
        let storedAt: Date
        let ratings: [String: Double]
    }

    private let fileURL: URL?
    private var entries: [String: Entry]?
    private var inflight: [String: Task<MdbListDetailsService.TitleResult, Never>] = [:]
    private var pausedUntil: Date?
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = MdbListRatingsStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    static var defaultFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("mdblist-ratings-v1.json")
    }

    /// Whether a stored entry is still fresh enough to skip the request.
    static func isFresh(_ entry: Entry, now: Date) -> Bool {
        let age = now.timeIntervalSince(entry.storedAt)
        return age >= 0 && age < (entry.ratings.isEmpty ? notFoundLifetime : lifetime)
    }

    /// Every rating MDBList has for the title, by provider, or nil when they
    /// can't be had right now.
    func ratings(imdbID: String, mediaType: String, apiKey: String,
                 request: (@Sendable () async -> MdbListDetailsService.TitleResult)? = nil) async -> [String: Double]? {
        let key = "\(mediaType):\(imdbID)"
        loadIfNeeded()
        let now = Date()
        let stored = entries?[key]
        if let stored, Self.isFresh(stored, now: now) { return stored.ratings }
        if let pausedUntil, pausedUntil > now { return stored?.ratings }

        let task: Task<MdbListDetailsService.TitleResult, Never>
        if let running = inflight[key] {
            task = running
        } else {
            let fetch: @Sendable () async -> MdbListDetailsService.TitleResult = request ?? {
                await MdbListDetailsService.requestTitleRatings(imdbID: imdbID, mediaType: mediaType, apiKey: apiKey)
            }
            task = Task { await fetch() }
            inflight[key] = task
        }
        let result = await task.value
        if inflight[key] == task { inflight[key] = nil }

        switch result {
        case .ratings(let ratings):
            store(Entry(storedAt: Date(), ratings: ratings), for: key)
            return ratings
        case .notFound:
            store(Entry(storedAt: Date(), ratings: [:]), for: key)
            return [:]
        case .limitReached:
            if pausedUntil.map({ $0 <= Date() }) ?? true {
                mdbListLog.notice("MDBList daily request limit reached; ratings paused for an hour")
            }
            pausedUntil = Date().addingTimeInterval(Self.limitPause)
            return stored?.ratings
        case .failed:
            return stored?.ratings
        }
    }

    /// Stored ratings, for tests.
    func entry(for imdbID: String, mediaType: String) -> Entry? {
        loadIfNeeded()
        return entries?["\(mediaType):\(imdbID)"]
    }

    // MARK: - Disk

    private func loadIfNeeded() {
        guard entries == nil else { return }
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            entries = [:]
            return
        }
        let now = Date()
        entries = decoded.filter { now.timeIntervalSince($0.value.storedAt) < Self.lifetime }
    }

    private func store(_ entry: Entry, for key: String) {
        loadIfNeeded()
        entries?[key] = entry
        if let count = entries?.count, count > Self.maxEntries, let current = entries {
            let keep = current.sorted { $0.value.storedAt > $1.value.storedAt }.prefix(Self.maxEntries)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        scheduleSave()
    }

    private func scheduleSave() {
        guard fileURL != nil, saveTask == nil else { return }
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.save()
        }
    }

    /// Writes pending changes now instead of two seconds later.
    func flushToDisk() {
        saveTask?.cancel()
        save()
    }

    private func save() {
        saveTask = nil
        guard let fileURL, let entries, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

private struct TmdbVideosResponse: Decodable {
    let results: [TmdbVideoResult]
}

private struct TmdbVideoResult: Decodable {
    let key: String?
    let site: String?
    let type: String?
    let official: Bool?
    let publishedAt: String?

    enum CodingKeys: String, CodingKey {
        case key, site, type, official
        case publishedAt = "published_at"
    }

    var rank: Int {
        var value = 0
        if type?.caseInsensitiveCompare("Trailer") == .orderedSame { value += 100 }
        if official == true { value += 50 }
        if type?.caseInsensitiveCompare("Teaser") == .orderedSame { value += 25 }
        return value
    }
}

