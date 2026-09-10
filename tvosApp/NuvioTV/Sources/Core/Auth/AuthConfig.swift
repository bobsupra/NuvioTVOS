//
//  AuthConfig.swift
//  NuvioTV
//
//  Backend credentials for the Nuvio account API.
//

import Foundation

/// Nuvio account API credentials for the account / TV-login system.
enum AuthConfig {
    static let officialAPIBaseURL = "https://api.nuvio.tv"

    /// Public publishable key from the Nuvio Public API docs.
    static let officialPublishableKey = "sb_publishable_1Clq8rlTVACkdcZuqr6_AD__xUUC_EN"

    private static var active: ServerConfiguration? { ServerConfigurationStore().configuration }
    static var currentConfiguration: ServerConfiguration {
        active ?? ServerConfiguration(
            backendURL: officialAPIBaseURL,
            publishableKey: officialPublishableKey,
            capabilities: ServerCapabilities(emailPasswordAuth: true, tvLogin: true),
            discoveryURL: nil
        )
    }
    static var apiBaseURL: String { currentConfiguration.normalizedBackendURL }
    static var publishableKey: String { currentConfiguration.publishableKey }
    static var capabilities: ServerCapabilities { currentConfiguration.capabilities }
    static var isCustom: Bool { active != nil }
    static var backendIdentity: String { normalizedAPIBaseURL }
    static var avatarPublicBaseURL: String { normalizedAPIBaseURL + "/storage/v1/object/public/avatars" }
    static var storageBaseURL: String { normalizedAPIBaseURL + "/storage/v1" }

    static var apiKey: String { publishableKey }

    /// Base URL the phone opens to approve a TV login. Matches the Android
    /// `TV_LOGIN_WEB_BASE_URL` default; the backend ultimately returns the real
    /// `web_url` to encode in the QR code, so this is only a fallback hint.
    static var tvLoginWebBaseURL: String {
        if isCustom { return currentConfiguration.normalizedBackendURL + "/tv-login" }
        return "https://nuvio.tv/tv-login"
    }
    static let legacyTvLoginWebBaseURL = "https://app.nuvio.tv/tv-login"

    static var isConfigured: Bool {
        !apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var normalizedAPIBaseURL: String {
        var url = apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        return url
    }
}
