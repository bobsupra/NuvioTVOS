//
//  AuthManager.swift
//  NuvioTV
//
//  Observable orchestrator for the account system: global auth state, session
//  persistence, email sign-in/up, and the QR (TV) login start/poll/exchange
//  loop. Mirrors the Android AccountViewModel + AuthManager split.
//

import SwiftUI
import UIKit
import Security

@MainActor
final class AuthManager: ObservableObject {
    // Global auth state.
    @Published private(set) var authState: AuthState = .loading

    // QR login UI state.
    @Published var qrImage: UIImage?
    @Published var qrCode: String?
    @Published var qrStatusMessage: String?
    @Published var qrExpiresAt: Date?

    // Shared.
    @Published var isBusy = false
    @Published var errorMessage: String?

    private let service = AuthService()
    private let store = SessionStore()
    /// Authoritative for the current process. Persistence is a restore aid, not
    /// a prerequisite for using a session that just authenticated successfully.
    private var currentSession: AuthSession?

    private var qrNonce: String?
    private var qrAnonAccessToken: String?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<AuthSession?, Never>?

    var isAuthenticated: Bool { authState.isAuthenticated }
    var isBackendConfigured: Bool { AuthConfig.isConfigured }

    var currentEmail: String? {
        if case let .fullAccount(_, email) = authState { return email }
        return nil
    }

    /// Whether the login gate should be shown on launch (not signed in and the
    /// user hasn't previously chosen to continue without an account).
    var shouldShowLoginGate: Bool {
        !isAuthenticated && !store.didSkipLogin
    }

    /// Present in UserDefaults for as long as this install exists. UserDefaults
    /// dies with an app deletion but the Keychain does not, so a missing marker
    /// means a fresh install carrying a previous install's session.
    private static let installMarkerKey = "nuvio.auth.installMarker"

    init() {
        clearLeftoverSessionOnFreshInstall()
        restoreSession()
    }

