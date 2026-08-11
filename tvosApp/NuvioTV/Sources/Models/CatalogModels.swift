//
//  CatalogModels.swift
//  NuvioTV
//
//  Swift data models for catalog browsing
//

import Foundation

// MARK: - Catalog Models

/// Catalog collection with items
struct NuvioCatalog: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let itemIds: [String]
    let items: [NuvioMeta]?
    let contentType: String?
    let catalogId: String?
    /// Source add-on for Home pagination. Nil means the built-in Cinemeta base.
    let addonId: String?
    /// The source add-on's display name ("Cinemeta", "AIOStreams | ElfHosted"),
    /// resolved from its manifest while the row was loaded. Settings shows it
    /// under the row title so two add-ons offering a "Trending" catalog can be
    /// told apart, the way the Android client labels its rows.
    let addonName: String?
    /// Required genre extra used for the initial add-on request, if any.
    let catalogGenre: String?

    init(
        id: String,
        name: String,
        description: String,
        itemIds: [String],
        items: [NuvioMeta]? = nil,
        contentType: String? = nil,
        catalogId: String? = nil,
        addonId: String? = nil,
        addonName: String? = nil,
        catalogGenre: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.itemIds = itemIds
        self.items = items
        self.contentType = contentType
        self.catalogId = catalogId
        self.addonId = addonId
        self.addonName = addonName
        self.catalogGenre = catalogGenre
    }
}

/// A rating returned by an external metadata provider such as IMDb or TMDB.
struct NuvioExternalRating: Codable, Hashable, Identifiable {
    let source: String
    let value: Double

    var id: String { source }
}

/// Content metadata
struct NuvioMeta: Identifiable, Codable {
    let id: String
    let name: String
    let description: String?
    let posterUrl: String?
    let backgroundUrl: String?
    let logoUrl: String?
    let imdbId: String?
    let tmdbId: Int?
    let type: String
    let year: Int?
    let genres: [String]?
    let rating: Double?
    let releaseInfo: String?
    let runtime: String?
    let cast: [String]?
    let director: [String]?
    let writer: [String]?
    let certification: String?
    let country: String?
    let released: String?
    /// Series release status from Cinemeta ("Ended", "Continuing"). nil for movies.
    let status: String?
    /// Series episodes (Stremio `videos`). nil/empty for movies.
    let videos: [NuvioVideo]?
    /// YouTube trailer ids from Cinemeta `trailers` / `trailerStreams`.
    let trailerYtIds: [String]?
    /// Optional ratings fetched from the user's enabled MDBList providers.
    /// This is transient enrichment and is intentionally omitted from compact
    /// library/watch-state snapshots.
    let externalRatings: [NuvioExternalRating]?

    var isSeries: Bool { type == "series" }

    /// Compact copy for watched / library-style persistence.
    /// Drops the full episode guide (can be huge) and non-finite ratings so a
    /// single bad `Double.nan` cannot make `JSONEncoder` silently drop the
    /// entire watched list (Continue Watching already guards against this).
    var persistenceSnapshot: NuvioMeta {
        NuvioMeta(
            id: id,
            name: name,
            description: description,
            posterUrl: posterUrl,
            backgroundUrl: backgroundUrl,
            logoUrl: logoUrl,
            imdbId: imdbId,
            tmdbId: tmdbId,
            type: type,
            year: year,
            genres: genres,
            rating: rating.flatMap { $0.isFinite ? $0 : nil },
            releaseInfo: releaseInfo,
            runtime: runtime,
            cast: cast,
            director: director,
            writer: writer,
            certification: certification,
            country: country,
            released: released,
            status: status,
            videos: nil,
            trailerYtIds: trailerYtIds,
            externalRatings: nil
        )
    }

    /// Series status badge text ("ONGOING" / "ENDED"); nil for movies or
    /// when Cinemeta didn't provide a status. Shared by the details header
    /// and the Home hero.
    var statusBadgeLabel: String? {
        guard isSeries,
              let status = status?.trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty else { return nil }
        return status.caseInsensitiveCompare("Continuing") == .orderedSame ? "ONGOING" : status.uppercased()
    }

    /// Add-on catalog cards commonly omit fields that are available from their
    /// full `/meta` response. Keep the catalog's artwork/copy intact while
    /// filling the two fields Home's hero cannot otherwise display.
    var needsHeroMetadataEnrichment: Bool {
        let hasRuntime = runtime?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return !hasRuntime || (isSeries && !hasStatus)
    }

    func fillingMissingHeroMetadata(from fullMeta: NuvioMeta) -> NuvioMeta {
        let resolvedRuntime = runtime?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? runtime
            : fullMeta.runtime
        let resolvedStatus = status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? status
            : fullMeta.status

        return NuvioMeta(
            id: id,
            name: name,
            description: description,
            posterUrl: posterUrl,
            backgroundUrl: backgroundUrl,
            logoUrl: logoUrl,
            imdbId: imdbId ?? fullMeta.imdbId,
            tmdbId: tmdbId ?? fullMeta.tmdbId,
            type: type,
            year: year,
            genres: genres,
            rating: rating,
            releaseInfo: releaseInfo,
            runtime: resolvedRuntime,
            cast: cast,
            director: director,
            writer: writer,
            certification: certification,
            country: country,
            released: released,
            status: resolvedStatus,
            videos: videos,
            trailerYtIds: trailerYtIds,
            externalRatings: externalRatings
        )
    }

    func withExternalRatings(_ ratings: [NuvioExternalRating]) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: name,
            description: description,
            posterUrl: posterUrl,
            backgroundUrl: backgroundUrl,
            logoUrl: logoUrl,
            imdbId: imdbId,
            tmdbId: tmdbId,
            type: type,
            year: year,
            genres: genres,
            rating: rating,
            releaseInfo: releaseInfo,
            runtime: runtime,
            cast: cast,
            director: director,
            writer: writer,
            certification: certification,
            country: country,
            released: released,
            status: status,
            videos: videos,
            trailerYtIds: trailerYtIds,
            externalRatings: ratings.isEmpty ? nil : ratings
        )
    }

    init(
        id: String,
        name: String,
        description: String?,
        posterUrl: String?,
        backgroundUrl: String?,
        logoUrl: String?,
        imdbId: String?,
        tmdbId: Int?,
        type: String,
        year: Int?,
        genres: [String]?,
        rating: Double?,
        releaseInfo: String?,
        runtime: String?,
        cast: [String]?,
        director: [String]?,
        writer: [String]?,
        certification: String?,
        country: String?,
        released: String?,
        status: String? = nil,
        videos: [NuvioVideo]? = nil,
        trailerYtIds: [String]? = nil,
        externalRatings: [NuvioExternalRating]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.posterUrl = posterUrl
        self.backgroundUrl = backgroundUrl
        self.logoUrl = logoUrl
        self.imdbId = imdbId
        self.tmdbId = tmdbId
        self.type = type
        self.year = year
        self.genres = genres
        self.rating = rating
        self.releaseInfo = releaseInfo
        self.runtime = runtime
        self.cast = cast
        self.director = director
        self.writer = writer
        self.certification = certification
        self.country = country
        self.released = released
        self.status = status
        self.videos = videos
        self.trailerYtIds = trailerYtIds
        self.externalRatings = externalRatings
    }
}

/// A single series episode (Stremio `videos[]`).
struct NuvioVideo: Identifiable, Codable, Hashable {
    let id: String          // e.g. "tt0903747:1:1"
    let title: String
    let season: Int
    let episode: Int
    let thumbnail: String?
    let overview: String?
    let released: String?
    let rating: String?
}

enum EpisodeReleasePolicy {
    static let showUnairedNextUpKey = "nuvio.tv.settings.layout.showUnairedNextUp"
    static let upcomingNextSeasonWindowDays = 7
    /// The window during which an aired up-next episode is presented as new.
    static let newEpisodeWindowDays = 60

    static var showUnairedNextUp: Bool {
        if ProfileSettings.current.object(forKey: showUnairedNextUpKey) == nil {
            return true
        }
        return ProfileSettings.current.bool(forKey: showUnairedNextUpKey)
    }

    static func hasAired(_ released: String?) -> Bool {
        guard let releaseDay = isoDay(released) else { return true }
        return releaseDay < todayIsoDay()
    }

    /// Episodes dated today are still unaired by this date-only policy, but
    /// deserve to remain visible even when future Up Next suggestions are off.
    static func isAiringToday(_ released: String?) -> Bool {
        isoDay(released) == todayIsoDay()
    }

    static func shouldSurfaceNextEpisode(
        watchedSeason: Int?,
        candidateSeason: Int?,
        released: String?
    ) -> Bool {
        let isSeasonRollover = seasonSortKey(candidateSeason ?? 0) != seasonSortKey(watchedSeason ?? 0)
        if !isSeasonRollover {
            return showUnairedNextUp || isAiringToday(released) || hasAired(released)
        }
        if hasAired(released), isoDate(released) != nil {
            return true
        }
        if isAiringToday(released) {
            return true
        }
        guard showUnairedNextUp,
              let releaseDate = isoDate(released) else {
            return false
        }
        let days = Calendar.current.dateComponents([.day], from: today(), to: releaseDate).day
        return days.map { (0...upcomingNextSeasonWindowDays).contains($0) } ?? false
    }

    static func airDateText(for released: String?) -> String? {
        guard let released, !hasAired(released) else { return nil }
        if isAiringToday(released) {
            return "Today"
        }
        return NuvioDateDisplay.formattedDate(released) ?? released.prefix(10).description
    }

    /// True when `released` is a real date within the last `days` days. A missing
    /// or unparseable date returns false, so uncertain entries read as "Next Up"
    /// rather than over-claiming "New Episode".
    static func isRecentlyReleased(_ released: String?, within days: Int) -> Bool {
        guard let releaseDate = isoDate(released),
              let elapsed = Calendar.current.dateComponents([.day], from: releaseDate, to: today()).day else {
            return false
        }
        return (0...days).contains(elapsed)
    }

    /// True when an aired up-next episode is a genuine new drop rather than a
    /// backlog entry.
    ///
    /// Recency alone is not enough: an episode that was already out when the
    /// viewer finished the previous one is something they are behind on, not
    /// news, however recently it aired. So it also has to have released *after*
    /// the seeding episode was watched — the same rule the Android client's
    /// release-alert state uses (`calculateReleaseAlertState`).
    static func isNewEpisodeDrop(released: String?, seedWatchedAt: Date) -> Bool {
        guard let releaseDate = releaseDate(for: released),
              releaseDate > seedWatchedAt else { return false }
        return isRecentlyReleased(released, within: newEpisodeWindowDays)
    }

    /// The calendar day `released` names, as a local-midnight date. Nil for a
    /// missing or unparseable value.
    static func releaseDate(for released: String?) -> Date? { isoDate(released) }

    private static func isoDate(_ value: String?) -> Date? {
        guard let day = isoDay(value) else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone.current
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return components.date
    }

    private static func isoDay(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count >= 10 else { return nil }
        let day = String(raw.prefix(10))
        guard day.split(separator: "-").count == 3 else { return nil }
        return day
    }

    private static func todayIsoDay() -> String {
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone.current, from: Date())
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func today() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    private static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }
}

/// Catalog-level completion for series. Specials are excluded, and an episode
/// dated today or later does not hold back the badge until it has aired under
/// the app's existing date-only release policy.
enum CatalogWatchedPolicy {
    static func hasWatchedAllAiredEpisodes(
        videos: [NuvioVideo]?,
        watchedEpisodeKeys: Set<String>
    ) -> Bool {
        let airedEpisodes = (videos ?? []).filter {
            $0.season > 0 && $0.episode > 0 && EpisodeReleasePolicy.hasAired($0.released)
        }
        guard !airedEpisodes.isEmpty else { return false }
        return airedEpisodes.allSatisfy {
            watchedEpisodeKeys.contains("\($0.season):\($0.episode)")
        }
    }
}

enum UpNextEpisodeSelectionPolicy {
    static let preferenceKey = "nuvio.tv.settings.layout.upNextFromFurthestEpisode"

    static var prefersFurthestEpisode: Bool {
        if ProfileSettings.current.object(forKey: preferenceKey) == nil {
            return true
        }
        return ProfileSettings.current.bool(forKey: preferenceKey)
    }

    static func prefers(
        candidateSeason: Int,
        candidateEpisode: Int,
        candidateWatchedAt: Date,
        over currentSeason: Int,
        currentEpisode: Int,
        currentWatchedAt: Date,
        preferFurthestEpisode: Bool
    ) -> Bool {
        if preferFurthestEpisode {
            if candidateSeason != currentSeason {
                return candidateSeason > currentSeason
            }
            if candidateEpisode != currentEpisode {
                return candidateEpisode > currentEpisode
            }
            return candidateWatchedAt > currentWatchedAt
        }
        if candidateWatchedAt != currentWatchedAt {
            return candidateWatchedAt > currentWatchedAt
        }
        if candidateSeason != currentSeason {
            return candidateSeason > currentSeason
        }
        return candidateEpisode > currentEpisode
    }
}

/// Shared title-level release filtering. A year-only check misses titles dated
/// later in the current year, which is the common shape returned by metadata
/// providers.
enum ContentReleasePolicy {
    static func isUnreleased(_ meta: NuvioMeta, today: String? = nil) -> Bool {
        let today = today ?? todayIsoDay()

        if let released = isoDay(meta.released) {
            return released > today
        }
        if let releaseInfo = isoDay(meta.releaseInfo) {
            return releaseInfo > today
        }

        guard let releaseYear = meta.year ?? leadingYear(meta.releaseInfo),
              let currentYear = Int(today.prefix(4)) else {
            return false
        }
        return releaseYear > currentYear
    }

    private static func isoDay(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.count >= 10 else {
            return nil
        }
        let day = String(raw.prefix(10))
        let parts = day.split(separator: "-")
        guard parts.count == 3,
              parts[0].count == 4,
              parts[1].count == 2,
              parts[2].count == 2,
              parts.allSatisfy({ Int($0) != nil }) else {
            return nil
        }
        return day
    }

    private static func leadingYear(_ value: String?) -> Int? {
        guard let value, value.count >= 4 else { return nil }
        return Int(value.prefix(4))
    }

