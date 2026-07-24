import Foundation

enum SimklConfig {
    static let apiBaseURL = "https://api.simkl.com"
    static let appName = "nuvio-tvos"
    static let developerSettingsURL = "https://simkl.com/settings/developer/"
    static let pinVerificationURL = "https://simkl.com/pin"
    static let redirectURI = "urn:ietf:wg:oauth:2.0:oob"

    static var clientID: String {
        clientID(in: ProfileSettings.current)
    }

    static var isConfigured: Bool {
        isConfigured(in: ProfileSettings.current)
    }

    static func clientID(in store: UserDefaults) -> String {
        store.string(forKey: SettingsKey.simklClientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func isConfigured(in store: UserDefaults) -> Bool {
        !clientID(in: store).isEmpty
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var userAgent: String {
        "NuvioTV/\(appVersion)"
    }
}

struct SimklHTTPResult<T> {
    let statusCode: Int
    let value: T?
    let rawData: Data
    let errorMessage: String?

    func valueOrThrow() throws -> T {
        guard (200..<300).contains(statusCode) else {
            throw SimklServiceError.message(errorMessage ?? "Simkl request failed (\(statusCode)).")
        }
        guard let value else {
            throw SimklServiceError.message(errorMessage ?? "Simkl returned an empty response.")
        }
        return value
    }
}

enum SimklServiceError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

/// Shared HTTP transport for Simkl. Every request carries the required
/// `client_id`, `app-name`, `app-version` query params and `User-Agent` header.
final class SimklAPIClient {
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    func get<T: Decodable>(
        path: String,
        clientID: String,
        accessToken: String? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> SimklHTTPResult<T> {
        let request = try makeRequest(
            path: path,
            method: "GET",
            clientID: clientID,
            accessToken: accessToken,
            queryItems: queryItems,
            body: nil as Data?
        )
        return try await perform(request)
    }

    func postEmptyBody<T: Decodable>(
        path: String,
        clientID: String,
        accessToken: String?
    ) async throws -> SimklHTTPResult<T> {
        // Simkl's /users/settings is POST for historical reasons and takes no body.
        let request = try makeRequest(
            path: path,
            method: "POST",
            clientID: clientID,
            accessToken: accessToken,
            queryItems: [],
            body: Data("{}".utf8)
        )
        return try await perform(request)
    }

    func post<B: Encodable>(
        path: String,
        clientID: String,
        accessToken: String,
        queryItems: [URLQueryItem] = [],
        body: B
    ) async throws -> SimklHTTPResult<Data> {
        let request = try makeRequest(
            path: path,
            method: "POST",
            clientID: clientID,
            accessToken: accessToken,
            queryItems: queryItems,
            body: try encoder.encode(body)
        )
        return try await performRaw(request)
    }

    func getRaw(
        path: String,
        clientID: String,
        accessToken: String? = nil
    ) async throws -> SimklHTTPResult<Data> {
        let request = try makeRequest(
            path: path,
            method: "GET",
            clientID: clientID,
            accessToken: accessToken,
            queryItems: [],
            body: nil as Data?
        )
        return try await performRaw(request)
    }

    private func makeRequest(
        path: String,
        method: String,
        clientID: String,
        accessToken: String?,
        queryItems: [URLQueryItem],
        body: Data?
    ) throws -> URLRequest {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimklServiceError.message("Enter your Simkl Client ID first.")
        }

        let normalizedBase = SimklConfig.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(normalizedBase)/\(normalizedPath)") else {
            throw SimklServiceError.message("Invalid Simkl URL.")
        }

        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "app-name", value: SimklConfig.appName),
            URLQueryItem(name: "app-version", value: SimklConfig.appVersion)
        ])
        items.append(contentsOf: queryItems)
        components.queryItems = items

        guard let url = components.url else {
            throw SimklServiceError.message("Invalid Simkl URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        // PIN creation is a GET endpoint but every response is a unique,
        // short-lived credential. Cached responses immediately produce an
        // invalid PIN on the first poll. Sync/activity reads must also remain
        // authoritative, so Simkl requests never use URLCache.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(SimklConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> SimklHTTPResult<T> {
        let raw = try await performRaw(request)
        var value: T?
        if (200..<300).contains(raw.statusCode), !raw.rawData.isEmpty {
            do {
                value = try decoder.decode(T.self, from: raw.rawData)
            } catch {
                return SimklHTTPResult(
                    statusCode: raw.statusCode,
                    value: nil,
                    rawData: raw.rawData,
                    errorMessage: raw.errorMessage
                        ?? "Simkl response could not be read (\(error.localizedDescription))."
                )
            }
        }
        return SimklHTTPResult(
            statusCode: raw.statusCode,
            value: value,
            rawData: raw.rawData,
            errorMessage: Self.friendlyError(raw.errorMessage, status: raw.statusCode)
        )
    }

    private func performRaw(_ request: URLRequest) async throws -> SimklHTTPResult<Data> {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SimklServiceError.message("Invalid Simkl response.")
        }
        return SimklHTTPResult(
            statusCode: http.statusCode,
            value: data,
            rawData: data,
            errorMessage: Self.errorMessage(from: data)
        )
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["message", "error_description", "error", "msg"] {
            if let string = object[key] as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func friendlyError(_ raw: String?, status: Int) -> String? {
        switch status {
        case 401:
            return raw ?? "Simkl access was revoked. Connect again."
        case 403:
            return raw ?? "Simkl rejected this request. Check your Client ID."
        case 412:
            return raw ?? "Simkl Client ID is missing, wrong, or disabled."
        case 429:
            return raw ?? "Simkl is rate limiting requests. Wait and try again."
        case 500...599:
            return raw ?? "Simkl is temporarily unavailable (\(status))."
        default:
            return raw
        }
    }
}
