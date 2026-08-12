import Foundation

/// Resolves a torrent through Real-Debrid's REST API. Mirrors the Android
/// `RealDebridDirectDebridResolver` flow:
///   addMagnet → torrent info → select file → torrent info → unrestrict link.
/// On any failure it deletes the transient torrent so the account stays clean.
struct RealDebridResolver: DebridProvider {
    let kind: DebridProviderKind = .realDebrid

    private let base = URL(string: "https://api.real-debrid.com/rest/1.0")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(_ request: DebridRequest, apiKey: String) async -> DebridResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingApiKey }

        do {
            // 1. Add the magnet.
            guard let added: AddMagnetResponse = try await post(
                "torrents/addMagnet", key: key, form: ["magnet": request.magnetURI]
            ), !added.id.isEmpty else { return .stale }

            let torrentId = added.id
            var resolved = false
            defer {
                if !resolved {
                    Task { try? await delete("torrents/delete/\(torrentId)", key: key) }
                }
            }

            // 2. Read the file list and pick the wanted file.
            guard let infoBefore: TorrentInfo = try await get("torrents/info/\(torrentId)", key: key),
                  let file = selectFile(from: infoBefore.files ?? [], request: request),
                  let fileId = file.id
            else { return .stale }

            // 3. Select it (RD returns 204/202 on success).
            try await postVoid("torrents/selectFiles/\(torrentId)", key: key,
                               form: ["files": String(fileId)])

            // 4. Re-read info; once "downloaded" we get cached links.
            guard let infoAfter: TorrentInfo = try await get("torrents/info/\(torrentId)", key: key),
                  infoAfter.status?.lowercased() == "downloaded",
                  let link = infoAfter.links?.first(where: { !$0.isEmpty })
            else { return .stale }

            // 5. Unrestrict the cached link into a direct URL.
            guard let unrestricted: UnrestrictResponse = try await post(
                "unrestrict/link", key: key, form: ["link": link]
            ), let url = URL(string: unrestricted.download), !unrestricted.download.isEmpty
            else { return .stale }

            resolved = true
            return .success(
                url: url,
                filename: unrestricted.filename ?? file.displayName,
                videoSize: unrestricted.filesize ?? file.bytes
            )
        } catch let error as DebridHTTPError {
            return (error.status == 401 || error.status == 403) ? .error : .stale
        } catch is CancellationError {
            return .error
        } catch {
            return .error
        }
    }

    private func selectFile(from files: [TorrentInfo.File], request: DebridRequest) -> TorrentInfo.File? {
        DebridFileSelection.select(
            from: files, request: request,
            name: { $0.displayName }, size: { $0.bytes }, fileId: { $0.id }
        )
    }

    // MARK: - HTTP

    private func request(_ path: String, method: String, key: String, form: [String: String]?) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let form {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = form
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
                .joined(separator: "&")
                .data(using: .utf8)
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw DebridHTTPError(status: -1) }
        guard 200..<300 ~= http.statusCode else { throw DebridHTTPError(status: http.statusCode) }
        return data
    }

    private func get<T: Decodable>(_ path: String, key: String) async throws -> T? {
        let data = try await send(request(path, method: "GET", key: key, form: nil))
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func post<T: Decodable>(_ path: String, key: String, form: [String: String]) async throws -> T? {
        let data = try await send(request(path, method: "POST", key: key, form: form))
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func postVoid(_ path: String, key: String, form: [String: String]) async throws {
        _ = try await send(request(path, method: "POST", key: key, form: form))
    }

    private func delete(_ path: String, key: String) async throws {
        _ = try await send(request(path, method: "DELETE", key: key, form: nil))
    }
}

private struct DebridHTTPError: Error { let status: Int }

// MARK: - Real-Debrid DTOs

private struct AddMagnetResponse: Decodable {
    let id: String
}

private struct TorrentInfo: Decodable {
    let status: String?
    let links: [String]?
    let files: [File]?

    struct File: Decodable {
        let id: Int?
        let path: String?
        let bytes: Int64?
        let selected: Int?

        /// RD paths are absolute inside the torrent ("/Folder/file.mkv"); the
        /// last path component is the filename we match against.
        var displayName: String {
            (path?.split(separator: "/").last).map(String.init) ?? path ?? ""
        }
    }
}

private struct UnrestrictResponse: Decodable {
    let download: String
    let filename: String?
    let filesize: Int64?
}
