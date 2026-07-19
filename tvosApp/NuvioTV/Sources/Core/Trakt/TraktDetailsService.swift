import Foundation

/// A Trakt review/comment shown on the details page.
struct TraktCommentReview: Identifiable, Equatable {
    let id: Int64
    let author: String
    let comment: String
    let likes: Int
    let spoiler: Bool
    let rating: Int?
    let createdAt: String?

    var displayDate: String? {
        guard let createdAt else { return nil }
        // "2024-03-12T18:22:00.000Z" → short local date
        let prefix = String(createdAt.prefix(10))
        return NuvioDateDisplay.formattedDate(prefix) ?? prefix
    }
}

/// Trakt comments + related titles for the details page.
/// Uses the Nuvio Trakt proxy (client id stays server-side) when the user is linked.
enum TraktDetailsService {
    private static let pageLimit = 5

    static var isAuthenticated: Bool {
        TraktAuthStore.state.isAuthenticated
    }

    static var commentsEnabled: Bool {
        TraktSettingsStore.showMetaComments
    }

    /// Top liked comments (up to 5). Empty when Trakt is off / unlinked / unavailable.
    static func fetchTopComments(for meta: NuvioMeta) async -> [TraktCommentReview] {
        guard isAuthenticated, commentsEnabled else { return [] }
        guard let path = await resolvePath(for: meta) else { return [] }
        let route = "\(path.endpoint)/\(path.pathId)/comments/likes?page=1&limit=\(pageLimit)"
        guard let data = await proxyGET(route: route) else { return [] }

        guard let dtos = try? JSONDecoder().decode([TraktCommentDTO].self, from: data) else {
            return []
        }
        return dtos.compactMap { $0.toReview() }.prefix(pageLimit).map { $0 }
    }

    /// Related titles from Trakt (when More Like This source is Trakt).
    static func fetchRelated(for meta: NuvioMeta, limit: Int = 16) async -> [RelatedTitle] {
        guard isAuthenticated else { return [] }
        guard TraktSettingsStore.moreLikeThisSource == .trakt else { return [] }
        guard let path = await resolvePath(for: meta) else { return [] }
        let route = "\(path.endpoint)/\(path.pathId)/related?extended=full,images"
        guard let data = await proxyGET(route: route) else { return [] }

        if path.endpoint == "movies",
           let movies = try? JSONDecoder().decode([TraktRelatedMovieDTO].self, from: data) {
            return movies.compactMap { $0.toRelatedTitle() }.prefix(limit).map { $0 }
        }
        if path.endpoint == "shows",
           let shows = try? JSONDecoder().decode([TraktRelatedShowDTO].self, from: data) {
            return shows.compactMap { $0.toRelatedTitle() }.prefix(limit).map { $0 }
        }
        return []
    }

    // MARK: - Path resolution

    private struct Path {
        let endpoint: String
        let pathId: String
    }

    private static func resolvePath(for meta: NuvioMeta) async -> Path? {
        let endpoint = isSeries(meta.type) ? "shows" : "movies"
        if let imdb = meta.imdbId ?? (meta.id.hasPrefix("tt")
            ? String(meta.id.split(separator: ":").first ?? Substring(meta.id))
            : nil),
           imdb.hasPrefix("tt") {
            return Path(endpoint: endpoint, pathId: imdb)
        }
        if let tmdbId = meta.tmdbId, tmdbId > 0 {
            if let imdb = await searchImdbViaTrakt(tmdbId: tmdbId, type: isSeries(meta.type) ? "show" : "movie") {
                return Path(endpoint: endpoint, pathId: imdb)
            }
            // Trakt also accepts tmdb ids via search result slug; fall back to tmdb search id.
            if let slug = await searchSlugViaTrakt(tmdbId: tmdbId, type: isSeries(meta.type) ? "show" : "movie") {
                return Path(endpoint: endpoint, pathId: slug)
            }
        }
        return nil
    }

    private static func isSeries(_ type: String) -> Bool {
        ["series", "show", "tv", "tvshow"].contains(type.lowercased())
    }

