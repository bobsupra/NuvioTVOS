import Foundation
import Security
import SwiftUI

// MARK: - Connection mode

enum SimklConnectionMode {
    case disconnected
    case awaitingApproval
    case connected
}

// MARK: - Auth state

struct SimklAuthState: Equatable {
    var accessToken: String?
    var refreshToken: String?
    var tokenExpiresAt: Double?
    var username: String?
    var accountID: String?
    var accountPlan: String?
    var avatarURL: String?
    var deviceCode: String?
    var userCode: String?
    var verificationURI: String?
    var verificationURIComplete: String?
    var expiresAt: Double?
    var pollInterval: Int?
    var credentialClientID: String?
    var isV2Flow: Bool = false

    /// V2 access tokens are prefixed with `simkl_at_` (43 characters).
    /// Legacy V1 tokens are 64 lowercase hex characters with no prefix.
    var isV2: Bool {
        accessToken?.hasPrefix("simkl_at_") == true
    }

    var isAuthenticated: Bool {
        isAuthenticated(in: ProfileSettings.current)
    }

    func isAuthenticated(in store: UserDefaults) -> Bool {
        SimklConfig.isConfigured(in: store) &&
        !(accessToken ?? "").isEmpty &&
        credentialClientID == SimklConfig.clientID(in: store)
    }

    var hasActivePINFlow: Bool {
        hasActivePINFlow(in: ProfileSettings.current)
    }

    func hasActivePINFlow(in store: UserDefaults) -> Bool {
        SimklConfig.isConfigured(in: store) &&
        !(userCode ?? "").isEmpty &&
        credentialClientID == SimklConfig.clientID(in: store) &&
        (expiresAt.map { Date().timeIntervalSince1970 * 1000.0 < $0 } ?? false)
    }
}

struct SimklCachedStats: Codable, Equatable {
    var moviesWatched: Int?
    var showsWatched: Int?
    var episodesWatched: Int?
    var totalWatchedHours: Int?
}

// MARK: - Token storage

protocol SimklTokenStorage: AnyObject {
    func accessToken(for profileScope: String) -> String?
    func setAccessToken(_ token: String?, for profileScope: String)
    func refreshToken(for profileScope: String) -> String?
    func setRefreshToken(_ token: String?, for profileScope: String)
}

extension SimklTokenStorage {
    func refreshToken(for profileScope: String) -> String? { nil }
    func setRefreshToken(_ token: String?, for profileScope: String) {}
}

/// Long-lived Simkl access and refresh tokens live in the Keychain, namespaced by profile,
/// with ProfileSettings mirroring for iCloud sync across Apple TVs.
final class SimklKeychainTokenStorage: SimklTokenStorage {
    private let service = "com.nuvio.tv.simkl.auth"
    private static let lock = NSLock()
    private static var tokenCache: [String: String] = [:]

    func accessToken(for profileScope: String) -> String? {
        readToken(accountType: "accessToken", profileScope: profileScope, fallbackKey: SettingsKey.simklAccessToken)
    }

    func setAccessToken(_ token: String?, for profileScope: String) {
        writeToken(token, accountType: "accessToken", profileScope: profileScope, mirrorKey: SettingsKey.simklAccessToken)
    }

    func refreshToken(for profileScope: String) -> String? {
        readToken(accountType: "refreshToken", profileScope: profileScope, fallbackKey: SettingsKey.simklRefreshToken)
    }

