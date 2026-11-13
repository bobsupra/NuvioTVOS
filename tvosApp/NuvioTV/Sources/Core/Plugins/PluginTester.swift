import Foundation

/// "Test" for a provider (Settings on the TV and the web page): one search
/// for a sample title — streams and/or subtitles, whatever the provider
/// offers — with what came back, how long it took and the provider's log
/// lines from that run. Android has the same button for streams.
enum PluginTester {
    struct Sample: Equatable {
        var type: String
        var imdbID: String
        var season: Int?
        var episode: Int?

        /// The Matrix — Android's own test title.
        static let movie = Sample(type: "movie", imdbID: "tt0133093", season: nil, episode: nil)
        /// Breaking Bad S01E01.
        static let episode = Sample(type: "series", imdbID: "tt0903747", season: 1, episode: 1)

        var videoID: String {
            guard type != "movie", let season, let episode else { return imdbID }
            return "\(imdbID):\(season):\(episode)"
        }

        var label: String {
            guard type != "movie", let season, let episode else { return imdbID }
            return "\(imdbID) S\(season)E\(episode)"
        }

        /// What a search test looks for.
        var searchQuery: String {
            switch imdbID {
            case Self.movie.imdbID: return "The Matrix"
            case Self.episode.imdbID: return "Breaking Bad"
            default: return type == "movie" ? "The Matrix" : "Breaking Bad"
            }
        }
    }

    /// Catalog, search, metadata or ratings results of a test.
    struct Section: Sendable {
        let title: String
        let summary: String
        let lines: [String]
        let error: String?
    }

    struct Report {
        let sample: Sample
        let streams: [NuvioStream]
        /// Why the stream search failed, if it did.
        let error: String?
        let subtitles: [NuvioSubtitle]
        let subtitleError: String?
        let checkedStreams: Bool
        let checkedSubtitles: Bool
        let sections: [Section]
        let duration: TimeInterval
        let log: [PluginLogEntry]
        /// Lists the provider emitted before its final answer, and when the
        /// first one came (progressive results).
        var partialUpdates = 0
        var firstPartialAfter: TimeInterval?

        var failed: Bool {
            (checkedStreams && error != nil) || (checkedSubtitles && subtitleError != nil)
                || sections.contains { $0.error != nil }
        }

        var summary: String {
            var parts: [String] = []
            if checkedStreams {
                parts.append(error.map { "✕ \($0)" } ?? "\(streams.count) stream\(streams.count == 1 ? "" : "s")")
                if partialUpdates > 0, let first = firstPartialAfter {
                    parts.append(String(format: "first results after %.1f s (%ld update%@)", first, partialUpdates, partialUpdates == 1 ? "" : "s"))
                }
            }
            if checkedSubtitles {
                parts.append(subtitleError.map { "✕ subtitles: \($0)" }
                    ?? "\(subtitles.count) subtitle\(subtitles.count == 1 ? "" : "s")")
            }
            parts.append(contentsOf: sections.map(\.summary))
            parts.append(String(format: "%.1f s", duration))
            return parts.joined(separator: " · ")
        }
    }

    /// Asks the provider for everything it offers (streams, subtitles) for
    /// the sample, bypassing caches.
    static func run(_ scraper: PluginScraperRecord, sample: Sample) async -> Report {
        let before = PluginLogStore.shared.entries(for: scraper.id).last?.id
        let started = Date()
        let checkStreams = scraper.provides(PluginResources.stream)
        let checkSubtitles = scraper.provides(PluginResources.subtitles)

        let partials = PartialCounter(started: started)
        async let streamGroup = streams(scraper, sample: sample, when: checkStreams, partials: partials)
        async let subtitleOutcome = subtitles(scraper, sample: sample, when: checkSubtitles)
        async let addonSections = addonSections(scraper, sample: sample)
        let group = await streamGroup
        let outcome = await subtitleOutcome
        let sections = await addonSections

        let entries = PluginLogStore.shared.entries(for: scraper.id)
        let newLines: [PluginLogEntry]
        if let before, let index = entries.firstIndex(where: { $0.id == before }) {
            newLines = Array(entries[(index + 1)...])
        } else {
            newLines = entries
        }
        let progress = await partials.snapshot()
        return Report(
            sample: sample,
            streams: group?.streams ?? [],
            error: group?.error,
            subtitles: outcome?.subtitles ?? [],
            subtitleError: outcome?.error,
            checkedStreams: checkStreams,
            checkedSubtitles: checkSubtitles,
            sections: sections,
            duration: Date().timeIntervalSince(started),
            log: newLines,
            partialUpdates: progress.count,
            firstPartialAfter: progress.first
        )
    }

