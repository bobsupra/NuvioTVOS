import Foundation

enum CollectionSourceError: LocalizedError {
    case invalidAddonSource
    case missingTmdbAPIKey
    case missingTmdbID(String)
    case missingTraktClientID
    case missingTraktListID
    case unsupportedProvider(String)
    case requestFailed(String, Int)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddonSource:
            return "This add-on catalog source is incomplete."
        case .missingTmdbAPIKey:
            return "Enter a TMDB API key in Settings to load this folder."
        case .missingTmdbID(let sourceType):
            return "This TMDB \(sourceType.lowercased()) source has no ID."
        case .missingTraktClientID:
            return "Enter a Trakt Client ID in Settings to load this folder."
        case .missingTraktListID:
            return "This Trakt source has no public list ID."
        case .unsupportedProvider(let provider):
            return "The collection source provider “\(provider)” is not supported."
        case .requestFailed(let provider, let status):
            return "\(provider) returned HTTP \(status)."
        case .invalidResponse(let provider):
            return "\(provider) returned data the app could not read."
        }
    }
}

/// Resolves the heterogeneous collection source format shared with the Compose
/// client. Its cursor is a Stremio item offset for add-ons and a page number for
/// TMDB/Trakt; callers store the opaque value from `CatalogPage.nextSkip`.
struct CollectionSourceResolver {
    let repository: CatalogRepository
    var session: URLSession = .shared
    var settings: UserDefaults = ProfileSettings.current

    func browse(_ source: NuvioCollectionSource, cursor: Int = 0) async throws -> CatalogPage {
        switch source.normalizedProvider {
        case "addon":
            guard let addonId = nonEmpty(source.addonId),
                  let type = nonEmpty(source.type),
                  let catalogId = nonEmpty(source.catalogId) else {
                throw CollectionSourceError.invalidAddonSource
            }
            return try await repository.browseCatalog(
                addonId: addonId,
                contentType: type,
                catalogId: catalogId,
                skip: max(cursor, 0),
                genre: nonEmpty(source.genre)
            )
        case "tmdb":
            return try await browseTmdb(source, page: max(cursor, 1))
        case "trakt":
            return try await browseTrakt(source, page: max(cursor, 1))
        default:
            throw CollectionSourceError.unsupportedProvider(source.provider)
        }
    }

    static func label(for source: NuvioCollectionSource) -> String {
        if let title = nonEmpty(source.title) { return title }
        switch source.normalizedProvider {
        case "tmdb":
            return (nonEmpty(source.tmdbSourceType) ?? "TMDB").capitalized
        case "trakt":
            return "Trakt List"
        default:
            let name = (nonEmpty(source.catalogId) ?? "Catalog")
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            let type = nonEmpty(source.type)?.capitalized
            let base = type.map { "\(name) (\($0))" } ?? name
            if let genre = nonEmpty(source.genre) {
                return "\(base) · \(genre)"
            }
            return base
        }
    }

    // MARK: - TMDB

