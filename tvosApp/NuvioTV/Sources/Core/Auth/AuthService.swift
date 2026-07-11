//
//  AuthService.swift
//  NuvioTV
//
//  Thin Supabase REST client implementing the email + TV (QR) login flows
//  directly over URLSession — no Supabase SDK — mirroring Android's AuthManager.
//

import Foundation

struct AuthService {
    private let session: URLSession = .shared
    private let decoder = JSONDecoder()

    private var baseURL: String { AuthConfig.normalizedSupabaseURL }
    private var apiKey: String { AuthConfig.apiKey }

    // MARK: - Email auth

    /// POST /auth/v1/token?grant_type=password
    func signInWithEmail(email: String, password: String) async throws -> AuthSession {
        let token: SupabaseTokenResponse = try await request(
            path: "/auth/v1/token",
            query: ["grant_type": "password"],
            method: "POST",
            bearer: apiKey,
            json: ["email": email, "password": password]
        )
        return try authSession(from: token)
    }

    /// POST /auth/v1/signup
    func signUpWithEmail(email: String, password: String) async throws -> AuthSession {
        let token: SupabaseTokenResponse = try await request(
            path: "/auth/v1/signup",
            method: "POST",
            bearer: apiKey,
            json: ["email": email, "password": password]
        )
        return try authSession(from: token)
    }

    // MARK: - QR / TV login

    /// Anonymous GoTrue session used to authorize the TV-login RPCs.
    /// supabase-js posts `{ "data": {} }` to /signup for anonymous sign-in.
    func signInAnonymously() async throws -> AuthSession {
        let token: SupabaseTokenResponse = try await request(
            path: "/auth/v1/signup",
            method: "POST",
            bearer: apiKey,
            json: ["data": [String: String]()]
        )
        return try authSession(from: token)
    }

    /// POST /rest/v1/rpc/start_tv_login_session
    func startTvLoginSession(accessToken: String, deviceNonce: String, deviceName: String?) async throws -> TvLoginStartResult {
        var includeDeviceName = deviceName?.isEmpty == false
        do {
            return try await startTvLoginSessionRequest(
                accessToken: accessToken,
                deviceNonce: deviceNonce,
                deviceName: deviceName,
                redirectBaseURL: AuthConfig.tvLoginWebBaseURL,
                includeDeviceName: includeDeviceName
            )
        } catch {
            var lastError = error
            if includeDeviceName && shouldRetryWithoutDeviceName(error) {
                includeDeviceName = false
                do {
                    return try await startTvLoginSessionRequest(
                        accessToken: accessToken,
                        deviceNonce: deviceNonce,
                        deviceName: deviceName,
                        redirectBaseURL: AuthConfig.tvLoginWebBaseURL,
                        includeDeviceName: false
                    )
                } catch {
                    lastError = error
                }
            }

            guard shouldRetryLegacyRedirectBase(lastError),
                  AuthConfig.legacyTvLoginWebBaseURL != AuthConfig.tvLoginWebBaseURL else {
                throw lastError
            }

            do {
                return try await startTvLoginSessionRequest(
                    accessToken: accessToken,
                    deviceNonce: deviceNonce,
                    deviceName: deviceName,
                    redirectBaseURL: AuthConfig.legacyTvLoginWebBaseURL,
                    includeDeviceName: includeDeviceName
                )
            } catch {
                if includeDeviceName && shouldRetryWithoutDeviceName(error) {
                    return try await startTvLoginSessionRequest(
                        accessToken: accessToken,
                        deviceNonce: deviceNonce,
                        deviceName: deviceName,
                        redirectBaseURL: AuthConfig.legacyTvLoginWebBaseURL,
                        includeDeviceName: false
                    )
                }
                throw error
            }
        }
    }

    private func startTvLoginSessionRequest(
        accessToken: String,
        deviceNonce: String,
        deviceName: String?,
        redirectBaseURL: String,
        includeDeviceName: Bool
    ) async throws -> TvLoginStartResult {
        var body: [String: Any] = [
            "p_device_nonce": deviceNonce,
            "p_redirect_base_url": redirectBaseURL
        ]
        if includeDeviceName, let deviceName, !deviceName.isEmpty { body["p_device_name"] = deviceName }
        let rows: [TvLoginStartResult] = try await request(
            path: "/rest/v1/rpc/start_tv_login_session",
            method: "POST",
            bearer: accessToken,
            json: body
        )
        guard let first = rows.first else {
            throw AuthError(message: "Empty response from start_tv_login_session")
        }
        return first
    }

    /// POST /rest/v1/rpc/poll_tv_login_session
    func pollTvLoginSession(accessToken: String, code: String, deviceNonce: String) async throws -> TvLoginPollResult {
        let rows: [TvLoginPollResult] = try await request(
            path: "/rest/v1/rpc/poll_tv_login_session",
            method: "POST",
            bearer: accessToken,
            json: ["p_code": code, "p_device_nonce": deviceNonce]
        )
        guard let first = rows.first else {
            throw AuthError(message: "Empty response from poll_tv_login_session")
        }
        return first
    }

