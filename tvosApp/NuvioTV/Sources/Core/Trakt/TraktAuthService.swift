import Foundation
import SwiftUI

enum TraktConfig {
    static var proxyURL: String {
        value(
            "TRAKT_PROXY_URL",
            fallback: "\(AuthConfig.normalizedAPIBaseURL)/functions/v1/trakt"
        )
    }

    static var proxyConfigured: Bool {
        AuthConfig.isConfigured &&
        !proxyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func value(_ key: String, fallback: String) -> String {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let resolved = resolvedValue(value) {
            return resolved
        }
        if let value = ProcessInfo.processInfo.environment[key],
           let resolved = resolvedValue(value) {
            return resolved
        }
        return fallback
    }

    private static func resolvedValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !(trimmed.hasPrefix("$(") && trimmed.hasSuffix(")")) else { return nil }
        return trimmed
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

struct TraktCachedStats: Equatable {
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

    var isAuthenticated: Bool {
        !(accessToken ?? "").isEmpty && !(refreshToken ?? "").isEmpty
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
    }

    static var state: TraktAuthState {
        let defaults = ProfileSettings.current
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
            pollInterval: intIfPresent(Key.pollInterval, defaults: defaults)
        )
    }

    static func saveDeviceFlow(_ response: TraktDeviceCodeResponse) {
        let defaults = ProfileSettings.current
        defaults.set(response.deviceCode, forKey: Key.deviceCode)
        defaults.set(response.userCode, forKey: Key.userCode)
        defaults.set(response.verificationURL, forKey: Key.verificationURL)
        defaults.set(Date().timeIntervalSince1970 * 1000.0 + Double(response.expiresIn * 1000), forKey: Key.expiresAt)
        defaults.set(response.interval, forKey: Key.pollInterval)
    }

    static func saveToken(_ response: TraktTokenResponse) {
        let defaults = ProfileSettings.current
        defaults.set(response.accessToken, forKey: Key.accessToken)
        defaults.set(response.refreshToken, forKey: Key.refreshToken)
        defaults.set(response.tokenType, forKey: Key.tokenType)
        defaults.set(response.createdAt, forKey: Key.createdAt)
        defaults.set(normalizeTokenLifetime(response.expiresIn), forKey: Key.expiresIn)
    }

    static func saveUser(username: String?, slug: String?) {
        let defaults = ProfileSettings.current
        setOptional(username, forKey: Key.username, defaults: defaults)
        setOptional(slug, forKey: Key.userSlug, defaults: defaults)
    }

    static func updatePollInterval(_ seconds: Int) {
        ProfileSettings.current.set(seconds, forKey: Key.pollInterval)
    }

    static func clearDeviceFlow() {
        let defaults = ProfileSettings.current
        [Key.deviceCode, Key.userCode, Key.verificationURL, Key.expiresAt, Key.pollInterval].forEach {
            defaults.removeObject(forKey: $0)
        }
    }

    static func clearAuth() {
        let defaults = ProfileSettings.current
        [
            Key.accessToken, Key.refreshToken, Key.tokenType, Key.createdAt, Key.expiresIn,
            Key.username, Key.userSlug, Key.deviceCode, Key.userCode, Key.verificationURL,
            Key.expiresAt, Key.pollInterval
        ].forEach { defaults.removeObject(forKey: $0) }
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
        expiresIn <= 0 ? 86_400 : min(expiresIn, 86_400)
    }
}

enum TraktSettingsStore {
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
            ProfileSettings.current.set(
                normalizeContinueWatchingDaysCap(newValue),
                forKey: SettingsKey.traktContinueWatchingDaysCap
            )
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
        set { ProfileSettings.current.set(newValue.rawValue, forKey: SettingsKey.traktWatchProgressSource) }
    }

