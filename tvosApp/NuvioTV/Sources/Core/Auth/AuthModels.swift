//
//  AuthModels.swift
//  NuvioTV
//
//  App auth state + Nuvio API wire models for the TV-login / email flows.
//

import Foundation

/// App-level authentication state, mirroring Android's `AuthState`.
enum AuthState: Equatable {
    case loading
    case signedOut
    case fullAccount(userId: String, email: String)

    var isAuthenticated: Bool {
        if case .fullAccount = self { return true }
        return false
    }
}

/// A persisted Nuvio account session (tokens + identity).
struct AuthSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var userId: String
    var email: String?
    /// Unix epoch seconds when the access token expires (best-effort).
    var expiresAt: TimeInterval?
    var backendIdentity: String? = nil

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince1970 >= expiresAt - 30
    }
}

// MARK: - Nuvio API wire models

/// GoTrue token/session response (sign-in, sign-up, anonymous, refresh).
struct NuvioTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double?
    let expiresAt: Double?
    let user: NuvioUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user
    }
}

struct NuvioUser: Decodable {
    let id: String
    let email: String?
}

/// One row from the `start_tv_login_session` RPC.
struct TvLoginStartResult: Decodable {
    let code: String
    let webUrl: String
    let expiresAt: String
    let pollIntervalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case code
        case webUrl = "web_url"
        case expiresAt = "expires_at"
        case pollIntervalSeconds = "poll_interval_seconds"
    }

    init(code: String, webUrl: String, expiresAt: String, pollIntervalSeconds: Int = 3) {
        self.code = code
        self.webUrl = Self.sanitizeWebURL(webUrl, code: code)
        self.expiresAt = expiresAt
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCode = try c.decode(String.self, forKey: .code)
        let rawWebUrl = try c.decode(String.self, forKey: .webUrl)
        code = decodedCode
        webUrl = Self.sanitizeWebURL(rawWebUrl, code: decodedCode)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        pollIntervalSeconds = (try? c.decode(Int.self, forKey: .pollIntervalSeconds)) ?? 3
    }

    static func sanitizeWebURL(_ raw: String, code: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "\(AuthConfig.tvLoginWebBaseURL)?code=\(code)"
        }
        if trimmed.contains("api.nuvio.tv") {
            return trimmed.replacingOccurrences(of: "api.nuvio.tv", with: "nuvio.tv")
        }
        return trimmed
    }
}

/// One row from the `start_device_login_session` RPC: a short code the user
/// can type at `verification_uri`, and the device code the TV polls with.
struct DeviceLoginStartResult: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: String
    let verificationURIComplete: String
    let expiresAt: String
    let pollIntervalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresAt = "expires_at"
        case pollIntervalSeconds = "poll_interval_seconds"
    }

    init(
        deviceCode: String,
        userCode: String,
        verificationURI: String,
        verificationURIComplete: String,
        expiresAt: String,
        pollIntervalSeconds: Int = 3
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.verificationURIComplete = verificationURIComplete
        self.expiresAt = expiresAt
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceCode = try c.decode(String.self, forKey: .deviceCode)
        userCode = try c.decode(String.self, forKey: .userCode)
        verificationURI = try c.decode(String.self, forKey: .verificationURI)
        verificationURIComplete = try c.decode(String.self, forKey: .verificationURIComplete)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        pollIntervalSeconds = (try? c.decode(Int.self, forKey: .pollIntervalSeconds)) ?? 3
    }

    /// Every field the sign-in screen needs is there.
    var isComplete: Bool {
        !deviceCode.isEmpty && !userCode.isEmpty && !verificationURIComplete.isEmpty
    }
}

/// One row from the `poll_tv_login_session` RPC.
struct TvLoginPollResult: Decodable {
    let status: String
    let expiresAt: String?
    let pollIntervalSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case status
        case expiresAt = "expires_at"
        case pollIntervalSeconds = "poll_interval_seconds"
    }
}

/// Response from the `tv-logins-exchange` edge function.
struct TvLoginExchangeResult: Decodable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String?
    let expiresIn: Double?
    let expiresAt: Double?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
    }
}

/// A user-facing error message surfaced by the auth layer.
struct AuthError: LocalizedError {
    let message: String
    let statusCode: Int?

    init(message: String, statusCode: Int? = nil) {
        self.message = message
        self.statusCode = statusCode
    }

    var errorDescription: String? { message }
}