    /// POST /functions/v1/tv-logins-exchange — swaps the approved code for the
    /// real user session, then resolves the identity from the new token.
    func exchangeTvLoginSession(accessToken: String, code: String, deviceNonce: String) async throws -> AuthSession {
        let result: TvLoginExchangeResult = try await request(
            path: "/functions/v1/tv-logins-exchange",
            method: "POST",
            bearer: accessToken,
            json: ["code": code, "device_nonce": deviceNonce]
        )
        let user = try await getUser(accessToken: result.accessToken)
        let expiresAt = resolvedTokenExpiry(
            accessToken: result.accessToken,
            expiresAt: result.expiresAt,
            expiresIn: result.expiresIn
        )
        return AuthSession(
            accessToken: result.accessToken,
            refreshToken: result.refreshToken,
            userId: user.id,
            email: user.email,
            expiresAt: expiresAt
        )
    }

    /// POST /auth/v1/token?grant_type=refresh_token
    func refresh(refreshToken: String) async throws -> AuthSession {
        let token: SupabaseTokenResponse = try await request(
            path: "/auth/v1/token",
            query: ["grant_type": "refresh_token"],
            method: "POST",
            bearer: apiKey,
            json: ["refresh_token": refreshToken]
        )
        return try authSession(from: token)
    }

    /// GET /auth/v1/user
    func getUser(accessToken: String) async throws -> SupabaseUser {
        try await request(
            path: "/auth/v1/user",
            method: "GET",
            bearer: accessToken,
            json: nil
        )
    }

    /// POST /auth/v1/logout
    func signOut(accessToken: String) async throws {
        let _: EmptyResponse = try await request(
            path: "/auth/v1/logout",
            method: "POST",
            bearer: accessToken,
            json: [String: String]()
        )
    }

    // MARK: - Helpers

    private func authSession(from token: SupabaseTokenResponse) throws -> AuthSession {
        guard let user = token.user else {
            throw AuthError(message: "Missing user in auth response")
        }
        let expiresAt = resolvedTokenExpiry(
            accessToken: token.accessToken,
            expiresAt: token.expiresAt,
            expiresIn: token.expiresIn
        )
        return AuthSession(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            userId: user.id,
            email: user.email,
            expiresAt: expiresAt
        )
    }

    private func request<T: Decodable>(
        path: String,
        query: [String: String] = [:],
        method: String,
        bearer: String,
        json: [String: Any]?
    ) async throws -> T {
        guard AuthConfig.isConfigured else {
            throw AuthError(message: "Account backend is not configured. Add the Nuvio API URL and publishable key in AuthConfig.swift.")
        }
        guard var components = URLComponents(string: baseURL + path) else {
            throw AuthError(message: "Invalid backend URL")
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else {
            throw AuthError(message: "Invalid backend URL")
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError(message: "No response from server")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError(
                message: Self.serverErrorMessage(data: data, status: http.statusCode),
                statusCode: http.statusCode
            )
        }
        if data.isEmpty, T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AuthError(message: "Unexpected response from server")
        }
    }

    private static func serverErrorMessage(data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["error_description", "msg", "message", "error", "error_code"] {
                if let s = obj[key] as? String, !s.isEmpty { return s }
            }
        }
        return "Request failed (\(status))"
    }

    private func shouldRetryWithoutDeviceName(_ error: Error) -> Bool {
        let message = friendlyMessage(error).lowercased()
        return message.contains("p_device_name") &&
            message.contains("start_tv_login_session")
    }

    private func shouldRetryLegacyRedirectBase(_ error: Error) -> Bool {
        let message = friendlyMessage(error).lowercased()
        return message.contains("redirect") ||
            message.contains("base_url") ||
            message.contains("not allowed")
    }

    private func friendlyMessage(_ error: Error) -> String {
        (error as? AuthError)?.message ?? error.localizedDescription
    }
}

private struct EmptyResponse: Decodable {}

/// The JWT's signed `exp` claim is authoritative. Some TV exchange deployments
/// have returned `expires_at` in milliseconds or as a duration, both of which
/// made a fresh session appear immediately expired and forced a failing refresh.
private func resolvedTokenExpiry(
    accessToken: String,
    expiresAt: Double?,
    expiresIn: Double?
) -> TimeInterval? {
    if let jwt = jwtExpiry(accessToken) { return jwt }
    if let raw = expiresAt {
        if raw > 10_000_000_000 { return raw / 1000 }
        if raw > 1_000_000_000 { return raw }
        if raw > 0 { return Date().timeIntervalSince1970 + raw }
    }
    return expiresIn.map { Date().timeIntervalSince1970 + $0 }
}

/// Best-effort expiry extraction from a JWT's `exp` claim.
private func jwtExpiry(_ jwt: String) -> TimeInterval? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var payload = String(parts[1])
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 { payload.append("=") }
    guard let data = Data(base64Encoded: payload),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let exp = obj["exp"] as? Double else { return nil }
    return exp
}
