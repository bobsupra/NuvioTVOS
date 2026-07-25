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
    var username: String?
    var accountID: String?
    var accountPlan: String?
    var avatarURL: String?
    var userCode: String?
    var verificationURI: String?
    var expiresAt: Double?
    var pollInterval: Int?
    var credentialClientID: String?

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
}

/// Long-lived Simkl access tokens live in the Keychain, namespaced by profile.
final class SimklKeychainTokenStorage: SimklTokenStorage {
    private let service = "com.nuvio.tv.simkl.auth"

    func accessToken(for profileScope: String) -> String? {
        var query = keychainQuery(for: profileScope)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func setAccessToken(_ token: String?, for profileScope: String) {
        SecItemDelete(keychainQuery(for: profileScope) as CFDictionary)
        guard let token, !token.isEmpty, let data = token.data(using: .utf8) else { return }

        var addQuery = keychainQuery(for: profileScope)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func keychainQuery(for profileScope: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "accessToken.\(profileScope)"
        ]
    }
}

/// In-memory token storage for unit tests.
final class SimklMemoryTokenStorage: SimklTokenStorage {
    private var tokens: [String: String] = [:]

    func accessToken(for profileScope: String) -> String? {
        tokens[profileScope]
    }

    func setAccessToken(_ token: String?, for profileScope: String) {
        if let token, !token.isEmpty {
            tokens[profileScope] = token
        } else {
            tokens.removeValue(forKey: profileScope)
        }
    }
}

// MARK: - Auth store

enum SimklAuthStore {
    static let changedNotification = Notification.Name("nuvio.tv.simkl.auth.changed")

    private enum Key {
        static let username = "nuvio.tv.simkl.auth.username"
        static let accountID = "nuvio.tv.simkl.auth.accountID"
        static let accountPlan = "nuvio.tv.simkl.auth.accountPlan"
        static let avatarURL = "nuvio.tv.simkl.auth.avatarURL"
        static let userCode = "nuvio.tv.simkl.auth.userCode"
        static let verificationURI = "nuvio.tv.simkl.auth.verificationURI"
        static let expiresAt = "nuvio.tv.simkl.auth.expiresAt"
        static let pollInterval = "nuvio.tv.simkl.auth.pollInterval"
        static let credentialClientID = "nuvio.tv.simkl.auth.credentialClientID"
        /// Non-secret marker that a Keychain token exists for this profile.
        static let hasAccessToken = "nuvio.tv.simkl.auth.hasAccessToken"
        static let cachedStats = "nuvio.tv.simkl.auth.cachedStats"
        /// `settings.all` from the last `/users/settings` read, so the next one
        /// can be skipped until the account actually changes.
        static let settingsWatermark = "nuvio.tv.simkl.auth.settingsWatermark"
    }

    static func state(
        in defaults: UserDefaults,
        profileScope: String,
        tokenStorage: SimklTokenStorage = SimklKeychainTokenStorage()
    ) -> SimklAuthState {
        let hasMarker = defaults.bool(forKey: Key.hasAccessToken)
        let token = hasMarker ? tokenStorage.accessToken(for: profileScope) : nil
        return SimklAuthState(
            accessToken: token,
            username: defaults.string(forKey: Key.username),
            accountID: defaults.string(forKey: Key.accountID),
            accountPlan: defaults.string(forKey: Key.accountPlan),
            avatarURL: defaults.string(forKey: Key.avatarURL),
            userCode: defaults.string(forKey: Key.userCode),
            verificationURI: defaults.string(forKey: Key.verificationURI),
            expiresAt: doubleIfPresent(Key.expiresAt, defaults: defaults),
            pollInterval: intIfPresent(Key.pollInterval, defaults: defaults),
            credentialClientID: defaults.string(forKey: Key.credentialClientID)
        )
    }

    static func savePINFlow(
        _ response: SimklPINCodeResponse,
        clientID: String,
        store defaults: UserDefaults
    ) {
        if defaults.string(forKey: Key.credentialClientID) != clientID {
            [
                Key.username, Key.accountID, Key.accountPlan, Key.avatarURL,
                Key.hasAccessToken, Key.cachedStats, Key.settingsWatermark
            ].forEach { defaults.removeObject(forKey: $0) }
        }
        defaults.set(response.userCode, forKey: Key.userCode)
        defaults.set(response.verificationURI, forKey: Key.verificationURI)
        defaults.set(
            Date().timeIntervalSince1970 * 1000.0 + Double(response.expiresIn * 1000),
            forKey: Key.expiresAt
        )
        defaults.set(max(response.interval, 5), forKey: Key.pollInterval)
        defaults.set(clientID, forKey: Key.credentialClientID)
    }

