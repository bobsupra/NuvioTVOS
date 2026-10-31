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
        var lookups: [(contentId: String, url: URL)] = []
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.contentId).inserted {
            guard TopShelfTrailerStore.needsLookup(saved[entry.contentId], now: now),
                  let url = lookupURL(for: entry) else { continue }
            lookups.append((entry.contentId, url))
        }

        let results = await withTaskGroup(of: (String, Lookup).self) { group -> [String: Lookup] in
            for lookup in lookups {
                group.addTask { (lookup.contentId, await self.lookup(lookup.url)) }
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
        return records.compactMapValues(\.link)
    }

    /// Trailerio's page for the title, by its IMDb id. Nil for titles without
    /// one (Kitsu, TMDB-only add-on ids).
    static func lookupURL(for entry: TopShelfEntry) -> URL? {
        let candidates = [entry.imdbId, entry.contentId.split(separator: ":").first.map(String.init)]
        guard let imdbID = candidates.lazy.compactMap({ $0.flatMap(canonicalIMDbID) }).first else { return nil }
        let kind = isSeries(entry.contentType) ? "series" : "movie"
        return URL(string: "https://trailerio.cc/meta/\(kind)/\(imdbID).json")
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
