import Foundation
import Security
import SwiftUI

// MARK: - Connection Mode

enum WeTrakrConnectionMode {
    case disconnected
    case awaitingApproval
    case connected
}

// MARK: - Auth State

struct WeTrakrAuthState: Equatable {
    var accessToken: String?
    var refreshToken: String?
    var tokenExpiresAt: Double?
    var username: String?
    var displayName: String?
    var accountID: String?
    var accountPlan: String?
    var avatarURL: String?
    var deviceCode: String?
    var userCode: String?
    var verificationURI: String?
    var expiresAt: Double?
    var pollInterval: Int?
    var credentialClientID: String?

    var isAuthenticated: Bool {
        isAuthenticated(in: ProfileSettings.current)
    }

    func isAuthenticated(in store: UserDefaults) -> Bool {
        WeTrakrConfig.isConfigured(in: store) &&
        !(accessToken ?? "").isEmpty &&
        credentialClientID == WeTrakrConfig.clientID(in: store)
    }

    var hasActivePINFlow: Bool {
        hasActivePINFlow(in: ProfileSettings.current)
    }

    func hasActivePINFlow(in store: UserDefaults) -> Bool {
        WeTrakrConfig.isConfigured(in: store) &&
        !(userCode ?? "").isEmpty &&
        credentialClientID == WeTrakrConfig.clientID(in: store) &&
        (expiresAt.map { Date().timeIntervalSince1970 * 1000.0 < $0 } ?? false)
    }
}

struct WeTrakrCachedStats: Codable, Equatable {
    var moviesWatched: Int?
    var showsWatched: Int?
    var episodesWatched: Int?
    var totalWatchedHours: Int?
}

// MARK: - Token Storage

protocol WeTrakrTokenStorage: AnyObject {
    func accessToken(for profileScope: String) -> String?
    func setAccessToken(_ token: String?, for profileScope: String)
    func refreshToken(for profileScope: String) -> String?
    func setRefreshToken(_ token: String?, for profileScope: String)
}

final class WeTrakrKeychainTokenStorage: WeTrakrTokenStorage {
    private let service = "com.nuvio.tv.wetrakr.auth"
    private static let lock = NSLock()
    private static var tokenCache: [String: String] = [:]

    func accessToken(for profileScope: String) -> String? {
        readToken(accountType: "accessToken", profileScope: profileScope, fallbackKey: SettingsKey.wetrakrAccessToken)
    }

    func setAccessToken(_ token: String?, for profileScope: String) {
        writeToken(token, accountType: "accessToken", profileScope: profileScope, mirrorKey: SettingsKey.wetrakrAccessToken)
    }

    func refreshToken(for profileScope: String) -> String? {
        readToken(accountType: "refreshToken", profileScope: profileScope, fallbackKey: SettingsKey.wetrakrRefreshToken)
    }

    func setRefreshToken(_ token: String?, for profileScope: String) {
        writeToken(token, accountType: "refreshToken", profileScope: profileScope, mirrorKey: SettingsKey.wetrakrRefreshToken)
    }

    private func readToken(accountType: String, profileScope: String, fallbackKey: String) -> String? {
        let cacheKey = "\(accountType):\(profileScope)"
        if let cached = Self.lock.withLock({ Self.tokenCache[cacheKey] }), !cached.isEmpty {
            return cached
        }

        var query = keychainQuery(for: profileScope, accountType: accountType)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let token = String(data: data, encoding: .utf8), !token.isEmpty {
            Self.lock.withLock { Self.tokenCache[cacheKey] = token }
            return token
        }

        let store = ProfileSettings.store(for: profileScope)
        if let mirrored = store.string(forKey: fallbackKey), !mirrored.isEmpty {
            writeToken(mirrored, accountType: accountType, profileScope: profileScope, mirrorKey: fallbackKey)
            return mirrored
        }
        return nil
    }

    private func writeToken(_ token: String?, accountType: String, profileScope: String, mirrorKey: String) {
        let cacheKey = "\(accountType):\(profileScope)"
        Self.lock.withLock {
            if let token, !token.isEmpty {
                Self.tokenCache[cacheKey] = token
            } else {
                Self.tokenCache.removeValue(forKey: cacheKey)
            }
        }
        SecItemDelete(keychainQuery(for: profileScope, accountType: accountType) as CFDictionary)
        let store = ProfileSettings.store(for: profileScope)
        if let token, !token.isEmpty {
            store.set(token, forKey: mirrorKey)
            if let data = token.data(using: .utf8) {
                var addQuery = keychainQuery(for: profileScope, accountType: accountType)
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                addQuery[kSecValueData as String] = data
                SecItemAdd(addQuery as CFDictionary, nil)
            }
        } else {
            store.removeObject(forKey: mirrorKey)
        }
    }

