import Foundation

/// One playable file for a Plex title: the movie itself, or one episode.
struct PlexIndexedItem: Codable, Equatable {
    /// The movie's or episode's rating key, which playback progress reports to.
    let ratingKey: String
    let partKey: String
    let container: String?
    let size: Int64?
    let durationMs: Int64?
    var season: Int?
    var episode: Int?
    var episodeName: String?
    var episodeOverview: String?
    var episodePremiereDate: String?
    var episodeThumb: String?
    /// What sets the main file apart when there are others ("4K · 18.2 Mbps").
    var label: String? = nil
    /// Other versions and parts of the same movie or episode.
    var alternates: [PlexFile]? = nil
    /// The main file's format. Absent on items synced before it was kept.
    var details: PlexFileDetails? = nil

    /// Every file, the main one first.
    var files: [PlexFile] {
        [PlexFile(partKey: partKey, container: container, sizeBytes: size, label: label, details: details)]
            + (alternates ?? [])
    }
}

/// One Plex movie or show with everything Home and Details need, stored
/// locally after a sync the same way Jellyfin titles are. `contentId` is
/// synthetic (`plex-<serverID>-<ratingKey>`); IMDb and TMDB ids are kept so
/// catalog titles from other sources can offer the Plex copy as a stream.
struct PlexIndexedTitle: Codable, Equatable {
    let contentId: String
    let serverID: String
    let libraryID: String
    let libraryName: String
    let ratingKey: String
    let type: String
    let name: String
    let overview: String?
    let year: Int?
    let genres: [String]?
    let rating: Double?
    let contentRating: String?
    let premiereDate: String?
    let durationMs: Int64?
    let imdbId: String?
    let tmdbId: Int?
    let thumb: String?
    let art: String?
    let cast: [String]?
    let directors: [String]?
    var items: [PlexIndexedItem]
}

/// The account's watch state for one movie or episode, as Plex reports it.
struct PlexWatchState: Codable, Equatable {
    var viewOffsetMs: Int64
    var viewCount: Int
    /// Unix seconds; 0 when never played.
    var lastViewedAt: Int64

    var isWatched: Bool { viewCount > 0 }
    var resumeSeconds: Double { Double(viewOffsetMs) / 1000 }

    init(viewOffsetMs: Int64 = 0, viewCount: Int = 0, lastViewedAt: Int64 = 0) {
        self.viewOffsetMs = viewOffsetMs
        self.viewCount = viewCount
        self.lastViewedAt = lastViewedAt
    }

    init(_ item: PlexMediaItem) {
        self.init(viewOffsetMs: item.viewOffsetMs ?? 0, viewCount: item.viewCount ?? 0, lastViewedAt: item.lastViewedAt ?? 0)
    }
}

enum PlexLibraryResolver {
    /// Groups one section's movies, shows, and episodes into titles locally.
    static func resolve(
        movies: [PlexMediaItem],
        shows: [PlexMediaItem],
        episodes: [PlexMediaItem],
        serverID: String,
        library: PlexLibrary
    ) -> [PlexIndexedTitle] {
        func title(_ item: PlexMediaItem, type: String, items: [PlexIndexedItem]) -> PlexIndexedTitle {
            PlexIndexedTitle(
                contentId: PlexLibraryIndex.contentId(serverID: serverID, ratingKey: item.ratingKey),
                serverID: serverID,
                libraryID: library.id,
                libraryName: library.name,
                ratingKey: item.ratingKey,
                type: type,
                name: item.title,
                overview: item.summary,
                year: item.year,
                genres: item.genres,
                rating: item.rating,
                contentRating: item.contentRating,
                premiereDate: item.originallyAvailableAt,
                durationMs: item.durationMs,
                imdbId: item.imdbId,
                tmdbId: item.tmdbId,
                thumb: item.thumb,
                art: item.art,
                cast: item.cast,
                directors: item.directors,
                items: items
            )
        }

        var titles: [PlexIndexedTitle] = movies.compactMap { movie in
            guard let partKey = movie.partKey else { return nil }
            return title(movie, type: "movie", items: [
                PlexIndexedItem(
                    ratingKey: movie.ratingKey,
                    partKey: partKey,
                    container: movie.container,
                    size: movie.sizeBytes,
                    durationMs: movie.durationMs,
                    label: movie.files.count > 1 ? movie.files.first?.label : nil,
                    alternates: movie.files.count > 1 ? Array(movie.files.dropFirst()) : nil,
                    details: movie.files.first?.details
                )
            ])
        }

        let episodesByShow = Dictionary(grouping: episodes.filter { $0.partKey != nil }) { $0.showRatingKey ?? "" }
        for show in shows {
            let files = (episodesByShow[show.ratingKey] ?? []).map { episode in
                PlexIndexedItem(
                    ratingKey: episode.ratingKey,
                    partKey: episode.partKey ?? "",
                    container: episode.container,
                    size: episode.sizeBytes,
                    durationMs: episode.durationMs,
                    season: episode.seasonNumber,
                    episode: episode.episodeNumber,
                    episodeName: episode.title,
                    episodeOverview: episode.summary,
                    episodePremiereDate: episode.originallyAvailableAt,
                    episodeThumb: episode.thumb,
                    label: episode.files.count > 1 ? episode.files.first?.label : nil,
                    alternates: episode.files.count > 1 ? Array(episode.files.dropFirst()) : nil,
                    details: episode.files.first?.details
                )
            }
            guard !files.isEmpty else { continue }
            titles.append(title(show, type: "series", items: files))
        }
        return titles
    }
}

