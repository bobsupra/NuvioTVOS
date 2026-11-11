import Foundation

/// Plugin scrapers as stream sources: one group per enabled scraper beside the
/// add-on groups, like Android's `plugin:<id>` groups.
enum PluginStreamDiscovery {
    struct Target: Sendable {
        let groupID: String
        let displayName: String
        let scraper: PluginScraperRecord
    }

    /// Enabled scrapers that handle this content type.
    @MainActor
    static func targets(type: String, videoID: String? = nil) -> [Target] {
        let normalized = PluginTypes.normalized(type)
        guard normalized == "movie" || normalized == "tv" else { return [] }
        return PluginStore.shared.activeScrapers(for: normalized)
            .filter { scraper in videoID.map { scraper.accepts(id: $0) } ?? true }
            // One AIOStreams serves comes through it instead.
            .filter { !PluginAIOBridge.servesThroughAIO($0) }
            .map { Target(groupID: "plugin:\($0.id)", displayName: $0.name, scraper: $0) }
    }

    /// The identifiers one stream request hands a plugin.
    struct Request: Equatable {
        /// First argument, as Android passes it: the TMDB id when TMDB is set
        /// up and knows the title, otherwise the content id (`tt…`).
        let primaryID: String
        let mediaType: String
        let season: Int?
        let episode: Int?
        let imdbID: String?
        let tmdbID: String?
        let videoID: String

        /// Fifth argument — an Apple TV extension Android does not pass, so a
        /// plugin that needs the IMDb id (Usenet indexers) gets it either way.
        var context: [String: Any] {
            var value: [String: Any] = [
                "platform": PluginTypes.platform,
                "type": mediaType,
                "videoId": videoID
            ]
            if let imdbID { value["imdbId"] = imdbID }
            if let tmdbID { value["tmdbId"] = tmdbID }
            if let season { value["season"] = season }
            if let episode { value["episode"] = episode }
            return value
        }

        var arguments: [Any] {
            [primaryID, mediaType, season.map { $0 as Any } ?? NSNull(), episode.map { $0 as Any } ?? NSNull(), context]
        }
    }

    /// Splits a Stremio video id (`tt0944947:1:2`, `tmdb:1399:1:2`, `kitsu:…`)
    /// into what plugins receive; `tmdbID` is the resolved TMDB id if known.
    /// A scraper that lists `series` in its manifest gets `series` for an
    /// episode instead of `tv`, as on Android TV.
    static func request(
        type: String,
        videoID: String,
        resolvedTMDBID: String?,
        scraperDeclaresSeries: Bool = false
    ) -> Request {
        let baseType = PluginTypes.normalized(type) == "tv" ? "tv" : "movie"
        let episode = StreamsRepository.seasonEpisode(fromVideoId: videoID)
        let isEpisode = baseType == "tv" && episode.season != nil && episode.episode != nil
        let mediaType = isEpisode && scraperDeclaresSeries ? "series" : baseType
        var base = videoID
        if isEpisode, let season = episode.season, let number = episode.episode,
           base.hasSuffix(":\(season):\(number)") {
            base.removeLast(":\(season):\(number)".count)
        }
        var tmdbID = resolvedTMDBID
        var imdbID: String?
        if base.hasPrefix("tmdb:") || base.hasPrefix("tmdb/") {
            base = String(base.dropFirst(5))
            if tmdbID == nil, base.allSatisfy(\.isNumber) { tmdbID = base }
        } else if base.lowercased().hasPrefix("tt") {
            imdbID = base
        } else if tmdbID == nil, !base.isEmpty, base.allSatisfy(\.isNumber) {
            tmdbID = base
        }
        return Request(
            primaryID: tmdbID ?? base,
            mediaType: mediaType,
            season: isEpisode ? episode.season : nil,
            episode: isEpisode ? episode.episode : nil,
            imdbID: imdbID,
            tmdbID: tmdbID,
            videoID: videoID
        )
    }