    private func keychainQuery(for profileScope: String, accountType: String = "accessToken") -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(accountType).\(profileScope)"
        ]
    }
}

final class WeTrakrMemoryTokenStorage: WeTrakrTokenStorage {
    private var accessTokens: [String: String] = [:]
    private var refreshTokens: [String: String] = [:]

    func accessToken(for profileScope: String) -> String? {
        accessTokens[profileScope]
    }

    func setAccessToken(_ token: String?, for profileScope: String) {
        accessTokens[profileScope] = token
    }

    func refreshToken(for profileScope: String) -> String? {
        refreshTokens[profileScope]
    }

    func setRefreshToken(_ token: String?, for profileScope: String) {
        refreshTokens[profileScope] = token
    }
}

// MARK: - Runtime Session

enum WeTrakrRuntimeSession {
    static func profileScope() -> String {
        let value = ProfileSettings.activeProfileScope.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty && value != "default" {
            return value
        }
        let watchedValue = WatchedStore.activeProfileId?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return watchedValue.isEmpty ? (value.isEmpty ? "default" : value) : watchedValue
    }

    static func authenticatedState(
        store: UserDefaults = ProfileSettings.current,
        tokenStorage: WeTrakrTokenStorage = WeTrakrKeychainTokenStorage(),
        profileScope: String? = nil
    ) -> WeTrakrAuthState? {
        let storeProfileId = store.string(forKey: "nuvio.tv.profile.settings.profileID")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedProfileScope: String
        if let profileScope, !profileScope.isEmpty {
            resolvedProfileScope = profileScope
        } else if let storeProfileId, !storeProfileId.isEmpty {
            resolvedProfileScope = storeProfileId
        } else {
            resolvedProfileScope = self.profileScope()
        }
        let state = WeTrakrAuthStore.state(
            in: store,
            profileScope: resolvedProfileScope,
            tokenStorage: tokenStorage
        )
        return state.isAuthenticated(in: store) ? state : nil
    }

    static func isAuthenticated(
        in store: UserDefaults = ProfileSettings.current,
        tokenStorage: WeTrakrTokenStorage = WeTrakrKeychainTokenStorage(),
        profileScope: String? = nil
    ) -> Bool {
        authenticatedState(store: store, tokenStorage: tokenStorage, profileScope: profileScope) != nil
    }
}

// MARK: - Store

enum WeTrakrAuthStore {
    static let changedNotification = Notification.Name("nuvio.tv.wetrakr.auth.changed")

    private enum Key {
        static let accountBindingID = "nuvio.tv.wetrakr.auth.accountBindingID"
        static let hasAccessToken = "nuvio.tv.wetrakr.auth.hasAccessToken"
        static let username = "nuvio.tv.wetrakr.auth.username"
        static let displayName = "nuvio.tv.wetrakr.auth.displayName"
        static let accountID = "nuvio.tv.wetrakr.auth.accountID"
        static let accountPlan = "nuvio.tv.wetrakr.auth.accountPlan"
        static let avatarURL = "nuvio.tv.wetrakr.auth.avatarURL"
        static let deviceCode = "nuvio.tv.wetrakr.auth.deviceCode"
        static let userCode = "nuvio.tv.wetrakr.auth.userCode"
        static let verificationURI = "nuvio.tv.wetrakr.auth.verificationURI"
        static let expiresAt = "nuvio.tv.wetrakr.auth.expiresAt"
        static let pollInterval = "nuvio.tv.wetrakr.auth.pollInterval"
        static let credentialClientID = "nuvio.tv.wetrakr.auth.credentialClientID"
        static let cachedStats = "nuvio.tv.wetrakr.auth.cachedStats"
        static let tokenExpiresAt = "nuvio.tv.wetrakr.auth.tokenExpiresAt"
    }