/// A movie or episode of a looked-up title whose link was stored
/// (`PlexLibraryIndex.rememberLookedUpItem`).
struct PlexRememberedItem: Codable, Equatable {
    let serverID: String
    let ratingKey: String
    /// Every file of the item: `/library/parts/...` paths.
    let partKeys: [String]
    let durationMs: Int64?
}

/// Persisted Plex titles per server, for the active profile. Mirrors
/// `JellyfinLibraryIndex`, including where it stores its payload.
@MainActor
final class PlexLibraryIndex: ObservableObject {
    static let shared = PlexLibraryIndex()

    static let changedNotification = Notification.Name("nuvio.tv.plex.library.changed")

    /// No `:` inside, so it survives the `contentId:season:episode` video ids.
    nonisolated static func contentId(serverID: String, ratingKey: String) -> String {
        "plex-\(serverID)-\(ratingKey)"
    }

    @Published private(set) var titlesByServerID: [String: [PlexIndexedTitle]] = [:]
    /// Watch state per server, keyed by the movie's or episode's rating key.
    /// A server has an entry here once its state has been read at least once.
    @Published private(set) var watchStatesByServerID: [String: [String: PlexWatchState]] = [:]

    /// Titles found by asking a server about one title in a library too large
    /// to sync, by the content id they were found for, and when each library
    /// was asked ("server|library"). Kept in memory only, for stream lists and
    /// playback; past `lookedUpLimit` content ids the oldest go, times and all.
    private var lookedUpTitles: [String: [PlexIndexedTitle]] = [:]
    private var lookupTimes: [String: [String: Date]] = [:]
    private var lookedUpOrder: [String] = []
    nonisolated static let lookedUpLimit = 30

    /// Movies and episodes of looked-up titles whose link was stored for
    /// Continue Watching. Looked-up titles are gone after a relaunch, so a
    /// replayed link is recognised from here. Saved, newest last, at most
    /// `rememberedLimit`.
    private var rememberedItems: [PlexRememberedItem] = []

    /// Libraries known to be on disk exactly as they are in memory, by
    /// server: read from their files or written by `replace`. Anything else
    /// is written by the next `replace`, changed or not.
    private var savedLibraryIDs: [String: Set<String>] = [:]
    /// Bumped by `removeAll`, so a `replace` that was writing when its
    /// server was removed doesn't put the titles back.
    private var removals: [String: Int] = [:]
    nonisolated static let rememberedLimit = 200

    enum IndexError: LocalizedError {
        case persistenceFailed
        var errorDescription: String? { "The Plex library index could not be saved." }
    }

    private init() {
        (titlesByServerID, savedLibraryIDs) = Self.loadTitles()
        watchStatesByServerID = Self.loadWatchStates()
        rememberedItems = Self.loadRememberedItems()
        PlexWatched.rebuild(titles: titlesByServerID, states: watchStatesByServerID)
    }

    func reload() {
        (titlesByServerID, savedLibraryIDs) = Self.loadTitles()
        watchStatesByServerID = Self.loadWatchStates()
        rememberedItems = Self.loadRememberedItems()
        lookedUpTitles = [:]
        lookupTimes = [:]
        lookedUpOrder = []
        PlexWatched.rebuild(titles: titlesByServerID, states: watchStatesByServerID)
    }

