import Foundation
import SwiftUI

enum TraktConfig {
    static let apiBaseURL = "https://api.trakt.tv"
    static let redirectURI = "urn:ietf:wg:oauth:2.0:oob"

    static var clientID: String {
        clientID(in: ProfileSettings.current)
    }

    static var clientSecret: String {
        clientSecret(in: ProfileSettings.current)
    }

    static var isConfigured: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty
    }

    static func clientID(in store: UserDefaults) -> String {
        store.string(forKey: SettingsKey.traktClientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func clientSecret(in store: UserDefaults) -> String {
        store.string(forKey: SettingsKey.traktClientSecret)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func isConfigured(in store: UserDefaults) -> Bool {
        !clientID(in: store).isEmpty && !clientSecret(in: store).isEmpty
    }

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "NuvioTV/\(version)"
    }
}

enum TraktConnectionMode {
    case disconnected
    case awaitingApproval
    case connected
}

enum TraktWatchProgressSource: String, CaseIterable {
    case trakt = "TRAKT"
    case nuvioSync = "NUVIO_SYNC"

    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .nuvioSync: return "Nuvio Sync"
        }
    }
}

enum TraktLibrarySourceMode: String, CaseIterable {
    case trakt = "TRAKT"
    case local = "LOCAL"

    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .local: return "Nuvio Library"
        }
    }
}

enum TraktMoreLikeThisSource: String, CaseIterable {
    case trakt = "TRAKT"
    case tmdb = "TMDB"

    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .tmdb: return "TMDB"
        }
    }
}

struct TraktCachedStats: Codable, Equatable {
    var moviesWatched: Int?
    var showsWatched: Int?
    var episodesWatched: Int?
    var totalWatchedHours: Int?
}

struct TraktAuthState: Equatable {
    var accessToken: String?
    var refreshToken: String?
    var tokenType: String?
    var createdAt: Int?
    var expiresIn: Int?
    var username: String?
    var userSlug: String?
    var deviceCode: String?
    var userCode: String?
    var verificationURL: String?
    var expiresAt: Double?
    var pollInterval: Int?
    var credentialClientID: String?

    var isAuthenticated: Bool {
        isAuthenticated(in: ProfileSettings.current)
    }

    func isAuthenticated(in store: UserDefaults) -> Bool {
        TraktConfig.isConfigured(in: store) &&
        !(accessToken ?? "").isEmpty &&
        !(refreshToken ?? "").isEmpty &&
        credentialClientID == TraktConfig.clientID(in: store)
    }

    var hasActiveDeviceFlow: Bool {
        hasActiveDeviceFlow(in: ProfileSettings.current)
    }

    func hasActiveDeviceFlow(in store: UserDefaults) -> Bool {
        TraktConfig.isConfigured(in: store) &&
        !(deviceCode ?? "").isEmpty &&
        credentialClientID == TraktConfig.clientID(in: store)
    }

    var tokenExpiresAtMillis: Double? {
        guard let createdAt, let expiresIn else { return nil }
        return Double(createdAt + expiresIn) * 1000.0
    }
}

enum TraktDefaults {
    static let continueWatchingDaysCapAll = 0
    static let continueWatchingDaysCap = 60
    static let showMetaComments = true
    static let watchProgressSource = TraktWatchProgressSource.trakt
    static let librarySourceMode = TraktLibrarySourceMode.trakt
    static let moreLikeThisSource = TraktMoreLikeThisSource.trakt
}

enum TraktAuthStore {
    static let changedNotification = Notification.Name("nuvio.tv.trakt.auth.changed")

    private enum Key {
        static let accessToken = "nuvio.tv.trakt.auth.accessToken"
        static let refreshToken = "nuvio.tv.trakt.auth.refreshToken"
        static let tokenType = "nuvio.tv.trakt.auth.tokenType"
        static let createdAt = "nuvio.tv.trakt.auth.createdAt"
        static let expiresIn = "nuvio.tv.trakt.auth.expiresIn"
        static let username = "nuvio.tv.trakt.auth.username"
        static let userSlug = "nuvio.tv.trakt.auth.userSlug"
        static let deviceCode = "nuvio.tv.trakt.auth.deviceCode"
        static let userCode = "nuvio.tv.trakt.auth.userCode"
        static let verificationURL = "nuvio.tv.trakt.auth.verificationURL"
        static let expiresAt = "nuvio.tv.trakt.auth.expiresAt"
        static let pollInterval = "nuvio.tv.trakt.auth.pollInterval"
        static let credentialClientID = "nuvio.tv.trakt.auth.credentialClientID"
        static let cachedStats = "nuvio.tv.trakt.auth.cachedStats"
    }

    static var state: TraktAuthState {
        state(in: ProfileSettings.current)
    }

    static func state(in defaults: UserDefaults) -> TraktAuthState {
        return TraktAuthState(
            accessToken: defaults.string(forKey: Key.accessToken),
            refreshToken: defaults.string(forKey: Key.refreshToken),
            tokenType: defaults.string(forKey: Key.tokenType),
            createdAt: intIfPresent(Key.createdAt, defaults: defaults),
            expiresIn: intIfPresent(Key.expiresIn, defaults: defaults).map(normalizeTokenLifetime),
            username: defaults.string(forKey: Key.username),
            userSlug: defaults.string(forKey: Key.userSlug),
            deviceCode: defaults.string(forKey: Key.deviceCode),
            userCode: defaults.string(forKey: Key.userCode),
            verificationURL: defaults.string(forKey: Key.verificationURL),
            expiresAt: doubleIfPresent(Key.expiresAt, defaults: defaults),
            pollInterval: intIfPresent(Key.pollInterval, defaults: defaults),
            credentialClientID: defaults.string(forKey: Key.credentialClientID)
        )
    }

    static func saveDeviceFlow(
        _ response: TraktDeviceCodeResponse,
        clientID: String,
        store defaults: UserDefaults = ProfileSettings.current
    ) {
        if defaults.string(forKey: Key.credentialClientID) != clientID {
            [
                Key.accessToken, Key.refreshToken, Key.tokenType, Key.createdAt,
                Key.expiresIn, Key.username, Key.userSlug, Key.cachedStats
            ].forEach { defaults.removeObject(forKey: $0) }
        }
        defaults.set(response.deviceCode, forKey: Key.deviceCode)
        defaults.set(response.userCode, forKey: Key.userCode)
        defaults.set(response.verificationURL, forKey: Key.verificationURL)
        defaults.set(Date().timeIntervalSince1970 * 1000.0 + Double(response.expiresIn * 1000), forKey: Key.expiresAt)
        defaults.set(response.interval, forKey: Key.pollInterval)
        defaults.set(clientID, forKey: Key.credentialClientID)
    }

