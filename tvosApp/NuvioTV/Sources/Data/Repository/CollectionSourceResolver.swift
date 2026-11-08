import Foundation

enum CollectionSourceError: LocalizedError {
    case invalidAddonSource
    case missingTmdbAPIKey
    case missingTmdbID(String)
    case missingTraktClientID
    case missingTraktListID
    case missingMdbListSource
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
        case .missingMdbListSource:
            return "This MDBList source has no list URL or list ID."
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
        let page: CatalogPage
        switch source.normalizedProvider {
        case "addon":
            guard let type = nonEmpty(source.type),
                  let catalogId = nonEmpty(source.catalogId) else {
                throw CollectionSourceError.invalidAddonSource
            }
            page = try await repository.browseCatalog(
                addonId: nonEmpty(source.addonId),
                contentType: type,
                catalogId: catalogId,
                skip: max(cursor, 0),
                genre: nonEmpty(source.genre)
            )
        case "tmdb":
            page = try await browseTmdb(source, page: max(cursor, 1))
        case "trakt":
            page = try await browseTrakt(source, page: max(cursor, 1))
        case "mdblist":
            page = try await browseMdbList(source, page: max(cursor, 1))
        default:
            throw CollectionSourceError.unsupportedProvider(source.provider)
        }
        for item in page.items {
            repository.cacheCatalogMetadata(item)
        }
        return page
    }

    static func label(
        for source: NuvioCollectionSource,
        installedCatalogs: [AddonCatalogOption] = []
    ) -> String {
        if let title = nonEmpty(source.title) { return title }
        switch source.normalizedProvider {
        case "tmdb":
            return (nonEmpty(source.tmdbSourceType) ?? "TMDB").capitalized
        case "trakt":
            return "Trakt List"
        case "mdblist":
            if let slug = nonEmpty(source.mdblistSlug) {
                let name = slug.split(separator: "/").last.map(String.init) ?? slug
                return name.replacingOccurrences(of: "-", with: " ").capitalized
            }
            if let id = source.mdblistId {
                return "MDBList #\(id)"
            }
            return "MDBList"
        default:
            if source.normalizedProvider == "addon",
               let addonId = nonEmpty(source.addonId),
               let type = nonEmpty(source.type),
               let catalogId = nonEmpty(source.catalogId),
               let catalogName = installedCatalogs.first(where: {
                   $0.addonId == addonId && $0.type == type && $0.catalogId == catalogId
               }).flatMap({ nonEmpty($0.catalogName) }) {
                return catalogName
            }
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
            var rawResults = response.results
            if let withoutLang = nonEmpty(source.filters?.withoutOriginalLanguage)?.lowercased() {
                let excluded = Set(withoutLang.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
                rawResults = rawResults.filter { item in
                    guard let lang = item.originalLanguage?.lowercased() else { return true }
                    return !excluded.contains(lang)
                }
            }
            let items = rawResults.compactMap {
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
        let rawGte = filters?.releaseDateGte
        let normalizedGte = TmdbDateNormalizer.normalize(rawGte, isEndDate: false)
        let rawLte = filters?.releaseDateLte
        let normalizedLte = TmdbDateNormalizer.normalize(rawLte, isEndDate: true)
            ?? (isRecentReleaseSource(source, sort: sort) ? currentLocalDateString() : nil)
        let voteCountGte = filters?.voteCountGte.map { String($0) }
        let voteCountLte = filters?.voteCountLte.map { String($0) }
        let voteAverageGte = filters?.voteAverageGte.map { String($0) }
        let voteAverageLte = filters?.voteAverageLte.map { String($0) }
        var values: [(String, String?)] = [
            ("language", language),
            ("page", String(page)),
            ("sort_by", sort),
            ("with_companies", filters?.withCompanies),
            ("without_companies", filters?.withoutCompanies),
            ("with_networks", filters?.withNetworks),
            ("with_genres", filters?.withGenres),
            ("without_genres", filters?.withoutGenres),
            ("vote_count.gte", voteCountGte),
            ("vote_count.lte", voteCountLte),
            ("vote_average.gte", voteAverageGte),
            ("vote_average.lte", voteAverageLte),
            ("with_original_language", filters?.withOriginalLanguage),
            ("with_origin_country", filters?.withOriginCountry),
            ("without_origin_country", filters?.withoutOriginCountry),
            ("with_keywords", filters?.withKeywords),
            ("without_keywords", filters?.withoutKeywords),
        ]
        if let providers = nonEmpty(filters?.withWatchProviders) {
            values.append(("with_watch_providers", providers))
            values.append(("watch_region", nonEmpty(filters?.watchRegion) ?? "US"))
            values.append(("with_watch_monetization_types", "flatrate|free|ads|rent|buy"))
        }
        if let withoutProviders = nonEmpty(filters?.withoutWatchProviders) {
            values.append(("without_watch_providers", withoutProviders))
        }
        if let year = filters?.year {
            values.append((mediaType == "tv" ? "first_air_date_year" : "year", String(year)))
        }
        values.append((
            mediaType == "tv" ? "first_air_date.gte" : "primary_release_date.gte",
            normalizedGte
        ))
        values.append((
            mediaType == "tv" ? "first_air_date.lte" : "primary_release_date.lte",
            normalizedLte
        ))
        return values.compactMap { name, value in
            nonEmpty(value).map { URLQueryItem(name: name, value: $0) }
        }
    }

    /// The built-in Recent rows sort by release date, but TMDB includes announced
    /// future titles unless the discover request also supplies an upper bound.
    private func isRecentReleaseSource(_ source: NuvioCollectionSource, sort: String) -> Bool {
        guard let title = nonEmpty(source.title)?.lowercased(), title.hasPrefix("recent ") else {
            return false
        }
        return sort == "primary_release_date.desc" || sort == "first_air_date.desc"
    }

    private func currentLocalDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
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

    // MARK: - MDBList

    private func browseMdbList(_ source: NuvioCollectionSource, page: Int) async throws -> CatalogPage {
        let (rawItems, hasMore): ([MdbListCollectionRawItem], Bool) = try await fetchMdbListItems(source: source, page: page)

        var pageMetas: [NuvioMeta] = rawItems.compactMap { item in
            let imdbId = nonEmpty(item.imdbId) ?? nonEmpty(item.ids?.imdb)
            let tmdbId = item.id ?? item.ids?.tmdb
            let id: String
            if let imdb = imdbId {
                id = imdb
            } else if let tmdb = tmdbId, tmdb > 0 {
                id = "tmdb:\(tmdb)"
            } else {
                return nil
            }
            let title = nonEmpty(item.title) ?? nonEmpty(item.name) ?? nonEmpty(item.originalTitle) ?? id
            let rawType = (item.mediatype ?? item.type ?? "").lowercased()
            let resolvedType = (rawType == "show" || rawType == "series" || rawType == "tv") ? "series" : "movie"
            let year = item.releaseYear ?? item.year

            let cached = repository.cachedMetadata(for: id)
            let posterUrl = nonEmpty(item.poster) ?? cached?.posterUrl
            let backgroundUrl = nonEmpty(item.backdrop) ?? cached?.backgroundUrl
            let rating = item.score.flatMap { $0 > 0 ? $0 : nil } ?? cached?.rating

            return NuvioMeta(
                id: id,
                name: title,
                description: nonEmpty(item.description) ?? cached?.description,
                posterUrl: posterUrl,
                backgroundUrl: backgroundUrl,
                logoUrl: cached?.logoUrl,
                imdbId: imdbId,
                tmdbId: tmdbId,
                type: resolvedType,
                year: year,
                genres: cached?.genres,
                rating: rating,
                releaseInfo: year.map(String.init),
                runtime: cached?.runtime,
                cast: nil,
                director: nil,
                writer: nil,
                certification: cached?.certification,
                country: cached?.country,
                released: year.map { "\($0)-01-01" }
            )
        }

        // Enrich the first few items that lack a poster
        await withTaskGroup(of: (Int, NuvioMeta).self) { group in
            for (idx, meta) in pageMetas.enumerated().prefix(15) {
                guard meta.posterUrl == nil else { continue }
                group.addTask {
                    if let full = try? await repository.getMetadata(id: meta.id, type: meta.type) {
                        return (idx, meta.fillingMissingHeroMetadata(from: full))
                    }
                    return (idx, meta)
                }
            }
            for await (idx, enriched) in group {
                pageMetas[idx] = enriched
            }
        }

        for meta in pageMetas {
            repository.cacheCatalogMetadata(meta)
        }

        return CatalogPage(
            items: pageMetas,
            hasMore: hasMore && !pageMetas.isEmpty,
            page: page,
            nextSkip: hasMore && !pageMetas.isEmpty ? page + 1 : nil
        )
    }

    private func fetchMdbListItems(
        source: NuvioCollectionSource,
        page: Int
    ) async throws -> (items: [MdbListCollectionRawItem], hasMore: Bool) {
        let apiKey = settings.string(forKey: SettingsKey.mdbListApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let targetUrl: URL
        let limit = 50

        if let rawUrl = nonEmpty(source.mdblistUrl) {
            targetUrl = try mdbListJsonUrl(from: rawUrl, apiKey: apiKey)
        } else if let slug = nonEmpty(source.mdblistSlug) {
            targetUrl = try mdbListJsonUrl(from: slug, apiKey: apiKey)
        } else if let id = source.mdblistId, id > 0 {
            if let apiKey, !apiKey.isEmpty {
                let mediaPath = source.mediaType == "tv" || source.mediaType == "series" ? "/show" : (source.mediaType == "movie" ? "/movie" : "")
                var components = URLComponents(string: "\(MdbListConfig.apiBaseURL)/lists/\(id)/items\(mediaPath)")!
                let queryItems = [
                    URLQueryItem(name: "apikey", value: apiKey),
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "offset", value: String((page - 1) * limit)),
                    URLQueryItem(name: "append_to_response", value: "poster,description,ratings")
                ]
                components.queryItems = queryItems
                if let url = components.url {
                    do {
                        let (data, _) = try await requestData(url, provider: "MDBList", headers: [:])
                        let parsed = parseMdbListItems(from: data)
                        if !parsed.isEmpty {
                            let hasMore = parsed.count >= limit
                            return (filterAndSortMdbListItems(parsed, source: source), hasMore)
                        }
                    } catch {
                        // Fallback to web json
                    }
                }
            }
            targetUrl = try mdbListJsonUrl(from: String(id), apiKey: apiKey)
        } else if let catalogId = nonEmpty(source.catalogId) {
            targetUrl = try mdbListJsonUrl(from: catalogId, apiKey: apiKey)
        } else {
            throw CollectionSourceError.missingMdbListSource
        }

        let (data, _) = try await requestData(targetUrl, provider: "MDBList", headers: [:])
        let allItems = filterAndSortMdbListItems(parseMdbListItems(from: data), source: source)

        let startIndex = (page - 1) * limit
        guard startIndex < allItems.count else {
            return ([], false)
        }
        let slice = Array(allItems[startIndex..<min(startIndex + limit, allItems.count)])
        let hasMore = startIndex + limit < allItems.count
        return (slice, hasMore)
    }

    private func mdbListJsonUrl(from input: String, apiKey: String?) throws -> URL {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            if trimmed.lowercased().hasPrefix("mdblist.com/") {
                trimmed = "https://\(trimmed)"
            } else if trimmed.contains("/") {
                trimmed = "https://mdblist.com/lists/\(trimmed)"
            } else {
                trimmed = "https://mdblist.com/lists/\(trimmed)"
            }
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if !trimmed.lowercased().hasSuffix("/json") {
            trimmed += "/json"
        }
        guard var components = URLComponents(string: trimmed) else {
            throw CollectionSourceError.invalidResponse("MDBList")
        }
        if let apiKey = nonEmpty(apiKey) {
            var items = components.queryItems ?? []
            if !items.contains(where: { $0.name.lowercased() == "apikey" }) {
                items.append(URLQueryItem(name: "apikey", value: apiKey))
                components.queryItems = items
            }
        }
        guard let url = components.url else {
            throw CollectionSourceError.invalidResponse("MDBList")
        }
        return url
    }

    private func parseMdbListItems(from data: Data) -> [MdbListCollectionRawItem] {
        if let list = try? JSONDecoder().decode([MdbListCollectionRawItem].self, from: data) {
            return list
        }
        if let envelope = try? JSONDecoder().decode(MdbListCollectionEnvelope.self, from: data) {
            if let items = envelope.items { return items }
            if let results = envelope.results { return results }
            if let d = envelope.data { return d }
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var rawArray: [[String: Any]] = []
            for key in ["items", "data", "results", "movies", "shows"] {
                if let array = root[key] as? [[String: Any]] {
                    rawArray.append(contentsOf: array)
                }
            }
            if !rawArray.isEmpty,
               let reencoded = try? JSONSerialization.data(withJSONObject: rawArray),
               let parsed = try? JSONDecoder().decode([MdbListCollectionRawItem].self, from: reencoded) {
                return parsed
            }
        }
        return []
    }

    private func filterAndSortMdbListItems(
        _ items: [MdbListCollectionRawItem],
        source: NuvioCollectionSource
    ) -> [MdbListCollectionRawItem] {
        var filtered = items
        if let mediaType = nonEmpty(source.mediaType)?.lowercased(), mediaType != "all" {
            let isSeries = mediaType == "tv" || mediaType == "series" || mediaType == "show"
            filtered = filtered.filter { item in
                let raw = (item.mediatype ?? item.type ?? "").lowercased()
                let itemIsSeries = raw == "tv" || raw == "series" || raw == "show"
                return isSeries ? itemIsSeries : !itemIsSeries
            }
        }

        switch source.sortBy {
        case "title.asc":
            filtered.sort { ($0.title ?? $0.name ?? "").localizedCaseInsensitiveCompare($1.title ?? $1.name ?? "") == .orderedAscending }
        case "title.desc":
            filtered.sort { ($0.title ?? $0.name ?? "").localizedCaseInsensitiveCompare($1.title ?? $1.name ?? "") == .orderedDescending }
        case "year.desc":
            filtered.sort { ($0.releaseYear ?? $0.year ?? 0) > ($1.releaseYear ?? $1.year ?? 0) }
        case "year.asc":
            filtered.sort { ($0.releaseYear ?? $0.year ?? 0) < ($1.releaseYear ?? $1.year ?? 0) }
        case "score.desc", "rating.desc":
            filtered.sort { ($0.score ?? 0) > ($1.score ?? 0) }
        default:
            filtered.sort { ($0.rank ?? Int.max) < ($1.rank ?? Int.max) }
        }
        return filtered
    }

    // MARK: - Networking

    private func requestData(
        _ url: URL,
        provider: String,
        headers: [String: String]
    ) async throws -> (data: Data, http: HTTPURLResponse) {
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
        return (data, http)
    }

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

        // Configured add-ons commonly keep a token in the manifest URL's
        // query. Concatenating onto `absoluteString` puts the catalog path
        // after `?token=…`, where the server reads it as part of the token
        // instead of the request path. Work with URLComponents so that path,
        // query, and fragment retain their proper roles.
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        var basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if basePath.hasSuffix("manifest.json") {
            basePath = (basePath as NSString).deletingLastPathComponent
            if basePath == "/" || basePath == "." { basePath = "" }
            basePath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        components.percentEncodedPath = "/" + ([basePath, path]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }

    private static let unreserved: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func encodedPathComponent(_ value: String) -> String {
        let clean = value.removingPercentEncoding ?? value
        return clean.addingPercentEncoding(withAllowedCharacters: unreserved) ?? clean
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
    let originalLanguage: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview, job
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case voteAverage = "vote_average"
        case mediaType = "media_type"
        case originalLanguage = "original_language"
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

private struct MdbListCollectionRawItem: Decodable {
    let id: Int?
    let title: String?
    let name: String?
    let originalTitle: String?
    let mediatype: String?
    let type: String?
    let releaseYear: Int?
    let year: Int?
    let imdbId: String?
    let tvdbid: Int?
    let poster: String?
    let backdrop: String?
    let description: String?
    let score: Double?
    let rank: Int?
    let ids: MdbListCollectionIds?

    enum CodingKeys: String, CodingKey {
        case id, title, name, mediatype, type, score, rank, ids, poster, backdrop, description
        case originalTitle = "original_title"
        case releaseYear = "release_year"
        case year
        case imdbId = "imdb_id"
        case tvdbid
    }
}

private struct MdbListCollectionIds: Decodable {
    let imdb: String?
    let tmdb: Int?
    let tvdb: Int?
    let trakt: Int?
}

private struct MdbListCollectionEnvelope: Decodable {
    let items: [MdbListCollectionRawItem]?
    let results: [MdbListCollectionRawItem]?
    let data: [MdbListCollectionRawItem]?
}
