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

    /// Short 2-letter provider badge matching Android TV / iOS ("TB", "RD", "PM").
    var shortName: String {
        switch self {
        case .torbox: return "TB"
        case .realDebrid: return "RD"
        case .premiumize: return "PM"
        case .allDebrid: return "AD"
        case .debridLink: return "DL"
        case .none: return ""
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
    /// Provider rate limit reached (HTTP 429) — caller should pause and avoid hammering remaining candidates.
    case rateLimited
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
        "m4v", "mpg", "mpeg", "ts", "m2ts", "vob", "ogv",
        "iso", "img"
    ]

    /// Whether a torrent file path looks like a playable video (by extension).
    static func isPlayable(_ path: String) -> Bool {
        guard let ext = path.split(separator: ".").last?.lowercased() else { return false }
        return extensions.contains(ext)
    }

    /// A release's sample clip (`Show.S01E05.1080p-GRP-sample.mkv`, `Sample/show.s01e05.mkv`):
    /// `sample` as a whole word anywhere in the path.
    static func isSample(_ path: String) -> Bool {
        path.range(of: "(?<![a-z0-9])sample(?![a-z0-9])", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Matches complete episode tokens such as S01E05, S1E5 or 1x05. The
    /// trailing digit boundary is essential: S1E2 must not select S1E20.
    static func matchesEpisode(_ path: String, season: Int?, episode: Int?) -> Bool {
        guard let season, let episode, season >= 0, episode > 0 else { return false }
        let pattern = "(?:^|[^a-z0-9])(?:s0*\(season)e0*\(episode)|0*\(season)x0*\(episode))(?![0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return false
        }
        let range = NSRange(path.startIndex..., in: path)
        return regex.firstMatch(in: path, range: range) != nil
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
        // A release's sample clip also carries the episode token; it is picked only when the
        // torrent holds nothing else.
        let features = playable.filter { !DebridVideo.isSample(name($0)) }
        let candidates = features.isEmpty ? playable : features

        // Series: a filename that matches the season/episode wins; the largest one if several do.
        if request.season != nil,
           request.episode != nil,
           let match = candidates
               .filter({ file in
                   DebridVideo.matchesEpisode(
                       name(file),
                       season: request.season,
                       episode: request.episode
                   )
               })
               .max(by: { (size($0) ?? 0) < (size($1) ?? 0) }) {
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
        return candidates.max(by: { (size($0) ?? 0) < (size($1) ?? 0) })
    }
}
