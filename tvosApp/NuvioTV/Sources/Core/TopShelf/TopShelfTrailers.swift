import Foundation

// MARK: - Top Shelf trailers
//
// The carousel plays a title's trailer when its item stays in focus
// (`TVTopShelfCarouselItem.previewVideoURL`). The links come from Trailerio,
// which the Details page already plays trailers from: Apple TV (HLS), Rotten
// Tomatoes, Plex and MUBI (MP4), none of them DRM-protected or signed.
//
// The shelf gives no callback when an item gains focus: the system asks for
// the whole carousel, trailer links included, and plays them on its own. So
// the extension looks the carousel's titles up each time the system loads the
// shelf, rather than relying on links saved days earlier, and falls back to
// the last links it found when Trailerio doesn't answer in time.
// Shared with the extension target, so free of app model types.

/// One trailer Trailerio lists for a title.
public struct TopShelfTrailerLink: Codable, Equatable, Sendable {
    public let url: String
    /// Trailerio's label: source and quality ("Apple TV 4K DV Atmos").
    public let provider: String

    public init(url: String, provider: String) {
        self.url = url
        self.provider = provider
    }
}

/// Chooses the trailer with the best picture among the ones listed.
public enum TopShelfTrailerPicker {
    /// The highest resolution, then Dolby Vision over HDR over SDR, then the
    /// richest sound, then the source (Apple TV first, as on Details), then
    /// HLS over a single file. The first listed wins a tie.
    public static func best(_ links: [TopShelfTrailerLink]) -> TopShelfTrailerLink? {
        var best: TopShelfTrailerLink?
        var bestRank = Int.min
        for link in links {
            let rank = rank(of: link)
            if rank > bestRank {
                best = link
                bestRank = rank
            }
        }
        return best
    }

    static func rank(of link: TopShelfTrailerLink) -> Int {
        let label = link.provider.lowercased()
        let words = Set(label.split { !$0.isLetter && !$0.isNumber }.map(String.init))

        let resolution: Int
        if words.contains("4k") || words.contains("uhd") || label.contains("2160") {
            resolution = 5
        } else if label.contains("1440") || words.contains("2k") {
            resolution = 4
        } else if label.contains("1080") || words.contains("fhd") {
            resolution = 3
        } else if label.contains("720") {
            resolution = 2
        } else if label.contains("480") || words.contains("sd") {
            resolution = 1
        } else {
            resolution = 0
        }

        let dynamicRange: Int
        if words.contains("dv") || label.contains("dolby vision") {
            dynamicRange = 2
        } else if words.contains(where: { $0.hasPrefix("hdr") }) {
            dynamicRange = 1
        } else {
            dynamicRange = 0
        }

        let sound: Int
        if words.contains("atmos") {
            sound = 2
        } else if label.contains("5.1") || label.contains("7.1") {
            sound = 1
        } else {
            sound = 0
        }

        let source: Int
        if label.contains("apple tv") {
            source = 5
        } else if label.contains("rotten tomatoes") || label.contains("fandango") {
            source = 4
        } else if label.contains("plex") {
            source = 3
        } else if label.contains("mubi") {
            source = 2
        } else if label.contains("imdb") {
            source = 1
        } else {
            source = 0
        }

        let path = (URL(string: link.url)?.path ?? link.url).lowercased()
        let format = path.hasSuffix(".m3u8") ? 2 : (path.hasSuffix(".mp4") || path.hasSuffix(".m4v") ? 1 : 0)

        return resolution * 10_000 + dynamicRange * 1_000 + sound * 100 + source * 10 + format
    }
}

/// The trailers found for the shelf's titles, kept next to the feeds as the
/// fallback when Trailerio can't be reached.
public enum TopShelfTrailerStore {
    public struct Record: Codable, Equatable, Sendable {
        /// Nil: Trailerio has no trailer for the title.
        public let link: TopShelfTrailerLink?
        public let fetchedAt: Date

        public init(link: TopShelfTrailerLink?, fetchedAt: Date) {
            self.link = link
            self.fetchedAt = fetchedAt
        }
    }

    static let fileName = "trailers.json"
    /// A title without a trailer is asked about again after this long.
    static let missingRecheckInterval: TimeInterval = 24 * 60 * 60

    static func read(in directory: URL) -> [String: Record] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let records = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return records
    }

    static func write(_ records: [String: Record], in directory: URL) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    /// Titles with a trailer are always looked up again, so the shelf gets
    /// the link Trailerio gives now; titles without one only once a day.
    static func needsLookup(_ record: Record?, now: Date = Date()) -> Bool {
        guard let record, record.link == nil else { return true }
        return now.timeIntervalSince(record.fetchedAt) >= missingRecheckInterval
    }
}

public enum TopShelfTrailerResolver {
    /// The shelf waits for the lookups, so they get a few seconds at most.
    static let requestTimeout: TimeInterval = 4
    static let totalTimeout: TimeInterval = 6

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = totalTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    private enum Lookup: Sendable {
        case found(TopShelfTrailerLink)
        case missing
        case failed
    }