    func setRefreshToken(_ token: String?, for profileScope: String) {
        writeToken(token, accountType: "refreshToken", profileScope: profileScope, mirrorKey: SettingsKey.simklRefreshToken)
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

        // Fallback to ProfileSettings (mirrored by iCloud sync across Apple TVs)
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

/// In-memory token storage for unit tests.
final class SimklMemoryTokenStorage: SimklTokenStorage {
    private var accessTokens: [String: String] = [:]
    private var refreshTokens: [String: String] = [:]

    func accessToken(for profileScope: String) -> String? {
        accessTokens[profileScope]
    }

    func setAccessToken(_ token: String?, for profileScope: String) {
        if let token, !token.isEmpty {
            accessTokens[profileScope] = token
        } else {
            accessTokens.removeValue(forKey: profileScope)
        }
    }

    func refreshToken(for profileScope: String) -> String? {
        refreshTokens[profileScope]
    }

    func setRefreshToken(_ token: String?, for profileScope: String) {
        if let token, !token.isEmpty {
            refreshTokens[profileScope] = token
        } else {
            refreshTokens.removeValue(forKey: profileScope)
        }
    }
}

// MARK: - Auth store

enum SimklAuthStore {
    static let changedNotification = Notification.Name("nuvio.tv.simkl.auth.changed")

    private enum Key {
        static let accountBindingID = "nuvio.tv.simkl.auth.accountBindingID"
        static let username = "nuvio.tv.simkl.auth.username"
        static let accountID = "nuvio.tv.simkl.auth.accountID"
        static let accountPlan = "nuvio.tv.simkl.auth.accountPlan"
        static let avatarURL = "nuvio.tv.simkl.auth.avatarURL"
        static let deviceCode = "nuvio.tv.simkl.auth.deviceCode"
        static let userCode = "nuvio.tv.simkl.auth.userCode"
        static let verificationURI = "nuvio.tv.simkl.auth.verificationURI"
        static let verificationURIComplete = "nuvio.tv.simkl.auth.verificationURIComplete"
        static let expiresAt = "nuvio.tv.simkl.auth.expiresAt"
        static let pollInterval = "nuvio.tv.simkl.auth.pollInterval"
        static let credentialClientID = "nuvio.tv.simkl.auth.credentialClientID"
        /// Non-secret marker that a Keychain token exists for this profile.
        static let hasAccessToken = "nuvio.tv.simkl.auth.hasAccessToken"
        static let cachedStats = "nuvio.tv.simkl.auth.cachedStats"
        /// `settings.all` from the last `/users/settings` read, so the next one
        /// can be skipped until the account actually changes.
        static let settingsWatermark = "nuvio.tv.simkl.auth.settingsWatermark"
        static let tokenExpiresAt = "nuvio.tv.simkl.auth.tokenExpiresAt"
        static let isV2Flow = "nuvio.tv.simkl.auth.isV2Flow"
    }

    static func state(
        in defaults: UserDefaults,
        profileScope: String,
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage()
    ) -> SimklAuthState {
        let hasMarker = defaults.bool(forKey: Key.hasAccessToken)
        let token = hasMarker ? tokenStorage.accessToken(for: profileScope) : nil
        let refreshToken = hasMarker ? tokenStorage.refreshToken(for: profileScope) : nil
        return SimklAuthState(
            accessToken: token,
            refreshToken: refreshToken,
            tokenExpiresAt: doubleIfPresent(Key.tokenExpiresAt, defaults: defaults),
            username: defaults.string(forKey: Key.username),
            accountID: defaults.string(forKey: Key.accountID),
            accountPlan: defaults.string(forKey: Key.accountPlan),
            avatarURL: defaults.string(forKey: Key.avatarURL),
            deviceCode: defaults.string(forKey: Key.deviceCode),
            userCode: defaults.string(forKey: Key.userCode),
            verificationURI: defaults.string(forKey: Key.verificationURI),
            verificationURIComplete: defaults.string(forKey: Key.verificationURIComplete),
            expiresAt: doubleIfPresent(Key.expiresAt, defaults: defaults),
            pollInterval: intIfPresent(Key.pollInterval, defaults: defaults),
            credentialClientID: defaults.string(forKey: Key.credentialClientID),
            isV2Flow: defaults.bool(forKey: Key.isV2Flow)
        )
    }

    static func savePINFlow(
        _ response: SimklPINCodeResponse,
        isV2Flow: Bool = false,
        clientID: String,
        store defaults: UserDefaults
    ) {
        if defaults.string(forKey: Key.credentialClientID) != clientID {
            [
                Key.username, Key.accountID, Key.accountPlan, Key.avatarURL,
                Key.hasAccessToken, Key.cachedStats, Key.settingsWatermark,
                Key.tokenExpiresAt
            ].forEach { defaults.removeObject(forKey: $0) }
        }
        setOptional(response.deviceCode, forKey: Key.deviceCode, defaults: defaults)
        defaults.set(response.userCode, forKey: Key.userCode)
        defaults.set(response.verificationURI, forKey: Key.verificationURI)
        setOptional(response.verificationURIComplete, forKey: Key.verificationURIComplete, defaults: defaults)
        defaults.set(
            Date().timeIntervalSince1970 * 1000.0 + Double(response.expiresIn * 1000),
            forKey: Key.expiresAt
        )
        defaults.set(max(response.interval, 5), forKey: Key.pollInterval)
        defaults.set(clientID, forKey: Key.credentialClientID)
        defaults.set(isV2Flow, forKey: Key.isV2Flow)
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
        tokenStorage: SimklTokenStorage,
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
        accountID: String?,
        accountPlan: String?,
        avatarURL: String?,
        store defaults: UserDefaults
    ) {
        setOptional(username, forKey: Key.username, defaults: defaults)
        setOptional(accountID, forKey: Key.accountID, defaults: defaults)
        setOptional(accountPlan, forKey: Key.accountPlan, defaults: defaults)
        setOptional(avatarURL, forKey: Key.avatarURL, defaults: defaults)
    }

    static func cachedStats(in defaults: UserDefaults) -> SimklCachedStats? {
        guard let data = defaults.data(forKey: Key.cachedStats) else { return nil }
        return try? JSONDecoder().decode(SimklCachedStats.self, from: data)
    }

    static func saveCachedStats(_ stats: SimklCachedStats, store defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(stats) else { return }
        defaults.set(data, forKey: Key.cachedStats)
    }

    static func settingsWatermark(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: Key.settingsWatermark)
    }

    static func saveSettingsWatermark(_ watermark: String, store defaults: UserDefaults) {
        defaults.set(watermark, forKey: Key.settingsWatermark)
    }

    static func updatePollInterval(_ seconds: Int, store defaults: UserDefaults) {
        defaults.set(max(seconds, 5), forKey: Key.pollInterval)
    }

    static func clearPINFlow(store defaults: UserDefaults) {
        [
            Key.deviceCode, Key.userCode, Key.verificationURI,
            Key.verificationURIComplete, Key.expiresAt, Key.pollInterval,
            Key.isV2Flow
        ].forEach {
            defaults.removeObject(forKey: $0)
        }
    }

    static func clearAuth(
        profileScope: String,
        store defaults: UserDefaults,
        tokenStorage: SimklTokenStorage
    ) {
        tokenStorage.setAccessToken(nil, for: profileScope)
        tokenStorage.setRefreshToken(nil, for: profileScope)
        [
            Key.accountBindingID, Key.username, Key.accountID, Key.accountPlan, Key.avatarURL,
            Key.deviceCode, Key.userCode, Key.verificationURI, Key.verificationURIComplete,
            Key.expiresAt, Key.pollInterval, Key.credentialClientID, Key.hasAccessToken,
            Key.cachedStats, Key.settingsWatermark, Key.tokenExpiresAt, Key.isV2Flow
        ].forEach { defaults.removeObject(forKey: $0) }
        RemoteLibraryStore.clear(source: .simkl, profileId: profileScope)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        RemoteTrackingState.normalizeWatchProgressSource(in: defaults)
        RemoteTrackingState.normalizeLibrarySource(in: defaults)
        RemoteTrackingState.normalizeMoreLikeThisSource(in: defaults)
    }

    /// Clears auth when the settings Client ID no longer matches the one that
    /// created the token or pending PIN.
    @discardableResult
    static func invalidateIfClientIDChanged(
        currentClientID: String,
        profileScope: String,
        store defaults: UserDefaults,
        tokenStorage: SimklTokenStorage
    ) -> Bool {
        let bound = defaults.string(forKey: Key.credentialClientID)
        guard let bound, bound != currentClientID else { return false }
        clearAuth(profileScope: profileScope, store: defaults, tokenStorage: tokenStorage)
        return true
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
}

// MARK: - API models

struct SimklPINCodeResponse: Decodable, Equatable {
    let result: String?
    let deviceCode: String?
    let userCode: String
    let verificationURI: String
    let verificationURIComplete: String?
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case result
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURL = "verification_url"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }

    init(
        result: String? = "OK",
        deviceCode: String? = "DEVICE_CODE",
        userCode: String,
        verificationURI: String,
        verificationURIComplete: String? = nil,
        expiresIn: Int,
        interval: Int
    ) {
        self.result = result
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresIn = expiresIn
        self.interval = interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        deviceCode = try container.decodeIfPresent(String.self, forKey: .deviceCode)
        userCode = try container.decode(String.self, forKey: .userCode)
        if let uri = try container.decodeIfPresent(String.self, forKey: .verificationURI) {
            verificationURI = uri
        } else if let url = try container.decodeIfPresent(String.self, forKey: .verificationURL) {
            verificationURI = url
        } else {
            verificationURI = SimklConfig.pinVerificationURL
        }
        verificationURIComplete = try container.decodeIfPresent(String.self, forKey: .verificationURIComplete)
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 900
        interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 5
    }
}

struct SimklOAuthTokenResponse: Decodable, Equatable {
    let accessToken: String
    let tokenType: String?
    let scope: String?
    let expiresIn: Int?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }

    init(
        accessToken: String,
        tokenType: String? = "Bearer",
        scope: String? = "media:read media:write",
        expiresIn: Int? = 604800,
        refreshToken: String? = nil
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
    }
}

struct SimklPINPollResponse: Decodable {
    let result: String?
    let message: String?
    let accessToken: String?
    /// Present when the original PIN disappeared and the server mint a new code.
    let deviceCode: String?
    let userCode: String?
    let verificationURI: String?
    let expiresIn: Int?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case result
        case message
        case accessToken = "access_token"
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decodeIfPresent(String.self, forKey: .result)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken)
        deviceCode = try container.decodeIfPresent(String.self, forKey: .deviceCode)
        userCode = try container.decodeIfPresent(String.self, forKey: .userCode)
        if let uri = try container.decodeIfPresent(String.self, forKey: .verificationURI) {
            verificationURI = uri
        } else {
            verificationURI = try container.decodeIfPresent(String.self, forKey: .verificationURL)
        }
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn)
        interval = try container.decodeIfPresent(Int.self, forKey: .interval)
    }

    /// Server fell through to create-a-new-code after the original PIN was deleted.
    var isOriginalCodeGone: Bool {
        deviceCode != nil && accessToken == nil
    }
}

