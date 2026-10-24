import Foundation

/// One NNTP provider the engine can fetch articles from.
struct UsenetServerConfig: Sendable, Equatable, Hashable {
    var host: String
    var port: Int
    var useSSL: Bool
    var username: String?
    var password: String?
    /// Simultaneous connections the provider allows for this account.
    var maxConnections: Int

    init(host: String, port: Int, useSSL: Bool, username: String?, password: String?, maxConnections: Int) {
        self.host = host
        self.port = port
        self.useSSL = useSSL
        self.username = username
        self.password = password
        self.maxConnections = min(50, max(1, maxConnections))
    }

    static let defaultConnections = 5

    /// Parses a Stremio-style server URL: `nntps://user:pass@host:563/5`
    /// (`nntp://` for plain text; the path is the connection count).
    init?(url string: String) {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "nntp" || scheme == "nntps" || scheme == "snews",
              let host = components.host, !host.isEmpty else { return nil }
        let ssl = scheme != "nntp"
        let connections = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").first.flatMap { Int($0) } ?? Self.defaultConnections
        self.init(
            host: host,
            port: components.port ?? (ssl ? 563 : 119),
            useSSL: ssl,
            username: components.user?.removingPercentEncoding ?? components.user,
            password: components.password?.removingPercentEncoding ?? components.password,
            maxConnections: connections
        )
    }

    /// Back to the URL form (used to carry addon-supplied servers inside a stream URL).
    var urlString: String {
        var components = URLComponents()
        components.scheme = useSSL ? "nntps" : "nntp"
        components.host = host
        components.port = port
        if let username, !username.isEmpty { components.percentEncodedUser = Self.encode(username) }
        if let password, !password.isEmpty { components.percentEncodedPassword = Self.encode(password) }
        components.path = "/\(maxConnections)"
        return components.string ?? ""
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value
    }
}

/// What an add-on asked to play: the NZB, optionally its own servers, and how
/// to pick the video file inside a multi-file NZB (Stremio stream fields
/// `nzbUrl`, `servers`, `fileMustInclude`, `fileIdx`).
struct UsenetStreamSpec: Sendable, Equatable {
    var nzbURL: URL
    var servers: [UsenetServerConfig]
    var fileMustInclude: String?
    var fileIdx: Int?

    static let scheme = "nuvio-usenet"

    /// Streams travel through the app as an ordinary URL string (stream lists,
    /// "last stream" stores and the play callbacks all expect one), so the spec
    /// is encoded into a private scheme and resolved right before playback.
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "play"
        var items = [URLQueryItem(name: "nzb", value: nzbURL.absoluteString)]
        items += servers.map { URLQueryItem(name: "server", value: $0.urlString) }
        if let fileMustInclude, !fileMustInclude.isEmpty { items.append(URLQueryItem(name: "must", value: fileMustInclude)) }
        if let fileIdx { items.append(URLQueryItem(name: "idx", value: String(fileIdx))) }
        components.queryItems = items
        return components.url!
    }

    init(nzbURL: URL, servers: [UsenetServerConfig] = [], fileMustInclude: String? = nil, fileIdx: Int? = nil) {
        self.nzbURL = nzbURL
        self.servers = servers
        self.fileMustInclude = fileMustInclude
        self.fileIdx = fileIdx
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let nzb = items.first(where: { $0.name == "nzb" })?.value.flatMap(URL.init(string:)) else { return nil }
        self.init(
            nzbURL: nzb,
            servers: items.filter { $0.name == "server" }.compactMap { $0.value.flatMap(UsenetServerConfig.init(url:)) },
            fileMustInclude: items.first { $0.name == "must" }?.value,
            fileIdx: items.first { $0.name == "idx" }?.value.flatMap { Int($0) }
        )
    }

    static func isUsenetURL(_ string: String?) -> Bool {
        guard let string else { return false }
        return string.hasPrefix(scheme + "://")
    }
}

enum UsenetError: LocalizedError, Equatable {
    case noServers
    case nzbDownloadFailed(Int)
    case nzbUnreadable
    case noPlayableFile
    case archiveNotSupported(String)
    case firstSegmentUnavailable
    case serverRejected(String)
    case archiveCompressed(String)
    case archiveEncrypted
    case releaseIncomplete
    case fileNotInPack

    var errorDescription: String? {
        switch self {
        case .noServers:
            return L10n.string("usenet_error_no_servers", fallback: "Add a Usenet server in Settings → Usenet.")
        case .nzbDownloadFailed(let code):
            return L10n.format("usenet_error_nzb_http", fallback: "Couldn't download the NZB (HTTP %d).", code)
        case .nzbUnreadable:
            return L10n.string("usenet_error_nzb_unreadable", fallback: "The NZB file couldn't be read.")
        case .noPlayableFile:
            return L10n.string("usenet_error_no_file", fallback: "The NZB has no video file to play.")
        case .archiveNotSupported(let name):
            return L10n.format("usenet_error_archive", fallback: "%@ is packed in a 7z/zip archive, which can't be streamed.", name)
        case .firstSegmentUnavailable:
            return L10n.string("usenet_error_first_segment", fallback: "The release is incomplete on your Usenet servers.")
        case .serverRejected(let message):
            return message
        case .archiveCompressed(let name):
            return L10n.format("usenet_error_archive_compressed", fallback: "%@ is compressed inside its archive and can't be streamed.", name)
        case .archiveEncrypted:
            return L10n.string("usenet_error_archive_encrypted", fallback: "The release is password protected.")
        case .releaseIncomplete:
            return L10n.string("usenet_error_incomplete", fallback: "Parts of this release are missing on your Usenet servers.")
        case .fileNotInPack:
            return L10n.string("usenet_error_not_in_pack", fallback: "The episode wasn't found in this pack.")
        }
    }
}
