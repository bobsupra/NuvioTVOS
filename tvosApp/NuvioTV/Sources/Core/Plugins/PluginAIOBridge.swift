import Foundation

/// AIOStreams in Nuvio (AIOStreamsHost): plugins set "Through AIOStreams" reach the
/// AIOStreams running in Nuvio's Node.js as Stremio add-ons, on the plugins' own server
/// on this Apple TV (``PluginLoopbackServer``, `http://127.0.0.1:<port>/<token>/`):
///
/// - `stremio/plugins.json` — the plugins set so; AIOStreams' "Nuvio plugins" card
///   (`nuvio-main.mjs`) makes each of them an add-on of its own (`stremio/health` only
///   tells that the server answers);
/// - `stremio/p/<key>/manifest.json` and `stremio/p/<key>/<resource>/<type>/<id>[/<extra>].json`
///   for its streams, subtitles, catalogs and metadata.
///
/// Through AIOStreams a plugin's streams come at once when it has finished (no
/// progressive results), with their headers as `proxyHeaders` and links resolved on
/// play still pointing at this server.
///
/// Once AIOStreams has asked for the plugins (its configuration has the card) and while
/// AIOStreams runs with its addon on, Nuvio shows that plugin only through AIOStreams:
/// its own stream group, subtitles, catalogs and metadata are left out; its ratings
/// stay (AIOStreams has none). Without AIOStreams the plugin is shown directly again.
enum PluginAIOBridge {
    typealias Request = PluginHTTPServerCore.Request
    typealias Response = PluginHTTPServerCore.Response

    private static let lock = NSLock()
    private nonisolated(unsafe) static var askedKeys: Set<String> = []

    // MARK: - What Nuvio leaves to AIOStreams

    /// Whether Nuvio leaves `scraper` to AIOStreams now.
    static func servesThroughAIO(_ scraper: PluginScraperRecord) -> Bool {
        guard scraper.throughAIO == true, AIOStreamsHost.isServingAddon else { return false }
        let key = PluginAddonRegistry.key(for: scraper.id)
        return lock.withLock { askedKeys.contains(key) }
    }