struct SimklUserSettingsResponse: Decodable {
    struct User: Decodable {
        let name: String?
        let avatar: String?
    }

    struct Account: Decodable {
        let id: Int?
        let type: String?
    }

    let user: User?
    let account: Account?
}

private struct SimklUserStatsResponse: Decodable {
    struct Count: Decodable {
        let count: Int?
        let watchedEpisodesCount: Int?

        enum CodingKeys: String, CodingKey {
            case count
            case watchedEpisodesCount = "watched_episodes_count"
        }
    }

    struct Movies: Decodable {
        let completed: Count?
    }

    struct Series: Decodable {
        let watching: Count?
        let hold: Count?
        let planToWatch: Count?
        let notInteresting: Count?
        let completed: Count?

        enum CodingKeys: String, CodingKey {
            case watching, hold, completed
            case planToWatch = "plantowatch"
            case notInteresting = "notinteresting"
        }

        var watchedShows: Int {
            [watching, hold, planToWatch, notInteresting, completed]
                .compactMap { group in
                    guard (group?.watchedEpisodesCount ?? 0) > 0 else { return nil }
                    return group?.count
                }
                .reduce(0, +)
        }

        var watchedEpisodes: Int {
            [watching, hold, planToWatch, notInteresting, completed]
                .compactMap { $0?.watchedEpisodesCount }
                .reduce(0, +)
        }
    }

    let totalMinutes: Int?
    let movies: Movies?
    let tv: Series?
    let anime: Series?

    enum CodingKeys: String, CodingKey {
        case movies, tv, anime
        case totalMinutes = "total_mins"
    }

    var cachedStats: SimklCachedStats {
        let totalMinutes = totalMinutes ?? 0
        return SimklCachedStats(
            moviesWatched: movies?.completed?.count,
            showsWatched: (tv?.watchedShows ?? 0) + (anime?.watchedShows ?? 0),
            episodesWatched: (tv?.watchedEpisodes ?? 0) + (anime?.watchedEpisodes ?? 0),
            totalWatchedHours: totalMinutes > 0 ? totalMinutes / 60 : nil
        )
    }
}

enum SimklPollResult {
    case pending
    case approved(String?)
    case superseded
    case expired
    case originalCodeGone
    case rateLimited(Int)
    case revoked
    case failed(String)
}

// MARK: - Auth service

final class SimklAuthService {
    private let client: SimklAPIClient
    private let store: UserDefaults
    private let profileScope: String
    private let tokenStorage: SimklTokenStorage

    init(
        client: SimklAPIClient = SimklAPIClient(),
        store: UserDefaults = ProfileSettings.current,
        profileScope: String = "default",
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage()
    ) {
        self.client = client
        self.store = store
        self.profileScope = profileScope
        self.tokenStorage = tokenStorage
    }

    func hasRequiredCredentials() -> Bool {
        SimklConfig.isConfigured(in: store)
    }

    func currentState() -> SimklAuthState {
        SimklAuthStore.state(in: store, profileScope: profileScope, tokenStorage: tokenStorage)
    }

    /// Clears token and pending PIN when the settings Client ID no longer matches.
    @discardableResult
    func invalidateIfCredentialsChanged() -> Bool {
        SimklAuthStore.invalidateIfClientIDChanged(
            currentClientID: clientID,
            profileScope: profileScope,
            store: store,
            tokenStorage: tokenStorage
        )
    }

    func startPINAuth() async throws -> SimklPINCodeResponse {
        let requestedClientID = clientID
        guard hasRequiredCredentials() else {
            throw SimklServiceError.message("Enter your Simkl Client ID first.")
        }

        invalidateIfCredentialsChanged()

        let state = currentState()
        if state.hasActivePINFlow(in: store),
           let userCode = state.userCode,
           let expiresAt = state.expiresAt {
            return SimklPINCodeResponse(
                deviceCode: state.deviceCode,
                userCode: userCode,
                verificationURI: state.verificationURI ?? SimklConfig.pinVerificationURL,
                verificationURIComplete: state.verificationURIComplete,
                expiresIn: max(Int((expiresAt - Date().timeIntervalSince1970 * 1000.0) / 1000.0), 0),
                interval: state.pollInterval ?? 5
            )
        }

        // Try AUTH V2 Device Flow first (RFC 8628)
        let v2Result: SimklHTTPResult<SimklPINCodeResponse> = try await client.postFormURLEncoded(
            path: "oauth2/device",
            parameters: [
                "client_id": requestedClientID,
                "scope": "media:read media:write"
            ]
        )

        guard !Task.isCancelled, clientID == requestedClientID else { throw CancellationError() }

        if (200..<300).contains(v2Result.statusCode), let pin = v2Result.value {
            guard !pin.userCode.isEmpty else {
                throw SimklServiceError.message("Simkl did not return a PIN code.")
            }
            if state.credentialClientID != nil && state.credentialClientID != requestedClientID {
                tokenStorage.setAccessToken(nil, for: profileScope)
                tokenStorage.setRefreshToken(nil, for: profileScope)
            }
            SimklAuthStore.savePINFlow(pin, isV2Flow: true, clientID: requestedClientID, store: store)
            return pin
        }

        // If client_id is not enabled for OAuth 2.0 (legacy V1 App) or endpoint not found, fall back to AUTH V1 PIN flow
        let shouldFallbackToV1 = v2Result.statusCode == 404 || (
            v2Result.statusCode == 401 && (
                v2Result.oauthError == "invalid_client" ||
                (v2Result.errorMessage ?? "").lowercased().contains("oauth 2.0")
            )
        )

        if shouldFallbackToV1 {
            let v1Response: SimklHTTPResult<SimklPINCodeResponse> = try await client.get(
                path: "oauth/pin",
                clientID: requestedClientID
            )

            guard !Task.isCancelled, clientID == requestedClientID else { throw CancellationError() }

            switch v1Response.statusCode {
            case 200..<300:
                let pin = try v1Response.valueOrThrow()
                guard !pin.userCode.isEmpty else {
                    throw SimklServiceError.message("Simkl did not return a PIN code.")
                }
                if state.credentialClientID != nil && state.credentialClientID != requestedClientID {
                    tokenStorage.setAccessToken(nil, for: profileScope)
                    tokenStorage.setRefreshToken(nil, for: profileScope)
                }
                SimklAuthStore.savePINFlow(pin, isV2Flow: false, clientID: requestedClientID, store: store)
                return pin
            case 403, 412:
                throw SimklServiceError.message(
                    v1Response.errorMessage ?? "Simkl rejected the Client ID. Check the value and try again."
                )
            case 429:
                throw SimklServiceError.message(
                    v1Response.errorMessage ?? "Simkl is rate limiting login attempts. Wait and try again."
                )
            default:
                throw SimklServiceError.message(
                    v1Response.errorMessage ?? "Unable to start Simkl login (\(v1Response.statusCode))."
                )
            }
        }

        switch v2Result.statusCode {
        case 403, 412:
            throw SimklServiceError.message(
                v2Result.errorMessage ?? "Simkl rejected the Client ID. Check the value and try again."
            )
        case 429:
            throw SimklServiceError.message(
                v2Result.errorMessage ?? "Simkl is rate limiting login attempts. Wait and try again."
            )
        default:
            throw SimklServiceError.message(
                v2Result.errorMessage ?? "Unable to start Simkl login (\(v2Result.statusCode))."
            )
        }
    }

