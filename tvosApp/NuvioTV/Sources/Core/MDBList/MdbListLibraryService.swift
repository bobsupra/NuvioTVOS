import Foundation

@MainActor
enum MdbListLibraryService {
    static let mutationNotification = Notification.Name("nuvio.tv.mdblist.library.mutation")
    private static let maxLibraryItems = 200

    private struct Seed {
        let type: String
        let ids: [String: Any]
        let identity: String
        let title: String
        let year: Int?
        let poster: String?
        let backdrop: String?
        let addedAt: Date
    }

    static func fetchLibrary(
        repository: CatalogRepository,
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> [LibraryStoreItem]? {
        let scope = profileScope ?? MdbListRuntimeSession.profileScope()
        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: scope,
            tokenStorage: tokenStorage
        )
        var seeds: [Seed] = []
        var receivedResponse = false

        for path in ["/watchlist/items", "/sync/collection"] {
            var cursor: String?
            var seenCursors = Set<String>()
            while !Task.isCancelled {
                var query = [URLQueryItem(name: "limit", value: "1000")]
                if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                do {
                    let response = try await service.authorizedRequest(path: path, method: .get, queryItems: query)
                    guard (200..<300).contains(response.statusCode) else {
                        return receivedResponse
                            ? await resolve(
                                Array(deduplicated(seeds).prefix(maxLibraryItems)),
                                using: repository
                            )
                            : nil
                    }
                    receivedResponse = true
                    guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else { break }
                    seeds.append(contentsOf: parseSeeds(object, source: path))
                    guard let next = nextCursor(in: object),
                          !next.isEmpty,
                          seenCursors.insert(next).inserted else { break }
                    cursor = next
                } catch {
                    if !receivedResponse { return nil }
                    break
                }
            }
        }

        guard receivedResponse else { return nil }
        return await resolve(
            Array(deduplicated(seeds).prefix(maxLibraryItems)),
            using: repository
        )
    }