    static var librarySourceMode: TraktLibrarySourceMode {
        get {
            let raw = ProfileSettings.current.string(forKey: SettingsKey.traktLibrarySourceMode)
            return TraktLibrarySourceMode(rawValue: raw ?? "") ?? TraktDefaults.librarySourceMode
        }
        set { ProfileSettings.current.set(newValue.rawValue, forKey: SettingsKey.traktLibrarySourceMode) }
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

private struct TraktDeviceCodeRequest: Encodable {}

private struct TraktDeviceTokenRequest: Encodable {
    let code: String
}

private struct TraktRefreshTokenRequest: Encodable {
    let refreshToken: String
    let grantType = "refresh_token"
    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case grantType = "grant_type"
    }
}

private struct TraktRevokeRequest: Encodable {
    let token: String
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

private struct TraktAccountSessionResponse: Decodable {
    let accessToken: String
    let tokenType: String?
    let expiresIn: Int?
    let refreshToken: String
    let createdAt: Int?
    let username: String?
    let userSlug: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case createdAt = "created_at"
        case username
        case userSlug = "user_slug"
    }

    var tokenResponse: TraktTokenResponse {
        TraktTokenResponse(
            accessToken: accessToken,
            tokenType: tokenType ?? "bearer",
            expiresIn: expiresIn ?? 7_776_000,
            refreshToken: refreshToken,
            createdAt: createdAt ?? Int(Date().timeIntervalSince1970)
        )
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
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let authService = AuthService()
    private let nuvioSessionStore = SessionStore()
    private let refreshLeewaySeconds = 60

    init(session: URLSession = .shared) {
        self.session = session
    }

    func hasRequiredCredentials() -> Bool {
        TraktConfig.proxyConfigured
    }

    func currentState() -> TraktAuthState {
        TraktAuthStore.state
    }

    func importAccountConnection() async throws -> Bool {
        guard hasRequiredCredentials() else {
            throw TraktServiceError.message("Nuvio Trakt proxy is not configured.")
        }
        guard let nuvioSession = await validNuvioSession() else {
            throw TraktServiceError.message("Sign into your Nuvio account before fetching Trakt.")
        }

        var request = baseRequest(path: "account/session")
        request.httpMethod = "GET"
        request.setValue("Bearer \(nuvioSession.accessToken)", forHTTPHeaderField: "Authorization")
        let result: HTTPResult<TraktAccountSessionResponse> = try await perform(request)
        if result.statusCode == 404 {
            return false
        }
        let accountSession = try result.valueOrThrow()

        TraktAuthStore.saveToken(accountSession.tokenResponse)
        TraktAuthStore.saveUser(
            username: accountSession.username,
            slug: accountSession.userSlug
        )
        TraktAuthStore.clearDeviceFlow()
        return true
    }

    func startDeviceAuth() async throws -> TraktDeviceCodeResponse {
        guard hasRequiredCredentials() else {
            throw TraktServiceError.message("Nuvio Trakt proxy is not configured.")
        }

        let state = currentState()
        if let deviceCode = state.deviceCode,
           let expiresAt = state.expiresAt,
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
            body: TraktDeviceCodeRequest(),
            authorized: false
        )
        TraktAuthStore.saveDeviceFlow(response)
        return response
    }

