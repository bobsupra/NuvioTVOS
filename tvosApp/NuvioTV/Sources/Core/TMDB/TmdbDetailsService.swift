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
/// Lightweight related-title card for More Like This / production browse.
struct RelatedTitle: Identifiable, Equatable {
    let id: String
    let type: String
    let name: String
    let posterURL: String?
    let year: String?
    let rating: Double?
    let overview: String?

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
            backgroundUrl: nil,
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

/// TMDB helpers for details enrichment: production companies, more-like-this,
/// and discovering everything a company/network has made.
enum TmdbDetailsService {
    private static let apiBase = URL(string: "https://api.themoviedb.org/3")!
    private static let imageBase = "https://image.tmdb.org/t/p/"

    private static var apiKey: String? {
        let key = ProfileSettings.current.string(forKey: SettingsKey.tmdbApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? nil : key
    }

    private static var isEnabled: Bool {
        (ProfileSettings.current.object(forKey: SettingsKey.tmdbEnabled) as? Bool) ?? false
    }

    // MARK: - Public

    static func resolveTmdbId(for meta: NuvioMeta) async -> (id: Int, mediaType: String)? {
        guard isEnabled, apiKey != nil else { return nil }
        let mediaType = isSeries(meta.type) ? "tv" : "movie"
        if let tmdbId = meta.tmdbId, tmdbId > 0 {
            return (tmdbId, mediaType)
        }
        let imdb = meta.imdbId ?? (meta.id.hasPrefix("tt") ? meta.id.split(separator: ":").first.map(String.init) : nil)
        guard let imdb, imdb.hasPrefix("tt") else { return nil }
        return await findByImdb(imdb)
    }

    static func fetchCompanies(for meta: NuvioMeta) async -> [MetaCompany] {
        guard let resolved = await resolveTmdbId(for: meta) else { return [] }
        return await fetchCompanies(tmdbId: resolved.id, mediaType: resolved.mediaType)
    }

    static func fetchMoreLikeThis(for meta: NuvioMeta, limit: Int = 16) async -> [RelatedTitle] {
        guard let resolved = await resolveTmdbId(for: meta) else { return [] }
        return await fetchRecommendations(
            tmdbId: resolved.id,
            mediaType: resolved.mediaType,
            limit: limit
        )
    }

    /// All titles from a production company or network (movies + TV when applicable).
    static func discoverTitles(
        company: MetaCompany,
        page: Int = 1
    ) async -> [RelatedTitle] {
        guard isEnabled, let apiKey, let companyId = company.tmdbId, companyId > 0 else {
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

    // MARK: - Private

    private static func isSeries(_ type: String) -> Bool {
        ["series", "show", "tv", "tvshow"].contains(type.lowercased())
    }

    private static func findByImdb(_ imdbId: String) async -> (id: Int, mediaType: String)? {
        guard let apiKey else { return nil }
        var components = URLComponents(
            url: apiBase.appendingPathComponent("find/\(imdbId)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "external_source", value: "imdb_id")
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TmdbFindResponse.self, from: data) else {
            return nil
        }
        if let movie = decoded.movieResults?.first {
            return (movie.id, "movie")
        }
        if let show = decoded.tvResults?.first {
            return (show.id, "tv")
        }
        return nil
    }

    private static func fetchCompanies(tmdbId: Int, mediaType: String) async -> [MetaCompany] {
        guard let apiKey else { return [] }
        var components = URLComponents(
            url: apiBase.appendingPathComponent("\(mediaType)/\(tmdbId)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(TmdbDetailsResponse.self, from: data) else {
            return []
        }

        var companies: [MetaCompany] = []
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
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
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
        apiKey: String
    ) async -> [RelatedTitle] {
        var components = URLComponents(
            url: apiBase.appendingPathComponent(endpoint),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: companyParam, value: String(companyId)),
            URLQueryItem(name: "sort_by", value: "popularity.desc"),
            URLQueryItem(name: "page", value: String(page))
        ]
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
            overview: item.overview?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func imageURL(_ path: String?, size: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return path }
        return imageBase + size + path
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

    enum CodingKeys: String, CodingKey {
        case productionCompanies = "production_companies"
        case networks
    }
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