    private struct Response: Decodable {
        struct Meta: Decodable {
            struct Link: Decodable {
                let trailers: String?
                let provider: String?
            }
            let links: [Link]?
        }
        let meta: Meta?
    }

    /// The trailer to play for each of `entries`, by content id: looked up
    /// now, else the last one found. Saves what it found for next time and
    /// forgets titles no longer passed in.
    public static func trailers(
        for entries: [TopShelfEntry],
        in container: URL?,
        now: Date = Date()
    ) async -> [String: TopShelfTrailerLink] {
        let saved = container.map(TopShelfTrailerStore.read(in:)) ?? [:]
        var lookups: [(contentId: String, urls: [URL])] = []
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.contentId).inserted {
            let urls = lookupURLs(for: entry)
            guard TopShelfTrailerStore.needsLookup(saved[entry.contentId], now: now), !urls.isEmpty else { continue }
            lookups.append((entry.contentId, urls))
        }

        let results = await withTaskGroup(of: (String, Lookup).self) { group -> [String: Lookup] in
            for lookup in lookups {
                group.addTask {
                    // The title's own trailer, else an earlier season's.
                    var failed = false
                    for url in lookup.urls {
                        let result = await self.lookup(url)
                        switch result {
                        case .found: return (lookup.contentId, result)
                        case .failed: failed = true
                        case .missing: break
                        }
                    }
                    return (lookup.contentId, failed ? .failed : .missing)
                }
            }
            var results: [String: Lookup] = [:]
            for await (contentId, result) in group {
                results[contentId] = result
            }
            return results
        }

        var records: [String: TopShelfTrailerStore.Record] = [:]
        for contentId in seen {
            switch results[contentId] {
            case .found(let link):
                records[contentId] = TopShelfTrailerStore.Record(link: link, fetchedAt: now)
            case .missing:
                records[contentId] = TopShelfTrailerStore.Record(link: nil, fetchedAt: now)
            case .failed, nil:
                if let record = saved[contentId] { records[contentId] = record }
            }
        }
        if let container, records != saved {
            TopShelfTrailerStore.write(records, in: container)
        }
        var found = records.compactMapValues(\.link)

