import Foundation
import Security
import SwiftUI

// MARK: - Configuration and transport

/// MDBList's public client id is not a secret. It identifies Nuvio's device
/// login flow; the user's access/refresh tokens remain profile-scoped secrets.
enum MdbListConfig {
    static let apiBaseURL = "https://api.mdblist.com"
    static let clientID = "kMMZyv8qithmUSF5102U6HTAPEDqfHtNbn1W4gkz"
    static let deviceAuthorizationPath = "/oauth/device-authorization/"
    static let tokenPath = "/oauth/token/"
    static let revokePath = "/oauth/revoke_token/"
    static let deviceLoginURL = "https://mdblist.com/oauth/device/"

    static var userAgent: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "NuvioTV/\(version)"
    }
}

enum MdbListHTTPMethod: String {
    case get = "GET"
    case post = "POST"
}

struct MdbListHTTPResponse {
    let statusCode: Int
    let data: Data
    let headers: [AnyHashable: Any]

    var errorMessage: String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["detail", "message", "error_description", "error", "msg"] {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}

enum MdbListServiceError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        }
    }
}

/// Small injectable HTTP client. MDBList's API key is intentionally encoded
/// as `?apikey=...`, matching the API contract; OAuth requests use Bearer auth.
final class MdbListAPIClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func request(
        path: String,
        method: MdbListHTTPMethod,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        form: [String: String]? = nil,
        accessToken: String? = nil,
        apiKey: String? = nil
    ) async throws -> MdbListHTTPResponse {
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard !normalizedPath.contains("?") && !normalizedPath.contains("#") else {
            throw MdbListServiceError.message("Invalid MDBList request path.")
        }
        guard var components = URLComponents(string: MdbListConfig.apiBaseURL + normalizedPath) else {
            throw MdbListServiceError.message("Invalid MDBList URL.")
        }
        var query = queryItems
        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            query.append(URLQueryItem(name: "apikey", value: apiKey))
        }
        components.queryItems = query
        guard let url = components.url else {
            throw MdbListServiceError.message("Invalid MDBList URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MdbListConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")

        if let accessToken = accessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let form {
            var formComponents = URLComponents()
            formComponents.queryItems = form
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formComponents.percentEncodedQuery?.data(using: .utf8)
        } else if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MdbListServiceError.message("Invalid MDBList response.")
        }
        return MdbListHTTPResponse(
            statusCode: http.statusCode,
            data: data,
            headers: http.allHeaderFields
        )
    }
}

// MARK: - Token storage

struct MdbListStoredTokens: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAtMillis: Double
}

protocol MdbListTokenStorage: AnyObject {
    func tokens(for profileScope: String) -> MdbListStoredTokens?
    func save(_ tokens: MdbListStoredTokens, for profileScope: String)
    func remove(for profileScope: String)
    func removeAll()
}

final class MdbListKeychainTokenStorage: MdbListTokenStorage {
    private static let service = "com.nuvio.tv.mdblist.auth"

    func tokens(for profileScope: String) -> MdbListStoredTokens? {
        var query = keychainQuery(for: profileScope)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(MdbListStoredTokens.self, from: data)
    }

    func save(_ tokens: MdbListStoredTokens, for profileScope: String) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        var addQuery = keychainQuery(for: profileScope)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = data
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            _ = SecItemUpdate(
                keychainQuery(for: profileScope) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
        }
    }

    func remove(for profileScope: String) {
        _ = SecItemDelete(keychainQuery(for: profileScope) as CFDictionary)
    }

    func removeAll() {
        _ = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service
        ] as CFDictionary)
    }

    private func keychainQuery(for profileScope: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: "tokens.\(profileScope)"
        ]
    }
}

final class MdbListMemoryTokenStorage: MdbListTokenStorage {
    private var values: [String: MdbListStoredTokens] = [:]

    func tokens(for profileScope: String) -> MdbListStoredTokens? { values[profileScope] }

    func save(_ tokens: MdbListStoredTokens, for profileScope: String) {
        values[profileScope] = tokens
    }

    func remove(for profileScope: String) {
        values.removeValue(forKey: profileScope)
    }

    func removeAll() {
        values.removeAll()
    }
}

// MARK: - Authentication state and store

enum MdbListConnectionMode {
    case disconnected
    case awaitingApproval
    case connected
}