    static func saveToken(
        _ response: TraktTokenResponse,
        clientID: String,
        store defaults: UserDefaults = ProfileSettings.current
    ) {
        defaults.set(response.accessToken, forKey: Key.accessToken)
        defaults.set(response.refreshToken, forKey: Key.refreshToken)
        defaults.set(response.tokenType, forKey: Key.tokenType)
        defaults.set(response.createdAt, forKey: Key.createdAt)
        defaults.set(normalizeTokenLifetime(response.expiresIn), forKey: Key.expiresIn)
        defaults.set(clientID, forKey: Key.credentialClientID)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func saveUser(
        username: String?,
        slug: String?,
        store defaults: UserDefaults = ProfileSettings.current
    ) {
        setOptional(username, forKey: Key.username, defaults: defaults)
        setOptional(slug, forKey: Key.userSlug, defaults: defaults)
    }

    static func updatePollInterval(
        _ seconds: Int,
        store: UserDefaults = ProfileSettings.current
    ) {
        store.set(seconds, forKey: Key.pollInterval)
    }

    static var cachedStats: TraktCachedStats? {
        cachedStats(in: ProfileSettings.current)
    }

    static func cachedStats(in store: UserDefaults) -> TraktCachedStats? {
        guard let data = store.data(forKey: Key.cachedStats) else { return nil }
        return try? JSONDecoder().decode(TraktCachedStats.self, from: data)
    }

    static func saveCachedStats(
        _ stats: TraktCachedStats,
        store: UserDefaults = ProfileSettings.current
    ) {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        store.set(data, forKey: Key.cachedStats)
    }

    static func clearDeviceFlow(store defaults: UserDefaults = ProfileSettings.current) {
        [Key.deviceCode, Key.userCode, Key.verificationURL, Key.expiresAt, Key.pollInterval].forEach {
            defaults.removeObject(forKey: $0)
        }
    }

    static func clearAuth(store defaults: UserDefaults = ProfileSettings.current) {
        [
            Key.accessToken, Key.refreshToken, Key.tokenType, Key.createdAt, Key.expiresIn,
            Key.username, Key.userSlug, Key.deviceCode, Key.userCode, Key.verificationURL,
            Key.expiresAt, Key.pollInterval, Key.credentialClientID, Key.cachedStats
        ].forEach { defaults.removeObject(forKey: $0) }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static func intIfPresent(_ key: String, defaults: UserDefaults) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }

    private static func doubleIfPresent(_ key: String, defaults: UserDefaults) -> Double? {
        defaults.object(forKey: key) == nil ? nil : defaults.double(forKey: key)
    }

    private static func setOptional(_ value: String?, forKey key: String, defaults: UserDefaults) {
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func normalizeTokenLifetime(_ expiresIn: Int) -> Int {
        expiresIn <= 0 ? 7_776_000 : expiresIn
    }
}

enum TraktSettingsStore {
    static let continueWatchingChangedNotification = Notification.Name(
        "nuvio.tv.trakt.continueWatchingSettings.changed"
    )
    static let libraryChangedNotification = Notification.Name(
        "nuvio.tv.trakt.librarySettings.changed"
    )

    static var continueWatchingDaysCap: Int {
        get {
            let defaults = ProfileSettings.current
            guard defaults.object(forKey: SettingsKey.traktContinueWatchingDaysCap) != nil else {
                return TraktDefaults.continueWatchingDaysCap
            }
            let value = defaults.integer(forKey: SettingsKey.traktContinueWatchingDaysCap)
            return normalizeContinueWatchingDaysCap(value)
        }
        set {
            let normalized = normalizeContinueWatchingDaysCap(newValue)
            guard normalized != continueWatchingDaysCap else { return }
            ProfileSettings.current.set(normalized, forKey: SettingsKey.traktContinueWatchingDaysCap)
            NotificationCenter.default.post(name: continueWatchingChangedNotification, object: nil)
        }
    }

    static var showMetaComments: Bool {
        get { bool(SettingsKey.traktShowMetaComments, fallback: TraktDefaults.showMetaComments) }
        set { ProfileSettings.current.set(newValue, forKey: SettingsKey.traktShowMetaComments) }
    }

    static var watchProgressSource: TraktWatchProgressSource {
        get {
            let raw = ProfileSettings.current.string(forKey: SettingsKey.traktWatchProgressSource)
            return TraktWatchProgressSource(rawValue: raw ?? "") ?? TraktDefaults.watchProgressSource
        }
        set {
            guard newValue != watchProgressSource else { return }
            ProfileSettings.current.set(newValue.rawValue, forKey: SettingsKey.traktWatchProgressSource)
            NotificationCenter.default.post(name: continueWatchingChangedNotification, object: nil)
        }
    }

    static var librarySourceMode: TraktLibrarySourceMode {
        get {
            let raw = ProfileSettings.current.string(forKey: SettingsKey.traktLibrarySourceMode)
            return TraktLibrarySourceMode(rawValue: raw ?? "") ?? TraktDefaults.librarySourceMode
        }
        set {
            guard newValue != librarySourceMode else { return }
            ProfileSettings.current.set(newValue.rawValue, forKey: SettingsKey.traktLibrarySourceMode)
            NotificationCenter.default.post(name: libraryChangedNotification, object: nil)
        }
    }

    static var moreLikeThisSource: TraktMoreLikeThisSource {
        get {
            let raw = ProfileSettings.current.string(forKey: SettingsKey.traktMoreLikeThisSource)
            return TraktMoreLikeThisSource(rawValue: raw ?? "") ?? TraktDefaults.moreLikeThisSource
        }
        set { ProfileSettings.current.set(newValue.rawValue, forKey: SettingsKey.traktMoreLikeThisSource) }
    }

    private static func bool(_ key: String, fallback: Bool) -> Bool {
        let defaults = ProfileSettings.current
        return defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    private static func normalizeContinueWatchingDaysCap(_ days: Int) -> Int {
        if days == TraktDefaults.continueWatchingDaysCapAll { return days }
        return min(max(days, 7), 365)
    }
}

private struct TraktDeviceCodeRequest: Encodable {
    let clientID: String
    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

private struct TraktDeviceTokenRequest: Encodable {
    let code: String
    let clientID: String
    let clientSecret: String
    enum CodingKeys: String, CodingKey {
        case code
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}

private struct TraktRefreshTokenRequest: Encodable {
    let refreshToken: String
    let clientID: String
    let clientSecret: String
    let redirectURI: String
    let grantType = "refresh_token"
    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case redirectURI = "redirect_uri"
        case grantType = "grant_type"
    }
}

private struct TraktRevokeRequest: Encodable {
    let token: String
    let clientID: String
    let clientSecret: String
    enum CodingKeys: String, CodingKey {
        case token
        case clientID = "client_id"
        case clientSecret = "client_secret"
    }
}

struct TraktDeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let expiresIn: Int
    let interval: Int
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

struct TraktTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String
    let createdAt: Int
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case createdAt = "created_at"
    }
}

private struct TraktUserSettingsResponse: Decodable {
    struct User: Decodable {
        struct IDs: Decodable { let slug: String? }
        let username: String?
        let ids: IDs?
    }
    let user: User?
}

private struct TraktUserStatsResponse: Decodable {
    struct Category: Decodable {
        let watched: Int?
        let minutes: Int?
    }
    let movies: Category?
    let shows: Category?
    let episodes: Category?
}

enum TraktPollResult {
    case pending
    case alreadyUsed
    case expired
    case denied
    case slowDown(Int)
    case approved(String?)
    case failed(String)
}

final class TraktAuthService {
    private let session: URLSession
    private let store: UserDefaults
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let refreshLeewaySeconds = 60

    init(session: URLSession = .shared, store: UserDefaults = ProfileSettings.current) {
        self.session = session
        self.store = store
    }

    func hasRequiredCredentials() -> Bool {
        TraktConfig.isConfigured(in: store)
    }

    func currentState() -> TraktAuthState {
        TraktAuthStore.state(in: store)
    }

    func startDeviceAuth() async throws -> TraktDeviceCodeResponse {
        guard hasRequiredCredentials() else {
            throw TraktServiceError.message("Enter your Trakt Client ID and Client Secret first.")
        }

        let state = currentState()
        if let deviceCode = state.deviceCode,
           let expiresAt = state.expiresAt,
           state.credentialClientID == clientID,
           Date().timeIntervalSince1970 * 1000.0 < expiresAt {
            let response = TraktDeviceCodeResponse(
                deviceCode: deviceCode,
                userCode: state.userCode ?? "",
                verificationURL: state.verificationURL ?? "https://trakt.tv/activate",
                expiresIn: max(Int((expiresAt - Date().timeIntervalSince1970 * 1000.0) / 1000.0), 0),
                interval: state.pollInterval ?? 5
            )
            return response
        }

        let response: TraktDeviceCodeResponse = try await post(
            path: "oauth/device/code",
            body: TraktDeviceCodeRequest(clientID: clientID),
            authorized: false
        )
        TraktAuthStore.saveDeviceFlow(response, clientID: clientID, store: store)
        return response
    }

    func pollDeviceToken() async -> TraktPollResult {
        guard hasRequiredCredentials() else {
            return .failed("Enter your Trakt Client ID and Client Secret first.")
        }
        let state = currentState()
        guard state.hasActiveDeviceFlow(in: store),
              let deviceCode = state.deviceCode,
              !deviceCode.isEmpty else {
            return .failed("No active Trakt device code.")
        }

        do {
            let response: HTTPResult<TraktTokenResponse> = try await postResult(
                path: "oauth/device/token",
                body: TraktDeviceTokenRequest(
                    code: deviceCode,
                    clientID: clientID,
                    clientSecret: clientSecret
                ),
                authorized: false
            )
            if let token = response.value, (200..<300).contains(response.statusCode) {
                TraktAuthStore.saveToken(token, clientID: clientID, store: store)
                TraktAuthStore.clearDeviceFlow(store: store)
                let username = await fetchUserSettings()
                return .approved(username)
            }
            switch response.statusCode {
            case 400: return .pending
            case 409:
                TraktAuthStore.clearDeviceFlow(store: store)
                return .alreadyUsed
            case 410:
                TraktAuthStore.clearDeviceFlow(store: store)
                return .expired
            case 418:
                TraktAuthStore.clearDeviceFlow(store: store)
                return .denied
            case 429:
                let next = min((currentState().pollInterval ?? 5) + 5, 60)
                TraktAuthStore.updatePollInterval(next, store: store)
                return .slowDown(next)
            default:
                return .failed("Trakt token polling failed (\(response.statusCode)).")
            }
        } catch {
            return .failed("Network error. Retrying is safe.")
        }
    }

    func refreshTokenIfNeeded(force: Bool = false) async -> Bool {
        guard hasRequiredCredentials() else { return false }
        let state = currentState()
        guard state.isAuthenticated(in: store), let refreshToken = state.refreshToken else { return false }
        if !force && !isTokenExpiredOrExpiring(state) { return true }

        do {
            let response: HTTPResult<TraktTokenResponse> = try await postResult(
                path: "oauth/token",
                body: TraktRefreshTokenRequest(
                    refreshToken: refreshToken,
                    clientID: clientID,
                    clientSecret: clientSecret,
                    redirectURI: TraktConfig.redirectURI
                ),
                authorized: false
            )
            guard let token = response.value, (200..<300).contains(response.statusCode) else {
                if response.statusCode == 401 || response.statusCode == 403 {
                    TraktAuthStore.clearAuth(store: store)
                }
                return false
            }
            TraktAuthStore.saveToken(token, clientID: clientID, store: store)
            return true
        } catch {
            return false
        }
    }

    func revokeAndLogout() async {
        let state = currentState()
        if hasRequiredCredentials(), state.isAuthenticated(in: store), let accessToken = state.accessToken {
            try? await postEmpty(
                path: "oauth/revoke",
                body: TraktRevokeRequest(
                    token: accessToken,
                    clientID: clientID,
                    clientSecret: clientSecret
                ),
                authorized: false
            )
        }
        TraktAuthStore.clearAuth(store: store)
    }

    func fetchUserSettings() async -> String? {
        guard let response: TraktUserSettingsResponse = try? await authorizedGet(path: "users/settings") else {
            return nil
        }
        let username = response.user?.username
        let slug = response.user?.ids?.slug
        TraktAuthStore.saveUser(username: username, slug: slug, store: store)
        return username
    }

    func fetchUserStats() async -> TraktCachedStats? {
        let slug = currentState().userSlug ?? "me"
        guard let response: TraktUserStatsResponse = try? await authorizedGet(path: "users/\(slug)/stats") else {
            return nil
        }
        let totalMinutes = (response.movies?.minutes ?? 0) + (response.episodes?.minutes ?? 0)
        return TraktCachedStats(
            moviesWatched: response.movies?.watched,
            showsWatched: response.shows?.watched,
            episodesWatched: response.episodes?.watched,
            totalWatchedHours: totalMinutes > 0 ? totalMinutes / 60 : nil
        )
    }

    fileprivate func authorizedGet<T: Decodable>(path: String) async throws -> T {
        guard await refreshTokenIfNeeded(), let token = currentState().accessToken else {
            throw TraktServiceError.message("Not authenticated with Trakt.")
        }
        var request = baseRequest(path: path)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let result: HTTPResult<T> = try await perform(request)
        return try result.valueOrThrow()
    }

    /// Authenticated writes such as scrobbles may legitimately return an empty
    /// body. Check the status directly instead of requiring a decoded payload.
    fileprivate func authorizedPostEmpty<Body: Encodable>(path: String, body: Body) async throws {
        guard await refreshTokenIfNeeded() else {
            throw TraktServiceError.message("Not authenticated with Trakt.")
        }
        let result: HTTPResult<EmptyResponse> = try await postResult(
            path: path,
            body: body,
            authorized: true
        )
        guard (200..<300).contains(result.statusCode) else {
            throw TraktServiceError.message(
                result.errorMessage ?? "Trakt request failed (\(result.statusCode))."
            )
        }
    }

    fileprivate func authorizedPost<T: Decodable, Body: Encodable>(path: String, body: Body) async throws -> T {
        guard await refreshTokenIfNeeded() else {
            throw TraktServiceError.message("Not authenticated with Trakt.")
        }
        let result: HTTPResult<T> = try await postResult(
            path: path,
            body: body,
            authorized: true
        )
        return try result.valueOrThrow()
    }

    private func post<T: Decodable, Body: Encodable>(path: String, body: Body, authorized: Bool) async throws -> T {
        try await postResult(path: path, body: body, authorized: authorized).valueOrThrow()
    }

    private func postEmpty<Body: Encodable>(path: String, body: Body, authorized: Bool) async throws {
        _ = try await postResult(path: path, body: body, authorized: authorized) as HTTPResult<EmptyResponse>
    }

    private func postResult<T: Decodable, Body: Encodable>(path: String, body: Body, authorized: Bool) async throws -> HTTPResult<T> {
        var request = baseRequest(path: path)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorized, let token = currentState().accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> HTTPResult<T> {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TraktServiceError.message("Invalid Trakt response.")
        }
        let rawError = Self.errorMessage(from: data)
        // Prefer decoding only on success so Trakt error payloads never surface as
        // cryptic Decodable cast failures for TraktDeviceCodeResponse / tokens.
        var value: T?
        if (200..<300).contains(http.statusCode), !data.isEmpty {
            do {
                value = try decoder.decode(T.self, from: data)
            } catch {
                return HTTPResult(
                    statusCode: http.statusCode,
                    value: nil,
                    errorMessage: rawError
                        ?? "Trakt response could not be read (\(error.localizedDescription))."
                )
            }
        }
        return HTTPResult(
            statusCode: http.statusCode,
            value: value,
            errorMessage: Self.friendlyTraktError(rawError, status: http.statusCode)
        )
    }

    private func baseRequest(path: String) -> URLRequest {
        let normalizedBase = TraktConfig.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "\(normalizedBase)/\(path)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(TraktConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        return request
    }

    private var clientID: String { TraktConfig.clientID(in: store) }
    private var clientSecret: String { TraktConfig.clientSecret(in: store) }

    private func isTokenExpiredOrExpiring(_ state: TraktAuthState) -> Bool {
        guard let createdAt = state.createdAt, let expiresIn = state.expiresIn else { return true }
        let now = Int(Date().timeIntervalSince1970)
        return now >= createdAt + expiresIn - refreshLeewaySeconds
    }

    private static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["error_description", "msg", "message", "error", "error_code"] {
            if let string = object[key] as? String, !string.isEmpty {
                return string
            }
        }
        return nil
    }

    private static func friendlyTraktError(_ raw: String?, status: Int) -> String? {
        if status == 401 || status == 403 {
            return raw ?? "Trakt rejected the Client ID or Client Secret. Check both values and try again."
        }
        if status == 429 {
            return raw ?? "Trakt is rate limiting login attempts. Wait a few minutes and try again."
        }
        if status >= 500 {
            return raw ?? "Trakt is temporarily unavailable (\(status))."
        }
        return raw
    }
}

// MARK: - Continue Watching

/// Loads the remote progress selected by Settings → Trakt → Watch Progress.
/// Remote entries stay in Home's view state instead of being written into the
/// Nuvio Sync store, so switching sources never mixes or destroys either list.
enum TraktScrobbleAction: String {
    case start
    case pause
    case stop
}

struct TraktProgressService {
    private static let completionPercent = 92.0
    private static let maxItems = 20

