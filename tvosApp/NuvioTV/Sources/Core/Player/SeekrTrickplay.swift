import CoreGraphics
import Foundation

/// Seek-preview storyboards from Seekr (https://seekr.tv), with the profile's API key
/// (Settings → Playback → Seekr API Key, kept in the Nuvio account with the other
/// settings). One lookup per title and file length gives a signed WebVTT whose cues
/// point at 320×180 tiles in JPEG sprite sheets, which `WebVTTStoryboardProvider`
/// reads. A title Seekr doesn't have leaves the previews to the player.
///
/// Public beta limits per key: 2 requests a second, 5,000 lookups, 20 movies and
/// 70 episodes a day. A lookup is reused while its URLs are valid, a title without
/// previews is not asked again for 6 hours, and a 429 waits for its Retry-After.
actor SeekrTrickplay {
    static let shared = SeekrTrickplay()
    static let apiBase = URL(string: "https://api.seekr.tv")!
    static let notFoundMemory: TimeInterval = 6 * 3600

    enum Title: Hashable, Sendable {
        case movie(imdbID: String?, tmdbID: Int?)
        case episode(showIMDbID: String?, showTMDBID: Int?, season: Int, episode: Int)
    }

    struct Lookup: Equatable, Sendable {
        let vttURL: URL
        /// The played file's length over the sprites' source length.
        let scale: Double
        let expiresAt: Date?
    }

    private struct CacheKey: Hashable {
        let title: Title
        let durationSeconds: Int
    }

    private var lookups: [CacheKey: Lookup] = [:]
    private var notFoundUntil: [CacheKey: Date] = [:]
    private var limitedUntil: Date?
    private var rejectedKey: String?
    private var lastRequest = Date.distantPast

    // MARK: Requests

    /// The storyboard for this title and file length: nil without a key, when Seekr doesn't
    /// have it, or when it can't be asked now.
    func provider(
        contentId: String?,
        season: Int?,
        episode: Int?,
        durationSeconds: Double
    ) async -> (any TrickplayProviding)? {
        let apiKey = await Self.apiKey()
        guard !apiKey.isEmpty, durationSeconds.isFinite, durationSeconds > 0 else { return nil }
        guard let title = Self.title(contentId: contentId, season: season, episode: episode) else {
            await report("no IMDb or TMDB id")
            return nil
        }
        let durationMs = Int((durationSeconds * 1000).rounded())
        guard let found = await storyboard(title: title, durationMs: durationMs, apiKey: apiKey, fresh: false) else {
            return nil
        }
        return SeekrStoryboardProvider(storyboard: found.0, lookup: found.1) {
            let apiKey = await Self.apiKey()
            guard !apiKey.isEmpty else { return nil }
            return await SeekrTrickplay.shared.storyboard(title: title, durationMs: durationMs, apiKey: apiKey, fresh: true)
        }
    }

    private func storyboard(
        title: Title,
        durationMs: Int,
        apiKey: String,
        fresh: Bool
    ) async -> (WebVTTStoryboardProvider, Lookup)? {
        guard let lookup = await lookup(title: title, durationMs: durationMs, apiKey: apiKey, fresh: fresh) else {
            return nil
        }
        // The VTT and the tiles are signed: no key goes there.
        guard let storyboard = await TrickplayResolver.shared.fetchStoryboard(from: lookup.vttURL) else {
            lookups[CacheKey(title: title, durationSeconds: durationMs / 1000)] = nil
            await report("VTT unavailable")
            return nil
        }
        return (storyboard, lookup)
    }

    private func lookup(title: Title, durationMs: Int, apiKey: String, fresh: Bool) async -> Lookup? {
        let key = CacheKey(title: title, durationSeconds: durationMs / 1000)
        let now = Date()
        if !fresh, let cached = lookups[key], (cached.expiresAt ?? .distantFuture) > now.addingTimeInterval(120) {
            await report("found (reused)" + Self.scaleText(cached.scale))
            return cached
        }
        if let until = notFoundUntil[key], until > now {
            await report("no previews for this title (remembered)")
            return nil
        }
        if let until = limitedUntil, until > now {
            await report("limit reached, waiting \(Int(until.timeIntervalSince(now).rounded(.up))) s")
            return nil
        }
        guard rejectedKey != apiKey else {
            await report("key rejected (401)")
            return nil
        }
        guard let url = Self.lookupURL(for: title, durationMs: durationMs) else { return nil }

        // 2 requests a second per key.
        let wait = lastRequest.addingTimeInterval(0.5).timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        lastRequest = Date()
        await report("looking up…")

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else {
            await report("unreachable")
            return nil
        }
        switch http.statusCode {
        case 200:
            guard let lookup = Self.parseLookup(data) else {
                await report("unreadable answer")
                return nil
            }
            lookups[key] = lookup
            await report("found" + Self.scaleText(lookup.scale))
            return lookup
        case 404:
            notFoundUntil[key] = Date().addingTimeInterval(Self.notFoundMemory)
            await report("no previews for this title (404)")
        case 401:
            rejectedKey = apiKey
            await report("key rejected (401)")
        case 429:
            let retry = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            limitedUntil = Date().addingTimeInterval(retry)
            await report("limit reached (429), waiting \(Int(retry)) s")
        default:
            await report("HTTP \(http.statusCode)")
        }
        return nil
    }

    /// Whether Seekr accepts `apiKey`: nil when it couldn't be asked.
    static func validate(apiKey: String) async -> Bool? {
        var request = URLRequest(url: apiBase.appendingPathComponent("v1/keys/validate"))
        request.timeoutInterval = 8
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let valid = body["valid"] as? Bool else { return nil }
        if valid { await shared.forgetRejection(of: apiKey) }
        return valid
    }

    private func forgetRejection(of apiKey: String) {
        if rejectedKey == apiKey { rejectedKey = nil }
    }

    static func hasAPIKey() async -> Bool {
        await !apiKey().isEmpty
    }

    private static func apiKey() async -> String {
        await MainActor.run {
            ProfileSettings.current.string(forKey: SettingsKey.seekrApiKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
    }

    private func report(_ status: String) async {
        await MainActor.run { SeekPreviewDiagnostics.shared.updateSeekr(status) }
    }

    // MARK: Format

    /// The title for Nuvio's content id: an IMDb id ("tt…", also "tt…:1:2") or "tmdb:…".
    /// With a season and an episode it is that episode of the show.
    static func title(contentId: String?, season: Int?, episode: Int?) -> Title? {
        let parts = (contentId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().split(separator: ":").map(String.init)
        guard let first = parts.first else { return nil }
        var imdbID: String?
        var tmdbID: Int?
        if first.count > 2, first.hasPrefix("tt"), first.dropFirst(2).allSatisfy(\.isNumber) {
            imdbID = first
        } else if first == "tmdb", parts.count >= 2, let id = Int(parts[1]), id > 0 {
            tmdbID = id
        } else {
            return nil
        }
        if let season, let episode, season >= 0, episode > 0 {
            return .episode(showIMDbID: imdbID, showTMDBID: tmdbID, season: season, episode: episode)
        }
        return .movie(imdbID: imdbID, tmdbID: tmdbID)
    }

    /// `/sprites` with one identifier (IMDb first) and the file's length.
    static func lookupURL(for title: Title, durationMs: Int) -> URL? {
        guard durationMs > 0,
              var components = URLComponents(url: apiBase.appendingPathComponent("sprites"),
                                             resolvingAgainstBaseURL: false) else { return nil }
        var items = [URLQueryItem(name: "duration_ms", value: String(durationMs))]
        switch title {
        case let .movie(imdbID, tmdbID):
            if let imdbID {
                items.append(URLQueryItem(name: "imdb_id", value: imdbID))
            } else if let tmdbID {
                items.append(URLQueryItem(name: "tmdb_id", value: String(tmdbID)))
            } else {
                return nil
            }
        case let .episode(imdbID, tmdbID, season, episode):
            if let imdbID {
                items.append(URLQueryItem(name: "show_imdb_id", value: imdbID))
            } else if let tmdbID {
                items.append(URLQueryItem(name: "show_tmdb_id", value: String(tmdbID)))
            } else {
                return nil
            }
            items.append(URLQueryItem(name: "season", value: String(season)))
            items.append(URLQueryItem(name: "episode", value: String(episode)))
        }
        components.queryItems = items
        return components.url
    }

    static func parseLookup(_ data: Data) -> Lookup? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = body["vtt_url"] as? String,
              let url = URL(string: raw),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        let scale = (body["scale"] as? NSNumber)?.doubleValue ?? 1
        return Lookup(
            vttURL: url,
            scale: scale.isFinite && scale > 0 ? scale : 1,
            expiresAt: expiry(of: url))
    }

    /// The signed URL's `exp` (Unix seconds), when it has one.
    static func expiry(of url: URL) -> Date? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "exp" })?.value,
              let seconds = TimeInterval(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Retry-After in seconds, a minute when missing.
    static func retryAfter(_ value: String?) -> TimeInterval {
        guard let value, let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) else { return 60 }
        return max(1, seconds)
    }

    /// The position on the sprites' timeline: `scale` is the played file's length over the
    /// source's, so a position there is the played one divided by it.
    static func sourceSeconds(_ seconds: Double, scale: Double) -> Double {
        guard scale.isFinite, scale > 0 else { return seconds }
        return seconds / scale
    }

    private static func scaleText(_ scale: Double) -> String {
        abs(scale - 1) < 0.0005 ? "" : String(format: ", scale %.3f", scale)
    }
}

