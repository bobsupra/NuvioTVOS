import Foundation
import SMBClient

/// Authentication strategy for an SMB session, as exposed to a host app's
/// server-configuration UI: no account, an explicit guest account, or
/// credentials. Distinct from the credential-less URL path (`SMBURL` /
/// `SMBConnection.connect(user:password:domain:)`), which infers "no account"
/// from an empty username and drives its own guest-then-anonymous fallback —
/// see `SMBAuth.loginCredentialLess` below.
public enum SMBAuthMode: Sendable, Equatable {
    case anonymous
    case guest
    case user(name: String, password: String, domain: String = "")
}

/// The login arguments for one attempt, decoupled from the network call so
/// the mode → arguments mapping is unit-testable without a live server.
struct SMBLoginAttempt: Equatable {
    let username: String?
    let password: String?
    let domain: String?
}

enum SMBAuth {
    /// The single login attempt for an explicit auth mode. No automatic
    /// fallback: the user picked this mode in Settings, so a rejected guest
    /// or bad password should surface as a real error, not silently
    /// downgrade to a different account.
    static func attempt(for mode: SMBAuthMode) -> SMBLoginAttempt {
        switch mode {
        case .anonymous:
            return SMBLoginAttempt(username: nil, password: nil, domain: nil)
        case .guest:
            return SMBLoginAttempt(username: "guest", password: nil, domain: nil)
        case .user(let name, let password, let domain):
            return SMBLoginAttempt(
                username: name,
                password: password.isEmpty ? nil : password,
                domain: domain.isEmpty ? nil : domain
            )
        }
    }

    static func login(_ client: SMBClient, mode: SMBAuthMode) async throws {
        let attempt = attempt(for: mode)
        try await client.login(username: attempt.username, password: attempt.password, domain: attempt.domain)
    }

    /// Credential-less connect used by `SMBConnection.connect`: an empty
    /// username means "no explicit account" (see `SMBURL`, which leaves an
    /// omitted user empty rather than substituting "guest"). Tries guest
    /// first, then falls back to a fully anonymous NTLM session if the server
    /// rejects guest. An explicit username never falls back — that failure is
    /// a real auth error and must propagate.
    static func loginCredentialLess(
        _ client: SMBClient,
        user: String,
        password: String,
        domain: String
    ) async throws {
        let account = user.isEmpty ? nil : user
        let secret = password.isEmpty ? nil : password
        let realm = domain.isEmpty ? nil : domain
        do {
            try await client.login(username: account ?? "guest", password: secret, domain: realm)
        } catch where account == nil {
            try await client.login(username: nil, password: nil)
        }
    }
}
