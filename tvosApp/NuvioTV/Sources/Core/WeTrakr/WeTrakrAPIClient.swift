import Foundation

enum WeTrakrConfig {
    static let apiBaseURL = "https://api.wetrakr.com"
    static let apiVersion = "1"
    static let activationURL = "https://wetrakr.com/activate"
    static let websiteURL = "https://wetrakr.com"
    static let documentationURL = "https://www.vinnota.store"

    static var defaultClientID: String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "WETRAKR_CLIENT_ID") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasPrefix("$(") else { return "" }
        return raw
    }

    static var clientID: String {
        clientID(in: ProfileSettings.current)
    }

    static var clientSecret: String {
        clientSecret(in: ProfileSettings.current)
    }

    static var isConfigured: Bool {
        isConfigured(in: ProfileSettings.current)
    }

    static func clientID(in store: UserDefaults) -> String {
        let custom = store.string(forKey: SettingsKey.wetrakrClientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? defaultClientID : custom
    }

    static func clientSecret(in store: UserDefaults) -> String {
        store.string(forKey: SettingsKey.wetrakrClientSecret)?
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

struct WeTrakrHTTPResult<T> {
    let statusCode: Int
    let value: T?
    let rawData: Data
    let errorMessage: String?
    let headers: [String: String]

    init(
        statusCode: Int,
        value: T?,
        rawData: Data,
        errorMessage: String?,
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.value = value
        self.rawData = rawData
        self.errorMessage = errorMessage
        self.headers = headers
    }

    var oauthError: String? {
        guard !rawData.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let error = json["error"] as? String ?? json["message"] as? String else {
            return nil
        }
        return error
    }

    func valueOrThrow() throws -> T {
        guard (200..<300).contains(statusCode) else {
            if let oauth = oauthError {
                if oauth == "authorization_pending" {
                    throw WeTrakrServiceError.authorizationPending
                } else if oauth == "too_many_requests" || statusCode == 429 {
                    throw WeTrakrServiceError.rateLimited
                } else if oauth == "invalid_client" {
                    throw WeTrakrServiceError.invalidClient
                }
                throw WeTrakrServiceError.message(oauth)
            }
            throw WeTrakrServiceError.message(errorMessage ?? "WeTrakr request failed (\(statusCode)).")
        }
        guard let value else {
            throw WeTrakrServiceError.message(errorMessage ?? "WeTrakr returned an empty response.")
        }
        return value
    }
}

enum WeTrakrServiceError: LocalizedError, Equatable {
    case message(String)
    case authorizationPending
    case expiredCode
    case rateLimited
    case invalidClient
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .authorizationPending: return "Waiting for authorization on wetrakr.com/activate."
        case .expiredCode: return "Device pairing code expired. Please request a new one."
        case .rateLimited: return "Rate limit exceeded. Please wait a moment."
        case .invalidClient: return "Invalid WeTrakr Client ID."
        case .notConfigured: return "Please enter your WeTrakr Client ID in Settings."
        }
    }
}

