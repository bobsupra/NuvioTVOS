import Foundation

/// Resolves a torrent through Premiumize's `transfer/directdl` endpoint, which
/// returns the cached file list (with direct links) in a single call. Mirrors
/// the Android `PremiumizeDirectDebridResolver`.
struct PremiumizeResolver: DebridProvider {
    let kind: DebridProviderKind = .premiumize

    private let endpoint = URL(string: "https://www.premiumize.me/api/transfer/directdl")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func resolve(_ request: DebridRequest, apiKey: String) async -> DebridResult {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .missingApiKey }

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let src = request.magnetURI.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? request.magnetURI
        req.httpBody = "src=\(src)".data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return .error }
            guard 200..<300 ~= http.statusCode else {
                return (http.statusCode == 401 || http.statusCode == 403) ? .error : .stale
            }

            let decoded = try JSONDecoder().decode(DirectDownload.self, from: data)
            // Premiumize reports errors in-band with a 200 (e.g. not cached).
            guard decoded.status?.lowercased() != "error" else { return .stale }

            guard let file = DebridFileSelection.select(
                from: decoded.content ?? [], request: request,
                name: { $0.displayName }, size: { $0.size }
            ), let link = file.link, !link.isEmpty, let url = URL(string: link) else {
                return .stale
            }

            return .success(url: url, filename: file.displayName, videoSize: file.size)
        } catch is CancellationError {
            return .error
        } catch {
            return .error
        }
    }
}

// MARK: - Premiumize DTOs

private struct DirectDownload: Decodable {
    let status: String?
    let content: [File]?

    struct File: Decodable {
        let path: String?
        let size: Int64?
        let link: String?

        /// Last path component of the file's path inside the torrent.
        var displayName: String {
            (path?.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last).map(String.init) ?? (path ?? "")
        }
    }
}