        // What Trailerio doesn't have, IMDb itself may (as Details plays it). Its links are signed
        // and expire, so they are asked again at every refresh and never kept.
        let withoutTrailer = entries.filter { found[$0.contentId] == nil }
        if !withoutTrailer.isEmpty {
            let fromIMDb = await withTaskGroup(of: (String, TopShelfTrailerLink?).self) { group -> [String: TopShelfTrailerLink] in
                var asked = Set<String>()
                for entry in withoutTrailer where asked.insert(entry.contentId).inserted {
                    let ids = Self.imdbIDs(for: entry)
                    guard !ids.isEmpty else { continue }
                    group.addTask {
                        for id in ids {
                            if let link = await Self.imdbTrailer(imdbID: id) { return (entry.contentId, link) }
                        }
                        return (entry.contentId, nil)
                    }
                }
                var links: [String: TopShelfTrailerLink] = [:]
                for await (contentId, link) in group {
                    if let link { links[contentId] = link }
                }
                return links
            }
            found.merge(fromIMDb) { trailerio, _ in trailerio }
        }
        return found
    }

    /// Trailerio's page for the title, by its IMDb id. Nil for titles without
    /// one (Kitsu, TMDB-only add-on ids).
    static func lookupURL(for entry: TopShelfEntry) -> URL? {
        lookupURLs(for: entry).first
    }

    /// The title's page, then its earlier seasons' (`TopShelfEntry.trailerFallbackIMDbIds`).
    static func lookupURLs(for entry: TopShelfEntry) -> [URL] {
        let kind = isSeries(entry.contentType) ? "series" : "movie"
        return imdbIDs(for: entry).compactMap { URL(string: "https://trailerio.cc/meta/\(kind)/\($0).json") }
    }

    /// The title's IMDb id, then its earlier seasons' (at most four).
    static func imdbIDs(for entry: TopShelfEntry) -> [String] {
        let candidates = [entry.imdbId, entry.contentId.split(separator: ":").first.map(String.init)]
            + (entry.trailerFallbackIMDbIds ?? []).map { Optional($0) }
        var seen = Set<String>()
        let ids = candidates.compactMap { $0.flatMap(canonicalIMDbID) }.filter { seen.insert($0).inserted }
        return Array(ids.prefix(4))
    }

    // MARK: IMDb

    private struct IMDbResponse: Decodable {
        struct DataField: Decodable { var title: Title? = nil }
        struct Title: Decodable {
            var latestTrailer: Video? = nil
            var primaryVideos: Videos? = nil
        }
        struct Videos: Decodable {
            struct Edge: Decodable { var node: Video? = nil }
            var edges: [Edge]? = nil
        }
        struct Video: Decodable {
            struct Name: Decodable { var value: String? = nil }
            struct Playback: Decodable {
                var url: String? = nil
                var videoMimeType: String? = nil
                var videoDefinition: String? = nil
            }
            var id: String? = nil
            var name: Name? = nil
            var playbackURLs: [Playback]? = nil
        }
        var data: DataField? = nil
    }

    static let imdbQuery = """
    query TitleTrailer($const: ID!) { title(id: $const) {
      latestTrailer { id name { value } playbackURLs { url videoMimeType videoDefinition } }
      primaryVideos(first: 10) { edges { node { id name { value } playbackURLs { url videoMimeType videoDefinition } } } }
    } }
    """

    /// The title's trailer straight from IMDb: its latest trailer, else a video named a trailer,
    /// in the best file the shelf plays (1080p MP4 first).
    static func imdbTrailer(imdbID: String) async -> TopShelfTrailerLink? {
        guard let url = URL(string: "https://graphql.prod.api.imdb.a2z.com/"),
              let body = try? JSONSerialization.data(withJSONObject: ["query": imdbQuery, "variables": ["const": imdbID]]) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.imdb.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.imdb.com/", forHTTPHeaderField: "Referer")
        guard let result = try? await session.data(for: request),
              let http = result.1 as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return imdbLink(from: result.0)
    }

    static func imdbLink(from data: Data) -> TopShelfTrailerLink? {
        guard let title = (try? JSONDecoder().decode(IMDbResponse.self, from: data))?.data?.title else { return nil }
        var videos: [IMDbResponse.Video] = []
        if let latest = title.latestTrailer { videos.append(latest) }
        for edge in title.primaryVideos?.edges ?? [] {
            guard let node = edge.node, !videos.contains(where: { $0.id != nil && $0.id == node.id }) else { continue }
            videos.append(node)
        }
        func name(_ video: IMDbResponse.Video) -> String { (video.name?.value ?? "").lowercased() }
        let playable = videos.filter { !($0.playbackURLs ?? []).isEmpty && !name($0).contains("vertical") }
        let latest = title.latestTrailer.flatMap { trailer in playable.first(where: { $0.id == trailer.id }) }
        let named = playable.first(where: { name($0).contains("trailer") })
        let chosen = latest ?? named ?? playable.first
        guard let files = chosen?.playbackURLs else { return nil }
        let ranked = files.compactMap { file -> (url: String, rank: Int, definition: String)? in
            guard let url = file.url?.trimmingCharacters(in: .whitespacesAndNewlines), url.hasPrefix("https://") else { return nil }
            return (url, imdbRank(definition: file.videoDefinition, mime: file.videoMimeType), file.videoDefinition ?? "")
        }.sorted { $0.rank > $1.rank }
        guard let best = ranked.first else { return nil }
        let quality = best.definition.replacingOccurrences(of: "DEF_", with: "")
        return TopShelfTrailerLink(url: best.url, provider: "IMDb \(quality)".trimmingCharacters(in: .whitespaces))
    }

    /// 1080p, 720p, 480p MP4, then HLS; anything else last.
    static func imdbRank(definition: String?, mime: String?) -> Int {
        let isMP4 = (mime ?? "").lowercased().contains("mp4")
        switch definition {
        case "DEF_1080p": return isMP4 ? 50 : 40
        case "DEF_720p": return isMP4 ? 30 : 25
        case "DEF_AUTO": return 20
        case "DEF_480p": return isMP4 ? 15 : 10
        default: return isMP4 ? 5 : 1
        }
    }

    /// The playable links of a Trailerio response, in its order. Nil when it
    /// isn't one (an error page).
    static func links(from data: Data) -> [TopShelfTrailerLink]? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        return (response.meta?.links ?? []).compactMap { link in
            guard let url = link.trailers?.trimmingCharacters(in: .whitespacesAndNewlines),
                  url.hasPrefix("https://") || url.hasPrefix("http://"),
                  URL(string: url) != nil else { return nil }
            return TopShelfTrailerLink(url: url, provider: link.provider ?? "")
        }
    }

    private static func lookup(_ url: URL) async -> Lookup {
        var request = URLRequest(url: url)
        request.setValue("NuvioTV/1.0", forHTTPHeaderField: "User-Agent")
        guard let result = try? await session.data(for: request),
              let http = result.1 as? HTTPURLResponse else { return .failed }
        if http.statusCode == 404 { return .missing }
        guard (200...299).contains(http.statusCode) else { return .failed }
        guard let listed = links(from: result.0) else { return .failed }
        guard let best = TopShelfTrailerPicker.best(listed) else { return .missing }
        return .found(best)
    }

    private static func canonicalIMDbID(_ text: String) -> String? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard candidate.hasPrefix("tt"), candidate.count > 2,
              candidate.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return candidate
    }

    /// The content types Nuvio treats as series (`NuvioMeta.isSeriesType`).
    private static func isSeries(_ type: String) -> Bool {
        [
            "series", "show", "shows", "tv", "tvshow", "tvshows",
            "tv_series", "tv-series", "tv_show", "tv-show",
            "anime", "miniseries", "mini-series", "mini_series", "serial"
        ].contains(type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
}