    static func todayIsoDay() -> String {
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone.current, from: Date())
        guard let year = components.year,
              let month = components.month,
              let day = components.day else {
            return ""
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// Video stream information
struct NuvioSubtitle: Identifiable, Codable, Equatable {
    var id: String { url }
    let url: String
    let language: String
    let label: String?
    /// Where the subtitle came from ("OpenSubtitles v3", stream add-on name);
    /// shown as the badge in the player's subtitle picker.
    var source: String? = nil
}

struct NuvioStream: Identifiable, Codable {
    /// Stable identity for lists and focus. Prefer URL / torrent key; never mint a
    /// fresh UUID on each access (that forces full SwiftUI list rebuilds).
    var id: String {
        if let url, !url.isEmpty { return url }
        if let infoHash, !infoHash.isEmpty {
            return "\(infoHash):\(fileIdx ?? -1)"
        }
        // Deterministic content fallback for rare shells with no playable key.
        return "stream:\(name ?? "")|\(description ?? "")|\(addonName ?? "")|\(filename ?? "")"
    }
    let url: String?
    let name: String?
    let description: String?
    let addonName: String?
    let subtitles: [NuvioSubtitle]
    /// The source add-on's manifest `logo`, shown on the stream card instead of a
    /// generic placeholder. `nil` when the add-on manifest has no logo.
    let addonLogoURL: String?
    /// Torrent info-hash from add-ons like Torrentio. Present when the add-on
    /// returns a torrent instead of a direct URL; a debrid provider turns this
    /// into a playable link. See `Core/Debrid`.
    let infoHash: String?
    /// Index of the wanted file inside the torrent (for multi-file torrents).
    let fileIdx: Int?
    /// Optional tracker/DHT hints the add-on attaches to the torrent.
    let sources: [String]
    /// Suggested filename for the wanted file, used by some debrid file pickers.
    let filename: String?
    /// Stremio `behaviorHints.videoSize`, retained for the Android-compatible
    /// stream file-size badge.
    let videoSize: Int64?
    /// Stremio `behaviorHints.bingeGroup` — same release group for episode autoplay.
    let bingeGroup: String?
    /// Explicit cached flag from the add-on when present; otherwise inferred from text.
    let isCached: Bool?
    /// Per-stream request headers supplied by a Stremio add-on through
    /// `behaviorHints.proxyHeaders.request`. Some hosts reject playback without
    /// the add-on's Referer or User-Agent.
    let httpHeaders: [String: String]?

    init(
        url: String?,
        name: String?,
        description: String?,
        addonName: String?,
        subtitles: [NuvioSubtitle] = [],
        addonLogoURL: String? = nil,
        infoHash: String? = nil,
        fileIdx: Int? = nil,
        sources: [String] = [],
        filename: String? = nil,
        videoSize: Int64? = nil,
        bingeGroup: String? = nil,
        isCached: Bool? = nil,
        httpHeaders: [String: String]? = nil
    ) {
        self.url = url
        self.name = name
        self.description = description
        self.addonName = addonName
        self.subtitles = subtitles
        self.addonLogoURL = addonLogoURL
        self.infoHash = infoHash
        self.fileIdx = fileIdx
        self.sources = sources
        self.filename = filename
        self.videoSize = videoSize
        self.bingeGroup = bingeGroup
        self.isCached = isCached
        self.httpHeaders = httpHeaders
    }

    /// A stream that has no direct URL but carries a torrent info-hash: it must
    /// be run through a debrid provider before it can play.
    var isDebridResolvable: Bool {
        (url?.isEmpty ?? true) && (infoHash?.isEmpty == false)
    }

    /// True when the stream is known or strongly labeled as debrid-cached.
    var isLikelyCached: Bool {
        StreamQualityTags.parse(stream: self).isCached
    }

    /// Returns a copy tagged with the source add-on's logo. Used to attach the
    /// logo after streams are fetched, so the logo lookup never blocks them.
    func withAddonLogoURL(_ logo: String?) -> NuvioStream {
        NuvioStream(
            url: url, name: name, description: description, addonName: addonName,
            subtitles: subtitles, addonLogoURL: logo, infoHash: infoHash,
            fileIdx: fileIdx, sources: sources, filename: filename, videoSize: videoSize,
            bingeGroup: bingeGroup, isCached: isCached, httpHeaders: httpHeaders
        )
    }

    /// Merges external subtitle-add-on results without dropping torrent metadata
    /// (infoHash, fileIdx, sources, filename) or branding (logo, addon name).
    func mergingExternalSubtitles(_ external: [NuvioSubtitle]) -> NuvioStream {
        guard !external.isEmpty else { return self }
        var seen = Set(subtitles.map(\.url))
        var merged = subtitles
        for subtitle in external where seen.insert(subtitle.url).inserted {
            merged.append(subtitle)
        }
        return NuvioStream(
            url: url,
            name: name,
            description: description,
            addonName: addonName,
            subtitles: merged,
            addonLogoURL: addonLogoURL,
            infoHash: infoHash,
            fileIdx: fileIdx,
            sources: sources,
            filename: filename,
            videoSize: videoSize,
            bingeGroup: bingeGroup,
            isCached: isCached,
            httpHeaders: httpHeaders
        )
    }
}

/// One add-on's stream results in the progressive picker, matching Android's
/// `AddonStreamGroup`: created as loading before requests start, then updated
/// independently as that add-on completes, fails, or times out.
struct AddonStreamGroup: Identifiable {
    var id: String { addonId }
    /// Stable identity (manifest URL / manifest id) — never the display name.
    let addonId: String
    let displayName: String
    var streams: [NuvioStream]
    var isLoading: Bool
    var error: String?

    init(
        addonId: String,
        displayName: String,
        streams: [NuvioStream] = [],
        isLoading: Bool = true,
        error: String? = nil
    ) {
        self.addonId = addonId
        self.displayName = displayName
        self.streams = streams
        self.isLoading = isLoading
        self.error = error
    }
}

enum StreamsEmptyStateReason: Equatable {
    case noAddonsConfigured
    case noCompatibleAddons
    case noStreamsFound
}

/// Shared stream-discovery snapshot observed by Details and reused when
/// returning from playback for the same request key.
struct StreamsDiscoveryState {
    var requestKey: String? = nil
    /// Monotonic publication counter. Advances whenever the repository replaces
    /// this snapshot, including metadata-only updates with unchanged stream ids.
    var revision: UInt64 = 0
    var groups: [AddonStreamGroup] = []
    var isAnyLoading: Bool = false
    var emptyStateReason: StreamsEmptyStateReason? = nil
    /// True once this request finished its initial setup (even if empty).
    var hasResolvedTargets: Bool = false

    var allStreams: [NuvioStream] {
        groups.flatMap(\.streams)
    }

    var hasAnyStreams: Bool {
        groups.contains { !$0.streams.isEmpty }
    }
}

enum PlaybackMarkers {
    static let trailerSubtitle = "Trailer"
}

enum EpisodeTagResolver {
    static func episodeNumbers(in text: String) -> (season: Int, episode: Int)? {
        let patterns = [
            #"(?i)(?:^|[^A-Za-z0-9])S(\d{1,2})[\s._-]*E(\d{1,3})(?:[^A-Za-z0-9]|$)"#,
            #"(?i)(?:^|[^A-Za-z0-9])(\d{1,2})x(\d{1,3})(?:[^A-Za-z0-9]|$)"#,
            #"(?i)(?:season|s)[\s._-]*(\d{1,2})[\s._-]*(?:episode|ep|e)[\s._-]*(\d{1,3})"#,
            #"(?i)(?:^|[^A-Za-z0-9])tt\d+:(\d{1,2}):(\d{1,3})(?:[^A-Za-z0-9]|$)"#
        ]

        for pattern in patterns {
            guard let match = text.range(of: pattern, options: .regularExpression) else { continue }
            let numbers = text[match]
                .components(separatedBy: CharacterSet.decimalDigits.inverted)
                .filter { !$0.isEmpty }
                .compactMap { Int($0) }

            if numbers.count >= 2 {
                return (numbers[numbers.count - 2], numbers[numbers.count - 1])
            }
        }

        return nil
    }
}

struct TrailerPlaybackSource {
    let videoUrl: String
    let audioUrl: String?
}

struct ContinueWatchingItem: Identifiable, Codable {
    var id: String { meta.id }
    let meta: NuvioMeta
    let streamUrl: String
    let position: Double
    let duration: Double
    let lastWatchedAt: Date
    /// Which episode this progress belongs to (nil for movies and for entries
    /// saved before episode tracking existed — optionals keep old JSON decoding).
    let season: Int?
    let episode: Int?
    let released: String?
    /// Fresh episode metadata is stored independently from `meta.videos` so a
    /// placeholder episode guide entry (for example "TBA") can be corrected
    /// without discarding the rest of the series metadata.
    let episodeTitleOverride: String?
    let episodeOverviewOverride: String?
    let episodeThumbnailOverride: String?
    /// True when this entry is a fresh next-episode suggestion (the previous
    /// episode was finished) rather than real playback progress. Optional so
    /// old persisted JSON keeps decoding.
    let isUpNext: Bool?
    /// Which season the finished episode that seeded this suggestion belonged to.
    /// `season` above is the *suggested* episode's, so the two are the only way
    /// to tell a season rollover from a step within a season. Nil for progress
    /// entries, for JSON written before this existed, and wherever the seed is
    /// unknown — a rollover is then simply not claimed.
    let upNextSeedSeason: Int?

    /// The episode this entry points at, resolved once at construction.
    ///
    /// Everything below — the title, the artwork, the overview, the aired check,
    /// the badge — used to re-derive this on every read, and the derivation walks
    /// `meta.videos` end to end. A card's body reads four or five of them, and
    /// SwiftUI re-evaluates that body repeatedly while the row scrolls, so a
    /// long-running series had its whole episode guide scanned several times per
    /// card per frame. Derived state, so it is deliberately absent from the
    /// persisted JSON and rebuilt on decode instead.
    private let resolved: ResolvedEpisode

    private struct ResolvedEpisode {
        let numbers: (season: Int, episode: Int)?
        let video: NuvioVideo?
    }

    var isUpNextEntry: Bool { isUpNext == true }
    /// The episode guide travels with refreshed metadata. Prefer it over the
    /// stored enrichment override so an air-date correction is reflected without
    /// waiting for a progress record to be rebuilt.
    private var effectiveEpisodeReleaseDate: String? { episodeVideo?.released ?? released }
    var hasAired: Bool { EpisodeReleasePolicy.hasAired(effectiveEpisodeReleaseDate) }
    var isAiringToday: Bool { EpisodeReleasePolicy.isAiringToday(effectiveEpisodeReleaseDate) }
    var airDateText: String? { EpisodeReleasePolicy.airDateText(for: effectiveEpisodeReleaseDate) }
    var upNextBadgeText: String {
        guard isUpNextEntry else { return remainingText }
        if hasAired {
            if isNewSeasonDrop { return "NEW SEASON" }
            return isNewEpisodeDrop ? "NEW EPISODE" : "NEXT UP"
        }
        if let airDateText { return "AIRS \(airDateText.uppercased())" }
        return "UPCOMING"
    }

    /// An aired up-next episode reads as a "New Episode" drop only while it is
    /// inside the release-alert window *and* it aired after the episode that
    /// seeded this card was watched — `lastWatchedAt` on an up-next entry is the
    /// finished episode's timestamp, not this one's. Without the second half a
    /// show the viewer is simply behind on claims a drop it never had: the badge
    /// said "New Episode" for any episode released in the last two months, even
    /// one that was already out weeks before they watched the previous one.
    var isNewEpisodeDrop: Bool {
        isUpNextEntry && hasAired && EpisodeReleasePolicy.isNewEpisodeDrop(
            released: effectiveEpisodeReleaseDate,
            seedWatchedAt: lastWatchedAt
        )
    }

    /// A new drop that also crosses a season boundary — a returning show rather
    /// than the next episode of one already running, which is the more useful
    /// thing to say. Both season numbers have to be known, so a card whose seed
    /// season was never recorded stays "New Episode" instead of guessing.
    /// Android's `isNewSeasonRelease` reads the same way.
    var isNewSeasonDrop: Bool {
        guard isNewEpisodeDrop,
              let upNextSeedSeason,
              let season = resolved.numbers?.season else { return false }
        return season != upNextSeedSeason
    }

    /// Where this card sits in the row's newest-first order.
    ///
    /// A genuine drop is ranked by when it aired, not by when the viewer finished
    /// the previous episode — otherwise a show they have been away from for
    /// months sinks to the bottom of the row on the very day it comes back, which
    /// is exactly the day it deserves the top. Everything else keeps its watch
    /// time, so this only ever promotes a card the badge already calls news.
    /// Mirrors the Android client's `sortTimestamp`.
    var recencySortDate: Date {
        guard isNewEpisodeDrop,
              let releaseDate = EpisodeReleasePolicy.releaseDate(
                for: effectiveEpisodeReleaseDate
              ) else { return lastWatchedAt }
        return releaseDate
    }

    init(
        meta: NuvioMeta,
        streamUrl: String,
        position: Double,
        duration: Double,
        lastWatchedAt: Date,
        season: Int? = nil,
        episode: Int? = nil,
        released: String? = nil,
        episodeTitleOverride: String? = nil,
        episodeOverviewOverride: String? = nil,
        episodeThumbnailOverride: String? = nil,
        isUpNext: Bool? = nil,
        upNextSeedSeason: Int? = nil
    ) {
        self.meta = meta
        self.streamUrl = streamUrl
        self.position = position
        self.duration = duration
        self.lastWatchedAt = lastWatchedAt
        self.season = season
        self.episode = episode
        self.released = released
        self.episodeTitleOverride = episodeTitleOverride
        self.episodeOverviewOverride = episodeOverviewOverride
        self.episodeThumbnailOverride = episodeThumbnailOverride
        self.isUpNext = isUpNext
        self.upNextSeedSeason = upNextSeedSeason
        self.resolved = Self.resolveEpisode(
            meta: meta,
            streamUrl: streamUrl,
            season: season,
            episode: episode
        )
    }

    /// Decoding rebuilds the resolved episode rather than reading it: it is
    /// derived from `meta` and the stored numbers, so keeping it out of the JSON
    /// leaves the persisted shape (and every older payload) untouched.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decode(NuvioMeta.self, forKey: .meta)
        streamUrl = try container.decode(String.self, forKey: .streamUrl)
        position = try container.decode(Double.self, forKey: .position)
        duration = try container.decode(Double.self, forKey: .duration)
        lastWatchedAt = try container.decode(Date.self, forKey: .lastWatchedAt)
        season = try container.decodeIfPresent(Int.self, forKey: .season)
        episode = try container.decodeIfPresent(Int.self, forKey: .episode)
        released = try container.decodeIfPresent(String.self, forKey: .released)
        episodeTitleOverride = try container.decodeIfPresent(String.self, forKey: .episodeTitleOverride)
        episodeOverviewOverride = try container.decodeIfPresent(String.self, forKey: .episodeOverviewOverride)
        episodeThumbnailOverride = try container.decodeIfPresent(String.self, forKey: .episodeThumbnailOverride)
        isUpNext = try container.decodeIfPresent(Bool.self, forKey: .isUpNext)
        upNextSeedSeason = try container.decodeIfPresent(Int.self, forKey: .upNextSeedSeason)
        resolved = Self.resolveEpisode(
            meta: meta,
            streamUrl: streamUrl,
            season: season,
            episode: episode
        )
    }

    /// Only the stored fields; `resolved` is derived and never encoded.
    private enum CodingKeys: String, CodingKey {
        case meta
        case streamUrl
        case position
        case duration
        case lastWatchedAt
        case season
        case episode
        case released
        case episodeTitleOverride
        case episodeOverviewOverride
        case episodeThumbnailOverride
        case isUpNext
        case upNextSeedSeason
    }

    /// Episode numbers for display, plus the guide entry they point at. Entries
    /// saved before episode tracking have nil season/episode; for those, fall
    /// back to a stream filename tag when possible, then to the first playable
    /// episode in stored series metadata.
    private static func resolveEpisode(
        meta: NuvioMeta,
        streamUrl: String,
        season: Int?,
        episode: Int?
    ) -> ResolvedEpisode {
        guard let numbers = resolveNumbers(
            meta: meta,
            streamUrl: streamUrl,
            season: season,
            episode: episode
        ) else {
            return ResolvedEpisode(numbers: nil, video: nil)
        }
        let video = meta.videos?.first {
            $0.season == numbers.season && $0.episode == numbers.episode
        }
        return ResolvedEpisode(numbers: numbers, video: video)
    }

    private static func resolveNumbers(
        meta: NuvioMeta,
        streamUrl: String,
        season: Int?,
        episode: Int?
    ) -> (season: Int, episode: Int)? {
        if let season, let episode { return (season, episode) }
        guard meta.isSeries else { return nil }
        if let numbers = EpisodeTagResolver.episodeNumbers(in: streamUrl) {
            return numbers
        }
        return firstPlayableEpisode(in: meta).map { ($0.season, $0.episode) }
    }

    private static func firstPlayableEpisode(in meta: NuvioMeta) -> NuvioVideo? {
        guard let videos = meta.videos, !videos.isEmpty else { return nil }
        let sorted = videos.sorted {
            (seasonSortKey($0.season), $0.episode) < (seasonSortKey($1.season), $1.episode)
        }
        return sorted.first { $0.season > 0 } ?? sorted.first
    }

    private static func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
    }

    private var resolvedNumbers: (season: Int, episode: Int)? {
        resolved.numbers
    }

    var episodeNumbers: (season: Int, episode: Int)? {
        resolved.numbers
    }

    /// "S1 E3 · Title" line for the episode in progress; nil when unknown.
    var episodeDisplayLine: String? {
        guard let label = episodeLabel else { return nil }
        if let title = episodeDisplayTitle {
            return "\(label) · \(title)"
        }
        return label
    }

    /// "S1 E3" label for the episode in progress; nil when unknown.
    var episodeLabel: String? {
        guard let numbers = resolvedNumbers else { return nil }
        return "S\(numbers.season) E\(numbers.episode)"
    }

    /// The full episode entry from the stored series meta, carrying the
    /// episode's title and overview for display.
    var episodeVideo: NuvioVideo? {
        resolved.video
    }

    var episodeDisplayTitle: String? {
        meaningfulEpisodeText(episodeTitleOverride) ?? meaningfulEpisodeText(episodeVideo?.title)
    }

    var episodeOverview: String? {
        meaningfulEpisodeText(episodeOverviewOverride) ?? meaningfulEpisodeText(episodeVideo?.overview)
    }

    var episodeArtworkURL: String? {
        episodeThumbnailOverride ?? episodeVideo?.thumbnail
    }

    /// Player-style episode line ("S1 · E3 · Title"); nil when unknown.
    var episodeSubtitle: String? {
        guard let numbers = resolvedNumbers else { return nil }
        let title = episodeDisplayTitle ?? "Episode \(numbers.episode)"
        return "S\(numbers.season) · E\(numbers.episode) · \(title)"
    }

