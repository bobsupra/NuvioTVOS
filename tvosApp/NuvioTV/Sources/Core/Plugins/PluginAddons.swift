import Foundation
import CryptoKit

/// Catalogs, metadata and ratings from plugins — an Apple TV extension of the
/// Nuvio plugin format.
///
/// A provider whose manifest `resources` list `catalog`, `meta` or `ratings`
/// is shown to the rest of the app as a Stremio add-on that exists only on
/// this Apple TV (a "virtual add-on"). Its manifest lives at
/// `https://plugins.nuvio.invalid/<key>/manifest.json`, which
/// ``PluginAddonURLProtocol`` answers by calling the plugin's `getCatalog`,
/// `getMeta` and `getRatings`. Home and Discover rows, catalog ordering,
/// search, Details and ratings then work exactly as they do for add-ons, and
/// nothing is written to the add-on list that syncs with the account.
final class PluginAddonRegistry: @unchecked Sendable {
    static let shared = PluginAddonRegistry()
    /// `.invalid` never resolves, so these URLs can't leave the device.
    static let host = "plugins.nuvio.invalid"

    struct Entry: Sendable {
        let key: String
        let scraper: PluginScraperRecord
        /// The virtual add-on's Stremio manifest, as JSON.
        let manifest: Data
        let manifestURL: URL
    }

    private let lock = NSLock()
    private var scope: String?
    private var entries: [String: Entry] = [:]
    private var urls: [URL] = []

    /// Manifest URLs of the active profile's virtual add-ons, in repository
    /// order. Each carries `?v=<revision>`, so a changed manifest is a new URL
    /// and Home reloads its rows. A plugin AIOStreams serves now
    /// (``PluginAIOBridge``) keeps only its ratings here: its
    /// catalogs and metadata come through AIOStreams.
    var manifestURLs: [URL] {
        lock.lock()
        loadIfNeeded()
        let all = urls
        let snapshot = entries
        lock.unlock()
        return all.compactMap { url in
            guard let key = url.pathComponents.dropFirst().first,
                  let entry = snapshot[key],
                  PluginAIOBridge.servesThroughAIO(entry.scraper) else { return url }
            return snapshot[key + Self.ratingsOnlySuffix]?.manifestURL
        }
    }

    /// The key of a plugin's virtual add-on with its ratings only.
    static let ratingsOnlySuffix = "r"

    func entry(key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return entries[key]
    }

    /// Called by ``PluginStore`` whenever its state changes.
    func update(state: PluginStore.State, scope: String) {
        let built = Self.build(state)
        lock.lock()
        self.scope = scope
        entries = built.entries
        urls = built.urls
        lock.unlock()
        PluginAddonURLProtocol.registerOnce()
    }

    /// The app asks for add-on URLs before the Plugins store is opened, so the
    /// first read loads the active profile's plugins from disk. Lock held.
    private func loadIfNeeded() {
        let active = ProfileSettings.activeProfileScope
        guard scope != active else { return }
        let built = Self.build(PluginStore.loadState(scope: active))
        scope = active
        entries = built.entries
        urls = built.urls
        PluginAddonURLProtocol.registerOnce()
    }