struct MdbListAuthState: Equatable {
    let username: String?
    let displayName: String?
    let accountID: String?
    let userCode: String?
    let verificationURL: String?
    let expiresAtMillis: Double?
    let pollInterval: Int?
    let hasOAuthTokens: Bool

    var hasActiveDeviceFlow: Bool {
        guard let userCode, !userCode.isEmpty, let expiresAtMillis else { return false }
        return Date().timeIntervalSince1970 * 1_000 < expiresAtMillis
    }
}

enum MdbListAuthError: LocalizedError {
    case invalidResponse
    case authorizationPending
    case slowDown
    case accessDenied
    case expired
    case insufficientScope
    case revoked

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "MDBList returned an unexpected response. Try connecting again."
        case .authorizationPending:
            return "Waiting for MDBList approval…"
        case .slowDown:
            return "MDBList asked the Apple TV to slow down login polling."
        case .accessDenied:
            return "MDBList sign-in was declined."
        case .expired:
            return "The MDBList sign-in code expired. Connect again."
        case .insufficientScope:
            return "MDBList did not grant write access for playback syncing."
        case .revoked:
            return "MDBList authorization was revoked. Connect again."
        }
    }
}

enum MdbListAuthStore {
    static let changedNotification = Notification.Name("nuvio.tv.mdblist.auth.changed")

    private enum Key {
        static let username = "nuvio.tv.mdblist.auth.username"
        static let displayName = "nuvio.tv.mdblist.auth.displayName"
        static let accountID = "nuvio.tv.mdblist.auth.accountID"
        static let userCode = "nuvio.tv.mdblist.auth.userCode"
        static let verificationURL = "nuvio.tv.mdblist.auth.verificationURL"
        static let expiresAtMillis = "nuvio.tv.mdblist.auth.expiresAtMillis"
        static let pollInterval = "nuvio.tv.mdblist.auth.pollInterval"
        static let deviceCode = "nuvio.tv.mdblist.auth.deviceCode"
    }

    static func state(
        in defaults: UserDefaults,
        profileScope: String,
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage()
    ) -> MdbListAuthState {
        MdbListAuthState(
            username: defaults.string(forKey: Key.username),
            displayName: defaults.string(forKey: Key.displayName),
            accountID: defaults.string(forKey: Key.accountID),
            userCode: defaults.string(forKey: Key.userCode),
            verificationURL: defaults.string(forKey: Key.verificationURL),
            expiresAtMillis: defaults.object(forKey: Key.expiresAtMillis) == nil
                ? nil : defaults.double(forKey: Key.expiresAtMillis),
            pollInterval: defaults.object(forKey: Key.pollInterval) == nil
                ? nil : defaults.integer(forKey: Key.pollInterval),
            hasOAuthTokens: tokenStorage.tokens(for: profileScope) != nil
        )
    }

    static func saveDeviceFlow(
        deviceCode: String,
        userCode: String,
        verificationURL: String,
        expiresAtMillis: Double,
        pollInterval: Int,
        store defaults: UserDefaults
    ) {
        defaults.set(deviceCode, forKey: Key.deviceCode)
        defaults.set(userCode, forKey: Key.userCode)
        defaults.set(verificationURL, forKey: Key.verificationURL)
        defaults.set(expiresAtMillis, forKey: Key.expiresAtMillis)
        defaults.set(max(pollInterval, 1), forKey: Key.pollInterval)
    }