    static func fetchContinueWatching(
        repository: CatalogRepository
    ) async -> [ContinueWatchingItem]? {
        guard TraktSettingsStore.watchProgressSource == .trakt,
              TraktAuthStore.state.isAuthenticated else {
            return []
        }

        let service = TraktAuthService()
        guard await service.refreshTokenIfNeeded() else { return nil }

        var receivedResponse = false
        var seeds: [TraktProgressSeed] = []

        if let movies: [TraktPlaybackDTO] = try? await service.authorizedGet(
            path: "sync/playback/movies"
        ) {
            receivedResponse = true
            seeds.append(contentsOf: movies.compactMap { playbackSeed(from: $0, type: "movie") })
        }

        if let episodes: [TraktPlaybackDTO] = try? await service.authorizedGet(
            path: "sync/playback/episodes"
        ) {
            receivedResponse = true
            seeds.append(contentsOf: episodes.compactMap { playbackSeed(from: $0, type: "series") })
        }

        let playbackIDs = Set(seeds.map(\.contentID))
        if let watchedShows: [TraktWatchedShowDTO] = try? await service.authorizedGet(
            path: "sync/watched/shows"
        ) {
            receivedResponse = true
            seeds.append(contentsOf: watchedShows.compactMap { show in
                guard let seed = nextUpSeed(from: show), !playbackIDs.contains(seed.contentID) else {
                    return nil
                }
                return seed
            })
        }

        // Some Trakt accounts return watched shows with an empty `seasons`
        // array even though episode history and stats are present. History is
        // the authoritative fallback for choosing the next episode in that case.
        if let episodeHistory: [TraktEpisodeHistoryDTO] = try? await service.authorizedGet(
            path: "users/me/history/episodes?page=1&limit=100"
        ) {
            receivedResponse = true
            seeds.append(contentsOf: episodeHistory.compactMap { history in
                guard let seed = nextUpSeed(from: history), !playbackIDs.contains(seed.contentID) else {
                    return nil
                }
                return seed
            })
        }

        guard receivedResponse else { return nil }

        let cutoff: Date? = {
            let days = TraktSettingsStore.continueWatchingDaysCap
            guard days != TraktDefaults.continueWatchingDaysCapAll else { return nil }
            return Calendar.current.date(byAdding: .day, value: -days, to: Date())
        }()

        let recentSeeds = seeds
            .filter { cutoff == nil || $0.lastUpdated >= cutoff! }
            .sorted { $0.lastUpdated > $1.lastUpdated }

        var items: [ContinueWatchingItem] = []
        var usedContentIDs = Set<String>()
        for seed in recentSeeds {
            guard !Task.isCancelled, items.count < maxItems else { break }
            guard usedContentIDs.insert(seed.contentID).inserted else { continue }
            if let item = await makeItem(from: seed, repository: repository) {
                items.append(item)
            }
        }
        return items
    }

