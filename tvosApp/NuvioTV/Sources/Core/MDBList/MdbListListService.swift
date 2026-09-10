import Foundation

struct MdbListUserList: Identifiable, Equatable {
    let id: Int
    let name: String
    let slug: String?
    let itemCount: Int
}

struct MdbListListItem: Equatable {
    let meta: NuvioMeta
    let addedAt: Date
}

/// Loads the authenticated user's MDBList lists.  MDBList has returned a few
/// different envelopes for these endpoints over time, so parsing deliberately
/// uses JSONSerialization and accepts both the documented and legacy shapes.
@MainActor
enum MdbListListService {
    private static let pageSize = 1000

    static func fetchUserLists(
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> [MdbListUserList]? {
        let auth = MdbListAuthService(
            client: client,
            store: store,
            profileScope: profileScope ?? ProfileSettings.activeProfileScope,
            tokenStorage: tokenStorage
        )
        var cursor: String?
        var seenCursors = Set<String>()
        var result: [MdbListUserList] = []

        do {
            repeat {
                let response = try await auth.authorizedRequest(
                    path: "/lists/user",
                    method: .get,
                    queryItems: query(cursor: cursor)
                )
                guard (200..<300).contains(response.statusCode),
                      let root = try? JSONSerialization.jsonObject(with: response.data) else { return nil }
                let values = array(in: root, keys: ["lists", "data", "results", "items"]) ?? (root as? [[String: Any]]) ?? []
                result.append(contentsOf: values.compactMap(parseList))
                let next = nextCursor(in: root)
                guard let next, !next.isEmpty, seenCursors.insert(next).inserted else { break }
                cursor = next
            } while true
            return result
        } catch {
            return nil
        }
    }

    static func fetchItems(
        listID: Int,
        repository: CatalogRepository,
        store: UserDefaults = ProfileSettings.current,
        client: MdbListAPIClient = MdbListAPIClient(),
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) async -> [LibraryStoreItem]? {
        let auth = MdbListAuthService(
            client: client,
            store: store,
            profileScope: profileScope ?? ProfileSettings.activeProfileScope,
            tokenStorage: tokenStorage
        )
        var cursor: String?
        var seenCursors = Set<String>()
        var rawItems: [(object: [String: Any], type: String)] = []

        do {
            repeat {
                let response = try await auth.authorizedRequest(
                    path: "/lists/\(listID)/items",
                    method: .get,
                    queryItems: query(cursor: cursor)
                )
                guard (200..<300).contains(response.statusCode),
                      let root = try? JSONSerialization.jsonObject(with: response.data) else { return nil }
                let buckets: [(String, String)] = [("movies", "movie"), ("movie", "movie"), ("shows", "series"), ("series", "series"), ("tv", "series")]
                var foundBucket = false
                for (key, type) in buckets {
                    if let entries = array(in: root, keys: [key]) {
                        foundBucket = true
                        rawItems.append(contentsOf: entries.map { ($0, type) })
                    }
                }
                if !foundBucket {
                    let values = array(in: root, keys: ["items", "data", "results"]) ?? (root as? [[String: Any]]) ?? []
                    rawItems.append(contentsOf: values.map { ($0, inferredType($0)) })
                }
                let next = nextCursor(in: root)
                guard let next, !next.isEmpty, seenCursors.insert(next).inserted else { break }
                cursor = next
            } while true
        } catch {
            return nil
        }

        var result: [LibraryStoreItem] = []
        for entry in rawItems {
            let id = providerID(entry.object)
            guard let id else { continue }
            let date = date(entry.object) ?? .distantPast
            let meta: NuvioMeta
            do {
                meta = try await repository.getMetadata(id: id.value, type: entry.type)
            } catch {
                meta = placeholder(id: id.value, type: entry.type, object: entry.object)
            }
            result.append(LibraryStoreItem(meta: meta, addedAt: date))
        }
        return result
    }

    private static func query(cursor: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: "limit", value: String(pageSize))]
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        return items
    }

    private static func parseList(_ object: [String: Any]) -> MdbListUserList? {
        guard let id = integer(object["id"] ?? object["list_id"]) else { return nil }
        let name = string(object["name"] ?? object["title"]) ?? "MDBList \(id)"
        return MdbListUserList(
            id: id,
            name: name,
            slug: string(object["slug"]),
            itemCount: integer(
                object["item_count"]
                    ?? object["itemCount"]
                    ?? object["count"]
                    ?? object["items_count"]
                    ?? object["items"]
            ) ?? 0
        )
    }

    private static func array(in value: Any, keys: [String]) -> [[String: Any]]? {
        if let object = value as? [String: Any] {
            for key in keys { if let array = object[key] as? [[String: Any]] { return array } }
        }
        return nil
    }

    private static func nextCursor(in value: Any) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        for key in ["next_cursor", "nextCursor", "next", "cursor_next"] {
            if let value = string(object[key]), !value.isEmpty { return value }
        }
        if let pagination = object["pagination"] as? [String: Any] {
            return nextCursor(in: pagination)
        }
        return nil
    }

    private static func providerID(_ object: [String: Any]) -> (value: String, provider: String)? {
        let ids = (object["ids"] as? [String: Any]) ?? (object["provider_ids"] as? [String: Any]) ?? [:]
        for provider in ["imdb", "tmdb", "trakt", "tvdb", "mdblist"] {
            let value = string(ids[provider]) ?? string(object["\(provider)_id"])
            guard let value, !value.isEmpty else { continue }
            let normalized = provider == "imdb" ? (NuvioMeta.canonicalImdbID(from: value) ?? value) : "\(provider):\(value)"
            return (normalized, provider)
        }
        if let value = string(object["id"]) { return (value, "") }
        return nil
    }

    private static func inferredType(_ object: [String: Any]) -> String {
        let raw = string(object["type"] ?? object["media_type"] ?? object["mediatype"])?.lowercased() ?? "movie"
        return NuvioMeta.isSeriesType(raw) || raw == "tv" ? "series" : "movie"
    }

    private static func placeholder(id: String, type: String, object: [String: Any]) -> NuvioMeta {
        let title = string(object["title"] ?? object["name"] ?? object["original_title"] ?? object["original_name"]) ?? id
        let year = integer(object["year"])
        let ids = providerID(object)
        return NuvioMeta(id: id, name: title, description: nil, posterUrl: string(object["poster"] ?? object["poster_url"]), backgroundUrl: string(object["backdrop"] ?? object["backdrop_url"]), logoUrl: nil, imdbId: ids?.provider == "imdb" ? id : nil, tmdbId: ids?.provider == "tmdb" ? integer(ids?.value.replacingOccurrences(of: "tmdb:", with: "")) : nil, type: type, year: year, genres: nil, rating: nil, releaseInfo: year.map(String.init), runtime: nil, cast: nil, director: nil, writer: nil, certification: nil, country: nil, released: nil, status: nil, videos: nil, trailerYtIds: nil, externalRatings: nil)
    }

    private static func date(_ object: [String: Any]) -> Date? {
        let value = object["added_at"] ?? object["addedAt"] ?? object["listed_at"] ?? object["listedAt"] ?? object["created_at"] ?? object["date_added"] ?? object["added"]
        if let number = value as? NSNumber { return Date(timeIntervalSince1970: number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue) }
        guard let text = string(value) else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = string(value) { return Int(value) }
        return nil
    }
}