    static func deviceCode(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: Key.deviceCode)
    }

    static func updatePollInterval(_ seconds: Int, store defaults: UserDefaults) {
        defaults.set(min(max(seconds, 1), 3_600), forKey: Key.pollInterval)
    }

    static func saveTokens(
        _ tokens: MdbListStoredTokens,
        user: MdbListUser?,
        profileScope: String,
        store defaults: UserDefaults,
        tokenStorage: MdbListTokenStorage
    ) {
        tokenStorage.save(tokens, for: profileScope)
        saveUser(user, store: defaults)
        clearDeviceFlow(store: defaults)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    static func saveUser(_ user: MdbListUser?, store defaults: UserDefaults) {
        if let username = user?.username, !username.isEmpty {
            defaults.set(username, forKey: Key.username)
        } else {
            defaults.removeObject(forKey: Key.username)
        }
        if let displayName = user?.displayName, !displayName.isEmpty {
            defaults.set(displayName, forKey: Key.displayName)
        } else {
            defaults.removeObject(forKey: Key.displayName)
        }
        if let accountID = user?.accountID, !accountID.isEmpty {
            defaults.set(accountID, forKey: Key.accountID)
        } else {
            defaults.removeObject(forKey: Key.accountID)
        }
    }

    static func clearDeviceFlow(store defaults: UserDefaults) {
        [Key.deviceCode, Key.userCode, Key.verificationURL, Key.expiresAtMillis, Key.pollInterval]
            .forEach { defaults.removeObject(forKey: $0) }
    }

    static func clearAuth(
        profileScope: String,
        store defaults: UserDefaults,
        tokenStorage: MdbListTokenStorage,
        expectedAccessToken: String? = nil
    ) {
        if let expectedAccessToken,
           tokenStorage.tokens(for: profileScope)?.accessToken != expectedAccessToken {
            return
        }
        tokenStorage.remove(for: profileScope)
        [
            Key.username, Key.displayName, Key.accountID, Key.deviceCode, Key.userCode,
            Key.verificationURL, Key.expiresAtMillis, Key.pollInterval
        ].forEach { defaults.removeObject(forKey: $0) }
        NotificationCenter.default.post(name: changedNotification, object: nil)
        RemoteTrackingState.normalizeWatchProgressSource(in: defaults)
        RemoteTrackingState.normalizeLibrarySource(in: defaults)
    }
}

struct MdbListDeviceAuthorizationResponse: Equatable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let verificationURLComplete: String
    let expiresInSeconds: Int
    let intervalSeconds: Int
}

struct MdbListUser: Equatable {
    let accountID: String?
    let username: String?
    let displayName: String?
}

struct MdbListWatchStats: Equatable {
    let moviesWatched: Int?
    let showsWatched: Int?
    let episodesWatched: Int?
    let totalWatchedHours: Int?
}

enum MdbListDevicePollResult: Equatable {
    case pending
    case approved
    case expired
    case denied
    case rateLimited(Int)
    case failed(String)
}

// MARK: - Authentication service