    /// Deleting the app must mean a clean slate: without this, a reinstall
    /// restores the old account from the surviving Keychain item while every
    /// bit of local state (profiles, add-ons, watch data) is gone — a
    /// half-signed-in limbo. First launch of a fresh install drops any
    /// leftover session so the login gate shows.
    private func clearLeftoverSessionOnFreshInstall() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.installMarkerKey) else { return }
        defaults.set(true, forKey: Self.installMarkerKey)
        store.clear()
        store.didSkipLogin = false
    }

    // MARK: - Session restore / persistence

    private func restoreSession() {
        guard let session = store.load() else {
            currentSession = nil
            authState = .signedOut
            return
        }
        currentSession = session
        authState = .fullAccount(userId: session.userId, email: session.email ?? "")
        if session.isExpired {
            Task { _ = await self.refreshSessionForSync() }
        }
    }

    func currentSessionForSync() -> AuthSession? {
        if let currentSession { return currentSession }
        let restored = store.load()
        currentSession = restored
        return restored
    }

    func validSessionForSync(validateWithServer: Bool = false) async -> AuthSession? {
        guard let session = currentSessionForSync() else { return nil }
        var candidate = session
        var attemptedRefresh = false
        if session.isExpired {
            attemptedRefresh = true
            // A malformed/stale local expiry must not discard an access token
            // that the server still accepts. Prefer a refresh, but validate the
            // existing token below when refreshing is temporarily unavailable.
            if let refreshed = await refreshSessionForSync() {
                candidate = refreshed
            }
        }
        guard validateWithServer else { return candidate }

        do {
            _ = try await service.getUser(accessToken: candidate.accessToken)
            return candidate
        } catch let error as AuthError where error.statusCode == 401 {
            // The server is authoritative. A token can be revoked/rejected
            // before its locally stored expiry, so refresh once on a real 401.
            guard !attemptedRefresh else { return nil }
            return await refreshSessionForSync()
        } catch {
            // A transient validation outage should not discard a locally valid
            // session; the sync request will surface its own network failure.
            return candidate
        }
    }

    func refreshSessionForSync() async -> AuthSession? {
        if let refreshTask {
            guard let refreshed = await refreshTask.value, isAuthenticated else { return nil }
            if currentSession?.refreshToken != refreshed.refreshToken {
                apply(session: refreshed)
            }
            return refreshed
        }

        guard let session = currentSessionForSync() else { return nil }
        let task = Task { [service] in
            try? await service.refresh(refreshToken: session.refreshToken)
        }
        refreshTask = task
        guard let refreshed = await task.value else {
            refreshTask = nil
            return nil
        }
        refreshTask = nil
        // Never resurrect a session after sign-out while refresh was in flight.
        guard isAuthenticated,
              currentSession?.refreshToken == session.refreshToken else { return nil }
        apply(session: refreshed)
        return refreshed
    }

    private func apply(session: AuthSession) {
        currentSession = session
        if !store.save(session) {
            // Do not strand a successful login on Home just because secure
            // persistence is unavailable in this simulator/install. The live
            // in-memory session remains valid for all sync requests.
            print("Nuvio session is active, but secure persistence failed.")
        }
        authState = .fullAccount(userId: session.userId, email: session.email ?? "")
    }

    // MARK: - Skip / sign out

    func skipLogin() {
        store.didSkipLogin = true
    }

    func requireLogin() {
        store.didSkipLogin = false
        if !isAuthenticated {
            authState = .signedOut
        }
    }

    func signOut() {
        pollTask?.cancel()
        let session = currentSession ?? store.load()
        currentSession = nil
        store.clear()
        store.didSkipLogin = false
        clearQrState()
        authState = .signedOut
        Task {
            if let accessToken = session?.accessToken {
                try? await service.signOut(accessToken: accessToken)
            }
        }
    }

    // MARK: - Email

    func signIn(email: String, password: String) async {
        await runEmail { try await self.service.signInWithEmail(email: email, password: password) }
    }

    func signUp(email: String, password: String) async {
        await runEmail { try await self.service.signUpWithEmail(email: email, password: password) }
    }

    private func runEmail(_ op: @escaping () async throws -> AuthSession) async {
        guard ensureConfigured() else { return }
        isBusy = true
        errorMessage = nil
        do {
            apply(session: try await op())
        } catch {
            errorMessage = friendly(error)
        }
        isBusy = false
    }

    // MARK: - QR login

    func startQrLogin(force: Bool = false) {
        guard ensureConfigured() else { return }

        // Reuse the current pending session when possible: every fresh start
        // consumes an anonymous sign-in plus a TV-login session server-side,
        // and both are rate-limited. Re-entering the screen or toggling
        // QR/Email must not mint new sessions while one is still valid;
        // only the explicit Refresh QR button forces a new one.
        if !force,
           let expires = qrExpiresAt, expires.timeIntervalSinceNow > 30,
           qrCode != nil, qrNonce != nil, qrAnonAccessToken != nil, qrImage != nil {
            qrStatusMessage = "Waiting for approval on your phone…"
            startPolling(intervalSeconds: 2)
            return
        }

        pollTask?.cancel()
        clearQrState()
        isBusy = true
        errorMessage = nil
        qrStatusMessage = "Preparing QR login…"

        let nonce = Self.makeNonce()
        qrNonce = nonce

        Task {
            do {
                let anon = try await service.signInAnonymously()
                qrAnonAccessToken = anon.accessToken
                let start = try await service.startTvLoginSession(
                    accessToken: anon.accessToken,
                    deviceNonce: nonce,
                    deviceName: Self.deviceName
                )
                qrCode = start.code
                qrImage = QRCode.image(from: start.webUrl)
                qrExpiresAt = Self.parseDate(start.expiresAt)
                qrStatusMessage = "Scan QR, approve in browser, then return here."
                isBusy = false
                startPolling(intervalSeconds: max(start.pollIntervalSeconds, 2))
            } catch {
                errorMessage = friendly(error)
                qrStatusMessage = "Failed to start QR login"
                isBusy = false
            }
        }
    }

    func stopQrLogin() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func startPolling(intervalSeconds: Int) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var interval = intervalSeconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                interval = await self.pollOnce(currentInterval: interval)
            }
        }
    }

    /// Runs a single poll; returns the (possibly updated) poll interval.
    private func pollOnce(currentInterval: Int) async -> Int {
        guard let code = qrCode, let nonce = qrNonce, let anon = qrAnonAccessToken else {
            return currentInterval
        }
        do {
            let result = try await service.pollTvLoginSession(accessToken: anon, code: code, deviceNonce: nonce)
            var interval = currentInterval
            if let secs = result.pollIntervalSeconds { interval = max(secs, 2) }
            if let exp = result.expiresAt.flatMap(Self.parseDate) { qrExpiresAt = exp }

            switch result.status.lowercased() {
            case "approved":
                qrStatusMessage = "Login approved. Finishing sign in…"
                await exchange(code: code, nonce: nonce, anon: anon)
                pollTask?.cancel()
                pollTask = nil
            case "pending":
                qrStatusMessage = "Waiting for approval on your phone…"
            case "expired", "used", "cancelled":
                qrStatusMessage = "QR login expired. Generate a new code."
                // Dead session: drop the expiry so the reuse path in
                // startQrLogin() can't resurrect it.
                qrExpiresAt = nil
                pollTask?.cancel()
                pollTask = nil
            default:
                qrStatusMessage = "Status: \(result.status)"
            }
            return interval
        } catch {
            errorMessage = friendly(error)
            return currentInterval
        }
    }

    private func exchange(code: String, nonce: String, anon: String) async {
        isBusy = true
        do {
            let session = try await service.exchangeTvLoginSession(accessToken: anon, code: code, deviceNonce: nonce)
            apply(session: session)
            qrStatusMessage = "Signed in successfully"
            clearQrState()
        } catch {
            errorMessage = friendly(error)
            qrStatusMessage = "Could not complete QR sign in"
        }
        isBusy = false
    }

    private func clearQrState() {
        qrImage = nil
        qrCode = nil
        qrExpiresAt = nil
        qrNonce = nil
        qrAnonAccessToken = nil
    }

    // MARK: - Helpers

    @discardableResult
    private func ensureConfigured() -> Bool {
        if AuthConfig.isConfigured { return true }
        errorMessage = "Account backend isn't configured yet. Add the Nuvio API URL and publishable key in AuthConfig.swift."
        return false
    }

    private func friendly(_ error: Error) -> String {
        (error as? AuthError)?.message ?? error.localizedDescription
    }

    private static var deviceName: String {
        UIDevice.current.name
    }

    private static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}