    func pollPINToken() async -> SimklPollResult {
        guard hasRequiredCredentials() else {
            return .failed("Enter your Simkl Client ID first.")
        }

        let state = currentState()
        guard state.hasActivePINFlow(in: store) else {
            if let expiresAt = state.expiresAt,
               Date().timeIntervalSince1970 * 1000.0 >= expiresAt {
                SimklAuthStore.clearPINFlow(store: store)
                return .expired
            }
            return .failed("No active Simkl PIN code.")
        }

        if let expiresAt = state.expiresAt,
           Date().timeIntervalSince1970 * 1000.0 >= expiresAt {
            SimklAuthStore.clearPINFlow(store: store)
            return .expired
        }

        if state.isV2Flow {
            return await pollV2DeviceToken(state: state)
        } else {
            return await pollV1PINToken(state: state)
        }
    }

    private func pollV2DeviceToken(state: SimklAuthState) async -> SimklPollResult {
        guard let requestedClientID = state.credentialClientID,
              clientID == requestedClientID else { return .pending }
        guard let deviceCode = state.deviceCode, !deviceCode.isEmpty else {
            return .failed("No active Simkl device code.")
        }

        do {
            let response: SimklHTTPResult<SimklOAuthTokenResponse> = try await client.postFormURLEncoded(
                path: "oauth2/token",
                parameters: [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "client_id": requestedClientID,
                    "device_code": deviceCode
                ]
            )

            let latestState = currentState()
            guard !Task.isCancelled,
                  latestState.hasActivePINFlow(in: store),
                  latestState.userCode == state.userCode,
                  latestState.deviceCode == state.deviceCode,
                  latestState.credentialClientID == requestedClientID else { return .superseded }

            switch response.statusCode {
            case 200..<300:
                guard let body = response.value, !body.accessToken.isEmpty else {
                    return .failed("Simkl returned an empty token response.")
                }
                SimklAuthStore.saveToken(
                    body.accessToken,
                    refreshToken: body.refreshToken,
                    expiresIn: body.expiresIn,
                    clientID: requestedClientID,
                    profileScope: profileScope,
                    store: store,
                    tokenStorage: tokenStorage
                )
                guard currentState().accessToken == body.accessToken else {
                    return .failed("Unable to securely save the Simkl login. Try connecting again.")
                }
                SimklAuthStore.clearPINFlow(store: store)
                TraktSettingsStore.selectWatchProgressSourceOnConnect(.simkl, in: store)
                let username = await fetchUserSettings()
                guard !Task.isCancelled, clientID == requestedClientID else { return .superseded }
                return .approved(username)

            case 400:
                let error = response.oauthError
                if error == "authorization_pending" {
                    return .pending
                } else if error == "slow_down" {
                    let next = min((state.pollInterval ?? 5) + 5, 60)
                    SimklAuthStore.updatePollInterval(next, store: store)
                    return .rateLimited(next)
                } else if error == "expired_token" {
                    SimklAuthStore.clearPINFlow(store: store)
                    return .expired
                } else {
                    return .failed(response.errorMessage ?? "Simkl device polling error (\(error ?? "unknown")).")
                }

            case 401:
                if response.oauthError == "invalid_client" {
                    return .failed(response.errorMessage ?? "Invalid Simkl Client ID.")
                }
                SimklAuthStore.clearAuth(
                    profileScope: profileScope,
                    store: store,
                    tokenStorage: tokenStorage
                )
                return .revoked

            case 429:
                let next = min((state.pollInterval ?? 5) + 5, 60)
                SimklAuthStore.updatePollInterval(next, store: store)
                return .rateLimited(next)

            default:
                return .failed(response.errorMessage ?? "Simkl polling failed (\(response.statusCode)).")
            }
        } catch {
            if Task.isCancelled { return .superseded }
            return .failed("Network error. Retrying is safe.")
        }
    }

    private func pollV1PINToken(state: SimklAuthState) async -> SimklPollResult {
        guard let requestedClientID = state.credentialClientID,
              clientID == requestedClientID else { return .pending }
        guard let userCode = state.userCode, !userCode.isEmpty else {
            return .failed("No active Simkl PIN code.")
        }

        do {
            let encoded = userCode.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userCode
            let response: SimklHTTPResult<SimklPINPollResponse> = try await client.get(
                path: "oauth/pin/\(encoded)",
                clientID: requestedClientID
            )

            let latestState = currentState()
            guard !Task.isCancelled,
                  latestState.hasActivePINFlow(in: store),
                  latestState.userCode == state.userCode,
                  latestState.deviceCode == state.deviceCode,
                  latestState.credentialClientID == requestedClientID else { return .superseded }

            switch response.statusCode {
            case 200..<300:
                guard let body = response.value else {
                    return .failed("Simkl returned an empty poll response.")
                }
                if body.isOriginalCodeGone {
                    SimklAuthStore.clearPINFlow(store: store)
                    return .originalCodeGone
                }
                if let token = body.accessToken, !token.isEmpty, body.result?.uppercased() == "OK" {
                    SimklAuthStore.saveToken(
                        token,
                        clientID: requestedClientID,
                        profileScope: profileScope,
                        store: store,
                        tokenStorage: tokenStorage
                    )
                    guard currentState().accessToken == token else {
                        return .failed("Unable to securely save the Simkl login. Try connecting again.")
                    }
                    SimklAuthStore.clearPINFlow(store: store)
                    TraktSettingsStore.selectWatchProgressSourceOnConnect(.simkl, in: store)
                    let username = await fetchUserSettings()
                    guard !Task.isCancelled, clientID == requestedClientID else { return .superseded }
                    return .approved(username)
                }
                if body.result?.uppercased() == "KO" {
                    return .pending
                }
                return .pending
            case 401:
                SimklAuthStore.clearAuth(
                    profileScope: profileScope,
                    store: store,
                    tokenStorage: tokenStorage
                )
                return .revoked
            case 403, 412:
                return .failed(
                    response.errorMessage ?? "Simkl rejected the Client ID. Check the value and try again."
                )
            case 429:
                let next = min((state.pollInterval ?? 5) + 5, 60)
                SimklAuthStore.updatePollInterval(next, store: store)
                return .rateLimited(next)
            default:
                return .failed(
                    response.errorMessage ?? "Simkl PIN polling failed (\(response.statusCode))."
                )
            }
        } catch {
            if Task.isCancelled { return .superseded }
            return .failed("Network error. Retrying is safe.")
        }
    }

