import Foundation

/// Stalker channels require a portal call to obtain a playback URL. `command`
/// and the portal response can contain account information: never log either.
struct IPTVStalkerChannel: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let command: String
    let logo: String?
    let categoryID: String?
    var categoryName: String? = nil
}

struct IPTVStalkerPage {
    let channels: [IPTVStalkerChannel]
    let rawCount: Int
    let totalItems: Int?
    let lastPage: Int?
}

struct IPTVStalkerPagination {
    private(set) var rawRowsReceived = 0
    private(set) var totalItems: Int?
    private(set) var lastPage: Int?

    mutating func didLoad(_ page: IPTVStalkerPage, number pageNumber: Int) -> Bool {
        let (updatedCount, overflow) = rawRowsReceived.addingReportingOverflow(page.rawCount)
        rawRowsReceived = overflow ? Int.max : updatedCount
        if let totalItems = page.totalItems, totalItems > 0 { self.totalItems = totalItems }
        if let lastPage = page.lastPage { self.lastPage = lastPage }

        if let totalItems { return rawRowsReceived >= totalItems }
        return lastPage.map { pageNumber >= $0 } ?? false
    }
}

enum IPTVStalkerError: Error, Equatable {
    case invalidPortal
    case invalidMAC
    case invalidResponse
    case httpStatus(Int)
    case tooLarge
}

enum IPTVStalkerProtocol {
    /// Accepts common MAC spellings and returns the canonical portal form.
    static func normalizedMAC(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let hex = text.filter { $0 != ":" && $0 != "-" }
        guard hex.utf8.count == 12,
              hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        let chars = Array(hex)
        return stride(from: 0, to: 12, by: 2).map { String(chars[$0...$0 + 1]) }.joined(separator: ":")
    }