    /// What Nuvio shows of the plugins changed: Home loads its catalogs again.
    static func changed() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: AIOStreamsHost.addonChangedNotification, object: nil)
        }
    }

    private static func noteAsked(_ key: String) {
        let first = lock.withLock { askedKeys.insert(key).inserted }
        if first { changed() }
    }

    /// The plugins set "Through AIOStreams" (on, with plugins on).
    @MainActor
    static func served() -> [PluginScraperRecord] {
        let store = PluginStore.shared
        store.ensureLoaded()
        guard store.state.pluginsEnabled else { return [] }
        return store.state.scrapers.filter { $0.throughAIO == true && $0.enabled && $0.manifestEnabled }
    }

    /// For AIOStreams' "Nuvio plugins" card: each plugin's key, name and what it offers.
    @MainActor
    static func list() -> [[String: Any]] {
        served().map { scraper in
            let resources = (manifest(for: scraper)["resources"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            var entry: [String: Any] = [
                "key": PluginAddonRegistry.key(for: scraper.id),
                "name": scraper.name,
                "resources": resources
            ]
            if let logo = scraper.logo { entry["logo"] = logo }
            return entry
        }
    }

    // MARK: - The add-ons

    /// A plugin's Stremio manifest for AIOStreams: streams and subtitles for IMDb and TMDB
    /// ids (or the plugin's own prefixes), and its catalogs and metadata as its virtual
    /// add-on has them (``PluginAddonRegistry/manifest(for:only:)``) — without ratings.
    static func manifest(for scraper: PluginScraperRecord) -> [String: Any] {
        let key = PluginAddonRegistry.key(for: scraper.id)
        let types = PluginAddonRegistry.stremioTypes(scraper.supportedTypes)
        let prefixes = (scraper.idPrefixes ?? []).isEmpty ? ["tt", "tmdb:"] : (scraper.idPrefixes ?? [])
        var resources: [[String: Any]] = []
        var catalogs: [[String: Any]] = []
        var allTypes = types
        if let virtual = PluginAddonRegistry.manifest(for: scraper, only: [PluginResources.catalog, PluginResources.meta]) {
            resources = virtual["resources"] as? [[String: Any]] ?? []
            catalogs = virtual["catalogs"] as? [[String: Any]] ?? []
            allTypes = virtual["types"] as? [String] ?? types
        }
        for resource in [PluginResources.stream, PluginResources.subtitles] where scraper.provides(resource) {
            resources.append(["name": resource, "types": types, "idPrefixes": prefixes])
        }
        let version = scraper.version.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil ? scraper.version : "1.0.0"
        var manifest: [String: Any] = [
            "id": "nuvio.plugin.aio.\(key)",
            "version": version,
            "name": scraper.name,
            "description": scraper.description.isEmpty ? "A Nuvio plugin on this Apple TV" : scraper.description,
            "types": allTypes,
            "resources": resources,
            "catalogs": catalogs,
            "behaviorHints": ["configurable": false]
        ]
        if let logo = scraper.logo { manifest["logo"] = logo }
        return manifest
    }

    /// `stremio/…` on ``PluginLoopbackServer`` (``PluginRoutes/handleLocal(_:)``).
    static func handle(_ request: Request) async -> Response {
        var parts = request.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.first == "stremio" else { return notFound }
        parts.removeFirst()
        if parts == ["health"] {
            return .json(["ok": true])
        }
        if parts == ["plugins.json"] {
            // Asked only by the "Nuvio plugins" card: these plugins are in AIOStreams now.
            let plugins = await MainActor.run { list() }
            for plugin in plugins {
                if let key = plugin["key"] as? String { noteAsked(key) }
            }
            return .json(["plugins": plugins])
        }
        guard parts.count >= 3, parts[0] == "p" else { return notFound }
        let key = parts[1]
        let found = await MainActor.run { served().first { PluginAddonRegistry.key(for: $0.id) == key } }
        guard let scraper = found else { return notFound }
        noteAsked(key)
        let rest = parts.dropFirst(2).joined(separator: "/")
        if rest == "manifest.json" {
            return .json(manifest(for: scraper))
        }
        // `<resource>/<type>/<id>[/<extra>].json`, as the plugin's virtual add-on reads it.
        guard let virtualURL = URL(string: "https://\(PluginAddonRegistry.host)/\(key)/\(rest)"),
              let route = PluginAddonService.Route(url: virtualURL) else { return notFound }
        switch route.resource {
        case PluginResources.stream where scraper.provides(PluginResources.stream):
            return .json(["streams": await streams(scraper, type: route.type, id: route.id)])
        case PluginResources.subtitles where scraper.provides(PluginResources.subtitles):
            return .json(["subtitles": await subtitles(scraper, route: route)])
        case PluginResources.catalog, PluginResources.meta:
            let reply = await PluginAddonService.reply(for: virtualURL)
            return Response(status: reply.status, contentType: "application/json; charset=utf-8", body: reply.body)
        default:
            return notFound
        }
    }

    /// A plugin's streams as Stremio stream objects, once it has finished. Each
    /// request goes into the AIOStreams log with its times (TMDB lookup, waiting
    /// for a free plugin slot, the plugin itself): nuvio-main.mjs logs next to it
    /// how many of them AIOStreams took.
    static func streams(_ scraper: PluginScraperRecord, type: String, id: String) async -> [[String: Any]] {
        let begin = Date()
        func report(_ outcome: String, tmdb: TimeInterval, wait: TimeInterval, run: TimeInterval) {
            AIOStreamsHost.note(String(
                format: "AIOStreams asked %@ for %@ %@: %@ in %.1f s (TMDB %.1f s, waiting %.1f s, plugin %.1f s)",
                scraper.name, type, id, outcome, Date().timeIntervalSince(begin), tmdb, wait, run
            ))
        }
        guard let code = await PluginStore.shared.code(for: scraper) else {
            PluginLogStore.shared.append(scraper.id, level: .error, message: "AIOStreams asked, but the provider's code is not available.")
            report("no code", tmdb: 0, wait: 0, run: 0)
            return []
        }
        let declaresSeries = scraper.declaresSeriesType == true
        let initial = PluginStreamDiscovery.request(type: type, videoID: id, resolvedTMDBID: nil, scraperDeclaresSeries: declaresSeries)
        var resolvedTMDB: String?
        let tmdbStart = Date()
        if initial.tmdbID == nil, let imdb = initial.imdbID {
            // Cached after the first time (Nuvio looks the title up for its details too).
            resolvedTMDB = await TmdbDetailsService.pluginTmdbId(forImdb: imdb, mediaType: initial.mediaType == "movie" ? "movie" : "tv")
                .map(String.init)
        }
        let tmdb = Date().timeIntervalSince(tmdbStart)
        let pluginRequest = resolvedTMDB == nil
            ? initial
            : PluginStreamDiscovery.request(type: type, videoID: id, resolvedTMDBID: resolvedTMDB, scraperDeclaresSeries: declaresSeries)
        let settings = PluginSettingsVault.settings(scraperID: scraper.id)
        let waitStart = Date()
        await PluginConcurrency.shared.acquire()
        defer { Task { await PluginConcurrency.shared.release() } }
        let wait = Date().timeIntervalSince(waitStart)
        let runStart = Date()
        do {
            let result = try await PluginRuntime.call(
                code: code,
                scraperId: scraper.id,
                settings: settings,
                function: "getStreams",
                arguments: pluginRequest.arguments,
                timeout: PluginRuntime.streamTimeout,
                keepAlive: scraper.keepAlive == true
            )
            let objects = streamObjects(from: result, scraper: scraper)
            let raw = (result as? [Any])?.count ?? 0
            report(raw == objects.count ? "\(objects.count) streams" : "\(objects.count) of \(raw) streams", tmdb: tmdb, wait: wait, run: Date().timeIntervalSince(runStart))
            return objects
        } catch is CancellationError {
            report("cancelled", tmdb: tmdb, wait: wait, run: Date().timeIntervalSince(runStart))
            return []
        } catch {
            PluginLogStore.shared.append(scraper.id, level: .error, message: "getStreams for AIOStreams failed: \(error.localizedDescription)")
            report("failed (\(error.localizedDescription))", tmdb: tmdb, wait: wait, run: Date().timeIntervalSince(runStart))
            return []
        }
    }

    /// A `getStreams` result as Stremio stream objects; what has nothing to play is left out.
    static func streamObjects(from result: Any, scraper: PluginScraperRecord) -> [[String: Any]] {
        ((result as? [Any]) ?? [])
            .compactMap { $0 as? [String: Any] }
            .compactMap { PluginStreamDiscovery.stremioObject(from: $0, providerName: scraper.name, scraperID: scraper.id) }
            .filter { object in ["url", "infoHash", "nzbUrl", "externalUrl"].contains { object[$0] != nil } }
    }

    /// A plugin's subtitles as Stremio subtitle objects.
    static func subtitles(_ scraper: PluginScraperRecord, route: PluginAddonService.Route) async -> [[String: Any]] {
        let query = PluginSubtitleDiscovery.Query(
            type: route.type,
            videoID: route.id,
            videoHash: route.extra["videoHash"],
            videoSize: route.extra["videoSize"].flatMap { Int64($0) },
            filename: route.extra["filename"]
        )
        let found = await PluginSubtitleDiscovery.subtitles(from: scraper, query: query)
        return found.map { subtitle in
            var entry: [String: Any] = ["id": subtitle.url, "url": subtitle.url, "lang": subtitle.language]
            if let label = subtitle.label { entry["label"] = label }
            return entry
        }
    }

    private static var notFound: Response {
        .json(["error": "Not found"], status: 404)
    }
}
