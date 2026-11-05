import Foundation

protocol CalendarHTTPClient: Sendable {
    /// Returns the body and status code. Throws only on transport failures.
    func get(_ url: URL) async throws -> (Data, Int)
}

struct CalendarURLSessionClient: CalendarHTTPClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.requestCachePolicy = .useProtocolCachePolicy
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    func get(_ url: URL) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

enum CalendarTmdbError: Error, Equatable, Sendable {
    case missingApiKey
    case unauthorized
    case notFound
    case http(Int)
    case decoding
}

enum CalendarText {
    /// IDs from tracker/library records are not display titles. Prefer a
    /// resolved TMDB name over an IMDb or TMDB identifier when available.
    static func readableLibraryTitle(_ candidate: String?) -> String? {
        guard let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let lower = text.lowercased()
        let imdb = lower.hasPrefix("imdb:") ? String(lower.dropFirst(5)) : lower
        if imdb.hasPrefix("tt"), imdb.count > 2,
           imdb.dropFirst(2).allSatisfy({ $0.isNumber }) {
            return nil
        }
        if lower.hasPrefix("tmdb:"), Int(lower.dropFirst(5)) != nil {
            return nil
        }
        return text
    }

    /// True when the text is written in a script most viewers of a Latin,
    /// Cyrillic or Greek UI can't read: Japanese, Chinese, Korean, Indic
    /// (Devanagari, Bengali, Tamil…), Thai, Lao, Khmer, Myanmar, Arabic,
    /// Hebrew, Georgian, Armenian or Ethiopic. TMDB falls back to such
    /// original titles when the app language has no translation.
    static func isNonLatin(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0530...0x058F,           // Armenian
                 0x0590...0x05FF,           // Hebrew
                 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, // Arabic
                 0x0900...0x0DFF,           // Indic scripts, Sinhala
                 0x0E00...0x0EFF,           // Thai, Lao
                 0x1000...0x109F,           // Myanmar
                 0x10A0...0x10FF,           // Georgian
                 0x1100...0x11FF,           // Hangul Jamo
                 0x1200...0x137F,           // Ethiopic
                 0x1780...0x17FF,           // Khmer
                 0x3040...0x30FF,           // Hiragana, Katakana
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // CJK
                 0xAC00...0xD7AF,           // Hangul
                 0xFB1D...0xFDFF, 0xFE70...0xFEFF, // Hebrew/Arabic forms
                 0xFF66...0xFF9F:           // Half-width Katakana
                return true
            default:
                return false
            }
        }
    }

    /// Languages whose own script `isNonLatin` covers: native titles are
    /// fine for these viewers.
    static func readsNonLatin(_ language: String) -> Bool {
        let code = language.lowercased().prefix(2)
        return ["ja", "zh", "ko", "hi", "bn", "ta", "te", "kn", "ml", "mr", "gu", "pa", "si",
                "th", "lo", "km", "my", "ar", "fa", "ur", "he", "ka", "hy", "am"].contains(String(code))
    }
}

/// The few TMDB endpoints the calendar needs, decoded into minimal shapes.
enum CalendarTmdb {
    static let imageBase = "https://image.tmdb.org/t/p/"