    /// Automatically refreshes the OAuth 2.0 access token when expiring or expired.
    /// AUTH V1 legacy tokens (which have no refresh grant) return `true` immediately.
    func refreshTokenIfNeeded(
        force: Bool = false,
        shouldCommit: () -> Bool = { true },
        didRefreshToken: (String) -> Void = { _ in }
    ) async -> Bool {
        guard shouldCommit(), ProfileSettings.isActiveStore(store), hasRequiredCredentials() else { return false }
        let state = currentState()
        guard state.isAuthenticated(in: store) else { return false }
        let requestedClientID = clientID

        // V1 tokens are long-lived (5 years) and do not support refreshing
        guard state.isV2 else { return true }
        guard let refreshToken = state.refreshToken, !refreshToken.isEmpty else { return false }

        if !force && !isTokenExpiredOrExpiring(state) {
            return true
        }

        do {
            let response: SimklHTTPResult<SimklOAuthTokenResponse> = try await client.postFormURLEncoded(
                path: "oauth2/token",
                parameters: [
                    "grant_type": "refresh_token",
                    "client_id": requestedClientID,
                    "refresh_token": refreshToken
                ]
            )

            let latestState = currentState()
            guard !Task.isCancelled, shouldCommit(), ProfileSettings.isActiveStore(store),
                  clientID == requestedClientID,
                  latestState.accessToken == state.accessToken,
                  latestState.refreshToken == refreshToken else { return false }

            guard (200..<300).contains(response.statusCode), let token = response.value else {
                if response.statusCode == 401 || (response.statusCode == 400 && response.oauthError == "invalid_grant") {
                    SimklAuthStore.clearAuth(
                        profileScope: profileScope,
                        store: store,
                        tokenStorage: tokenStorage
                    )
                }
                return false
            }

            SimklAuthStore.saveToken(
                token.accessToken,
                refreshToken: token.refreshToken ?? refreshToken,
                expiresIn: token.expiresIn,
                clientID: requestedClientID,
                profileScope: profileScope,
                store: store,
                tokenStorage: tokenStorage,
                isNewLogin: false
            )
            didRefreshToken(token.accessToken)
            return true
        } catch {
            return false
        }
    }

    private func isTokenExpiredOrExpiring(_ state: SimklAuthState) -> Bool {
        guard let expiresAt = state.tokenExpiresAt else { return false }
        let now = Date().timeIntervalSince1970 * 1000.0
        // Refresh proactively when within 24 hours of expiry
        let buffer = 24.0 * 60.0 * 60.0 * 1000.0
        return now >= (expiresAt - buffer)
    }

    func logout() {
        let state = currentState()
        if state.isV2, let token = state.refreshToken ?? state.accessToken {
            let clientID = self.clientID
            Task { [client] in
                _ = try? await client.postFormURLEncodedRaw(
                    path: "oauth2/revoke",
                    parameters: [
                        "client_id": clientID,
                        "token": token
                    ]
                )
            }
        }
        SimklAuthStore.clearAuth(
            profileScope: profileScope,
            store: store,
            tokenStorage: tokenStorage
        )
    }

    func clearPINFlow() {
        SimklAuthStore.clearPINFlow(store: store)
    }

    /// Refreshes the cached profile only when the account actually changed.
    ///
    /// `/users/settings` is set-and-forget in practice, and Simkl asks callers
    /// to gate it on the `settings.all` activity timestamp instead of refetching
    /// on every launch or screen appearance. `/sync/activities` is the cheapest
    /// call in the API, so most appearances now cost one small read and stop.
    @discardableResult
    func refreshUserSettingsIfNeeded() async -> String? {
        guard await refreshTokenIfNeeded() else { return nil }
        let state = currentState()
        guard let token = state.accessToken, !token.isEmpty else { return nil }

        let cachedName = state.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasCachedProfile = !cachedName.isEmpty && state.accountID?.isEmpty == false

        // Nothing cached yet, so there is nothing to compare a timestamp
        // against — read the profile and record the watermark for next time.
        guard hasCachedProfile else {
            let username = await fetchUserSettings()
            if username != nil, let watermark = await settingsWatermark(token: token) {
                SimklAuthStore.saveSettingsWatermark(watermark, store: store)
            }
            return username
        }

        guard let watermark = await settingsWatermark(token: token) else {
            return cachedName
        }
        guard watermark != SimklAuthStore.settingsWatermark(in: store) else {
            return cachedName
        }

        let username = await fetchUserSettings()
        if username != nil, !Task.isCancelled, currentState().accessToken == token {
            SimklAuthStore.saveSettingsWatermark(watermark, store: store)
        }
        return username
    }

    private func settingsWatermark(token: String) async -> String? {
        let response: SimklHTTPResult<SimklActivitiesResponse>? = try? await client.get(
            path: "sync/activities",
            clientID: clientID,
            accessToken: token
        )
        return response?.value?.settings?.all
    }

    @discardableResult
    func fetchUserSettings() async -> String? {
        guard await refreshTokenIfNeeded(), !Task.isCancelled else { return nil }
        guard let token = currentState().accessToken, !token.isEmpty else { return nil }
        let requestedClientID = clientID
        do {
            let response: SimklHTTPResult<SimklUserSettingsResponse> = try await client.postEmptyBody(
                path: "users/settings",
                clientID: requestedClientID,
                accessToken: token
            )
            guard !Task.isCancelled else { return nil }
            if response.statusCode == 401 {
                guard currentState().accessToken == token,
                      clientID == requestedClientID else { return nil }
                var rejectedToken = token
                if await refreshTokenIfNeeded(force: true),
                   let refreshedToken = currentState().accessToken {
                    rejectedToken = refreshedToken
                    let retryResponse: SimklHTTPResult<SimklUserSettingsResponse> = try await client.postEmptyBody(
                        path: "users/settings",
                        clientID: requestedClientID,
                        accessToken: refreshedToken
                    )
                    guard !Task.isCancelled else { return nil }
                    if (200..<300).contains(retryResponse.statusCode), let body = retryResponse.value {
                        guard currentState().accessToken == refreshedToken else { return nil }
                        let username = body.user?.name
                        let accountID = body.account?.id.map(String.init)
                        let plan = body.account?.type
                        let avatar = body.user?.avatar
                        SimklAuthStore.saveUser(
                            username: username,
                            accountID: accountID,
                            accountPlan: plan,
                            avatarURL: avatar,
                            store: store
                        )
                        return username
                    }
                    guard retryResponse.statusCode == 401 else { return nil }
                }
                clearAuthIfCurrent(token: rejectedToken, clientID: requestedClientID)
                return nil
            }
            guard !Task.isCancelled, currentState().accessToken == token,
                  let body = try? response.valueOrThrow() else { return nil }
            let username = body.user?.name
            let accountID = body.account?.id.map(String.init)
            let plan = body.account?.type
            let avatar = body.user?.avatar
            SimklAuthStore.saveUser(
                username: username,
                accountID: accountID,
                accountPlan: plan,
                avatarURL: avatar,
                store: store
            )
            return username
        } catch {
            return nil
        }
    }