    // MARK: - Libraries too large to sync

    /// Whether `contentId` was looked up in this library less than `interval` ago.
    func wasLookedUp(
        contentId: String,
        serverID: String,
        libraryID: String,
        within interval: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard let date = lookupTimes[Self.normalizedContentId(contentId)]?["\(serverID)|\(libraryID)"] else { return false }
        return now.timeIntervalSince(date) < interval
    }

    /// Records a lookup of `contentId` in `libraries` and the titles it found
    /// there, replacing what earlier lookups found in those libraries.
    func recordLookup(
        contentId: String,
        libraries: [(serverID: String, libraryID: String)],
        found: [PlexIndexedTitle],
        at date: Date = Date()
    ) {
        let key = Self.normalizedContentId(contentId)
        let titles = (lookedUpTitles[key] ?? []).filter { title in
            !libraries.contains { $0.serverID == title.serverID && $0.libraryID == title.libraryID }
        } + found
        lookedUpTitles[key] = titles.isEmpty ? nil : titles
        var times = lookupTimes[key] ?? [:]
        for library in libraries { times["\(library.serverID)|\(library.libraryID)"] = date }
        lookupTimes[key] = times
        lookedUpOrder.removeAll { $0 == key }
        lookedUpOrder.append(key)
        while lookedUpOrder.count > Self.lookedUpLimit {
            let oldest = lookedUpOrder.removeFirst()
            lookedUpTitles.removeValue(forKey: oldest)
            lookupTimes.removeValue(forKey: oldest)
        }
    }

    private func lookedUp(forServerID serverID: String) -> [PlexIndexedTitle] {
        lookedUpOrder.flatMap { lookedUpTitles[$0] ?? [] }.filter { $0.serverID == serverID }
    }

    /// Keeps a looked-up movie or episode whose link is being stored, so the
    /// link still plays and reports progress after a relaunch. Synced titles
    /// need nothing: the index finds them.
    func rememberLookedUpItem(serverID: String, ratingKey: String) {
        let synced = titlesByServerID[serverID]?.contains { $0.items.contains { $0.ratingKey == ratingKey } } ?? false
        guard !synced,
              let item = lookedUp(forServerID: serverID).flatMap(\.items).first(where: { $0.ratingKey == ratingKey }) else { return }
        var updated = rememberedItems.filter { !($0.serverID == serverID && $0.ratingKey == ratingKey) }
        updated.append(PlexRememberedItem(
            serverID: serverID,
            ratingKey: ratingKey,
            partKeys: item.files.map(\.partKey),
            durationMs: item.durationMs
        ))
        if updated.count > Self.rememberedLimit { updated.removeFirst(updated.count - Self.rememberedLimit) }
        guard updated != rememberedItems else { return }
        rememberedItems = updated
        persistRememberedItems()
    }

    /// A remembered movie or episode with this file (`/library/parts/...`).
    func rememberedItem(partPath: String) -> PlexRememberedItem? {
        rememberedItems.last { $0.partKeys.contains(partPath) }
    }

    /// A remembered movie or episode with this rating key.
    func rememberedItem(ratingKey: String) -> PlexRememberedItem? {
        rememberedItems.last { $0.ratingKey == ratingKey }
    }

    /// A content id as stream lists match it: trimmed, without `imdb:`.
    nonisolated static func normalizedContentId(_ contentId: String) -> String {
        let trimmed = contentId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased().hasPrefix("imdb:") ? String(trimmed.dropFirst(5)) : trimmed
    }

    // MARK: - Watch state

    /// `nil` until the server's watch state has been read; afterwards an item
    /// Plex never mentioned is simply unwatched.
    func watchState(serverID: String, ratingKey: String) -> PlexWatchState? {
        guard let states = watchStatesByServerID[serverID] else { return nil }
        return states[ratingKey] ?? PlexWatchState()
    }

    /// Replaces a server's states (after a full sync) or merges newer ones in.
    func setWatchStates(_ states: [String: PlexWatchState], forServerID serverID: String, merging: Bool) {
        var updated = watchStatesByServerID
        if merging {
            updated[serverID, default: [:]].merge(states) { _, new in new }
        } else {
            updated[serverID] = states
        }
        guard updated != watchStatesByServerID else { return }
        watchStatesByServerID = updated
        PlexWatched.rebuild(titles: titlesByServerID, states: updated)
        if let data = try? JSONEncoder().encode(updated) {
            _ = LargePayloadStore.write(data, key: Self.watchStateKey, directory: Self.storageDirectoryName)
        }
        NotificationCenter.default.post(name: Self.watchStateChangedNotification, object: nil)
    }