/// Serializes refresh-token rotation across the short-lived service instances
/// created by playback and Home requests. MDBList may rotate refresh tokens;
/// two simultaneous refreshes must never overwrite each other or clear a newer
/// credential set.
private actor MdbListRefreshCoordinator {
    static let shared = MdbListRefreshCoordinator()

    private struct Entry {
        let generation: Int
        let task: Task<Bool, Never>
    }

    private var nextGeneration = 0
    private var entries: [String: Entry] = [:]

    func refresh(key: String, operation: @escaping () async -> Bool) async -> Bool {
        if let existing = entries[key] {
            return await existing.task.value
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        let task = Task { await operation() }
        entries[key] = Entry(generation: generation, task: task)

        let result = await task.value
        if entries[key]?.generation == generation {
            entries.removeValue(forKey: key)
        }
        return result
    }
}

final class MdbListAuthService {
    private let client: MdbListAPIClient
    private let store: UserDefaults
    private let profileScope: String
    private let tokenStorage: MdbListTokenStorage

    init(
        client: MdbListAPIClient = MdbListAPIClient(),
        store: UserDefaults = ProfileSettings.current,
        profileScope: String = ProfileSettings.activeProfileScope,
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage()
    ) {
        self.client = client
        self.store = store
        self.profileScope = profileScope.isEmpty ? "default" : profileScope
        self.tokenStorage = tokenStorage
    }

    func currentState() -> MdbListAuthState {
        MdbListAuthStore.state(in: store, profileScope: profileScope, tokenStorage: tokenStorage)
    }

    func hasOAuthAuthorization() -> Bool {
        currentState().hasOAuthTokens
    }

    func startDeviceAuthorization(
        shouldCommit: () -> Bool = { true }
    ) async throws -> MdbListDeviceAuthorizationResponse {
        let response = try await client.request(
            path: MdbListConfig.deviceAuthorizationPath,
            method: .post,
            form: ["client_id": MdbListConfig.clientID, "scope": "write"]
        )
        guard (200..<300).contains(response.statusCode),
              let object = try? jsonObject(response.data),
              let deviceCode = string(object["device_code"]),
              let userCode = string(object["user_code"]),
              let verificationURL = trustedVerificationURL(
                string(object["verification_uri"]) ?? MdbListConfig.deviceLoginURL
              ) else {
            throw MdbListServiceError.message(response.errorMessage ?? "Unable to start MDBList login.")
        }
        let expires = int(object["expires_in"]) ?? 600
        let interval = min(max(int(object["interval"]) ?? 5, 1), 3_600)
        let complete = trustedVerificationURL(
            string(object["verification_uri_complete"])
                ?? "\(verificationURL)?user_code=\(urlEncode(userCode))"
        ) ?? verificationURL
        let expiresAt = Date().timeIntervalSince1970 * 1_000 + Double(expires * 1_000)
        try Task.checkCancellation()
        guard shouldCommit() else { throw CancellationError() }
        MdbListAuthStore.saveDeviceFlow(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: complete,
            expiresAtMillis: expiresAt,
            pollInterval: interval,
            store: store
        )
        return MdbListDeviceAuthorizationResponse(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verificationURL,
            verificationURLComplete: complete,
            expiresInSeconds: expires,
            intervalSeconds: interval
        )
    }

    func pollDeviceAuthorization(
        shouldCommit: () -> Bool = { true }
    ) async -> MdbListDevicePollResult {
        guard let code = MdbListAuthStore.deviceCode(in: store), !code.isEmpty else {
            return .failed("No active MDBList login code.")
        }
        let state = currentState()
        if let expiresAt = state.expiresAtMillis,
           Date().timeIntervalSince1970 * 1_000 >= expiresAt {
            MdbListAuthStore.clearDeviceFlow(store: store)
            return .expired
        }

        do {
            let response = try await client.request(
                path: MdbListConfig.tokenPath,
                method: .post,
                form: [
                    "client_id": MdbListConfig.clientID,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": code,
                    "scope": "write"
                ]
            )
            try Task.checkCancellation()
            guard shouldCommit() else { return .pending }
            guard let object = try? jsonObject(response.data) else {
                return .failed(response.errorMessage ?? "MDBList returned invalid login data.")
            }
            if (200..<300).contains(response.statusCode) {
                guard let tokens = parseTokens(object),
                      tokens.scope?.contains("write") != false else {
                    return .failed(MdbListAuthError.insufficientScope.localizedDescription)
                }
                let user = await fetchUser(tokens: tokens.value)
                MdbListAuthStore.saveTokens(
                    tokens.value,
                    user: user,
                    profileScope: profileScope,
                    store: store,
                    tokenStorage: tokenStorage
                )
                await MdbListRatingsService.invalidate(store: store, profileScope: profileScope)
                TraktSettingsStore.selectWatchProgressSourceOnConnect(.mdblist, in: store)
                return .approved
            }

            switch string(object["error"])?.lowercased() {
            case "authorization_pending": return .pending
            case "slow_down":
                let next = min((state.pollInterval ?? 5) + 5, 60)
                MdbListAuthStore.updatePollInterval(next, store: store)
                return .rateLimited(next)
            case "access_denied":
                MdbListAuthStore.clearDeviceFlow(store: store)
                return .denied
            case "expired_token":
                MdbListAuthStore.clearDeviceFlow(store: store)
                return .expired
            default:
                return .failed(response.errorMessage ?? "MDBList login failed (HTTP \(response.statusCode)).")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func cancelDeviceAuthorization() {
        MdbListAuthStore.clearDeviceFlow(store: store)
    }

    /// Refreshes the bearer token when it is close to expiry. API-key-only
    /// profiles simply return false and continue through the API-key fallback.
    func refreshTokenIfNeeded(force: Bool = false) async -> Bool {
        await MdbListRefreshCoordinator.shared.refresh(
            key: "\(MdbListConfig.clientID):\(profileScope)"
        ) { [weak self] in
            guard let self else { return false }
            return await self.refreshTokenIfNeededUncoordinated(force: force)
        }
    }

    private func refreshTokenIfNeededUncoordinated(force: Bool) async -> Bool {
        guard let current = tokenStorage.tokens(for: profileScope) else { return false }
        let now = Date().timeIntervalSince1970 * 1_000
        guard force || current.expiresAtMillis - now <= 60_000 else { return true }

        do {
            let response = try await client.request(
                path: MdbListConfig.tokenPath,
                method: .post,
                form: [
                    "client_id": MdbListConfig.clientID,
                    "grant_type": "refresh_token",
                    "refresh_token": current.refreshToken
                ]
            )
            guard (200..<300).contains(response.statusCode),
                  let object = try? jsonObject(response.data),
                  let parsed = parseTokens(object, previousRefreshToken: current.refreshToken),
                  parsed.scope?.contains("write") != false else {
                if response.statusCode == 401 {
                    MdbListAuthStore.clearAuth(
                        profileScope: profileScope,
                        store: store,
                        tokenStorage: tokenStorage,
                        expectedAccessToken: current.accessToken
                    )
                }
                return false
            }
            // Another request may have completed a rotation while this request
            // was in flight. Keep the newer token set in that case.
            if tokenStorage.tokens(for: profileScope)?.accessToken != current.accessToken {
                return true
            }
            tokenStorage.save(parsed.value, for: profileScope)
            return true
        } catch {
            return false
        }
    }

    func fetchUser(tokens: MdbListStoredTokens? = nil) async -> MdbListUser? {
        let credentials = tokens ?? tokenStorage.tokens(for: profileScope)
        guard let credentials else { return nil }
        do {
            let response = try await client.request(
                path: "/user",
                method: .get,
                accessToken: credentials.accessToken
            )
            guard (200..<300).contains(response.statusCode),
                  let object = try? jsonObject(response.data) else { return nil }
            let user = MdbListUser(
                accountID: string(object["user_id"]) ?? string(object["id"]),
                username: string(object["username"]),
                displayName: string(object["name"]) ?? string(object["username"])
            )
            MdbListAuthStore.saveUser(user, store: store)
            return user
        } catch {
            return nil
        }
    }

    func fetchUserStats() async -> MdbListWatchStats? {
        do {
            let response = try await authorizedRequest(path: "/user/stats", method: .get)
            guard (200..<300).contains(response.statusCode) else { return nil }
            return MdbListWatchStats(data: response.data)
        } catch {
            return nil
        }
    }

    func authorizedRequest(
        path: String,
        method: MdbListHTTPMethod,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> MdbListHTTPResponse {
        if let current = tokenStorage.tokens(for: profileScope) {
            _ = await refreshTokenIfNeeded()
            let token = tokenStorage.tokens(for: profileScope)?.accessToken ?? current.accessToken
            var response = try await client.request(
                path: path,
                method: method,
                queryItems: queryItems,
                body: body,
                accessToken: token
            )
            if response.statusCode == 401,
               await refreshTokenIfNeeded(force: true),
               let refreshed = tokenStorage.tokens(for: profileScope) {
                response = try await client.request(
                    path: path,
                    method: method,
                    queryItems: queryItems,
                    body: body,
                    accessToken: refreshed.accessToken
                )
            }
            if response.statusCode == 401 {
                MdbListAuthStore.clearAuth(
                    profileScope: profileScope,
                    store: store,
                    tokenStorage: tokenStorage,
                    expectedAccessToken: token
                )
            }
            return response
        }

        let apiKey = store.string(forKey: SettingsKey.mdbListApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            throw MdbListServiceError.message("MDBList is not connected.")
        }
        return try await client.request(
            path: path,
            method: method,
            queryItems: queryItems,
            body: body,
            apiKey: apiKey
        )
    }

    func logout() {
        if let tokens = tokenStorage.tokens(for: profileScope) {
            Task {
                _ = try? await client.request(
                    path: MdbListConfig.revokePath,
                    method: .post,
                    form: [
                        "client_id": MdbListConfig.clientID,
                        "token": tokens.refreshToken,
                        "token_type_hint": "refresh_token"
                    ]
                )
            }
        }
        MdbListAuthStore.clearAuth(
            profileScope: profileScope,
            store: store,
            tokenStorage: tokenStorage
        )
        Task { @MainActor in
            MdbListRatingsService.invalidate(store: store, profileScope: profileScope)
        }
        if TraktSettingsStore.watchProgressSource(in: store) == .mdblist {
            store.set(TraktWatchProgressSource.nuvioSync.rawValue, forKey: SettingsKey.traktWatchProgressSource)
            NotificationCenter.default.post(
                name: TraktSettingsStore.continueWatchingChangedNotification,
                object: nil
            )
        }
        if TraktSettingsStore.librarySourceMode(in: store) == .mdblist {
            store.set(TraktLibrarySourceMode.local.rawValue, forKey: SettingsKey.traktLibrarySourceMode)
            NotificationCenter.default.post(
                name: TraktSettingsStore.libraryChangedNotification,
                object: nil
            )
        }
    }

    private func parseTokens(
        _ object: [String: Any],
        previousRefreshToken: String? = nil
    ) -> (value: MdbListStoredTokens, scope: Set<String>?)? {
        guard let access = string(object["access_token"]),
              let refresh = string(object["refresh_token"]) ?? previousRefreshToken,
              let expires = int(object["expires_in"]), expires > 0,
              string(object["token_type"])?.lowercased() == "bearer" else { return nil }
        let scopeValue = string(object["scope"])
        let scope = scopeValue.map {
            Set($0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init))
        }
        return (
            MdbListStoredTokens(
                accessToken: access,
                refreshToken: refresh,
                expiresAtMillis: Date().timeIntervalSince1970 * 1_000 + Double(expires * 1_000)
            ),
            scope
        )
    }

    private func trustedVerificationURL(_ value: String) -> String? {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "mdblist.com" || host == "www.mdblist.com",
              url.user == nil,
              url.password == nil else { return nil }
        return url.absoluteString
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MdbListServiceError.message("MDBList returned invalid JSON.")
        }
        return object
    }

    private func string(_ value: Any?) -> String? {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func int(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }
}

private extension MdbListWatchStats {
    init?(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let generalContainers = Self.containers(
            from: root,
            keys: ["data", "stats", "summary", "totals", "watched", "watch_stats", "watchStats"]
        )
        let movieContainers = Self.nestedContainers(
            in: generalContainers,
            keys: ["movies", "movie", "movie_stats", "movieStats"]
        )
        let showContainers = Self.nestedContainers(
            in: generalContainers,
            keys: ["shows", "show", "show_stats", "showStats"]
        )
        let episodeContainers = Self.nestedContainers(
            in: generalContainers,
            keys: ["episodes", "episode", "episode_stats", "episodeStats"]
        )

        let movies = Self.firstInteger(
            in: generalContainers,
            keys: [
                "movies", "movie_count", "movies_count", "movies_watched",
                "watched_movies", "movieCount", "moviesCount", "moviesWatched",
                "tv_movies", "tvMovies"
            ]
        ) ?? Self.firstInteger(in: movieContainers, keys: ["watched", "count", "total", "value", "items"])
        let shows = Self.firstInteger(
            in: generalContainers,
            keys: [
                "shows", "show_count", "shows_count", "shows_watched",
                "watched_shows", "showCount", "showsCount", "showsWatched",
                "tv_shows", "tvShows", "series", "series_watched"
            ]
        ) ?? Self.firstInteger(in: showContainers, keys: ["watched", "count", "total", "value", "items"])
        let episodes = Self.firstInteger(
            in: generalContainers,
            keys: [
                "episodes", "episode_count", "episodes_count", "episodes_watched",
                "watched_episodes", "episodeCount", "episodesCount", "episodesWatched",
                "tv_episodes", "tvEpisodes"
            ]
        ) ?? Self.firstInteger(in: episodeContainers, keys: ["watched", "count", "total", "value", "items"])

        let directHours = Self.firstInteger(
            in: generalContainers,
            keys: [
                "hours", "watched_hours", "total_hours", "watch_hours",
                "total_watched_hours", "totalWatchedHours", "watchHours",
                "time_watched_hours", "timeWatchedHours"
            ]
        ) ?? Self.firstInteger(in: [root], keys: ["hours"])
        let minutes = Self.firstInteger(
            in: generalContainers,
            keys: [
                "minutes", "watched_minutes", "total_minutes", "watch_minutes",
                "watch_time_minutes", "total_watched_minutes", "totalWatchedMinutes",
                "total_watch_time_minutes", "watchTimeMinutes", "runtime_minutes"
            ]
        )
        let seconds = Self.firstInteger(
            in: generalContainers,
            keys: [
                "seconds", "watched_seconds", "total_seconds", "watch_time_seconds",
                "total_watch_time_seconds", "watchTimeSeconds"
            ]
        )
        var hours = directHours
        if hours == nil, let minutes {
            hours = minutes / 60
        }
        if hours == nil, let seconds {
            hours = seconds / 3_600
        }

        guard movies != nil || shows != nil || episodes != nil || hours != nil else {
            return nil
        }
        self.init(
            moviesWatched: movies,
            showsWatched: shows,
            episodesWatched: episodes,
            totalWatchedHours: hours
        )
    }

    static func containers(from root: [String: Any], keys: [String]) -> [[String: Any]] {
        var result = [root]
        for key in keys {
            if let object = root[key] as? [String: Any] {
                result.append(object)
            }
        }
        return result
    }

    static func nestedContainers(in roots: [[String: Any]], keys: [String]) -> [[String: Any]] {
        var result = roots
        for root in roots {
            for key in keys {
                if let object = root[key] as? [String: Any] {
                    result.append(object)
                }
            }
        }
        return result
    }

    static func firstInteger(in containers: [[String: Any]], keys: [String]) -> Int? {
        for container in containers {
            for key in keys {
                if let number = integer(container[key]) {
                    return number
                }
            }
        }
        return nil
    }

    static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? Double, value.isFinite { return Int(value.rounded()) }
        if let value = value as? String {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

enum MdbListRuntimeSession {
    static func profileScope() -> String {
        let value = ProfileSettings.activeProfileScope.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "default" : value
    }

    static func isAuthenticated(
        in store: UserDefaults = ProfileSettings.current,
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        profileScope: String? = nil
    ) -> Bool {
        let scope = profileScope ?? self.profileScope()
        if MdbListAuthStore.state(in: store, profileScope: scope, tokenStorage: tokenStorage).hasOAuthTokens {
            return true
        }
        return !(store.string(forKey: SettingsKey.mdbListApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }
}

// MARK: - Settings view model

@MainActor
final class MdbListSettingsViewModel: ObservableObject {
    @Published private(set) var mode: MdbListConnectionMode = .disconnected
    @Published private(set) var username: String?
    @Published private(set) var displayName: String?
    @Published private(set) var accountID: String?
    @Published private(set) var deviceUserCode: String?
    @Published private(set) var verificationURL: String?
    @Published private(set) var expiresAtMillis: Double?
    @Published private(set) var pollInterval = 5
    @Published private(set) var isPolling = false
    @Published private(set) var isLoading = false
    @Published private(set) var isStatsLoading = false
    @Published private(set) var connectedStats: MdbListWatchStats?
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let store: UserDefaults
    private let profileScope: String
    private let tokenStorage: MdbListTokenStorage
    private let service: MdbListAuthService
    private var pollTask: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?
    private var authorizationGeneration = 0

    init(
        store: UserDefaults = ProfileSettings.current,
        profileScope: String = ProfileSettings.activeProfileScope,
        tokenStorage: MdbListTokenStorage = MdbListKeychainTokenStorage(),
        service: MdbListAuthService? = nil
    ) {
        self.store = store
        self.profileScope = profileScope.isEmpty ? "default" : profileScope
        self.tokenStorage = tokenStorage
        self.service = service ?? MdbListAuthService(
            store: store,
            profileScope: self.profileScope,
            tokenStorage: tokenStorage
        )
        reload()
    }

    deinit {
        pollTask?.cancel()
        authorizationTask?.cancel()
    }

    var hasAPIKey: Bool {
        !(store.string(forKey: SettingsKey.mdbListApiKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }

    func reload() {
        let state = service.currentState()
        let hasActiveDeviceFlow = state.hasActiveDeviceFlow
        if !hasActiveDeviceFlow && !state.hasOAuthTokens && state.userCode != nil {
            MdbListAuthStore.clearDeviceFlow(store: store)
        }
        username = state.username
        displayName = state.displayName ?? state.username
        accountID = state.accountID
        deviceUserCode = hasActiveDeviceFlow ? state.userCode : nil
        verificationURL = hasActiveDeviceFlow ? state.verificationURL : nil
        expiresAtMillis = hasActiveDeviceFlow ? state.expiresAtMillis : nil
        pollInterval = state.pollInterval ?? 5
        mode = state.hasOAuthTokens ? .connected : (hasActiveDeviceFlow ? .awaitingApproval : .disconnected)
        if mode == .awaitingApproval {
            startPolling(generation: authorizationGeneration)
        } else {
            pollTask?.cancel()
            isPolling = false
        }
    }

    func connect() {
        guard !isLoading else { return }
        authorizationTask?.cancel()
        authorizationGeneration &+= 1
        let generation = authorizationGeneration
        isLoading = true
        errorMessage = nil
        statusMessage = "Starting MDBList login…"
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await service.startDeviceAuthorization { [weak self] in
                    self?.authorizationGeneration == generation
                }
                guard !Task.isCancelled, self.authorizationGeneration == generation else { return }
                deviceUserCode = response.userCode
                verificationURL = response.verificationURLComplete
                expiresAtMillis = Date().timeIntervalSince1970 * 1_000 + Double(response.expiresInSeconds * 1_000)
                pollInterval = response.intervalSeconds
                mode = .awaitingApproval
                isLoading = false
                statusMessage = "Waiting for approval…"
                startPolling(generation: generation)
            } catch {
                guard !Task.isCancelled, self.authorizationGeneration == generation else { return }
                isLoading = false
                errorMessage = error.localizedDescription
                statusMessage = nil
            }
        }
    }

    func cancelLogin() {
        authorizationGeneration &+= 1
        authorizationTask?.cancel()
        authorizationTask = nil
        pollTask?.cancel()
        pollTask = nil
        service.cancelDeviceAuthorization()
        isLoading = false
        isPolling = false
        statusMessage = nil
        errorMessage = nil
        reload()
    }

    func disconnect() {
        authorizationGeneration &+= 1
        authorizationTask?.cancel()
        authorizationTask = nil
        pollTask?.cancel()
        pollTask = nil
        isLoading = true
        service.logout()
        isLoading = false
        isStatsLoading = false
        connectedStats = nil
        displayName = nil
        statusMessage = "Disconnected from MDBList."
        errorMessage = nil
        reload()
    }

    func loadConnectedData() {
        guard mode == .connected, !isLoading, !isStatsLoading else { return }
        isStatsLoading = true
        Task {
            _ = await service.refreshTokenIfNeeded()
            _ = await service.fetchUser()
            if let stats = await service.fetchUserStats() {
                connectedStats = stats
            }
            isStatsLoading = false
            reload()
        }
    }

    func refreshNow() {
        guard mode == .connected, !isLoading, !isStatsLoading else { return }
        isLoading = true
        isStatsLoading = true
        statusMessage = "Syncing MDBList..."
        errorMessage = nil
        Task {
            _ = await service.refreshTokenIfNeeded()
            _ = await service.fetchUser()

            let shouldSyncHistory = TraktSettingsStore.watchProgressSource(in: store) == .mdblist
            let historySynced = shouldSyncHistory
                ? await MdbListProgressService.syncWatchedHistory(
                    store: store,
                    tokenStorage: tokenStorage,
                    profileScope: profileScope
                )
                : true
            if let stats = await service.fetchUserStats() {
                connectedStats = stats
            }

            isStatsLoading = false
            isLoading = false
            statusMessage = historySynced
                ? "MDBList sync completed."
                : "MDBList account refreshed, but watched history could not be imported."
            reload()
        }
    }

    private func startPolling(generation: Int) {
        pollTask?.cancel()
        isPolling = true
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let seconds = max(self.pollInterval, 1)
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                } catch {
                    return
                }
                let result = await self.service.pollDeviceAuthorization { [weak self] in
                    self?.authorizationGeneration == generation
                }
                guard !Task.isCancelled else { return }
                switch result {
                case .pending:
                    await MainActor.run { self.statusMessage = "Waiting for approval…" }
                case .rateLimited(let next):
                    await MainActor.run {
                        self.pollInterval = next
                        self.statusMessage = "Waiting for approval…"
                    }
                case .approved:
                    await MainActor.run {
                        self.isPolling = false
                        self.statusMessage = "MDBList connected."
                        self.reload()
                    }
                    return
                case .expired:
                    await MainActor.run {
                        self.isPolling = false
                        self.errorMessage = "The MDBList sign-in code expired. Connect again."
                        self.reload()
                    }
                    return
                case .denied:
                    await MainActor.run {
                        self.isPolling = false
                        self.errorMessage = "MDBList sign-in was declined."
                        self.reload()
                    }
                    return
                case .failed(let message):
                    await MainActor.run {
                        self.isPolling = false
                        self.errorMessage = message
                        self.reload()
                    }
                    return
                }
            }
        }
    }
}