    static func imageURL(_ path: String?, size: String) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: imageBase + size + path)
    }

    struct Episode: Decodable, Hashable, Sendable {
        let airDate: String?
        let episodeNumber: Int?
        let seasonNumber: Int?
        let name: String?
        let overview: String?
        let stillPath: String?
        let episodeType: String?

        enum CodingKeys: String, CodingKey {
            case airDate = "air_date"
            case episodeNumber = "episode_number"
            case seasonNumber = "season_number"
            case name, overview
            case stillPath = "still_path"
            case episodeType = "episode_type"
        }

        init(airDate: String?, episodeNumber: Int?, seasonNumber: Int?, name: String? = nil,
             overview: String? = nil, stillPath: String? = nil, episodeType: String? = nil) {
            self.airDate = airDate
            self.episodeNumber = episodeNumber
            self.seasonNumber = seasonNumber
            self.name = name
            self.overview = overview
            self.stillPath = stillPath
            self.episodeType = episodeType
        }
    }

    struct SeasonSummary: Decodable, Hashable, Sendable {
        let seasonNumber: Int?
        let airDate: String?

        enum CodingKeys: String, CodingKey {
            case seasonNumber = "season_number"
            case airDate = "air_date"
        }

        init(seasonNumber: Int?, airDate: String?) {
            self.seasonNumber = seasonNumber
            self.airDate = airDate
        }
    }

    struct TvDetails: Decodable, Hashable, Sendable {
        let id: Int
        let name: String?
        let posterPath: String?
        let nextEpisodeToAir: Episode?
        let lastEpisodeToAir: Episode?
        let seasons: [SeasonSummary]?
        let genres: [Genre]?
        let originCountry: [String]?
        let translations: Translations?

        struct Genre: Decodable, Hashable, Sendable { let id: Int }

        struct Translations: Decodable, Hashable, Sendable {
            struct Item: Decodable, Hashable, Sendable {
                struct Payload: Decodable, Hashable, Sendable { let name: String? }
                let language: String?
                let data: Payload?
                enum CodingKeys: String, CodingKey {
                    case language = "iso_639_1"
                    case data
                }
            }
            let translations: [Item]?
        }

        enum CodingKeys: String, CodingKey {
            case id, name, seasons, genres, translations
            case posterPath = "poster_path"
            case nextEpisodeToAir = "next_episode_to_air"
            case lastEpisodeToAir = "last_episode_to_air"
            case originCountry = "origin_country"
        }

        /// A name the viewer can read: the localized one, or English when
        /// TMDB fell back to an original title in another script.
        var readableName: String? {
            if let name, !name.isEmpty, !CalendarText.isNonLatin(name) { return name }
            let english = translations?.translations?
                .first { $0.language == "en" }?.data?.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let english, !english.isEmpty, !CalendarText.isNonLatin(english) { return english }
            return nil
        }

        init(id: Int, name: String?, posterPath: String? = nil, nextEpisodeToAir: Episode? = nil,
             lastEpisodeToAir: Episode? = nil, seasons: [SeasonSummary]? = nil,
             genres: [Genre]? = nil, originCountry: [String]? = nil, translations: Translations? = nil) {
            self.id = id
            self.name = name
            self.posterPath = posterPath
            self.nextEpisodeToAir = nextEpisodeToAir
            self.lastEpisodeToAir = lastEpisodeToAir
            self.seasons = seasons
            self.genres = genres
            self.originCountry = originCountry
            self.translations = translations
        }

        /// Japanese animation: TMDB dates these by the Japanese broadcast day.
        var isJapaneseAnime: Bool {
            (genres ?? []).contains { $0.id == 16 } && (originCountry ?? []).contains("JP")
        }
    }

    struct SeasonDetails: Decodable, Hashable, Sendable {
        let episodes: [Episode]?
    }

    struct ReleaseDate: Decodable, Hashable, Sendable {
        let releaseDate: String?
        /// 1 premiere, 2 limited theatrical, 3 theatrical, 4 digital, 5 physical, 6 TV.
        let type: Int?

        enum CodingKeys: String, CodingKey {
            case releaseDate = "release_date"
            case type
        }

        init(releaseDate: String?, type: Int?) {
            self.releaseDate = releaseDate
            self.type = type
        }
    }

    struct CountryReleases: Decodable, Hashable, Sendable {
        let country: String?
        let releaseDates: [ReleaseDate]?

        enum CodingKeys: String, CodingKey {
            case country = "iso_3166_1"
            case releaseDates = "release_dates"
        }

        init(country: String?, releaseDates: [ReleaseDate]?) {
            self.country = country
            self.releaseDates = releaseDates
        }
    }

    struct MovieDetails: Decodable, Hashable, Sendable {
        let id: Int
        let title: String?
        let posterPath: String?
        let backdropPath: String?
        let releaseDate: String?
        let overview: String?
        let releaseDates: ReleaseDatesContainer?

        struct ReleaseDatesContainer: Decodable, Hashable, Sendable {
            let results: [CountryReleases]?
        }

        enum CodingKeys: String, CodingKey {
            case id, title, overview
            case posterPath = "poster_path"
            case backdropPath = "backdrop_path"
            case releaseDate = "release_date"
            case releaseDates = "release_dates"
        }

        init(id: Int, title: String?, posterPath: String? = nil, backdropPath: String? = nil,
             releaseDate: String? = nil, overview: String? = nil, countries: [CountryReleases]? = nil) {
            self.id = id
            self.title = title
            self.posterPath = posterPath
            self.backdropPath = backdropPath
            self.releaseDate = releaseDate
            self.overview = overview
            self.releaseDates = countries.map { ReleaseDatesContainer(results: $0) }
        }
    }

    /// One title from a TMDB list or discover query.
    struct ListResult: Decodable, Hashable, Identifiable, Sendable {
        let id: Int
        let name: String?
        let title: String?
        let posterPath: String?
        let firstAirDate: String?
        let releaseDate: String?

        enum CodingKeys: String, CodingKey {
            case id, name, title
            case posterPath = "poster_path"
            case firstAirDate = "first_air_date"
            case releaseDate = "release_date"
        }

        var displayTitle: String { title ?? name ?? "#\(id)" }
        var year: Int? { (releaseDate ?? firstAirDate).flatMap { Int($0.prefix(4)) } }
    }

    struct ListPage: Decodable, Sendable {
        let results: [ListResult]?
        let totalPages: Int?

        enum CodingKeys: String, CodingKey {
            case results
            case totalPages = "total_pages"
        }
    }

    struct FindResults: Decodable, Sendable {
        struct Item: Decodable, Sendable { let id: Int }
        let tvResults: [Item]?
        enum CodingKeys: String, CodingKey { case tvResults = "tv_results" }
    }

    struct ExternalIds: Decodable, Sendable {
        let imdbId: String?
        let tvdbId: Int?
        enum CodingKeys: String, CodingKey {
            case imdbId = "imdb_id"
            case tvdbId = "tvdb_id"
        }

        /// The IMDb id when it looks like one ("tt…").
        var validImdbId: String? {
            guard let imdb = imdbId?.trimmingCharacters(in: .whitespacesAndNewlines), imdb.hasPrefix("tt") else {
                return nil
            }
            return imdb
        }
    }

    struct Client: Sendable {
        let apiKey: String
        let language: String
        private let http: CalendarHTTPClient
        private let baseURL: URL

        init(apiKey: String, language: String = "en-US", http: CalendarHTTPClient = CalendarURLSessionClient(),
             baseURL: URL = URL(string: "https://api.themoviedb.org/3")!) {
            self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.language = language
            self.http = http
            self.baseURL = baseURL
        }

        func tvDetails(_ id: Int) async throws -> TvDetails {
            // Translations ride along so CJK fallback names can be swapped for English.
            try await get("tv/\(id)", query: ["append_to_response": "translations"])
        }

        func season(_ tvId: Int, number: Int) async throws -> SeasonDetails {
            try await get("tv/\(tvId)/season/\(number)")
        }

        func movieDetails(_ id: Int) async throws -> MovieDetails {
            try await get("movie/\(id)", query: ["append_to_response": "release_dates"])
        }

        func list(_ path: String, query: [String: String] = [:], pages: Int = 2) async throws -> [ListResult] {
            var all: [ListResult] = []
            var seen = Set<Int>()
            for page in 1...max(1, pages) {
                var q = query
                q["page"] = String(page)
                let response: ListPage = try await get(path, query: q)
                var results = response.results ?? []
                // TMDB falls back to the original title (Japanese, Hindi, Thai…)
                // when there's no translation; fetch the page in English then.
                if !CalendarText.readsNonLatin(language), results.contains(where: { CalendarText.isNonLatin($0.displayTitle) }),
                   let english: ListPage = try? await get(path, query: q, language: "en-US") {
                    let names = Dictionary((english.results ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                    results = results.map { result in
                        guard CalendarText.isNonLatin(result.displayTitle), let en = names[result.id],
                              !CalendarText.isNonLatin(en.displayTitle) else { return result }
                        return ListResult(id: result.id, name: en.name, title: en.title, posterPath: result.posterPath,
                                          firstAirDate: result.firstAirDate, releaseDate: result.releaseDate)
                    }
                }
                for result in results where seen.insert(result.id).inserted {
                    all.append(result)
                }
                if let total = response.totalPages, page >= total { break }
            }
            return all
        }

        func imdbId(tmdbId: Int, kind: CalendarMediaKind) async throws -> String? {
            try await externalIds(tmdbId: tmdbId, kind: kind).validImdbId
        }

        /// The TMDB show a TheTVDB series id belongs to, if TMDB knows it.
        func tvId(forTvdb tvdbId: Int) async throws -> Int? {
            let found: FindResults = try await get("find/\(tvdbId)", query: ["external_source": "tvdb_id"])
            return found.tvResults?.first?.id
        }

        func externalIds(tmdbId: Int, kind: CalendarMediaKind) async throws -> ExternalIds {
            let media = kind == .series ? "tv" : "movie"
            return try await get("\(media)/\(tmdbId)/external_ids")
        }

        func get<T: Decodable>(_ path: String, query: [String: String] = [:], language: String? = nil) async throws -> T {
            guard !apiKey.isEmpty else { throw CalendarTmdbError.missingApiKey }
            guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
                throw CalendarTmdbError.http(0)
            }
            var items = [
                URLQueryItem(name: "api_key", value: apiKey),
                URLQueryItem(name: "language", value: language ?? self.language),
            ]
            for key in query.keys.sorted() {
                items.append(URLQueryItem(name: key, value: query[key]))
            }
            components.queryItems = items
            guard let url = components.url else { throw CalendarTmdbError.http(0) }

            let (data, status) = try await http.get(url)
            switch status {
            case 200...299: break
            case 401: throw CalendarTmdbError.unauthorized
            case 404: throw CalendarTmdbError.notFound
            default: throw CalendarTmdbError.http(status)
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw CalendarTmdbError.decoding
            }
        }
    }
}