    static let watchStateChangedNotification = Notification.Name("nuvio.tv.plex.watchState.changed")

    /// One title's most recently played movie or episode that Plex has a
    /// saved position for.
    struct InProgress: Equatable {
        let title: PlexIndexedTitle
        let item: PlexIndexedItem
        let state: PlexWatchState
    }

    /// Plex's own Continue Watching leaves out anything not played for this
    /// long (16 weeks by default).
    nonisolated static let inProgressWindow: TimeInterval = 16 * 7 * 24 * 3600

    /// Titles with a saved position on Plex, newest first, one entry per title.
    func inProgress(now: Date = Date()) -> [InProgress] {
        let cutoff = Int64(now.timeIntervalSince1970 - Self.inProgressWindow)
        var result: [InProgress] = []
        for title in titles() {
            guard let states = watchStatesByServerID[title.serverID] else { continue }
            let latest = title.items
                .compactMap { item -> (PlexIndexedItem, PlexWatchState)? in
                    guard let state = states[item.ratingKey], state.viewOffsetMs > 0, state.lastViewedAt >= cutoff else { return nil }
                    return (item, state)
                }
                .max { $0.1.lastViewedAt < $1.1.lastViewedAt }
            if let (item, state) = latest {
                result.append(InProgress(title: title, item: item, state: state))
            }
        }
        return result.sorted { $0.state.lastViewedAt > $1.state.lastViewedAt }
    }

    /// The server, title, and item with this rating key (a movie or an episode).
    func locate(ratingKey: String, preferredHost: String? = nil) -> (server: PlexServerConfig, title: PlexIndexedTitle, item: PlexIndexedItem)? {
        let servers = PlexServerStore.shared.servers
        let preferred = servers.filter { preferredHost != nil && $0.baseURL?.host == preferredHost }
        for server in preferred + servers.filter({ candidate in !preferred.contains(where: { $0.id == candidate.id }) }) {
            for title in (titlesByServerID[server.id] ?? []) + lookedUp(forServerID: server.id) {
                if let item = title.items.first(where: { $0.ratingKey == ratingKey }) {
                    return (server, title, item)
                }
            }
        }
        return nil
    }

    /// The server, title, and file a `/library/parts/...` path belongs to.
    func locate(partPath: String, preferredHost: String? = nil) -> (server: PlexServerConfig, title: PlexIndexedTitle, item: PlexIndexedItem)? {
        let servers = PlexServerStore.shared.servers
        let preferred = servers.filter { preferredHost != nil && $0.baseURL?.host == preferredHost }
        for server in preferred + servers.filter({ candidate in !preferred.contains(where: { $0.id == candidate.id }) }) {
            for title in (titlesByServerID[server.id] ?? []) + lookedUp(forServerID: server.id) {
                if let item = title.items.first(where: { $0.files.contains { $0.partKey == partPath } }) {
                    return (server, title, item)
                }
            }
        }
        return nil
    }

    func titles() -> [PlexIndexedTitle] {
        let orderedIDs = PlexServerStore.shared.servers.map(\.id)
        let known = Set(orderedIDs)
        return orderedIDs.flatMap { titlesByServerID[$0] ?? [] }
            + titlesByServerID.filter { !known.contains($0.key) }.values.flatMap { $0 }
    }

    /// Titles for a Plex content id, or for a catalog title by IMDb or TMDB id,
    /// then the ones looked up for it in libraries too large to sync.
    func titles(matching contentId: String) -> [PlexIndexedTitle] {
        let trimmed = Self.normalizedContentId(contentId)
        guard !trimmed.isEmpty else { return [] }
        let targetImdb = trimmed.lowercased().hasPrefix("tt") ? NuvioMeta.canonicalImdbID(from: trimmed) : nil
        let targetTmdb = trimmed.hasPrefix("tmdb:") ? Int(trimmed.dropFirst(5)) : nil
        let synced = titles().filter { title in
            if title.contentId == trimmed { return true }
            if let targetImdb, let imdb = title.imdbId, NuvioMeta.canonicalImdbID(from: imdb) == targetImdb { return true }
            if let targetTmdb, title.tmdbId == targetTmdb { return true }
            return false
        }
        let lookedUp = (lookedUpTitles[trimmed] ?? []).filter { found in
            !synced.contains { $0.serverID == found.serverID && $0.ratingKey == found.ratingKey }
        }
        return synced + lookedUp
    }

