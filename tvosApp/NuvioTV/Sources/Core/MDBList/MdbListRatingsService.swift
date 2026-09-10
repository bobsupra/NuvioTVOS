import Foundation

/// A user's MDBList rating and the provider identity used to address it.
struct MdbListUserRating: Equatable, Hashable {
    let contentID: String
    let type: String
    let rating: Int
    let ratedAt: Date?
    let season: Int?
    let episode: Int?
    let providerIDs: [String: String]

    /// Alias useful to callers that use the persisted content-identity term.
    var identity: String { contentID }
}

@MainActor
enum MdbListRatingsService {
    static let changedNotification = Notification.Name("nuvio.tv.mdblist.ratings.changed")
    private static let cacheLifetime: TimeInterval = 300
    private struct RatingSnapshot {
        let values: [MdbListUserRating]
        let fetchedAt: Date
    }
    private static var cachedSnapshots: [String: RatingSnapshot] = [:]

    static func fetchRatings(
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> [MdbListUserRating]? {
        let scope = profileScope ?? MdbListRuntimeSession.profileScope()
        let cacheKey = self.cacheKey(store: store, scope: scope)
        if let cached = cachedSnapshots[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < cacheLifetime {
            return cached.values
        }
        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: scope,
            tokenStorage: tokenStorage
        )
        var query = [URLQueryItem(name: "limit", value: "1000")]
        var cursors = Set<String>()
        var result: [MdbListUserRating] = []

        do {
            for _ in 0..<1_000 {
                let response = try await service.authorizedRequest(
                    path: "/sync/ratings", method: .get, queryItems: query
                )
                guard (200..<300).contains(response.statusCode),
                      let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
                else { return nil }

                result.append(contentsOf: parseRatings(from: object))
                guard let pagination = object["pagination"] as? [String: Any],
                      let cursor = string(pagination["next_cursor"]), !cursor.isEmpty else {
                    cachedSnapshots[cacheKey] = RatingSnapshot(values: result, fetchedAt: Date())
                    return result
                }
                guard cursors.insert(cursor).inserted else { return nil }
                query = [
                    URLQueryItem(name: "limit", value: "1000"),
                    URLQueryItem(name: "cursor", value: cursor)
                ]
            }
            return nil
        } catch {
            return nil
        }
    }

    static func fetchRating(
        for meta: NuvioMeta,
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Int? {
        guard let ratings = await fetchRatings(
            store: store,
            client: client,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ),
              let ids = providerIDs(for: meta) else { return nil }
        return ratings.first { rating in
            ids.contains { key, value in
                guard let expected = string(value),
                      let actual = rating.providerIDs[key] else { return false }
                if key == "imdb" {
                    return NuvioMeta.canonicalImdbID(from: expected)
                        == NuvioMeta.canonicalImdbID(from: actual)
                }
                return expected == actual
            }
        }?.rating
    }

    static func invalidate(
        store: UserDefaults = ProfileSettings.current,
        profileScope: String? = nil
    ) {
        let scope = profileScope ?? MdbListRuntimeSession.profileScope()
        let prefix = "\(ObjectIdentifier(store)):\(scope):"
        cachedSnapshots.keys
            .filter { $0.hasPrefix(prefix) }
            .forEach { cachedSnapshots.removeValue(forKey: $0) }
    }

    static func setRating(
        _ meta: NuvioMeta,
        rating: Int?,
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        guard rating == nil || (rating! >= 1 && rating! <= 10),
              !isEpisode(meta.type),
              let ids = providerIDs(for: meta) else { return false }

        let isShow = meta.isSeries
        let key = isShow ? "shows" : "movies"
        var item: [String: Any] = ["ids": ids]
        if let rating { item["rating"] = rating }
        let body: [String: Any] = [key: [item]]
        let path = rating == nil ? "/sync/ratings/remove" : "/sync/ratings"
        let scope = profileScope ?? MdbListRuntimeSession.profileScope()
        let cacheKey = self.cacheKey(store: store, scope: scope)
        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: scope,
            tokenStorage: tokenStorage
        )

        do {
            let response = try await service.authorizedRequest(
                path: path, method: .post, body: try jsonData(body)
            )
            guard (200..<300).contains(response.statusCode) else { return false }
            cachedSnapshots.removeValue(forKey: cacheKey)
            NotificationCenter.default.post(name: changedNotification, object: nil)
            return true
        } catch {
            return false
        }
    }

    private static func parseRatings(from object: [String: Any]) -> [MdbListUserRating] {
        var ratings: [MdbListUserRating] = []
        for (key, type) in [("movies", "movie"), ("shows", "show")] {
            guard let rows = object[key] as? [Any] else { continue }
            for row in rows {
                guard let item = row as? [String: Any],
                      let rating = integer(item["rating"]), rating >= 0, rating <= 10,
                      let ids = providerIDs(from: item["ids"]),
                      let identity = identity(from: ids) else { continue }
                ratings.append(MdbListUserRating(
                    contentID: identity, type: type, rating: rating,
                    ratedAt: date(item["rated_at"] ?? item["ratedAt"]),
                    season: integer(item["season"]), episode: integer(item["episode"]),
                    providerIDs: ids
                ))
            }
        }
        return ratings
    }

    private static func cacheKey(store: UserDefaults, scope: String) -> String {
        let accountID = MdbListAuthStore.state(
            in: store,
            profileScope: scope
        ).accountID ?? ""
        return "\(ObjectIdentifier(store)):\(scope):\(accountID)"
    }

    private static func providerIDs(for meta: NuvioMeta) -> [String: Any]? {
        var ids: [String: Any] = [:]
        let prefix = meta.id.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased()
        let value = meta.id.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
        let imdbCandidate: String? = {
            if let imdb = meta.imdbId { return imdb }
            if prefix == "imdb" { return value }
            if prefix?.hasPrefix("tt") == true { return meta.id }
            return nil
        }()
        if let imdbCandidate,
           let imdb = NuvioMeta.canonicalImdbID(from: imdbCandidate) {
            ids["imdb"] = imdb
        }
        if let tmdb = meta.tmdbId ?? (prefix == "tmdb" ? Int(value ?? "") : nil), tmdb > 0 { ids["tmdb"] = tmdb }
        if prefix == "trakt", let value, let id = Int(value), id > 0 { ids["trakt"] = id }
        if prefix == "tvdb", let value, let id = Int(value), id > 0 { ids["tvdb"] = id }
        if prefix == "mdblist", let value, !value.isEmpty { ids["mdblist"] = value }
        return ids.isEmpty ? nil : ids
    }

    private static func providerIDs(from value: Any?) -> [String: String]? {
        guard let raw = value as? [String: Any] else { return nil }
        var ids: [String: String] = [:]
        for key in ["imdb", "tmdb", "trakt", "tvdb", "mdblist"] {
            if let value = string(raw[key]), !value.isEmpty {
                ids[key] = key == "imdb" ? (NuvioMeta.canonicalImdbID(from: value) ?? value) : value
            }
        }
        return ids.isEmpty ? nil : ids
    }

    private static func identity(from ids: [String: String]) -> String? {
        if let imdb = ids["imdb"] { return NuvioMeta.canonicalImdbID(from: imdb) ?? imdb }
        for key in ["tmdb", "trakt", "tvdb", "mdblist"] where ids[key] != nil {
            return "\(key):\(ids[key]!)"
        }
        return nil
    }

    private static func isEpisode(_ type: String) -> Bool {
        ["episode", "episodes", "tv_episode", "tv-episode"].contains(type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        guard let value = string(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)
    }

    private static func jsonData(_ object: [String: Any]) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else { throw MdbListServiceError.message("Invalid MDBList request body.") }
        return try JSONSerialization.data(withJSONObject: object)
    }
}
