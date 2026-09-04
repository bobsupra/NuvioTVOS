import Foundation

/// Simkl's community numbers for one title, shown on the details summary line.
struct SimklTitleRatings: Equatable {
    let rating: Double?
    let votes: Int?
    let rank: Int?
    /// Share of users who started the title and gave up on it, preformatted by
    /// Simkl as a percentage string ("3.2%").
    let dropRate: String?

    var isEmpty: Bool {
        rating == nil && rank == nil && dropRate == nil
    }
}

/// The two things the details page takes from one Simkl detail response.
struct SimklTitleDetails: Equatable {
    var ratings: SimklTitleRatings?
    var related: [RelatedTitle]
}

/// Simkl details enrichment: community ratings and More Like This.
///
/// Both come out of a single `/movies|tv|anime/{id}` call, which needs only the
/// Client ID — no linked account, no bearer token — and is Cloudflare-cached by
/// Simkl id on their side.
enum SimklDetailsService {
    private static let client = SimklAPIClient()

    static var isConfigured: Bool { SimklConfig.isConfigured }

    /// Community ratings + recommendations. `nil` when Simkl isn't set up or
    /// the title can't be matched to a Simkl id.
    static func fetchDetails(for meta: NuvioMeta, limit: Int = 16) async -> SimklTitleDetails? {
        guard isConfigured else { return nil }
        guard let match = await resolveMatch(for: meta) else { return nil }
        guard let detail: SimklDetailDTO = await get(path: "\(match.kind.path)/\(match.simklID)") else {
            return nil
        }
        let ratings = detail.toRatings()
        return SimklTitleDetails(
            ratings: ratings.isEmpty ? nil : ratings,
            related: detail.toRelated(limit: limit)
        )
    }

    /// Resolves a `simkl:` card id to an IMDb id so Cinemeta can open it.
    ///
    /// `users_recommendations` entries carry only Simkl's own id and slug, so
    /// this runs once for the card the user actually opened rather than for
    /// every card in the row. Called from `CatalogRepository.loadMetadata`.
    static func resolveImdbID(simklID: String, type: String) async -> String? {
        guard isConfigured, let identifier = Int(simklID), identifier > 0 else { return nil }
        // Simkl files anime under its own endpoint, and the id spaces don't
        // overlap, so fall back to it when the type-matched endpoint misses.
        let candidates: [Kind] = isSeries(type) ? [.show, .anime, .movie] : [.movie, .show, .anime]
        for kind in candidates {
            guard let detail: SimklDetailDTO = await get(path: "\(kind.path)/\(identifier)") else {
                continue
            }
            if let imdb = detail.ids?.imdb?.trimmingCharacters(in: .whitespacesAndNewlines),
               imdb.hasPrefix("tt") {
                return imdb
            }
        }
        return nil
    }

    // MARK: - Matching

    private struct Match {
        let simklID: Int
        let kind: Kind
    }

    private enum Kind {
        case movie, show, anime

        init(rawType: String?, fallbackIsSeries: Bool) {
            switch (rawType ?? "").lowercased() {
            case "movie": self = .movie
            case "anime": self = .anime
            case "show", "tv", "series": self = .show
            default: self = fallbackIsSeries ? .show : .movie
            }
        }

        var path: String {
            switch self {
            case .movie: return "movies"
            case .show: return "tv"
            case .anime: return "anime"
            }
        }

        var nuvioType: String {
            self == .movie ? "movie" : "series"
        }
    }

    private static func resolveMatch(for meta: NuvioMeta) async -> Match? {
        let series = isSeries(meta.type)
        var query: [URLQueryItem]
        if let imdb = imdbID(for: meta) {
            query = [URLQueryItem(name: "imdb", value: imdb)]
        } else if let tmdbId = meta.tmdbId, tmdbId > 0 {
            // `type` is only consulted for tmdb lookups, and "show" covers both
            // regular series and anime.
            query = [
                URLQueryItem(name: "tmdb", value: String(tmdbId)),
                URLQueryItem(name: "type", value: series ? "show" : "movie")
            ]
        } else {
            return nil
        }

        guard let results: [SimklSearchDTO] = await get(path: "search/id", queryItems: query),
              let first = results.first,
              let simklID = first.ids?.simkl else {
            return nil
        }
        return Match(simklID: simklID, kind: Kind(rawType: first.type, fallbackIsSeries: series))
    }

    private static func imdbID(for meta: NuvioMeta) -> String? {
        // Series ids arrive as "tt123:1:4" when the caller came from an episode.
        let candidate = meta.imdbId ?? String(meta.id.split(separator: ":").first ?? "")
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("tt") ? trimmed : nil
    }