    private func browseTmdb(_ source: NuvioCollectionSource, page: Int) async throws -> CatalogPage {
        guard let apiKey = nonEmpty(settings.string(forKey: SettingsKey.tmdbApiKey)) else {
            throw CollectionSourceError.missingTmdbAPIKey
        }

        let sourceType = (nonEmpty(source.tmdbSourceType) ?? "DISCOVER").uppercased()
        let language = TmdbDetailsService.preferredLanguage
        switch sourceType {
        case "LIST":
            let id = try requiredTmdbID(source, sourceType: sourceType)
            let response: TmdbCollectionListResponse = try await tmdbRequest(
                path: "list/\(id)",
                apiKey: apiKey,
                query: [
                    URLQueryItem(name: "language", value: language),
                    URLQueryItem(name: "page", value: String(page))
                ]
            )
            let items = sortedTmdbItems(
                response.items.compactMap { tmdbMeta(from: $0, fallbackMediaType: source.mediaType) },
                sortBy: source.sortBy
            )
            let hasMore = page < (response.totalPages ?? page) && !items.isEmpty
            return CatalogPage(
                items: items,
                hasMore: hasMore,
                page: page,
                nextSkip: hasMore ? page + 1 : nil
            )

        case "COLLECTION":
            let id = try requiredTmdbID(source, sourceType: sourceType)
            let response: TmdbCollectionResponse = try await tmdbRequest(
                path: "collection/\(id)",
                apiKey: apiKey,
                query: [URLQueryItem(name: "language", value: language)]
            )
            let items = sortedTmdbItems(
                response.parts.compactMap { tmdbMeta(from: $0, fallbackMediaType: "movie") },
                sortBy: source.sortBy
            )
            return CatalogPage(items: items, hasMore: false, page: 1, nextSkip: nil)

        case "PERSON", "DIRECTOR":
            let id = try requiredTmdbID(source, sourceType: sourceType)
            let response: TmdbCollectionCreditsResponse = try await tmdbRequest(
                path: "person/\(id)/combined_credits",
                apiKey: apiKey,
                query: [URLQueryItem(name: "language", value: language)]
            )
            let rawItems = sourceType == "DIRECTOR"
                ? response.crew.filter { $0.job?.caseInsensitiveCompare("Director") == .orderedSame }
                : response.cast
            let items = sortedTmdbItems(
                rawItems.compactMap { tmdbMeta(from: $0, fallbackMediaType: source.mediaType) },
                sortBy: source.sortBy
            )
            return CatalogPage(items: items, hasMore: false, page: 1, nextSkip: nil)

        case "COMPANY", "NETWORK", "DISCOVER":
            let mediaType = sourceType == "NETWORK" ? "tv" : normalizedTmdbMediaType(source.mediaType)
            var query = tmdbDiscoverQuery(source, mediaType: mediaType, page: page, language: language)
            if sourceType == "COMPANY" {
                query.append(
                    URLQueryItem(
                        name: "with_companies",
                        value: String(try requiredTmdbID(source, sourceType: sourceType))
                    )
                )
            } else if sourceType == "NETWORK" {
                query.append(
                    URLQueryItem(
                        name: "with_networks",
                        value: String(try requiredTmdbID(source, sourceType: sourceType))
                    )
                )
            }
            let response: TmdbCollectionPageResponse = try await tmdbRequest(
                path: "discover/\(mediaType)",
                apiKey: apiKey,
                query: query
            )
            let items = response.results.compactMap {
                tmdbMeta(from: $0, fallbackMediaType: mediaType)
            }
            let hasMore = page < (response.totalPages ?? page) && !items.isEmpty
            return CatalogPage(
                items: items,
                hasMore: hasMore,
                page: page,
                nextSkip: hasMore ? page + 1 : nil
            )

        default:
            throw CollectionSourceError.unsupportedProvider("TMDB \(sourceType)")
        }
    }

    private func requiredTmdbID(
        _ source: NuvioCollectionSource,
        sourceType: String
    ) throws -> Int {
        guard let id = source.tmdbId, id > 0 else {
            throw CollectionSourceError.missingTmdbID(sourceType)
        }
        return id
    }

    private func tmdbDiscoverQuery(
        _ source: NuvioCollectionSource,
        mediaType: String,
        page: Int,
        language: String
    ) -> [URLQueryItem] {
        let filters = source.filters
        let sort = normalizedTmdbSort(source.sortBy, mediaType: mediaType)
        let voteCountGte = filters?.voteCountGte.map { String($0) }
        let voteAverageGte = filters?.voteAverageGte.map { String($0) }
        let voteAverageLte = filters?.voteAverageLte.map { String($0) }
        var values: [(String, String?)] = [
            ("language", language),
            ("page", String(page)),
            ("sort_by", sort),
            ("with_companies", filters?.withCompanies),
            ("with_networks", filters?.withNetworks),
            ("with_genres", filters?.withGenres),
            ("vote_count.gte", voteCountGte),
            ("vote_average.gte", voteAverageGte),
            ("vote_average.lte", voteAverageLte),
            ("with_original_language", filters?.withOriginalLanguage),
            ("with_origin_country", filters?.withOriginCountry),
            ("with_keywords", filters?.withKeywords),
        ]
        if let providers = nonEmpty(filters?.withWatchProviders) {
            values.append(("with_watch_providers", providers))
            values.append(("watch_region", nonEmpty(filters?.watchRegion) ?? "US"))
            values.append(("with_watch_monetization_types", "flatrate|free|ads|rent|buy"))
        }
        if let year = filters?.year {
            values.append((mediaType == "tv" ? "first_air_date_year" : "year", String(year)))
        }
        values.append((
            mediaType == "tv" ? "first_air_date.gte" : "primary_release_date.gte",
            filters?.releaseDateGte
        ))
        values.append((
            mediaType == "tv" ? "first_air_date.lte" : "primary_release_date.lte",
            filters?.releaseDateLte
        ))
        return values.compactMap { name, value in
            nonEmpty(value).map { URLQueryItem(name: name, value: $0) }
        }
    }

