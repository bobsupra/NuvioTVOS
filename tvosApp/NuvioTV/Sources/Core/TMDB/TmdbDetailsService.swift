import Foundation

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
            released: meta.released,
            status: meta.status,
            videos: meta.videos,
            trailerYtIds: meta.trailerYtIds,
            externalRatings: meta.externalRatings
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

    private static var apiKey: String? {
        let key = ProfileSettings.current.string(forKey: SettingsKey.tmdbApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    private static var isEnabled: Bool {
        (ProfileSettings.current.object(forKey: SettingsKey.tmdbEnabled) as? Bool) ?? false
    }

    static var preferredLanguage: String {
        normalizedLanguage(
            ProfileSettings.current.string(forKey: SettingsKey.tmdbLanguage)
        )
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

    // MARK: - Public

    static func resolveTmdbId(for meta: NuvioMeta) async -> (id: Int, mediaType: String)? {
        guard isEnabled, apiKey != nil else { return nil }
        let mediaType = isSeries(meta.type) ? "tv" : "movie"
        let imdb = meta.imdbId ?? (meta.id.hasPrefix("tt") ? meta.id.split(separator: ":").first.map(String.init) : nil)

        // 1. If an IMDb id is available, resolve via TMDB's authoritative /find/ endpoint first
        // to guarantee the correct TMDB id and avoid stale/incorrect moviedb_id values from Cinemeta.
        if let imdb, imdb.hasPrefix("tt"), let resolved = await findByImdb(imdb) {
            return resolved
        }

        // 2. Fallback to meta.tmdbId or tmdb: prefix id if available
        let tmdbId = meta.tmdbId ?? (meta.id.hasPrefix("tmdb:") ? Int(meta.id.dropFirst(5)) : nil)
        if let tmdbId, tmdbId > 0 {
            return (tmdbId, mediaType)
        }

        return nil
    }

    static func fetchCompanies(for meta: NuvioMeta) async -> [MetaCompany] {
        guard useProductions || useNetworks else { return [] }
        guard let resolved = await resolveTmdbId(for: meta) else { return [] }
        return await fetchCompanies(tmdbId: resolved.id, mediaType: resolved.mediaType)
    }

    static func fetchTrailerYouTubeId(for meta: NuvioMeta) async -> String? {
        guard useTrailers,
              apiKey != nil,
              let resolved = await resolveTmdbId(for: meta) else {
            return nil
        }
        return await fetchTrailerYouTubeId(tmdbId: resolved.id, mediaType: resolved.mediaType)
    }

    static func fetchTrailerYouTubeId(tmdbId: Int, mediaType: String) async -> String? {
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
              let (data, response) = try? await URLSession.shared.data(from: url),
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
              let (data, response) = try? await URLSession.shared.data(from: url),
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
        guard resolved.mediaType == "tv", let apiKey else { return [] }
        var components = URLComponents(
            url: apiBase.appendingPathComponent("tv/\(resolved.id)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: preferredLanguage)
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TmdbDetailsResponse.self, from: data) else {
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
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let showDetails = try? JSONDecoder().decode(TmdbTvShowDetailsResponse.self, from: data) else {
            return nil
        }

        let seasonNumbers = (showDetails.seasons ?? []).compactMap { season -> Int? in
            guard let num = season.seasonNumber, num >= 0 else { return nil }
            return num
        }

        return await withTaskGroup(of: [NuvioVideo].self, returning: [NuvioVideo]?.self) { group in
            for seasonNum in seasonNumbers {
                group.addTask {
                    await fetchSeasonEpisodes(
                        parentId: meta.id,
                        tmdbId: resolved.id,
                        seasonNumber: seasonNum,
                        apiKey: apiKey
                    )
                }
            }
            var allVideos: [NuvioVideo] = []
            for await seasonVideos in group {
                allVideos.append(contentsOf: seasonVideos)
            }
            return allVideos.isEmpty ? nil : allVideos
        }
    }

    private static func fetchSeasonEpisodes(
        parentId: String,
        tmdbId: Int,
        seasonNumber: Int,
        apiKey: String
    ) async -> [NuvioVideo] {
        var components = URLComponents(
            url: apiBase.appendingPathComponent("tv/\(tmdbId)/season/\(seasonNumber)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: preferredLanguage)
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
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
            return NuvioVideo(
                id: "\(baseParentId):\(epSeason):\(epNum)",
                title: nonEmpty(ep.name) ?? "Episode \(epNum)",
                season: epSeason,
                episode: epNum,
                thumbnail: imageURL(ep.stillPath, size: "w500"),
                overview: nonEmpty(ep.overview),
                released: nonEmpty(ep.airDate),
                rating: ratingStr
            )
        }
    }

    /// Applies the selected TMDB language to user-facing text while retaining
    /// Cinemeta/add-on values wherever TMDB has no translation.
    static func localizedMetadata(for meta: NuvioMeta) async -> NuvioMeta {
        guard useBasicInfo || useArtwork else { return meta }
        guard let resolved = await resolveTmdbId(for: meta),
              let details = await fetchLocalizedDetails(
                tmdbId: resolved.id,
                mediaType: resolved.mediaType
              ) else {
            return meta
        }

        let rawTitle = nonEmpty(details.title ?? details.name)
        let originalTitle = nonEmpty(details.originalTitle ?? details.originalName)
        let requestedCode = preferredLanguage.split(separator: "-").first.map(String.init) ?? "en"
        let localizedTitle: String?
        if requestedCode != "en",
           rawTitle == originalTitle,
           let originalLanguage = nonEmpty(details.originalLanguage),
           originalLanguage.caseInsensitiveCompare(requestedCode) != .orderedSame {
            localizedTitle = nil
        } else {
            localizedTitle = rawTitle
        }

        let localizedGenres = details.genres?
            .compactMap { nonEmpty($0.name) }
            .nilIfEmpty
        let tmdbPosterURL = useArtwork ? imageURL(details.posterPath, size: "w500") : nil
        let tmdbBackgroundURL = useArtwork ? imageURL(details.backdropPath, size: "w1280") : nil
        let tmdbLogoPath = useArtwork
            ? preferredLogoPath(from: details.images?.logos)
            : nil
        let tmdbLogoURL = imageURL(tmdbLogoPath, size: "w500")

        return NuvioMeta(
            id: meta.id,
            name: localizedTitle ?? meta.name,
            description: nonEmpty(details.overview) ?? meta.description,
            posterUrl: tmdbPosterURL ?? meta.posterUrl,
            backgroundUrl: tmdbBackgroundURL ?? meta.backgroundUrl,
            logoUrl: tmdbLogoURL ?? meta.logoUrl,
            imdbId: meta.imdbId,
            tmdbId: meta.tmdbId ?? resolved.id,
            type: meta.type,
            year: meta.year,
            genres: localizedGenres ?? meta.genres,
            rating: meta.rating,
            releaseInfo: meta.releaseInfo,
            runtime: meta.runtime,
            cast: meta.cast,
            director: meta.director,
            writer: meta.writer,
            certification: meta.certification,
            country: meta.country,
            released: meta.released,
            status: meta.status,
            videos: meta.videos,
            trailerYtIds: meta.trailerYtIds
        )
    }

    /// Applies the lightweight TMDB title/description/artwork enrichment to
    /// catalog cards while preserving their source order. The details screen
    /// remains the only place that requests credits and episode data.
    static func localizedMetadata(for metas: [NuvioMeta]) async -> [NuvioMeta] {
        guard isEnabled, useBasicInfo || useArtwork, !metas.isEmpty else { return metas }

        return await withTaskGroup(of: (Int, NuvioMeta).self, returning: [NuvioMeta].self) { group in
            for (index, meta) in metas.enumerated() {
                group.addTask {
                    (index, await localizedMetadata(for: meta))
                }
            }

            var localized = metas
            for await (index, meta) in group {
                localized[index] = meta
            }
            return localized
        }
    }

    /// All titles from a production company or network (movies + TV when applicable).
    static func discoverTitles(
        company: MetaCompany,
        page: Int = 1
    ) async -> [RelatedTitle] {
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
              let (data, response) = try? await URLSession.shared.data(from: url),
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
        ["series", "show", "tv", "tvshow"].contains(type.lowercased())
    }

    private static func findByImdb(_ imdbId: String) async -> (id: Int, mediaType: String)? {
        if let cached = await findCache.value(for: imdbId) {
            return cached
        }
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
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TmdbFindResponse.self, from: data) else {
            return nil
        }
        if let movie = decoded.movieResults?.first {
            let result = (movie.id, "movie")
            await findCache.insert(result, for: imdbId)
            return result
        }
        if let show = decoded.tvResults?.first {
            let result = (show.id, "tv")
            await findCache.insert(result, for: imdbId)
            return result
        }
        return nil
    }

    private static func fetchCompanies(tmdbId: Int, mediaType: String) async -> [MetaCompany] {
        guard let apiKey else { return [] }
        var components = URLComponents(
            url: apiBase.appendingPathComponent("\(mediaType)/\(tmdbId)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: preferredLanguage)
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TmdbDetailsResponse.self, from: data) else {
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
              let (data, response) = try? await URLSession.shared.data(from: url),
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
              let (data, response) = try? await URLSession.shared.data(from: url),
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
              let (data, response) = try? await URLSession.shared.data(from: url),
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
        if let cached = await localizedDetailsCache.value(for: cacheKey) {
            return cached
        }
        var components = URLComponents(
            url: apiBase.appendingPathComponent("\(mediaType)/\(tmdbId)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "language", value: preferredLanguage),
            URLQueryItem(name: "append_to_response", value: "images"),
            URLQueryItem(
                name: "include_image_language",
                value: "\(preferredLanguage),en,null"
            )
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(TmdbLocalizedDetailsResponse.self, from: data) else {
            return nil
        }
        await localizedDetailsCache.insert(decoded, for: cacheKey)
        return decoded
    }

    private static func normalizedLanguage(_ value: String?) -> String {
        let raw = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-") ?? ""
        guard !raw.isEmpty else { return "en" }
        let parts = raw.split(separator: "-", omittingEmptySubsequences: true)
        guard let language = parts.first else { return "en" }
        if raw.caseInsensitiveCompare("es-419") == .orderedSame { return "es-MX" }
        guard parts.count > 1 else { return language.lowercased() }
        return "\(language.lowercased())-\(parts[1].uppercased())"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func tmdbBoolean(_ key: String) -> Bool {
        guard let value = ProfileSettings.current.object(forKey: key) else {
            // All Android TV TMDB modules default to enabled. Keep that same
            // behavior for existing tvOS profiles that predate these keys.
            return true
        }
        return (value as? Bool) ?? true
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

    enum CodingKeys: String, CodingKey {
        case id, name, overview
        case airDate = "air_date"
        case episodeNumber = "episode_number"
        case seasonNumber = "season_number"
        case stillPath = "still_path"
        case voteAverage = "vote_average"
    }
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

private actor TmdbFindCache {
    private var values: [String: (id: Int, mediaType: String)] = [:]

    func value(for key: String) -> (id: Int, mediaType: String)? {
        values[key]
    }

    func insert(_ value: (id: Int, mediaType: String), for key: String) {
        values[key] = value
    }
}

private actor TmdbLocalizedDetailsCache {
    private var values: [String: TmdbLocalizedDetailsResponse] = [:]

    func value(for key: String) -> TmdbLocalizedDetailsResponse? {
        values[key]
    }

    func insert(_ value: TmdbLocalizedDetailsResponse, for key: String) {
        values[key] = value
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
    let genres: [TmdbGenreDTO]?

    enum CodingKeys: String, CodingKey {
        case title, name, overview, genres
        case originalTitle = "original_title"
        case originalName = "original_name"
        case originalLanguage = "original_language"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case images
    }
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

    static let providerPriorityOrder = [
        providerIMDb,
        providerTMDB,
        providerTomatoes,
        providerMetacritic,
        providerTrakt,
        providerLetterboxd,
        providerAudience
    ]

    private static let providerSettings: [String: String] = [
        providerIMDb: SettingsKey.mdbListUseImdb,
        providerTMDB: SettingsKey.mdbListUseTmdb,
        providerTomatoes: SettingsKey.mdbListUseTomatoes,
        providerMetacritic: SettingsKey.mdbListUseMetacritic,
        providerTrakt: SettingsKey.mdbListUseTrakt,
        providerLetterboxd: SettingsKey.mdbListUseLetterboxd,
        providerAudience: SettingsKey.mdbListUseAudience
    ]

    private struct RatingRequest: Encodable {
        let ids: [String]
        let provider: String
    }

    private struct RatingResponse: Decodable {
        let ratings: [RatingItem]
    }

    private struct RatingItem: Decodable {
        let rating: Double?
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
        return await withTaskGroup(of: (String, NuvioExternalRating?).self) { group in
            for provider in providers {
                group.addTask {
                    (provider, await fetchProviderRating(
                        imdbID: imdbID,
                        mediaType: mediaType,
                        provider: provider,
                        apiKey: apiKey
                    ))
                }
            }

            var resolved: [String: NuvioExternalRating] = [:]
            for await (provider, rating) in group {
                if let rating {
                    resolved[provider] = rating
                }
            }
            return providerPriorityOrder.compactMap { resolved[$0] }
        }
    }

    private static func fetchProviderRating(
        imdbID: String,
        mediaType: String,
        provider: String,
        apiKey: String
    ) async -> NuvioExternalRating? {
        guard let url = URL(string: "https://api.mdblist.com/rating/\(mediaType)/\(provider)?apikey=\(apiKey)") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(
            RatingRequest(ids: [imdbID], provider: providerIMDb)
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let payload = try JSONDecoder().decode(RatingResponse.self, from: data)
            guard let value = payload.ratings.first?.rating, value.isFinite else { return nil }
            return NuvioExternalRating(source: provider, value: value)
        } catch is CancellationError {
            return nil
        } catch {
            // Rating badges are optional enrichment; leave the rest of the
            // details page usable when an individual provider fails.
            return nil
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