    /// Writes the current player position to the same Trakt playback feed that
    /// Home reads when Watch Progress is set to Trakt. The local Nuvio Sync
    /// store intentionally stays untouched in this mode.
    static func reportPlayback(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        action: TraktScrobbleAction
    ) async -> Bool {
        guard TraktSettingsStore.watchProgressSource == .trakt,
              TraktAuthStore.state.isAuthenticated,
              position.isFinite,
              duration.isFinite,
              duration > 0,
              let media = scrobbleMedia(for: meta) else {
            return false
        }

        let progress = min(max(position / duration * 100, 0.01), 100)
        let request: TraktScrobbleRequest
        if meta.isSeries {
            guard let season, season >= 0, let episode, episode > 0 else { return false }
            request = TraktScrobbleRequest(
                progress: progress,
                movie: nil,
                show: media,
                episode: TraktScrobbleEpisode(season: season, number: episode)
            )
        } else {
            request = TraktScrobbleRequest(
                progress: progress,
                movie: media,
                show: nil,
                episode: nil
            )
        }

        do {
            try await TraktAuthService().authorizedPostEmpty(
                path: "scrobble/\(action.rawValue)",
                body: request
            )
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            return true
        } catch {
            return false
        }
    }

    private static func scrobbleMedia(for meta: NuvioMeta) -> TraktScrobbleMedia? {
        let firstIDComponent = meta.id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? meta.id
        let imdb = meta.imdbId ?? (firstIDComponent.hasPrefix("tt") ? firstIDComponent : nil)
        let tmdb = meta.tmdbId ?? (meta.id.hasPrefix("tmdb:")
            ? Int(meta.id.dropFirst("tmdb:".count))
            : nil)
        guard imdb != nil || tmdb != nil else { return nil }
        return TraktScrobbleMedia(ids: TraktScrobbleIDs(imdb: imdb, tmdb: tmdb))
    }

