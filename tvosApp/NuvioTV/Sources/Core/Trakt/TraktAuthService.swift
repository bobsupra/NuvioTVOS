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

enum TraktWatchProgressSource: String, CaseIterable, Codable {
    case trakt = "TRAKT"
    case simkl = "SIMKL"
    case nuvioSync = "NUVIO_SYNC"

    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .simkl: return "Simkl"
        case .nuvioSync: return "Nuvio Sync"
        }
    }
}

enum TraktLibrarySourceMode: String, CaseIterable {
    case trakt = "TRAKT"
    case simkl = "SIMKL"
    case local = "LOCAL"

    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .simkl: return "Simkl"
        case .local: return "Nuvio Library"
        }
    }
}

enum TraktMoreLikeThisSource: String, CaseIterable {
    case trakt = "TRAKT"
    case tmdb = "TMDB"
    case simkl = "SIMKL"

    var label: String {
        switch self {
        case .trakt: return "Trakt"
        case .tmdb: return "TMDB"
        case .simkl: return "Simkl"
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
    /// Nuvio Sync, not Trakt. The old default named a provider the user had not
    /// necessarily connected, and because every Trakt/Simkl write is gated on the
    /// selected source matching, a Simkl-only account silently scrobbled nowhere.
    /// Connecting a tracker now selects it (see `selectWatchProgressSourceOnConnect`).
    static let watchProgressSource = TraktWatchProgressSource.nuvioSync
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
            watchProgressSource(in: ProfileSettings.current)
        }
        set {
            guard newValue != watchProgressSource else { return }
            ProfileSettings.current.set(newValue.rawValue, forKey: SettingsKey.traktWatchProgressSource)
            NotificationCenter.default.post(name: continueWatchingChangedNotification, object: nil)
        }
    }

    static func watchProgressSource(in defaults: UserDefaults) -> TraktWatchProgressSource {
        let raw = defaults.string(forKey: SettingsKey.traktWatchProgressSource)
        return TraktWatchProgressSource(rawValue: raw ?? "") ?? TraktDefaults.watchProgressSource
    }

    /// True once the user has picked a source from the Settings row themselves.
    static func watchProgressSourceChosenByUser(in defaults: UserDefaults = ProfileSettings.current) -> Bool {
        defaults.bool(forKey: SettingsKey.watchProgressSourceChosenByUser)
    }

    /// Records an explicit choice, so connecting a tracker later never silently
    /// overrides what the user asked for.
    static func markWatchProgressSourceChosenByUser(in defaults: UserDefaults = ProfileSettings.current) {
        defaults.set(true, forKey: SettingsKey.watchProgressSourceChosenByUser)
    }

    /// One-time upgrade step for installs that never stored a source.
    ///
    /// The default used to be `.trakt`, so a Trakt user who never opened the
    /// picker relied on it. Flipping the default to `.nuvioSync` would silently
    /// stop their scrobbling, so resolve the absent value once from whichever
    /// tracker this profile actually has credentials for and write it down.
    static func migrateWatchProgressSourceIfNeeded(
        in defaults: UserDefaults,
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage(),
        profileScope: String? = nil
    ) {
        guard defaults.string(forKey: SettingsKey.traktWatchProgressSource) == nil else { return }
        let resolved: TraktWatchProgressSource
        if TraktAuthStore.state(in: defaults).isAuthenticated(in: defaults) {
            resolved = .trakt
        } else if SimklRuntimeSession.authenticatedState(
            store: defaults,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        ) != nil {
            resolved = .simkl
        } else {
            resolved = .nuvioSync
        }
        defaults.set(resolved.rawValue, forKey: SettingsKey.traktWatchProgressSource)
    }

    /// Points watch progress at a tracker the user has just connected.
    ///
    /// Connecting Trakt or Simkl is the clearest possible statement that the user
    /// wants their playback to land there, and every write path is gated on this
    /// value. Without this, "Connected" was shown while nothing was ever sent.
    /// An explicit choice already on record always wins.
    static func selectWatchProgressSourceOnConnect(
        _ source: TraktWatchProgressSource,
        in defaults: UserDefaults = ProfileSettings.current
    ) {
        guard source != .nuvioSync else { return }
        guard !watchProgressSourceChosenByUser(in: defaults) else { return }
        guard watchProgressSource(in: defaults) != source else { return }
        defaults.set(source.rawValue, forKey: SettingsKey.traktWatchProgressSource)
        NotificationCenter.default.post(name: continueWatchingChangedNotification, object: nil)
    }

    static var librarySourceMode: TraktLibrarySourceMode {
        get {
            librarySourceMode(in: ProfileSettings.current)
        }
        set {
            guard newValue != librarySourceMode else { return }
            ProfileSettings.current.set(newValue.rawValue, forKey: SettingsKey.traktLibrarySourceMode)
            NotificationCenter.default.post(name: libraryChangedNotification, object: nil)
        }
    }

