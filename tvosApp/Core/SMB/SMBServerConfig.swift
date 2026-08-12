import Foundation

/// How a configured SMB server authenticates. Distinct from
/// `AetherEngineSMB.SMBAuthMode` (which carries the actual credentials): this
/// is the persisted, `Codable` choice — the password itself never lives here,
/// see `SMBCredentialStore`.
enum SMBAuthKind: String, Codable, CaseIterable, Equatable {
    case anonymous
    case guest
    case credentials

    var title: String {
        switch self {
        case .anonymous: return L10n.string("smb_auth_anonymous", fallback: "Anonymous")
        case .guest: return L10n.string("smb_auth_guest", fallback: "Guest")
        case .credentials: return L10n.string("smb_auth_credentials", fallback: "Sign In")
        }
    }
}

/// One configured SMB server, as saved in Settings → Integrations → SMB.
/// The password never lives here — see `SMBCredentialStore`.
struct SMBServerConfig: Codable, Identifiable, Equatable {
    let id: String
    var displayName: String
    var host: String
    var port: Int?
    var authKind: SMBAuthKind
    var username: String
    var domain: String
    /// Shares selected for scanning, from the share-selection sheet.
    var selectedShares: [String]
    var maxDepth: Int
    /// Wall-clock of the last successfully completed scan, for the "scanned 2h
    /// ago" row subtitle. `nil` before the first scan.
    var lastScanDate: Date?
    /// Matched-title count from the last completed scan.
    var lastScanTitleCount: Int?

    init(
        id: String = UUID().uuidString,
        displayName: String,
        host: String,
        port: Int? = nil,
        authKind: SMBAuthKind = .anonymous,
        username: String = "",
        domain: String = "",
        selectedShares: [String] = [],
        maxDepth: Int = 6,
        lastScanDate: Date? = nil,
        lastScanTitleCount: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.port = port
        self.authKind = authKind
        self.username = username
        self.domain = domain
        self.selectedShares = selectedShares
        self.maxDepth = maxDepth
        self.lastScanDate = lastScanDate
        self.lastScanTitleCount = lastScanTitleCount
    }

    /// Label shown alongside the host in a server row ("Guest", "raul", …).
    var authSummary: String {
        switch authKind {
        case .anonymous, .guest:
            return authKind.title
        case .credentials:
            return username.isEmpty ? authKind.title : username
        }
    }

    /// `host[:port]` for display and for building `smb://` stream URLs.
    var hostAndPort: String {
        guard let port else { return host }
        return "\(host):\(port)"
    }
}