    private func meaningfulEpisodeText(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.caseInsensitiveCompare("TBA") != .orderedSame else {
            return nil
        }
        return value
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var resumePosition: Double {
        max(0, min(position, max(duration - 5, 0)))
    }

    var remainingText: String {
        // Synced rows can arrive without a runtime; there is no honest number to
        // show for those, so offer the action instead.
        guard duration > 0 else { return "RESUME" }
        let remaining = max(0, duration - position)
        let minutes = Int(remaining / 60)
        let hours = minutes / 60
        let remainder = minutes % 60

        if hours > 0 {
            return "\(hours)h \(remainder)m left"
        }
        return "\(max(minutes, 1))m left"
    }
}

/// Orders the Continue Watching row.
///
/// Every recency comparison here reads `recencySortDate` rather than
/// `lastWatchedAt`: the two differ only for a genuine new drop, which ranks by
/// its air date so a returning show surfaces the day it returns instead of at
/// the age of the episode that seeded it. "Default" is ordered by the same key
/// before it ever reaches this type — see `refreshContinueWatching()`.
enum ContinueWatchingSortPolicy {
    static func sorted(_ items: [ContinueWatchingItem], preference: String) -> [ContinueWatchingItem] {
        switch preference {
        case "Recently watched":
            return items.enumerated()
                .sorted { lhs, rhs in
                    if lhs.element.recencySortDate != rhs.element.recencySortDate {
                        return lhs.element.recencySortDate > rhs.element.recencySortDate
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
        case "Release order":
            return items.enumerated()
                .sorted { lhs, rhs in
                    let left = releaseKey(lhs.element)
                    let right = releaseKey(rhs.element)
                    if left != right { return left > right }
                    if lhs.element.recencySortDate != rhs.element.recencySortDate {
                        return lhs.element.recencySortDate > rhs.element.recencySortDate
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
        case "Next up":
            return items.enumerated()
                .sorted { lhs, rhs in
                    if lhs.element.isUpNextEntry != rhs.element.isUpNextEntry {
                        return lhs.element.isUpNextEntry
                    }
                    if lhs.element.recencySortDate != rhs.element.recencySortDate {
                        return lhs.element.recencySortDate > rhs.element.recencySortDate
                    }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)
        default:
            return items
        }
    }

    private static func releaseKey(_ item: ContinueWatchingItem) -> String {
        for value in [item.released, item.episodeVideo?.released, item.meta.released] {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                continue
            }
            return value
        }
        return item.meta.year.map { String(format: "%04d", $0) } ?? ""
    }
}

enum ContinueWatchingStore {
    /// Posted whenever the list changes (progress saved, item removed, profile
    /// switched) so views like Home can refresh their Continue Watching row
    /// without relying on `onAppear` — which no longer re-fires now that Home
    /// stays mounted behind the Details/Player overlays.
    static let changedNotification = Notification.Name("nuvio.tv.continueWatching.changed")

    /// Base key. Used on its own for the legacy (pre-profile) shared list and
    /// suffixed with the active profile id for per-profile watch history.
    private static let baseKey = "nuvio.tv.continueWatching.items"
    private static let storageDirectoryName = "nuvio-continue-watching"
    private static let maxItems = 20
    private static let maxEpisodeResumePoints = 200

    /// Continue Watching intentionally keeps one visible row per show. Resume
    /// points cannot share that shape: each episode needs an independent key or
    /// the show's latest row leaks into a different episode.
    private struct EpisodeResumePoint: Codable {
        let metaId: String
        let imdbId: String?
        let tmdbId: Int?
        let season: Int
        let episode: Int
        let episodeId: String?
        let position: Double
        let duration: Double
        let updatedAt: Date
    }

    /// Last durable-storage result, suitable for the on-screen sync diagnostic.
    static private(set) var persistenceDiagnostic = "not attempted"

    /// Decoded rows for `cachedKey`, mirroring ``WatchProgressLedger``'s memo.
    ///
    /// `items()` is not an occasional call: it runs on every Home refresh, every
    /// resume lookup, every Top Shelf write, and once per page the Continue
    /// Watching row materialises. A synced list carries several megabytes of
    /// episode metadata, so decoding it per call put a multi-megabyte
    /// `JSONDecoder` run on the main actor at exactly the moment the user was
    /// scrolling into the next page. Every write path below refreshes or clears
    /// this, because a stale row is worse than a slow one.
    private static var cachedItems: [ContinueWatchingItem]?
    private static var cachedKey: String?

    private static func invalidateCache() {
        cachedItems = nil
        cachedKey = nil
    }

    private enum PersistenceError: LocalizedError {
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .verificationFailed:
                return "the saved progress could not be verified"
            }
        }
    }

    struct DebugSnapshot {
        let profileId: String
        let source: String
        let byteCount: Int
        let decodedCount: Int
        let keptCount: Int
        let decodeError: String?
    }

    /// Identifier of the profile whose watch history is currently active.
    /// Set at launch and whenever the user switches profiles so each profile
    /// keeps its own Continue Watching list (app settings stay shared device-wide).
    private(set) static var activeProfileId: String?

    /// Point the store at a profile. Call on launch and on every profile switch
    /// so reads/writes land in that profile's bucket.
    static func setActiveProfile(_ profileId: String?) {
        activeProfileId = profileId
        // The key check in `items()` already separates profiles; this also covers
        // re-selecting the same profile after the file changed underneath us (a
        // sync pull, or the legacy migration below).
        invalidateCache()
        // The raw ledger is profile-scoped too; it must move first so anything
        // reading progress during this switch sees the new profile's rows.
        WatchProgressLedger.setActiveProfile(profileId)
        ContinueWatchingDismissStore.setActiveProfile(profileId)
        migrateLegacyHistoryIfNeeded()
        // Carry a pre-ledger install's history across, so upgrading users keep
        // their row and it becomes syncable.
        WatchProgressLedger.backfillIfEmpty(from: items())
        // Recover movie rows a rejected payload left marked as synced.
        WatchProgressLedger.repushMoviesOnceIfNeeded()
        // Rebuild Top Shelf on every profile load. Its App Group snapshot may
        // have been cleared by an update or signing change even when the local
        // Continue Watching file is still intact.
        writeTopShelfFeed()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static var storageKey: String { storageKey(for: activeProfileId) }

    private static func storageKey(for profileId: String?) -> String {
        guard let id = profileId, !id.isEmpty else { return baseKey }
        return "\(baseKey).\(id)"
    }

    private static var episodeResumeStorageKey: String {
        episodeResumeStorageKey(for: activeProfileId)
    }

    private static func episodeResumeStorageKey(for profileId: String?) -> String {
        "\(storageKey(for: profileId)).episodeResumePoints.v1"
    }

    static func items() -> [ContinueWatchingItem] {
        let key = storageKey
        if cachedKey == key, let cachedItems {
            return cachedItems
        }
        guard let data = data(for: key) else {
            cachedItems = []
            cachedKey = key
            return []
        }
        let decoded: [ContinueWatchingItem]
        do {
            decoded = try makeDecoder().decode([ContinueWatchingItem].self, from: data)
        } catch {
            // Keep the payload intact so debugSnapshot() can report the actual
            // corruption instead of turning it into an unexplained missing file.
            // Deliberately uncached: a sync pull may rewrite this file moments
            // later, and caching the empty result would hide the recovery.
            persistenceDiagnostic = "decode failed: \(diagnosticText(for: error))"
            return []
        }

        let kept = decoded
            .filter { shouldKeep(position: $0.position, duration: $0.duration) }
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
        cachedItems = kept
        cachedKey = key
        return kept
    }

    static func item(for metaId: String) -> ContinueWatchingItem? {
        items().first { $0.meta.id == metaId }
    }

    /// Accounts for every entry between the stored file and the rendered row.
    ///
    /// A count that drops between these stages is the whole question when a user
    /// reports "only N showed", and each stage discards for a different reason:
    /// the file is capped, `shouldKeep` drops finished playback, and Home hides
    /// unreleased titles when that preference is on.
    static func rowDiagnostic() -> String {
        guard let data = data(for: storageKey) else {
            return "stored file missing (rebuilds from ledger on next Home load)"
        }
        let decoded: [ContinueWatchingItem]
        do {
            decoded = try makeDecoder().decode([ContinueWatchingItem].self, from: data)
        } catch {
            return "stored file unreadable: \(diagnosticText(for: error))"
        }
        let kept = decoded.filter { shouldKeep(position: $0.position, duration: $0.duration) }
        let upNext = kept.filter(\.isUpNextEntry).count
        let unaired = kept.filter { $0.isUpNextEntry && !$0.hasAired }.count
        return "cap \(maxItems); stored \(decoded.count), passing filter \(kept.count), "
            + "of those up-next \(upNext) (unaired \(unaired)); \(persistenceDiagnostic)"
    }

    /// Exact per-episode resume lookup. A series request never falls back to
    /// the show's latest Continue Watching row unless that row identifies the
    /// same season and episode.
    static func resumePosition(
        for meta: NuvioMeta,
        season: Int?,
        episode: Int?,
        episodeId: String? = nil
    ) -> Double? {
        guard meta.isSeries else { return item(for: meta.id)?.resumePosition }
        guard let season, let episode else { return nil }
        let watchedAt = WatchedStore.items().first {
            WatchedStore.sameContent($0.meta, meta)
                && $0.season == season && $0.episode == episode
        }?.watchedAt

        if let point = episodeResumePoints().first(where: {
            resumePoint($0, matches: meta, season: season, episode: episode, episodeId: episodeId)
        }) {
            if let watchedAt, watchedAt >= point.updatedAt { return nil }
            return clampedResume(position: point.position, duration: point.duration)
        }

        // Migration path for progress written before the per-episode ledger.
        guard let legacy = items().first(where: {
            guard $0.meta.id == meta.id, !$0.isUpNextEntry else { return false }
            if let storedSeason = $0.season, let storedEpisode = $0.episode {
                return storedSeason == season && storedEpisode == episode
            }
            return EpisodeTagResolver.episodeNumbers(in: $0.streamUrl).map {
                $0.season == season && $0.episode == episode
            } ?? false
        }) else {
            return nil
        }
        if let watchedAt, watchedAt >= legacy.lastWatchedAt { return nil }
        saveEpisodeResumePoint(
            meta: meta,
            season: season,
            episode: episode,
            episodeId: episodeId,
            position: legacy.position,
            duration: legacy.duration,
            updatedAt: legacy.lastWatchedAt
        )
        return legacy.resumePosition
    }

    /// Read-only storage diagnostics for the on-screen Home failure panel.
    /// It deliberately bypasses `items()` so a corrupt payload is reported
    /// instead of being silently removed before the user can photograph it.
    static func debugSnapshot() -> DebugSnapshot {
        let key = storageKey
        let source: String
        let rawData: Data?
        if let url = storageURL(for: key), let data = try? Data(contentsOf: url) {
            source = "Caches"
            rawData = data
        } else if let match = legacyStorageURLs(for: key).lazy
            .compactMap({ url in (try? Data(contentsOf: url)).map { (url, $0) } })
            .first {
            source = "legacy \(match.0.deletingLastPathComponent().lastPathComponent)"
            rawData = match.1
        } else if let data = UserDefaults.standard.data(forKey: key) {
            source = "UserDefaults (legacy)"
            rawData = data
        } else {
            // Not an error: evicted or not yet built. The ledger rebuilds it.
            source = "missing"
            rawData = nil
        }

        guard let rawData else {
            return DebugSnapshot(
                profileId: activeProfileId ?? "none",
                source: source,
                byteCount: 0,
                decodedCount: 0,
                keptCount: 0,
                decodeError: nil
            )
        }
        do {
            let decoded = try makeDecoder().decode([ContinueWatchingItem].self, from: rawData)
            return DebugSnapshot(
                profileId: activeProfileId ?? "none",
                source: source,
                byteCount: rawData.count,
                decodedCount: decoded.count,
                keptCount: decoded.filter { shouldKeep(position: $0.position, duration: $0.duration) }.count,
                decodeError: nil
            )
        } catch {
            return DebugSnapshot(
                profileId: activeProfileId ?? "none",
                source: source,
                byteCount: rawData.count,
                decodedCount: 0,
                keptCount: 0,
                decodeError: error.localizedDescription
            )
        }
    }

    static func save(
        meta: NuvioMeta,
        streamUrl: String,
        position: Double,
        duration: Double,
        season: Int? = nil,
        episode: Int? = nil,
        episodeId: String? = nil
    ) {
        // A temporarily unavailable MPV time-pos must not erase a valid resume
        // point. Only a coherent, started sample is allowed to replace/remove
        // existing progress.
        guard position.isFinite,
              duration.isFinite,
              position > 0,
              duration >= 60 else { return }

        // Going back to a title retires the removal the user made earlier, so a
        // months-old dismissal can never hide progress they just made.
        ContinueWatchingDismissStore.clear(contentId: meta.id)

        // Record the raw row before any display rule runs. A finished episode is
        // not "nothing to store" — it is precisely the seed that produces the
        // next episode's Next Up card, here and on every other device.
        WatchProgressLedger.upsert(
            WatchProgressRecord(
                progressKey: WatchProgressLedger.progressKey(
                    contentId: meta.id,
                    season: season,
                    episode: episode
                ),
                contentId: meta.id,
                contentType: meta.isSeries ? "series" : "movie",
                videoId: WatchProgressLedger.videoId(
                    contentId: meta.id,
                    season: season,
                    episode: episode
                ),
                season: season,
                episode: episode,
                position: position,
                duration: duration,
                lastWatchedAt: Date(),
                isPendingPush: true
            )
        )

        guard shouldKeep(position: position, duration: duration) else {
            if let season, let episode {
                removeEpisodeResumePoint(meta: meta, season: season, episode: episode)
            }
            remove(metaId: meta.id, retainingLedger: true)
            return
        }

        if meta.isSeries, let season, let episode {
            saveEpisodeResumePoint(
                meta: meta,
                season: season,
                episode: episode,
                episodeId: episodeId,
                position: position,
                duration: duration,
                updatedAt: Date()
            )
        }

        // A save that doesn't know its episode (resume paths that only carry a
        // stream URL) must not erase the episode identity an earlier save recorded.
        let existing = item(for: meta.id)
        let item = ContinueWatchingItem(
            meta: meta,
            streamUrl: streamUrl,
            position: position,
            duration: duration,
            lastWatchedAt: Date(),
            season: season ?? existing?.season,
            episode: episode ?? existing?.episode,
            released: existing?.released
        )
        let updated = ([item] + items().filter { $0.meta.id != meta.id }).prefix(maxItems)
        persist(Array(updated))
    }

    /// Records a genuine watch-through.
    ///
    /// The ledger row becomes a completed row rather than being deleted: that
    /// completed row is exactly what seeds the following episode's Next Up card,
    /// here and on every other device. Position-at-runtime is how the phone
    /// marks a finished row, and it is the only completion signal the sync
    /// payload can carry — there is no `is_completed` column on the wire.
    static func markPlaybackCompleted(
        meta: NuvioMeta,
        duration: Double,
        season: Int? = nil,
        episode: Int? = nil
    ) {
        guard duration.isFinite, duration > 0 else { return }
        ContinueWatchingDismissStore.clear(contentId: meta.id)
        WatchProgressLedger.upsert(
            WatchProgressRecord(
                progressKey: WatchProgressLedger.progressKey(
                    contentId: meta.id,
                    season: season,
                    episode: episode
                ),
                contentId: meta.id,
                contentType: meta.isSeries ? "series" : "movie",
                videoId: WatchProgressLedger.videoId(
                    contentId: meta.id,
                    season: season,
                    episode: episode
                ),
                season: season,
                episode: episode,
                position: duration,
                duration: duration,
                lastWatchedAt: Date(),
                isPendingPush: true
            )
        )
        if let season, let episode {
            removeEpisodeResumePoint(meta: meta, season: season, episode: episode)
        }
        remove(metaId: meta.id, retainingLedger: true)
    }

    /// Display-only "Next Up" suggestion. Deliberately absent from the ledger: a
    /// suggestion is not playback, and pushing one would create a phantom
    /// just-started row on every other device.
    static func saveUpNext(
        meta: NuvioMeta,
        duration: Double,
        season: Int,
        episode: Int,
        released: String? = nil,
        seedSeason: Int? = nil
    ) {
        let item = ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: 1,
            duration: max(duration, 120),
            lastWatchedAt: Date(),
            season: season,
            episode: episode,
            released: released,
            isUpNext: true,
            upNextSeedSeason: seedSeason
        )
        let updated = ([item] + items().filter { $0.meta.id != meta.id }).prefix(maxItems)
        persist(Array(updated))
    }

    /// Continue Watching can be restored before account sync runs. Refresh only
    /// incomplete episode guides here so the Home hero does not stay stuck on a
    /// series synopsis when Cinemeta later supplies the episode overview/still.
    static func refreshMissingEpisodeDetails() async {
        let current = items()
        guard current.contains(where: needsEpisodeGuideRefresh) else { return }

        let repository = CinemetaCatalogRepository()
        var refreshedItems = current
        var didRefresh = false

        for index in refreshedItems.indices where needsEpisodeGuideRefresh(refreshedItems[index]) {
            let item = refreshedItems[index]
            guard let latest = try? await repository.refreshMetadata(id: item.meta.id, type: item.meta.type),
                  let numbers = item.episodeNumbers,
                  let latestEpisode = latest.videos?.first(where: {
                      $0.season == numbers.season && $0.episode == numbers.episode
                  }),
                  !episodeText(latestEpisode.overview).isEmpty else {
                continue
            }

            refreshedItems[index] = ContinueWatchingItem(
                meta: latest,
                streamUrl: item.streamUrl,
                position: item.position,
                duration: item.duration,
                lastWatchedAt: item.lastWatchedAt,
                season: item.season,
                episode: item.episode,
                released: latestEpisode.released ?? item.released,
                episodeTitleOverride: item.episodeTitleOverride,
                episodeOverviewOverride: item.episodeOverviewOverride,
                episodeThumbnailOverride: item.episodeThumbnailOverride,
                isUpNext: item.isUpNext,
                upNextSeedSeason: item.upNextSeedSeason
            )
            didRefresh = true
        }

        if didRefresh {
            persist(refreshedItems)
        }
    }

    private static func needsEpisodeGuideRefresh(_ item: ContinueWatchingItem) -> Bool {
        guard item.meta.isSeries, item.episodeNumbers != nil else { return false }
        return episodeText(item.episodeOverview).isEmpty
    }

    private static func episodeText(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Removes a title from the rendered row.
    ///
    /// `retainingLedger` keeps the underlying synced rows — used when an episode
    /// simply finished, where the row still has to seed Next Up. A user-initiated
    /// removal clears both, so the title does not come back on the next rebuild.
    static func remove(metaId: String, retainingLedger: Bool = false) {
        if !retainingLedger {
            WatchProgressLedger.removeContent(id: metaId)
        }
        persist(items().filter { $0.meta.id != metaId })
    }

    /// Resolves the raw ledger row behind a watched mark the user made by hand.
    ///
    /// ``removeWatched(_:)`` clears the rendered row and the episode's resume
    /// point, but ``ContinueWatchingBuilder`` rebuilds the row from
    /// ``WatchProgressLedger`` — so a row still sitting there as in-progress
    /// puts the progress bar straight back on the next Home load or sync pull.
    /// Completing the row rather than deleting it keeps the Next Up seed a
    /// finished episode is meant to produce, exactly as
    /// ``markPlaybackCompleted(meta:duration:season:episode:)`` does.
    static func markLedgerWatched(meta: NuvioMeta, season: Int? = nil, episode: Int? = nil) {
        guard let record = WatchProgressLedger.record(
            contentId: meta.id,
            season: season,
            episode: episode
        ), !WatchProgressLedger.isComplete(record) else { return }

        // A row whose runtime was never learned cannot express completion as
        // position-over-runtime, and there is no other completion flag on the
        // wire. Dropping it is the only way to stop it rebuilding as progress.
        guard record.duration > 0 else {
            WatchProgressLedger.remove(keys: [record.progressKey])
            return
        }

        WatchProgressLedger.upsert(
            WatchProgressRecord(
                progressKey: record.progressKey,
                contentId: record.contentId,
                contentType: record.contentType,
                videoId: record.videoId,
                season: record.season,
                episode: record.episode,
                position: record.duration,
                duration: record.duration,
                lastWatchedAt: Date(),
                isPendingPush: true
            )
        )
    }

    /// Removes resume rows that are older than a durable watched mark. Episode
    /// marks only remove the matching episode; a later rewatch/progress update
    /// wins by timestamp and remains visible.
    static func removeWatched(_ watchedItems: [WatchedStoreItem]) {
        guard !watchedItems.isEmpty else { return }
        let newestWatchedByIdentity = WatchedStore.newestWatchedDatesByIdentity(watchedItems)
        removeEpisodeResumePoints(watchedItems: watchedItems)
        let current = items()
        let remaining = current.filter { progress in
            let season: Int?
            let episode: Int?
            if progress.meta.isSeries {
                guard let progressEpisode = progress.episodeNumbers else { return true }
                season = progressEpisode.season
                episode = progressEpisode.episode
            } else {
                season = nil
                episode = nil
            }
            let keys = WatchedStore.watchedIdentityKeys(
                metaId: progress.meta.id,
                imdbId: progress.meta.imdbId,
                tmdbId: progress.meta.tmdbId,
                contentType: progress.meta.type,
                season: season,
                episode: episode
            )
            return !keys.contains {
                newestWatchedByIdentity[$0].map { $0 >= progress.lastWatchedAt } ?? false
            }
        }
        guard remaining.count != current.count else { return }
        persist(remaining)
    }

    /// Installs a freshly derived list. `ContinueWatchingBuilder` owns the
    /// derivation; this store only persists and publishes the result.
    static func replaceAll(_ newItems: [ContinueWatchingItem]) {
        let ordered = Array(newItems.sorted { $0.lastWatchedAt > $1.lastWatchedAt }.prefix(maxItems))
        guard persist(ordered) else { return }

        // Keep per-episode resume points in step so opening an episode directly
        // still resumes where the account left it.
        for item in ordered where item.meta.isSeries && !item.isUpNextEntry {
            guard let season = item.season,
                  let episode = item.episode,
                  shouldKeep(position: item.position, duration: item.duration) else {
                continue
            }
            let episodeId = item.meta.videos?.first {
                $0.season == season && $0.episode == episode
            }?.id
            saveEpisodeResumePoint(
                meta: item.meta,
                season: season,
                episode: episode,
                episodeId: episodeId,
                position: item.position,
                duration: item.duration,
                updatedAt: item.lastWatchedAt
            )
        }
    }

    private static func shouldKeep(position: Double, duration: Double) -> Bool {
        // Any started playback counts (> 0), matching the phone app's rule —
        // a stricter threshold here hides items the phone still lists.
        guard position > 0 else { return false }
        // An unknown runtime is not evidence of completion. The phone stores
        // duration-less rows and keeps them resumable; treating them as
        // finished here is what made synced titles vanish from this device.
        guard duration > 0 else { return true }
        return (position / duration) < WatchProgressLedger.completionFraction
    }

    private static func episodeResumePoints() -> [EpisodeResumePoint] {
        guard let data = UserDefaults.standard.data(forKey: episodeResumeStorageKey),
              let decoded = try? makeDecoder().decode([EpisodeResumePoint].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func saveEpisodeResumePoint(
        meta: NuvioMeta,
        season: Int,
        episode: Int,
        episodeId: String?,
        position: Double,
        duration: Double,
        updatedAt: Date
    ) {
        guard position > 5 else { return }
        guard shouldKeep(position: position, duration: duration) else {
            removeEpisodeResumePoint(meta: meta, season: season, episode: episode)
            return
        }
        let current = episodeResumePoints()
        if let existing = current.first(where: {
            resumePoint($0, matches: meta, season: season, episode: episode, episodeId: episodeId)
        }), existing.updatedAt > updatedAt {
            return
        }
        let point = EpisodeResumePoint(
            metaId: meta.id,
            imdbId: meta.imdbId,
            tmdbId: meta.tmdbId,
            season: season,
            episode: episode,
            episodeId: episodeId,
            position: position,
            duration: duration,
            updatedAt: updatedAt
        )
        let updated = ([point] + current.filter {
            !resumePoint($0, matches: meta, season: season, episode: episode, episodeId: episodeId)
        }).prefix(maxEpisodeResumePoints)
        guard let data = try? makeEncoder().encode(Array(updated)) else { return }
        UserDefaults.standard.set(data, forKey: episodeResumeStorageKey)
    }

    private static func removeEpisodeResumePoint(meta: NuvioMeta, season: Int, episode: Int) {
        let current = episodeResumePoints()
        let remaining = current.filter {
            !resumePoint($0, matches: meta, season: season, episode: episode, episodeId: nil)
        }
        guard remaining.count != current.count,
              let data = try? makeEncoder().encode(remaining) else { return }
        UserDefaults.standard.set(data, forKey: episodeResumeStorageKey)
    }

    private static func removeEpisodeResumePoints(watchedItems: [WatchedStoreItem]) {
        let newestWatchedByIdentity = WatchedStore.newestWatchedDatesByIdentity(watchedItems)
        let current = episodeResumePoints()
        let remaining = current.filter { point in
            let keys = WatchedStore.watchedIdentityKeys(
                metaId: point.metaId,
                imdbId: point.imdbId,
                tmdbId: point.tmdbId,
                contentType: "series",
                season: point.season,
                episode: point.episode
            )
            return !keys.contains {
                newestWatchedByIdentity[$0].map { $0 >= point.updatedAt } ?? false
            }
        }
        guard remaining.count != current.count,
              let data = try? makeEncoder().encode(remaining) else { return }
        UserDefaults.standard.set(data, forKey: episodeResumeStorageKey)
    }

    private static func resumePoint(
        _ point: EpisodeResumePoint,
        matches meta: NuvioMeta,
        season: Int,
        episode: Int,
        episodeId: String?
    ) -> Bool {
        guard point.season == season, point.episode == episode else { return false }
        let sameShow = point.metaId == meta.id
            || (point.imdbId != nil && point.imdbId == meta.imdbId)
            || (point.tmdbId != nil && point.tmdbId == meta.tmdbId)
        guard sameShow else { return false }
        if let episodeId, let storedEpisodeId = point.episodeId {
            return storedEpisodeId == episodeId
        }
        return true
    }

    private static func clampedResume(position: Double, duration: Double) -> Double? {
        guard position > 5, shouldKeep(position: position, duration: duration) else { return nil }
        // With no known runtime there is nothing to clamp against; resume where
        // the row says playback stopped.
        guard duration > 0 else { return position }
        return max(0, min(position, max(duration - 5, 0)))
    }

    @discardableResult
    private static func persist(_ items: [ContinueWatchingItem]) -> Bool {
        let storedItems = Array(items.prefix(maxItems))
        let data: Data
        do {
            data = try makeEncoder().encode(storedItems)
        } catch {
            persistenceDiagnostic = "encode failed: \(diagnosticText(for: error))"
            return false
        }

        let key = storageKey
        guard let url = storageURL(for: key) else {
            persistenceDiagnostic = "save failed: Caches unavailable"
            return false
        }

        do {
            try writeAndVerify(data, to: url)
            // Retire any copy an older build left in a directory tvOS will not
            // let us write to again.
            for legacyURL in legacyStorageURLs(for: key) {
                try? FileManager.default.removeItem(at: legacyURL)
            }
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: fallbackMarkerKey(for: key))
            // What was just written *is* what the next read would decode, so
            // refresh the memo rather than clearing it — a save during playback
            // would otherwise force a full re-decode on the next row refresh.
            cachedItems = storedItems
                .filter { shouldKeep(position: $0.position, duration: $0.duration) }
                .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
            cachedKey = key
            persistenceDiagnostic = "Caches: \(storedItems.count) item(s), \(data.count) bytes"
            NotificationCenter.default.post(name: changedNotification, object: nil)
            writeTopShelfFeed()
            return true
        } catch {
            // Deliberately no UserDefaults fallback: a synced list carries several
            // megabytes of episode metadata, and tvOS 27 aborts the process when a
            // value that large is written to UserDefaults.
            // The file may have been partially written, so trust disk over memory.
            invalidateCache()
            persistenceDiagnostic = "save failed: \(diagnosticText(for: error))"
            return false
        }
    }

    /// Mirrors the active profile's Continue Watching list into the App Group so
    /// the Top Shelf extension can render the Apple TV home row. No-op when the
    /// shared container isn't available.
    private static func writeTopShelfFeed() {
        let entries = items().prefix(10).map { item -> TopShelfEntry in
            let fraction = item.duration > 0 ? min(max(item.position / item.duration, 0), 1) : nil
            var subtitleParts: [String] = []
            if let season = item.season, let episode = item.episode {
                subtitleParts.append("S\(season) · E\(episode)")
            } else if let year = item.meta.year {
                subtitleParts.append(String(year))
            }
            if let remaining = Self.remainingTimeText(
                seconds: max(0, item.duration - item.position)
            ) {
                subtitleParts.append("\(remaining) left")
            }
            return TopShelfEntry(
                contentId: item.meta.id,
                contentType: item.meta.type,
                title: item.meta.name,
                subtitle: subtitleParts.isEmpty ? nil : subtitleParts.joined(separator: "  ·  "),
                imageURL: item.meta.posterUrl,
                progress: item.isUpNextEntry ? nil : fraction
            )
        }
        TopShelfFeedStore.write(Array(entries))
    }

    private static func remainingTimeText(seconds: Double) -> String? {
        guard seconds >= 60 else { return nil }
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Deletes one profile's resume state, leaving every other profile alone.
    /// Use this rather than ``eraseAllProfiles()`` for anything that is only
    /// cleaning up after itself — see ``WatchedStore/eraseProfile(_:)``.
    static func eraseProfile(_ profileId: String) {
        invalidateCache()
        WatchProgressLedger.eraseProfile(profileId)
        ContinueWatchingDismissStore.eraseProfile(profileId)
        for key in [storageKey(for: profileId), episodeResumeStorageKey(for: profileId)] {
            UserDefaults.standard.removeObject(forKey: key)
            if let url = storageURL(for: key) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Deletes every profile's watch history (and the legacy shared list).
    /// Called on sign-out so the next user starts with no resume state.
    static func eraseAllProfiles() {
        invalidateCache()
        WatchProgressLedger.eraseAllProfiles()
        ContinueWatchingDismissStore.eraseAllProfiles()
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(baseKey) }
            .forEach { defaults.removeObject(forKey: $0) }
        if let directory = storageDirectoryURL {
            try? FileManager.default.removeItem(at: directory)
        }
        for legacyDirectory in legacyStorageDirectoryURLs {
            try? FileManager.default.removeItem(at: legacyDirectory)
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// One-time copy of the old shared list into the active profile's bucket so
    /// existing users keep their Continue Watching when profiles arrive. Only the
    /// first profile that becomes active inherits it; afterwards the legacy key
    /// is cleared so other profiles start clean.
    private static func migrateLegacyHistoryIfNeeded() {
        guard let id = activeProfileId, !id.isEmpty else { return }
        let profileKey = "\(baseKey).\(id)"
        // Nothing to migrate, or this profile already has its own history.
        guard data(for: profileKey) == nil,
              let legacyData = data(for: baseKey),
              let profileURL = storageURL(for: profileKey) else { return }
        do {
            try writeAndVerify(legacyData, to: profileURL)
            // The active profile's file now holds the legacy list.
            invalidateCache()
            removeStorage(for: baseKey)
            persistenceDiagnostic = "migrated shared progress to profile \(id)"
        } catch {
            // The shared copy remains the source of truth until this succeeds.
            persistenceDiagnostic = "profile migration failed: \(diagnosticText(for: error))"
        }
    }

    /// Caches is the only directory a tvOS app can actually write to on real
    /// hardware. Application Support and Documents both raise "you don't have
    /// permission" on device while succeeding in the Simulator, which is how the
    /// old primary path shipped: every physical Apple TV was silently running on
    /// what the code called its fallback.
    ///
    /// Caches being evictable is acceptable here because this file is a derived
    /// view. [[WatchProgressLedger]] holds the durable history in UserDefaults,
    /// and `ContinueWatchingBuilder` rebuilds this from it on the next Home load.
    private static var storageDirectoryURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nuvio", isDirectory: true)
            .appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    /// Read-only migration sources, newest scheme first. Older builds aimed at
    /// Application Support (which worked only in the Simulator) and, before that,
    /// Documents. Anything found here is copied into Caches and removed.
    private static var legacyStorageDirectoryURLs: [URL] {
        let manager = FileManager.default
        var urls: [URL] = []
        if let applicationSupport = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(
                applicationSupport
                    .appendingPathComponent("Nuvio", isDirectory: true)
                    .appendingPathComponent(storageDirectoryName, isDirectory: true)
            )
        }
        if let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
            urls.append(documents.appendingPathComponent(storageDirectoryName, isDirectory: true))
        }
        return urls
    }

    private static func storageURL(for key: String) -> URL? {
        storageDirectoryURL?.appendingPathComponent(fileName(for: key))
    }

    private static func legacyStorageURLs(for key: String) -> [URL] {
        legacyStorageDirectoryURLs.map { $0.appendingPathComponent(fileName(for: key)) }
    }

    private static func fileName(for key: String) -> String {
        let encoded = Data(key.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return "\(encoded).json"
    }

    private static func data(for key: String) -> Data? {
        if let url = storageURL(for: key),
           let data = try? Data(contentsOf: url) {
            return data
        }

        // Nothing in Caches: either this is the first read after an upgrade, or
        // tvOS evicted the file. Recover whatever an older build left behind and
        // move it into Caches. A miss here is not an error — the ledger can
        // rebuild the whole view.
        for legacyURL in legacyStorageURLs(for: key) {
            guard let data = try? Data(contentsOf: legacyURL) else { continue }
            if let url = storageURL(for: key) {
                do {
                    try writeAndVerify(data, to: url)
                    try? FileManager.default.removeItem(at: legacyURL)
                    persistenceDiagnostic = "migrated progress from \(legacyURL.deletingLastPathComponent().lastPathComponent)"
                } catch {
                    persistenceDiagnostic = "migration failed: \(diagnosticText(for: error))"
                }
            }
            return data
        }

        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key) else { return nil }
        if let url = storageURL(for: key) {
            do {
                try writeAndVerify(data, to: url)
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: fallbackMarkerKey(for: key))
                persistenceDiagnostic = "migrated UserDefaults progress"
            } catch {
                // Preserve the legacy value until the destination is verified.
                persistenceDiagnostic = "UserDefaults migration failed: \(diagnosticText(for: error))"
            }
        }
        return data
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }

    private static func writeAndVerify(_ data: Data, to url: URL) throws {
        _ = try makeDecoder().decode([ContinueWatchingItem].self, from: data)
        try write(data, to: url)
        guard let saved = try? Data(contentsOf: url), saved == data else {
            throw PersistenceError.verificationFailed
        }
        _ = try makeDecoder().decode([ContinueWatchingItem].self, from: saved)
    }

    private static func fallbackMarkerKey(for key: String) -> String {
        "\(key).userDefaultsFallback"
    }

    private static func diagnosticText(for error: Error) -> String {
        let singleLine = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        return String(singleLine.prefix(160))
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    /// Drops the derived file the way tvOS does when it reclaims Caches, leaving
    /// the ledger untouched. Exists so the recovery path is actually covered.
    static func simulateStorageEvictionForTesting() {
        removeStorage(for: storageKey)
        invalidateCache()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static func removeStorage(for key: String) {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: fallbackMarkerKey(for: key))
        if let url = storageURL(for: key) {
            try? FileManager.default.removeItem(at: url)
        }
        for legacyURL in legacyStorageURLs(for: key) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
    }
}

/// Cards the user removed from Continue Watching by hand.
///
/// Local progress is deleted outright when a card is removed, but a Trakt- or
/// Simkl-backed row is rebuilt from the provider on every refresh, and a synced
/// Nuvio row can be restored by a pull that races the delete. A removal only
/// stays removed if this device also remembers it.
///
/// The key carries the episode the card was showing, so the removal is scoped
/// to exactly what the user dismissed: finishing a later episode produces a
/// different key, and any fresh progress for the title clears its keys outright
/// (see `ContinueWatchingStore.save`), so a show they return to always comes
/// back on its own.
enum ContinueWatchingDismissStore {
    static let changedNotification = Notification.Name("nuvio.tv.continueWatching.dismissed")

    private static let baseKey = "nuvio.tv.continueWatching.dismissedKeys"
    private static let separator = "\u{1f}"

    private(set) static var activeProfileId: String?

    /// Driven by `ContinueWatchingStore.setActiveProfile` so removals follow the
    /// same profile scope as the row they hide.
    static func setActiveProfile(_ profileId: String?) {
        activeProfileId = profileId
    }

    private static var storageKey: String {
        guard let id = activeProfileId, !id.isEmpty else { return baseKey }
        return "\(baseKey).\(id)"
    }

    /// Scoped counterpart to ``eraseAllProfiles()`` — see
    /// ``WatchedStore/eraseProfile(_:)``.
    static func eraseProfile(_ profileId: String) {
        let key = profileId.isEmpty ? baseKey : "\(baseKey).\(profileId)"
        UserDefaults.standard.removeObject(forKey: key)
    }

    static func key(for item: ContinueWatchingItem) -> String {
        let numbers = item.episodeNumbers
        return key(contentId: item.meta.id, season: numbers?.season, episode: numbers?.episode)
    }

    static func key(contentId: String, season: Int?, episode: Int?) -> String {
        let id = contentId.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(id)\(separator)\(season ?? -1)\(separator)\(episode ?? -1)"
    }

    static func keys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: storageKey) ?? [])
    }

    static func isDismissed(_ item: ContinueWatchingItem) -> Bool {
        let current = keys()
        guard !current.isEmpty else { return false }
        return current.contains(key(for: item))
    }

    static func dismiss(_ item: ContinueWatchingItem) {
        var current = keys()
        guard current.insert(key(for: item)).inserted else { return }
        persist(current)
    }

    /// Retires every removal recorded for a title.
    static func clear(contentId: String) {
        let current = keys()
        guard !current.isEmpty else { return }
        let prefix = "\(contentId.trimmingCharacters(in: .whitespacesAndNewlines))\(separator)"
        let remaining = current.filter { !$0.hasPrefix(prefix) }
        guard remaining.count != current.count else { return }
        persist(remaining)
    }

    private static func persist(_ keys: Set<String>) {
        if keys.isEmpty {
            UserDefaults.standard.removeObject(forKey: storageKey)
        } else {
            UserDefaults.standard.set(Array(keys), forKey: storageKey)
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Deletes every profile's removals (and the legacy shared set) on sign-out.
    static func eraseAllProfiles() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(baseKey) }
            .forEach { defaults.removeObject(forKey: $0) }
    }
}

struct LibraryStoreItem: Identifiable, Codable {
    var id: String { meta.id }
    let meta: NuvioMeta
    let addedAt: Date

    var stremioMeta: StremioMeta {
        StremioMeta(
            id: meta.id,
            name: meta.name,
            contentType: meta.type,
            poster: meta.posterUrl,
            background: meta.backgroundUrl,
            logo: meta.logoUrl,
            description: meta.description,
            releaseInfo: meta.releaseInfo ?? meta.year.map(String.init),
            imdbRating: meta.rating.map { String(format: "%.1f", $0) },
            year: meta.year.map(Int32.init),
            genres: meta.genres,
            runtime: meta.runtime
        )
    }
}

enum LibraryStore {
    static let changedNotification = Notification.Name("nuvio.tv.library.changed")

    private static let baseKey = "nuvio.tv.library.items"
    private(set) static var activeProfileId: String?

    static func setActiveProfile(_ profileId: String?) {
        activeProfileId = profileId
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static var storageKey: String {
        guard let id = activeProfileId, !id.isEmpty else { return baseKey }
        return "\(baseKey).\(id)"
    }

    static func items() -> [LibraryStoreItem] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([LibraryStoreItem].self, from: data) else {
            return []
        }

        return decoded.sorted { $0.addedAt > $1.addedAt }
    }

    static func contains(metaId: String, type: String) -> Bool {
        items().contains { $0.meta.id == metaId && $0.meta.type.caseInsensitiveCompare(type) == .orderedSame }
    }

    @discardableResult
    static func toggle(meta: NuvioMeta) -> Bool {
        if contains(metaId: meta.id, type: meta.type) {
            remove(metaId: meta.id, type: meta.type)
            return false
        }

        add(meta)
        return true
    }

    static func add(_ meta: NuvioMeta) {
        let item = LibraryStoreItem(meta: meta, addedAt: Date())
        let updated = [item] + items().filter {
            !($0.meta.id == meta.id && $0.meta.type.caseInsensitiveCompare(meta.type) == .orderedSame)
        }
        persist(updated)
    }

    static func remove(metaId: String, type: String) {
        persist(items().filter {
            !($0.meta.id == metaId && $0.meta.type.caseInsensitiveCompare(type) == .orderedSame)
        })
    }

    static func mergeRemote(_ remoteItems: [LibraryStoreItem]) {
        guard !remoteItems.isEmpty else { return }
        var byKey: [String: LibraryStoreItem] = [:]
        (items() + remoteItems).forEach { item in
            let key = "\(item.meta.type.lowercased()):\(item.meta.id)"
            let existing = byKey[key]
            if existing == nil || item.addedAt > existing!.addedAt {
                byKey[key] = item
            }
        }
        persist(Array(byKey.values).sorted { $0.addedAt > $1.addedAt })
    }

    static func replaceAll(_ newItems: [LibraryStoreItem]) {
        persist(newItems.sorted { $0.addedAt > $1.addedAt })
    }

    private static func persist(_ items: [LibraryStoreItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Deletes every profile's library (and the legacy shared one) on sign-out.
    static func eraseAllProfiles() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(baseKey) }
            .forEach { defaults.removeObject(forKey: $0) }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

// MARK: - Account collections (synced read-only from the phone/Android apps)

/// Mirrors the Android app's serialized collection JSON
/// (`CollectionsDataStore.SerializableCollection`). Only the fields tvOS
/// renders are declared; unknown fields in the blob are ignored, and every
/// optional has a default so older/newer payload shapes still decode.
/// How a collection folder opens — mirrors Android `FolderViewMode`.
enum CollectionFolderViewMode: String, CaseIterable, Hashable {
    case tabbedGrid = "TABBED_GRID"
    case rows = "ROWS"
    case followLayout = "FOLLOW_LAYOUT"

    /// Rows-style layout (horizontal catalog strips), including follow-home.
    var usesCatalogRows: Bool {
        switch self {
        case .rows, .followLayout: return true
        case .tabbedGrid: return false
        }
    }

    static func fromStored(_ value: String?) -> CollectionFolderViewMode {
        guard let value else { return .tabbedGrid }
        switch value.uppercased() {
        case "ROWS": return .rows
        case "FOLLOW_LAYOUT": return .followLayout
        case "TABBED_GRID": return .tabbedGrid
        default:
            switch value.lowercased() {
            case "rows": return .rows
            case "follow_layout": return .followLayout
            default: return .tabbedGrid
            }
        }
    }
}

struct NuvioCollection: Decodable, Identifiable {
    let id: String
    let title: String
    var pinToTop: Bool
    /// Tabs vs Rows when browsing a folder inside this collection.
    var viewMode: CollectionFolderViewMode
    var showAllTab: Bool
    var folders: [NuvioCollectionFolder]

    enum CodingKeys: String, CodingKey {
        case id, title, pinToTop, folders, viewMode, showAllTab
        case pin_to_top, view_mode, show_all_tab
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        pinToTop = try c.decodeIfPresent(Bool.self, forKey: .pinToTop)
            ?? c.decodeIfPresent(Bool.self, forKey: .pin_to_top)
            ?? false
        let modeRaw = try c.decodeIfPresent(String.self, forKey: .viewMode)
            ?? c.decodeIfPresent(String.self, forKey: .view_mode)
        viewMode = CollectionFolderViewMode.fromStored(modeRaw)
        showAllTab = try c.decodeIfPresent(Bool.self, forKey: .showAllTab)
            ?? c.decodeIfPresent(Bool.self, forKey: .show_all_tab)
            ?? true
        folders = try c.decodeIfPresent([NuvioCollectionFolder].self, forKey: .folders) ?? []
    }
}

/// Folder card aspect on Home — mirrors Android `PosterShape` / `tileShape`.
enum CollectionTileShape: String, CaseIterable, Identifiable, Hashable {
    case poster = "POSTER"
    case landscape = "LANDSCAPE"
    case square = "SQUARE"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .poster: return "Poster"
        case .landscape: return "Landscape"
        case .square: return "Square"
        }
    }

    /// Width / height, matching Android `PosterShape.aspectRatio()`.
    var aspectRatio: Double {
        switch self {
        case .poster: return 0.675
        case .landscape: return 1.78
        case .square: return 1
        }
    }

    static func fromStored(_ value: String?) -> CollectionTileShape {
        guard let value else { return .square }
        switch value.uppercased() {
        case "POSTER": return .poster
        case "LANDSCAPE": return .landscape
        case "SQUARE": return .square
        default:
            switch value.lowercased() {
            case "poster": return .poster
            case "landscape": return .landscape
            case "square": return .square
            default: return .square
            }
        }
    }
}

struct NuvioCollectionFolder: Decodable, Identifiable {
    let id: String
    let title: String
    var coverImageUrl: String?
    var coverEmoji: String?
    var focusGifUrl: String?
    var focusGifEnabled: Bool
    var hideTitle: Bool
    var heroBackdropUrl: String?
    var heroVideoUrl: String?
    var titleLogoUrl: String?
    /// Optional tvOS presentation hint used by curated collection templates.
    var presentationStyle: String?
    /// Android `tileShape`: POSTER / LANDSCAPE / SQUARE.
    var tileShape: CollectionTileShape
    var sources: [NuvioCollectionSource]
    /// Legacy pre-`sources` field still present in old blobs.
    var catalogSources: [NuvioCollectionCatalogSource]

    enum CodingKeys: String, CodingKey {
        case id, title, coverImageUrl, coverEmoji, tileShape, sources, catalogSources
        case focusGifUrl, focusGifEnabled, hideTitle
        case heroBackdropUrl, heroVideoUrl, titleLogoUrl
        case presentationStyle
        case cover_image_url, cover_emoji, tile_shape, catalog_sources
        case focus_gif_url, focus_gif_enabled, hide_title
        case hero_backdrop_url, hero_video_url, title_logo_url
        case presentation_style
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        coverImageUrl = try c.decodeIfPresent(String.self, forKey: .coverImageUrl)
            ?? c.decodeIfPresent(String.self, forKey: .cover_image_url)
        coverEmoji = try c.decodeIfPresent(String.self, forKey: .coverEmoji)
            ?? c.decodeIfPresent(String.self, forKey: .cover_emoji)
        focusGifUrl = try c.decodeIfPresent(String.self, forKey: .focusGifUrl)
            ?? c.decodeIfPresent(String.self, forKey: .focus_gif_url)
        focusGifEnabled = try c.decodeIfPresent(Bool.self, forKey: .focusGifEnabled)
            ?? c.decodeIfPresent(Bool.self, forKey: .focus_gif_enabled)
            ?? true
        hideTitle = try c.decodeIfPresent(Bool.self, forKey: .hideTitle)
            ?? c.decodeIfPresent(Bool.self, forKey: .hide_title)
            ?? false
        heroBackdropUrl = try c.decodeIfPresent(String.self, forKey: .heroBackdropUrl)
            ?? c.decodeIfPresent(String.self, forKey: .hero_backdrop_url)
        heroVideoUrl = try c.decodeIfPresent(String.self, forKey: .heroVideoUrl)
            ?? c.decodeIfPresent(String.self, forKey: .hero_video_url)
        titleLogoUrl = try c.decodeIfPresent(String.self, forKey: .titleLogoUrl)
            ?? c.decodeIfPresent(String.self, forKey: .title_logo_url)
        presentationStyle = try c.decodeIfPresent(String.self, forKey: .presentationStyle)
            ?? c.decodeIfPresent(String.self, forKey: .presentation_style)
        let shapeRaw = try c.decodeIfPresent(String.self, forKey: .tileShape)
            ?? c.decodeIfPresent(String.self, forKey: .tile_shape)
        tileShape = CollectionTileShape.fromStored(shapeRaw)
        sources = try c.decodeIfPresent([NuvioCollectionSource].self, forKey: .sources) ?? []
        catalogSources = try c.decodeIfPresent([NuvioCollectionCatalogSource].self, forKey: .catalogSources)
            ?? c.decodeIfPresent([NuvioCollectionCatalogSource].self, forKey: .catalog_sources)
            ?? []
    }

    /// Provider-aware sources used by the folder browser. Modern payloads keep
    /// the heterogeneous `sources` array; legacy payloads are promoted from
    /// `catalogSources` exactly as the Compose client does.
    var resolvedSources: [NuvioCollectionSource] {
        if !sources.isEmpty { return sources }
        return catalogSources.map {
            NuvioCollectionSource(
                provider: "addon",
                addonId: $0.addonId,
                type: $0.type,
                catalogId: $0.catalogId,
                genre: $0.genre
            )
        }
    }

    /// Compatibility accessor for settings that only need add-on catalogs.
    var addonCatalogSources: [NuvioCollectionCatalogSource] {
        var seen = Set<String>()
        var merged: [NuvioCollectionCatalogSource] = []
        for source in resolvedSources {
            guard source.provider.isEmpty || source.provider.lowercased() == "addon",
                  let addonId = source.addonId, !addonId.isEmpty,
                  let type = source.type, !type.isEmpty,
                  let catalogId = source.catalogId, !catalogId.isEmpty else { continue }
            let key = "\(addonId)_\(type)_\(catalogId)_\(source.genre ?? "")"
            guard seen.insert(key).inserted else { continue }
            merged.append(
                NuvioCollectionCatalogSource(
                    addonId: addonId,
                    type: type,
                    catalogId: catalogId,
                    genre: source.genre
                )
            )
        }
        return merged
    }
}

struct NuvioCollectionSource: Decodable, Hashable {
    var provider: String
    var addonId: String?
    var type: String?
    var catalogId: String?
    var genre: String?
    var tmdbSourceType: String?
    var title: String?
    var tmdbId: Int?
    var traktListId: Int64?
    var mediaType: String?
    var sortBy: String?
    var sortHow: String?
    var filters: NuvioTmdbCollectionFilters?

    enum CodingKeys: String, CodingKey {
        case provider, addonId, type, catalogId, genre, tmdbSourceType, title
        case tmdbId, traktListId, mediaType, sortBy, sortHow, filters
        case addon_id, catalog_id, tmdb_source_type, tmdb_id, trakt_list_id
        case media_type, sort_by, sort_how
    }

    init(
        provider: String = "addon",
        addonId: String? = nil,
        type: String? = nil,
        catalogId: String? = nil,
        genre: String? = nil,
        tmdbSourceType: String? = nil,
        title: String? = nil,
        tmdbId: Int? = nil,
        traktListId: Int64? = nil,
        mediaType: String? = nil,
        sortBy: String? = nil,
        sortHow: String? = nil,
        filters: NuvioTmdbCollectionFilters? = nil
    ) {
        self.provider = provider
        self.addonId = addonId
        self.type = type
        self.catalogId = catalogId
        self.genre = genre
        self.tmdbSourceType = tmdbSourceType
        self.title = title
        self.tmdbId = tmdbId
        self.traktListId = traktListId
        self.mediaType = mediaType
        self.sortBy = sortBy
        self.sortHow = sortHow
        self.filters = filters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "addon"
        addonId = try c.decodeIfPresent(String.self, forKey: .addonId)
            ?? c.decodeIfPresent(String.self, forKey: .addon_id)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        catalogId = try c.decodeIfPresent(String.self, forKey: .catalogId)
            ?? c.decodeIfPresent(String.self, forKey: .catalog_id)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
        tmdbSourceType = try c.decodeIfPresent(String.self, forKey: .tmdbSourceType)
            ?? c.decodeIfPresent(String.self, forKey: .tmdb_source_type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId)
            ?? c.decodeIfPresent(Int.self, forKey: .tmdb_id)
        traktListId = try c.decodeIfPresent(Int64.self, forKey: .traktListId)
            ?? c.decodeIfPresent(Int64.self, forKey: .trakt_list_id)
        mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType)
            ?? c.decodeIfPresent(String.self, forKey: .media_type)
        sortBy = try c.decodeIfPresent(String.self, forKey: .sortBy)
            ?? c.decodeIfPresent(String.self, forKey: .sort_by)
        sortHow = try c.decodeIfPresent(String.self, forKey: .sortHow)
            ?? c.decodeIfPresent(String.self, forKey: .sort_how)
        filters = try c.decodeIfPresent(NuvioTmdbCollectionFilters.self, forKey: .filters)
    }

    var normalizedProvider: String {
        let value = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? "addon" : value
    }

    var routeKey: String {
        switch normalizedProvider {
        case "tmdb":
            return "tmdb_\(tmdbSourceType ?? "")_\(tmdbId.map(String.init) ?? "")_\(mediaType ?? "")_\(sortBy ?? "")_\(filters?.routeKey ?? "")"
        case "trakt":
            return "trakt_\(traktListId.map(String.init) ?? "")_\(mediaType ?? "")_\(sortBy ?? "")_\(sortHow ?? "")"
        default:
            return "addon_\(addonId ?? "")_\(type ?? "")_\(catalogId ?? "")_\(genre ?? "")"
        }
    }
}

struct NuvioTmdbCollectionFilters: Decodable, Hashable {
    var withGenres: String?
    var releaseDateGte: String?
    var releaseDateLte: String?
    var voteAverageGte: Double?
    var voteAverageLte: Double?
    var voteCountGte: Int?
    var withOriginalLanguage: String?
    var withOriginCountry: String?
    var withKeywords: String?
    var withCompanies: String?
    var withNetworks: String?
    var year: Int?
    var watchRegion: String?
    var withWatchProviders: String?

