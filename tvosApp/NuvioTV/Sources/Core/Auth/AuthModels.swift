//
//  AuthModels.swift
//  NuvioTV
//
//  App auth state + Supabase wire models for the TV-login / email flows.
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

/// A persisted Supabase session (tokens + identity).
struct AuthSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var userId: String
    var email: String?
    /// Unix epoch seconds when the access token expires (best-effort).
    var expiresAt: TimeInterval?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince1970 >= expiresAt - 30
    }
}

// MARK: - Supabase wire models

/// GoTrue token/session response (sign-in, sign-up, anonymous, refresh).
struct SupabaseTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double?
    let expiresAt: Double?
    let user: SupabaseUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user
    }
}

struct SupabaseUser: Decodable {
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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = try c.decode(String.self, forKey: .code)
        webUrl = try c.decode(String.self, forKey: .webUrl)
        expiresAt = try c.decode(String.self, forKey: .expiresAt)
        pollIntervalSeconds = (try? c.decode(Int.self, forKey: .pollIntervalSeconds)) ?? 3
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