    static func build(_ state: PluginStore.State) -> (entries: [String: Entry], urls: [URL]) {
        guard state.pluginsEnabled else { return ([:], []) }
        let order = Dictionary(state.repositories.enumerated().map { ($1.manifestURL, $0) }, uniquingKeysWith: { first, _ in first })
        let scrapers = state.scrapers
            .filter { $0.enabled && $0.manifestEnabled }
            .sorted { (order[$0.repositoryURL] ?? .max) < (order[$1.repositoryURL] ?? .max) }
        var entries: [String: Entry] = [:]
        var urls: [URL] = []
        for scraper in scrapers {
            guard let manifest = manifest(for: scraper),
                  let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) else { continue }
            let key = key(for: scraper.id)
            let revision = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
            guard entries[key] == nil,
                  let url = URL(string: "https://\(host)/\(key)/manifest.json?v=\(revision)") else { continue }
            entries[key] = Entry(key: key, scraper: scraper, manifest: data, manifestURL: url)
            urls.append(url)
            // Its ratings alone, for while AIOStreams serves the rest.
            if let ratings = Self.manifest(for: scraper, only: [PluginResources.ratings]),
               let ratingsData = try? JSONSerialization.data(withJSONObject: ratings, options: [.sortedKeys]),
               let ratingsURL = URL(string: "https://\(host)/\(key)\(ratingsOnlySuffix)/manifest.json?v=\(revision)") {
                let ratingsKey = key + ratingsOnlySuffix
                entries[ratingsKey] = Entry(key: ratingsKey, scraper: scraper, manifest: ratingsData, manifestURL: ratingsURL)
            }
        }
        return (entries, urls)
    }

    static func key(for scraperID: String) -> String {
        SHA256.hash(data: Data(scraperID.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func isVirtualAddon(_ url: URL) -> Bool {
        url.host?.lowercased() == host
    }

    // MARK: - Manifest

    /// The Stremio manifest of a provider's virtual add-on, or nil when it
    /// offers no catalogs, metadata or ratings.
    ///
    /// - `catalog`: the provider's `catalogs` (Stremio format).
    /// - `meta`: only for the provider's own `idPrefixes` — `tt` and `tmdb`
    ///   ids keep their metadata from Cinemeta / TMDB.
    /// - `ratings`: for the provider's `idPrefixes` (all ids when it has
    ///   none), with its `ratingSources`.
    static func manifest(for scraper: PluginScraperRecord, only: Set<String>? = nil) -> [String: Any]? {
        func wanted(_ resource: String) -> Bool {
            scraper.provides(resource) && (only?.contains(resource) ?? true)
        }
        let types = stremioTypes(scraper.supportedTypes)
        let prefixes = scraper.idPrefixes ?? []
        var resources: [[String: Any]] = []
        var allTypes = types

        var catalogs: [[String: Any]] = []
        if wanted(PluginResources.catalog) {
            catalogs = sanitizedCatalogs(scraper.catalogsJSON)
            for catalog in catalogs {
                if let type = catalog["type"] as? String, !allTypes.contains(type) { allTypes.append(type) }
            }
            if !catalogs.isEmpty {
                resources.append(["name": PluginResources.catalog, "types": allTypes])
            }
        }
        if wanted(PluginResources.meta) {
            let own = ownPrefixes(prefixes)
            if !own.isEmpty {
                resources.append(["name": PluginResources.meta, "types": allTypes, "idPrefixes": own])
            }
        }
        var ratingSources: [[String: Any]] = []
        if wanted(PluginResources.ratings) {
            ratingSources = sanitizedRatingSources(scraper.ratingSourcesJSON)
            if !ratingSources.isEmpty {
                var resource: [String: Any] = ["name": PluginResources.ratings, "types": types]
                if !prefixes.isEmpty { resource["idPrefixes"] = prefixes }
                resources.append(resource)
            }
        }
        guard !resources.isEmpty else { return nil }

        var manifest: [String: Any] = [
            "id": "nuvio.plugin.\(key(for: scraper.id))",
            "version": scraper.version,
            "name": scraper.name,
            "description": scraper.description,
            "types": allTypes,
            "resources": resources,
            "catalogs": catalogs
        ]
        if let logo = scraper.logo { manifest["logo"] = logo }
        if !ratingSources.isEmpty { manifest["ratingSources"] = ratingSources }
        return manifest
    }

    static func stremioTypes(_ supportedTypes: [String]) -> [String] {
        var types: [String] = []
        for type in supportedTypes {
            let value = PluginTypes.normalized(type) == "tv" ? "series" : PluginTypes.normalized(type)
            if !types.contains(value) { types.append(value) }
        }
        return types.isEmpty ? ["movie", "series"] : types
    }

    /// Prefixes that are the plugin's own: not IMDb (`tt`) or TMDB.
    static func ownPrefixes(_ prefixes: [String]) -> [String] {
        prefixes.filter { prefix in
            let lower = prefix.lowercased()
            return !lower.isEmpty && !"tt".hasPrefix(lower) && !lower.hasPrefix("tt") && !lower.hasPrefix("tmdb")
        }
    }

    /// Catalog entries the app's manifest decoder accepts: `type` and `id`
    /// are required, `tv` becomes `series`, and only the known Stremio keys
    /// (with the right value types) are kept.
    static func sanitizedCatalogs(_ json: String?) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for raw in jsonArray(json) {
            guard let object = raw as? [String: Any],
                  let rawType = object["type"].flatMap(PluginJSON.text), !rawType.isEmpty,
                  let id = object["id"].flatMap(PluginJSON.text), !id.isEmpty else { continue }
            let type = PluginTypes.normalized(rawType) == "tv" ? "series" : rawType.lowercased()
            var catalog: [String: Any] = ["type": type, "id": id, "name": object["name"].flatMap(PluginJSON.text) ?? id]
            if let extra = object["extra"] as? [Any] {
                catalog["extra"] = extra.compactMap { item -> [String: Any]? in
                    guard let item = item as? [String: Any], let name = item["name"].flatMap(PluginJSON.text) else { return nil }
                    var value: [String: Any] = ["name": name]
                    if let required = item["isRequired"] as? Bool { value["isRequired"] = required }
                    if let options = item["options"] as? [Any] { value["options"] = options.compactMap(PluginJSON.text) }
                    if let limit = item["optionsLimit"] as? Int { value["optionsLimit"] = limit }
                    return value
                }
            }
            for key in ["extraSupported", "extraRequired", "genres"] {
                if let list = object[key] as? [Any] { catalog[key] = list.compactMap(PluginJSON.text) }
            }
            if let showInHome = object["showInHome"] as? Bool { catalog["showInHome"] = showInHome }
            if let shape = object["posterShape"].flatMap(PluginJSON.text) { catalog["posterShape"] = shape }
            result.append(catalog)
        }
        return result
    }

    /// Nuvio `ratingSources` entries: `source` is required.
    static func sanitizedRatingSources(_ json: String?) -> [[String: Any]] {
        jsonArray(json).compactMap { raw -> [String: Any]? in
            guard let object = raw as? [String: Any],
                  let source = object["source"].flatMap(PluginJSON.text), !source.isEmpty else { return nil }
            var value: [String: Any] = ["source": source]
            if let name = object["name"].flatMap(PluginJSON.text) { value["name"] = name }
            if let icon = object["icon"].flatMap(PluginJSON.text) { value["icon"] = icon }
            if let max = object["max"] as? Double { value["max"] = max }
            if let episodes = object["episodes"] as? Bool { value["episodes"] = episodes }
            return value
        }
    }

    private static func jsonArray(_ json: String?) -> [Any] {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return array
    }
}

// MARK: - Requests

/// Answers the virtual add-ons' Stremio requests from the plugins.
enum PluginAddonService {
    /// The app's add-on requests give up after 8–10 s.
    static let timeout: TimeInterval = 8

    struct Reply: Sendable {
        let status: Int
        let body: Data

        static let notFound = Reply(status: 404, body: Data(#"{"error":"Not found"}"#.utf8))

        static func json(_ object: [String: Any]) -> Reply {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return Reply(status: 200, body: data)
        }

        static func failure(_ message: String) -> Reply {
            let data = (try? JSONSerialization.data(withJSONObject: ["error": message])) ?? Data("{}".utf8)
            return Reply(status: 502, body: data)
        }
    }

    /// `/<key>/manifest.json` or `/<key>/<resource>/<type>/<id>[/<extra>].json`.
    struct Route: Equatable {
        let key: String
        let resource: String
        let type: String
        let id: String
        let extra: [String: String]

        init(key: String, resource: String, type: String, id: String, extra: [String: String] = [:]) {
            self.key = key
            self.resource = resource
            self.type = type
            self.id = id
            self.extra = extra
        }

        init?(url: URL) {
            guard PluginAddonRegistry.isVirtualAddon(url) else { return nil }
            let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
            var parts = path.split(separator: "/").map(String.init)
            guard parts.count >= 2 else { return nil }
            key = parts.removeFirst()
            if parts == ["manifest.json"] {
                resource = "manifest"
                type = ""
                id = ""
                extra = [:]
                return
            }
            guard parts.count == 3 || parts.count == 4, var last = parts.last, last.hasSuffix(".json") else { return nil }
            last.removeLast(".json".count)
            parts[parts.count - 1] = last
            resource = parts[0]
            type = parts[1].removingPercentEncoding ?? parts[1]
            id = parts[2].removingPercentEncoding ?? parts[2]
            extra = parts.count == 4 ? Self.parseExtra(parts[3]) : [:]
        }

        /// Stremio's `genre=Action&skip=100`, each name and value percent-encoded.
        static func parseExtra(_ encoded: String) -> [String: String] {
            var result: [String: String] = [:]
            for pair in encoded.split(separator: "&") {
                let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let name = pieces.first?.removingPercentEncoding, !name.isEmpty else { continue }
                let value = pieces.count > 1 ? (pieces[1].removingPercentEncoding ?? pieces[1]) : ""
                result[name] = value
            }
            return result
        }

        var cacheKey: String {
            ([key, resource, type, id] + extra.keys.sorted().map { "\($0)=\(extra[$0] ?? "")" }).joined(separator: "|")
        }

        var cacheLifetime: TimeInterval {
            switch resource {
            case PluginResources.catalog: return extra["search"] == nil ? 10 * 60 : 2 * 60
            default: return 60 * 60
            }
        }
    }

    static func reply(for url: URL) async -> Reply {
        guard let route = Route(url: url),
              let entry = PluginAddonRegistry.shared.entry(key: route.key) else { return .notFound }
        if route.resource == "manifest" { return Reply(status: 200, body: entry.manifest) }
        guard PluginResources.addonResources.contains(route.resource),
              entry.scraper.provides(route.resource) else { return .notFound }
        return await PluginAddonResponseCache.shared.reply(key: entry.scraper.id + "|" + route.cacheKey, lifetime: route.cacheLifetime) {
            await call(entry.scraper, route: route)
        }
    }

    /// One uncached plugin call for a route (the Test button uses it directly).
    static func call(_ scraper: PluginScraperRecord, route: Route) async -> Reply {
        guard let code = await PluginStore.shared.code(for: scraper) else {
            return .failure("The provider's code is not available. Refresh the repository.")
        }
        let function: String
        var arguments: [Any] = [route.type, route.id]
        switch route.resource {
        case PluginResources.catalog:
            function = "getCatalog"
            arguments.append(route.extra)
        case PluginResources.meta:
            function = "getMeta"
            arguments.append(["platform": PluginTypes.platform, "type": route.type, "id": route.id])
        default:
            function = "getRatings"
            let context = await ratingsContext(type: route.type, id: route.id)
            arguments.append(context)
        }
        let settings = PluginSettingsVault.settings(scraperID: scraper.id)
        await PluginConcurrency.shared.acquire()
        defer { Task { await PluginConcurrency.shared.release() } }
        do {
            let result = try await PluginRuntime.call(
                code: code,
                scraperId: scraper.id,
                settings: settings,
                function: function,
                arguments: arguments,
                timeout: timeout,
                keepAlive: scraper.keepAlive == true
            )
            switch route.resource {
            case PluginResources.catalog:
                return .json(["metas": metas(from: result, type: route.type)])
            case PluginResources.meta:
                guard let meta = meta(from: result, type: route.type, id: route.id) else { return .notFound }
                return .json(["meta": meta])
            default:
                return .json(["ratings": ratings(from: result)])
            }
        } catch is CancellationError {
            return .failure("Cancelled")
        } catch {
            PluginLogStore.shared.append(scraper.id, level: .error, message: "\(function) failed: \(error.localizedDescription)")
            return .failure(error.localizedDescription)
        }
    }

    static func ratingsContext(type: String, id: String) async -> [String: Any] {
        let base = PluginStreamDiscovery.request(type: type, videoID: id, resolvedTMDBID: nil)
        var resolved: String?
        if base.tmdbID == nil, let imdb = base.imdbID {
            resolved = await TmdbDetailsService.pluginTmdbId(forImdb: imdb, mediaType: PluginTypes.normalized(type) == "tv" ? "tv" : "movie")
                .map(String.init)
        }
        let request = resolved == nil ? base : PluginStreamDiscovery.request(type: type, videoID: id, resolvedTMDBID: resolved)
        var context = request.context
        context["type"] = type
        return context
    }

    // MARK: Results

    /// `{ metas: [...] }` or a bare array → metas with an `id`, a `type`
    /// (the catalog's when missing) and a `name`.
    static func metas(from result: Any, type: String) -> [[String: Any]] {
        let items = (result as? [Any]) ?? ((result as? [String: Any])?["metas"] as? [Any]) ?? []
        return items.compactMap { raw in
            guard var meta = raw as? [String: Any], let id = meta["id"].flatMap(PluginJSON.text) else { return nil }
            meta["id"] = id
            if meta["type"].flatMap(PluginJSON.text) == nil { meta["type"] = type }
            if meta["name"].flatMap(PluginJSON.text) == nil { meta["name"] = "" }
            return JSONSerialization.isValidJSONObject(meta) ? meta : nil
        }
    }

    /// `{ meta: {...} }` or the meta itself.
    static func meta(from result: Any, type: String, id: String) -> [String: Any]? {
        guard let object = result as? [String: Any] else { return nil }
        guard var meta = (object["meta"] as? [String: Any]) ?? (object["id"] != nil ? object : nil) else { return nil }
        if meta["id"].flatMap(PluginJSON.text) == nil { meta["id"] = id }
        if meta["type"].flatMap(PluginJSON.text) == nil { meta["type"] = type }
        if meta["name"].flatMap(PluginJSON.text) == nil { meta["name"] = "" }
        return JSONSerialization.isValidJSONObject(meta) ? meta : nil
    }

    /// `{ ratings: [...] }` or a bare array → `{ source, value, url }` with a
    /// numeric value.
    static func ratings(from result: Any) -> [[String: Any]] {
        let items = (result as? [Any]) ?? ((result as? [String: Any])?["ratings"] as? [Any]) ?? []
        return items.compactMap { raw in
            guard let object = raw as? [String: Any],
                  let source = object["source"].flatMap(PluginJSON.text) else { return nil }
            let value: Double?
            if let number = object["value"] as? NSNumber, !PluginJSON.isBoolean(number) {
                value = number.doubleValue
            } else if let text = object["value"] as? String {
                value = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
            } else {
                value = nil
            }
            guard let value, value.isFinite else { return nil }
            var rating: [String: Any] = ["source": source, "value": value]
            if let url = object["url"].flatMap(PluginJSON.text) { rating["url"] = url }
            return rating
        }
    }
}

/// Plugin answers for catalogs (10 min, searches 2 min), metadata and ratings
/// (1 hour); one call per request at a time. Failures are not kept.
actor PluginAddonResponseCache {
    static let shared = PluginAddonResponseCache()

    private var entries: [String: (expires: Date, reply: PluginAddonService.Reply)] = [:]
    private var inFlight: [String: Task<PluginAddonService.Reply, Never>] = [:]

    func reply(
        key: String,
        lifetime: TimeInterval,
        load: @escaping @Sendable () async -> PluginAddonService.Reply
    ) async -> PluginAddonService.Reply {
        if let entry = entries[key], entry.expires > Date() { return entry.reply }
        if let task = inFlight[key] { return await task.value }
        let task = Task { await load() }
        inFlight[key] = task
        let reply = await task.value
        inFlight[key] = nil
        if reply.status == 200 {
            if entries.count > 500 { entries = entries.filter { $0.value.expires > Date() } }
            entries[key] = (Date().addingTimeInterval(lifetime), reply)
        }
        return reply
    }

    /// After a provider's settings change.
    func removeAll() {
        entries.removeAll()
    }
}

// MARK: - URL loading

/// Serves `https://plugins.nuvio.invalid/…` from ``PluginAddonService``.
/// Registered for `URLSession.shared` and installed into the add-on sessions
/// (``install(in:)``).
final class PluginAddonURLProtocol: URLProtocol {
    private static let registration = NSLock()
    nonisolated(unsafe) private static var registered = false

    static func registerOnce() {
        registration.lock()
        defer { registration.unlock() }
        guard !registered else { return }
        registered = true
        URLProtocol.registerClass(PluginAddonURLProtocol.self)
    }

    /// Adds the protocol to a session configuration (custom sessions don't
    /// consult `registerClass`).
    static func install(in configuration: URLSessionConfiguration) {
        configuration.protocolClasses = [PluginAddonURLProtocol.self] + (configuration.protocolClasses ?? [])
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url.map(PluginAddonRegistry.isVirtualAddon) ?? false
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private var work: Task<Void, Never>?
    private var clientThread: Thread?
    private var modes: [String] = [RunLoop.Mode.default.rawValue]
    private var stopped = false

    override func startLoading() {
        // URL loading expects the client to be called on this thread.
        clientThread = Thread.current
        if let mode = RunLoop.current.currentMode { modes = [mode.rawValue] }
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        work = Task { [weak self] in
            let reply = await PluginAddonService.reply(for: url)
            self?.deliver(reply)
        }
    }

    override func stopLoading() {
        stopped = true
        work?.cancel()
        work = nil
    }

    private func deliver(_ reply: PluginAddonService.Reply) {
        let box = PluginAddonReplyBox(reply)
        if let clientThread {
            perform(#selector(finish(_:)), on: clientThread, with: box, waitUntilDone: false, modes: modes)
        } else {
            finish(box)
        }
    }

    @objc private func finish(_ box: PluginAddonReplyBox) {
        guard !stopped, let url = request.url else { return }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: box.reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json; charset=utf-8"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: box.reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class PluginAddonReplyBox: NSObject {
    let reply: PluginAddonService.Reply

    init(_ reply: PluginAddonService.Reply) {
        self.reply = reply
    }
}