    static func state(
        in defaults: UserDefaults,
        profileScope: String,
        tokenStorage: WeTrakrTokenStorage = WeTrakrKeychainTokenStorage()
    ) -> WeTrakrAuthState {
        let hasMarker = defaults.bool(forKey: Key.hasAccessToken)
        let token = hasMarker ? tokenStorage.accessToken(for: profileScope) : nil
        let refreshToken = hasMarker ? tokenStorage.refreshToken(for: profileScope) : nil
        return WeTrakrAuthState(
            accessToken: token,
            refreshToken: refreshToken,
            tokenExpiresAt: doubleIfPresent(Key.tokenExpiresAt, defaults: defaults),
            username: defaults.string(forKey: Key.username),
            displayName: defaults.string(forKey: Key.displayName),
            accountID: defaults.string(forKey: Key.accountID),
            accountPlan: defaults.string(forKey: Key.accountPlan),
            avatarURL: defaults.string(forKey: Key.avatarURL),
            deviceCode: defaults.string(forKey: Key.deviceCode),
            userCode: defaults.string(forKey: Key.userCode),
            verificationURI: defaults.string(forKey: Key.verificationURI),
            expiresAt: doubleIfPresent(Key.expiresAt, defaults: defaults),
            pollInterval: intIfPresent(Key.pollInterval, defaults: defaults),
            credentialClientID: defaults.string(forKey: Key.credentialClientID)
        )
    }

    static func saveDeviceFlow(
        _ response: WeTrakrDeviceCodeResponse,
        clientID: String,
        store defaults: UserDefaults
    ) {
        if defaults.string(forKey: Key.credentialClientID) != clientID {
            [
                Key.username, Key.displayName, Key.accountID, Key.accountPlan,
                Key.avatarURL, Key.hasAccessToken, Key.cachedStats, Key.tokenExpiresAt
            ].forEach { defaults.removeObject(forKey: $0) }
        }
        setOptional(response.deviceCode, forKey: Key.deviceCode, defaults: defaults)
        defaults.set(response.userCode, forKey: Key.userCode)
        defaults.set(response.verificationUrl, forKey: Key.verificationURI)
        defaults.set(
            Date().timeIntervalSince1970 * 1000.0 + Double(response.expiresIn * 1000),
            forKey: Key.expiresAt
        )
        defaults.set(max(response.interval, 5), forKey: Key.pollInterval)
        defaults.set(clientID, forKey: Key.credentialClientID)
    }

    /// Stable across refresh, replaced on every new login (including same-account relinks).
    static func accountBindingID(in defaults: UserDefaults) -> String {
        if let value = defaults.string(forKey: Key.accountBindingID) { return value }
        let value = UUID().uuidString
        defaults.set(value, forKey: Key.accountBindingID)
        return value
    }