    private static func searchImdbViaTrakt(tmdbId: Int, type: String) async -> String? {
        let route = "search/tmdb/\(tmdbId)?type=\(type)"
        guard let data = await proxyGET(route: route),
              let results = try? JSONDecoder().decode([TraktSearchResultDTO].self, from: data) else {
            return nil
        }
        for result in results {
            if type == "movie", let imdb = result.movie?.ids?.imdb, imdb.hasPrefix("tt") {
                return imdb
            }
            if type == "show", let imdb = result.show?.ids?.imdb, imdb.hasPrefix("tt") {
                return imdb
            }
        }
        return nil
    }

    private static func searchSlugViaTrakt(tmdbId: Int, type: String) async -> String? {
        let route = "search/tmdb/\(tmdbId)?type=\(type)"
        guard let data = await proxyGET(route: route),
              let results = try? JSONDecoder().decode([TraktSearchResultDTO].self, from: data) else {
            return nil
        }
        for result in results {
            if type == "movie", let slug = result.movie?.ids?.slug, !slug.isEmpty { return slug }
            if type == "show", let slug = result.show?.ids?.slug, !slug.isEmpty { return slug }
        }
        return nil
    }

    // MARK: - Proxy

    private static func proxyGET(route: String) async -> Data? {
        guard TraktConfig.proxyConfigured else { return nil }
        guard let token = TraktAuthStore.state.accessToken, !token.isEmpty else { return nil }

        let base = TraktConfig.proxyURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/\(route)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Trakt-Access-Token")
        request.setValue(AuthConfig.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(AuthConfig.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return data
        } catch {
            return nil
        }
    }
}

// MARK: - DTOs

private struct TraktCommentDTO: Decodable {
    let id: Int64?
    let comment: String?
    let spoiler: Bool?
    let likes: Int?
    let createdAt: String?
    let user: TraktCommentUserDTO?
    let userStats: TraktCommentUserStatsDTO?

    enum CodingKeys: String, CodingKey {
        case id, comment, spoiler, likes
        case createdAt = "created_at"
        case user
        case userStats = "user_stats"
    }

    func toReview() -> TraktCommentReview? {
        let text = comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let id, !text.isEmpty else { return nil }
        let author = user?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? user?.username?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "Trakt user"
        return TraktCommentReview(
            id: id,
            author: author,
            comment: text,
            likes: likes ?? 0,
            spoiler: spoiler ?? false,
            rating: userStats?.rating,
            createdAt: createdAt
        )
    }
}

private struct TraktCommentUserDTO: Decodable {
    let username: String?
    let name: String?
}

private struct TraktCommentUserStatsDTO: Decodable {
    let rating: Int?
}

private struct TraktSearchResultDTO: Decodable {
    let movie: TraktIdContainer?
    let show: TraktIdContainer?
}

private struct TraktIdContainer: Decodable {
    let ids: TraktIdsDTO?
}

private struct TraktIdsDTO: Decodable {
    let imdb: String?
    let slug: String?
    let tmdb: Int?
}

private struct TraktRelatedMovieDTO: Decodable {
    let title: String?
    let year: Int?
    let overview: String?
    let ids: TraktIdsDTO?
    let images: TraktImagesDTO?

    func toRelatedTitle() -> RelatedTitle? {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let id = ids?.imdb.flatMap { $0.hasPrefix("tt") ? $0 : nil }
            ?? ids?.tmdb.map { "tmdb:\($0)" }
            ?? ids?.slug.map { "trakt:\($0)" }
        guard let id else { return nil }
        return RelatedTitle(
            id: id,
            type: "movie",
            name: name,
            posterURL: images?.poster?.first ?? images?.fanart?.first,
            year: year.map(String.init),
            rating: nil,
            overview: overview
        )
    }
}

private struct TraktRelatedShowDTO: Decodable {
    let title: String?
    let year: Int?
    let overview: String?
    let ids: TraktIdsDTO?
    let images: TraktImagesDTO?

    func toRelatedTitle() -> RelatedTitle? {
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let id = ids?.imdb.flatMap { $0.hasPrefix("tt") ? $0 : nil }
            ?? ids?.tmdb.map { "tmdb:\($0)" }
            ?? ids?.slug.map { "trakt:\($0)" }
        guard let id else { return nil }
        return RelatedTitle(
            id: id,
            type: "series",
            name: name,
            posterURL: images?.poster?.first ?? images?.fanart?.first,
            year: year.map(String.init),
            rating: nil,
            overview: overview
        )
    }
}

private struct TraktImagesDTO: Decodable {
    let poster: [String]?
    let fanart: [String]?
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