    private static func isSeries(_ type: String) -> Bool {
        NuvioMeta.isSeriesType(type)
    }

    // MARK: - Transport

    private static func get<T: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async -> T? {
        do {
            let result: SimklHTTPResult<T> = try await client.get(
                path: path,
                clientID: SimklConfig.clientID,
                queryItems: queryItems
            )
            guard (200...299).contains(result.statusCode) else { return nil }
            // An unknown Simkl id answers `[]` rather than 404, which fails to
            // decode into the object shape and lands here as nil.
            return result.value
        } catch {
            return nil
        }
    }

    // MARK: - Images

    /// Simkl returns bare image path fragments ("20/2052598c2716ef054"). Their
    /// docs ask that clients go through wsrv.nl rather than hitting simkl.in
    /// directly, and `_m` is the 340px-wide variant that fits a poster card.
    fileprivate static func posterURL(from fragment: String?) -> String? {
        let value = fragment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }
        return "https://wsrv.nl/?url=https://simkl.in/posters/\(value)_m.webp"
    }

    /// Recommendation entries always state their own type ("movie", "show",
    /// "anime"); everything that isn't a movie opens as a series.
    fileprivate static func nuvioType(forRecommendation rawType: String?) -> String {
        (rawType ?? "").lowercased() == "movie" ? "movie" : "series"
    }
}

// MARK: - DTOs

private struct SimklSearchDTO: Decodable {
    let type: String?
    let ids: SimklDetailIDsDTO?
}

private struct SimklDetailIDsDTO: Decodable {
    let simkl: Int?
    let slug: String?
    let imdb: String?
}

private struct SimklDetailDTO: Decodable {
    let ids: SimklDetailIDsDTO?
    let rank: SimklFlexibleRank?
    let dropRate: String?
    let ratings: SimklRatingsDTO?
    let usersRecommendations: [SimklRecommendationDTO]?

    enum CodingKeys: String, CodingKey {
        case ids, rank, ratings
        case dropRate = "droprate"
        case usersRecommendations = "users_recommendations"
    }

    func toRatings() -> SimklTitleRatings {
        let simkl = ratings?.simkl
        let drop = dropRate?.trimmingCharacters(in: .whitespacesAndNewlines)
        return SimklTitleRatings(
            rating: simkl?.rating.flatMap { $0 > 0 ? $0 : nil },
            votes: simkl?.votes.flatMap { $0 > 0 ? $0 : nil },
            rank: rank?.value.flatMap { $0 > 0 ? $0 : nil },
            dropRate: (drop?.isEmpty ?? true) ? nil : drop
        )
    }

    func toRelated(limit: Int) -> [RelatedTitle] {
        (usersRecommendations ?? [])
            .compactMap { $0.toRelatedTitle() }
            .prefix(limit)
            .map { $0 }
    }
}

private struct SimklRatingsDTO: Decodable {
    let simkl: SimklRatingValueDTO?
}

private struct SimklRatingValueDTO: Decodable {
    let rating: Double?
    let votes: Int?
}

/// `rank` is a bare integer on the detail endpoints but an object on some
/// others, so accept either rather than dropping the whole record.
private struct SimklFlexibleRank: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if let number = try? single.decode(Int.self) {
                value = number
                return
            }
            if let text = try? single.decode(String.self), let number = Int(text) {
                value = number
                return
            }
        }
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self) {
            if let number = try? keyed.decode(Int.self, forKey: .value) {
                value = number
                return
            }
            if let text = try? keyed.decode(String.self, forKey: .value), let number = Int(text) {
                value = number
                return
            }
        }
        value = nil
    }

    private enum CodingKeys: String, CodingKey {
        case value
    }
}

private struct SimklRecommendationDTO: Decodable {
    let title: String?
    let year: Int?
    let poster: String?
    let type: String?
    let ids: SimklDetailIDsDTO?

    func toRelatedTitle() -> RelatedTitle? {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty, let simklID = ids?.simkl else { return nil }
        // Recommendations carry no external ids, so the card keeps Simkl's id
        // and `CatalogRepository` trades it for an IMDb id when it's opened.
        return RelatedTitle(
            id: "simkl:\(simklID)",
            type: SimklDetailsService.nuvioType(forRecommendation: type),
            name: name,
            posterURL: SimklDetailsService.posterURL(from: poster),
            year: year.map(String.init),
            rating: nil,
            overview: nil
        )
    }
}
