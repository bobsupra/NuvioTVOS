import Foundation

/// Subtitles from plugins — an Apple TV extension of the Nuvio plugin format.
/// A provider that lists `subtitles` in its manifest `resources` gets
///
///     getSubtitles(type, id, context)
///
/// with the Stremio type (`movie` / `series`), the Stremio video id
/// (`tt0903747:1:1`) and `{ platform, type, videoId, imdbId, tmdbId, season,
/// episode, filename, videoSize, videoHash }`, and answers with
/// `[{ url, lang, label }]` (or `{ subtitles: [...] }`, like a Stremio add-on).
/// The player lists them next to the add-ons' subtitles.
enum PluginSubtitleDiscovery {
    static let timeout: TimeInterval = 20
    static let maxResults = 200

    struct Query: Hashable, Sendable {
        /// Stremio type: `movie` or `series`.
        let type: String
        let videoID: String
        var videoHash: String?
        var videoSize: Int64?
        var filename: String?

        init(type: String, videoID: String, videoHash: String? = nil, videoSize: Int64? = nil, filename: String? = nil) {
            self.type = PluginTypes.normalized(type) == "tv" ? "series" : "movie"
            self.videoID = videoID
            self.videoHash = videoHash?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            self.videoSize = videoSize.flatMap { $0 > 0 ? $0 : nil }
            self.filename = filename?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    struct Outcome: Sendable {
        let subtitles: [NuvioSubtitle]
        let error: String?
    }

    /// Enabled providers that give subtitles for this type and id.
    @MainActor
    static func providers(for query: Query) -> [PluginScraperRecord] {
        PluginStore.shared
            .activeScrapers(for: query.type, resource: PluginResources.subtitles)
            .filter { $0.accepts(id: query.videoID) }
            // One AIOStreams serves comes through it instead.
            .filter { !PluginAIOBridge.servesThroughAIO($0) }
    }

    /// One provider's subtitles, kept for ten minutes so reopening the player
    /// doesn't ask the site again. Failures are logged and not kept.
    static func subtitles(from scraper: PluginScraperRecord, query: Query) async -> [NuvioSubtitle] {
        await PluginSubtitleCache.shared.subtitles(key: cacheKey(scraper, query)) {
            await run(scraper, query: query)
        }
    }

    /// One uncached call (the Test button uses it directly).
    static func run(_ scraper: PluginScraperRecord, query: Query) async -> Outcome {
        guard let code = await PluginStore.shared.code(for: scraper) else {
            return Outcome(subtitles: [], error: "The provider's code is not available. Refresh the repository.")
        }
        let base = PluginStreamDiscovery.request(type: query.type, videoID: query.videoID, resolvedTMDBID: nil)
        var resolvedTMDB: String?
        if base.tmdbID == nil, let imdb = base.imdbID {
            resolvedTMDB = await TmdbDetailsService.pluginTmdbId(forImdb: imdb, mediaType: query.type == "movie" ? "movie" : "tv")
                .map(String.init)
        }
        let request = resolvedTMDB == nil
            ? base
            : PluginStreamDiscovery.request(type: query.type, videoID: query.videoID, resolvedTMDBID: resolvedTMDB)
        let settings = PluginSettingsVault.settings(scraperID: scraper.id)

        await PluginConcurrency.shared.acquire()
        defer { Task { await PluginConcurrency.shared.release() } }
        do {
            let result = try await PluginRuntime.call(
                code: code,
                scraperId: scraper.id,
                settings: settings,
                function: "getSubtitles",
                arguments: [query.type, query.videoID, context(query: query, request: request)],
                timeout: timeout,
                keepAlive: scraper.keepAlive == true
            )
            return Outcome(subtitles: subtitles(from: result, providerName: scraper.name), error: nil)
        } catch is CancellationError {
            return Outcome(subtitles: [], error: nil)
        } catch {
            PluginLogStore.shared.append(scraper.id, level: .error, message: "getSubtitles failed: \(error.localizedDescription)")
            return Outcome(subtitles: [], error: error.localizedDescription)
        }
    }

    static func context(query: Query, request: PluginStreamDiscovery.Request) -> [String: Any] {
        var value = request.context
        value["type"] = query.type
        if let filename = query.filename { value["filename"] = filename }
        if let videoSize = query.videoSize { value["videoSize"] = videoSize }
        if let videoHash = query.videoHash { value["videoHash"] = videoHash }
        return value
    }

    /// Plugin results → player subtitles: http(s) links only, each once, at
    /// most ``maxResults``. `lang` (or `language`) is best an ISO 639-2 code
    /// (`cze`, `slo`, `eng`) as Stremio add-ons use; the label is `label`,
    /// `title` or `name`.
    static func subtitles(from result: Any, providerName: String) -> [NuvioSubtitle] {
        let items: [Any]
        if let array = result as? [Any] {
            items = array
        } else if let object = result as? [String: Any], let array = object["subtitles"] as? [Any] {
            items = array
        } else {
            items = []
        }
        var seen = Set<String>()
        var subtitles: [NuvioSubtitle] = []
        for raw in items {
            guard subtitles.count < maxResults,
                  let object = raw as? [String: Any],
                  let url = clean(object["url"]),
                  let scheme = URL(string: url)?.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  seen.insert(url).inserted else { continue }
            subtitles.append(NuvioSubtitle(
                url: url,
                language: clean(object["lang"]) ?? clean(object["language"]) ?? "Unknown",
                label: clean(object["label"]) ?? clean(object["title"]) ?? clean(object["name"]),
                source: providerName
            ))
        }
        return subtitles
    }

    private static func cacheKey(_ scraper: PluginScraperRecord, _ query: Query) -> String {
        [scraper.id, query.type, query.videoID, query.filename ?? "", query.videoHash ?? "", query.videoSize.map(String.init) ?? ""]
            .joined(separator: "|")
    }

    private static func clean(_ value: Any?) -> String? {
        guard let value, let text = PluginJSON.text(value) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("[object") ? nil : trimmed
    }
}

/// Ten-minute memory of plugin subtitle answers; one call per key at a time.
actor PluginSubtitleCache {
    static let shared = PluginSubtitleCache()
    static let lifetime: TimeInterval = 10 * 60

    private var entries: [String: (date: Date, subtitles: [NuvioSubtitle])] = [:]
    private var inFlight: [String: Task<PluginSubtitleDiscovery.Outcome, Never>] = [:]

    func subtitles(
        key: String,
        load: @escaping @Sendable () async -> PluginSubtitleDiscovery.Outcome
    ) async -> [NuvioSubtitle] {
        if let entry = entries[key], Date().timeIntervalSince(entry.date) < Self.lifetime {
            return entry.subtitles
        }
        if let task = inFlight[key] { return await task.value.subtitles }
        let task = Task { await load() }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        if outcome.error == nil {
            if entries.count > 200 { entries.removeAll() }
            entries[key] = (Date(), outcome.subtitles)
        }
        return outcome.subtitles
    }

    /// After a provider's settings change.
    func removeAll() {
        entries.removeAll()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