    static func saveToken(
        _ accessToken: String,
        refreshToken: String? = nil,
        expiresIn: Int? = nil,
        clientID: String,
        profileScope: String,
        store defaults: UserDefaults,
        tokenStorage: WeTrakrTokenStorage,
        isNewLogin: Bool = true
    ) {
        if isNewLogin {
            defaults.set(UUID().uuidString, forKey: Key.accountBindingID)
        } else {
            _ = accountBindingID(in: defaults)
        }
        tokenStorage.setAccessToken(accessToken, for: profileScope)
        if let refreshToken {
            tokenStorage.setRefreshToken(refreshToken, for: profileScope)
        }
        if let expiresIn {
            let expiresAt = Date().timeIntervalSince1970 * 1000.0 + Double(expiresIn * 1000)
            defaults.set(expiresAt, forKey: Key.tokenExpiresAt)
        }
        defaults.set(true, forKey: Key.hasAccessToken)
        defaults.set(clientID, forKey: Key.credentialClientID)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func saveUser(
        username: String?,
        displayName: String?,
        accountID: String?,
        accountPlan: String?,
        avatarURL: String?,
        store defaults: UserDefaults
    ) {
        setOptional(username, forKey: Key.username, defaults: defaults)
        setOptional(displayName, forKey: Key.displayName, defaults: defaults)
        setOptional(accountID, forKey: Key.accountID, defaults: defaults)
        setOptional(accountPlan, forKey: Key.accountPlan, defaults: defaults)
        setOptional(avatarURL, forKey: Key.avatarURL, defaults: defaults)
    }

    static func clearCachedUser(store defaults: UserDefaults) {
        [Key.username, Key.displayName, Key.accountID, Key.accountPlan, Key.avatarURL]
            .forEach { defaults.removeObject(forKey: $0) }
    }

    static func cachedStats(in defaults: UserDefaults) -> WeTrakrCachedStats? {
        guard let data = defaults.data(forKey: Key.cachedStats) else { return nil }
        return try? JSONDecoder().decode(WeTrakrCachedStats.self, from: data)
    }

    static func saveCachedStats(_ stats: WeTrakrCachedStats, store defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        defaults.set(data, forKey: Key.cachedStats)
    }

    static func clearDeviceFlow(store defaults: UserDefaults) {
        [
            Key.deviceCode, Key.userCode, Key.verificationURI,
            Key.expiresAt, Key.pollInterval
        ].forEach {
            defaults.removeObject(forKey: $0)
        }
    }

    static func clearAuth(
        profileScope: String,
        store defaults: UserDefaults,
        tokenStorage: WeTrakrTokenStorage
    ) {
        tokenStorage.setAccessToken(nil, for: profileScope)
        tokenStorage.setRefreshToken(nil, for: profileScope)
        [
            Key.accountBindingID, Key.username, Key.displayName, Key.accountID, Key.accountPlan, Key.avatarURL,
            Key.deviceCode, Key.userCode, Key.verificationURI,
            Key.expiresAt, Key.pollInterval, Key.credentialClientID, Key.hasAccessToken,
            Key.cachedStats, Key.tokenExpiresAt
        ].forEach { defaults.removeObject(forKey: $0) }
        RemoteLibraryStore.clear(source: .wetrakr, profileId: profileScope)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        RemoteTrackingState.normalizeWatchProgressSource(in: defaults)
        RemoteTrackingState.normalizeLibrarySource(in: defaults)
    }

    private static func setOptional(_ value: String?, forKey key: String, defaults: UserDefaults) {
        if let value, !value.isEmpty {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func doubleIfPresent(_ key: String, defaults: UserDefaults) -> Double? {
        defaults.object(forKey: key) as? Double
    }

    private static func intIfPresent(_ key: String, defaults: UserDefaults) -> Int? {
        defaults.object(forKey: key) as? Int
    }
}

// MARK: - Models / DTOs

struct WeTrakrDeviceCodeRequest: Codable {
    let clientId: String

    enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
    }
}

struct WeTrakrDeviceCodeResponse: Codable {
    let deviceCode: String
    let userCode: String
    let verificationUrl: String
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUrl = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }
}

struct WeTrakrDeviceTokenRequest: Codable {
    let code: String
    let clientId: String
    let clientSecret: String?

    enum CodingKeys: String, CodingKey {
        case code
        case clientId = "client_id"
        case clientSecret = "client_secret"
    }
}

struct WeTrakrDeviceTokenResponse: Codable {
    let accessToken: String
    let tokenType: String?
    let expiresIn: Int?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

struct WeTrakrRefreshTokenRequest: Codable {
    let refreshToken: String
    let clientId: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
        case clientId = "client_id"
    }
}

struct WeTrakrAccountSettingsResponse: Codable {
    let id: Int?
    let plan: String?
    let info: WeTrakrUserInfo?
    let images: WeTrakrUserImages?
}

struct WeTrakrUserInfo: Codable {
    let username: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case username
        case displayName = "display_name"
    }
}

struct WeTrakrUserImages: Codable {
    let avatar: String?
}

// MARK: - Service

final class WeTrakrAuthService {
    private let client: WeTrakrAPIClient
    private let store: UserDefaults
    private let tokenStorage: WeTrakrTokenStorage
    private let profileScope: String

    init(
        client: WeTrakrAPIClient = WeTrakrAPIClient(),
        store: UserDefaults = ProfileSettings.current,
        tokenStorage: WeTrakrTokenStorage = WeTrakrKeychainTokenStorage(),
        profileScope: String? = nil
    ) {
        self.client = client
        self.store = store
        self.tokenStorage = tokenStorage
        self.profileScope = profileScope ?? WeTrakrRuntimeSession.profileScope()
    }

    var currentState: WeTrakrAuthState {
        WeTrakrAuthStore.state(in: store, profileScope: profileScope, tokenStorage: tokenStorage)
    }