/// Seekr's storyboard on the player's timeline: positions scaled to the sprites' source, and
/// the signed URLs looked up again shortly before they expire.
actor SeekrStoryboardProvider: TrickplayProviding {
    typealias Refresh = @Sendable () async -> (WebVTTStoryboardProvider, SeekrTrickplay.Lookup)?

    private var storyboard: WebVTTStoryboardProvider
    private var scale: Double
    private var expiresAt: Date?
    private let refresh: Refresh

    init(storyboard: WebVTTStoryboardProvider, lookup: SeekrTrickplay.Lookup, refresh: @escaping Refresh) {
        self.storyboard = storyboard
        self.scale = lookup.scale
        self.expiresAt = lookup.expiresAt
        self.refresh = refresh
    }

    func thumbnail(at seconds: Double) async -> CGImage? {
        if let expiresAt, Date() >= expiresAt.addingTimeInterval(-60) {
            // Sheets already loaded keep working; a failed refresh is tried again later.
            self.expiresAt = Date().addingTimeInterval(300)
            if let (fresh, lookup) = await refresh() {
                storyboard = fresh
                scale = lookup.scale
                self.expiresAt = lookup.expiresAt
            }
        }
        let image = await storyboard.thumbnail(at: SeekrTrickplay.sourceSeconds(seconds, scale: scale))
        return SeekPreviewOriginTags.shared.tag(image, "seekr", seconds: nil)
    }
}
