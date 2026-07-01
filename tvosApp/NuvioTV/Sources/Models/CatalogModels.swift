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
    let contentType: String?
    let catalogId: String?

    init(
        id: String,
        name: String,
        description: String,
        itemIds: [String],
        contentType: String? = nil,
        catalogId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.itemIds = itemIds
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

/// Video stream information
struct NuvioSubtitle: Identifiable, Codable, Equatable {
    var id: String { url }
    let url: String
    let language: String
    let label: String?
}

struct NuvioStream: Identifiable, Codable {
    var id: String { url ?? UUID().uuidString }
    let url: String?
    let name: String?
    let description: String?
    let addonName: String?
    let subtitles: [NuvioSubtitle]

    init(
        url: String?,
        name: String?,
        description: String?,
        addonName: String?,
        subtitles: [NuvioSubtitle] = []
    ) {
        self.url = url
        self.name = name
        self.description = description
        self.addonName = addonName
        self.subtitles = subtitles
    }
}

enum PlaybackMarkers {
    static let trailerSubtitle = "Trailer"
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
    private static let maxItems = 20

    /// Identifier of the profile whose watch history is currently active.
    /// Set at launch and whenever the user switches profiles so each profile
    /// keeps its own Continue Watching list (app settings stay shared device-wide).
    private(set) static var activeProfileId: String?

    /// Point the store at a profile. Call on launch and on every profile switch
    /// so reads/writes land in that profile's bucket.
    static func setActiveProfile(_ profileId: String?) {
        activeProfileId = profileId
        migrateLegacyHistoryIfNeeded()
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    private static var storageKey: String {
        guard let id = activeProfileId, !id.isEmpty else { return baseKey }
        return "\(baseKey).\(id)"
    }

    static func items() -> [ContinueWatchingItem] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ContinueWatchingItem].self, from: data) else {
            return []
        }

        return decoded
            .filter { shouldKeep(position: $0.position, duration: $0.duration) }
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
    }

    static func item(for metaId: String) -> ContinueWatchingItem? {
        items().first { $0.meta.id == metaId }
    }

    static func save(meta: NuvioMeta, streamUrl: String, position: Double, duration: Double) {
        guard shouldKeep(position: position, duration: duration) else {
            remove(metaId: meta.id)
            return
        }

        let item = ContinueWatchingItem(
            meta: meta,
            streamUrl: streamUrl,
            position: position,
            duration: duration,
            lastWatchedAt: Date()
        )
        let updated = ([item] + items().filter { $0.meta.id != meta.id }).prefix(maxItems)
        persist(Array(updated))
    }

    static func remove(metaId: String) {
        persist(items().filter { $0.meta.id != metaId })
    }

    private static func shouldKeep(position: Double, duration: Double) -> Bool {
        guard duration >= 60, position >= 10 else { return false }
        let remaining = duration - position
        return remaining >= 60 && (position / duration) < 0.92
    }

    private static func persist(_ items: [ContinueWatchingItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    /// One-time copy of the old shared list into the active profile's bucket so
    /// existing users keep their Continue Watching when profiles arrive. Only the
    /// first profile that becomes active inherits it; afterwards the legacy key
    /// is cleared so other profiles start clean.
    private static func migrateLegacyHistoryIfNeeded() {
        guard let id = activeProfileId, !id.isEmpty else { return }
        let profileKey = "\(baseKey).\(id)"
        let defaults = UserDefaults.standard
        // Nothing to migrate, or this profile already has its own history.
        guard defaults.data(forKey: profileKey) == nil,
              let legacyData = defaults.data(forKey: baseKey) else { return }
        defaults.set(legacyData, forKey: profileKey)
        defaults.removeObject(forKey: baseKey)
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

    private static func persist(_ items: [LibraryStoreItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

struct WatchedStoreItem: Identifiable, Codable {
    var id: String { "\(meta.type):\(meta.id)" }
    let meta: NuvioMeta
    let watchedAt: Date
}

enum WatchedStore {
    static let changedNotification = Notification.Name("nuvio.tv.watched.changed")

    private static let baseKey = "nuvio.tv.watched.items"
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
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WatchedStoreItem].self, from: data) else {
            return []
        }

        return decoded.sorted { $0.watchedAt > $1.watchedAt }
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

        markWatched(meta)
        return true
    }

    static func markWatched(_ meta: NuvioMeta) {
        ContinueWatchingStore.remove(metaId: meta.id)
        let item = WatchedStoreItem(meta: meta, watchedAt: Date())
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

    private static func persist(_ items: [WatchedStoreItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
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