    private actor PartialCounter {
        let started: Date
        var count = 0
        var first: TimeInterval?

        init(started: Date) {
            self.started = started
        }

        func record() {
            count += 1
            if first == nil { first = Date().timeIntervalSince(started) }
        }

        func snapshot() -> (count: Int, first: TimeInterval?) {
            (count, first)
        }
    }

    private static func streams(
        _ scraper: PluginScraperRecord,
        sample: Sample,
        when enabled: Bool,
        partials: PartialCounter
    ) async -> AddonStreamGroup? {
        guard enabled else { return nil }
        let target = PluginStreamDiscovery.Target(groupID: "plugin:\(scraper.id)", displayName: scraper.name, scraper: scraper)
        return await PluginStreamDiscovery.fetchGroup(
            target: target,
            type: sample.type,
            videoID: sample.videoID,
            onPartial: { _ in await partials.record() }
        )
    }

    private static func subtitles(_ scraper: PluginScraperRecord, sample: Sample, when enabled: Bool) async -> PluginSubtitleDiscovery.Outcome? {
        guard enabled else { return nil }
        return await PluginSubtitleDiscovery.run(scraper, query: PluginSubtitleDiscovery.Query(type: sample.type, videoID: sample.videoID))
    }

    // MARK: - Catalogs, search, metadata, ratings

    private static func addonSections(_ scraper: PluginScraperRecord, sample: Sample) async -> [Section] {
        let key = PluginAddonRegistry.key(for: scraper.id)
        var sections: [Section] = []
        var seen: [(id: String, type: String)] = []

        if scraper.provides(PluginResources.catalog) {
            let catalogs = PluginAddonRegistry.sanitizedCatalogs(scraper.catalogsJSON)
            if catalogs.isEmpty {
                sections.append(Section(title: "Catalogs", summary: "✕ no catalogs", lines: [],
                                        error: "The manifest lists no valid catalogs (each needs a type and an id)."))
            }
            if let catalog = catalogs.first(where: { !requiresExtra($0) }) {
                let result = await catalogSection(scraper, key: key, catalog: catalog, extra: [:], title: "Catalog")
                sections.append(result.section)
                seen.append(contentsOf: result.items)
            }
            if let catalog = catalogs.first(where: supportsSearch) {
                let result = await catalogSection(scraper, key: key, catalog: catalog, extra: ["search": sample.searchQuery],
                                                  title: "Search “\(sample.searchQuery)”")
                sections.append(result.section)
                seen.append(contentsOf: result.items)
            }
        }

        if scraper.provides(PluginResources.meta) {
            let own = PluginAddonRegistry.ownPrefixes(scraper.idPrefixes ?? [])
            if own.isEmpty {
                sections.append(Section(title: "Metadata", summary: "✕ metadata", lines: [],
                                        error: "Metadata needs the provider's own idPrefixes (not tt or tmdb)."))
            } else if let item = seen.first(where: { item in own.contains { item.id.hasPrefix($0) } }) {
                let id = item.id
                let route = PluginAddonService.Route(key: key, resource: PluginResources.meta, type: item.type, id: id)
                let reply = await PluginAddonService.call(scraper, route: route)
                if let meta = json(reply)?["meta"] as? [String: Any] {
                    let videos = (meta["videos"] as? [Any])?.count ?? 0
                    let name = (meta["name"] as? String) ?? id
                    sections.append(Section(title: "Metadata \(id)", summary: "metadata ✓",
                                            lines: [name + (videos > 0 ? " · \(videos) episodes" : "")], error: nil))
                } else {
                    sections.append(Section(title: "Metadata \(id)", summary: "✕ metadata", lines: [], error: errorText(reply)))
                }
            } else {
                sections.append(Section(title: "Metadata", summary: "metadata not tested",
                                        lines: ["No catalog item with the provider's own id to try."], error: nil))
            }
        }

        if scraper.provides(PluginResources.ratings) {
            let type = sample.type == "movie" ? "movie" : "series"
            let route = PluginAddonService.Route(key: key, resource: PluginResources.ratings, type: type, id: sample.imdbID)
            let reply = await PluginAddonService.call(scraper, route: route)
            if reply.status == 200, let ratings = json(reply)?["ratings"] as? [[String: Any]] {
                let lines = ratings.map { rating in
                    "\(rating["source"] as? String ?? "?"): \(rating["value"].map { "\($0)" } ?? "?")"
                }
                sections.append(Section(title: "Ratings \(sample.imdbID)", summary: "\(ratings.count) rating\(ratings.count == 1 ? "" : "s")",
                                        lines: lines, error: nil))
            } else {
                sections.append(Section(title: "Ratings \(sample.imdbID)", summary: "✕ ratings", lines: [], error: errorText(reply)))
            }
        }
        return sections
    }