    /// Runs one scraper's `getStreams` and returns its finished group.
    ///
    /// Apple TV extension: the plugin may call `context.emit(list)` while it
    /// searches; each list is added to what `onPartial` shows (still loading)
    /// until the returned list replaces them all.
    static func fetchGroup(
        target: Target,
        type: String,
        videoID: String,
        onPartial: (@Sendable (AddonStreamGroup) async -> Void)? = nil
    ) async -> AddonStreamGroup {
        func group(_ streams: [NuvioStream], error: String?) -> AddonStreamGroup {
            AddonStreamGroup(addonId: target.groupID, displayName: target.displayName, streams: streams, isLoading: false, error: error)
        }
        guard let code = await PluginStore.shared.code(for: target.scraper) else {
            return group([], error: "The provider's code is not available. Refresh the repository.")
        }
        let declaresSeries = target.scraper.declaresSeriesType == true
        let initial = request(type: type, videoID: videoID, resolvedTMDBID: nil, scraperDeclaresSeries: declaresSeries)
        var resolvedTMDB: String?
        if initial.tmdbID == nil, let imdb = initial.imdbID {
            let tmdbType = initial.mediaType == "movie" ? "movie" : "tv"
            resolvedTMDB = await TmdbDetailsService.pluginTmdbId(forImdb: imdb, mediaType: tmdbType).map(String.init)
        }
        let pluginRequest = resolvedTMDB == nil
            ? initial
            : request(type: type, videoID: videoID, resolvedTMDBID: resolvedTMDB, scraperDeclaresSeries: declaresSeries)
        let settings = PluginSettingsVault.settings(scraperID: target.scraper.id)
        // At most ten plugins run at once, as on Android TV.
        await PluginConcurrency.shared.acquire()
        defer { Task { await PluginConcurrency.shared.release() } }
        let scraperID = target.scraper.id
        let displayName = target.displayName
        // Emitted lists, in order, shown as they come.
        let (emitted, emitter) = AsyncStream<String>.makeStream()
        let shownSoFar = PluginPartialStreams()
        let partials = Task {
            var shown: [NuvioStream] = []
            for await json in emitted {
                let list: Any = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [Any]()
                let batch = streams(from: list, providerName: displayName, scraperID: scraperID)
                guard !batch.isEmpty else { continue }
                shown += await DebridStreamPresentation.present(streams: batch)
                shownSoFar.set(shown)
                await onPartial?(AddonStreamGroup(
                    addonId: target.groupID,
                    displayName: displayName,
                    streams: shown,
                    isLoading: true,
                    error: nil
                ))
            }
        }
        defer {
            emitter.finish()
            partials.cancel()
        }
        var forward: (@Sendable (String) -> Void)?
        if onPartial != nil {
            forward = { list in
                _ = emitter.yield(list)
            }
        }
        do {
            let result = try await PluginRuntime.call(
                code: code,
                scraperId: scraperID,
                settings: settings,
                function: "getStreams",
                arguments: pluginRequest.arguments,
                timeout: PluginRuntime.streamTimeout,
                keepAlive: target.scraper.keepAlive == true,
                emitArgument: 4,
                onEmit: forward
            )
            emitter.finish()
            partials.cancel()
            let presented = await DebridStreamPresentation.present(
                streams: streams(from: result, providerName: displayName, scraperID: scraperID)
            )
            return group(presented, error: nil)
        } catch is CancellationError {
            return group([], error: nil)
        } catch {
            PluginLogStore.shared.append(target.scraper.id, level: .error, message: "getStreams failed: \(error.localizedDescription)")
            // What the plugin emitted before it failed (or ran out of time) stays.
            let kept = shownSoFar.get()
            return kept.isEmpty ? group([], error: error.localizedDescription) : group(kept, error: nil)
        }
    }

    /// The streams of a `getStreams` result (or an emitted list).
    static func streams(from result: Any, providerName: String, scraperID: String? = nil) -> [NuvioStream] {
        ((result as? [Any]) ?? []).compactMap { item -> NuvioStream? in
            guard let object = item as? [String: Any] else { return nil }
            return stream(from: object, providerName: providerName, scraperID: scraperID)
        }
    }