    static func librarySourceMode(in defaults: UserDefaults) -> TraktLibrarySourceMode {
        let raw = defaults.string(forKey: SettingsKey.traktLibrarySourceMode)
        return TraktLibrarySourceMode(rawValue: raw ?? "") ?? TraktDefaults.librarySourceMode
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

enum RemoteTrackingState {
    static var isProgressSourceAuthenticated: Bool {
        isProgressSourceAuthenticated(in: ProfileSettings.current)
    }

    static func isProgressSourceAuthenticated(in store: UserDefaults) -> Bool {
        switch TraktSettingsStore.watchProgressSource(in: store) {
        case .nuvioSync:
            return false
        case .trakt:
            return TraktAuthStore.state(in: store).isAuthenticated(in: store)
        case .simkl:
            return SimklRuntimeSession.authenticatedState(store: store) != nil
        }
    }

    static func routesWatchedHistory(
        to target: TraktWatchProgressSource,
        selectedSource: TraktWatchProgressSource
    ) -> Bool {
        target != .nuvioSync && target == selectedSource
    }

    static func shouldSyncWatchedHistory(
        to target: TraktWatchProgressSource,
        in store: UserDefaults = ProfileSettings.current
    ) -> Bool {
        let selectedSource = TraktSettingsStore.watchProgressSource(in: store)
        guard routesWatchedHistory(to: target, selectedSource: selectedSource) else {
            return false
        }
        switch target {
        case .nuvioSync:
            return false
        case .trakt:
            return TraktAuthStore.state(in: store).isAuthenticated(in: store)
        case .simkl:
            return SimklRuntimeSession.authenticatedState(store: store) != nil
        }
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
                // Same reasoning as the Simkl connect path: point watch progress
                // at the tracker the user just linked, unless they have already
                // chosen a source by hand.
                TraktSettingsStore.selectWatchProgressSourceOnConnect(.trakt, in: store)
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

@MainActor
struct TraktProgressService {
    private static let completionPercent = 90.0
    private static let maxItems = 20
    /// Long enough to outlive an app relaunch plus Simkl's 20-second per-user
    /// scrobble lock. Kept to an hour so a checkpoint the server never confirms
    /// (for example the title was marked watched on another device) cannot linger
    /// as a ghost card for a whole session.
    private static let localCheckpointLifetime: TimeInterval = 60 * 60
    private static let checkpointStorageKey = "nuvio.tv.remoteProgress.localCheckpoints.v1"

    private struct LocalPlaybackCheckpoint: Codable {
        let profileId: String?
        let source: TraktWatchProgressSource
        let item: ContinueWatchingItem
    }

    private struct ContinueWatchingSnapshot {
        let profileId: String?
        let source: TraktWatchProgressSource
        let items: [ContinueWatchingItem]
    }

    /// Optimistic positions bridge the interval between leaving playback and the
    /// provider returning the newly-scrobbled timestamp from `sync/playback`.
    /// They are deliberately separate from ContinueWatchingStore so choosing
    /// Trakt never contaminates Nuvio Sync's independent progress ledger.
    ///
    /// Persisted: these used to be memory-only, so quitting the app during the
    /// window when the provider had not yet published the scrobble left the title
    /// missing from Continue Watching with nothing to mask the gap.
    private static var cachedCheckpoints: [LocalPlaybackCheckpoint]?
    private static var localPlaybackCheckpoints: [LocalPlaybackCheckpoint] {
        get {
            if let cachedCheckpoints { return cachedCheckpoints }
            let loaded = loadCheckpoints()
            cachedCheckpoints = loaded
            return loaded
        }
        set {
            cachedCheckpoints = newValue
            saveCheckpoints(newValue)
        }
    }

    private static func loadCheckpoints() -> [LocalPlaybackCheckpoint] {
        guard let data = UserDefaults.standard.data(forKey: checkpointStorageKey),
              let decoded = try? checkpointDecoder().decode(
                  [LocalPlaybackCheckpoint].self,
                  from: data
              ) else {
            return []
        }
        return decoded
    }

    private static func saveCheckpoints(_ checkpoints: [LocalPlaybackCheckpoint]) {
        guard !checkpoints.isEmpty else {
            UserDefaults.standard.removeObject(forKey: checkpointStorageKey)
            return
        }
        guard let data = try? checkpointEncoder().encode(checkpoints) else { return }
        UserDefaults.standard.set(data, forKey: checkpointStorageKey)
    }

    private static func checkpointEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    private static func checkpointDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }
    /// Last list handed to Home for each profile. Details and an already-rendered
    /// Home card use this synchronously, avoiding a stale resume position while
    /// a replacement Trakt fetch is still in flight.
    private static var continueWatchingSnapshots: [ContinueWatchingSnapshot] = []

    static func currentContinueWatchingItem(
        for meta: NuvioMeta,
        source sourceOverride: TraktWatchProgressSource? = nil
    ) -> ContinueWatchingItem? {
        pruneExpiredLocalCheckpoints()
        let profileId = ContinueWatchingStore.activeProfileId
        let source = sourceOverride ?? TraktSettingsStore.watchProgressSource
        if let local = localPlaybackCheckpoints.first(where: {
            $0.profileId == profileId
                && $0.source == source
                && WatchedStore.sameContent($0.item.meta, meta)
        })?.item {
            return local
        }
        return continueWatchingSnapshots.first(where: {
            $0.profileId == profileId && $0.source == source
        })?
            .items.first(where: { WatchedStore.sameContent($0.meta, meta) })
    }

    static func recordLocalPlayback(
        meta: NuvioMeta,
        position: Double,
        duration: Double,
        season: Int?,
        episode: Int?,
        source sourceOverride: TraktWatchProgressSource? = nil,
        notify: Bool
    ) {
        guard position.isFinite,
              duration.isFinite,
              position > 0,
              duration > 0 else { return }

        let profileId = ContinueWatchingStore.activeProfileId
        let source = sourceOverride ?? TraktSettingsStore.watchProgressSource
        // Going back to a title retires the removal the user made earlier, so a
        // provider row they are actively watching again is never hidden.
        ContinueWatchingDismissStore.clear(contentId: meta.id)
        localPlaybackCheckpoints.removeAll {
            $0.profileId == profileId
                && $0.source == source
                && WatchedStore.sameContent($0.item.meta, meta)
        }

        let progressPercent = position / duration * 100
        if progressPercent < completionPercent {
            let video = meta.videos?.first {
                $0.season == season && $0.episode == episode
            }
            localPlaybackCheckpoints.append(
                LocalPlaybackCheckpoint(
                    profileId: profileId,
                    source: source,
                    item: ContinueWatchingItem(
                        // Snapshot drops the episode guide, which can run to
                        // megabytes — tvOS aborts the process on a UserDefaults
                        // value that large. The overrides below already carry
                        // everything the card renders.
                        meta: meta.persistenceSnapshot,
                        streamUrl: "",
                        position: position,
                        duration: duration,
                        lastWatchedAt: Date(),
                        season: season,
                        episode: episode,
                        released: video?.released,
                        episodeTitleOverride: video?.title,
                        episodeOverviewOverride: video?.overview,
                        episodeThumbnailOverride: video?.thumbnail,
                        isUpNext: false
                    )
                )
            )
        } else {
            removeFromContinueWatchingSnapshot(profileId: profileId, source: source) {
                WatchedStore.sameContent($0.meta, meta)
            }
        }

        if notify {
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
        }
    }

    /// Drops a title from the optimistic layers that sit in front of the
    /// provider's list, so a card the user removed cannot be re-shown by a
    /// checkpoint or the snapshot of the last fetch while the row refreshes.
    ///
    /// `season`/`episode` narrow the removal to one episode — what a watched
    /// mark clears, since another episode of the same show may still be
    /// legitimately in progress. `recordedNoLaterThan` keeps progress made
    /// *after* the mark (the user carried on watching), mirroring how
    /// ``ContinueWatchingStore/removeWatched(_:)`` settles the same race.
    static func forgetLocalPlayback(
        meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil,
        recordedNoLaterThan cutoff: Date? = nil,
        notify: Bool = false
    ) {
        let profileId = ContinueWatchingStore.activeProfileId
        let source = TraktSettingsStore.watchProgressSource
        let matchesRemoval: (ContinueWatchingItem) -> Bool = { item in
            guard WatchedStore.sameContent(item.meta, meta) else { return false }
            if let cutoff, item.lastWatchedAt > cutoff { return false }
            guard let season, let episode else { return true }
            // A row that never recorded its episode cannot be attributed to this
            // mark, and Details only draws a bar for a row that names one.
            guard let rowSeason = item.season, let rowEpisode = item.episode else { return false }
            return rowSeason == season && rowEpisode == episode
        }

        let removingCheckpoints = localPlaybackCheckpoints.contains {
            $0.profileId == profileId && $0.source == source && matchesRemoval($0.item)
        }
        if removingCheckpoints {
            localPlaybackCheckpoints.removeAll {
                $0.profileId == profileId && $0.source == source && matchesRemoval($0.item)
            }
        }
        let removedFromSnapshot = removeFromContinueWatchingSnapshot(
            profileId: profileId,
            source: source,
            where: matchesRemoval
        )

        // The caller's own store notification has already been posted by now, so
        // a view that reads this layer needs its own signal to look again.
        if notify, removingCheckpoints || removedFromSnapshot {
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
        }
    }

    static func fetchContinueWatching(
        repository: CatalogRepository,
        source sourceOverride: TraktWatchProgressSource? = nil,
        updateDisplayedSnapshot: Bool = true
    ) async -> [ContinueWatchingItem]? {
        let source = sourceOverride ?? TraktSettingsStore.watchProgressSource
        #if DEBUG
        print("[ContinueWatching] Provider fetch started source=\(source.rawValue)")
        #endif
        if source == .simkl {
            guard SimklRuntimeSession.authenticatedState() != nil else { return [] }
            guard let items = await SimklProgressService.fetchContinueWatching(
                repository: repository
            ) else { return nil }
            let resolvedItems = updateDisplayedSnapshot
                ? mergingLocalPlaybackCheckpoints(into: items, source: source)
                : items
            if updateDisplayedSnapshot {
                replaceContinueWatchingSnapshot(resolvedItems, source: source)
            }
            return resolvedItems
        }

        guard source == .trakt,
              TraktAuthStore.state.isAuthenticated else {
            return []
        }

        let service = TraktAuthService()
        guard await service.refreshTokenIfNeeded() else {
            #if DEBUG
            print("[ContinueWatching] Trakt token refresh failed")
            #endif
            return nil
        }

        async let moviesRequest: [TraktPlaybackDTO]? = fetchList(
            TraktPlaybackDTO.self,
            path: "sync/playback/movies",
            service: service
        )
        async let episodesRequest: [TraktPlaybackDTO]? = fetchList(
            TraktPlaybackDTO.self,
            path: "sync/playback/episodes",
            service: service
        )
        async let watchedShowsRequest: [TraktWatchedShowDTO]? = fetchList(
            TraktWatchedShowDTO.self,
            path: "sync/watched/shows",
            service: service
        )
        async let episodeHistoryRequest: [TraktEpisodeHistoryDTO]? = fetchList(
            TraktEpisodeHistoryDTO.self,
            path: "users/me/history/episodes?page=1&limit=100",
            service: service
        )

        let (movies, episodes, watchedShows, episodeHistory) = await (
            moviesRequest,
            episodesRequest,
            watchedShowsRequest,
            episodeHistoryRequest
        )
        #if DEBUG
        print(
            "[ContinueWatching] Trakt lists movies=\(movies?.count.description ?? "failed") "
                + "episodes=\(episodes?.count.description ?? "failed") "
                + "shows=\(watchedShows?.count.description ?? "failed") "
                + "history=\(episodeHistory?.count.description ?? "failed")"
        )
        #endif
        guard movies != nil || episodes != nil || watchedShows != nil || episodeHistory != nil else {
            return nil
        }

        var seeds =
            movies.orEmpty.compactMap { playbackSeed(from: $0, type: "movie") }
            + episodes.orEmpty.compactMap { playbackSeed(from: $0, type: "series") }
        let playbackIDs = Set(seeds.map(\.contentID))
        let preferFurthestEpisode = UpNextEpisodeSelectionPolicy.prefersFurthestEpisode

        let watchedShowSeeds: [TraktProgressSeed] = watchedShows.orEmpty.compactMap { show in
            guard let seed = nextUpSeed(
                from: show,
                preferFurthestEpisode: preferFurthestEpisode
            ), !playbackIDs.contains(seed.contentID) else {
                return nil
            }
            return seed
        }
        seeds.append(contentsOf: watchedShowSeeds)
        let watchedShowIDs = Set(watchedShowSeeds.map(\.contentID))

        // Some Trakt accounts return watched shows with an empty `seasons`
        // array even though episode history and stats are present. History is
        // the authoritative fallback for choosing the next episode in that case.
        var historySeedsByContentID: [String: TraktProgressSeed] = [:]
        for history in episodeHistory.orEmpty {
            guard let candidate = nextUpSeed(from: history),
                  !playbackIDs.contains(candidate.contentID),
                  !watchedShowIDs.contains(candidate.contentID) else {
                continue
            }
            if let current = historySeedsByContentID[candidate.contentID] {
                guard UpNextEpisodeSelectionPolicy.prefers(
                    candidateSeason: candidate.season ?? 0,
                    candidateEpisode: candidate.episode ?? 0,
                    candidateWatchedAt: candidate.lastUpdated,
                    over: current.season ?? 0,
                    currentEpisode: current.episode ?? 0,
                    currentWatchedAt: current.lastUpdated,
                    preferFurthestEpisode: preferFurthestEpisode
                ) else { continue }
            }
            historySeedsByContentID[candidate.contentID] = candidate
        }
        seeds.append(contentsOf: historySeedsByContentID.values)

        let cutoff: Date? = {
            let days = TraktSettingsStore.continueWatchingDaysCap
            guard days != TraktDefaults.continueWatchingDaysCapAll else { return nil }
            return Calendar.current.date(byAdding: .day, value: -days, to: Date())
        }()

        let recentSeeds = seeds
            .filter { cutoff == nil || $0.lastUpdated >= cutoff! }
            .sorted {
                ordersBefore(
                    isUpNext: $0.isUpNext,
                    updatedAt: $0.lastUpdated,
                    otherIsUpNext: $1.isUpNext,
                    otherUpdatedAt: $1.lastUpdated
                )
            }

        var usedContentIDs = Set<String>()
        let uniqueSeeds = recentSeeds.filter {
            usedContentIDs.insert($0.contentID).inserted
        }
        let metadataTasks = uniqueSeeds.prefix(maxItems).enumerated().map { index, seed in
            Task { @MainActor in
                (index, seed.title, await makeItem(from: seed, repository: repository))
            }
        }
        var indexedItems: [(Int, ContinueWatchingItem)] = []
        for task in metadataTasks {
            guard !Task.isCancelled else {
                #if DEBUG
                print("[ContinueWatching] Trakt metadata assembly cancelled")
                #endif
                return nil
            }
            let (index, title, item) = await task.value
            if let item {
                indexedItems.append((index, item))
            } else {
                #if DEBUG
                print("[ContinueWatching] Trakt metadata omitted \(title)")
                #endif
            }
        }
        let items = indexedItems.sorted { $0.0 < $1.0 }.map(\.1)
        let resolvedItems = updateDisplayedSnapshot
            ? mergingLocalPlaybackCheckpoints(into: items, source: source)
            : items
        if updateDisplayedSnapshot {
            replaceContinueWatchingSnapshot(resolvedItems, source: source)
        }
        #if DEBUG
        print("[ContinueWatching] Trakt provider returning \(resolvedItems.count) items")
        #endif
        return resolvedItems
    }

    private static func fetchList<Element: Decodable>(
        _ type: Element.Type,
        path: String,
        service: TraktAuthService
    ) async -> [Element]? {
        do {
            return try await service.authorizedGet(path: path)
        } catch {
            #if DEBUG
            print("[ContinueWatching] Trakt GET \(path) failed: \(error.localizedDescription)")
            #endif
            return nil
        }
    }

    nonisolated static func ordersBefore(
        isUpNext: Bool,
        updatedAt: Date,
        otherIsUpNext: Bool,
        otherUpdatedAt: Date
    ) -> Bool {
        if isUpNext != otherIsUpNext {
            return !isUpNext
        }
        return updatedAt > otherUpdatedAt
    }

    private static func mergingLocalPlaybackCheckpoints(
        into remoteItems: [ContinueWatchingItem],
        source: TraktWatchProgressSource
    ) -> [ContinueWatchingItem] {
        pruneExpiredLocalCheckpoints()

        let profileId = ContinueWatchingStore.activeProfileId
        let checkpoints = localPlaybackCheckpoints.filter {
            $0.profileId == profileId && $0.source == source
        }
        var merged = remoteItems
        var confirmedItems: [ContinueWatchingItem] = []

        for checkpoint in checkpoints {
            let local = checkpoint.item
            if let index = merged.firstIndex(where: { WatchedStore.sameContent($0.meta, local.meta) }) {
                let remote = merged[index]
                let sameEpisode = remote.season == local.season && remote.episode == local.episode
                let remoteCaughtUp = sameEpisode && abs(remote.position - local.position) <= 2
                let remoteIsNewer = remote.lastWatchedAt
                    > local.lastWatchedAt.addingTimeInterval(1)
                if remoteCaughtUp || remoteIsNewer {
                    confirmedItems.append(local)
                } else {
                    merged[index] = local
                }
            } else {
                merged.append(local)
            }
        }

        if !confirmedItems.isEmpty {
            localPlaybackCheckpoints.removeAll { checkpoint in
                checkpoint.profileId == profileId
                    && checkpoint.source == source
                    && confirmedItems.contains { confirmed in
                        WatchedStore.sameContent(checkpoint.item.meta, confirmed.meta)
                    }
            }
        }

        return Array(
            merged
                .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
                .prefix(maxItems)
        )
    }

    private static func pruneExpiredLocalCheckpoints() {
        let now = Date()
        localPlaybackCheckpoints.removeAll {
            now.timeIntervalSince($0.item.lastWatchedAt) > localCheckpointLifetime
        }
    }

    private static func replaceContinueWatchingSnapshot(
        _ items: [ContinueWatchingItem],
        source: TraktWatchProgressSource
    ) {
        let profileId = ContinueWatchingStore.activeProfileId
        continueWatchingSnapshots.removeAll {
            $0.profileId == profileId && $0.source == source
        }
        continueWatchingSnapshots.append(
            ContinueWatchingSnapshot(profileId: profileId, source: source, items: items)
        )
    }

    /// Returns whether the snapshot actually lost a row.
    @discardableResult
    private static func removeFromContinueWatchingSnapshot(
        profileId: String?,
        source: TraktWatchProgressSource,
        where matchesRemoval: (ContinueWatchingItem) -> Bool
    ) -> Bool {
        guard let index = continueWatchingSnapshots.firstIndex(where: {
            $0.profileId == profileId && $0.source == source
        }) else {
            return false
        }
        let remaining = continueWatchingSnapshots[index].items.filter { !matchesRemoval($0) }
        guard remaining.count != continueWatchingSnapshots[index].items.count else { return false }
        continueWatchingSnapshots[index] = ContinueWatchingSnapshot(
            profileId: profileId,
            source: source,
            items: remaining
        )
        return true
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
        action: TraktScrobbleAction,
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        if TraktSettingsStore.watchProgressSource(in: store) == .simkl {
            return await SimklProgressService.reportPlayback(
                meta: meta,
                position: position,
                duration: duration,
                season: season,
                episode: episode,
                action: action,
                store: store
            )
        }

        guard TraktSettingsStore.watchProgressSource(in: store) == .trakt,
              TraktAuthStore.state(in: store).isAuthenticated(in: store),
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
            try await TraktAuthService(store: store).authorizedPostEmpty(
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
            lastUpdated: traktDate(item.pausedAt) ?? .distantPast,
            season: item.episode?.season,
            episode: item.episode?.number,
            episodeTitle: item.episode?.title,
            isUpNext: false,
            ids: media.ids
        )
    }

    private static func nextUpSeed(
        from item: TraktWatchedShowDTO,
        preferFurthestEpisode: Bool
    ) -> TraktProgressSeed? {
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
        guard var selected = watched.first else { return nil }
        for candidate in watched.dropFirst() {
            if UpNextEpisodeSelectionPolicy.prefers(
                candidateSeason: candidate.season,
                candidateEpisode: candidate.episode,
                candidateWatchedAt: candidate.watchedAt ?? .distantPast,
                over: selected.season,
                currentEpisode: selected.episode,
                currentWatchedAt: selected.watchedAt ?? .distantPast,
                preferFurthestEpisode: preferFurthestEpisode
            ) {
                selected = candidate
            }
        }

        return TraktProgressSeed(
            contentID: contentID,
            type: "series",
            title: show.title ?? contentID,
            year: show.year,
            progressPercent: 0,
            lastUpdated: selected.watchedAt ?? traktDate(item.lastWatchedAt) ?? .distantPast,
            season: selected.season,
            episode: selected.episode,
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
            lastUpdated: traktDate(item.watchedAt) ?? .distantPast,
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
        // Home caches lightweight catalog cards without episode guides. Next Up
        // must bypass that shallow cache or the newest watched show is omitted.
        let loadedMeta: NuvioMeta?
        if seed.isUpNext {
            loadedMeta = try? await repository.refreshMetadata(
                id: seed.contentID,
                type: seed.type
            )
        } else {
            loadedMeta = try? await repository.getMetadata(
                id: seed.contentID,
                type: seed.type
            )
        }
        var meta = loadedMeta ?? placeholderMeta(for: seed)

        // The seed's own season, kept before the up-next branch below overwrites
        // `season` with the suggested episode's — the pair is what tells a season
        // rollover from a step inside one.
        let seedSeason = seed.season
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
            isUpNext: seed.isUpNext,
            upNextSeedSeason: seed.isUpNext ? seedSeason : nil
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

// MARK: - Watched history

/// Mirrors durable local watched/unwatched mutations to Trakt history. This is
/// intentionally independent of the selected Continue Watching source: a
/// connected Trakt account should receive an explicit watched action even when
/// resume points are kept in Nuvio Sync.
struct TraktHistoryService {
    /// Returns a complete Trakt watched snapshot without mutating Nuvio's
    /// watched store. Used by one-way provider transfers.
    static func fetchWatchedHistory(
        store: UserDefaults = ProfileSettings.current
    ) async -> [WatchedStoreItem]? {
        guard TraktAuthStore.state(in: store).isAuthenticated(in: store) else { return nil }

        let service = TraktAuthService(store: store)
        guard await service.refreshTokenIfNeeded(),
              let movies: [TraktWatchedMovieDTO] = try? await service.authorizedGet(
                path: "sync/watched/movies"
              ),
              let shows: [TraktWatchedShowDTO] = try? await service.authorizedGet(
                path: "sync/watched/shows"
              ) else {
            return nil
        }

        var remoteItems = movies.compactMap(watchedMovie)
        guard remoteItems.count == movies.count else { return nil }

        var needsHistoryFallback = false
        for show in shows {
            if show.seasons.orEmpty.isEmpty {
                needsHistoryFallback = true
            } else if let episodes = watchedEpisodes(show) {
                remoteItems.append(contentsOf: episodes)
            } else {
                return nil
            }
        }

        if needsHistoryFallback {
            guard let historyItems = await fetchCompleteEpisodeHistory(using: service) else {
                return nil
            }
            remoteItems.append(contentsOf: historyItems)
        }
        return WatchedStore.mergedByIdentity(remoteItems)
    }

    /// Pulls Trakt's complete watched snapshot into the durable store used by
    /// Details, episode cards, Continue Watching reconciliation, and Nuvio
    /// Sync. This runs whenever Trakt is connected, independently of which
    /// provider is selected for resume progress.
    @MainActor
    static func syncWatchedHistory(
        store: UserDefaults = ProfileSettings.current
    ) async -> Bool {
        guard TraktAuthStore.state(in: store).isAuthenticated(in: store) else { return false }

        let targetProfileId = WatchedStore.activeProfileId
        let service = TraktAuthService(store: store)
        guard await service.refreshTokenIfNeeded() else { return false }

        // Local changes are durable until a complete pull confirms them. Retry
        // them before fetching so a transient POST failure cannot be mistaken
        // for an authoritative remote removal.
        for pending in WatchedStore.pendingTraktMutations(profileId: targetProfileId) {
            guard WatchedStore.activeProfileId == targetProfileId else { return false }
            _ = await setWatched(
                pending.meta,
                season: pending.season,
                episode: pending.episode,
                isWatched: pending.isWatched,
                store: store,
                notifyChange: false
            )
        }
        let syncStartedAt = Date()

        var receivedResponse = false
        var receivedCompleteSnapshot = true
        var remoteItems: [WatchedStoreItem] = []

        if let movies: [TraktWatchedMovieDTO] = try? await service.authorizedGet(
            path: "sync/watched/movies"
        ) {
            receivedResponse = true
            remoteItems.append(contentsOf: movies.compactMap(watchedMovie))
        } else {
            receivedCompleteSnapshot = false
        }

        if let shows: [TraktWatchedShowDTO] = try? await service.authorizedGet(
            path: "sync/watched/shows"
        ) {
            receivedResponse = true
            var needsHistoryFallback = false
            for show in shows {
                if show.seasons.orEmpty.isEmpty {
                    needsHistoryFallback = true
                } else if let episodes = watchedEpisodes(show) {
                    remoteItems.append(contentsOf: episodes)
                } else {
                    receivedCompleteSnapshot = false
                }
            }

            if needsHistoryFallback {
                if let historyItems = await fetchCompleteEpisodeHistory(using: service) {
                    remoteItems.append(contentsOf: historyItems)
                } else {
                    receivedCompleteSnapshot = false
                }
            }
        } else {
            receivedCompleteSnapshot = false
        }

        guard receivedResponse else { return false }
        // Network requests above can outlive the profile that initiated them.
        // Never apply one profile's Trakt account to another profile's store.
        guard WatchedStore.activeProfileId == targetProfileId else { return false }
        guard receivedCompleteSnapshot else {
            // A partial response is still useful for importing new marks, but
            // absence is authoritative only when both Trakt collections loaded.
            return WatchedStore.mergeRemote(
                remoteItems.map { $0.adding(source: .trakt) },
                confirmsTombstoneDeletions: false
            )
        }
        return WatchedStore.reconcileTraktSnapshot(
            remoteItems,
            syncStartedAt: syncStartedAt
        )
    }

    static func setWatched(
        _ meta: NuvioMeta,
        season: Int? = nil,
        episode: Int? = nil,
        isWatched: Bool,
        store: UserDefaults = ProfileSettings.current,
        notifyChange: Bool = true
    ) async -> Bool {
        await setWatched(
            meta,
            season: season,
            episodes: episode.map { [$0] } ?? [],
            isWatched: isWatched,
            store: store,
            notifyChange: notifyChange
        )
    }

    /// Season-wide counterpart: every episode listed rides in one `sync/history`
    /// write instead of one request each.
    static func setWatched(
        _ meta: NuvioMeta,
        season: Int?,
        episodes: [Int],
        isWatched: Bool,
        store: UserDefaults = ProfileSettings.current,
        notifyChange: Bool = true
    ) async -> Bool {
        guard TraktAuthStore.state(in: store).isAuthenticated(in: store),
              let mutation = mutation(
                for: meta,
                season: season,
                episodes: episodes,
                watchedAt: isWatched ? iso8601Now() : nil
              ) else {
            return false
        }

        do {
            try await TraktAuthService(store: store).authorizedPostEmpty(
                path: isWatched ? "sync/history" : "sync/history/remove",
                body: mutation
            )
            if notifyChange {
                NotificationCenter.default.post(
                    name: TraktSettingsStore.continueWatchingChangedNotification,
                    object: nil
                )
            }
            return true
        } catch {
            return false
        }
    }

    /// `episodes` carries every episode being marked in one season, so a whole
    /// season is one request rather than one per episode.
    private static func mutation(
        for meta: NuvioMeta,
        season: Int?,
        episodes: [Int],
        watchedAt: String?
    ) -> TraktHistoryMutation? {
        let firstIDComponent = meta.id.split(separator: ":", maxSplits: 1).first.map(String.init) ?? meta.id
        let ids = TraktHistoryIDs(
            trakt: meta.id.hasPrefix("trakt:") ? Int(meta.id.dropFirst("trakt:".count)) : nil,
            imdb: meta.imdbId ?? (firstIDComponent.hasPrefix("tt") ? firstIDComponent : nil),
            tmdb: meta.tmdbId ?? (meta.id.hasPrefix("tmdb:")
                ? Int(meta.id.dropFirst("tmdb:".count))
                : nil)
        )
        guard ids.trakt != nil || ids.imdb != nil || ids.tmdb != nil else { return nil }

        if meta.isSeries {
            let seasons: [TraktHistorySeason]?
            if let season, !episodes.isEmpty {
                seasons = [
                    TraktHistorySeason(
                        number: season,
                        episodes: episodes.map {
                            TraktHistoryEpisode(number: $0, watchedAt: watchedAt)
                        }
                    )
                ]
            } else {
                seasons = nil
            }
            return TraktHistoryMutation(
                movies: nil,
                shows: [
                    TraktHistoryShow(
                        title: meta.name,
                        year: meta.year,
                        ids: ids,
                        watchedAt: watchedAt,
                        seasons: seasons
                    )
                ]
            )
        }

        return TraktHistoryMutation(
            movies: [
                TraktHistoryMovie(
                    title: meta.name,
                    year: meta.year,
                    ids: ids,
                    watchedAt: watchedAt
                )
            ],
            shows: nil
        )
    }

    private static func iso8601Now() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func watchedMovie(_ item: TraktWatchedMovieDTO) -> WatchedStoreItem? {
        guard let movie = item.movie,
              let contentID = historyContentID(from: movie.ids) else { return nil }
        return WatchedStoreItem(
            meta: historyMeta(from: movie, contentID: contentID, type: "movie"),
            watchedAt: historyDate(item.lastWatchedAt) ?? .distantPast
        )
    }

    private static func watchedEpisodes(_ item: TraktWatchedShowDTO) -> [WatchedStoreItem]? {
        guard let show = item.show,
              let contentID = historyContentID(from: show.ids),
              let seasons = item.seasons,
              !seasons.isEmpty else { return nil }
        let meta = historyMeta(from: show, contentID: contentID, type: "series")
        var watched: [WatchedStoreItem] = []
        for season in seasons {
            guard let seasonNumber = season.number,
                  seasonNumber >= 0,
                  let episodes = season.episodes else { return nil }
            for episode in episodes {
                guard let episodeNumber = episode.number, episodeNumber > 0 else { return nil }
                guard (episode.plays ?? 1) > 0 else { continue }
                watched.append(
                    WatchedStoreItem(
                        meta: meta,
                        watchedAt: historyDate(episode.lastWatchedAt ?? item.lastWatchedAt) ?? .distantPast,
                        season: seasonNumber,
                        episode: episodeNumber
                    )
                )
            }
        }
        return watched
    }

    private static func fetchCompleteEpisodeHistory(
        using service: TraktAuthService
    ) async -> [WatchedStoreItem]? {
        let pageSize = 100
        var page = 1
        var watched: [WatchedStoreItem] = []

        while true {
            guard let historyPage: [TraktEpisodeHistoryDTO] = try? await service.authorizedGet(
                path: "users/me/history/episodes?page=\(page)&limit=\(pageSize)"
            ) else { return nil }

            let converted = historyPage.compactMap(watchedEpisode)
            // A row we cannot identify makes absence unsafe as a deletion signal.
            guard converted.count == historyPage.count else { return nil }
            watched.append(contentsOf: converted)
            guard historyPage.count == pageSize else { return watched }
            page += 1
        }
    }

    private static func watchedEpisode(_ item: TraktEpisodeHistoryDTO) -> WatchedStoreItem? {
        guard let show = item.show,
              let episode = item.episode,
              let seasonNumber = episode.season,
              let episodeNumber = episode.number,
              seasonNumber >= 0,
              episodeNumber > 0,
              let contentID = historyContentID(from: show.ids) else { return nil }
        return WatchedStoreItem(
            meta: historyMeta(from: show, contentID: contentID, type: "series"),
            watchedAt: historyDate(item.watchedAt) ?? .distantPast,
            season: seasonNumber,
            episode: episodeNumber
        )
    }

    private static func historyMeta(
        from media: TraktProgressMediaDTO,
        contentID: String,
        type: String
    ) -> NuvioMeta {
        NuvioMeta(
            id: contentID,
            name: media.title ?? contentID,
            description: media.overview,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: media.ids?.imdb,
            tmdbId: media.ids?.tmdb,
            type: type,
            year: media.year,
            genres: media.genres,
            rating: media.rating,
            releaseInfo: media.year.map(String.init),
            runtime: media.runtime.map { "\($0) min" },
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil
        ).persistenceSnapshot
    }

    private static func historyContentID(from ids: TraktProgressIDsDTO?) -> String? {
        if let imdb = ids?.imdb?.trimmingCharacters(in: .whitespacesAndNewlines), !imdb.isEmpty {
            return imdb
        }
        if let tmdb = ids?.tmdb { return "tmdb:\(tmdb)" }
        if let trakt = ids?.trakt { return "trakt:\(trakt)" }
        return nil
    }

    private static func historyDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

private struct TraktHistoryMutation: Encodable {
    let movies: [TraktHistoryMovie]?
    let shows: [TraktHistoryShow]?
}

private struct TraktHistoryMovie: Encodable {
    let title: String
    let year: Int?
    let ids: TraktHistoryIDs
    let watchedAt: String?

    enum CodingKeys: String, CodingKey {
        case title, year, ids
        case watchedAt = "watched_at"
    }
}

private struct TraktHistoryShow: Encodable {
    let title: String
    let year: Int?
    let ids: TraktHistoryIDs
    let watchedAt: String?
    let seasons: [TraktHistorySeason]?

    enum CodingKeys: String, CodingKey {
        case title, year, ids, seasons
        case watchedAt = "watched_at"
    }
}

private struct TraktHistorySeason: Encodable {
    let number: Int
    let episodes: [TraktHistoryEpisode]
}

private struct TraktHistoryEpisode: Encodable {
    let number: Int
    let watchedAt: String?

    enum CodingKeys: String, CodingKey {
        case number
        case watchedAt = "watched_at"
    }
}

private struct TraktHistoryIDs: Encodable {
    let trakt: Int?
    let imdb: String?
    let tmdb: Int?
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

private struct TraktWatchedMovieDTO: Decodable {
    let lastWatchedAt: String?
    let movie: TraktProgressMediaDTO?

    enum CodingKeys: String, CodingKey {
        case movie
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

    static func fetchLibrary(
        repository: CatalogRepository,
        requireSelectedSource: Bool = true
    ) async -> [LibraryStoreItem]? {
        guard (!requireSelectedSource || TraktSettingsStore.librarySourceMode == .trakt),
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
        let profileId = WatchedStore.activeProfileId
        Task {
            await service.revokeAndLogout()
            WatchedStore.clearPendingTraktMutations(profileId: profileId)
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
            let historySynced = await TraktHistoryService.syncWatchedHistory(store: store)
            // Match Android TV's Sync Now sequence: refresh the Trakt progress
            // repository before updating account details and cached stats. Home
            // owns the tvOS progress snapshot, so its change notification is the
            // equivalent refresh signal here.
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            _ = await service.fetchUserSettings()
            if let stats = await service.fetchUserStats() {
                TraktAuthStore.saveCachedStats(stats, store: store)
                connectedStats = stats
            }
            isStatsLoading = false
            isLoading = false
            statusMessage = historySynced
                ? "Trakt sync completed."
                : "Trakt account refreshed, but watched history could not be imported."
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
        // A hand-picked source outranks the connect-time selection from then on.
        TraktSettingsStore.markWatchProgressSourceChosenByUser(in: store)
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