    func pollDeviceToken() async -> TraktPollResult {
        guard hasRequiredCredentials() else {
            return .failed("Nuvio Trakt proxy is not configured.")
        }
        guard let deviceCode = currentState().deviceCode, !deviceCode.isEmpty else {
            return .failed("No active Trakt device code.")
        }

        do {
            let response: HTTPResult<TraktTokenResponse> = try await postResult(
                path: "oauth/device/token",
                body: TraktDeviceTokenRequest(code: deviceCode),
                authorized: false
            )
            if let token = response.value, (200..<300).contains(response.statusCode) {
                TraktAuthStore.saveToken(token)
                TraktAuthStore.clearDeviceFlow()
                let username = await fetchUserSettings()
                return .approved(username)
            }
            switch response.statusCode {
            case 400: return .pending
            case 409:
                TraktAuthStore.clearDeviceFlow()
                return .alreadyUsed
            case 410:
                TraktAuthStore.clearDeviceFlow()
                return .expired
            case 418:
                TraktAuthStore.clearDeviceFlow()
                return .denied
            case 429:
                let next = min((currentState().pollInterval ?? 5) + 5, 60)
                TraktAuthStore.updatePollInterval(next)
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
        guard let refreshToken = state.refreshToken else { return false }
        if !force && !isTokenExpiredOrExpiring(state) { return true }

        do {
            let response: HTTPResult<TraktTokenResponse> = try await postResult(
                path: "oauth/token",
                body: TraktRefreshTokenRequest(refreshToken: refreshToken),
                authorized: false
            )
            guard let token = response.value, (200..<300).contains(response.statusCode) else {
                if response.statusCode == 401 || response.statusCode == 403 {
                    TraktAuthStore.clearAuth()
                }
                return false
            }
            TraktAuthStore.saveToken(token)
            return true
        } catch {
            return false
        }
    }

    func revokeAndLogout() async {
        let state = currentState()
        if hasRequiredCredentials(), let accessToken = state.accessToken {
            try? await postEmpty(
                path: "oauth/revoke",
                body: TraktRevokeRequest(token: accessToken),
                authorized: false
            )
        }
        TraktAuthStore.clearAuth()
    }

    func fetchUserSettings() async -> String? {
        guard let response: TraktUserSettingsResponse = try? await authorizedGet(path: "users/settings") else {
            return nil
        }
        let username = response.user?.username
        let slug = response.user?.ids?.slug
        TraktAuthStore.saveUser(username: username, slug: slug)
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

    private func authorizedGet<T: Decodable>(path: String) async throws -> T {
        guard await refreshTokenIfNeeded(), let token = currentState().accessToken else {
            throw TraktServiceError.message("Not authenticated with Trakt.")
        }
        var request = baseRequest(path: path)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Trakt-Access-Token")
        let result: HTTPResult<T> = try await perform(request)
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
        // Prefer decoding only on success so proxy error payloads never surface as
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
            errorMessage: Self.friendlyProxyError(rawError, status: http.statusCode)
        )
    }

    private func baseRequest(path: String) -> URLRequest {
        let normalizedBase = TraktConfig.proxyURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "\(normalizedBase)/\(path)")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(AuthConfig.apiKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(AuthConfig.apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func isTokenExpiredOrExpiring(_ state: TraktAuthState) -> Bool {
        guard let createdAt = state.createdAt, let expiresIn = state.expiresIn else { return true }
        let now = Int(Date().timeIntervalSince1970)
        return now >= createdAt + expiresIn - refreshLeewaySeconds
    }

    private func validNuvioSession() async -> AuthSession? {
        guard let stored = nuvioSessionStore.load() else { return nil }
        guard stored.isExpired else { return stored }
        guard let refreshed = try? await authService.refresh(refreshToken: stored.refreshToken) else {
            return nil
        }
        nuvioSessionStore.save(refreshed)
        return refreshed
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

    /// Maps known Nuvio edge-function boot failures to an actionable message.
    private static func friendlyProxyError(_ raw: String?, status: Int) -> String? {
        let lowered = (raw ?? "").lowercased()
        if lowered.contains("invalidworkercreation")
            || lowered.contains("entrypoint")
            || lowered.contains("bootstrap runtime") {
            return "Trakt login service is down on the Nuvio server (edge function failed to start). Redeploy functions/v1/trakt with TRAKT_CLIENT_ID and TRAKT_CLIENT_SECRET, then try again."
        }
        if status == 502 || status == 503 || status == 504 {
            return raw ?? "Trakt login service is temporarily unavailable (\(status))."
        }
        if status >= 500 {
            return raw ?? "Trakt login service error (\(status))."
        }
        return raw
    }
}

private struct EmptyResponse: Decodable {}

private struct HTTPResult<T: Decodable> {
    let statusCode: Int
    let value: T?
    let errorMessage: String?

    func valueOrThrow() throws -> T {
        guard (200..<300).contains(statusCode) else {
            throw TraktServiceError.message(errorMessage ?? "Nuvio Trakt request failed (\(statusCode)).")
        }
        guard let value else {
            throw TraktServiceError.message(errorMessage ?? "Nuvio Trakt proxy returned an empty response.")
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
    @Published var credentialsConfigured = TraktConfig.proxyConfigured
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

    private let service = TraktAuthService()
    private var pollTask: Task<Void, Never>?
    private var didAutoFetchAccountConnection = false

    init() {
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
        mode = state.isAuthenticated ? .connected : (state.deviceCode == nil ? .disconnected : .awaitingApproval)
        continueWatchingDaysCap = TraktSettingsStore.continueWatchingDaysCap
        showMetaComments = TraktSettingsStore.showMetaComments
        watchProgressSource = TraktSettingsStore.watchProgressSource
        librarySourceMode = TraktSettingsStore.librarySourceMode
        moreLikeThisSource = TraktSettingsStore.moreLikeThisSource
        if mode == .awaitingApproval {
            startPolling()
        }
    }

    func fetchAccountConnection(auto: Bool = false) {
        guard !isLoading else { return }
        guard credentialsConfigured else {
            errorMessage = "Nuvio Trakt proxy is not configured."
            return
        }
        if auto {
            guard !didAutoFetchAccountConnection, mode == .disconnected else { return }
            didAutoFetchAccountConnection = true
        }
        isLoading = true
        statusMessage = auto ? "Checking your Nuvio account for Trakt..." : nil
        errorMessage = nil
        Task {
            do {
                if try await service.importAccountConnection() {
                    connectedStats = await service.fetchUserStats()
                    statusMessage = "Connected to Trakt from your Nuvio account."
                    isLoading = false
                    reload()
                } else {
                    statusMessage = auto ? nil : "No Trakt connection was found on your Nuvio account."
                    isLoading = false
                }
            } catch {
                if auto {
                    statusMessage = nil
                } else {
                    errorMessage = error.localizedDescription
                }
                isLoading = false
            }
        }
    }

    func connect() {
        guard !isLoading else { return }
        guard credentialsConfigured else {
            errorMessage = "Nuvio Trakt proxy is not configured."
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
        TraktAuthStore.clearDeviceFlow()
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
            _ = await service.refreshTokenIfNeeded(force: true)
            _ = await service.fetchUserSettings()
            connectedStats = await service.fetchUserStats()
            isStatsLoading = false
            isLoading = false
            statusMessage = "Trakt sync completed."
            reload()
        }
    }

    func cycleLibrarySource() {
        let values = TraktLibrarySourceMode.allCases
        librarySourceMode = nextValue(current: librarySourceMode, in: values)
        TraktSettingsStore.librarySourceMode = librarySourceMode
    }

    func cycleWatchProgressSource() {
        let values = TraktWatchProgressSource.allCases
        watchProgressSource = nextValue(current: watchProgressSource, in: values)
        TraktSettingsStore.watchProgressSource = watchProgressSource
    }

    func cycleContinueWatchingDaysCap() {
        let values = [14, 30, 60, 90, 180, 365, TraktDefaults.continueWatchingDaysCapAll]
        continueWatchingDaysCap = nextValue(current: continueWatchingDaysCap, in: values)
        TraktSettingsStore.continueWatchingDaysCap = continueWatchingDaysCap
    }

    func toggleComments() {
        showMetaComments.toggle()
        TraktSettingsStore.showMetaComments = showMetaComments
    }

    func cycleMoreLikeThisSource() {
        let values = TraktMoreLikeThisSource.allCases
        moreLikeThisSource = nextValue(current: moreLikeThisSource, in: values)
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
                    TraktAuthStore.clearDeviceFlow()
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
                    self.refreshNow()
                    return
                case .failed(let reason):
                    self.errorMessage = reason
                }
            }
        }
    }

    private func nextValue<T: Equatable>(current: T, in values: [T]) -> T {
        guard let index = values.firstIndex(of: current) else { return values.first ?? current }
        return values[(index + 1) % values.count]
    }
}