    private static func playbackSeed(from item: TraktPlaybackDTO, type: String) -> TraktProgressSeed? {
        let media = type == "movie" ? item.movie : item.show
        guard let media, let contentID = contentID(from: media.ids) else { return nil }
        guard let progress = normalizedProgress(item.progress),
              progress > 0,
              progress < completionPercent else { return nil }

        return TraktProgressSeed(
            contentID: contentID,
            type: type,
            title: media.title ?? contentID,
            year: media.year,
            progressPercent: progress,
            lastUpdated: traktDate(item.pausedAt) ?? Date(),
            season: item.episode?.season,
            episode: item.episode?.number,
            episodeTitle: item.episode?.title,
            isUpNext: false,
            ids: media.ids
        )
    }

    private static func nextUpSeed(from item: TraktWatchedShowDTO) -> TraktProgressSeed? {
        guard let show = item.show, let contentID = contentID(from: show.ids) else { return nil }
        let watched = item.seasons.orEmpty.flatMap { season -> [TraktWatchedEpisodeSeed] in
            guard let seasonNumber = season.number, seasonNumber > 0 else { return [] }
            return season.episodes.orEmpty.compactMap { episode in
                guard let number = episode.number,
                      number > 0,
                      (episode.plays ?? 1) > 0 else { return nil }
                return TraktWatchedEpisodeSeed(
                    season: seasonNumber,
                    episode: number,
                    watchedAt: traktDate(episode.lastWatchedAt ?? item.lastWatchedAt)
                )
            }
        }
        guard let latest = watched.max(by: { lhs, rhs in
            switch (lhs.watchedAt, rhs.watchedAt) {
            case let (left?, right?) where left != right: return left < right
            default: return (lhs.season, lhs.episode) < (rhs.season, rhs.episode)
            }
        }) else { return nil }

        return TraktProgressSeed(
            contentID: contentID,
            type: "series",
            title: show.title ?? contentID,
            year: show.year,
            progressPercent: 0,
            lastUpdated: latest.watchedAt ?? traktDate(item.lastWatchedAt) ?? Date(),
            season: latest.season,
            episode: latest.episode,
            episodeTitle: nil,
            isUpNext: true,
            ids: show.ids
        )
    }

    private static func nextUpSeed(from item: TraktEpisodeHistoryDTO) -> TraktProgressSeed? {
        guard let show = item.show,
              let episode = item.episode,
              let season = episode.season,
              let number = episode.number,
              season > 0,
              number > 0,
              let contentID = contentID(from: show.ids) else { return nil }

        return TraktProgressSeed(
            contentID: contentID,
            type: "series",
            title: show.title ?? contentID,
            year: show.year,
            progressPercent: 0,
            lastUpdated: traktDate(item.watchedAt) ?? Date(),
            season: season,
            episode: number,
            episodeTitle: episode.title,
            isUpNext: true,
            ids: show.ids
        )
    }

    private static func makeItem(
        from seed: TraktProgressSeed,
        repository: CatalogRepository
    ) async -> ContinueWatchingItem? {
        var meta = (try? await repository.getMetadata(id: seed.contentID, type: seed.type))
            ?? placeholderMeta(for: seed)

        var season = seed.season
        var episode = seed.episode
        var episodeTitle = seed.episodeTitle
        var episodeOverview: String?
        var episodeThumbnail: String?
        var released: String?

        if seed.type == "series", let currentSeason = season, let currentEpisode = episode {
            if seed.isUpNext {
                guard let next = nextEpisode(after: (currentSeason, currentEpisode), in: meta),
                      EpisodeReleasePolicy.shouldSurfaceNextEpisode(
                        watchedSeason: currentSeason,
                        candidateSeason: next.season,
                        released: next.released
                      ) else { return nil }
                season = next.season
                episode = next.episode
                episodeTitle = next.title
                episodeOverview = next.overview
                episodeThumbnail = next.thumbnail
                released = next.released
            } else if let matched = meta.videos?.first(where: {
                $0.season == currentSeason && $0.episode == currentEpisode
            }) {
                episodeTitle = episodeTitle ?? matched.title
                episodeOverview = matched.overview
                episodeThumbnail = matched.thumbnail
                released = matched.released
            }
        }

        // Prefer the canonical id and artwork returned by metadata, while a
        // lightweight fallback still lets a Trakt-only result open Details.
        if meta.id.isEmpty {
            meta = placeholderMeta(for: seed)
        }
        let duration = runtimeSeconds(for: meta)
        let position = seed.isUpNext
            ? 1.0
            : max(1.0, duration * seed.progressPercent / 100.0)

        return ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: position,
            duration: duration,
            lastWatchedAt: seed.lastUpdated,
            season: season,
            episode: episode,
            released: released,
            episodeTitleOverride: episodeTitle,
            episodeOverviewOverride: episodeOverview,
            episodeThumbnailOverride: episodeThumbnail,
            isUpNext: seed.isUpNext
        )
    }

    private static func nextEpisode(
        after current: (season: Int, episode: Int),
        in meta: NuvioMeta
    ) -> NuvioVideo? {
        let episodes = meta.videos.orEmpty
            .filter { $0.season > 0 }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        guard let index = episodes.firstIndex(where: {
            $0.season == current.season && $0.episode == current.episode
        }) else { return nil }
        let nextIndex = episodes.index(after: index)
        return episodes.indices.contains(nextIndex) ? episodes[nextIndex] : nil
    }

