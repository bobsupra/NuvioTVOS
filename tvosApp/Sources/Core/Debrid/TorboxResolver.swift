import Foundation

/// Resolves a torrent through TorBox: create the (cached-only) torrent, read its
/// file list, then request a direct download link for the chosen file. Mirrors
/// the Android `TorboxDirectDebridResolver`.
struct TorboxResolver: DebridProvider {
    let kind: DebridProviderKind = .torbox

    private let base = URL(string: "https://api.torbox.app")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(_ request: DebridRequest, apiKey: String) async -> DebridResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingApiKey }

        do {
            // 1. Create the torrent, cached-only so we fail fast when it isn't.
            let createReq = multipartRequest(
                "v1/api/torrents/createtorrent", key: key,
                fields: ["magnet": request.magnetURI, "add_only_if_cached": "true", "allow_zip": "false"]
            )
            let (createData, createResp) = try await session.data(for: createReq)
            guard let createHTTP = createResp as? HTTPURLResponse else { return .error }
            guard 200..<300 ~= createHTTP.statusCode else {
                switch createHTTP.statusCode {
                case 401, 403: return .error
                default: return .stale   // 409 = not cached, and everything else
                }
            }
            let created = try JSONDecoder().decode(Envelope<CreateData>.self, from: createData)
            guard created.success != false, let torrentId = created.data?.resolvedId else { return .stale }

            // 2. Read the file list.
            guard let info: Envelope<TorrentData> = try await get(
                "v1/api/torrents/mylist", key: key,
                query: [.init(name: "id", value: String(torrentId)), .init(name: "bypass_cache", value: "true")]
            ), let file = DebridFileSelection.select(
                from: info.data?.files ?? [], request: request,
                name: { $0.displayName }, size: { $0.size }, fileId: { $0.id }
            ), let fileId = file.id else { return .stale }

            // 3. Request a direct link for that file.
            guard let link: Envelope<String> = try await get(
                "v1/api/torrents/requestdl", key: key,
                query: [
                    .init(name: "token", value: key),
                    .init(name: "torrent_id", value: String(torrentId)),
                    .init(name: "file_id", value: String(fileId)),
                    .init(name: "zip_link", value: "false"),
                    .init(name: "redirect", value: "false"),
                    .init(name: "append_name", value: "false")
                ]
            ), let urlString = link.data, !urlString.isEmpty, let url = URL(string: urlString) else {
                return .stale
            }

            return .success(url: url, filename: file.displayName, videoSize: file.size)
        } catch is CancellationError {
            return .error
        } catch {
            return .error
        }
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ path: String, key: String, query: [URLQueryItem]) async throws -> T? {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func multipartRequest(_ path: String, key: String, fields: [String: String]) -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        body.append("--\(boundary)--\r\n")
        req.httpBody = body
        return req
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

// MARK: - TorBox DTOs

/// TorBox wraps every response in `{ success, data, error, detail }`.
private struct Envelope<T: Decodable>: Decodable {
    let success: Bool?
    let data: T?
}

private struct CreateData: Decodable {
    let torrentId: Int?
    let id: Int?

    var resolvedId: Int? { torrentId ?? id }

    enum CodingKeys: String, CodingKey {
        case torrentId = "torrent_id"
        case id
    }
}

private struct TorrentData: Decodable {
    let files: [File]?

    struct File: Decodable {
        let id: Int?
        let name: String?
        let shortName: String?
        let size: Int64?

        var displayName: String {
            if let shortName, !shortName.isEmpty { return shortName }
            if let name, let last = name.split(separator: "/").last { return String(last) }
            return name ?? ""
        }

        enum CodingKeys: String, CodingKey {
            case id, name, size
            case shortName = "short_name"
        }
    }
}