    var routeKey: String {
        var parts: [String] = []
        parts.append(withGenres ?? "")
        parts.append(releaseDateGte ?? "")
        parts.append(releaseDateLte ?? "")
        if let voteAverageGte {
            parts.append(String(voteAverageGte))
        } else {
            parts.append("")
        }
        if let voteAverageLte {
            parts.append(String(voteAverageLte))
        } else {
            parts.append("")
        }
        if let voteCountGte {
            parts.append(String(voteCountGte))
        } else {
            parts.append("")
        }
        parts.append(withOriginalLanguage ?? "")
        parts.append(withOriginCountry ?? "")
        parts.append(withKeywords ?? "")
        parts.append(withCompanies ?? "")
        parts.append(withNetworks ?? "")
        if let year {
            parts.append(String(year))
        } else {
            parts.append("")
        }
        parts.append(watchRegion ?? "")
        parts.append(withWatchProviders ?? "")
        return parts.joined(separator: ",")
    }
}

struct NuvioCollectionCatalogSource: Codable {
    let addonId: String
    let type: String
    let catalogId: String
    var genre: String?

    init(addonId: String, type: String, catalogId: String, genre: String? = nil) {
        self.addonId = addonId
        self.type = type
        self.catalogId = catalogId
        self.genre = genre
    }
}

/// One folder card inside a Home collection row (Android-style grouping).
/// Selecting it opens the folder's resolved catalog sources, rather than
/// flattening those catalogs into top-level Home rows.
struct TVCollectionFolderItem: Identifiable, Hashable {
    let id: String
    let collectionId: String
    let folderId: String
    let title: String
    let coverImageUrl: String?
    let coverEmoji: String?
    let focusGifUrl: String?
    let focusGifEnabled: Bool
    let hideTitle: Bool
    /// Full-screen Modern Home backdrop when this folder is focused.
    let heroBackdropUrl: String?
    /// Optional looping hero trailer URL (Android Modern Home; not yet played on tvOS).
    let heroVideoUrl: String?
    /// Optional wordmark shown in the hero title area instead of plain text.
    let titleLogoUrl: String?
    let presentationStyle: String?
    let tileShape: CollectionTileShape
    let sources: [NuvioCollectionSource]
    /// Parent collection view mode (Tabs / Rows / Follow layout).
    let viewMode: CollectionFolderViewMode
    let showAllTab: Bool

