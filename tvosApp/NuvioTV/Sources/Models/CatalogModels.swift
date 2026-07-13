//
//  CatalogModels.swift
//  NuvioTV
//
//  Created by Claude Code
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

    init(
        id: String,
        name: String,
        description: String,
        itemIds: [String],
        items: [NuvioMeta]? = nil,
        contentType: String? = nil,
        catalogId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.itemIds = itemIds
        self.items = items
        self.contentType = contentType
        self.catalogId = catalogId
    }
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

    var isSeries: Bool { type == "series" }

    /// Series status badge text ("ONGOING" / "ENDED"); nil for movies or
    /// when Cinemeta didn't provide a status. Shared by the details header
    /// and the Home hero.
    var statusBadgeLabel: String? {
        guard isSeries,
              let status = status?.trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty else { return nil }
        return status.caseInsensitiveCompare("Continuing") == .orderedSame ? "ONGOING" : status.uppercased()
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
        trailerYtIds: [String]? = nil
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
        if UserDefaults.standard.object(forKey: showUnairedNextUpKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: showUnairedNextUpKey)
    }

    static func hasAired(_ released: String?) -> Bool {
        guard let releaseDay = isoDay(released) else { return true }
        return releaseDay < todayIsoDay()
    }

    static func shouldSurfaceNextEpisode(
        watchedSeason: Int?,
        candidateSeason: Int?,
        released: String?
    ) -> Bool {
        let isSeasonRollover = seasonSortKey(candidateSeason ?? 0) != seasonSortKey(watchedSeason ?? 0)
        if !isSeasonRollover {
            return showUnairedNextUp || hasAired(released)
        }
        if hasAired(released), isoDate(released) != nil {
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
    var id: String { url ?? infoHash.map { "\($0):\(fileIdx ?? -1)" } ?? UUID().uuidString }
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
        filename: String? = nil
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
    }

    /// A stream that has no direct URL but carries a torrent info-hash: it must
    /// be run through a debrid provider before it can play.
    var isDebridResolvable: Bool {
        (url?.isEmpty ?? true) && (infoHash?.isEmpty == false)
    }

    /// Returns a copy tagged with the source add-on's logo. Used to attach the
    /// logo after streams are fetched, so the logo lookup never blocks them.
    func withAddonLogoURL(_ logo: String?) -> NuvioStream {
        NuvioStream(
            url: url, name: name, description: description, addonName: addonName,
            subtitles: subtitles, addonLogoURL: logo, infoHash: infoHash,
            fileIdx: fileIdx, sources: sources, filename: filename
        )
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

    var isUpNextEntry: Bool { isUpNext == true }
    var hasAired: Bool { EpisodeReleasePolicy.hasAired(released ?? episodeVideo?.released) }
    var airDateText: String? { EpisodeReleasePolicy.airDateText(for: released ?? episodeVideo?.released) }
    var upNextBadgeText: String {
        guard isUpNextEntry else { return remainingText }
        if hasAired { return isNewEpisodeDrop ? "NEW EPISODE" : "NEXT UP" }
        if let airDateText { return "AIRS \(airDateText.uppercased())" }
        return "UPCOMING"
    }

    /// An aired up-next episode remains a visible "New Episode" drop through
    /// the release-alert window. Progress timestamps are not reliable after a
    /// cross-device sync or a regenerated Next Up entry, so they must not hide
    /// a genuinely recent episode.
    var isNewEpisodeDrop: Bool {
        isUpNextEntry && hasAired && EpisodeReleasePolicy.isRecentlyReleased(
            released ?? episodeVideo?.released,
            within: EpisodeReleasePolicy.newEpisodeWindowDays
        )
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
        isUpNext: Bool? = nil
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
    }

    /// Episode numbers for display. Entries saved before episode tracking have
    /// nil season/episode; for those, fall back to a stream filename tag when
    /// possible, then to the first playable episode in stored series metadata.
    private var resolvedNumbers: (season: Int, episode: Int)? {
        if let season, let episode { return (season, episode) }
        guard meta.isSeries else { return nil }
        if let numbers = EpisodeTagResolver.episodeNumbers(in: streamUrl) {
            return numbers
        }
        return firstPlayableEpisode.map { ($0.season, $0.episode) }
    }

    var episodeNumbers: (season: Int, episode: Int)? {
        resolvedNumbers
    }

    private var firstPlayableEpisode: NuvioVideo? {
        guard let videos = meta.videos, !videos.isEmpty else { return nil }
        let sorted = videos.sorted {
            (seasonSortKey($0.season), $0.episode) < (seasonSortKey($1.season), $1.episode)
        }
        return sorted.first { $0.season > 0 } ?? sorted.first
    }

    private func seasonSortKey(_ season: Int) -> Int {
        season <= 0 ? Int.max : season
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
        guard let numbers = resolvedNumbers else { return nil }
        return meta.videos?.first { $0.season == numbers.season && $0.episode == numbers.episode }
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

    /// Last durable-storage result, suitable for the on-screen sync diagnostic.
    static private(set) var persistenceDiagnostic = "not attempted"

    private enum PersistenceError: LocalizedError {
        case applicationSupportUnavailable
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "Application Support is unavailable"
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
        migrateLegacyHistoryIfNeeded()
        // Rebuild Top Shelf on every profile load. Its App Group snapshot may
        // have been cleared by an update or signing change even when the local
        // Continue Watching file is still intact.
        writeTopShelfFeed()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static var storageKey: String {
        guard let id = activeProfileId, !id.isEmpty else { return baseKey }
        return "\(baseKey).\(id)"
    }

    static func items() -> [ContinueWatchingItem] {
        guard let data = data(for: storageKey) else {
            return []
        }
        let decoded: [ContinueWatchingItem]
        do {
            decoded = try makeDecoder().decode([ContinueWatchingItem].self, from: data)
        } catch {
            // Keep the payload intact so debugSnapshot() can report the actual
            // corruption instead of turning it into an unexplained missing file.
            persistenceDiagnostic = "decode failed: \(diagnosticText(for: error))"
            return []
        }

        return decoded
            .filter { shouldKeep(position: $0.position, duration: $0.duration) }
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
    }

    static func item(for metaId: String) -> ContinueWatchingItem? {
        items().first { $0.meta.id == metaId }
    }

    /// Read-only storage diagnostics for the on-screen Home failure panel.
    /// It deliberately bypasses `items()` so a corrupt payload is reported
    /// instead of being silently removed before the user can photograph it.
    static func debugSnapshot() -> DebugSnapshot {
        let key = storageKey
        let source: String
        let rawData: Data?
        if UserDefaults.standard.bool(forKey: fallbackMarkerKey(for: key)),
           let data = UserDefaults.standard.data(forKey: key) {
            source = "UserDefaults fallback"
            rawData = data
        } else if let url = storageURL(for: key), let data = try? Data(contentsOf: url) {
            source = "Application Support"
            rawData = data
        } else if let url = fallbackStorageURL(for: key), let data = try? Data(contentsOf: url) {
            source = "Caches fallback"
            rawData = data
        } else if let url = legacyStorageURL(for: key), let data = try? Data(contentsOf: url) {
            source = "Documents (legacy)"
            rawData = data
        } else if let data = UserDefaults.standard.data(forKey: key) {
            source = "UserDefaults (legacy)"
            rawData = data
        } else {
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

    static func save(meta: NuvioMeta, streamUrl: String, position: Double, duration: Double, season: Int? = nil, episode: Int? = nil) {
        // A temporarily unavailable MPV time-pos must not erase a valid resume
        // point. Only a coherent, started sample is allowed to replace/remove
        // existing progress.
        guard position.isFinite,
              duration.isFinite,
              position > 0,
              duration >= 60 else { return }
        guard shouldKeep(position: position, duration: duration) else {
            remove(metaId: meta.id)
            return
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

    static func saveUpNext(meta: NuvioMeta, duration: Double, season: Int, episode: Int, released: String? = nil) {
        let item = ContinueWatchingItem(
            meta: meta,
            streamUrl: "",
            position: 1,
            duration: max(duration, 120),
            lastWatchedAt: Date(),
            season: season,
            episode: episode,
            released: released,
            isUpNext: true
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
                isUpNext: item.isUpNext
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

    static func remove(metaId: String) {
        persist(items().filter { $0.meta.id != metaId })
    }

    @discardableResult
    static func mergeRemote(_ remoteItems: [ContinueWatchingItem]) -> Bool {
        guard !remoteItems.isEmpty else { return true }
        var byId: [String: ContinueWatchingItem] = [:]
        // Remote items come second and win timestamp ties, so a re-pull can
        // refresh an entry's presentation (e.g. up-next state) even when the
        // underlying remote row hasn't moved.
        (items() + remoteItems).forEach { item in
            let existing = byId[item.meta.id]
            if existing == nil || item.lastWatchedAt >= existing!.lastWatchedAt {
                byId[item.meta.id] = item
            }
        }
        return persist(Array(byId.values).sorted { $0.lastWatchedAt > $1.lastWatchedAt }.prefix(maxItems).map { $0 })
    }

    static func replaceAll(_ newItems: [ContinueWatchingItem]) {
        persist(Array(newItems.sorted { $0.lastWatchedAt > $1.lastWatchedAt }.prefix(maxItems)))
    }

    private static func shouldKeep(position: Double, duration: Double) -> Bool {
        // Any started playback counts (> 0), matching the phone app's rule —
        // a stricter threshold here hides items the phone still lists.
        guard duration >= 60, position > 0 else { return false }
        let remaining = duration - position
        return remaining >= 60 && (position / duration) < 0.92
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
        let defaults = UserDefaults.standard
        var primaryError: Error?
        if let url = storageURL(for: key) {
            do {
                try writeAndVerify(data, to: url)
                if let fallbackURL = fallbackStorageURL(for: key) {
                    try? FileManager.default.removeItem(at: fallbackURL)
                }
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: fallbackMarkerKey(for: key))
                persistenceDiagnostic = "Application Support: \(storedItems.count) item(s), \(data.count) bytes"
                NotificationCenter.default.post(name: changedNotification, object: nil)
                writeTopShelfFeed()
                return true
            } catch {
                primaryError = error
            }
        } else {
            primaryError = PersistenceError.applicationSupportUnavailable
        }

        // Synced progress can contain several megabytes of episode metadata.
        // tvOS 27 aborts the process when a value that large is written to
        // UserDefaults, so the fallback must remain file-backed too.
        if let fallbackURL = fallbackStorageURL(for: key) {
            do {
                try writeAndVerify(data, to: fallbackURL)
                if let primaryURL = storageURL(for: key),
                   FileManager.default.fileExists(atPath: primaryURL.path) {
                    try FileManager.default.removeItem(at: primaryURL)
                }
                defaults.removeObject(forKey: key)
                defaults.removeObject(forKey: fallbackMarkerKey(for: key))
                let reason = primaryError.map(diagnosticText(for:)) ?? "unknown error"
                persistenceDiagnostic = "Caches fallback: \(storedItems.count) item(s); \(reason)"
                NotificationCenter.default.post(name: changedNotification, object: nil)
                writeTopShelfFeed()
                return true
            } catch {
                let primaryReason = primaryError.map(diagnosticText(for:)) ?? "unknown error"
                persistenceDiagnostic = "save failed: \(primaryReason); Caches fallback: \(diagnosticText(for: error))"
                return false
            }
        }

        let reason = primaryError.map(diagnosticText(for:)) ?? "unknown error"
        persistenceDiagnostic = "save failed: \(reason); Caches unavailable"
        return false
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

    /// Deletes every profile's watch history (and the legacy shared list).
    /// Called on sign-out so the next user starts with no resume state.
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
        if let legacyDirectory = legacyStorageDirectoryURL {
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
            removeStorage(for: baseKey)
            persistenceDiagnostic = "migrated shared progress to profile \(id)"
        } catch {
            // The shared copy remains the source of truth until this succeeds.
            persistenceDiagnostic = "profile migration failed: \(diagnosticText(for: error))"
        }
    }

    private static var storageDirectoryURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nuvio", isDirectory: true)
            .appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    /// Pre-sideload builds used Documents. Some signing/install paths expose
    /// that directory as read-only on tvOS, so it is migration-only now.
    private static var legacyStorageDirectoryURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    private static var fallbackStorageDirectoryURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Nuvio", isDirectory: true)
            .appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    private static func storageURL(for key: String) -> URL? {
        storageDirectoryURL?.appendingPathComponent(fileName(for: key))
    }

    private static func legacyStorageURL(for key: String) -> URL? {
        legacyStorageDirectoryURL?.appendingPathComponent(fileName(for: key))
    }

    private static func fallbackStorageURL(for key: String) -> URL? {
        fallbackStorageDirectoryURL?.appendingPathComponent(fileName(for: key))
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
        let defaults = UserDefaults.standard
        let markerKey = fallbackMarkerKey(for: key)

        // A verified fallback is newer than any file left by the failed write.
        // Retry the preferred storage opportunistically without risking it.
        if defaults.bool(forKey: markerKey), let data = defaults.data(forKey: key) {
            if let url = storageURL(for: key) {
                do {
                    try writeAndVerify(data, to: url)
                    defaults.removeObject(forKey: key)
                    defaults.removeObject(forKey: markerKey)
                    persistenceDiagnostic = "recovered Application Support storage"
                } catch {
                    persistenceDiagnostic = "using UserDefaults fallback: \(diagnosticText(for: error))"
                }
            }
            return data
        }

        if let url = storageURL(for: key),
           let data = try? Data(contentsOf: url) {
            return data
        }

        if let fallbackURL = fallbackStorageURL(for: key),
           let data = try? Data(contentsOf: fallbackURL) {
            if let url = storageURL(for: key) {
                do {
                    try writeAndVerify(data, to: url)
                    try? FileManager.default.removeItem(at: fallbackURL)
                    persistenceDiagnostic = "recovered Application Support storage"
                } catch {
                    persistenceDiagnostic = "using Caches fallback: \(diagnosticText(for: error))"
                }
            }
            return data
        }

        // Preserve progress from older builds when their Documents file is
        // still readable, but keep all future writes in Application Support.
        if let legacyURL = legacyStorageURL(for: key),
           let data = try? Data(contentsOf: legacyURL) {
            if let url = storageURL(for: key) {
                do {
                    try writeAndVerify(data, to: url)
                    try? FileManager.default.removeItem(at: legacyURL)
                    persistenceDiagnostic = "migrated Documents progress"
                } catch {
                    persistenceDiagnostic = "Documents migration failed: \(diagnosticText(for: error))"
                }
            }
            return data
        }

        guard let data = defaults.data(forKey: key) else { return nil }
        if let url = storageURL(for: key) {
            do {
                try writeAndVerify(data, to: url)
                defaults.removeObject(forKey: key)
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

    private static func removeStorage(for key: String) {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: fallbackMarkerKey(for: key))
        if let url = storageURL(for: key) {
            try? FileManager.default.removeItem(at: url)
        }
        if let legacyURL = legacyStorageURL(for: key) {
            try? FileManager.default.removeItem(at: legacyURL)
        }
        if let fallbackURL = fallbackStorageURL(for: key) {
            try? FileManager.default.removeItem(at: fallbackURL)
        }
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
struct NuvioCollection: Codable, Identifiable {
    let id: String
    let title: String
    var pinToTop: Bool
    var folders: [NuvioCollectionFolder]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        pinToTop = try c.decodeIfPresent(Bool.self, forKey: .pinToTop) ?? false
        folders = try c.decodeIfPresent([NuvioCollectionFolder].self, forKey: .folders) ?? []
    }
}

struct NuvioCollectionFolder: Codable, Identifiable {
    let id: String
    let title: String
    var coverImageUrl: String?
    var coverEmoji: String?
    var sources: [NuvioCollectionSource]
    /// Legacy pre-`sources` field still present in old blobs.
    var catalogSources: [NuvioCollectionCatalogSource]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        coverImageUrl = try c.decodeIfPresent(String.self, forKey: .coverImageUrl)
        coverEmoji = try c.decodeIfPresent(String.self, forKey: .coverEmoji)
        sources = try c.decodeIfPresent([NuvioCollectionSource].self, forKey: .sources) ?? []
        catalogSources = try c.decodeIfPresent([NuvioCollectionCatalogSource].self, forKey: .catalogSources) ?? []
    }

    /// Add-on backed catalog sources, merging the modern `sources` array with
    /// the legacy `catalogSources` field (mirrors the Android accessor).
    /// TMDB/Trakt sources are skipped — tvOS resolves add-on catalogs only.
    var addonCatalogSources: [NuvioCollectionCatalogSource] {
        var merged = sources.compactMap { source -> NuvioCollectionCatalogSource? in
            guard source.provider.isEmpty || source.provider.lowercased() == "addon",
                  let addonId = source.addonId,
                  let type = source.type,
                  let catalogId = source.catalogId else { return nil }
            return NuvioCollectionCatalogSource(addonId: addonId, type: type, catalogId: catalogId, genre: source.genre)
        }
        merged.append(contentsOf: catalogSources)
        return merged
    }
}

struct NuvioCollectionSource: Codable {
    var provider: String
    var addonId: String?
    var type: String?
    var catalogId: String?
    var genre: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? "addon"
        addonId = try c.decodeIfPresent(String.self, forKey: .addonId)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        catalogId = try c.decodeIfPresent(String.self, forKey: .catalogId)
        genre = try c.decodeIfPresent(String.self, forKey: .genre)
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

/// Per-profile cache of the account's collections. Written only by the sync
/// pull (Android/phone remain the editors); read by the Home screen.
enum CollectionsStore {
    static let changedNotification = Notification.Name("nuvio.tv.collections.changed")

    private static let baseKey = "nuvio.tv.collections.json"
    private(set) static var activeProfileId: String?

    static func setActiveProfile(_ profileId: String?) {
        activeProfileId = profileId
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static var storageKey: String {
        guard let id = activeProfileId, !id.isEmpty else { return baseKey }
        return "\(baseKey).\(id)"
    }

    static func collections() -> [NuvioCollection] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([NuvioCollection].self, from: data) else {
            return []
        }
        return decoded
    }

    /// Replaces the cache with the account's blob. Raw data is stored as-is so
    /// fields tvOS doesn't model yet survive round-trips of the app version.
    static func applyRemote(_ json: Data) {
        guard (try? JSONDecoder().decode([NuvioCollection].self, from: json)) != nil else { return }
        UserDefaults.standard.set(json, forKey: storageKey)
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
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else {
            return []
        }
        return rows
    }

    /// Persists a local edit and asks the sync manager to push it.
    static func saveLocalEdit(_ raw: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: raw),
              (try? JSONDecoder().decode([NuvioCollection].self, from: data)) != nil else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
        NotificationCenter.default.post(name: locallyEditedNotification, object: raw)
    }

    /// Deletes every profile's collections on sign-out.
    static func eraseAllProfiles() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(baseKey) }
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

    init(meta: NuvioMeta, watchedAt: Date, season: Int? = nil, episode: Int? = nil) {
        self.meta = meta
        self.watchedAt = watchedAt
        self.season = season
        self.episode = episode
    }
}

enum WatchedStore {
    static let changedNotification = Notification.Name("nuvio.tv.watched.changed")

    private static let baseKey = "nuvio.tv.watched.items"
    private static let storageDirectoryName = "WatchedStore"
    private(set) static var activeProfileId: String?

    static func setActiveProfile(_ profileId: String?) {
        activeProfileId = profileId
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static var storageKey: String {
        guard let id = activeProfileId, !id.isEmpty else { return baseKey }
        return "\(baseKey).\(id)"
    }

    static func items() -> [WatchedStoreItem] {
        guard let data = readData(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WatchedStoreItem].self, from: data) else {
            return []
        }

        return decoded.sorted { $0.watchedAt > $1.watchedAt }
    }

    /// Whole-title watched state (movies, or a series marked watched
    /// explicitly). Episode-level entries deliberately don't count here so one
    /// finished episode doesn't checkmark the whole series poster.
    static func contains(metaId: String, type: String) -> Bool {
        items().contains {
            $0.meta.id == metaId
                && $0.meta.type.caseInsensitiveCompare(type) == .orderedSame
                && $0.season == nil && $0.episode == nil
        }
    }

    static func containsEpisode(metaId: String, season: Int, episode: Int) -> Bool {
        items().contains { $0.meta.id == metaId && $0.season == season && $0.episode == episode }
    }

    /// "season:episode" keys of every watched episode of a series, for the
    /// Details episode strip.
    static func watchedEpisodeKeys(metaId: String) -> Set<String> {
        Set(items().compactMap { item in
            guard item.meta.id == metaId, let season = item.season, let episode = item.episode else {
                return nil
            }
            return "\(season):\(episode)"
        })
    }

    @discardableResult
    static func toggle(meta: NuvioMeta) -> Bool {
        if contains(metaId: meta.id, type: meta.type) {
            remove(metaId: meta.id, type: meta.type)
            return false
        }

        markWatched(meta)
        return true
    }

    static func markWatched(_ meta: NuvioMeta, season: Int? = nil, episode: Int? = nil) {
        ContinueWatchingStore.remove(metaId: meta.id)
        let item = WatchedStoreItem(meta: meta, watchedAt: Date(), season: season, episode: episode)
        let updated = [item] + items().filter {
            !($0.meta.id == meta.id
                && $0.meta.type.caseInsensitiveCompare(meta.type) == .orderedSame
                && $0.season == season && $0.episode == episode)
        }
        clearTombstone(metaId: meta.id, season: season, episode: episode)
        persist(updated)
    }

    /// Removes the whole-title mark only; per-episode history stays. Leaves a
    /// tombstone so the next sync deletes the remote row instead of pulling the
    /// mark right back.
    static func remove(metaId: String, type: String) {
        addTombstone(metaId: metaId, season: nil, episode: nil)
        persist(items().filter {
            !($0.meta.id == metaId
                && $0.meta.type.caseInsensitiveCompare(type) == .orderedSame
                && $0.season == nil && $0.episode == nil)
        })
    }

    /// Merges a FULL remote snapshot. Tombstones (locally removed marks) block
    /// their remote row and stay alive until a pull shows the row is really
    /// gone from the server — the pushed delete is best-effort, so the pull is
    /// the confirmation. A newer re-watch on another device supersedes one.
    static func mergeRemote(_ remoteItems: [WatchedStoreItem]) {
        let removedMarks = tombstones()
        guard !remoteItems.isEmpty || !removedMarks.isEmpty else { return }

        let stillBlocking = removedMarks.filter { tombstone in
            remoteItems.contains {
                $0.meta.id == tombstone.metaId && $0.season == tombstone.season
                    && $0.episode == tombstone.episode && $0.watchedAt <= tombstone.removedAt
            }
        }
        if stillBlocking.count != removedMarks.count {
            persistTombstones(stillBlocking)
        }

        let accepted = remoteItems.filter { item in
            !stillBlocking.contains {
                $0.metaId == item.meta.id && $0.season == item.season && $0.episode == item.episode
            }
        }

        var byKey: [String: WatchedStoreItem] = [:]
        (items() + accepted).forEach { item in
            let key = item.id.lowercased()
            let existing = byKey[key]
            if existing == nil || item.watchedAt > existing!.watchedAt {
                byKey[key] = item
            }
        }
        persist(Array(byKey.values).sorted { $0.watchedAt > $1.watchedAt })
    }

    // MARK: Tombstones — locally deleted marks awaiting remote deletion

    struct Tombstone: Codable, Equatable {
        let metaId: String
        let season: Int?
        let episode: Int?
        let removedAt: Date
    }

    private static var tombstoneStorageKey: String {
        guard let id = activeProfileId, !id.isEmpty else { return "\(baseKey).tombstones" }
        return "\(baseKey).tombstones.\(id)"
    }

    static func tombstones() -> [Tombstone] {
        guard let data = readData(forKey: tombstoneStorageKey),
              let decoded = try? JSONDecoder().decode([Tombstone].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func addTombstone(metaId: String, season: Int?, episode: Int?) {
        let entry = Tombstone(metaId: metaId, season: season, episode: episode, removedAt: Date())
        let updated = tombstones().filter {
            !($0.metaId == metaId && $0.season == season && $0.episode == episode)
        } + [entry]
        persistTombstones(updated)
    }

    private static func clearTombstone(metaId: String, season: Int?, episode: Int?) {
        persistTombstones(tombstones().filter {
            !($0.metaId == metaId && $0.season == season && $0.episode == episode)
        })
    }

    /// Called after the remote rows were deleted successfully.
    static func clearTombstones(_ cleared: [Tombstone]) {
        persistTombstones(tombstones().filter { !cleared.contains($0) })
    }

    private static func persistTombstones(_ entries: [Tombstone]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        writeData(data, forKey: tombstoneStorageKey)
    }

    static func replaceAll(_ newItems: [WatchedStoreItem]) {
        persist(newItems.sorted { $0.watchedAt > $1.watchedAt })
    }

    private static func persist(_ items: [WatchedStoreItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        writeData(data, forKey: storageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// Deletes every profile's watched marks and tombstones (the tombstone keys
    /// share `baseKey` as their prefix) on sign-out.
    static func eraseAllProfiles() {
        let defaults = UserDefaults.standard
        defaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(baseKey) }
            .forEach { defaults.removeObject(forKey: $0) }
        try? FileManager.default.removeItem(at: storageDirectoryURL)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static func readData(forKey key: String) -> Data? {
        let fileURL = fileURL(forKey: key)
        if let fileData = try? Data(contentsOf: fileURL) {
            return fileData
        }

        guard let defaultsData = UserDefaults.standard.data(forKey: key) else {
            return nil
        }

        // Older builds stored watched history in UserDefaults. Large accounts
        // can exceed tvOS preferences limits, so migrate each profile key to a
        // file the first time it is touched.
        if writeData(defaultsData, forKey: key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return defaultsData
    }

    @discardableResult
    private static func writeData(_ data: Data, forKey key: String) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: storageDirectoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL(forKey: key), options: .atomic)
            return true
        } catch {
            print("Nuvio watched storage write failed: \(error.localizedDescription)")
            return false
        }
    }

    private static var storageDirectoryURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent(storageDirectoryName, isDirectory: true)
    }

    private static func fileURL(forKey key: String) -> URL {
        storageDirectoryURL.appendingPathComponent(fileName(forKey: key), isDirectory: false)
    }

    private static func fileName(forKey key: String) -> String {
        Data(key.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
            + ".json"
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
        seedFromGlobalIfNeeded(suite)
        current = suite
    }

    static func clearActiveProfile() {
        current = .standard
    }

    /// Deletes the given profiles' settings suites and the pre-profile copies
    /// in `.standard`, so sign-out leaves no add-ons, API keys, or preferences
    /// behind. Points `current` back at `.standard` first so nothing keeps
    /// writing into a removed suite.
    static func eraseAll(profileIds: [String]) {
        current = .standard
        for id in Set(profileIds) where !id.isEmpty {
            UserDefaults.standard.removePersistentDomain(forName: "\(suitePrefix).\(id)")
        }
        for key in SettingsKey.all {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Clone the current profile's settings into a freshly created profile, then
    /// mark it seeded so the global migration never overwrites the copy.
    static func seedNewProfile(_ profileId: String, copyingFrom source: UserDefaults? = nil) {
        let destination = store(for: profileId)
        copySettings(from: source ?? current, to: destination)
        destination.set(true, forKey: seededFlag)
    }

    private static func seedFromGlobalIfNeeded(_ suite: UserDefaults) {
        guard !suite.bool(forKey: seededFlag) else { return }
        copySettings(from: .standard, to: suite)
        suite.set(true, forKey: seededFlag)
    }

    private static func copySettings(from source: UserDefaults, to destination: UserDefaults) {
        guard source != destination else { return }
        for key in SettingsKey.all {
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
    var isLoadingStreams: Bool = false
    var error: String? = nil
    var isInWatchlist: Bool = false
    var isWatched: Bool = false
    var userRating: Int? = nil
}
