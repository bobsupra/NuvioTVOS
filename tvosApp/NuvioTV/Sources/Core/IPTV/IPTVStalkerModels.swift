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
    /// can silently send account identifiers to the wrong path.
    static func requestURL(portal: URL, type: String, action: String, extra: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(url: portal, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        components.queryItems = [URLQueryItem(name: "type", value: type), URLQueryItem(name: "action", value: action),
                                 URLQueryItem(name: "JsHttpRequest", value: "1-xml")] + extra
        return components.url
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
        struct Payload: Decodable { let data: [Lossy] }
        struct Envelope: Decodable { let js: Payload }
        guard let decoded = try? JSONDecoder().decode(Envelope.self, from: data) else { throw IPTVStalkerError.invalidResponse }
        var seen = Set<String>()
        let channels = decoded.js.data.compactMap(\.value).compactMap { entry -> IPTVStalkerChannel? in
            guard let id = entry.id.value, !id.isEmpty,
                  !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !entry.cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seen.insert(id).inserted else { return nil }
            return IPTVStalkerChannel(id: id, name: entry.name, command: entry.cmd, logo: entry.logo, categoryID: entry.category?.value)
        }
        return IPTVStalkerPage(channels: channels, rawCount: decoded.js.data.count)
    }
}