    private static func placeholderMeta(for seed: TraktProgressSeed) -> NuvioMeta {
        NuvioMeta(
            id: seed.contentID,
            name: seed.title,
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: seed.ids?.imdb,
            tmdbId: seed.ids?.tmdb,
            type: seed.type,
            year: seed.year,
            genres: nil,
            rating: nil,
            releaseInfo: seed.year.map(String.init),
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }

    private static func contentID(from ids: TraktProgressIDsDTO?) -> String? {
        if let imdb = ids?.imdb?.trimmingCharacters(in: .whitespacesAndNewlines), !imdb.isEmpty {
            return imdb
        }
        if let tmdb = ids?.tmdb { return "tmdb:\(tmdb)" }
        if let trakt = ids?.trakt { return "trakt:\(trakt)" }
        return nil
    }

    private static func normalizedProgress(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(max(value <= 1 ? value * 100 : value, 0), 100)
    }

    private static func traktDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func runtimeSeconds(for meta: NuvioMeta) -> Double {
        let fallback = meta.isSeries ? 45.0 * 60.0 : 120.0 * 60.0
        guard let raw = meta.runtime?.lowercased(), !raw.isEmpty else { return fallback }
        let values = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
        guard let first = values.first else { return fallback }
        if raw.contains("h") {
            let minutes = values.count > 1 ? values[1] : 0
            return max((first * 60 + minutes) * 60, 60)
        }
        return max(first * 60, 60)
    }
}

private struct TraktProgressSeed {
    let contentID: String
    let type: String
    let title: String
    let year: Int?
    let progressPercent: Double
    let lastUpdated: Date
    let season: Int?
    let episode: Int?
    let episodeTitle: String?
    let isUpNext: Bool
    let ids: TraktProgressIDsDTO?
}

private struct TraktScrobbleRequest: Encodable {
    let progress: Double
    let movie: TraktScrobbleMedia?
    let show: TraktScrobbleMedia?
    let episode: TraktScrobbleEpisode?
}

private struct TraktScrobbleMedia: Encodable {
    let ids: TraktScrobbleIDs
}

private struct TraktScrobbleIDs: Encodable {
    let imdb: String?
    let tmdb: Int?
}

private struct TraktScrobbleEpisode: Encodable {
    let season: Int
    let number: Int
}

private struct TraktWatchedEpisodeSeed {
    let season: Int
    let episode: Int
    let watchedAt: Date?
}

private struct TraktPlaybackDTO: Decodable {
    let progress: Double?
    let pausedAt: String?
    let movie: TraktProgressMediaDTO?
    let show: TraktProgressMediaDTO?
    let episode: TraktProgressEpisodeDTO?

    enum CodingKeys: String, CodingKey {
        case progress, movie, show, episode
        case pausedAt = "paused_at"
    }
}

private struct TraktProgressMediaDTO: Decodable {
    let title: String?
    let year: Int?
    let ids: TraktProgressIDsDTO?
    let overview: String?
    let rating: Double?
    let genres: [String]?
    let runtime: Int?
}

private struct TraktProgressEpisodeDTO: Decodable {
    let title: String?
    let season: Int?
    let number: Int?
}

private struct TraktProgressIDsDTO: Decodable {
    let trakt: Int?
    let imdb: String?
    let tmdb: Int?
}

private struct TraktWatchedShowDTO: Decodable {
    let lastWatchedAt: String?
    let show: TraktProgressMediaDTO?
    let seasons: [TraktWatchedSeasonDTO]?

    enum CodingKeys: String, CodingKey {
        case show, seasons
        case lastWatchedAt = "last_watched_at"
    }
}

private struct TraktEpisodeHistoryDTO: Decodable {
    let watchedAt: String?
    let show: TraktProgressMediaDTO?
    let episode: TraktProgressEpisodeDTO?

    enum CodingKeys: String, CodingKey {
        case show, episode
        case watchedAt = "watched_at"
    }
}

private struct TraktWatchedSeasonDTO: Decodable {
    let number: Int?
    let episodes: [TraktWatchedEpisodeDTO]?
}

private struct TraktWatchedEpisodeDTO: Decodable {
    let number: Int?
    let plays: Int?
    let lastWatchedAt: String?

    enum CodingKeys: String, CodingKey {
        case number, plays
        case lastWatchedAt = "last_watched_at"
    }
}

private extension Optional where Wrapped: RangeReplaceableCollection {
    var orEmpty: Wrapped { self ?? Wrapped() }
}

// MARK: - Library

/// Loads the Trakt-backed library without writing it into `LibraryStore`.
/// Trakt's library surface mirrors the other Nuvio clients: Watchlist plus
/// items from the user's personal lists.
struct TraktLibraryService {
    private static let maxItems = 200
    static let mutationNotification = Notification.Name("nuvio.tv.trakt.library.mutation")

    /// Mirrors Android TV's default Library action: when the user selected
    /// Trakt as the library source, add/remove the title from Trakt's watchlist
    /// instead of writing only to the hidden local library.
    static func setWatchlist(_ meta: NuvioMeta, isInWatchlist: Bool) async -> Bool {
        guard TraktSettingsStore.librarySourceMode == .trakt,
              TraktAuthStore.state.isAuthenticated,
              let body = watchlistMutation(for: meta) else {
            return false
        }

        do {
            let response: TraktWatchlistMutationResponse = try await TraktAuthService().authorizedPost(
                path: isInWatchlist ? "sync/watchlist" : "sync/watchlist/remove",
                body: body
            )
            guard response.applied(isInWatchlist: isInWatchlist) else { return false }
            NotificationCenter.default.post(
                name: mutationNotification,
                object: TraktLibraryMutation(meta: meta, isInWatchlist: isInWatchlist)
            )
            NotificationCenter.default.post(
                name: TraktSettingsStore.libraryChangedNotification,
                object: nil
            )
            return true
        } catch {
            return false
        }
    }