    func fetchUserStats() async -> SimklCachedStats? {
        guard await refreshTokenIfNeeded(), !Task.isCancelled else { return nil }
        guard let token = currentState().accessToken, !token.isEmpty else { return nil }
        let requestedClientID = clientID
        var accountID = currentState().accountID
        if accountID?.isEmpty != false {
            _ = await fetchUserSettings()
            accountID = currentState().accountID
        }
        guard !Task.isCancelled, let accountID, !accountID.isEmpty else { return nil }

        do {
            let response: SimklHTTPResult<SimklUserStatsResponse> = try await client.postEmptyBody(
                path: "users/\(accountID)/stats",
                clientID: requestedClientID,
                accessToken: token
            )
            guard !Task.isCancelled else { return nil }
            if response.statusCode == 401 {
                guard currentState().accessToken == token,
                      clientID == requestedClientID else { return nil }
                var rejectedToken = token
                if await refreshTokenIfNeeded(force: true),
                   let refreshedToken = currentState().accessToken {
                    rejectedToken = refreshedToken
                    let retryResponse: SimklHTTPResult<SimklUserStatsResponse> = try await client.postEmptyBody(
                        path: "users/\(accountID)/stats",
                        clientID: requestedClientID,
                        accessToken: refreshedToken
                    )
                    guard !Task.isCancelled else { return nil }
                    if (200..<300).contains(retryResponse.statusCode), let body = retryResponse.value {
                        guard currentState().accessToken == refreshedToken else { return nil }
                        let stats = body.cachedStats
                        SimklAuthStore.saveCachedStats(stats, store: store)
                        return stats
                    }
                    guard retryResponse.statusCode == 401 else { return nil }
                }
                clearAuthIfCurrent(token: rejectedToken, clientID: requestedClientID)
                return nil
            }
            guard !Task.isCancelled, currentState().accessToken == token,
                  let body = try? response.valueOrThrow() else { return nil }
            let stats = body.cachedStats
            SimklAuthStore.saveCachedStats(stats, store: store)
            return stats
        } catch {
            return nil
        }
    }

    private func clearAuthIfCurrent(token: String, clientID expectedClientID: String) {
        let state = currentState()
        guard !Task.isCancelled, clientID == expectedClientID,
              state.credentialClientID == expectedClientID,
              state.accessToken == token else { return }
        SimklAuthStore.clearAuth(
            profileScope: profileScope,
            store: store,
            tokenStorage: tokenStorage
        )
    }

    private var clientID: String { SimklConfig.clientID(in: store) }
}

// MARK: - Settings view model

@MainActor
final class SimklSettingsViewModel: ObservableObject {
    @Published var mode: SimklConnectionMode = .disconnected
    @Published var credentialsConfigured = false
    @Published var isLoading = false
    @Published var isPolling = false
    @Published var username: String?
    @Published var accountPlan: String?
    @Published var accountID: String?
    @Published var avatarURL: String?
    @Published var connectedStats: SimklCachedStats?
    @Published var deviceUserCode: String?
    @Published var verificationURI: String?
    @Published var verificationURIComplete: String?
    @Published var isLegacyV1 = false
    @Published var pinExpiresAtMillis: Double?
    @Published var pollInterval = 5
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var loadingDebugInfo: String?
    @Published var isTransferringHistory = false
    @Published var isTransferringLibrary = false
    @Published var isTransferringProgress = false
    @Published var isStatsLoading = false
    @Published var historyTransferProgress: Int?
    @Published var historyTransferSourceLabel: String?
    @Published var libraryTransferProgress: Int?
    @Published var libraryTransferSourceLabel: String?
    @Published var progressTransferProgress: Int?
    @Published var progressTransferSourceLabel: String?

    private let store: UserDefaults
    private let service: SimklAuthService
    private var connectionTask: Task<Void, Never>?
    private var loadingTimeoutTask: Task<Void, Never>?
    private var loadingStage = "none"
    private var loadingStartedAt: Date?
    private var pollTask: Task<Void, Never>?
    private var historyTransferTask: Task<Void, Never>?
    private var libraryTransferTask: Task<Void, Never>?
    private var progressTransferTask: Task<Void, Never>?
    private var authGeneration: UInt = 0
    private var connectedDataTask: Task<Void, Never>?
    private var connectedDataRequestID: UUID?

    init(
        store: UserDefaults = ProfileSettings.current,
        profileScope: String = "default",
        service: SimklAuthService? = nil,
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage()
    ) {
        self.store = store
        self.service = service ?? SimklAuthService(
            store: store,
            profileScope: profileScope,
            tokenStorage: tokenStorage
        )
        reload()
    }

    deinit {
        connectedDataTask?.cancel()
        connectionTask?.cancel()
        loadingTimeoutTask?.cancel()
        pollTask?.cancel()
        historyTransferTask?.cancel()
        libraryTransferTask?.cancel()
        progressTransferTask?.cancel()
    }

    var isTraktTransferAvailable: Bool {
        TraktAuthStore.isAuthenticated(in: store)
    }

    func reload() {
        service.invalidateIfCredentialsChanged()
        credentialsConfigured = service.hasRequiredCredentials()
        let state = service.currentState()
        username = state.username
        accountPlan = state.accountPlan
        accountID = state.accountID
        avatarURL = state.avatarURL
        deviceUserCode = state.userCode
        verificationURI = state.verificationURI
        verificationURIComplete = state.verificationURIComplete
        pinExpiresAtMillis = state.expiresAt
        pollInterval = state.pollInterval ?? 5
        let isAuthenticated = state.isAuthenticated(in: store)
        isLegacyV1 = isAuthenticated && !state.isV2
        mode = isAuthenticated
            ? .connected
            : (state.hasActivePINFlow(in: store) ? .awaitingApproval : .disconnected)
        connectedStats = isAuthenticated ? SimklAuthStore.cachedStats(in: store) : nil
        if mode == .awaitingApproval {
            startPolling()
        } else {
            pollTask?.cancel()
            isPolling = false
        }
    }

    func credentialsDidChange() {
        cancelConnectedDataTask()
        isLoading = false
        isStatsLoading = false
        finishLoading(clearDebug: true)
        errorMessage = nil
        statusMessage = nil
        pollTask?.cancel()
        isPolling = false
        let changed = service.invalidateIfCredentialsChanged()
        if changed {
            statusMessage = "Simkl Client ID changed. Connect again."
        }
        // Even without a bound credential, empty Client ID must drop pending UI state.
        if !service.hasRequiredCredentials() {
            service.clearPINFlow()
            service.logout()
        }
        reload()
    }