    init(
        collectionId: String,
        folder: NuvioCollectionFolder,
        sources: [NuvioCollectionSource],
        viewMode: CollectionFolderViewMode = .tabbedGrid,
        showAllTab: Bool = true
    ) {
        self.collectionId = collectionId
        self.folderId = folder.id
        self.id = "\(collectionId)_\(folder.id)"
        self.title = folder.title
        self.coverImageUrl = folder.coverImageUrl
        self.coverEmoji = folder.coverEmoji
        self.focusGifUrl = folder.focusGifUrl
        self.focusGifEnabled = folder.focusGifEnabled
        self.hideTitle = folder.hideTitle
        self.heroBackdropUrl = folder.heroBackdropUrl
        self.heroVideoUrl = folder.heroVideoUrl
        self.titleLogoUrl = folder.titleLogoUrl
        self.presentationStyle = folder.presentationStyle
        self.tileShape = folder.tileShape
        self.sources = sources
        self.viewMode = viewMode
        self.showAllTab = showAllTab
    }

    /// Focus GIF overlay URL when the toggle is on and a URL is set.
    var activeFocusGifURLString: String? {
        guard focusGifEnabled else { return nil }
        let trimmed = focusGifUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Backdrop for the full-screen Home layer — matches Android
    /// `firstNonBlank(heroBackdropUrl, coverImageUrl)`.
    var preferredHeroBackdropURLString: String? {
        // Cinematic templates use transparent/wordmark artwork as their tile;
        // do not enlarge that logo into the full-screen Home backdrop.
        let style = presentationStyle?.uppercased()
        let usesLogoTile = style == "STREAMING_SERVICE" || style == "STUDIO_FRANCHISE"
        let candidates = usesLogoTile
            ? [heroBackdropUrl]
            : [heroBackdropUrl, coverImageUrl]
        for candidate in candidates {
            let url = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !url.isEmpty { return url }
        }
        return nil
    }

    var preferredTitleLogoURLString: String? {
        let url = titleLogoUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return url.isEmpty ? nil : url
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: TVCollectionFolderItem, rhs: TVCollectionFolderItem) -> Bool {
        lhs.id == rhs.id
            && lhs.focusGifUrl == rhs.focusGifUrl
            && lhs.focusGifEnabled == rhs.focusGifEnabled
            && lhs.hideTitle == rhs.hideTitle
            && lhs.tileShape == rhs.tileShape
            && lhs.coverEmoji == rhs.coverEmoji
            && lhs.coverImageUrl == rhs.coverImageUrl
            && lhs.heroBackdropUrl == rhs.heroBackdropUrl
            && lhs.titleLogoUrl == rhs.titleLogoUrl
            && lhs.presentationStyle == rhs.presentationStyle
            && lhs.sources == rhs.sources
            && lhs.viewMode == rhs.viewMode
            && lhs.showAllTab == rhs.showAllTab
    }
}

/// Per-profile cache of the account's collections. Written only by the sync
/// pull (Android/phone remain the editors); read by the Home screen.
enum CollectionsStore {
    static let changedNotification = Notification.Name("nuvio.tv.collections.changed")

    private static let baseKey = "nuvio.tv.collections.json"
    private static let lastPulledIdsKey = "nuvio.tv.collections.lastPulledIds"
    private(set) static var activeProfileId: String?