    static func fetchLibrary(repository: CatalogRepository) async -> [LibraryStoreItem]? {
        guard TraktSettingsStore.librarySourceMode == .trakt,
              TraktAuthStore.state.isAuthenticated else {
            return []
        }

        let service = TraktAuthService()
        guard await service.refreshTokenIfNeeded() else { return nil }

        var receivedResponse = false
        var seeds: [TraktLibrarySeed] = []

        if let movies: [TraktLibraryItemDTO] = try? await service.authorizedGet(
            path: "users/me/watchlist/movies/rank?extended=full&page=1&limit=1000"
        ) {
            receivedResponse = true
            seeds.append(contentsOf: movies.compactMap { seed(from: $0, type: "movie") })
        }

        if let shows: [TraktLibraryItemDTO] = try? await service.authorizedGet(
            path: "users/me/watchlist/shows/rank?extended=full&page=1&limit=1000"
        ) {
            receivedResponse = true
            seeds.append(contentsOf: shows.compactMap { seed(from: $0, type: "series") })
        }

        if let lists: [TraktPersonalListDTO] = try? await service.authorizedGet(
            path: "users/me/lists"
        ) {
            receivedResponse = true
            for list in lists where list.type?.lowercased() == "personal" {
                guard !Task.isCancelled, let identifier = listIdentifier(from: list.ids) else { continue }

                if let movies: [TraktLibraryItemDTO] = try? await service.authorizedGet(
                    path: "users/me/lists/\(identifier)/items/movie?extended=full&page=1&limit=1000"
                ) {
                    seeds.append(contentsOf: movies.compactMap { seed(from: $0, type: "movie") })
                }

                if let shows: [TraktLibraryItemDTO] = try? await service.authorizedGet(
                    path: "users/me/lists/\(identifier)/items/show?extended=full&page=1&limit=1000"
                ) {
                    seeds.append(contentsOf: shows.compactMap { seed(from: $0, type: "series") })
                }
            }
        }

        guard receivedResponse else { return nil }

        let sortedSeeds = seeds.sorted { $0.addedAt > $1.addedAt }
        var usedIDs = Set<String>()
        var results: [LibraryStoreItem] = []

        for seed in sortedSeeds {
            guard !Task.isCancelled, results.count < maxItems else { break }
            let key = "\(seed.type):\(seed.contentID)"
            guard usedIDs.insert(key).inserted else { continue }

            let meta = (try? await repository.getMetadata(id: seed.contentID, type: seed.type))
                ?? placeholderMeta(for: seed)
            results.append(LibraryStoreItem(meta: meta, addedAt: seed.addedAt))
        }
        return results
    }

    private static func seed(from item: TraktLibraryItemDTO, type: String) -> TraktLibrarySeed? {
        let media = type == "movie" ? item.movie : item.show
        guard let media, let contentID = contentID(from: media.ids) else { return nil }
        return TraktLibrarySeed(
            contentID: contentID,
            type: type,
            title: media.title ?? contentID,
            year: media.year,
            overview: media.overview,
            rating: media.rating,
            genres: media.genres,
            runtime: media.runtime,
            ids: media.ids,
            addedAt: traktDate(item.listedAt) ?? .distantPast
        )
    }

    private static func watchlistMutation(for meta: NuvioMeta) -> TraktWatchlistMutation? {
        let firstIDComponent = meta.id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? meta.id
        let imdb = meta.imdbId ?? (firstIDComponent.hasPrefix("tt") ? firstIDComponent : nil)
        let tmdb = meta.tmdbId ?? (meta.id.hasPrefix("tmdb:")
            ? Int(meta.id.dropFirst("tmdb:".count))
            : nil)
        let trakt = meta.id.hasPrefix("trakt:")
            ? Int(meta.id.dropFirst("trakt:".count))
            : nil
        guard imdb != nil || tmdb != nil || trakt != nil else { return nil }

        let item = TraktWatchlistMedia(
            title: meta.name,
            year: meta.year,
            ids: TraktWatchlistIDs(trakt: trakt, imdb: imdb, tmdb: tmdb)
        )
        return meta.isSeries
            ? TraktWatchlistMutation(movies: nil, shows: [item])
            : TraktWatchlistMutation(movies: [item], shows: nil)
    }

    private static func placeholderMeta(for seed: TraktLibrarySeed) -> NuvioMeta {
        NuvioMeta(
            id: seed.contentID,
            name: seed.title,
            description: seed.overview,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: seed.ids?.imdb,
            tmdbId: seed.ids?.tmdb,
            type: seed.type,
            year: seed.year,
            genres: seed.genres,
            rating: seed.rating,
            releaseInfo: seed.year.map(String.init),
            runtime: seed.runtime.map { "\($0) min" },
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        )
    }

    private static func contentID(from ids: TraktProgressIDsDTO?) -> String? {
        if let imdb = ids?.imdb?.trimmingCharacters(in: .whitespacesAndNewlines), !imdb.isEmpty {
            return imdb
        }
        if let tmdb = ids?.tmdb { return "tmdb:\(tmdb)" }
        if let trakt = ids?.trakt { return "trakt:\(trakt)" }
        return nil
    }

    private static func listIdentifier(from ids: TraktPersonalListIDsDTO?) -> String? {
        if let trakt = ids?.trakt { return String(trakt) }
        guard let slug = ids?.slug?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty else {
            return nil
        }
        return slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    }

    private static func traktDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct TraktLibrarySeed {
    let contentID: String
    let type: String
    let title: String
    let year: Int?
    let overview: String?
    let rating: Double?
    let genres: [String]?
    let runtime: Int?
    let ids: TraktProgressIDsDTO?
    let addedAt: Date
}

private struct TraktLibraryItemDTO: Decodable {
    let listedAt: String?
    let movie: TraktProgressMediaDTO?
    let show: TraktProgressMediaDTO?

    enum CodingKeys: String, CodingKey {
        case movie, show
        case listedAt = "listed_at"
    }
}

private struct TraktWatchlistMutation: Encodable {
    let movies: [TraktWatchlistMedia]?
    let shows: [TraktWatchlistMedia]?
}

private struct TraktWatchlistMedia: Encodable {
    let title: String
    let year: Int?
    let ids: TraktWatchlistIDs
}

private struct TraktWatchlistIDs: Encodable {
    let trakt: Int?
    let imdb: String?
    let tmdb: Int?
}

struct TraktLibraryMutation {
    let meta: NuvioMeta
    let isInWatchlist: Bool
}

private struct TraktWatchlistMutationResponse: Decodable {
    let added: TraktWatchlistMutationCount?
    let existing: TraktWatchlistMutationCount?
    let deleted: TraktWatchlistMutationCount?

    func applied(isInWatchlist: Bool) -> Bool {
        if isInWatchlist {
            return (added?.total ?? 0) + (existing?.total ?? 0) > 0
        }
        return (deleted?.total ?? 0) > 0
    }
}

private struct TraktWatchlistMutationCount: Decodable {
    let movies: Int?
    let shows: Int?

    var total: Int { (movies ?? 0) + (shows ?? 0) }
}

private struct TraktPersonalListDTO: Decodable {
    let type: String?
    let ids: TraktPersonalListIDsDTO?
}

private struct TraktPersonalListIDsDTO: Decodable {
    let trakt: Int?
    let slug: String?
}

private struct EmptyResponse: Decodable {}

private struct HTTPResult<T: Decodable> {
    let statusCode: Int
    let value: T?
    let errorMessage: String?

    func valueOrThrow() throws -> T {
        guard (200..<300).contains(statusCode) else {
            throw TraktServiceError.message(errorMessage ?? "Trakt request failed (\(statusCode)).")
        }
        guard let value else {
            throw TraktServiceError.message(errorMessage ?? "Trakt returned an empty response.")
        }
        return value
    }
}

private enum TraktServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}

@MainActor
final class TraktSettingsViewModel: ObservableObject {
    @Published var mode: TraktConnectionMode = .disconnected
    @Published var credentialsConfigured = false
    @Published var isLoading = false
    @Published var isStatsLoading = false
    @Published var isPolling = false
    @Published var username: String?
    @Published var deviceUserCode: String?
    @Published var verificationURL: String?
    @Published var deviceCodeExpiresAtMillis: Double?
    @Published var tokenExpiresAtMillis: Double?
    @Published var pollInterval = 5
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var connectedStats: TraktCachedStats?
    @Published var continueWatchingDaysCap = TraktSettingsStore.continueWatchingDaysCap
    @Published var showMetaComments = TraktSettingsStore.showMetaComments
    @Published var watchProgressSource = TraktSettingsStore.watchProgressSource
    @Published var librarySourceMode = TraktSettingsStore.librarySourceMode
    @Published var moreLikeThisSource = TraktSettingsStore.moreLikeThisSource