    /// The user provides the portal endpoint explicitly; guessing an endpoint
    /// can silently send account identifiers to the wrong path. Only the
    /// common client landing paths are translated to the API endpoint.
    static func requestURL(portal: URL, type: String, action: String, extra: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(url: portal, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        if let endpointPath = clientEndpointPaths(components.percentEncodedPath).first {
            components.percentEncodedPath = endpointPath
        }
        components.queryItems = [URLQueryItem(name: "type", value: type), URLQueryItem(name: "action", value: action),
                                 URLQueryItem(name: "JsHttpRequest", value: "1-xml")] + extra
        return components.url
    }

    static func portalEndpoints(for portal: URL) -> [URL] {
        guard let components = URLComponents(url: portal, resolvingAgainstBaseURL: false) else { return [portal] }
        let paths = clientEndpointPaths(components.percentEncodedPath)
        guard !paths.isEmpty else { return [portal] }
        return paths.compactMap { path in
            var endpoint = components
            endpoint.percentEncodedPath = path
            return endpoint.url
        }
    }

    static func shouldTryHandshakeFallback(after error: Error) -> Bool {
        if error is IPTVStalkerError, let stalkerError = error as? IPTVStalkerError {
            switch stalkerError {
            case .invalidResponse, .httpStatus(404): return true
            default: return false
            }
        }
        return false
    }

    private static func clientEndpointPaths(_ path: String) -> [String] {
        let lowercasedPath = path.lowercased()
        for suffix in ["/c/index.html", "/c/", "/c"] where lowercasedPath.hasSuffix(suffix) {
            let prefix = String(path.dropLast(suffix.count))
            return [prefix + "/server/load.php", prefix + "/c/portal.php", prefix + "/portal.php"]
        }
        return []
    }

    static func handshakeToken(from data: Data) throws -> String {
        struct Response: Decodable {
            struct Payload: Decodable {
                let token: String?
                let legacyToken: String?
                enum CodingKeys: String, CodingKey { case token, legacyToken = "Token" }
            }
            let js: Payload
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let token = [response.js.token, response.js.legacyToken].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            throw IPTVStalkerError.invalidResponse
        }
        return token
    }

    static func playbackURL(from data: Data) throws -> URL {
        struct Response: Decodable { struct Payload: Decodable { let cmd: String }; let js: Payload }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let token = response.js.cmd.split(whereSeparator: { $0.isWhitespace }).last,
              let url = URL(string: String(token)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { throw IPTVStalkerError.invalidResponse }
        return url
    }

    static func categoryNames(from data: Data) throws -> [String: String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["js"] else { throw IPTVStalkerError.invalidResponse }
        let rows = (payload as? [[String: Any]]) ?? ((payload as? [String: Any])?["data"] as? [[String: Any]])
        guard let rows else { throw IPTVStalkerError.invalidResponse }
        var categories: [String: String] = [:]
        for row in rows {
            let id: String?
            if let string = row["id"] as? String { id = string }
            else if let number = row["id"] as? Int { id = String(number) }
            else { id = nil }
            let name = ((row["title"] as? String) ?? (row["name"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id, !id.isEmpty, let name, !name.isEmpty { categories[id] = name }
        }
        return categories
    }

    static func channels(from data: Data) throws -> [IPTVStalkerChannel] {
        try page(from: data).channels
    }

    static func page(from data: Data) throws -> IPTVStalkerPage {
        struct FlexibleID: Decodable {
            let value: String?
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) { value = String(number) }
                else { value = try? container.decode(String.self) }
            }
        }
        struct Entry: Decodable {
            let id: FlexibleID
            let name: String
            let cmd: String
            let logo: String?
            let category: FlexibleID?
            enum CodingKeys: String, CodingKey { case id, name, cmd, logo, category = "tv_genre_id" }
        }
        struct Lossy: Decodable {
            let value: Entry?
            init(from decoder: Decoder) throws { value = try? Entry(from: decoder) }
        }
        struct FlexibleInt: Decodable {
            let value: Int?
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let number = try? container.decode(Int.self) { value = number }
                else if let text = try? container.decode(String.self) { value = Int(text) }
                else { value = nil }
            }
        }
        struct BoundedRows: Decodable {
            let values: [Lossy]

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var values: [Lossy] = []
                while !container.isAtEnd {
                    guard values.count < IPTVImportLimits.maximumChannels else { throw IPTVStalkerError.tooLarge }
                    values.append(try container.decode(Lossy.self))
                    if values.count.isMultiple(of: 512) { try Task.checkCancellation() }
                }
                self.values = values
            }
        }
        struct Payload: Decodable {
            let data: BoundedRows
            let totalItems: FlexibleInt?
            let totalPages: FlexibleInt?
            enum CodingKeys: String, CodingKey {
                case data
                case totalItems = "total_items"
                case totalPages = "total_pages"
            }

            var lastPage: Int? {
                if let totalPages = totalPages?.value, totalPages > 0 { return totalPages }
                return nil
            }
        }
        struct Envelope: Decodable { let js: Payload }
        let decoded: Envelope
        do {
            decoded = try JSONDecoder().decode(Envelope.self, from: data)
        } catch let error as IPTVStalkerError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IPTVStalkerError.invalidResponse
        }
        var seen = Set<String>()
        var channels: [IPTVStalkerChannel] = []
        channels.reserveCapacity(decoded.js.data.values.count)
        for (index, lossy) in decoded.js.data.values.enumerated() {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            guard let entry = lossy.value,
                  let id = entry.id.value, !id.isEmpty,
                  !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(id).inserted else { continue }
            channels.append(IPTVStalkerChannel(id: id, name: entry.name, command: entry.cmd,
                                               logo: entry.logo, categoryID: entry.category?.value))
        }
        try Task.checkCancellation()
        return IPTVStalkerPage(channels: channels, rawCount: decoded.js.data.values.count,
                               totalItems: decoded.js.totalItems?.value, lastPage: decoded.js.lastPage)
    }
}