    var connectionMode: WeTrakrConnectionMode {
        let state = currentState
        if state.isAuthenticated(in: store) {
            return .connected
        } else if state.hasActivePINFlow(in: store) {
            return .awaitingApproval
        } else {
            return .disconnected
        }
    }

    func requestDeviceCode() async throws -> WeTrakrDeviceCodeResponse {
        let clientID = WeTrakrConfig.clientID(in: store)
        guard !clientID.isEmpty else {
            throw WeTrakrServiceError.notConfigured
        }

        let body = WeTrakrDeviceCodeRequest(clientId: clientID)
        let result: WeTrakrHTTPResult<WeTrakrDeviceCodeResponse> = try await client.post(
            path: "/oauth/device/code",
            body: body,
            clientID: clientID
        )
        let response = try result.valueOrThrow()
        WeTrakrAuthStore.saveDeviceFlow(response, clientID: clientID, store: store)
        return response
    }

    func pollDeviceToken(deviceCode: String) async throws -> WeTrakrDeviceTokenResponse {
        let clientID = WeTrakrConfig.clientID(in: store)
        let clientSecret = WeTrakrConfig.clientSecret(in: store)
        guard !clientID.isEmpty else {
            throw WeTrakrServiceError.notConfigured
        }

        let body = WeTrakrDeviceTokenRequest(
            code: deviceCode,
            clientId: clientID,
            clientSecret: clientSecret.isEmpty ? nil : clientSecret
        )
        let result: WeTrakrHTTPResult<WeTrakrDeviceTokenResponse> = try await client.post(
            path: "/oauth/device/token",
            body: body,
            clientID: clientID
        )
        let response = try result.valueOrThrow()

        WeTrakrAuthStore.clearDeviceFlow(store: store)
        // A fresh device authorization may connect a different WeTrakr user.
        // Until settings for the new token are verified, the old account ID
        // must not authorize queued completions.
        WeTrakrAuthStore.clearCachedUser(store: store)
        WeTrakrAuthStore.saveToken(
            response.accessToken,
            refreshToken: response.refreshToken,
            expiresIn: response.expiresIn,
            clientID: clientID,
            profileScope: profileScope,
            store: store,
            tokenStorage: tokenStorage
        )

        // Automatically fetch profile information after token is received
        Task { [weak self] in
            await self?.refreshAccountProfile()
        }

        return response
    }

    func refreshAccessToken() async throws -> String {
        let clientID = WeTrakrConfig.clientID(in: store)
        let state = currentState
        guard let refreshToken = state.refreshToken, !refreshToken.isEmpty, !clientID.isEmpty else {
            throw WeTrakrServiceError.message("No refresh token available.")
        }
        let capturedAccessToken = state.accessToken ?? ""

        let body = WeTrakrRefreshTokenRequest(
            refreshToken: refreshToken,
            clientId: clientID
        )
        let result: WeTrakrHTTPResult<WeTrakrDeviceTokenResponse> = try await client.post(
            path: "/oauth/token/refresh",
            body: body,
            clientID: clientID
        )
        let response = try result.valueOrThrow()
        guard !capturedAccessToken.isEmpty,
              isCurrentProfileBinding(for: capturedAccessToken),
              currentState.accountID == state.accountID else {
            throw WeTrakrServiceError.message("WeTrakr account changed during token refresh.")
        }

        WeTrakrAuthStore.saveToken(
            response.accessToken,
            refreshToken: response.refreshToken ?? refreshToken,
            expiresIn: response.expiresIn,
            clientID: clientID,
            profileScope: profileScope,
            store: store,
            tokenStorage: tokenStorage,
            isNewLogin: false
        )
        return response.accessToken
    }

