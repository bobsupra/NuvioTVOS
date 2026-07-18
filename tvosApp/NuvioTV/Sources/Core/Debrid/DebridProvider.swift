import Foundation

// MARK: - Debrid provider abstraction
//
// A debrid provider turns a torrent (info-hash + optional file index) into a
// cached, directly-playable HTTPS URL. Torrent-only add-ons like Torrentio
// return `NuvioStream.infoHash` instead of a `url`; the resolver below runs
// that through the user's configured provider before playback.
//
// Ported from the Android app's `core/debrid` resolvers.

/// Provider identifiers stored under `SettingsKey.debridProvider`.
/// Settings → Integrations → Debrid links Real-Debrid, TorBox, and Premiumize.
/// AllDebrid and Debrid-Link are retained for stored/synced values only.
enum DebridProviderKind: String, CaseIterable {
    case none = "None"
    case realDebrid = "Real-Debrid"
    case allDebrid = "AllDebrid"
    case premiumize = "Premiumize"
    case debridLink = "Debrid-Link"
    case torbox = "TorBox"

    init(settingsValue: String?) {
        self = DebridProviderKind(rawValue: settingsValue ?? "None") ?? .none
    }

    /// Providers that can resolve torrent streams today.
    var hasResolver: Bool {
        switch self {
        case .realDebrid, .premiumize, .torbox: return true
        case .none, .allDebrid, .debridLink: return false
        }
    }

    /// Android TV `debrid_settings.preferred_resolver_provider_id` values.
    var androidProviderId: String? {
        switch self {
        case .torbox: return "torbox"
        case .premiumize: return "premiumize"
        case .realDebrid: return "realdebrid"
        case .none, .allDebrid, .debridLink: return nil
        }
    }

    init(androidProviderId: String?) {
        switch (androidProviderId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "torbox": self = .torbox
        case "premiumize": self = .premiumize
        case "realdebrid", "real-debrid", "real_debrid": self = .realDebrid
        default: self = .none
        }
    }
}

/// Everything a provider needs to resolve one torrent stream.
struct DebridRequest {
    let infoHash: String
    let fileIdx: Int?
    let sources: [String]
    let filename: String?
    /// Season/episode of the wanted item, used to pick the right file inside a
    /// season-pack torrent. `nil` for movies.
    let season: Int?
    let episode: Int?

    /// Builds a `magnet:` URI from the info-hash and any tracker `sources`.
    var magnetURI: String {
        var magnet = "magnet:?xt=urn:btih:\(infoHash)"
        for source in sources where !source.isEmpty {
            let encoded = source.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? source
            magnet += "&tr=\(encoded)"
        }
        return magnet
    }
}

/// Outcome of a resolve attempt. Distinguishing the failure modes lets the UI
/// tell the user *why* a stream didn't play (bad key vs. not cached).
enum DebridResult: Equatable {
    /// A ready-to-play direct URL, plus optional metadata for the player header.
    case success(url: URL, filename: String?, videoSize: Int64?)
    /// No API key configured for the selected provider.
    case missingApiKey
    /// The torrent isn't cached / no usable file — caller should try the next stream.
    case stale
    /// Auth failed or an unexpected error — caller should try the next stream.
    case error
}

/// A single debrid backend (Real-Debrid, Premiumize, …).
protocol DebridProvider {
    var kind: DebridProviderKind { get }
    func resolve(_ request: DebridRequest, apiKey: String) async -> DebridResult
}

// MARK: - Shared helpers

extension CharacterSet {
    /// Characters allowed unescaped inside a single URL query value.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+")
        return set
    }()
}

enum DebridVideo {
    static let extensions: Set<String> = [
        "mkv", "mp4", "avi", "mov", "wmv", "flv", "webm",
        "m4v", "mpg", "mpeg", "ts", "m2ts", "vob", "ogv"
    ]

    /// Whether a torrent file path looks like a playable video (by extension).
    static func isPlayable(_ path: String) -> Bool {
        guard let ext = path.split(separator: ".").last?.lowercased() else { return false }
        return extensions.contains(ext)
    }

    /// Case-insensitive S/E patterns used to pick the right file from a pack
    /// (e.g. "s01e05", "1x05"). Empty for movies.
    static func episodePatterns(season: Int?, episode: Int?) -> [String] {
        guard let season, let episode else { return [] }
        let s2 = String(format: "%02d", season)
        let e2 = String(format: "%02d", episode)
        return [
            "s\(s2)e\(e2)",
            "\(season)x\(e2)",
            "s\(season)e\(episode)"
        ]
    }
}

/// The file-picking heuristic shared by every provider (Real-Debrid, Premiumize,
/// Torbox): prefer a filename matching the wanted episode, then the add-on's
/// `fileIdx`, then the largest video file. Generic over each provider's file DTO
/// via accessor closures. Mirrors the Android `*FileSelector` classes.
enum DebridFileSelection {
    static func select<File>(
        from files: [File],
        request: DebridRequest,
        name: (File) -> String,
        size: (File) -> Int64?,
        fileId: (File) -> Int? = { _ in nil }
    ) -> File? {
        let playable = files.filter { DebridVideo.isPlayable(name($0)) }
        guard !playable.isEmpty else { return nil }

        // Series: a filename that matches the season/episode wins.
        let patterns = DebridVideo.episodePatterns(season: request.season, episode: request.episode)
        if !patterns.isEmpty,
           let match = playable.first(where: { file in
               let lower = name(file).lowercased()
               return patterns.contains { lower.contains($0) }
           }) {
            return match
        }

        // The add-on's fileIdx points at a position in the torrent's file list.
        if let idx = request.fileIdx {
            if files.indices.contains(idx), DebridVideo.isPlayable(name(files[idx])) {
                return files[idx]
            }
            if idx > 0, files.indices.contains(idx - 1), DebridVideo.isPlayable(name(files[idx - 1])) {
                return files[idx - 1]
            }
            if let byId = playable.first(where: { fileId($0) == idx }) { return byId }
        }

        // Fallback: the largest video file (usually the feature/episode).
        return playable.max(by: { (size($0) ?? 0) < (size($1) ?? 0) })
    }
}