    private func normalizedTmdbSort(_ value: String?, mediaType: String) -> String {
        let sort = nonEmpty(value) ?? "popularity.desc"
        if mediaType == "tv" {
            switch sort {
            case "primary_release_date.desc", "release_date.desc":
                return "first_air_date.desc"
            default:
                return sort
            }
        }
        if sort == "first_air_date.desc" { return "primary_release_date.desc" }
        return sort
    }

    private func normalizedTmdbMediaType(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "tv", "series", "show":
            return "tv"
        default:
            return "movie"
        }
    }

    private func tmdbRequest<T: Decodable>(
        path: String,
        apiKey: String,
        query: [URLQueryItem]
    ) async throws -> T {
        var components = URLComponents(
            url: URL(string: "https://api.themoviedb.org/3")!.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)] + query
        guard let url = components.url else {
            throw CollectionSourceError.invalidResponse("TMDB")
        }
        return try await request(url, provider: "TMDB", headers: [:])
    }

    private func tmdbMeta(
        from item: TmdbCollectionItem,
        fallbackMediaType: String?
    ) -> NuvioMeta? {
        guard item.id > 0 else { return nil }
        let mediaType = normalizedTmdbMediaType(item.mediaType ?? fallbackMediaType)
        let name = nonEmpty(item.title) ?? nonEmpty(item.name)
        guard let name else { return nil }
        let releaseDate = nonEmpty(item.releaseDate) ?? nonEmpty(item.firstAirDate)
        return NuvioMeta(
            id: "tmdb:\(item.id)",
            name: name,
            description: nonEmpty(item.overview),
            posterUrl: tmdbImage(item.posterPath, size: "w500")
                ?? tmdbImage(item.backdropPath, size: "w780"),
            backgroundUrl: tmdbImage(item.backdropPath, size: "w1280"),
            logoUrl: nil,
            imdbId: nil,
            tmdbId: item.id,
            type: mediaType == "tv" ? "series" : "movie",
            year: releaseDate.flatMap { Int($0.prefix(4)) },
            genres: nil,
            rating: item.voteAverage.flatMap { $0 > 0 ? $0 : nil },
            releaseInfo: releaseDate.map { String($0.prefix(4)) },
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: releaseDate
        )
    }

    private func sortedTmdbItems(_ items: [NuvioMeta], sortBy: String?) -> [NuvioMeta] {
        switch sortBy {
        case "vote_average.desc":
            return items.sorted { ($0.rating ?? -1) > ($1.rating ?? -1) }
        case "release_date.desc", "primary_release_date.desc", "first_air_date.desc":
            return items.sorted { ($0.released ?? "") > ($1.released ?? "") }
        default:
            return items
        }
    }

    private func tmdbImage(_ path: String?, size: String) -> String? {
        guard let path = nonEmpty(path) else { return nil }
        if path.lowercased().hasPrefix("http") { return path }
        return "https://image.tmdb.org/t/p/\(size)\(path.hasPrefix("/") ? path : "/\(path)")"
    }

    // MARK: - Trakt

    private func browseTrakt(_ source: NuvioCollectionSource, page: Int) async throws -> CatalogPage {
        let clientID = TraktConfig.clientID(in: settings)
        guard !clientID.isEmpty else {
            throw CollectionSourceError.missingTraktClientID
        }
        guard let listID = source.traktListId, listID > 0 else {
            throw CollectionSourceError.missingTraktListID
        }

        let isSeries = normalizedTmdbMediaType(source.mediaType) == "tv"
        let itemType = isSeries ? "show" : "movie"
        let limit = 50
        var components = URLComponents(
            string: "\(TraktConfig.apiBaseURL)/lists/\(listID)/items/\(itemType)"
        )!
        components.queryItems = [
            URLQueryItem(name: "extended", value: "full,images"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort_by", value: normalizedTraktSort(source.sortBy)),
            URLQueryItem(name: "sort_how", value: normalizedTraktDirection(source.sortHow))
        ]
        guard let url = components.url else {
            throw CollectionSourceError.invalidResponse("Trakt")
        }

        let response: (value: [TraktCollectionListItem], http: HTTPURLResponse) = try await requestWithResponse(
            url,
            provider: "Trakt",
            headers: [
                "Accept": "application/json",
                "trakt-api-version": "2",
                "trakt-api-key": clientID
            ]
        )
        var seen = Set<String>()
        let items = response.value.compactMap { entry in
            traktMeta(
                from: isSeries ? entry.show : entry.movie,
                type: isSeries ? "series" : "movie"
            )
        }.filter { seen.insert("\($0.type):\($0.id)").inserted }

        let pageCount = response.http.value(forHTTPHeaderField: "x-pagination-page-count")
            .flatMap(Int.init)
        let hasMore = pageCount.map { page < $0 } ?? (items.count == limit)
        return CatalogPage(
            items: items,
            hasMore: hasMore && !items.isEmpty,
            page: page,
            nextSkip: hasMore && !items.isEmpty ? page + 1 : nil
        )
    }

    private func normalizedTraktSort(_ value: String?) -> String {
        let allowed = ["rank", "added", "title", "released", "runtime", "popularity", "percentage", "votes"]
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return allowed.contains(value) ? value : "rank"
    }

    private func normalizedTraktDirection(_ value: String?) -> String {
        value?.caseInsensitiveCompare("desc") == .orderedSame ? "desc" : "asc"
    }

    private func traktMeta(from item: TraktCollectionMedia?, type: String) -> NuvioMeta? {
        guard let item, let name = nonEmpty(item.title) else { return nil }
        let id: String
        if let imdb = nonEmpty(item.ids?.imdb) {
            id = imdb
        } else if let tmdb = item.ids?.tmdb {
            id = "tmdb:\(tmdb)"
        } else if let trakt = item.ids?.trakt {
            id = "trakt:\(trakt)"
        } else {
            return nil
        }
        let releaseDate = type == "series" ? item.firstAired : item.released
        return NuvioMeta(
            id: id,
            name: name,
            description: nonEmpty(item.overview),
            posterUrl: traktImage(item.images?.poster) ?? traktImage(item.images?.fanart),
            backgroundUrl: traktImage(item.images?.fanart)
                ?? traktImage(item.images?.banner)
                ?? traktImage(item.images?.thumb),
            logoUrl: traktImage(item.images?.logo) ?? traktImage(item.images?.clearart),
            imdbId: nonEmpty(item.ids?.imdb),
            tmdbId: item.ids?.tmdb,
            type: type,
            year: item.year,
            genres: item.genres,
            rating: item.rating.flatMap { $0 > 0 ? $0 : nil },
            releaseInfo: item.year.map(String.init) ?? releaseDate.map { String($0.prefix(4)) },
            runtime: item.runtime.map { "\($0) min" },
            cast: nil,
            director: nil,
            writer: nil,
            certification: item.certification,
            country: item.country,
            released: releaseDate
        )
    }

    private func traktImage(_ values: [String]?) -> String? {
        guard var value = values?.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if value.hasPrefix("//") {
            value = "https:\(value)"
        } else if value.lowercased().hasPrefix("http://") {
            value = "https://" + String(value.dropFirst("http://".count))
        } else if !value.lowercased().hasPrefix("https://"),
                  value.lowercased().contains("trakt.tv/") {
            value = "https://\(value)"
        }
        return value
    }

    // MARK: - Networking

    private func request<T: Decodable>(
        _ url: URL,
        provider: String,
        headers: [String: String]
    ) async throws -> T {
        let result: (value: T, http: HTTPURLResponse) = try await requestWithResponse(
            url,
            provider: provider,
            headers: headers
        )
        return result.value
    }

    private func requestWithResponse<T: Decodable>(
        _ url: URL,
        provider: String,
        headers: [String: String]
    ) async throws -> (value: T, http: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CollectionSourceError.invalidResponse(provider)
        }
        guard 200..<300 ~= http.statusCode else {
            throw CollectionSourceError.requestFailed(provider, http.statusCode)
        }
        do {
            return (try JSONDecoder().decode(T.self, from: data), http)
        } catch {
            throw CollectionSourceError.invalidResponse(provider)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private func nonEmpty(_ value: String?) -> String? {
        Self.nonEmpty(value)
    }
}

/// Constructs Stremio path-style extras once. `URL.appendingPathComponent`
/// re-encodes an already escaped `%20` as `%2520`, so the endpoint is assembled
/// from an escaped string instead.
enum StremioCatalogURLBuilder {
    static func url(
        baseURL: URL,
        type: String,
        catalogId: String,
        skip: Int? = nil,
        search: String? = nil,
        genre: String? = nil
    ) throws -> URL {
        var extras: [String] = []
        if let search, let encoded = encodedExtra(name: "search", value: search) {
            extras.append(encoded)
        }
        if let genre, let encoded = encodedExtra(name: "genre", value: genre) {
            extras.append(encoded)
        }
        if let skip {
            extras.append("skip=\(max(skip, 0))")
        }

        var path = "catalog/\(encodedPathComponent(type))/\(encodedPathComponent(catalogId))"
        if !extras.isEmpty {
            path += "/" + extras.joined(separator: "&")
        }
        path += ".json"

        let base = baseURL.absoluteString.hasSuffix("/")
            ? String(baseURL.absoluteString.dropLast())
            : baseURL.absoluteString
        guard let url = URL(string: "\(base)/\(path)") else {
            throw URLError(.badURL)
        }
        return url
    }

    private static let unreserved: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func encodedPathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func encodedExtra(name: String, value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return "\(encodedPathComponent(name))=\(encodedPathComponent(value))"
    }
}

private struct TmdbCollectionPageResponse: Decodable {
    let page: Int?
    let totalPages: Int?
    let results: [TmdbCollectionItem]

    enum CodingKeys: String, CodingKey {
        case page, results
        case totalPages = "total_pages"
    }
}

private struct TmdbCollectionListResponse: Decodable {
    let page: Int?
    let totalPages: Int?
    let items: [TmdbCollectionItem]

    enum CodingKeys: String, CodingKey {
        case page, items
        case totalPages = "total_pages"
    }
}

private struct TmdbCollectionResponse: Decodable {
    let parts: [TmdbCollectionItem]
}

private struct TmdbCollectionCreditsResponse: Decodable {
    let cast: [TmdbCollectionItem]
    let crew: [TmdbCollectionItem]
}

private struct TmdbCollectionItem: Decodable {
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
    let job: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, job
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case mediaType = "media_type"
    }
}

private struct TraktCollectionListItem: Decodable {
    let movie: TraktCollectionMedia?
    let show: TraktCollectionMedia?
}

private struct TraktCollectionMedia: Decodable {
    let title: String?
    let year: Int?
    let ids: TraktCollectionIDs?
    let overview: String?
    let released: String?
    let firstAired: String?
    let rating: Double?
    let genres: [String]?
    let runtime: Int?
    let certification: String?
    let country: String?
    let images: TraktCollectionImages?

    enum CodingKeys: String, CodingKey {
        case title, year, ids, overview, released, rating, genres, runtime
        case certification, country, images
        case firstAired = "first_aired"
    }
}

private struct TraktCollectionIDs: Decodable {
    let trakt: Int?
    let imdb: String?
    let tmdb: Int?
}

private struct TraktCollectionImages: Decodable {
    let fanart: [String]?
    let poster: [String]?
    let logo: [String]?
    let clearart: [String]?
    let banner: [String]?
    let thumb: [String]?
}