    func meta(forContentId contentId: String) -> NuvioMeta? {
        guard contentId.hasPrefix("plex-"),
              let title = titles().first(where: { $0.contentId == contentId }) else { return nil }
        return meta(for: title)
    }

    func meta(for title: PlexIndexedTitle) -> NuvioMeta? {
        guard let server = PlexServerStore.shared.server(id: title.serverID),
              let baseURL = server.baseURL else { return nil }
        let token = PlexCredentialStore.token(forServerID: server.id)

        func image(_ path: String?, width: Int, height: Int) -> String? {
            PlexClient.imageURL(baseURL: baseURL, path: path, token: token, width: width, height: height)?.absoluteString
        }

        let videos: [NuvioVideo]? = title.type == "series"
            ? title.items.compactMap { file -> NuvioVideo? in
                guard let season = file.season, let episode = file.episode else { return nil }
                return NuvioVideo(
                    id: "\(title.contentId):\(season):\(episode)",
                    title: file.episodeName ?? L10n.format("jellyfin_episode_fallback_title", fallback: "Episode %d", episode),
                    season: season,
                    episode: episode,
                    thumbnail: image(file.episodeThumb, width: 640, height: 360),
                    overview: file.episodeOverview,
                    released: file.episodePremiereDate,
                    rating: nil
                )
            }
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
            : nil

        return NuvioMeta(
            id: title.contentId,
            name: title.name,
            description: title.overview,
            posterUrl: image(title.thumb, width: 400, height: 600),
            backgroundUrl: image(title.art, width: 1920, height: 1080),
            logoUrl: nil,
            imdbId: title.imdbId,
            tmdbId: title.tmdbId,
            type: title.type,
            year: title.year,
            genres: title.genres,
            rating: title.rating,
            releaseInfo: title.year.map(String.init),
            runtime: title.durationMs.map(Self.formattedRuntime),
            cast: title.cast,
            director: title.directors,
            writer: nil,
            certification: title.contentRating,
            country: nil,
            released: title.premiereDate,
            status: nil,
            videos: videos,
            trailerYtIds: nil,
            externalRatings: nil
        )
    }