    static func setWatchlist(
        _ meta: NuvioMeta,
        isInWatchlist: Bool,
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool {
        guard let ids = ids(for: meta) else { return false }
        let bucket = meta.isSeries ? "shows" : "movies"
        let body: [String: Any] = [bucket: [["ids": ids]]]
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return false }

        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: profileScope ?? MdbListRuntimeSession.profileScope(),
            tokenStorage: tokenStorage
        )
        do {
            let response = try await service.authorizedRequest(
                path: isInWatchlist ? "/watchlist/items/add" : "/watchlist/items/remove",
                method: .post,
                body: data
            )
            guard (200..<300).contains(response.statusCode) else { return false }
            NotificationCenter.default.post(
                name: mutationNotification,
                object: MdbListLibraryMutation(meta: meta, isInWatchlist: isInWatchlist)
            )
            return true
        } catch {
            return false
        }
    }

    static func isInWatchlist(
        _ meta: NuvioMeta,
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> Bool? {
        guard let wantedIDs = ids(for: meta) else { return nil }
        let service = MdbListAuthService(
            client: client,
            store: store,
            profileScope: profileScope ?? MdbListRuntimeSession.profileScope(),
            tokenStorage: tokenStorage
        )
        var cursor: String?
        var seenCursors = Set<String>()
        do {
            while !Task.isCancelled {
                var query = [URLQueryItem(name: "limit", value: "1000")]
                if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
                let response = try await service.authorizedRequest(
                    path: "/watchlist/items",
                    method: .get,
                    queryItems: query
                )
                guard (200..<300).contains(response.statusCode),
                      let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
                    return nil
                }
                if parseSeeds(object, source: "/watchlist/items").contains(where: {
                    identifiersMatch($0.ids, wantedIDs)
                }) {
                    return true
                }
                guard let next = nextCursor(in: object),
                      !next.isEmpty,
                      seenCursors.insert(next).inserted else { return false }
                cursor = next
            }
            return false
        } catch {
            return nil
        }
    }

    private static func parseSeeds(_ object: [String: Any], source: String) -> [Seed] {
        [
            ("movies", "movie"),
            ("shows", "series")
        ].flatMap { bucket, type in
            (object[bucket] as? [[String: Any]] ?? []).compactMap { row in
                seed(from: row, type: type, source: source)
            }
        }
    }

    private static func seed(from row: [String: Any], type: String, source: String) -> Seed? {
        var ids = (row["ids"] as? [String: Any]) ?? row
        if ids["imdb"] == nil { ids["imdb"] = row["imdb_id"] }
        if ids["tmdb"] == nil { ids["tmdb"] = row["tmdb_id"] }
        if ids["trakt"] == nil { ids["trakt"] = row["trakt_id"] }
        if ids["tvdb"] == nil { ids["tvdb"] = row["tvdb_id"] }
        guard let identity = identity(for: ids) else { return nil }
        let title = string(row["title"] ?? row["name"]) ?? identity
        let date = date(row["added_at"] ?? row["listed_at"] ?? row["collected_at"] ?? row["addedAt"] ?? row["listedAt"] ?? row["collectedAt"])
            ?? .distantPast
        return Seed(
            type: type,
            ids: ids,
            identity: "\(type):\(identity)",
            title: title,
            year: integer(row["year"] ?? row["release_year"]),
            poster: string(row["poster"]),
            backdrop: string(row["backdrop"] ?? row["background"]),
            addedAt: date
        )
    }

    private static func resolve(_ seeds: [Seed], using repository: CatalogRepository) async -> [LibraryStoreItem] {
        var result: [LibraryStoreItem] = []
        for seed in seeds where !Task.isCancelled {
            let lookupID = lookupID(for: seed.ids) ?? seed.identity
            let meta = (try? await repository.getMetadata(id: lookupID, type: seed.type)) ?? placeholder(for: seed)
            result.append(LibraryStoreItem(meta: meta, addedAt: seed.addedAt))
        }
        return result
    }

    private static func deduplicated(_ seeds: [Seed]) -> [Seed] {
        var unique: [String: Seed] = [:]
        for seed in seeds {
            if let existing = unique[seed.identity] {
                if seed.addedAt > existing.addedAt { unique[seed.identity] = seed }
            } else {
                unique[seed.identity] = seed
            }
        }
        return unique.values.sorted { $0.addedAt > $1.addedAt }
    }

    private static func ids(for meta: NuvioMeta) -> [String: Any]? {
        let first = meta.id.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased()
        let value = meta.id.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
        var ids: [String: Any] = [:]
        if let imdb = NuvioMeta.canonicalImdbID(from: meta.imdbId ?? (first == "imdb" ? value ?? meta.id : meta.id)) { ids["imdb"] = imdb }
        if let tmdb = meta.tmdbId ?? (first == "tmdb" ? Int(value ?? "") : nil) { ids["tmdb"] = tmdb }
        if let trakt = first == "trakt" ? Int(value ?? "") : nil { ids["trakt"] = trakt }
        if let tvdb = first == "tvdb" ? Int(value ?? "") : nil { ids["tvdb"] = tvdb }
        if let mdblist = first == "mdblist" ? value : nil, !mdblist.isEmpty { ids["mdblist"] = mdblist }
        return ids.isEmpty ? nil : ids
    }

    private static func identity(for ids: [String: Any]) -> String? {
        if let value = string(ids["imdb"]).flatMap({ NuvioMeta.canonicalImdbID(from: $0) }) { return "imdb:\(value)" }
        for key in ["tmdb", "trakt", "tvdb", "mdblist"] {
            if let value = string(ids[key]) ?? (ids[key] as? NSNumber)?.stringValue, !value.isEmpty { return "\(key):\(value)" }
        }
        return nil
    }

    private static func identifiersMatch(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        ["imdb", "tmdb", "trakt", "tvdb", "mdblist"].contains { key in
            guard let left = string(lhs[key]), let right = string(rhs[key]) else { return false }
            if key == "imdb" {
                return NuvioMeta.canonicalImdbID(from: left)
                    == NuvioMeta.canonicalImdbID(from: right)
            }
            return left == right
        }
    }

    private static func lookupID(for ids: [String: Any]) -> String? {
        guard let identity = identity(for: ids) else { return nil }
        return identity.hasPrefix("imdb:") ? String(identity.dropFirst(5)) : identity
    }

    private static func nextCursor(in object: [String: Any]) -> String? {
        let pagination = object["pagination"] as? [String: Any]
        return string(pagination?["next_cursor"] ?? object["next_cursor"])
    }

    private static func placeholder(for seed: Seed) -> NuvioMeta {
        NuvioMeta(id: lookupID(for: seed.ids) ?? seed.identity, name: seed.title, description: nil, posterUrl: seed.poster, backgroundUrl: seed.backdrop, logoUrl: nil, imdbId: string(seed.ids["imdb"]), tmdbId: integer(seed.ids["tmdb"]), type: seed.type, year: seed.year, genres: nil, rating: nil, releaseInfo: seed.year.map(String.init), runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
    }

    private static func string(_ value: Any?) -> String? { (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? (value as? NSNumber)?.stringValue }
    private static func integer(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init) }
    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue) }
        guard let value = string(value) else { return nil }
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

struct MdbListLibraryMutation {
    let meta: NuvioMeta
    let isInWatchlist: Bool
}