    @discardableResult
    func refreshAccountProfile() async -> Bool {
        let state = currentState
        guard let token = state.accessToken, !token.isEmpty else { return false }
        let clientID = WeTrakrConfig.clientID(in: store)

        do {
            let result: WeTrakrHTTPResult<WeTrakrAccountSettingsResponse> = try await client.get(
                path: "/account/settings",
                accessToken: token,
                clientID: clientID
            )
            let settings = try result.valueOrThrow()
            guard isCurrentProfileBinding(for: token) else { return false }

            let avatarFullURL: String? = {
                guard let raw = settings.images?.avatar, !raw.isEmpty else { return nil }
                if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                    return raw
                }
                return "https://media.wetrakr.com/avatars/\(raw)"
            }()

            WeTrakrAuthStore.saveUser(
                username: settings.info?.username,
                displayName: settings.info?.displayName,
                accountID: settings.id.map(String.init),
                accountPlan: settings.plan,
                avatarURL: avatarFullURL,
                store: store
            )
            return true
        } catch {
            return false
        }
    }

    private func isCurrentProfileBinding(for capturedToken: String) -> Bool {
        guard ProfileSettings.isActiveStore(store),
              currentState.accessToken == capturedToken else {
            return false
        }
        if let activeProfileID = ProfileSettings.activeProfileID,
           activeProfileID != profileScope {
            return false
        }
        if let storedProfileID = store.string(forKey: "nuvio.tv.profile.settings.profileID"),
           storedProfileID != profileScope {
            return false
        }
        return true
    }

    func fetchUserStats() async -> WeTrakrCachedStats? {
        let state = currentState
        guard let token = state.accessToken, !token.isEmpty else { return nil }
        let clientID = WeTrakrConfig.clientID(in: store)

        var moviesCount = 0
        var episodesCount = 0
        var showIds = Set<String>()
        var totalMinutes: Double = 0

        if let moviesRes: WeTrakrHTTPResult<[WeTrakrTrackingHistoryItemDTO]> = try? await client.get(
            path: "/sync/tracking/watched/history/movies",
            accessToken: token,
            clientID: clientID,
            queryItems: [URLQueryItem(name: "limit", value: "100")]
        ), let movies = try? moviesRes.valueOrThrow(), !movies.isEmpty {
            moviesCount = movies.count
            for m in movies {
                if let rt = m.movie?.runtime ?? m.media?.runtime, rt > 0 {
                    totalMinutes += Double(rt > 600 ? rt / 60 : rt)
                } else {
                    totalMinutes += 105
                }
            }
        } else if let moviesListRes: WeTrakrHTTPResult<[WeTrakrTrackingPlayingItemDTO]> = try? await client.get(
            path: "/sync/tracking/watched/movies",
            accessToken: token,
            clientID: clientID,
            queryItems: [URLQueryItem(name: "limit", value: "100")]
        ), let movies = try? moviesListRes.valueOrThrow() {
            moviesCount = movies.count
            totalMinutes += Double(moviesCount * 105)
        }

        if let epRes: WeTrakrHTTPResult<[WeTrakrTrackingHistoryItemDTO]> = try? await client.get(
            path: "/sync/tracking/watched/history/episodes",
            accessToken: token,
            clientID: clientID,
            queryItems: [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "extended", value: "show_level_1,episode_level_1")
            ]
        ), let episodes = try? epRes.valueOrThrow() {
            episodesCount = episodes.count
            for ep in episodes {
                if let show = ep.episode?.show ?? ep.media {
                    let id = show.id.map(String.init) ?? show.ids?.imdb ?? show.ids?.tmdb.map(String.init) ?? show.title ?? ""
                    if !id.isEmpty { showIds.insert(id) }
                }
                if let rt = ep.episode?.runtime ?? ep.media?.runtime, rt > 0 {
                    totalMinutes += Double(rt > 600 ? rt / 60 : rt)
                } else {
                    totalMinutes += 45
                }
            }
        }

        let stats = WeTrakrCachedStats(
            moviesWatched: moviesCount,
            showsWatched: showIds.count,
            episodesWatched: episodesCount,
            totalWatchedHours: Int(totalMinutes / 60.0)
        )
        WeTrakrAuthStore.saveCachedStats(stats, store: store)
        return stats
    }

    func disconnect() {
        WeTrakrAuthStore.clearAuth(profileScope: profileScope, store: store, tokenStorage: tokenStorage)
    }
}

// MARK: - Settings View Model

@MainActor
final class WeTrakrSettingsViewModel: ObservableObject {
    @Published var mode: WeTrakrConnectionMode = .disconnected
    @Published var credentialsConfigured = false
    @Published var isLoading = false
    @Published var isPolling = false
    @Published var username: String?
    @Published var displayName: String?
    @Published var accountPlan: String?
    @Published var accountID: String?
    @Published var avatarURL: String?
    @Published var connectedStats: WeTrakrCachedStats?
    @Published var deviceUserCode: String?
    @Published var verificationURI: String?
    @Published var pinExpiresAtMillis: Double?
    @Published var pollInterval = 5
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var isStatsLoading = false