    static func setActiveProfile(_ profileId: String?) {
        activeProfileId = profileId
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static var storageKey: String {
        guard let id = activeProfileId, !id.isEmpty else { return baseKey }
        return "\(baseKey).\(id)"
    }

    private static var lastPulledIdsStorageKey: String {
        guard let id = activeProfileId, !id.isEmpty else { return lastPulledIdsKey }
        return "\(lastPulledIdsKey).\(id)"
    }

    /// Collection ids present in the last successful account pull. Used when
    /// pushing a local edit so remote-only collections (created on Android
    /// after this device last synced) are not wiped, while intentional deletes
    /// of previously-pulled ids still go through.
    static func lastPulledCollectionIds() -> Set<String> {
        guard let data = UserDefaults.standard.data(forKey: lastPulledIdsStorageKey),
              let ids = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(ids)
    }

    private static func rememberPulledIds(_ ids: [String]) {
        guard let data = try? JSONEncoder().encode(ids) else { return }
        UserDefaults.standard.set(data, forKey: lastPulledIdsStorageKey)
    }

    /// Decode one collection at a time so a single bad row cannot drop the rest.
    static func collections() -> [NuvioCollection] {
        rawCollections().compactMap { row in
            guard let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            do {
                return try JSONDecoder().decode(NuvioCollection.self, from: data)
            } catch {
                let id = row["id"] as? String ?? "?"
                let title = row["title"] as? String ?? "?"
                print("CollectionsStore: skip undecodable collection id=\(id) title=\(title): \(error)")
                return nil
            }
        }
    }

    /// Replaces the cache with the account's blob. Raw data is stored as-is so
    /// fields tvOS doesn't model yet survive round-trips of the app version.
    /// Accepts the blob when at least one collection decodes (or the array is
    /// empty); a single corrupt row no longer blocks the whole apply.
    static func applyRemote(_ json: Data) {
        guard let rows = parseCollectionsArray(from: json) else {
            print("CollectionsStore.applyRemote: payload is not a JSON array (\(json.count) bytes)")
            return
        }

        let decoded = rows.compactMap { row -> NuvioCollection? in
            guard let data = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? JSONDecoder().decode(NuvioCollection.self, from: data)
        }
        if !rows.isEmpty && decoded.isEmpty {
            print("CollectionsStore.applyRemote: refused — 0/\(rows.count) collections decoded")
            return
        }
        if decoded.count != rows.count {
            print("CollectionsStore.applyRemote: partial decode \(decoded.count)/\(rows.count)")
        } else {
            print("CollectionsStore.applyRemote: \(decoded.count) collection(s)")
        }

        // Prefer re-encoded raw rows so a double-encoded string input is stored cleanly.
        let storeData = (try? JSONSerialization.data(withJSONObject: rows)) ?? json
        UserDefaults.standard.set(storeData, forKey: storageKey)
        rememberPulledIds(decoded.map(\.id))
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Posted after a local edit (create/pin/delete/add-source) so the sync
    /// manager pushes the new blob to the account; object is the raw
    /// `[[String: Any]]` collections array.
    static let locallyEditedNotification = Notification.Name("nuvio.tv.collections.locallyEdited")

    /// The stored blob as untyped JSON dictionaries. Local edits mutate these
    /// dicts instead of the typed models so fields only the Android app knows
    /// (view modes, tile shapes, TMDB sources, …) survive the round-trip.
    static func rawCollections() -> [[String: Any]] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
        let rows = parseCollectionsArray(from: data) ?? []
        let streamingMigration = migrateStreamingServicesTemplate(in: rows)
        let studiosMigration = migrateStudiosFranchisesTemplate(in: streamingMigration.rows)
        let genresMigration = migrateDiscoverGenresTemplate(in: studiosMigration.rows)
        if (streamingMigration.changed || studiosMigration.changed || genresMigration.changed),
           let migratedData = try? JSONSerialization.data(withJSONObject: genresMigration.rows) {
            UserDefaults.standard.set(migratedData, forKey: storageKey)
        }
        return genresMigration.rows
    }

    /// Keeps previously added Streaming Services collections in sync with
    /// one-time template additions while preserving later user customization.
    private static func migrateStreamingServicesTemplate(
        in rows: [[String: Any]]
    ) -> (rows: [[String: Any]], changed: Bool) {
        var migrated = rows
        var changed = false

        for collectionIndex in migrated.indices {
            var collection = migrated[collectionIndex]
            let version = (collection["templateVersion"] as? NSNumber)?.intValue
                ?? (collection["templateVersion"] as? Int)
                ?? 0
            guard version < 6,
                  var folders = collection["folders"] as? [[String: Any]],
                  folders.contains(where: {
                      ($0["presentationStyle"] as? String)?.uppercased() == "STREAMING_SERVICE"
                  }) else { continue }

            if version < 2 {
                for folderIndex in folders.indices {
                    guard (folders[folderIndex]["presentationStyle"] as? String)?.uppercased()
                        == "STREAMING_SERVICE" else { continue }
                    var sources = (folders[folderIndex]["sources"] as? [[String: Any]]) ?? []
                    let titles = Set(sources.compactMap { $0["title"] as? String })

                    if !titles.contains("Recent Movies"),
                       var recentMovies = sources.first(where: {
                           ($0["provider"] as? String)?.lowercased() == "tmdb"
                               && ($0["mediaType"] as? String)?.lowercased() == "movie"
                       }) {
                        recentMovies["title"] = "Recent Movies"
                        recentMovies["sortBy"] = "primary_release_date.desc"
                        sources.append(recentMovies)
                    }

                    if !titles.contains("Recent Shows"),
                       var recentShows = sources.first(where: {
                           ($0["provider"] as? String)?.lowercased() == "tmdb"
                               && ["tv", "series", "show"].contains(
                                   ($0["mediaType"] as? String)?.lowercased() ?? ""
                               )
                       }) {
                        recentShows["title"] = "Recent Shows"
                        recentShows["sortBy"] = "first_air_date.desc"
                        sources.append(recentShows)
                    }
                    folders[folderIndex]["sources"] = sources
                }
            }

            let hasCrunchyroll = folders.contains { isCrunchyrollStreamingServiceFolder($0) }
            if !hasCrunchyroll {
                folders.append(crunchyrollStreamingServiceFolder())
            }
            if version < 4 {
                for folderIndex in folders.indices
                where isCrunchyrollStreamingServiceFolder(folders[folderIndex]) {
                    folders[folderIndex]["coverImageUrl"] = crunchyrollLogoURL
                    folders[folderIndex]["titleLogoUrl"] = crunchyrollLogoURL
                }
            }
            if version < 6 {
                for folderIndex in folders.indices {
                    let title = folders[folderIndex]["title"] as? String ?? ""
                    if let backdropPath = streamingServiceBackdropPath(for: title) {
                        folders[folderIndex]["heroBackdropUrl"] = studioTemplateImageURL(
                            backdropPath,
                            width: "w1280"
                        )
                    }
                }
            }

            collection["templateID"] = "streaming-services"
            collection["templateVersion"] = 6
            collection["folders"] = folders
            migrated[collectionIndex] = collection
            changed = true
        }
        return (migrated, changed)
    }

    private static let crunchyrollLogoURL =
        "https://upload.wikimedia.org/wikipedia/commons/0/08/Crunchyroll_Logo.png"

    private static func streamingServiceBackdropPath(for title: String) -> String? {
        switch title.lowercased() {
        case "netflix": return "/aVvRQJ2Ckhlym4uh0YGc166CUoP.jpg"
        case "prime video", "amazon prime video": return "/JYgqp8g2kI3SEus9XBDSHukfBN.jpg"
        case "disney+", "disney plus": return "/14QbnygCuTO0vl7CAFmPf1fgZfV.jpg"
        case "max", "hbo max": return "/577eXC8wFQT0eUrJcgznSiFPRmk.jpg"
        case "apple tv+", "apple tv plus": return "/uTWhbLc7Bj4qNSdW3ZvZKL8cOHv.jpg"
        case "hulu": return "/q3pCsNvJ7CmdJUz2sJEEUY3pOPC.jpg"
        case "paramount+", "paramount plus": return "/zQCOimbHIq5BrLHThidw2bThZem.jpg"
        case "peacock": return "/obtdxPgmfykYwVnvuYXC5f2xKlQ.jpg"
        case "crunchyroll": return "/1RgPyOhN4DRs225BGTlHJqCudII.jpg"
        default: return nil
        }
    }

    private static func isCrunchyrollStreamingServiceFolder(_ folder: [String: Any]) -> Bool {
        if (folder["title"] as? String)?.caseInsensitiveCompare("Crunchyroll") == .orderedSame {
            return true
        }
        let sources = folder["sources"] as? [[String: Any]] ?? []
        return sources.contains { source in
            let filters = source["filters"] as? [String: Any]
            return (filters?["withWatchProviders"] as? String) == "283"
                || (filters?["withWatchProviders"] as? NSNumber)?.intValue == 283
        }
    }

    private static func crunchyrollStreamingServiceFolder() -> [String: Any] {
        let filters: [String: Any] = [
            "withWatchProviders": "283",
            "watchRegion": "US"
        ]
        return [
            "id": UUID().uuidString,
            "title": "Crunchyroll",
            "coverImageUrl": crunchyrollLogoURL,
            "titleLogoUrl": crunchyrollLogoURL,
            "presentationStyle": "STREAMING_SERVICE",
            "tileShape": "LANDSCAPE",
            "hideTitle": true,
            "focusGifEnabled": false,
            "sources": [
                [
                    "provider": "tmdb",
                    "tmdbSourceType": "DISCOVER",
                    "title": "Movies • Popular",
                    "mediaType": "movie",
                    "sortBy": "popularity.desc",
                    "filters": filters
                ],
                [
                    "provider": "tmdb",
                    "tmdbSourceType": "DISCOVER",
                    "title": "Series • Popular",
                    "mediaType": "tv",
                    "sortBy": "popularity.desc",
                    "filters": filters
                ],
                [
                    "provider": "tmdb",
                    "tmdbSourceType": "DISCOVER",
                    "title": "Recent Movies",
                    "mediaType": "movie",
                    "sortBy": "primary_release_date.desc",
                    "filters": filters
                ],
                [
                    "provider": "tmdb",
                    "tmdbSourceType": "DISCOVER",
                    "title": "Recent Shows",
                    "mediaType": "tv",
                    "sortBy": "first_air_date.desc",
                    "filters": filters
                ]
            ]
        ]
    }

    private struct StudioTemplateConfiguration {
        let logoPath: String
        let backdropPath: String
        let movieSourceType: String
        let movieID: Int?
        let seriesSourceType: String
        let seriesID: Int?
        let filters: [String: Any]?
    }

    /// Upgrades the first Studios & Franchises template to the cinematic,
    /// four-catalog presentation without requiring users to recreate it.
    private static func migrateStudiosFranchisesTemplate(
        in rows: [[String: Any]]
    ) -> (rows: [[String: Any]], changed: Bool) {
        var migrated = rows
        var changed = false

        for collectionIndex in migrated.indices {
            var collection = migrated[collectionIndex]
            let version = (collection["templateVersion"] as? NSNumber)?.intValue
                ?? (collection["templateVersion"] as? Int)
                ?? 0
            let templateID = (collection["templateID"] as? String)?.lowercased()
            let title = collection["title"] as? String
            let isStudiosTemplate = templateID == "studios-franchises"
                || title?.caseInsensitiveCompare("Studios & Franchises") == .orderedSame
            guard isStudiosTemplate,
                  version < 3,
                  var folders = collection["folders"] as? [[String: Any]] else { continue }

            if version < 2 {
                for folderIndex in folders.indices {
                    let folderTitle = folders[folderIndex]["title"] as? String ?? ""
                    guard let configuration = studioTemplateConfiguration(for: folderTitle) else { continue }
                    let logoURL = studioTemplateImageURL(configuration.logoPath, width: "w500")

                    folders[folderIndex]["coverImageUrl"] = logoURL
                    folders[folderIndex]["titleLogoUrl"] = logoURL
                    folders[folderIndex]["heroBackdropUrl"] = studioTemplateImageURL(
                        configuration.backdropPath,
                        width: "w1280"
                    )
                    folders[folderIndex]["presentationStyle"] = "STUDIO_FRANCHISE"
                    folders[folderIndex]["tileShape"] = "LANDSCAPE"
                    folders[folderIndex]["hideTitle"] = true
                    folders[folderIndex]["focusGifEnabled"] = false
                    folders[folderIndex]["sources"] = studioTemplateCatalogSources(configuration)
                }
            }
            if version < 3 {
                folders.removeAll { folder in
                    let title = folder["title"] as? String ?? ""
                    return title.caseInsensitiveCompare("Harry Potter") == .orderedSame
                        || title.caseInsensitiveCompare("Wizarding World") == .orderedSame
                }
            }

            collection["templateID"] = "studios-franchises"
            collection["templateVersion"] = 3
            collection["viewMode"] = "ROWS"
            collection["showAllTab"] = false
            collection["folders"] = folders
            migrated[collectionIndex] = collection
            changed = true
        }
        return (migrated, changed)
    }

    private static func studioTemplateConfiguration(
        for title: String
    ) -> StudioTemplateConfiguration? {
        let company: (Int, String, String)?
        switch title.lowercased() {
        case "a24":
            company = (41077, "/1ZXsGaFPgrgS6ZZGS37AqD5uU12.png", "/wjwMC7u3xWKkrronolBqsIy4L0L.jpg")
        case "pixar":
            company = (3, "/1TjvGVDMYsj6JBxOAkUHpPEwLf7.png", "/8sSKdEmlmqF4kJUd28SqthXC4yZ.jpg")
        case "warner bros.", "warner bros":
            company = (174, "/zhD3hhtKB5qyv7ZeL4uLpNxgMVU.png", "/cu3lhUReOdqFAo5K1jesoftwiBj.jpg")
        case "universal", "universal pictures":
            company = (33, "/8lvHyhjr8oUKOOy2dKXoALWKdp0.png", "/sSIzzVhhLfgLKVBcAUv0X6cLYz9.jpg")
        case "marvel", "marvel studios":
            company = (420, "/hUzeosd33nzE5MCNsZxCGEKTXaQ.png", "/qeQJx07rK2xm8SD2sJxFKhE7gs0.jpg")
        case "dc", "dc entertainment":
            company = (9993, "/2Tc1P3Ac8M479naPp1kYT3izLS5.png", "/rWYtghaUJSDvQm4jmXiCPXBHUdQ.jpg")
        case "hbo":
            return StudioTemplateConfiguration(
                logoPath: "/tuomPhY2UtuPTqqFnKMVHvSb724.png",
                backdropPath: "/577eXC8wFQT0eUrJcgznSiFPRmk.jpg",
                movieSourceType: "COMPANY",
                movieID: 3268,
                seriesSourceType: "NETWORK",
                seriesID: 49,
                filters: nil
            )
        default:
            company = nil
        }

        guard let company else { return nil }
        return StudioTemplateConfiguration(
            logoPath: company.1,
            backdropPath: company.2,
            movieSourceType: "COMPANY",
            movieID: company.0,
            seriesSourceType: "COMPANY",
            seriesID: company.0,
            filters: nil
        )
    }

    private static func studioTemplateCatalogSources(
        _ configuration: StudioTemplateConfiguration
    ) -> [[String: Any]] {
        [
            studioTemplateSource(
                title: "Movies • Popular",
                sourceType: configuration.movieSourceType,
                id: configuration.movieID,
                mediaType: "movie",
                sortBy: "popularity.desc",
                filters: configuration.filters
            ),
            studioTemplateSource(
                title: "Series • Popular",
                sourceType: configuration.seriesSourceType,
                id: configuration.seriesID,
                mediaType: "tv",
                sortBy: "popularity.desc",
                filters: configuration.filters
            ),
            studioTemplateSource(
                title: "Recent Movies",
                sourceType: configuration.movieSourceType,
                id: configuration.movieID,
                mediaType: "movie",
                sortBy: "primary_release_date.desc",
                filters: configuration.filters
            ),
            studioTemplateSource(
                title: "Recent Shows",
                sourceType: configuration.seriesSourceType,
                id: configuration.seriesID,
                mediaType: "tv",
                sortBy: "first_air_date.desc",
                filters: configuration.filters
            )
        ]
    }

    private static func studioTemplateSource(
        title: String,
        sourceType: String,
        id: Int?,
        mediaType: String,
        sortBy: String,
        filters: [String: Any]?
    ) -> [String: Any] {
        var source: [String: Any] = [
            "provider": "tmdb",
            "tmdbSourceType": sourceType,
            "title": title,
            "mediaType": mediaType,
            "sortBy": sortBy
        ]
        if let id { source["tmdbId"] = id }
        if let filters { source["filters"] = filters }
        return source
    }

    private static func studioTemplateImageURL(_ path: String, width: String) -> String {
        "https://image.tmdb.org/t/p/\(width)\(path)"
    }

    /// Keeps existing Discover by Genre templates in sync with backdrop and
    /// four-catalog additions while leaving later user edits alone.
    private static func migrateDiscoverGenresTemplate(
        in rows: [[String: Any]]
    ) -> (rows: [[String: Any]], changed: Bool) {
        var migrated = rows
        var changed = false

        for collectionIndex in migrated.indices {
            var collection = migrated[collectionIndex]
            let version = (collection["templateVersion"] as? NSNumber)?.intValue
                ?? (collection["templateVersion"] as? Int)
                ?? 0
            let templateID = (collection["templateID"] as? String)?.lowercased()
            let title = collection["title"] as? String
            let isGenreTemplate = templateID == "discover-genres"
                || title?.caseInsensitiveCompare("Discover by Genre") == .orderedSame
            guard isGenreTemplate,
                  version < 3,
                  var folders = collection["folders"] as? [[String: Any]] else { continue }

            if version < 2 {
                for folderIndex in folders.indices {
                    let folderTitle = folders[folderIndex]["title"] as? String ?? ""
                    guard let backdropPath = discoverGenreBackdropPath(for: folderTitle) else { continue }
                    folders[folderIndex]["heroBackdropUrl"] = studioTemplateImageURL(
                        backdropPath,
                        width: "w1280"
                    )
                }
            }

            if version < 3 {
                for folderIndex in folders.indices {
                    let folderTitle = folders[folderIndex]["title"] as? String ?? ""
                    var sources = folders[folderIndex]["sources"] as? [[String: Any]] ?? []

                    if !sources.contains(where: { ($0["mediaType"] as? String)?.lowercased() == "tv" }),
                       let keyword = discoverGenreSeriesKeyword(for: folderTitle) {
                        sources.append([
                            "provider": "tmdb",
                            "tmdbSourceType": "DISCOVER",
                            "title": "Series • Popular",
                            "mediaType": "tv",
                            "sortBy": "popularity.desc",
                            "filters": ["withKeywords": keyword]
                        ])
                    }

                    let titles = Set(sources.compactMap { $0["title"] as? String })
                    if !titles.contains("Recent Movies"),
                       var recentMovies = sources.first(where: {
                           ($0["mediaType"] as? String)?.lowercased() == "movie"
                       }) {
                        recentMovies["title"] = "Recent Movies"
                        recentMovies["sortBy"] = "primary_release_date.desc"
                        sources.append(recentMovies)
                    }
                    if !titles.contains("Recent Shows"),
                       var recentShows = sources.first(where: {
                           ($0["mediaType"] as? String)?.lowercased() == "tv"
                       }) {
                        recentShows["title"] = "Recent Shows"
                        recentShows["sortBy"] = "first_air_date.desc"
                        sources.append(recentShows)
                    }
                    folders[folderIndex]["sources"] = sources
                }
            }

            collection["templateID"] = "discover-genres"
            collection["templateVersion"] = 3
            collection["folders"] = folders
            migrated[collectionIndex] = collection
            changed = true
        }
        return (migrated, changed)
    }

    private static func discoverGenreSeriesKeyword(for title: String) -> String? {
        switch title.lowercased() {
        case "horror": return "315058"
        case "romance": return "9840"
        default: return nil
        }
    }

    private static func discoverGenreBackdropPath(for title: String) -> String? {
        switch title.lowercased() {
        case "action & adventure": return "/sSIzzVhhLfgLKVBcAUv0X6cLYz9.jpg"
        case "animation": return "/1RgPyOhN4DRs225BGTlHJqCudII.jpg"
        case "comedy": return "/xWBiXclrRmTggQHMRsIn84YHavs.jpg"
        case "crime": return "/qO55CD8tgVL1T4WKn6zYFFiD6lL.jpg"
        case "documentary": return "/eCP3PAiu442zkJWczdLdvALePNK.jpg"
        case "drama": return "/Af907x5h9W1wVis8XrSd7ynTWuy.jpg"
        case "family": return "/kxQiIJ4gVcD3K6o14MJ72p5yRcE.jpg"
        case "horror": return "/rZfmzpixLKLR3Hg2u0WgC7XLFl8.jpg"
        case "mystery & thriller": return "/flxau5Iu7bChQHsESqvGZ3FQRaI.jpg"
        case "romance": return "/1oKLEA9JOhvaBwLpqjROisvWMy7.jpg"
        case "sci-fi & fantasy": return "/qeQJx07rK2xm8SD2sJxFKhE7gs0.jpg"
        case "war & history": return "/cu3lhUReOdqFAo5K1jesoftwiBj.jpg"
        default: return nil
        }
    }

    /// Accepts a JSON array, or a JSON string that itself encodes an array
    /// (double-encoded blobs some backends have returned).
    private static func parseCollectionsArray(from data: Data) -> [[String: Any]]? {
        let object = try? JSONSerialization.jsonObject(with: data)
        if let array = object as? [[String: Any]] {
            return array
        }
        if let text = object as? String,
           let inner = text.data(using: .utf8),
           let array = (try? JSONSerialization.jsonObject(with: inner)) as? [[String: Any]] {
            return array
        }
        return nil
    }

    /// Persists a local edit and asks the sync manager to push it.
    /// Accepts partial decode (same as applyRemote) so one odd row does not
    /// block saving the rest of the list.
    static func saveLocalEdit(_ raw: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
        let decodedCount = raw.compactMap { row -> NuvioCollection? in
            guard let item = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? JSONDecoder().decode(NuvioCollection.self, from: item)
        }.count
        guard raw.isEmpty || decodedCount > 0 else {
            print("CollectionsStore.saveLocalEdit: refused — no decodable collections")
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        NotificationCenter.default.post(name: locallyEditedNotification, object: raw)
    }

    /// Merge a local edit into the latest remote blob.
    /// - Local rows win on the same id (edits / creates on this device).
    /// - Remote-only rows are kept unless their id was known from the last pull
    ///   and is missing locally (intentional delete on this device).
    static func mergeLocalEdit(
        local: [[String: Any]],
        remote: [[String: Any]],
        previouslyPulledIds: Set<String>
    ) -> [[String: Any]] {
        let localIds = Set(local.compactMap { $0["id"] as? String })
        let intentionalDeletes = previouslyPulledIds.subtracting(localIds)

        var byId: [String: [String: Any]] = [:]
        var order: [String] = []

        for row in remote {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            if intentionalDeletes.contains(id) { continue }
            byId[id] = row
            order.append(id)
        }
        for row in local {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            if byId[id] == nil { order.append(id) }
            byId[id] = row
        }

        let merged = order.compactMap { byId[$0] }
        let preserved = merged.count - local.count
        if preserved > 0 {
            print("CollectionsStore.mergeLocalEdit: kept \(preserved) remote-only collection(s)")
        }
        if !intentionalDeletes.isEmpty {
            print("CollectionsStore.mergeLocalEdit: dropped \(intentionalDeletes.count) intentionally deleted id(s)")
        }
        return merged
    }

    /// Deletes every profile's collections on sign-out.
    static func eraseAllProfiles() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(baseKey) || $0.hasPrefix(lastPulledIdsKey) }
            .forEach { defaults.removeObject(forKey: $0) }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

struct WatchedStoreItem: Identifiable, Codable {
    var id: String {
        if let season, let episode {
            return "\(meta.type):\(meta.id):s\(season)e\(episode)"
        }
        return "\(meta.type):\(meta.id)"
    }
    let meta: NuvioMeta
    let watchedAt: Date
    /// Which episode this entry marks; nil for movies and whole-title marks.
    let season: Int?
    let episode: Int?

    /// Which backends have this mark, as `TraktWatchProgressSource` raw values.
    ///
    /// The store is one shared list, but each backend keeps its own account, and
    /// a mark made under one is deliberately not pushed to the others. Without
    /// recording who confirmed a row, switching the selected source shows the
    /// union — a title watched only in Nuvio Sync keeps its checkmark under
    /// Simkl, which is not what either account says.
    ///
    /// A title can genuinely be watched in more than one place, so this is a set
    /// rather than a single owner. Empty means "not yet attributed": rows written
    /// before this existed, which ``migrateSourcesIfNeeded()`` backfills and
    /// which stay visible everywhere until it does.
    var sources: Set<String>

    enum CodingKeys: String, CodingKey {
        case meta, watchedAt, season, episode, sources
    }

    init(
        meta: NuvioMeta,
        watchedAt: Date,
        season: Int? = nil,
        episode: Int? = nil,
        sources: Set<String> = []
    ) {
        self.meta = meta
        self.watchedAt = watchedAt
        self.season = season
        self.episode = episode
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decode(NuvioMeta.self, forKey: .meta)
        watchedAt = try container.decode(Date.self, forKey: .watchedAt)
        season = try container.decodeIfPresent(Int.self, forKey: .season)
        episode = try container.decodeIfPresent(Int.self, forKey: .episode)
        sources = try container.decodeIfPresent(Set<String>.self, forKey: .sources) ?? []
    }

    /// Visible when the active source confirmed it, or when nothing has attributed
    /// it yet — an unattributed row is not evidence that the source *lacks* it.
    func isVisible(under source: TraktWatchProgressSource) -> Bool {
        sources.isEmpty || sources.contains(source.rawValue)
    }

    func adding(source: TraktWatchProgressSource) -> WatchedStoreItem {
        WatchedStoreItem(
            meta: meta,
            watchedAt: watchedAt,
            season: season,
            episode: episode,
            sources: sources.union([source.rawValue])
        )
    }
}

/// File storage for payloads that must never reach `UserDefaults`.
///
/// tvOS aborts the process outright on an oversized preferences write —
/// `__CFPREFERENCES_HAS_DETECTED_THIS_APP_TRYING_TO_STORE_TOO_MUCH_DATA__`,
/// a `SIGABRT` with nothing to catch. Anything holding a `NuvioMeta` per row
/// reaches megabytes on a real account and must live in a file instead.
///
/// Mirrors ``WatchedStore``'s durable storage: Application Support first, then
/// Caches, because physical tvOS sideloads can reject Application Support
/// writes while Simulator succeeds. There is deliberately no `UserDefaults`
/// tier — falling back to preferences is the crash this exists to prevent, and
/// every caller is a cache or a store that can survive a failed write.
enum LargePayloadStore {
    /// Newest wins rather than preferred-tier-wins: when Application Support
    /// turns unwritable the stale file there usually can't be deleted either,
    /// and it would shadow the fresh Caches copy forever.
    static func read(key: String, directory: String) -> Data? {
        urls(key: key, directory: directory)
            .compactMap { url -> (Data, Date)? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return (data, modifiedAt)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// Returns whether the payload reached durable storage. Callers that also
    /// hold a legacy `UserDefaults` copy should clear it only on `true`.
    @discardableResult
    static func write(_ data: Data, key: String, directory: String) -> Bool {
        for url in urls(key: key, directory: directory) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url, options: [.atomic])
                // A stale copy on the other tier would outrank this one on the
                // next read if it happened to carry a newer timestamp.
                removeAll(key: key, directory: directory, except: url)
                return true
            } catch {
                continue
            }
        }
        print("Nuvio large payload write failed for \(key)")
        return false
    }

    static func remove(key: String, directory: String) {
        removeAll(key: key, directory: directory, except: nil)
    }

    static func removeDirectory(_ directory: String) {
        for base in [applicationSupportBase, cachesBase] {
            guard let url = base?.appendingPathComponent(directory, isDirectory: true) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func removeAll(key: String, directory: String, except keep: URL?) {
        for url in urls(key: key, directory: directory) where url != keep {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Preferred tier first.
    private static func urls(key: String, directory: String) -> [URL] {
        [applicationSupportBase, cachesBase].compactMap { base in
            base?
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent(fileName(forKey: key), isDirectory: false)
        }
    }

    private static var applicationSupportBase: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    private static var cachesBase: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nuvio", isDirectory: true)
    }

    /// Base64 so a profile-scoped key with `/` or `.` can't escape the
    /// directory or collide. Same encoding ``WatchedStore`` uses.
    private static func fileName(forKey key: String) -> String {
        Data(key.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
            + ".json"
    }
}

enum WatchedStore {
    static let changedNotification = Notification.Name("nuvio.tv.watched.changed")

    private static let baseKey = "nuvio.tv.watched.items"
    private static let storageDirectoryName = "WatchedStore"
    private(set) static var activeProfileId: String?

    /// Last durable-storage result, for diagnostics on physical devices where
    /// Application Support writes can fail while Simulator succeeds.
    static private(set) var persistenceDiagnostic = "not attempted"

    private enum PersistenceError: LocalizedError {
        case applicationSupportUnavailable
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "Application Support is unavailable"
            case .verificationFailed:
                return "the saved watched list could not be verified"
            }
        }
    }

    static func setActiveProfile(_ profileId: String?) {
        activeProfileId = profileId
        migrateSourcesIfNeeded()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Attributes rows written before `sources` existed.
    ///
    /// The best available reconstruction is the trackers' own cached snapshots:
    /// anything Simkl supplied is still listed there, so those rows are tagged
    /// accordingly and everything else is treated as Nuvio Sync's. Runs once per
    /// profile — after it, an empty `sources` means a genuinely new row rather
    /// than a legacy one.
    private static func migrateSourcesIfNeeded() {
        guard let id = activeProfileId, !id.isEmpty else { return }
        let flagKey = "nuvio.tv.watched.sourcesMigrated.\(id)"
        let store = ProfileSettings.store(for: id)
        guard !store.bool(forKey: flagKey) else { return }

        let current = items()
        guard !current.isEmpty else {
            store.set(true, forKey: flagKey)
            return
        }

        let simklKeys = Set(
            SimklSyncCache.history(in: store)
                .flatMap(\.items)
                .flatMap(watchedIdentityKeys)
        )
        let migrated = current.map { item -> WatchedStoreItem in
            guard item.sources.isEmpty else { return item }
            let source: TraktWatchProgressSource =
                watchedIdentityKeys(item).isDisjoint(with: simklKeys) ? .nuvioSync : .simkl
            return item.adding(source: source)
        }
        guard persist(migrated) else { return }
        store.set(true, forKey: flagKey)
    }

    private static var storageKey: String { storageKey(for: activeProfileId) }

    private static func storageKey(for profileId: String?) -> String {
        guard let id = profileId, !id.isEmpty else { return baseKey }
        return "\(baseKey).\(id)"
    }

    static func items() -> [WatchedStoreItem] {
        guard let data = readData(forKey: storageKey) else { return [] }
        do {
            return try makeDecoder().decode([WatchedStoreItem].self, from: data)
                .sorted { $0.watchedAt > $1.watchedAt }
        } catch {
            // Keep the payload intact so a later successful write can replace
            // it; silent decode-to-empty would wipe history on the next mark.
            persistenceDiagnostic = "decode failed: \(diagnosticText(for: error))"
            return []
        }
    }

    /// Whole-title watched state (movies, or a series marked watched
    /// explicitly). Episode-level entries deliberately don't count here so one
    /// finished episode doesn't checkmark the whole series poster.
    static func contains(metaId: String, type: String) -> Bool {
        visibleItems().contains {
            $0.meta.id.caseInsensitiveCompare(metaId) == .orderedSame
                && $0.meta.type.caseInsensitiveCompare(type) == .orderedSame
                && $0.season == nil && $0.episode == nil
        }
    }

    /// Rows the selected backend actually has — which is what every "is this
    /// watched?" question in the UI means. ``items()`` stays the full local
    /// union, because sync pushes and history transfers work from that.
    static func visibleItems() -> [WatchedStoreItem] {
        let source = TraktSettingsStore.watchProgressSource(in: ProfileSettings.current)
        return items().filter { $0.isVisible(under: source) }
    }

    /// Alias-aware keys for catalog badges. A Trakt IMDb row and a TMDB-backed
    /// catalog preview for the same title must resolve to the same checkmark.
    static func visibleWholeTitleIdentityKeys() -> Set<String> {
        Set(visibleItems().flatMap { item -> [String] in
            guard item.season == nil, item.episode == nil else { return [] }
            return Array(catalogTitleIdentityKeys(for: item.meta))
        })
    }

    static func catalogTitleIdentityKeys(for meta: NuvioMeta) -> Set<String> {
        let type = normalizedType(meta.type)
        return Set(contentIdentityKeys(for: meta).map { "\(type)\u{1f}\($0)" })
    }

    static func contains(meta: NuvioMeta) -> Bool {
        visibleItems().contains {
            sameContent($0.meta, meta) && $0.season == nil && $0.episode == nil
        }
    }

    static func containsEpisode(metaId: String, season: Int, episode: Int) -> Bool {
        visibleItems().contains {
            $0.meta.id.caseInsensitiveCompare(metaId) == .orderedSame
                && $0.season == season && $0.episode == episode
        }
    }

    static func containsEpisode(meta: NuvioMeta, season: Int, episode: Int) -> Bool {
        visibleItems().contains {
            sameContent($0.meta, meta) && $0.season == season && $0.episode == episode
        }
    }

    /// "season:episode" keys of every watched episode of a series, for the
    /// Details episode strip.
    static func watchedEpisodeKeys(metaId: String) -> Set<String> {
        Set(visibleItems().compactMap { item in
            guard item.meta.id.caseInsensitiveCompare(metaId) == .orderedSame,
                  let season = item.season,
                  let episode = item.episode else {
                return nil
            }
            return "\(season):\(episode)"
        })
    }

    static func watchedEpisodeKeys(meta: NuvioMeta) -> Set<String> {
        Set(visibleItems().compactMap { item in
            guard sameContent(item.meta, meta),
                  let season = item.season,
                  let episode = item.episode else {
                return nil
            }
            return "\(season):\(episode)"
        })
    }

    /// Toggles whole-title watched state and returns the **actual** persisted
    /// result. Callers must not assume the opposite of the previous value —
    /// a failed device write keeps the prior state.
    @discardableResult
    static func toggle(meta: NuvioMeta) -> Bool {
        if contains(meta: meta) {
            remove(meta: meta)
        } else {
            markWatched(meta)
        }
        return contains(meta: meta)
    }

    /// Episode equivalent of the working movie/title toggle. It uses the same
    /// durable local store and Trakt mutation path as playback completion.
    @discardableResult
    static func toggleEpisode(meta: NuvioMeta, season: Int, episode: Int) -> Bool {
        if containsEpisode(meta: meta, season: season, episode: episode) {
            removeEpisode(meta: meta, season: season, episode: episode)
        } else {
            markWatched(meta, season: season, episode: episode)
        }
        return containsEpisode(meta: meta, season: season, episode: episode)
    }

    /// Marks or clears every listed episode of one season in a single write.
    ///
    /// Looping ``toggleEpisode(meta:season:episode:)`` would re-read and re-persist
    /// the whole watched file per episode and send one request per episode to the
    /// backend — a twenty-episode season is twenty of each, and Simkl serialises
    /// writes behind a 20-second lock. The rows written here are identical to the
    /// ones ``markWatched(_:season:episode:)`` writes, so checkmarks, Continue
    /// Watching and sync attribution can't tell the two paths apart.
    @discardableResult
    static func setSeasonWatched(
        meta: NuvioMeta,
        season: Int,
        episodes: [Int],
        isWatched: Bool
    ) -> Bool {
        let episodeNumbers = Set(episodes)
        guard !episodeNumbers.isEmpty else { return false }

        let snapshot = meta.persistenceSnapshot
        let watchedAt = Date()
        let source = TraktSettingsStore.watchProgressSource(in: ProfileSettings.current)
        let untouched = items().filter { item in
            guard sameContent(item.meta, meta), item.season == season,
                  let episode = item.episode else { return true }
            return !episodeNumbers.contains(episode)
        }
        let written = episodeNumbers.sorted().map { episode in
            WatchedStoreItem(
                meta: snapshot,
                watchedAt: watchedAt,
                season: season,
                episode: episode,
                sources: [source.rawValue]
            )
        }
        guard persist(isWatched ? written + untouched : untouched) else { return false }

        for episode in episodeNumbers.sorted() {
            if isWatched {
                clearTombstone(meta: meta, season: season, episode: episode)
            } else {
                addTombstone(meta: snapshot, season: season, episode: episode)
            }
        }
        if isWatched {
            // Same ordering rule as the single-episode path: resume progress is
            // only dropped once the marks it is being replaced by are durable.
            ContinueWatchingStore.removeWatched(written)
        }

        let traktStore = ProfileSettings.current
        if RemoteTrackingState.shouldSyncWatchedHistory(to: .trakt, in: traktStore) {
            let profileId = activeProfileId
            // The pending ledger stays per episode — it is what confirms and
            // retries each row individually on the next pull.
            for episode in episodeNumbers.sorted() {
                _ = enqueuePendingTraktMutation(
                    meta: meta,
                    season: season,
                    episode: episode,
                    isWatched: isWatched,
                    profileId: profileId
                )
            }
            Task {
                _ = await TraktHistoryService.setWatched(
                    meta,
                    season: season,
                    episodes: episodeNumbers.sorted(),
                    isWatched: isWatched,
                    store: traktStore
                )
            }
        }
        if RemoteTrackingState.shouldSyncWatchedHistory(to: .simkl, in: traktStore) {
            Task {
                _ = await SimklHistoryService.setWatched(
                    meta,
                    season: season,
                    episodes: episodeNumbers.sorted(),
                    isWatched: isWatched,
                    store: traktStore
                )
            }
        }
        return true
    }

    @discardableResult
    static func markWatched(_ meta: NuvioMeta, season: Int? = nil, episode: Int? = nil) -> Bool {
        // A new mark belongs to whichever backend is selected — that is the one
        // it gets pushed to, and the only one that will confirm it on a pull.
        let item = WatchedStoreItem(
            meta: meta.persistenceSnapshot,
            watchedAt: Date(),
            season: season,
            episode: episode,
            sources: [TraktSettingsStore.watchProgressSource(in: ProfileSettings.current).rawValue]
        )
        let updated = [item] + items().filter {
            !(sameContent($0.meta, meta)
                && $0.season == season && $0.episode == episode)
        }
        guard persist(updated) else { return false }
        // The mark is durable now, so it is safe to cancel any pending remote
        // delete. A failed watched-list write must leave that protection intact.
        clearTombstone(meta: meta, season: season, episode: episode)

        // Only clear Continue Watching after the watched mark is durable, so a
        // failed write does not drop resume progress with nothing to replace it.
        // The rendered row, the raw ledger it is rebuilt from, and the remote
        // provider's optimistic layer all have to be cleared: leaving any one of
        // them holding this episode puts the resume bar back on the next render.
        ContinueWatchingStore.markLedgerWatched(meta: meta, season: season, episode: episode)
        ContinueWatchingStore.removeWatched([item])
        let markedAt = item.watchedAt
        Task { @MainActor in
            TraktProgressService.forgetLocalPlayback(
                meta: meta,
                season: season,
                episode: episode,
                recordedNoLaterThan: markedAt,
                notify: true
            )
        }
        let traktStore = ProfileSettings.current
        if RemoteTrackingState.shouldSyncWatchedHistory(to: .trakt, in: traktStore) {
            let profileId = activeProfileId
            _ = enqueuePendingTraktMutation(
                meta: meta,
                season: season,
                episode: episode,
                isWatched: true,
                profileId: profileId
            )
            Task {
                _ = await TraktHistoryService.setWatched(
                    meta,
                    season: season,
                    episode: episode,
                    isWatched: true,
                    store: traktStore
                )
            }
        }
        if RemoteTrackingState.shouldSyncWatchedHistory(to: .simkl, in: traktStore) {
            Task {
                _ = await SimklHistoryService.setWatched(
                    meta,
                    season: season,
                    episode: episode,
                    isWatched: true,
                    store: traktStore
                )
            }
        }
        return true
    }

    @discardableResult
    static func remove(meta: NuvioMeta) -> Bool {
        let currentItems = items()
        let removed = currentItems.first {
            sameContent($0.meta, meta) && $0.season == nil && $0.episode == nil
        }
        let updated = currentItems.filter {
            !(sameContent($0.meta, meta) && $0.season == nil && $0.episode == nil)
        }
        guard persist(updated) else { return false }
        let removedMeta = removed?.meta ?? meta.persistenceSnapshot
        addTombstone(meta: removedMeta, season: nil, episode: nil)
        enqueueTraktRemovalIfConnected(meta: removedMeta, season: nil, episode: nil)
        return true
    }

    /// Removes the whole-title mark only; per-episode history stays. Leaves a
    /// tombstone so the next sync deletes the remote row instead of pulling the
    /// mark right back. Tombstone is written only after the local list saves.
    @discardableResult
    static func remove(metaId: String, type: String) -> Bool {
        let currentItems = items()
        let removed = currentItems.first {
            $0.meta.id == metaId
                && $0.meta.type.caseInsensitiveCompare(type) == .orderedSame
                && $0.season == nil && $0.episode == nil
        }
        let updated = currentItems.filter {
            !($0.meta.id == metaId
                && $0.meta.type.caseInsensitiveCompare(type) == .orderedSame
                && $0.season == nil && $0.episode == nil)
        }
        guard persist(updated) else { return false }
        guard let removed else { return true }
        addTombstone(meta: removed.meta, season: nil, episode: nil)
        enqueueTraktRemovalIfConnected(meta: removed.meta, season: nil, episode: nil)
        return true
    }

    @discardableResult
    private static func removeEpisode(meta: NuvioMeta, season: Int, episode: Int) -> Bool {
        let currentItems = items()
        let updated = currentItems.filter {
            !(sameContent($0.meta, meta)
                && $0.season == season && $0.episode == episode)
        }
        guard persist(updated) else { return false }
        addTombstone(meta: meta, season: season, episode: episode)
        enqueueTraktRemovalIfConnected(meta: meta, season: season, episode: episode)
        return true
    }

    private static func enqueueTraktRemovalIfConnected(
        meta: NuvioMeta,
        season: Int?,
        episode: Int?
    ) {
        let traktStore = ProfileSettings.current
        if RemoteTrackingState.shouldSyncWatchedHistory(to: .trakt, in: traktStore) {
            let profileId = activeProfileId
            _ = enqueuePendingTraktMutation(
                meta: meta,
                season: season,
                episode: episode,
                isWatched: false,
                profileId: profileId
            )
            Task {
                _ = await TraktHistoryService.setWatched(
                    meta,
                    season: season,
                    episode: episode,
                    isWatched: false,
                    store: traktStore
                )
            }
        }
        if RemoteTrackingState.shouldSyncWatchedHistory(to: .simkl, in: traktStore) {
            Task {
                _ = await SimklHistoryService.setWatched(
                    meta,
                    season: season,
                    episode: episode,
                    isWatched: false,
                    store: traktStore
                )
            }
        }
    }

    /// Merges a FULL remote snapshot. Tombstones (locally removed marks) block
    /// their remote row and stay alive until a pull shows the row is really
    /// gone from the server — the pushed delete is best-effort, so the pull is
    /// the confirmation. A newer re-watch on another device supersedes one.
    @discardableResult
    static func mergeRemote(
        _ remoteItems: [WatchedStoreItem],
        confirmsTombstoneDeletions: Bool = true
    ) -> Bool {
        let removedMarks = tombstones()
        guard !remoteItems.isEmpty || !removedMarks.isEmpty else { return true }

        let stillBlocking = removedMarks.filter { tombstone in
            let matchingRemote = remoteItems.first {
                tombstoneMatches(tombstone, item: $0)
            }
            if confirmsTombstoneDeletions {
                guard let matchingRemote else { return false }
                return matchingRemote.watchedAt <= tombstone.removedAt
            }
            // A Trakt snapshot cannot confirm that the separate Nuvio backend
            // applied its delete. Keep the tombstone unless Trakt contains a
            // genuinely newer re-watch.
            return matchingRemote == nil || matchingRemote!.watchedAt <= tombstone.removedAt
        }
        if stillBlocking.count != removedMarks.count {
            _ = persistTombstones(stillBlocking)
        }

        let accepted = remoteItems.filter { item in
            !stillBlocking.contains { tombstoneMatches($0, item: item) }
        }

        let merged = mergedByIdentity(items() + accepted)
        guard persist(merged) else { return false }
        ContinueWatchingStore.removeWatched(merged)
        return true
    }

    /// Applies Trakt as the authoritative watched snapshot. Local marks created
    /// after this request began are preserved; older Trakt-addressable marks
    /// absent from the snapshot become tombstones so a later Nuvio pull cannot
    /// resurrect them.
    @discardableResult
    static func reconcileTraktSnapshot(
        _ remoteItems: [WatchedStoreItem],
        syncStartedAt: Date
    ) -> Bool {
        let remoteItems = remoteItems.map { $0.adding(source: .trakt) }
        guard mergeRemote(remoteItems, confirmsTombstoneDeletions: false) else { return false }

        let remoteKeys = Set(remoteItems.flatMap(traktIdentityKeys))
        let pendingMarks = pendingTraktMutations().filter(\.isWatched)
        let current = items()
        let obsolete = current.filter { item in
            guard item.watchedAt <= syncStartedAt,
                  isRepresentedByTraktSnapshot(item) else { return false }
            let keys = traktIdentityKeys(item)
            guard keys.isDisjoint(with: remoteKeys) else { return false }
            return !pendingMarks.contains { pendingMatches($0, item: item) }
        }
        if !obsolete.isEmpty {
            let obsoleteIDs = Set(obsolete.map(\.id))
            guard persist(current.filter { !obsoleteIDs.contains($0.id) }) else { return false }
            obsolete.forEach {
                addTombstone(meta: $0.meta, season: $0.season, episode: $0.episode)
            }
        }
        confirmPendingTraktMutations(against: remoteItems)
        return true
    }

    /// Applies Simkl's cached remote snapshot while removing only rows that
    /// were previously supplied by Simkl. Local or Trakt-only marks are not
    /// treated as deletions, and marks created while the pull was running win.
    @discardableResult
    static func reconcileSimklSnapshot(
        _ remoteItems: [WatchedStoreItem],
        previousRemoteItems: [WatchedStoreItem],
        syncStartedAt: Date
    ) -> Bool {
        let remoteItems = remoteItems.map { $0.adding(source: .simkl) }
        guard mergeRemote(remoteItems, confirmsTombstoneDeletions: false) else { return false }

        let currentRemoteKeys = Set(remoteItems.flatMap(watchedIdentityKeys))
        let removedRemoteKeys = Set(previousRemoteItems.flatMap(watchedIdentityKeys))
            .subtracting(currentRemoteKeys)
        guard !removedRemoteKeys.isEmpty else { return true }

        let current = items()
        let updated = current.filter { item in
            guard item.watchedAt <= syncStartedAt else { return true }
            return watchedIdentityKeys(item).isDisjoint(with: removedRemoteKeys)
        }
        return updated.count == current.count || persist(updated)
    }

    static func sameContent(_ lhs: NuvioMeta, _ rhs: NuvioMeta) -> Bool {
        guard normalizedType(lhs.type) == normalizedType(rhs.type) else { return false }
        return !contentIdentityKeys(for: lhs).isDisjoint(with: contentIdentityKeys(for: rhs))
    }

    static func isRepresentedByTraktSnapshot(_ item: WatchedStoreItem) -> Bool {
        // Trakt represents a watched show as episode rows, not as a distinct
        // whole-series row. Keep the local title-level marker while reconciling
        // the episode history that Trakt can actually describe.
        if normalizedType(item.meta.type) == "series",
           item.season == nil,
           item.episode == nil { return false }
        return !traktIdentityKeys(item).isEmpty
    }

    /// Deduplicates a watched snapshot in one indexed pass. The previous
    /// implementation scanned every accumulated row for every incoming row,
    /// which made a large Trakt history quadratic and could block tvOS's main
    /// thread long enough to trigger the scene-update watchdog.
    static func mergedByIdentity(_ items: [WatchedStoreItem]) -> [WatchedStoreItem] {
        var merged: [WatchedStoreItem] = []
        merged.reserveCapacity(items.count)
        var indexByIdentity: [String: Int] = [:]
        indexByIdentity.reserveCapacity(items.count)

        for item in items {
            let identityKeys = watchedIdentityKeys(item)
            let existingIndex = identityKeys.compactMap { indexByIdentity[$0] }.min()

            if let existingIndex {
                // The newer row wins on timing, but attribution accumulates:
                // dropping the loser's sources would forget that the other
                // backend also has this mark.
                let combined = merged[existingIndex].sources.union(item.sources)
                if item.watchedAt > merged[existingIndex].watchedAt {
                    merged[existingIndex] = item
                }
                merged[existingIndex].sources = combined
                // Retain every alias learned for this content so a later row
                // can match by IMDb, TMDB, or catalog id without another scan.
                for key in identityKeys {
                    indexByIdentity[key] = min(indexByIdentity[key] ?? existingIndex, existingIndex)
                }
            } else {
                let index = merged.count
                merged.append(item)
                for key in identityKeys {
                    indexByIdentity[key] = index
                }
            }
        }

        return merged.sorted { $0.watchedAt > $1.watchedAt }
    }

    static func newestWatchedDatesByIdentity(_ items: [WatchedStoreItem]) -> [String: Date] {
        var newestByIdentity: [String: Date] = [:]
        newestByIdentity.reserveCapacity(items.count)
        for item in items {
            for key in watchedIdentityKeys(item) {
                if item.watchedAt > (newestByIdentity[key] ?? .distantPast) {
                    newestByIdentity[key] = item.watchedAt
                }
            }
        }
        return newestByIdentity
    }

    private static func watchedIdentityKeys(_ item: WatchedStoreItem) -> Set<String> {
        watchedIdentityKeys(
            metaId: item.meta.id,
            imdbId: item.meta.imdbId,
            tmdbId: item.meta.tmdbId,
            contentType: item.meta.type,
            season: item.season,
            episode: item.episode
        )
    }

    static func watchedIdentityKeys(
        metaId: String,
        imdbId: String?,
        tmdbId: Int?,
        contentType: String,
        season: Int?,
        episode: Int?
    ) -> Set<String> {
        let type = normalizedType(contentType)
        let season = season.map(String.init) ?? "-"
        let episode = episode.map(String.init) ?? "-"
        return Set(contentIdentityKeys(metaId: metaId, imdbId: imdbId, tmdbId: tmdbId).map {
            "\(type)|\($0)|\(season)|\(episode)"
        })
    }

    private static let identityTrimmingCharacters = CharacterSet.whitespacesAndNewlines

    private static func contentIdentityKeys(for meta: NuvioMeta) -> Set<String> {
        contentIdentityKeys(metaId: meta.id, imdbId: meta.imdbId, tmdbId: meta.tmdbId)
    }

    private static func contentIdentityKeys(
        metaId: String,
        imdbId: String?,
        tmdbId: Int?
    ) -> Set<String> {
        var keys: Set<String> = []
        let rawID = metaId.trimmingCharacters(in: identityTrimmingCharacters).lowercased()
        if !rawID.isEmpty {
            if rawID.hasPrefix("tt") {
                keys.insert("imdb:\(rawID)")
            } else if rawID.hasPrefix("tmdb:") || rawID.hasPrefix("trakt:") {
                keys.insert(rawID)
            } else {
                keys.insert("id:\(rawID)")
            }
        }
        if let imdb = imdbId?.trimmingCharacters(in: identityTrimmingCharacters).lowercased(),
           !imdb.isEmpty {
            keys.insert("imdb:\(imdb)")
        }
        if let tmdbId {
            keys.insert("tmdb:\(tmdbId)")
        }
        return keys
    }

    private static func normalizedType(_ type: String) -> String {
        switch type.lowercased() {
        case "series", "tv", "show", "tvshow": return "series"
        default: return type.lowercased()
        }
    }

    private static func traktIdentityKeys(_ item: WatchedStoreItem) -> Set<String> {
        Set(contentIdentityKeys(for: item.meta).map {
            "\($0)|\(item.season.map(String.init) ?? "-")|\(item.episode.map(String.init) ?? "-")"
        })
    }

    // MARK: Pending Trakt mutations

    struct PendingTraktMutation: Codable, Identifiable {
        let id: String
        let meta: NuvioMeta
        let season: Int?
        let episode: Int?
        let isWatched: Bool
        let changedAt: Date
    }

    private static func pendingTraktStorageKey(for profileId: String?) -> String {
        "\(storageKey(for: profileId)).pendingTrakt"
    }

    static func pendingTraktMutations(profileId: String? = activeProfileId) -> [PendingTraktMutation] {
        guard let data = readData(forKey: pendingTraktStorageKey(for: profileId)),
              let decoded = try? makeDecoder().decode([PendingTraktMutation].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.changedAt < $1.changedAt }
    }

    @discardableResult
    private static func enqueuePendingTraktMutation(
        meta: NuvioMeta,
        season: Int?,
        episode: Int?,
        isWatched: Bool,
        profileId: String?
    ) -> Bool {
        let entry = PendingTraktMutation(
            id: UUID().uuidString,
            meta: meta.persistenceSnapshot,
            season: season,
            episode: episode,
            isWatched: isWatched,
            changedAt: Date()
        )
        let updated = pendingTraktMutations(profileId: profileId).filter {
            !(sameContent($0.meta, meta) && $0.season == season && $0.episode == episode)
        } + [entry]
        return persistPendingTraktMutations(updated, profileId: profileId)
    }

    private static func confirmPendingTraktMutations(against remoteItems: [WatchedStoreItem]) {
        let pending = pendingTraktMutations()
        guard !pending.isEmpty else { return }
        let remaining = pending.filter { mutation in
            let existsRemotely = remoteItems.contains { pendingMatches(mutation, item: $0) }
            return mutation.isWatched ? !existsRemotely : existsRemotely
        }
        guard remaining.count != pending.count else { return }
        _ = persistPendingTraktMutations(remaining, profileId: activeProfileId)
    }

    private static func pendingMatches(
        _ pending: PendingTraktMutation,
        item: WatchedStoreItem
    ) -> Bool {
        guard sameContent(pending.meta, item.meta) else { return false }
        if normalizedType(pending.meta.type) == "series",
           pending.season == nil,
           pending.episode == nil {
            return true
        }
        return pending.season == item.season && pending.episode == item.episode
    }

    @discardableResult
    private static func persistPendingTraktMutations(
        _ entries: [PendingTraktMutation],
        profileId: String?
    ) -> Bool {
        guard let data = try? makeEncoder().encode(entries) else { return false }
        return writeData(data, forKey: pendingTraktStorageKey(for: profileId), verify: { payload in
            _ = try makeDecoder().decode([PendingTraktMutation].self, from: payload)
        })
    }

    static func clearPendingTraktMutations(profileId: String?) {
        _ = persistPendingTraktMutations([], profileId: profileId)
    }

    // MARK: Tombstones — locally deleted marks awaiting remote deletion

    struct Tombstone: Codable, Equatable {
        let metaId: String
        let contentType: String?
        let imdbId: String?
        let tmdbId: Int?
        let season: Int?
        let episode: Int?
        let removedAt: Date
    }

    private static var tombstoneStorageKey: String {
        tombstoneStorageKey(for: activeProfileId)
    }

    private static func tombstoneStorageKey(for profileId: String?) -> String {
        guard let id = profileId, !id.isEmpty else { return "\(baseKey).tombstones" }
        return "\(baseKey).tombstones.\(id)"
    }

    static func tombstones() -> [Tombstone] {
        guard let data = readData(forKey: tombstoneStorageKey),
              let decoded = try? JSONDecoder().decode([Tombstone].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func addTombstone(meta: NuvioMeta, season: Int?, episode: Int?) {
        let entry = Tombstone(
            metaId: meta.id,
            contentType: meta.type,
            imdbId: meta.imdbId,
            tmdbId: meta.tmdbId,
            season: season,
            episode: episode,
            removedAt: Date()
        )
        let updated = tombstones().filter {
            !(tombstoneContentMatches($0, meta: meta)
                && $0.season == season && $0.episode == episode)
        } + [entry]
        _ = persistTombstones(updated)
    }

    private static func clearTombstone(meta: NuvioMeta, season: Int?, episode: Int?) {
        _ = persistTombstones(tombstones().filter {
            !(tombstoneContentMatches($0, meta: meta)
                && $0.season == season && $0.episode == episode)
        })
    }

    private static func tombstoneMatches(_ tombstone: Tombstone, item: WatchedStoreItem) -> Bool {
        guard tombstoneContentMatches(tombstone, meta: item.meta) else { return false }
        if normalizedType(tombstone.contentType ?? item.meta.type) == "series",
           tombstone.season == nil,
           tombstone.episode == nil {
            return true
        }
        return tombstone.season == item.season && tombstone.episode == item.episode
    }

    private static func tombstoneContentMatches(_ tombstone: Tombstone, meta: NuvioMeta) -> Bool {
        if let contentType = tombstone.contentType,
           normalizedType(contentType) != normalizedType(meta.type) {
            return false
        }
        let tombstoneKeys = contentIdentityKeys(
            metaId: tombstone.metaId,
            imdbId: tombstone.imdbId,
            tmdbId: tombstone.tmdbId
        )
        return !tombstoneKeys.isDisjoint(with: contentIdentityKeys(for: meta))
    }

    /// Called after the remote rows were deleted successfully.
    static func clearTombstones(_ cleared: [Tombstone]) {
        _ = persistTombstones(tombstones().filter { !cleared.contains($0) })
    }

    @discardableResult
    private static func persistTombstones(_ entries: [Tombstone]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        return writeData(data, forKey: tombstoneStorageKey, verify: { payload in
            _ = try makeDecoder().decode([Tombstone].self, from: payload)
        })
    }

    static func replaceAll(_ newItems: [WatchedStoreItem]) {
        // Re-snapshot so older rows with non-finite ratings or bloated guides
        // cannot poison a later encode of the full list.
        let sanitized = newItems.map {
            WatchedStoreItem(
                meta: $0.meta.persistenceSnapshot,
                watchedAt: $0.watchedAt,
                season: $0.season,
                episode: $0.episode
            )
        }
        _ = persist(sanitized.sorted { $0.watchedAt > $1.watchedAt })
    }

    @discardableResult
    private static func persist(_ items: [WatchedStoreItem]) -> Bool {
        let data: Data
        do {
            data = try makeEncoder().encode(items)
        } catch {
            persistenceDiagnostic = "encode failed: \(diagnosticText(for: error))"
            print("Nuvio watched storage encode failed: \(error.localizedDescription)")
            return false
        }

        let saved = writeData(data, forKey: storageKey, verify: { payload in
            _ = try makeDecoder().decode([WatchedStoreItem].self, from: payload)
        })
        guard saved else { return false }
        NotificationCenter.default.post(name: changedNotification, object: nil)
        return true
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Same strategy as ContinueWatchingStore — default JSONEncoder throws on
        // Double.nan and a bare `try?` would drop the whole watched write.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }

    /// Deletes one profile's watched marks and tombstones, leaving every other
    /// profile untouched.
    ///
    /// ``eraseAllProfiles()`` is a sign-out operation — it removes the whole
    /// storage directory. Anything that only needs to clean up after itself
    /// (tests, in particular, which run inside the app's own container and so
    /// share these files with a real install) must use this instead.
    static func eraseProfile(_ profileId: String) {
        let keys = [storageKey(for: profileId), tombstoneStorageKey(for: profileId)]
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
            if let url = storageURL(forKey: key) {
                try? FileManager.default.removeItem(at: url)
            }
            if let url = fallbackStorageURL(forKey: key) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Deletes every profile's watched marks and tombstones (the tombstone keys
    /// share `baseKey` as their prefix) on sign-out.
    static func eraseAllProfiles() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(baseKey) }
            .forEach { defaults.removeObject(forKey: $0) }
        if let directory = storageDirectoryURL {
            try? FileManager.default.removeItem(at: directory)
        }
        if let directory = fallbackStorageDirectoryURL {
            try? FileManager.default.removeItem(at: directory)
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    // MARK: - Durable file storage (Application Support + Caches fallback)

    private static func readData(forKey key: String) -> Data? {
        // A failed primary write can leave an older Application Support file
        // beside a newer Caches fallback. Always choose the newest verified
        // byte stream instead of blindly preferring the stale primary copy.
        if let stored = newestStoredFile(forKey: key) {
            if stored.isFallback, let primaryURL = storageURL(forKey: key) {
                // Promote directly to the primary path. Calling writeData here
                // could succeed by writing Caches again and then delete the only
                // good fallback while incorrectly reporting a recovery.
                do {
                    try writeAndVerify(stored.data, to: primaryURL, verify: nil)
                    try? FileManager.default.removeItem(at: stored.url)
                    persistenceDiagnostic = "recovered Application Support storage"
                } catch {
                    persistenceDiagnostic = "using Caches fallback: \(diagnosticText(for: error))"
                }
            } else if !stored.isFallback,
                      let fallbackURL = fallbackStorageURL(forKey: key),
                      FileManager.default.fileExists(atPath: fallbackURL.path) {
                try? FileManager.default.removeItem(at: fallbackURL)
            }
            return stored.data
        }

        guard let defaultsData = UserDefaults.standard.data(forKey: key) else {
            return nil
        }

        // Older builds stored watched history in UserDefaults. Large accounts
        // can exceed tvOS preferences limits, so migrate each profile key to a
        // file the first time it is touched.
        if writeData(defaultsData, forKey: key, updateDiagnostic: false) {
            UserDefaults.standard.removeObject(forKey: key)
            persistenceDiagnostic = "migrated UserDefaults watched history"
        }
        return defaultsData
    }

    private struct StoredFile {
        let data: Data
        let url: URL
        let modifiedAt: Date
        let isFallback: Bool
    }

    private static func newestStoredFile(forKey key: String) -> StoredFile? {
        var candidates: [StoredFile] = []
        if let url = storageURL(forKey: key),
           let data = try? Data(contentsOf: url) {
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append(StoredFile(data: data, url: url, modifiedAt: modifiedAt, isFallback: false))
        }
        if let url = fallbackStorageURL(forKey: key),
           let data = try? Data(contentsOf: url) {
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            candidates.append(StoredFile(data: data, url: url, modifiedAt: modifiedAt, isFallback: true))
        }
        return candidates.max { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                // A remaining fallback represents a primary-write failure, so
                // let it win coarse filesystem timestamp ties.
                return !lhs.isFallback && rhs.isFallback
            }
            return lhs.modifiedAt < rhs.modifiedAt
        }
    }

    /// Writes `data` with a verify-read. Tries Application Support, then Caches.
    /// Optional `verify` round-trips the payload through JSON decode so a write
    /// that `items()` cannot load never reports success.
    @discardableResult
    private static func writeData(
        _ data: Data,
        forKey key: String,
        updateDiagnostic: Bool = true,
        verify: ((Data) throws -> Void)? = nil
    ) -> Bool {
        var primaryError: Error?

        if let url = storageURL(forKey: key) {
            do {
                try writeAndVerify(data, to: url, verify: verify)
                if let fallbackURL = fallbackStorageURL(forKey: key),
                   FileManager.default.fileExists(atPath: fallbackURL.path) {
                    try? FileManager.default.removeItem(at: fallbackURL)
                }
                if updateDiagnostic {
                    persistenceDiagnostic = "Application Support: \(data.count) bytes"
                }
                return true
            } catch {
                primaryError = error
            }
        } else {
            primaryError = PersistenceError.applicationSupportUnavailable
        }

        // Physical tvOS sideloads / some install paths can reject Application
        // Support writes while Simulator succeeds. Keep a verified Caches copy
        // so the mark still survives the session (and often longer).
        if let fallbackURL = fallbackStorageURL(forKey: key) {
            do {
                try writeAndVerify(data, to: fallbackURL, verify: verify)
                if let primaryURL = storageURL(forKey: key),
                   FileManager.default.fileExists(atPath: primaryURL.path) {
                    try? FileManager.default.removeItem(at: primaryURL)
                }
                let reason = primaryError.map(diagnosticText(for:)) ?? "unknown error"
                if updateDiagnostic {
                    persistenceDiagnostic = "Caches fallback: \(data.count) bytes; \(reason)"
                    print("Nuvio watched storage using Caches fallback: \(reason)")
                }
                return true
            } catch {
                let primaryReason = primaryError.map(diagnosticText(for:)) ?? "unknown error"
                persistenceDiagnostic = "save failed: \(primaryReason); Caches fallback: \(diagnosticText(for: error))"
                print("Nuvio watched storage write failed: \(persistenceDiagnostic)")
                return false
            }
        }

        let reason = primaryError.map(diagnosticText(for:)) ?? "unknown error"
        persistenceDiagnostic = "save failed: \(reason); Caches unavailable"
        print("Nuvio watched storage write failed: \(persistenceDiagnostic)")
        return false
    }

    private static func writeAndVerify(
        _ data: Data,
        to url: URL,
        verify: ((Data) throws -> Void)?
    ) throws {
        if let verify {
            try verify(data)
        }
        try write(data, to: url)
        guard let saved = try? Data(contentsOf: url), saved == data else {
            throw PersistenceError.verificationFailed
        }
        if let verify {
            try verify(saved)
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    private static var storageDirectoryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    private static var fallbackStorageDirectoryURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nuvio", isDirectory: true)
            .appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    private static func storageURL(forKey key: String) -> URL? {
        storageDirectoryURL?.appendingPathComponent(fileName(forKey: key), isDirectory: false)
    }

    private static func fallbackStorageURL(forKey key: String) -> URL? {
        fallbackStorageDirectoryURL?.appendingPathComponent(fileName(forKey: key), isDirectory: false)
    }

    private static func fileName(forKey key: String) -> String {
        Data(key.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
            + ".json"
    }

    private static func diagnosticText(for error: Error) -> String {
        let singleLine = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
        return String(singleLine.prefix(160))
    }
}

// MARK: - Per-profile settings

/// Backs every app setting with a per-profile `UserDefaults` suite so changing
/// the theme (or any other preference) on one profile never affects another.
///
/// SwiftUI views read it through `.defaultAppStorage(ProfileSettings.store(for:))`
/// so the 100-odd `@AppStorage` sites need no changes; the few direct
/// `UserDefaults` reads (subtitle style/language, reset) use `.current`.
///
/// A new profile is seeded with a copy of the active profile's settings at
    /// creation, then diverges independently. Existing installs whose settings live
    /// in `.standard` migrate that snapshot into each profile the first time it is
    /// used, so nobody loses their preferences when profiles arrive.
enum ProfileSettings {
    private static let suitePrefix = "nuvio.tv.profile.settings"
    private static let seededFlag = "nuvio.tv.profile.settings.seeded"

    /// Settings store for the active profile. `.standard` until one is loaded
    /// (e.g. on the login / "Who's watching?" screens).
    private(set) static var current: UserDefaults = .standard
    private(set) static var activeProfileID: String?

    /// Stable Keychain namespace for secrets belonging to the active profile.
    static var activeProfileScope: String { activeProfileID ?? "default" }

    /// The suite backing a given profile id, or `.standard` when there is none.
    /// `UserDefaults(suiteName:)` returns the same shared store for a name, so
    /// repeated calls for one profile all read and write the same values.
    static func store(for profileId: String?) -> UserDefaults {
        guard let id = profileId, !id.isEmpty,
              let suite = UserDefaults(suiteName: "\(suitePrefix).\(id)") else {
            return .standard
        }
        return suite
    }

    /// Point reads/writes at a profile. Called on launch and on every switch.
    /// Seeds the profile from the pre-profile global settings the first time it
    /// is used so existing installs keep their preferences.
    static func setActiveProfile(_ profileId: String?) {
        guard let id = profileId, !id.isEmpty else { return }
        let suite = store(for: id)
        let needsSeed = !suite.bool(forKey: seededFlag)
        seedFromGlobalIfNeeded(suite)
        current = suite
        activeProfileID = id
        AISubtitleKeyStore.migrateLegacyKey(from: suite, profileScope: id)
        if needsSeed {
            AISubtitleKeyStore.migrateLegacyKey(from: .standard, profileScope: id)
        }
        // Must run after `current` is pointed at the profile, and after the
        // watch-state stores have been scoped, because it inspects this
        // profile's Trakt/Simkl credentials.
        TraktSettingsStore.migrateWatchProgressSourceIfNeeded(in: suite)
    }

    static func clearActiveProfile() {
        current = .standard
        activeProfileID = nil
    }

    /// Deletes the given profiles' settings suites and the pre-profile copies
    /// in `.standard`, so sign-out leaves no add-ons, API keys, or preferences
    /// behind. Points `current` back at `.standard` first so nothing keeps
    /// writing into a removed suite.
    static func eraseAll(profileIds: [String]) {
        current = .standard
        activeProfileID = nil
        let simklTokenStorage = SimklKeychainTokenStorage()
        for id in Set(profileIds) where !id.isEmpty {
            simklTokenStorage.setAccessToken(nil, for: id)
            AISubtitleKeyStore.remove(profileScope: id)
            Task { await AISubtitleTranslationCache.shared.removeAll(profileScope: id) }
            UserDefaults.standard.removePersistentDomain(forName: "\(suitePrefix).\(id)")
        }
        AISubtitleKeyStore.remove(profileScope: "default")
        Task { await AISubtitleTranslationCache.shared.removeAll(profileScope: "default") }
        SimklAuthStore.clearAuth(
            profileScope: "default",
            store: .standard,
            tokenStorage: simklTokenStorage
        )
        // Removing the suites no longer takes the sync caches with them — they
        // are files now, and would otherwise be inherited by the next account.
        SimklSyncCache.eraseAll()
        for key in SettingsKey.all {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Clone the current profile's settings into a freshly created profile, then
    /// mark it seeded so the global migration never overwrites the copy.
    static func seedNewProfile(_ profileId: String, copyingFrom source: UserDefaults? = nil) {
        let destination = store(for: profileId)
        copySettings(from: source ?? current, to: destination)
        // Secrets never cross profile boundaries. Keep AI translation disabled
        // until this profile explicitly supplies its own Keychain credential.
        destination.set(false, forKey: SettingsKey.aiSubtitlesEnabled)
        destination.removeObject(forKey: SettingsKey.aiSubtitlesGeminiAPIKey)
        destination.set(true, forKey: seededFlag)
    }

    private static func seedFromGlobalIfNeeded(_ suite: UserDefaults) {
        guard !suite.bool(forKey: seededFlag) else { return }
        copySettings(from: .standard, to: suite)
        suite.set(true, forKey: seededFlag)
    }

    private static func copySettings(from source: UserDefaults, to destination: UserDefaults) {
        guard source != destination else { return }
        for key in SettingsKey.all where key != SettingsKey.aiSubtitlesGeminiAPIKey {
            if let value = source.object(forKey: key) {
                destination.set(value, forKey: key)
            } else {
                destination.removeObject(forKey: key)
            }
        }
    }
}

/// Paginated catalog page
struct CatalogPage {
    let items: [NuvioMeta]
    let hasMore: Bool
    let page: Int
    let nextSkip: Int?

    init(
        items: [NuvioMeta],
        hasMore: Bool,
        page: Int,
        nextSkip: Int? = nil
    ) {
        self.items = items
        self.hasMore = hasMore
        self.page = page
        self.nextSkip = nextSkip
    }
}

// MARK: - Filter & Sort Models

/// Filter state for catalog browsing
struct FilterState: Equatable {
    var contentType: String = "movie"
    var genre: String? = nil
    var year: Int? = nil
    var sort: SortOption = .trending
}

/// Sort options for catalog
enum SortOption: String, CaseIterable {
    case trending = "top"
    case popular = "popular"
    case newest = "newest"
    case rating = "rating"

    var displayName: String {
        switch self {
        case .trending: return "Trending"
        case .popular: return "Popular"
        case .newest: return "Newest"
        case .rating: return "Top Rated"
        }
    }

    var catalogId: String {
        return self.rawValue
    }
}

// MARK: - UI State

/// UI state for catalog browse screen
struct CatalogBrowseUiState {
    var isLoading: Bool = false
    var items: [NuvioMeta] = []
    var currentPage: Int = 1
    var hasMore: Bool = true
    var filterState: FilterState = FilterState()
    var availableGenres: [String] = []
    var error: String? = nil
    var isLoadingMore: Bool = false
}

/// UI state for details screen
struct DetailsUiState {
    var isLoading: Bool = true
    var meta: NuvioMeta? = nil
    var streams: [NuvioStream] = []
    /// Per-add-on groups for the stream picker (stable ids, loading/error).
    var streamGroups: [AddonStreamGroup] = []
    /// Mirrors `StreamsDiscoveryState.revision` for cheap picker cache invalidation.
    var streamsRevision: UInt64 = 0
    var isLoadingStreams: Bool = false
    var streamsEmptyReason: StreamsEmptyStateReason? = nil
    var error: String? = nil
    var isInWatchlist: Bool = false
    var isWatched: Bool = false
    /// Related titles under the cast row (TMDB, Trakt, or Simkl recommendations).
    var moreLikeThis: [RelatedTitle] = []
    /// Production companies + networks from TMDB.
    var companies: [MetaCompany] = []
    /// TMDB creator/director and cast people, including profile photos.
    var people: [TmdbPersonMetadata] = []
    /// Simkl community rating, catalog rank, and drop rate.
    var simklRatings: SimklTitleRatings? = nil
    /// Top liked Trakt comments (max 5).
    var comments: [TraktCommentReview] = []
    var isLoadingEnrichment: Bool = false
}
