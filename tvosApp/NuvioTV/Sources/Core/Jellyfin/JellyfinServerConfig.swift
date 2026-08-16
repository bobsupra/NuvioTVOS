import Foundation

/// How a configured Jellyfin server authenticates. Distinct from the
/// resulting access token (which never lives here, see
/// `JellyfinCredentialStore`): this is the persisted, `Codable` choice.
enum JellyfinAuthKind: String, Codable, CaseIterable, Equatable {
    /// A key generated in Jellyfin's dashboard — no password ever typed on
    /// the Apple TV keyboard, and the token never expires from this side.
    case apiKey
    /// Username + password, exchanged once for an access token via
    /// `AuthenticateByName`.
    case login

    var title: String {
        switch self {
        case .apiKey: return L10n.string("jellyfin_auth_api_key", fallback: "API Key")
        case .login: return L10n.string("jellyfin_auth_login", fallback: "Sign In")
        }
    }
}

/// One configured Jellyfin server, as saved in Settings → Integrations →
/// Jellyfin. The API key / password never lives here — see
/// `JellyfinCredentialStore`.
struct JellyfinServerConfig: Codable, Identifiable, Equatable {
    let id: String
    var displayName: String
    /// e.g. `"http://192.168.1.10:8096"` — scheme and port included, no
    /// trailing slash.
    var baseURLString: String
    var authKind: JellyfinAuthKind
    var username: String
    /// Jellyfin's internal user id, captured from `AuthenticateByName`'s
    /// response (login mode) or from `/Users/Me` (API-key mode). Needed by
    /// almost every other endpoint.
    var userId: String
    /// Libraries ("Views") selected for syncing, from the library-selection
    /// sheet.
    var selectedLibraryIDs: [String]
    /// Wall-clock of the last successfully completed sync, for the "synced 2h
    /// ago" row subtitle. `nil` before the first sync.
    var lastSyncDate: Date?
    /// Matched-title count from the last completed sync.
    var lastSyncTitleCount: Int?

    init(
        id: String = UUID().uuidString,
        displayName: String,
        baseURLString: String,
        authKind: JellyfinAuthKind = .apiKey,
        username: String = "",
        userId: String = "",
        selectedLibraryIDs: [String] = [],
        lastSyncDate: Date? = nil,
        lastSyncTitleCount: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURLString = baseURLString
        self.authKind = authKind
        self.username = username
        self.userId = userId
        self.selectedLibraryIDs = selectedLibraryIDs
        self.lastSyncDate = lastSyncDate
        self.lastSyncTitleCount = lastSyncTitleCount
    }

    var baseURL: URL? {
        URL(string: baseURLString)
    }

    /// Label shown alongside the host in a server row ("API Key", "raul", …).
    var authSummary: String {
        switch authKind {
        case .apiKey: return authKind.title
        case .login: return username.isEmpty ? authKind.title : username
        }
    }
}