/// Keychain-backed session persistence. The old UserDefaults key is migrated
/// once so existing installs do not lose a session when upgrading.
struct SessionStore {
    private let legacySessionKey = "nuvio.auth.session"
    private let skipKey = "nuvio.auth.skippedLogin"
    private let keychainService = "com.nuvio.app.tv.auth"
    private let keychainAccount = "session"
    private let defaults = UserDefaults.standard

    func load() -> AuthSession? {
        if let data = loadKeychainData(),
           let session = try? JSONDecoder().decode(AuthSession.self, from: data) {
            return session
        }
        return migrateLegacySession()
    }

    @discardableResult
    func save(_ session: AuthSession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        let saved = saveKeychainData(data)
        didSkipLogin = false
        return saved
    }

    func clear() {
        deleteKeychainData()
        defaults.removeObject(forKey: legacySessionKey)
    }

    var didSkipLogin: Bool {
        get { defaults.bool(forKey: skipKey) }
        nonmutating set { defaults.set(newValue, forKey: skipKey) }
    }

    private func migrateLegacySession() -> AuthSession? {
        guard let data = defaults.data(forKey: legacySessionKey),
              let session = try? JSONDecoder().decode(AuthSession.self, from: data) else {
            return nil
        }
        if saveKeychainData(data) {
            defaults.removeObject(forKey: legacySessionKey)
        }
        return session
    }

    private var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    private func loadKeychainData() -> Data? {
        var query = keychainQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private func saveKeychainData(_ data: Data) -> Bool {
        var addQuery = keychainQuery
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        addQuery[kSecValueData as String] = data

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            return SecItemUpdate(
                keychainQuery as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            ) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private func deleteKeychainData() {
        SecItemDelete(keychainQuery as CFDictionary)
    }
}