    private static func formattedRuntime(milliseconds: Int64) -> String {
        let minutes = Int(milliseconds / 60_000)
        guard minutes > 0 else { return "" }
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Saves each library of the server that changed to its own file, off
    /// the main actor, then shows the new titles. One file per library keeps
    /// the memory a save needs to that of the largest library, and the main
    /// actor stays free while a large library is written.
    func replace(titles: [PlexIndexedTitle], forServerID serverID: String) async throws {
        let previous = Dictionary(grouping: titlesByServerID[serverID] ?? [], by: \.libraryID)
        let onDisk = savedLibraryIDs[serverID] ?? []
        let libraries = Self.groupedByLibrary(titles)
        let changed = libraries.filter { !onDisk.contains($0.libraryID) || previous[$0.libraryID] != $0.titles }
        let order = libraries.map(\.libraryID)
        let prefix = Self.storagePrefix
        let removal = removals[serverID, default: 0]
        let saved = await Self.onWriteQueue {
            Self.writeServer(serverID, changed: changed, order: order, prefix: prefix)
        }
        // The server was removed or the profile changed while this was
        // written: `removeAll`'s delete is queued after the write, and the
        // titles stay out of memory.
        guard removals[serverID, default: 0] == removal, Self.storagePrefix == prefix else { throw CancellationError() }
        guard saved else {
            savedLibraryIDs[serverID] = nil
            throw IndexError.persistenceFailed
        }
        savedLibraryIDs[serverID] = Set(order)
        var updated = titlesByServerID
        updated[serverID] = titles
        titlesByServerID = updated
        PlexWatched.rebuild(titles: updated, states: watchStatesByServerID)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    func removeAll(forServerID serverID: String) {
        for key in Array(lookedUpTitles.keys) {
            lookedUpTitles[key]?.removeAll { $0.serverID == serverID }
        }
        for key in Array(lookupTimes.keys) {
            lookupTimes[key] = lookupTimes[key]?.filter { !$0.key.hasPrefix("\(serverID)|") }
        }
        if rememberedItems.contains(where: { $0.serverID == serverID }) {
            rememberedItems.removeAll { $0.serverID == serverID }
            persistRememberedItems()
        }
        if watchStatesByServerID[serverID] != nil {
            var states = watchStatesByServerID
            states.removeValue(forKey: serverID)
            watchStatesByServerID = states
            if let data = try? JSONEncoder().encode(states) {
                _ = LargePayloadStore.write(data, key: Self.watchStateKey, directory: Self.storageDirectoryName)
            }
        }
        // Deleted from disk even when nothing is in memory: a sync may be
        // writing the server's first titles right now.
        removals[serverID, default: 0] += 1
        savedLibraryIDs[serverID] = nil
        let prefix = Self.storagePrefix
        Self.writeQueue.async { _ = Self.writeServer(serverID, changed: [], order: [], prefix: prefix) }
        var updated = titlesByServerID
        guard updated.removeValue(forKey: serverID) != nil else { return }
        titlesByServerID = updated
        PlexWatched.rebuild(titles: updated, states: watchStatesByServerID)
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    nonisolated private static let storageDirectoryName = "plexLibraryIndex"
    /// Where every server's titles were saved as one file, before each
    /// library got its own.
    static var legacyStorageKey: String {
        "plexLibraryIndex.\(ProfileSettings.activeProfileID ?? "default")"
    }
    /// What the active profile's keys start with. Not the legacy key plus a
    /// suffix, so no profile id can make one look like the other.
    private static var storagePrefix: String {
        "plexLibraryIndex.v2|\(ProfileSettings.activeProfileID ?? "default")|"
    }
    /// A saved index larger than this is from a library past today's limit:
    /// reading it again could take more memory than tvOS allows. About
    /// 190,000 items.
    nonisolated static let legacyByteLimit = 150 * 1_048_576

    /// Waits for the saves already asked for.
    nonisolated static func waitForPendingWrites() { writeQueue.sync {} }
    /// The library ids saved for each server, in their order.
    nonisolated private static func manifestKey(prefix: String) -> String { prefix + "servers" }
    nonisolated private static func libraryKey(prefix: String, serverID: String, libraryID: String) -> String {
        prefix + "library|\(serverID)|\(libraryID)"
    }

    /// Saves are written one after another, in the order they were asked for.
    nonisolated private static let writeQueue = DispatchQueue(label: "nuvio.tv.plex.libraryIndex.write", qos: .utility)

    /// Main-actor isolated on purpose: the work is queued before the caller
    /// suspends, so it keeps its place ahead of anything the main actor
    /// queues next (a `removeAll`'s delete).
    private static func onWriteQueue<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            writeQueue.async { continuation.resume(returning: work()) }
        }
    }

    /// A server's titles by library, in the order the libraries come.
    nonisolated static func groupedByLibrary(_ titles: [PlexIndexedTitle]) -> [(libraryID: String, titles: [PlexIndexedTitle])] {
        var order: [String] = []
        var byLibrary: [String: [PlexIndexedTitle]] = [:]
        for title in titles {
            if byLibrary[title.libraryID] == nil { order.append(title.libraryID) }
            byLibrary[title.libraryID, default: []].append(title)
        }
        return order.map { ($0, byLibrary[$0] ?? []) }
    }

    /// Writes the changed libraries, then the server's library list, then
    /// deletes the files of libraries no longer listed. An empty `order`
    /// removes the server. Runs on `writeQueue`.
    nonisolated private static func writeServer(
        _ serverID: String,
        changed: [(libraryID: String, titles: [PlexIndexedTitle])],
        order: [String],
        prefix: String
    ) -> Bool {
        let encoder = JSONEncoder()
        for library in changed {
            // One library's data at a time: it's released before the next.
            guard let data = try? encoder.encode(library.titles),
                  LargePayloadStore.write(data, key: libraryKey(prefix: prefix, serverID: serverID, libraryID: library.libraryID), directory: storageDirectoryName)
            else { return false }
        }
        var manifest = readManifest(prefix: prefix) ?? [:]
        let previous = manifest[serverID] ?? []
        manifest[serverID] = order.isEmpty ? nil : order
        guard let data = try? encoder.encode(manifest),
              LargePayloadStore.write(data, key: manifestKey(prefix: prefix), directory: storageDirectoryName) else { return false }
        for libraryID in previous where !order.contains(libraryID) {
            LargePayloadStore.remove(key: libraryKey(prefix: prefix, serverID: serverID, libraryID: libraryID), directory: storageDirectoryName)
        }
        return true
    }

    nonisolated private static func readManifest(prefix: String) -> [String: [String]]? {
        guard let data = LargePayloadStore.read(key: manifestKey(prefix: prefix), directory: storageDirectoryName) else { return nil }
        return try? JSONDecoder().decode([String: [String]].self, from: data)
    }

    /// The active profile's titles, library by library. Titles saved in the
    /// single file of earlier versions are read once and saved again a
    /// library at a time.
    /// A library whose file is missing is left out, and a sync lists it
    /// again: it is neither in memory nor among the saved libraries.
    private static func loadTitles() -> (titles: [String: [PlexIndexedTitle]], saved: [String: Set<String>]) {
        // A save still queued for this profile would otherwise be missed.
        waitForPendingWrites()
        let prefix = storagePrefix
        if let manifest = readManifest(prefix: prefix) {
            var result: [String: [PlexIndexedTitle]] = [:]
            var saved: [String: Set<String>] = [:]
            let decoder = JSONDecoder()
            for (serverID, libraryIDs) in manifest {
                var titles: [PlexIndexedTitle] = []
                for libraryID in libraryIDs {
                    guard let data = LargePayloadStore.read(key: libraryKey(prefix: prefix, serverID: serverID, libraryID: libraryID), directory: storageDirectoryName),
                          let decoded = try? decoder.decode([PlexIndexedTitle].self, from: data) else { continue }
                    titles += decoded
                    saved[serverID, default: []].insert(libraryID)
                }
                if !titles.isEmpty { result[serverID] = titles }
            }
            return (result, saved)
        }
        let legacyKey = legacyStorageKey
        guard let data = LargePayloadStore.read(key: legacyKey, directory: storageDirectoryName) else { return ([:], [:]) }
        guard data.count <= legacyByteLimit,
              let decoded = try? JSONDecoder().decode([String: [PlexIndexedTitle]].self, from: data) else {
            // Too large to read safely, or unreadable: the next sync lists
            // the libraries again under the shared limit.
            LargePayloadStore.remove(key: legacyKey, directory: storageDirectoryName)
            return ([:], [:])
        }
        // Every library first, then one manifest: until all of them are on
        // disk, the legacy file stays the one that is read.
        let servers = decoded.mapValues(groupedByLibrary)
        writeQueue.async {
            let encoder = JSONEncoder()
            for (serverID, libraries) in servers {
                for library in libraries {
                    guard let data = try? encoder.encode(library.titles),
                          LargePayloadStore.write(data, key: libraryKey(prefix: prefix, serverID: serverID, libraryID: library.libraryID), directory: storageDirectoryName)
                    else { return }
                }
            }
            guard let manifest = try? encoder.encode(servers.mapValues { $0.map(\.libraryID) }),
                  LargePayloadStore.write(manifest, key: manifestKey(prefix: prefix), directory: storageDirectoryName) else { return }
            LargePayloadStore.remove(key: legacyKey, directory: storageDirectoryName)
        }
        // Not marked saved: a sync before the migration finishes writes them too.
        return (decoded, [:])
    }

    private static var watchStateKey: String {
        "plexWatchStates.\(ProfileSettings.activeProfileID ?? "default")"
    }

    private static func loadWatchStates() -> [String: [String: PlexWatchState]] {
        guard let data = LargePayloadStore.read(key: watchStateKey, directory: storageDirectoryName),
              let decoded = try? JSONDecoder().decode([String: [String: PlexWatchState]].self, from: data) else { return [:] }
        return decoded
    }

    private static var rememberedKey: String {
        "plexRememberedItems.\(ProfileSettings.activeProfileID ?? "default")"
    }

    private static func loadRememberedItems() -> [PlexRememberedItem] {
        guard let data = LargePayloadStore.read(key: rememberedKey, directory: storageDirectoryName),
              let decoded = try? JSONDecoder().decode([PlexRememberedItem].self, from: data) else { return [] }
        return decoded
    }

    private func persistRememberedItems() {
        if let data = try? JSONEncoder().encode(rememberedItems) {
            _ = LargePayloadStore.write(data, key: Self.rememberedKey, directory: Self.storageDirectoryName)
        }
    }

}