    static func saveToken(
        _ accessToken: String,
        clientID: String,
        profileScope: String,
        store defaults: UserDefaults,
        tokenStorage: SimklTokenStorage
    ) {
        tokenStorage.setAccessToken(accessToken, for: profileScope)
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
        [Key.userCode, Key.verificationURI, Key.expiresAt, Key.pollInterval].forEach {
            defaults.removeObject(forKey: $0)
        }
    }

    static func clearAuth(
        profileScope: String,
        store defaults: UserDefaults,
        tokenStorage: SimklTokenStorage
    ) {
        tokenStorage.setAccessToken(nil, for: profileScope)
        [
            Key.username, Key.accountID, Key.accountPlan, Key.avatarURL,
            Key.userCode, Key.verificationURI, Key.expiresAt, Key.pollInterval,
            Key.credentialClientID, Key.hasAccessToken, Key.cachedStats,
            Key.settingsWatermark
        ].forEach { defaults.removeObject(forKey: $0) }
        NotificationCenter.default.post(name: changedNotification, object: nil)
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
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case result
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURL = "verification_url"
        case expiresIn = "expires_in"
        case interval
    }

    init(
        result: String? = "OK",
        deviceCode: String? = "DEVICE_CODE",
        userCode: String,
        verificationURI: String,
        expiresIn: Int,
        interval: Int
    ) {
        self.result = result
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
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
        expiresIn = try container.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 900
        interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 5
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
        guard hasRequiredCredentials() else {
            throw SimklServiceError.message("Enter your Simkl Client ID first.")
        }

        invalidateIfCredentialsChanged()

        let state = currentState()
        if state.hasActivePINFlow(in: store),
           let userCode = state.userCode,
           let expiresAt = state.expiresAt {
            return SimklPINCodeResponse(
                userCode: userCode,
                verificationURI: state.verificationURI ?? SimklConfig.pinVerificationURL,
                expiresIn: max(Int((expiresAt - Date().timeIntervalSince1970 * 1000.0) / 1000.0), 0),
                interval: state.pollInterval ?? 5
            )
        }

        let response: SimklHTTPResult<SimklPINCodeResponse> = try await client.get(
            path: "oauth/pin",
            clientID: clientID
        )

        switch response.statusCode {
        case 200..<300:
            let pin = try response.valueOrThrow()
            guard !pin.userCode.isEmpty else {
                throw SimklServiceError.message("Simkl did not return a PIN code.")
            }
            // Starting a PIN under a different Client ID must not keep the old token.
            if state.credentialClientID != nil && state.credentialClientID != clientID {
                tokenStorage.setAccessToken(nil, for: profileScope)
            }
            SimklAuthStore.savePINFlow(pin, clientID: clientID, store: store)
            return pin
        case 403, 412:
            throw SimklServiceError.message(
                response.errorMessage ?? "Simkl rejected the Client ID. Check the value and try again."
            )
        case 429:
            throw SimklServiceError.message(
                response.errorMessage ?? "Simkl is rate limiting login attempts. Wait and try again."
            )
        default:
            throw SimklServiceError.message(
                response.errorMessage ?? "Unable to start Simkl login (\(response.statusCode))."
            )
        }
    }

    func pollPINToken() async -> SimklPollResult {
        guard hasRequiredCredentials() else {
            return .failed("Enter your Simkl Client ID first.")
        }

        let state = currentState()
        guard state.hasActivePINFlow(in: store),
              let userCode = state.userCode,
              !userCode.isEmpty else {
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

        do {
            // Poll with user_code — device_code is only a placeholder on Simkl.
            let encoded = userCode.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? userCode
            let response: SimklHTTPResult<SimklPINPollResponse> = try await client.get(
                path: "oauth/pin/\(encoded)",
                clientID: clientID
            )

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
                        clientID: clientID,
                        profileScope: profileScope,
                        store: store,
                        tokenStorage: tokenStorage
                    )
                    guard currentState().accessToken == token else {
                        return .failed("Unable to securely save the Simkl login. Try connecting again.")
                    }
                    SimklAuthStore.clearPINFlow(store: store)
                    // Connecting Simkl is the user asking for their playback to
                    // land in Simkl, and every write is gated on this setting.
                    // Without it, Settings reads "Connected" while nothing is
                    // ever scrobbled.
                    TraktSettingsStore.selectWatchProgressSourceOnConnect(.simkl, in: store)
                    let username = await fetchUserSettings()
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
            return .failed("Network error. Retrying is safe.")
        }
    }