    func connect() {
        guard !isLoading else { return }
        guard credentialsConfigured else {
            errorMessage = "Enter your Simkl Client ID first."
            return
        }
        isLoading = true
        statusMessage = nil
        errorMessage = nil
        beginLoadingTimeout(stage: "requesting authorization from Simkl")
        authGeneration &+= 1
        let generation = authGeneration
        connectionTask?.cancel()
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await service.startPINAuth()
                guard !Task.isCancelled, generation == authGeneration else {
                    if service.currentState().userCode == response.userCode { service.clearPINFlow() }
                    return
                }
                deviceUserCode = response.userCode
                verificationURI = response.verificationURI
                verificationURIComplete = response.verificationURIComplete
                pinExpiresAtMillis = Date().timeIntervalSince1970 * 1000.0 + Double(response.expiresIn * 1000)
                pollInterval = max(response.interval, 5)
                mode = .awaitingApproval
                statusMessage = "Waiting for approval…"
                isLoading = false
                finishLoading(clearDebug: true)
                startPolling()
            } catch {
                guard !Task.isCancelled, generation == authGeneration else { return }
                errorMessage = error.localizedDescription
                isLoading = false
                finishLoading(clearDebug: false)
            }
        }
    }

    func cancelPINFlow() {
        authGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = nil
        isLoading = false
        pollTask?.cancel()
        isPolling = false
        service.clearPINFlow()
        statusMessage = nil
        errorMessage = nil
        loadingDebugInfo = nil
        verificationURIComplete = nil
        reload()
    }

    func retryPolling() {
        errorMessage = nil
        startPolling()
    }

    func disconnect() {
        cancelConnectedDataTask()
        authGeneration &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = nil
        pollTask?.cancel()
        historyTransferTask?.cancel()
        libraryTransferTask?.cancel()
        progressTransferTask?.cancel()
        isPolling = false
        isTransferringHistory = false
        isTransferringLibrary = false
        isTransferringProgress = false
        historyTransferProgress = nil
        historyTransferSourceLabel = nil
        libraryTransferProgress = nil
        libraryTransferSourceLabel = nil
        progressTransferProgress = nil
        progressTransferSourceLabel = nil
        isLoading = true
        finishLoading(clearDebug: true)
        service.logout()
        isLoading = false
        isStatsLoading = false
        statusMessage = "Disconnected from Simkl."
        username = nil
        accountPlan = nil
        accountID = nil
        avatarURL = nil
        verificationURIComplete = nil
        isLegacyV1 = false
        reload()
    }

    /// Screen-appearance refresh. Deliberately cheap: the profile read is gated
    /// on the account's own change timestamp, and stats are left alone.
    ///
    /// `/users/{id}/stats` is the most expensive call in the Simkl API —
    /// computed live over the user's whole history on every request, with the
    /// docs asking that it fire only on an explicit user action, never on
    /// launch, resume, or in a polling loop. The cached figures from the last
    /// deliberate refresh are what the card shows until the user asks again.
    func loadConnectedData(includeStats: Bool = false) {
        guard mode == .connected, !isLoading, !isStatsLoading,
              !isTransferringHistory, !isTransferringLibrary,
              !isTransferringProgress else { return }
        connectedDataTask?.cancel()
        let requestID = UUID()
        connectedDataRequestID = requestID
        let generation = authGeneration
        isLoading = true
        isStatsLoading = includeStats
        beginLoadingTimeout(stage: includeStats
            ? "loading Simkl account, watch history, library, and stats"
            : "loading Simkl account details")
        connectedDataTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if connectedDataRequestID == requestID {
                    connectedDataTask = nil
                    connectedDataRequestID = nil
                }
            }
            _ = await service.refreshUserSettingsIfNeeded()
            guard !Task.isCancelled, generation == authGeneration,
                  connectedDataRequestID == requestID else { return }
            if includeStats {
                let stats = await service.fetchUserStats()
                guard !Task.isCancelled, generation == authGeneration,
                      connectedDataRequestID == requestID else { return }
                connectedStats = stats
                isStatsLoading = false
            }
            isLoading = false
            finishLoading(clearDebug: true)
            reload()
        }
    }

    func refreshNow() {
        guard mode == .connected, !isLoading,
              !isTransferringHistory, !isTransferringLibrary,
              !isTransferringProgress else { return }
        connectedDataTask?.cancel()
        let requestID = UUID()
        connectedDataRequestID = requestID
        let generation = authGeneration
        isLoading = true
        isStatsLoading = true
        statusMessage = "Syncing Simkl…"
        errorMessage = nil
        beginLoadingTimeout(stage: "refreshing Simkl account, history, library, and stats")
        connectedDataTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if connectedDataRequestID == requestID {
                    connectedDataTask = nil
                    connectedDataRequestID = nil
                }
            }
            _ = await service.fetchUserSettings()
            guard !Task.isCancelled, generation == authGeneration,
                  connectedDataRequestID == requestID else { return }
            async let stats = service.fetchUserStats()
            let historySynced = await SimklHistoryService.syncWatchedHistory(
                store: store,
                force: true
            )
            guard !Task.isCancelled, generation == authGeneration,
                  connectedDataRequestID == requestID else { return }
            _ = await SimklLibraryService.fetchLibrary(
                repository: CinemetaCatalogRepository(),
                store: store,
                force: true
            )
            guard !Task.isCancelled, generation == authGeneration,
                  connectedDataRequestID == requestID else { return }
            let fetchedStats = await stats
            guard !Task.isCancelled, generation == authGeneration,
                  connectedDataRequestID == requestID else { return }
            connectedStats = fetchedStats
            isStatsLoading = false
            isLoading = false
            finishLoading(clearDebug: true)
            statusMessage = historySynced
                ? "Simkl sync completed."
                : "Simkl account refreshed, but watch history could not be imported."
            NotificationCenter.default.post(
                name: TraktSettingsStore.libraryChangedNotification,
                object: nil
            )
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
            reload()
        }
    }

    func transferWatchHistory(from source: SimklHistoryTransferSource) {
        guard mode == .connected, !isLoading,
              !isTransferringHistory, !isTransferringLibrary,
              !isTransferringProgress else { return }
        if source == .trakt, !isTraktTransferAvailable {
            errorMessage = "Connect Trakt before transferring its watch history."
            return
        }

        historyTransferTask?.cancel()
        historyTransferProgress = 1
        historyTransferSourceLabel = source.label
        isTransferringHistory = true
        statusMessage = "Preparing \(source.label) watch history…"
        errorMessage = nil

        historyTransferTask = Task { [weak self] in
            guard let self else { return }
            let items: [WatchedStoreItem]?
            switch source {
            case .nuvioSync:
                items = WatchedStore.items()
            case .trakt:
                items = await TraktHistoryService.fetchWatchedHistory(store: store)
            }

            guard !Task.isCancelled else { return }
            guard let items else {
                isTransferringHistory = false
                errorMessage = "Could not load \(source.label) watch history."
                return
            }

            statusMessage = "Transferring \(source.label) watch history to Simkl…"
            let result = await SimklHistoryTransferService.transfer(
                items,
                store: store
            ) { [weak self] percentage in
                await MainActor.run {
                    self?.historyTransferProgress = percentage
                }
            }

            guard !Task.isCancelled else { return }
            isTransferringHistory = false
            if result.total == 0 {
                statusMessage = "No watched history was found in \(source.label)."
            } else if result.isComplete {
                statusMessage = "Transferred all \(result.transferred) watched items from \(source.label) to Simkl."
            } else {
                statusMessage = "Transferred \(result.transferred) of \(result.total) watched items. \(result.skipped) skipped, \(result.failed) failed."
            }
            NotificationCenter.default.post(
                name: WatchedStore.changedNotification,
                object: nil
            )
        }
    }

    func transferLibrary(from source: SimklLibraryTransferSource) {
        guard mode == .connected, !isLoading,
              !isTransferringHistory, !isTransferringLibrary,
              !isTransferringProgress else { return }
        if source == .trakt, !isTraktTransferAvailable {
            errorMessage = "Connect Trakt before transferring its library."
            return
        }

        libraryTransferTask?.cancel()
        libraryTransferProgress = 1
        libraryTransferSourceLabel = source.label
        isTransferringLibrary = true
        statusMessage = "Preparing \(source.label)…"
        errorMessage = nil

        libraryTransferTask = Task { [weak self] in
            guard let self else { return }
            let items: [LibraryStoreItem]?
            switch source {
            case .nuvioLibrary:
                items = LibraryStore.items()
            case .trakt:
                items = await TraktLibraryService.fetchLibrary(
                    repository: CinemetaCatalogRepository(),
                    requireSelectedSource: false
                )
            }

            guard !Task.isCancelled else { return }
            guard let items else {
                isTransferringLibrary = false
                errorMessage = "Could not load \(source.label)."
                return
            }

            statusMessage = "Transferring \(source.label) to Simkl Plan to Watch…"
            let result = await SimklLibraryTransferService.transfer(
                items,
                store: store
            ) { [weak self] percentage in
                await MainActor.run {
                    self?.libraryTransferProgress = percentage
                }
            }

            guard !Task.isCancelled else { return }
            isTransferringLibrary = false
            if result.total == 0 {
                statusMessage = "No library items were found in \(source.label)."
            } else if result.isComplete {
                statusMessage = "Transferred all \(result.transferred) library items from \(source.label) to Simkl."
            } else {
                statusMessage = "Transferred \(result.transferred) of \(result.total) library items. \(result.skipped) skipped, \(result.failed) failed."
            }
            NotificationCenter.default.post(
                name: TraktSettingsStore.libraryChangedNotification,
                object: nil
            )
        }
    }

    func transferProgress(from source: SimklProgressTransferSource) {
        guard mode == .connected, !isLoading,
              !isTransferringHistory, !isTransferringLibrary,
              !isTransferringProgress else { return }
        if source == .trakt, !isTraktTransferAvailable {
            errorMessage = "Connect Trakt before transferring its Continue Watching progress."
            return
        }

        progressTransferTask?.cancel()
        progressTransferProgress = 1
        progressTransferSourceLabel = source.label
        isTransferringProgress = true
        statusMessage = "Preparing \(source.label) Continue Watching…"
        errorMessage = nil

        progressTransferTask = Task { [weak self] in
            guard let self else { return }
            let items: [ContinueWatchingItem]?
            switch source {
            case .nuvioSync:
                items = ContinueWatchingStore.items()
            case .trakt:
                items = await TraktProgressService.fetchContinueWatching(
                    repository: CinemetaCatalogRepository(),
                    source: .trakt,
                    updateDisplayedSnapshot: false
                )
            }

            guard !Task.isCancelled else { return }
            guard let items else {
                isTransferringProgress = false
                errorMessage = "Could not load \(source.label) Continue Watching."
                return
            }

            statusMessage = "Transferring \(source.label) progress to Simkl…"
            let result = await SimklProgressTransferService.transfer(
                items,
                store: store
            ) { [weak self] percentage in
                await MainActor.run {
                    self?.progressTransferProgress = percentage
                }
            }

            guard !Task.isCancelled else { return }
            isTransferringProgress = false
            if result.total == 0 {
                statusMessage = "No unfinished playback progress was found in \(source.label)."
            } else if result.isComplete {
                statusMessage = "Transferred all \(result.transferred) Continue Watching items from \(source.label) to Simkl."
            } else {
                statusMessage = "Transferred \(result.transferred) of \(result.total) Continue Watching items. \(result.skipped) skipped, \(result.failed) failed."
            }
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
        }
    }

    private func cancelConnectedDataTask() {
        connectedDataRequestID = nil
        connectedDataTask?.cancel()
        connectedDataTask = nil
    }

    private func startPolling() {
        pollTask?.cancel()
        isPolling = true
        let generation = authGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard generation == self.authGeneration else { return }
                let state = self.service.currentState()
                if let expiresAt = state.expiresAt,
                   Date().timeIntervalSince1970 * 1000.0 >= expiresAt {
                    self.errorMessage = "Simkl PIN expired. Start again."
                    self.service.clearPINFlow()
                    self.isPolling = false
                    self.reload()
                    return
                }

                let wait = UInt64(max(state.pollInterval ?? self.pollInterval, 5))
                try? await Task.sleep(nanoseconds: wait * 1_000_000_000)
                if Task.isCancelled || generation != self.authGeneration { return }

                let result = await self.service.pollPINToken()
                guard !Task.isCancelled, generation == self.authGeneration else { return }
                switch result {
                case .pending:
                    self.statusMessage = "Waiting for Simkl approval…"
                case .approved(let username):
                    self.username = username
                    self.statusMessage = "Connected to Simkl."
                    self.isPolling = false
                    self.reload()
                    // Connecting is the explicit action that earns the one
                    // expensive stats read.
                    self.loadConnectedData(includeStats: true)
                    return
                case .superseded:
                    self.isPolling = false
                    return
                case .expired:
                    self.errorMessage = "Simkl PIN expired. Start again."
                    self.isPolling = false
                    self.reload()
                    return
                case .originalCodeGone:
                    self.errorMessage = "Simkl PIN is no longer valid. Start again."
                    self.isPolling = false
                    self.reload()
                    return
                case .rateLimited(let interval):
                    self.pollInterval = interval
                    self.statusMessage = "Simkl rate-limited polling. Slowing down…"
                case .revoked:
                    self.errorMessage = "Simkl access was revoked. Connect again."
                    self.isPolling = false
                    self.reload()
                    return
                case .failed(let reason):
                    self.errorMessage = reason
                    self.isPolling = false
                    return
                }
            }
        }
    }

    private func beginLoadingTimeout(stage: String) {
        loadingTimeoutTask?.cancel()
        loadingStage = stage
        loadingStartedAt = Date()
        loadingDebugInfo = nil

        loadingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            } catch {
                return
            }

            guard let self,
                  !Task.isCancelled,
                  self.isLoading,
                  self.loadingStage == stage else {
                return
            }

            self.loadingDebugInfo = self.makeLoadingDebugInfo()
            self.statusMessage = "Simkl is still loading. Read or screenshot the debug report and send it to the developer."
        }
    }

    private func finishLoading(clearDebug: Bool) {
        loadingTimeoutTask?.cancel()
        loadingTimeoutTask = nil
        loadingStartedAt = nil
        if clearDebug {
            loadingDebugInfo = nil
        }
    }

    private func makeLoadingDebugInfo() -> String {
        let state = service.currentState()
        let elapsed = loadingStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? 60
        let pinReceived = !(state.userCode?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        let modeName: String
        switch mode {
        case .disconnected: modeName = "disconnected"
        case .awaitingApproval: modeName = "awaiting_approval"
        case .connected: modeName = "connected"
        }

        return [
            "SIMKL DEBUG REPORT",
            "reason=no Simkl result after \(elapsed) seconds",
            "stage=\(loadingStage)",
            "endpoint=https://api.simkl.com",
            "request_timeout_seconds=30",
            "client_id_configured=\(service.hasRequiredCredentials())",
            "pin_received=\(pinReceived)",
            "polling=\(isPolling)",
            "mode=\(modeName)",
            "app_version=\(SimklConfig.appVersion)",
            "os=\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "next=possible DNS/network/VPN issue, Simkl outage, or a request stuck before an HTTP response"
        ].joined(separator: "\n")
    }

}