    /// Converts one plugin result to a stream through the Stremio decoder the
    /// add-ons use, so URLs, magnets, `nzbUrl` (Nuvio Usenet), headers and
    /// subtitles behave exactly like an add-on stream.
    ///
    /// Shown as on Android TV: the name (or title, or the provider) with
    /// " - quality" when the name doesn't already say it, the title below it,
    /// then size • language. Text containing "[object" (a plugin's stringified
    /// object) is ignored, also as on Android. Apple TV additionally reads the
    /// Stremio fields `description`, `behaviorHints`, `nzbUrl`,
    /// `fileMustInclude`, `fileIdx` and `servers`, and the Apple TV extension
    /// `resolve`: instead of `url`, any JSON the plugin's `resolveStream()`
    /// turns into the link when the stream is played (``PluginLoopbackServer``).
    static func stream(from object: [String: Any], providerName: String, scraperID: String? = nil) -> NuvioStream? {
        guard let stremio = stremioObject(from: object, providerName: providerName, scraperID: scraperID),
              let data = try? JSONSerialization.data(withJSONObject: stremio),
              let dto = try? JSONDecoder().decode(StreamAddonStreamDTO.self, from: data) else { return nil }
        return dto.toNuvioStream(addonName: providerName)
    }

    /// One plugin result as a Stremio stream object — what ``stream(from:providerName:scraperID:)``
    /// decodes, and what AIOStreams gets through ``PluginAIOBridge``. nil: nothing playable.
    static func stremioObject(from object: [String: Any], providerName: String, scraperID: String? = nil) -> [String: Any]? {
        var stremio: [String: Any] = [:]
        if let url = clean(object["url"]) {
            stremio["url"] = url
        } else if let nested = object["url"] as? [String: Any], let url = clean(nested["url"]) {
            stremio["url"] = url
        } else if let payload = object["resolve"], !(payload is NSNull), let scraperID {
            let filename = ((object["behaviorHints"] as? [String: Any])?["filename"]).flatMap(PluginJSON.text)
            guard let url = PluginLoopbackServer.shared.resolveURL(scraperID: scraperID, payload: payload, filename: filename) else {
                PluginLogStore.shared.append(scraperID, level: .warn, message: "A stream's resolve value is too big or not JSON; skipped.")
                return nil
            }
            PluginLoopbackServer.shared.ensureRunning()
            stremio["url"] = url
        }
        for key in ["externalUrl", "infoHash", "nzbUrl", "fileMustInclude", "servers", "sources"] {
            if let value = object[key], !(value is NSNull) { stremio[key] = value }
        }
        if let index = object["fileIdx"] as? NSNumber, !PluginJSON.isBoolean(index) { stremio["fileIdx"] = index.intValue }

        let name = clean(object["name"])
        let title = clean(object["title"])
        let quality = clean(object["quality"])
        var displayName = name ?? title ?? providerName
        if let quality, !displayName.localizedCaseInsensitiveContains(quality) {
            displayName += " - \(quality)"
        }
        stremio["name"] = displayName
        // The title becomes its own line only when it isn't already the name.
        if let name, let title, title != name { stremio["title"] = title }
        if let description = clean(object["description"]) {
            stremio["description"] = description
        } else {
            let parts = ["size", "language"].compactMap { clean(object[$0]) }
            if !parts.isEmpty { stremio["description"] = parts.joined(separator: " • ") }
        }

        var hints = (object["behaviorHints"] as? [String: Any]) ?? [:]
        if let headers = object["headers"] as? [String: Any] {
            var request: [String: String] = [:]
            for (key, value) in headers {
                let name = key.trimmingCharacters(in: .whitespaces)
                guard let text = clean(value),
                      !name.isEmpty,
                      name.caseInsensitiveCompare("Range") != .orderedSame else { continue }
                request[name] = text
            }
            if !request.isEmpty {
                var proxy = (hints["proxyHeaders"] as? [String: Any]) ?? [:]
                var merged = (proxy["request"] as? [String: Any]) ?? [:]
                for (key, value) in request { merged[key] = value }
                proxy["request"] = merged
                hints["proxyHeaders"] = proxy
                hints["notWebReady"] = true
            }
        }
        if !hints.isEmpty { stremio["behaviorHints"] = hints }

        if let subtitles = object["subtitles"] as? [Any] {
            stremio["subtitles"] = subtitles.enumerated().compactMap { index, raw -> [String: Any]? in
                guard let subtitle = raw as? [String: Any], let url = clean(subtitle["url"]) else { return nil }
                var entry: [String: Any] = ["url": url, "id": clean(subtitle["id"]) ?? "\(providerName)-\(index)"]
                entry["lang"] = clean(subtitle["language"]) ?? clean(subtitle["lang"]) ?? "Unknown"
                if let label = clean(subtitle["name"]) ?? clean(subtitle["title"]) { entry["name"] = label }
                return entry
            }
        }

        guard JSONSerialization.isValidJSONObject(stremio) else { return nil }
        return stremio
    }