    func logout() {
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

        // Not every account reports one: Simkl answers with an empty `settings`
        // group where nothing has ever been changed, and then there is no
        // timestamp to gate on. Profile data is set-and-forget, so keep the
        // cache rather than refetching forever — the explicit refresh action
        // still reads it unconditionally.
        guard let watermark = await settingsWatermark(token: token) else {
            return cachedName
        }
        guard watermark != SimklAuthStore.settingsWatermark(in: store) else {
            return cachedName
        }

        let username = await fetchUserSettings()
        if username != nil {
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
        guard let token = currentState().accessToken, !token.isEmpty else { return nil }
        do {
            let response: SimklHTTPResult<SimklUserSettingsResponse> = try await client.postEmptyBody(
                path: "users/settings",
                clientID: clientID,
                accessToken: token
            )
            if response.statusCode == 401 {
                SimklAuthStore.clearAuth(
                    profileScope: profileScope,
                    store: store,
                    tokenStorage: tokenStorage
                )
                return nil
            }
            guard let body = try? response.valueOrThrow() else { return nil }
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
        guard let token = currentState().accessToken, !token.isEmpty else { return nil }
        var accountID = currentState().accountID
        if accountID?.isEmpty != false {
            _ = await fetchUserSettings()
            accountID = currentState().accountID
        }
        guard let accountID, !accountID.isEmpty else { return nil }

        do {
            // `POST` with no body, same as /users/settings — Simkl serves both
            // reads that way and neither answers GET.
            let response: SimklHTTPResult<SimklUserStatsResponse> = try await client.postEmptyBody(
                path: "users/\(accountID)/stats",
                clientID: clientID,
                accessToken: token
            )
            if response.statusCode == 401 {
                SimklAuthStore.clearAuth(
                    profileScope: profileScope,
                    store: store,
                    tokenStorage: tokenStorage
                )
                return nil
            }
            guard let body = try? response.valueOrThrow() else { return nil }
            let stats = body.cachedStats
            SimklAuthStore.saveCachedStats(stats, store: store)
            return stats
        } catch {
            return nil
        }
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
    @Published var pinExpiresAtMillis: Double?
    @Published var pollInterval = 5
    @Published var statusMessage: String?
    @Published var errorMessage: String?
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
    private var pollTask: Task<Void, Never>?
    private var historyTransferTask: Task<Void, Never>?
    private var libraryTransferTask: Task<Void, Never>?
    private var progressTransferTask: Task<Void, Never>?

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
        pollTask?.cancel()
        historyTransferTask?.cancel()
        libraryTransferTask?.cancel()
        progressTransferTask?.cancel()
    }

    var isTraktTransferAvailable: Bool {
        TraktAuthStore.state(in: store).isAuthenticated(in: store)
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
        pinExpiresAtMillis = state.expiresAt
        pollInterval = state.pollInterval ?? 5
        let isAuthenticated = state.isAuthenticated(in: store)
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
        Task {
            do {
                let response = try await service.startPINAuth()
                deviceUserCode = response.userCode
                verificationURI = response.verificationURI
                pinExpiresAtMillis = Date().timeIntervalSince1970 * 1000.0 + Double(response.expiresIn * 1000)
                pollInterval = max(response.interval, 5)
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

    func cancelPINFlow() {
        pollTask?.cancel()
        isPolling = false
        service.clearPINFlow()
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
        service.logout()
        isLoading = false
        isStatsLoading = false
        statusMessage = "Disconnected from Simkl."
        username = nil
        accountPlan = nil
        accountID = nil
        avatarURL = nil
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
        isLoading = true
        isStatsLoading = includeStats
        Task {
            _ = await service.refreshUserSettingsIfNeeded()
            if includeStats {
                connectedStats = await service.fetchUserStats()
                isStatsLoading = false
            }
            isLoading = false
            reload()
        }
    }

    func refreshNow() {
        guard mode == .connected, !isLoading,
              !isTransferringHistory, !isTransferringLibrary,
              !isTransferringProgress else { return }
        isLoading = true
        isStatsLoading = true
        statusMessage = "Syncing Simkl…"
        errorMessage = nil
        Task {
            _ = await service.fetchUserSettings()
            async let stats = service.fetchUserStats()
            let historySynced = await SimklHistoryService.syncWatchedHistory(
                store: store,
                force: true
            )
            _ = await SimklLibraryService.fetchLibrary(
                repository: CinemetaCatalogRepository(),
                store: store,
                force: true
            )
            connectedStats = await stats
            isStatsLoading = false
            isLoading = false
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

    private func startPolling() {
        pollTask?.cancel()
        isPolling = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
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
                if Task.isCancelled { return }

                switch await self.service.pollPINToken() {
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
}