    private let store: UserDefaults
    private let service: WeTrakrAuthService
    private var connectionTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init(
        store: UserDefaults = ProfileSettings.current,
        profileScope: String = "default",
        service: WeTrakrAuthService? = nil,
        tokenStorage: WeTrakrTokenStorage = WeTrakrKeychainTokenStorage()
    ) {
        self.store = store
        self.service = service ?? WeTrakrAuthService(
            store: store,
            tokenStorage: tokenStorage,
            profileScope: profileScope
        )
        reload()
    }

    deinit {
        connectionTask?.cancel()
        pollTask?.cancel()
    }

    func reload() {
        credentialsConfigured = WeTrakrConfig.isConfigured(in: store)
        let state = service.currentState
        username = state.username
        displayName = state.displayName
        accountPlan = state.accountPlan
        accountID = state.accountID
        avatarURL = state.avatarURL
        deviceUserCode = state.userCode
        verificationURI = state.verificationURI
        pinExpiresAtMillis = state.expiresAt
        pollInterval = state.pollInterval ?? 5
        let isAuthenticated = state.isAuthenticated(in: store)
        mode = isAuthenticated
            ? .connected
            : (state.hasActivePINFlow(in: store) ? .awaitingApproval : .disconnected)
        connectedStats = isAuthenticated ? WeTrakrAuthStore.cachedStats(in: store) : nil
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
        pollTask?.cancel()
        isPolling = false
        credentialsConfigured = WeTrakrConfig.isConfigured(in: store)
        reload()
    }

    func startLogin() {
        guard WeTrakrConfig.isConfigured(in: store) else {
            errorMessage = "Please enter your WeTrakr Client ID first."
            return
        }
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.service.requestDeviceCode()
                await MainActor.run {
                    self.deviceUserCode = response.userCode
                    self.verificationURI = response.verificationUrl
                    self.pinExpiresAtMillis = Date().timeIntervalSince1970 * 1000.0 + Double(response.expiresIn * 1000)
                    self.pollInterval = response.interval
                    self.mode = .awaitingApproval
                    self.isLoading = false
                    self.startPolling()
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func startPolling() {
        guard let code = service.currentState.deviceCode, !code.isEmpty else { return }
        pollTask?.cancel()
        isPolling = true
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval) * 1_000_000_000)
                guard !Task.isCancelled else { break }
                do {
                    _ = try await self.service.pollDeviceToken(deviceCode: code)
                    await MainActor.run {
                        self.isPolling = false
                        self.reload()
                        self.loadConnectedData()
                    }
                    break
                } catch WeTrakrServiceError.authorizationPending {
                    continue
                } catch {
                    await MainActor.run {
                        self.isPolling = false
                        self.errorMessage = error.localizedDescription
                    }
                    break
                }
            }
        }
    }

    func loadConnectedData() {
        guard mode == .connected else { return }
        isStatsLoading = true
        Task { [weak self] in
            guard let self else { return }
            await self.service.refreshAccountProfile()
            let stats = await self.service.fetchUserStats()
            await MainActor.run {
                if let stats {
                    self.connectedStats = stats
                }
                self.isStatsLoading = false
                self.reload()
            }
        }
    }

    func refreshNow() {
        guard mode == .connected, !isLoading else { return }
        isLoading = true
        isStatsLoading = true
        Task { [weak self] in
            guard let self else { return }
            _ = await WeTrakrProgressService.syncWatchedHistory()
            await self.service.refreshAccountProfile()
            let stats = await self.service.fetchUserStats()
            await MainActor.run {
                if let stats {
                    self.connectedStats = stats
                }
                self.isLoading = false
                self.isStatsLoading = false
                self.reload()
            }
        }
    }

    func cancelLogin() {
        connectionTask?.cancel()
        pollTask?.cancel()
        isPolling = false
        WeTrakrAuthStore.clearDeviceFlow(store: store)
        reload()
    }

    func disconnect() {
        connectionTask?.cancel()
        pollTask?.cancel()
        isPolling = false
        service.disconnect()
        username = nil
        displayName = nil
        accountPlan = nil
        accountID = nil
        avatarURL = nil
        connectedStats = nil
        statusMessage = "Disconnected from WeTrakr."
        reload()
    }
}
