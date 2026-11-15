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

    /// A release's sample clip (`Show.S01E05.1080p-GRP-sample.mkv`, `Sample/show.s01e05.mkv`).
    /// For episode names, treat text before the episode marker as a possible title.
    static func isSample(_ path: String) -> Bool {
        let components = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard let filename = components.last else { return false }
        let samplePattern = "(?<![a-z0-9])sample(?![a-z0-9])"
        let episodePattern = #"(?i)(?:^|[^a-z0-9])(?:s\d+e\d+|\d+x\d+)(?![0-9])"#
        if let episode = filename.range(of: episodePattern, options: .regularExpression) {
            if components.dropLast().contains(where: { $0.caseInsensitiveCompare("sample") == .orderedSame }) {
                return true
            }
            return filename[episode.upperBound...].range(
                of: samplePattern, options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
        return path.range(of: samplePattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Matches complete episode tokens such as S01E05, S01E05E06 or 1x05.
    /// The trailing digit boundary prevents S1E2 from matching S1E20.
    static func matchesEpisode(_ path: String, season: Int?, episode: Int?) -> Bool {
        guard let season, let episode, season >= 0, episode > 0 else { return false }
        let pattern = "(?:^|[^a-z0-9])(?:s0*\(season)e(?:[0-9]+e)*0*\(episode)|0*\(season)x0*\(episode))(?![0-9])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return false
        }
        // Parent folders can contain a different episode number than the file.
        let filename = path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map(String.init) ?? ""
        let range = NSRange(filename.startIndex..., in: filename)
        return regex.firstMatch(in: filename, range: range) != nil
    }
}

/// The file-picking heuristic shared by every provider (Real-Debrid, Premiumize,
/// Torbox): prefer a filename matching the wanted episode, then the add-on's
/// `fileIdx`, then the largest video file. A unique add-on filename can pick a
/// specific release first. Generic over provider DTOs via accessor closures.
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
        // Exclude likely samples from automatic name/episode/size selection when
        // alternatives exist. An explicit file index may still select one below.
        let features = playable.filter { !DebridVideo.isSample(name($0)) }
        let candidates = features.isEmpty ? playable : features

        // Prefer an unambiguous file name supplied by the add-on. Keep the
        // sample protection, and do not override an explicit episode with a
        // conflicting or unidentifiable file name.
        if let requested = request.filename?.trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty {
            func normalized(_ value: String) -> String {
                value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\\", with: "/")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            let target = normalized(requested)
            let targetBasename = target.split(separator: "/").last.map(String.init) ?? target
            func basename(_ file: File) -> String {
                normalized(name(file)).split(separator: "/").last.map(String.init) ?? ""
            }
            let matchingGroups = [
                candidates.filter { normalized(name($0)) == target },
                candidates.filter { normalized(name($0)).caseInsensitiveCompare(target) == .orderedSame },
                candidates.filter { target.contains("/") && normalized(name($0)).hasSuffix("/" + target) },
                candidates.filter {
                    target.contains("/") && normalized(name($0)).lowercased().hasSuffix("/" + target.lowercased())
                },
                candidates.filter { basename($0) == targetBasename },
                candidates.filter { basename($0).caseInsensitiveCompare(targetBasename) == .orderedSame }
            ]
            let matchIndex = matchingGroups.firstIndex { !$0.isEmpty }
            let matches = matchIndex.map { matchingGroups[$0] } ?? []
            let pathParts = target.split(separator: "/").map(String.init)
            let filenameHasEpisode = targetBasename.range(
                of: #"(?i)(?:^|[^a-z0-9])(?:s\d+e\d+|\d+x\d+)(?![0-9])"#,
                options: .regularExpression
            ) != nil
            let folderMatchesEpisode = pathParts.count > 1 && !filenameHasEpisode &&
                DebridVideo.matchesEpisode(pathParts[pathParts.count - 2], season: request.season, episode: request.episode)
            let exactPathMatchesEpisode = (matchIndex == 0 || matchIndex == 1) && folderMatchesEpisode
            if matches.count == 1, let match = matches.first,
               (request.season == nil || request.episode == nil ||
                DebridVideo.matchesEpisode(name(match), season: request.season, episode: request.episode) ||
                exactPathMatchesEpisode) {
                return match
            }
        }

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