    private static func catalogSection(
        _ scraper: PluginScraperRecord,
        key: String,
        catalog: [String: Any],
        extra: [String: String],
        title: String
    ) async -> (section: Section, items: [(id: String, type: String)]) {
        let type = catalog["type"] as? String ?? "movie"
        let id = catalog["id"] as? String ?? ""
        let name = catalog["name"] as? String ?? id
        let route = PluginAddonService.Route(key: key, resource: PluginResources.catalog, type: type, id: id, extra: extra)
        let reply = await PluginAddonService.call(scraper, route: route)
        guard reply.status == 200, let metas = json(reply)?["metas"] as? [[String: Any]] else {
            return (Section(title: "\(title): \(name)", summary: "✕ \(extra["search"] == nil ? "catalog" : "search")", lines: [],
                            error: errorText(reply)), [])
        }
        let items = metas.compactMap { meta -> (id: String, type: String)? in
            guard let id = meta["id"] as? String else { return nil }
            return (id, (meta["type"] as? String) ?? type)
        }
        let lines = metas.prefix(8).map { meta in
            [meta["name"] as? String, meta["releaseInfo"] as? String, meta["id"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let label = extra["search"] == nil ? "in catalog" : "found"
        return (Section(title: "\(title): \(name)", summary: "\(metas.count) \(label)", lines: lines, error: nil), items)
    }

    private static func requiresExtra(_ catalog: [String: Any]) -> Bool {
        if let required = catalog["extraRequired"] as? [String], !required.isEmpty { return true }
        let extra = catalog["extra"] as? [[String: Any]] ?? []
        return extra.contains { ($0["isRequired"] as? Bool) == true }
    }

    private static func supportsSearch(_ catalog: [String: Any]) -> Bool {
        if let supported = catalog["extraSupported"] as? [String], supported.contains("search") { return true }
        let extra = catalog["extra"] as? [[String: Any]] ?? []
        return extra.contains { ($0["name"] as? String) == "search" }
    }

    private static func json(_ reply: PluginAddonService.Reply) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
    }

    private static func errorText(_ reply: PluginAddonService.Reply) -> String {
        if let message = json(reply)?["error"] as? String, !message.isEmpty {
            return reply.status == 404 ? "Not found (missing function or empty answer)" : message
        }
        return "HTTP \(reply.status)"
    }
}