final class WeTrakrAPIClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(session: URLSession = .shared) {
        self.session = session
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .useDefaultKeys
        self.decoder = dec
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .useDefaultKeys
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    func get<T: Decodable>(
        path: String,
        accessToken: String? = nil,
        clientID: String? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> WeTrakrHTTPResult<T> {
        let request = try makeRequest(
            path: path,
            method: "GET",
            accessToken: accessToken,
            clientID: clientID,
            queryItems: queryItems,
            body: nil
        )
        return try await perform(request)
    }

    func getRaw(
        path: String,
        accessToken: String? = nil,
        clientID: String? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> WeTrakrHTTPResult<Data> {
        let request = try makeRequest(
            path: path,
            method: "GET",
            accessToken: accessToken,
            clientID: clientID,
            queryItems: queryItems,
            body: nil
        )
        return try await performRaw(request)
    }

    func post<B: Encodable, T: Decodable>(
        path: String,
        body: B,
        accessToken: String? = nil,
        clientID: String? = nil,
        queryItems: [URLQueryItem] = [],
        idempotencyKey: String? = nil
    ) async throws -> WeTrakrHTTPResult<T> {
        let bodyData = try encoder.encode(body)
        let request = try makeRequest(
            path: path,
            method: "POST",
            accessToken: accessToken,
            clientID: clientID,
            queryItems: queryItems,
            body: bodyData,
            idempotencyKey: idempotencyKey
        )
        return try await perform(request)
    }

    func postEmptyBody<T: Decodable>(
        path: String,
        accessToken: String? = nil,
        clientID: String? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> WeTrakrHTTPResult<T> {
        let request = try makeRequest(
            path: path,
            method: "POST",
            accessToken: accessToken,
            clientID: clientID,
            queryItems: queryItems,
            body: Data("{}".utf8)
        )
        return try await perform(request)
    }

    func postRaw<B: Encodable>(
        path: String,
        body: B,
        accessToken: String? = nil,
        clientID: String? = nil,
        queryItems: [URLQueryItem] = [],
        idempotencyKey: String? = nil
    ) async throws -> WeTrakrHTTPResult<Data> {
        let bodyData = try encoder.encode(body)
        let request = try makeRequest(
            path: path,
            method: "POST",
            accessToken: accessToken,
            clientID: clientID,
            queryItems: queryItems,
            body: bodyData,
            idempotencyKey: idempotencyKey
        )
        return try await performRaw(request)
    }

    func delete<T: Decodable>(
        path: String,
        body: (any Encodable)? = nil,
        accessToken: String? = nil,
        clientID: String? = nil,
        queryItems: [URLQueryItem] = [],
        idempotencyKey: String? = nil
    ) async throws -> WeTrakrHTTPResult<T> {
        let bodyData = try body.map { try encoder.encode($0) }
        let request = try makeRequest(
            path: path,
            method: "DELETE",
            accessToken: accessToken,
            clientID: clientID,
            queryItems: queryItems,
            body: bodyData,
            idempotencyKey: idempotencyKey
        )
        return try await perform(request)
    }

    func deleteRaw(
        path: String,
        body: (any Encodable)? = nil,
        accessToken: String? = nil,
        clientID: String? = nil,
        queryItems: [URLQueryItem] = [],
        idempotencyKey: String? = nil
    ) async throws -> WeTrakrHTTPResult<Data> {
        let bodyData = try body.map { try encoder.encode($0) }
        let request = try makeRequest(
            path: path,
            method: "DELETE",
            accessToken: accessToken,
            clientID: clientID,
            queryItems: queryItems,
            body: bodyData,
            idempotencyKey: idempotencyKey
        )
        return try await performRaw(request)
    }

    private func makeRequest(
        path: String,
        method: String,
        accessToken: String?,
        clientID: String?,
        queryItems: [URLQueryItem],
        body: Data?,
        idempotencyKey: String? = nil
    ) throws -> URLRequest {
        let normalizedBase = WeTrakrConfig.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(normalizedBase)/\(normalizedPath)") else {
            throw WeTrakrServiceError.message("Invalid WeTrakr URL.")
        }

        if !queryItems.isEmpty {
            var items = components.queryItems ?? []
            items.append(contentsOf: queryItems)
            components.queryItems = items
        }

        guard let url = components.url else {
            throw WeTrakrServiceError.message("Invalid WeTrakr URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(WeTrakrConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(WeTrakrConfig.apiVersion, forHTTPHeaderField: "wetrakr-api-version")

        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        if let clientID, !clientID.isEmpty {
            request.setValue(clientID, forHTTPHeaderField: "wetrakr-api-key")
        }

        if let idempotencyKey = idempotencyKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !idempotencyKey.isEmpty {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }

        request.httpBody = body
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> WeTrakrHTTPResult<T> {
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let errorMessage: String? = {
            guard !(200..<300).contains(statusCode), !data.isEmpty else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (json["message"] as? String) ?? (json["error"] as? String)
            }
            return String(data: data, encoding: .utf8)
        }()

        let decoded: T?
        if (200..<300).contains(statusCode) {
            if data.isEmpty, T.self == Data.self {
                decoded = Data() as? T
            } else if data.isEmpty {
                decoded = nil
            } else {
                decoded = try? decoder.decode(T.self, from: data)
            }
        } else {
            decoded = nil
        }

        return WeTrakrHTTPResult(
            statusCode: statusCode,
            value: decoded,
            rawData: data,
            errorMessage: errorMessage,
            headers: Self.headers(from: response)
        )
    }

    private func performRaw(_ request: URLRequest) async throws -> WeTrakrHTTPResult<Data> {
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let errorMessage: String? = {
            guard !(200..<300).contains(statusCode), !data.isEmpty else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return (json["message"] as? String) ?? (json["error"] as? String)
            }
            return String(data: data, encoding: .utf8)
        }()

        return WeTrakrHTTPResult(
            statusCode: statusCode,
            value: (200..<300).contains(statusCode) ? data : nil,
            rawData: data,
            errorMessage: errorMessage,
            headers: Self.headers(from: response)
        )
    }

    private static func headers(from response: URLResponse) -> [String: String] {
        guard let response = response as? HTTPURLResponse else { return [:] }
        return response.allHeaderFields.reduce(into: [:]) { headers, field in
            guard let key = field.key as? String else { return }
            headers[key.lowercased()] = String(describing: field.value)
        }
    }
}