    private let store: UserDefaults
    private let service: TraktAuthService
    private var pollTask: Task<Void, Never>?

    init(store: UserDefaults = ProfileSettings.current) {
        self.store = store
        self.service = TraktAuthService(store: store)
        reload()
    }

    deinit {
        pollTask?.cancel()
    }

    func reload() {
        credentialsConfigured = service.hasRequiredCredentials()
        let state = service.currentState()
        username = state.username
        deviceUserCode = state.userCode
        verificationURL = state.verificationURL
        deviceCodeExpiresAtMillis = state.expiresAt
        tokenExpiresAtMillis = state.tokenExpiresAtMillis
        pollInterval = state.pollInterval ?? 5
        let isAuthenticated = state.isAuthenticated(in: store)
        mode = isAuthenticated
            ? .connected
            : (state.hasActiveDeviceFlow(in: store) ? .awaitingApproval : .disconnected)
        connectedStats = isAuthenticated ? TraktAuthStore.cachedStats(in: store) : nil
        continueWatchingDaysCap = TraktSettingsStore.continueWatchingDaysCap
        showMetaComments = TraktSettingsStore.showMetaComments
        watchProgressSource = TraktSettingsStore.watchProgressSource
        librarySourceMode = TraktSettingsStore.librarySourceMode
        moreLikeThisSource = TraktSettingsStore.moreLikeThisSource
        if mode == .awaitingApproval {
            startPolling()
        } else {
            pollTask?.cancel()
            isPolling = false
        }
    }

    func credentialsDidChange() {
        errorMessage = nil
        statusMessage = nil
        reload()
    }

    func connect() {
        guard !isLoading else { return }
        guard credentialsConfigured else {
            errorMessage = "Enter your Trakt Client ID and Client Secret first."
            return
        }
        isLoading = true
        statusMessage = nil
        errorMessage = nil
        Task {
            do {
                let response = try await service.startDeviceAuth()
                deviceUserCode = response.userCode
                verificationURL = response.verificationURL
                deviceCodeExpiresAtMillis = Date().timeIntervalSince1970 * 1000.0 + Double(response.expiresIn * 1000)
                pollInterval = response.interval
                mode = .awaitingApproval
                statusMessage = "Waiting for approval…"
                isLoading = false
                startPolling()
            } catch {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func cancelDeviceFlow() {
        pollTask?.cancel()
        TraktAuthStore.clearDeviceFlow(store: store)
        statusMessage = nil
        errorMessage = nil
        reload()
    }

    func retryPolling() {
        errorMessage = nil
        startPolling()
    }

    func disconnect() {
        pollTask?.cancel()
        isLoading = true
        Task {
            await service.revokeAndLogout()
            isLoading = false
            statusMessage = "Disconnected from Trakt."
            connectedStats = nil
            reload()
        }
    }

    func refreshNow() {
        guard mode == .connected else { return }
        isLoading = true
        isStatsLoading = true
        statusMessage = "Syncing Trakt..."
        errorMessage = nil
        Task {
            _ = await service.refreshTokenIfNeeded()
            _ = await service.fetchUserSettings()
            if let stats = await service.fetchUserStats() {
                TraktAuthStore.saveCachedStats(stats, store: store)
                connectedStats = stats
            }
            isStatsLoading = false
            isLoading = false
            statusMessage = "Trakt sync completed."
            reload()
        }
    }

    func loadConnectedData() {
        guard mode == .connected, !isLoading, !isStatsLoading else { return }
        isStatsLoading = true
        Task {
            guard await service.refreshTokenIfNeeded() else {
                isStatsLoading = false
                reload()
                return
            }
            if username?.isEmpty != false {
                _ = await service.fetchUserSettings()
            }
            if let stats = await service.fetchUserStats() {
                TraktAuthStore.saveCachedStats(stats, store: store)
                connectedStats = stats
            }
            isStatsLoading = false
            reload()
        }
    }

    func setLibrarySourceMode(_ source: TraktLibrarySourceMode) {
        librarySourceMode = source
        TraktSettingsStore.librarySourceMode = librarySourceMode
    }

    func setWatchProgressSource(_ source: TraktWatchProgressSource) {
        watchProgressSource = source
        TraktSettingsStore.watchProgressSource = watchProgressSource
    }

    func setContinueWatchingDaysCap(_ days: Int) {
        continueWatchingDaysCap = days
        TraktSettingsStore.continueWatchingDaysCap = continueWatchingDaysCap
    }

    func setShowMetaComments(_ show: Bool) {
        showMetaComments = show
        TraktSettingsStore.showMetaComments = showMetaComments
    }

    func setMoreLikeThisSource(_ source: TraktMoreLikeThisSource) {
        moreLikeThisSource = source
        TraktSettingsStore.moreLikeThisSource = moreLikeThisSource
    }

    private func startPolling() {
        pollTask?.cancel()
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let state = self.service.currentState()
                if let expiresAt = state.expiresAt,
                   Date().timeIntervalSince1970 * 1000.0 >= expiresAt {
                    self.errorMessage = "Trakt device code expired. Start again."
                    TraktAuthStore.clearDeviceFlow(store: self.store)
                    self.isPolling = false
                    self.reload()
                    return
                }

                let wait = UInt64(max(state.pollInterval ?? self.pollInterval, 5))
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                if Task.isCancelled { return }

                switch await self.service.pollDeviceToken() {
                case .pending:
                    self.statusMessage = "Waiting for Trakt approval..."
                case .alreadyUsed:
                    self.errorMessage = "This Trakt code was already used. Start again."
                    self.isPolling = false
                    self.reload()
                    return
                case .expired:
                    self.errorMessage = "Trakt device code expired. Start again."
                    self.isPolling = false
                    self.reload()
                    return
                case .denied:
                    self.errorMessage = "Trakt authorization was denied."
                    self.isPolling = false
                    self.reload()
                    return
                case .slowDown(let interval):
                    self.pollInterval = interval
                    self.statusMessage = "Trakt rate-limited polling. Slowing down..."
                case .approved(let username):
                    self.username = username
                    self.statusMessage = "Connected to Trakt."
                    self.isPolling = false
                    self.reload()
                    self.loadConnectedData()
                    return
                case .failed(let reason):
                    self.errorMessage = reason
                }
            }
        }
    }
}