    private static func clean(_ value: Any?) -> String? {
        guard let value, let text = PluginJSON.text(value) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("[object") ? nil : trimmed
    }
}

/// The streams a plugin emitted so far (``PluginStreamDiscovery/fetchGroup``).
final class PluginPartialStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var streams: [NuvioStream] = []

    func set(_ value: [NuvioStream]) {
        lock.lock()
        streams = value
        lock.unlock()
    }

    func get() -> [NuvioStream] {
        lock.lock()
        defer { lock.unlock() }
        return streams
    }
}

/// Limits how many plugin calls run at once (ten, as on Android TV).
actor PluginConcurrency {
    static let shared = PluginConcurrency(limit: 10)

    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            running = max(0, running - 1)
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// Reads a plugin's settings form and checks its settings, for Settings.
enum PluginSettingsService {
    /// The fields of the scraper's `onSettings()` form; empty when it has none.
    static func layout(for scraper: PluginScraperRecord) async throws -> [PluginSettingField] {
        guard let code = await PluginStore.shared.code(for: scraper) else {
            throw PluginStoreError.download("The provider's code is not available. Refresh the repository.")
        }
        do {
            let value = try await PluginRuntime.call(
                code: code,
                scraperId: scraper.id,
                settings: PluginSettingsVault.settings(scraperID: scraper.id),
                function: "onSettings",
                timeout: 20
            )
            return PluginSettingField.parseLayout(value)
        } catch PluginRuntimeError.missingFunction {
            return []
        }
    }

    /// Apple TV extension: a plugin may export `onVerify(settings)` that
    /// returns `{ ok, message }` (or a string) to check keys before saving.
    /// nil when the plugin has no such function.
    static func verify(scraper: PluginScraperRecord, settings: [String: Any]) async -> (ok: Bool, message: String)? {
        guard let code = await PluginStore.shared.code(for: scraper) else {
            return (false, "The provider's code is not available.")
        }
        do {
            let value = try await PluginRuntime.call(
                code: code,
                scraperId: scraper.id,
                settings: settings,
                function: "onVerify",
                arguments: [settings],
                timeout: 30
            )
            if let object = value as? [String: Any] {
                let ok = (object["ok"] as? Bool) ?? false
                let message = (object["message"] as? String) ?? (ok ? "OK" : "Failed")
                return (ok, message)
            }
            if let text = value as? String { return (true, text) }
            if PluginJSON.isBoolean(value) {
                let ok = (value as? Bool) == true
                return (ok, ok ? "OK" : "Failed")
            }
            return (true, "OK")
        } catch PluginRuntimeError.missingFunction {
            return nil
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Whether the plugin exports `onVerify`, so Settings can show the button.
    static func hasVerify(code: String) -> Bool {
        code.contains("onVerify")
    }
}
