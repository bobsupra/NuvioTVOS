import Foundation

enum PlexConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(libraries: [PlexLibrary])
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

struct PlexSyncReport: Equatable {
    struct OversizedLibrary: Equatable {
        let name: String
        /// 0 when the server didn't say.
        let itemCount: Int
    }

    struct LibraryFailure: Equatable {
        let name: String
        let reason: String
    }

    let titles: Int
    let episodes: Int
    /// Libraries too large to sync. Stream lists ask the server about each
    /// title in them instead.
    var oversizedLibraries: [OversizedLibrary] = []
    /// Libraries whose listing failed. Their titles from the last sync stay.
    var failedLibraries: [LibraryFailure] = []
}

/// What a sync found, library by library (`PlexSessionManager.syncLibraries`).
struct PlexLibrarySyncOutcome {
    var titles: [PlexIndexedTitle] = []
    var states: [String: PlexWatchState] = [:]
    var markers: [String: String] = [:]
    /// Libraries too large to sync, by id, with their item counts.
    var oversized: [String: Int] = [:]
    var oversizedLibraries: [PlexSyncReport.OversizedLibrary] = []
    var failures: [PlexSyncReport.LibraryFailure] = []
    var firstFailure: Error?
    /// Libraries listed, or kept because they hadn't changed.
    var syncedLibraries = 0
    /// Every library not too large to sync was listed in full, so `states`
    /// is complete for those libraries.
    var listedEverything = true

    /// Whether `states` can replace the server's watch state. Not when a
    /// library was kept, failed or was too large to sync: those keep the
    /// states read before (titles looked up in an oversized library among
    /// them), and the new states are merged in.
    var replacesWatchStates: Bool { listedEverything && oversized.isEmpty }
}

enum PlexSyncState: Equatable {
    case idle
    case syncing(found: Int, library: String)
    case done(PlexSyncReport)
    case failed(String)
}

/// Resumes a wait once, whichever of the work or the time limit ends first.
@MainActor
private final class PlexWaitGate<Value> {
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Value, Never>, returning value: Value) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}

/// Owns the live connection for each added Plex server and drives Connect /
/// Sync, mirroring `JellyfinSessionManager`. Plex returns a whole section per
/// item type in a few large pages, so a sync is three paged listings per
/// library and needs no per-show requests or resumable checkpoints.
@MainActor
final class PlexSessionManager: ObservableObject {
    static let shared = PlexSessionManager()

    /// A library that hasn't changed costs one small request to check, so a
    /// return to the app looks for new titles often.
    nonisolated static let foregroundAutoSyncInterval: TimeInterval = 15 * 60
    /// Opening a stream list syncs first when the last sync is older than this,
    /// so a title added since then offers its Plex copy on the first open.
    nonisolated static let streamListAutoSyncInterval: TimeInterval = 5 * 60
    /// How long a stream list waits for that sync before it shows what it has.
    nonisolated static let streamListSyncWait: TimeInterval = 2
    nonisolated static let launchAutoSyncCooldown: TimeInterval = 60

    @Published private(set) var connectionStates: [String: PlexConnectionState] = [:]
    @Published private(set) var syncStates: [String: PlexSyncState] = [:]
    /// Plex refused the saved token: Settings offers to sign in again.
    @Published private(set) var needsSignIn = false

    private var clients: [String: PlexClient] = [:]
    private var syncTasks: [String: Task<Void, Never>] = [:]
    private var connectionGenerations: [String: Int] = [:]
    private var connectionProfileIDs: [String: String] = [:]
    private var lastReconnectAttempt: [String: Date] = [:]

    nonisolated static let reconnectInterval: TimeInterval = 30

    private init() {}

    private var activeProfileID: String { ProfileSettings.activeProfileID ?? "default" }

    func connectionState(for serverID: String) -> PlexConnectionState {
        guard connectionProfileIDs[serverID] == nil || connectionProfileIDs[serverID] == activeProfileID else {
            return .disconnected
        }
        return connectionStates[serverID] ?? .disconnected
    }

    func syncState(for serverID: String) -> PlexSyncState {
        syncStates[serverID] ?? .idle
    }

    /// A connected client for building playback and progress requests.
    func client(forServerID serverID: String) -> PlexClient? {
        guard connectionProfileIDs[serverID] == activeProfileID else { return nil }
        return clients[serverID]
    }

    // MARK: - Account

    /// Re-reads the account's servers from plex.tv, adding new ones.
    func refreshServers() async throws {
        let token = PlexCredentialStore.accountToken()
        guard !token.isEmpty else { return }
        let resources = try await servers(accountToken: token)
        PlexServerStore.shared.merge(resources)
    }

    /// The account's servers, noting when plex.tv refuses the token.
    private func servers(accountToken: String) async throws -> [PlexResource] {
        do {
            let resources = try await PlexClient.servers(accountToken: accountToken)
            needsSignIn = false
            return resources
        } catch let error as PlexClient.ClientError where error.isUnauthorized {
            needsSignIn = true
            throw error
        }
    }

    /// Completes a sign-in (or a repeat one after the token expired).
    func signedIn(name: String, token: String) async throws {
        PlexServerStore.shared.signedIn(name: name, token: token)
        needsSignIn = false
        try await refreshServers()
        for server in PlexServerStore.shared.servers { disconnect(server) }
        await connectAll(autoSync: true)
    }

    // MARK: - Plex Home

    func homeUsers() async throws -> [PlexClient.HomeUser] {
        try await PlexClient.homeUsers(accountToken: PlexCredentialStore.ownerToken())
    }

    /// Acts as another member of the Plex Home from now on: their library
    /// access, their watch state, and their resume positions.
    func switchHomeUser(_ user: PlexClient.HomeUser, pin: String?) async throws {
        let token = try await PlexClient.switchHomeUser(user, pin: pin, accountToken: PlexCredentialStore.ownerToken())
        let store = PlexServerStore.shared
        for server in store.servers {
            disconnect(server)
            // Server tokens and watch state belong to the previous user.
            PlexCredentialStore.remove(forServerID: server.id)
            PlexLibraryIndex.shared.removeAll(forServerID: server.id)
            var reset = server
            reset.watchStateReadAt = nil
            reset.libraryChangeMarkers = nil
            reset.lastSyncDate = nil
            reset.lastSyncAttemptDate = nil
            reset.oversizedLibraries = nil
            store.upsert(reset)
        }
        store.setAccount(name: user.name, token: token)
        try await refreshServers()
        await connectAll(autoSync: true)
    }

    /// After a failed request to a server: try to reach it again, at most
    /// every `reconnectInterval` seconds. Covers a server that slept, moved
    /// address, or restarted while the app stayed open.
    func reconnectIfNeeded(serverID: String) async {
        guard let server = PlexServerStore.shared.server(id: serverID) else { return }
        if case .connecting = connectionState(for: serverID) { return }
        if let last = lastReconnectAttempt[serverID], Date().timeIntervalSince(last) < Self.reconnectInterval { return }
        lastReconnectAttempt[serverID] = Date()
        if let client = client(forServerID: serverID),
           await PlexClient.isServer(client.baseURL, machineIdentifier: serverID) {
            return
        }
        await connect(server)
    }

    func signOut() {
        for server in PlexServerStore.shared.servers {
            disconnect(server)
        }
        PlexServerStore.shared.signOut()
    }

    // MARK: - Connect

    /// Best-effort connect to every added server at launch and on profile
    /// switch, then a background sync for servers that are due.
    func connectAll(autoSync: Bool = true) async {
        guard PlexServerStore.shared.isSignedIn else { return }
        let resources = try? await servers(accountToken: PlexCredentialStore.accountToken())
        if let resources { PlexServerStore.shared.merge(resources) }
        await withTaskGroup(of: Void.self) { group in
            for server in PlexServerStore.shared.servers {
                if connectionProfileIDs[server.id] != activeProfileID {
                    clients[server.id] = nil
                    connectionStates[server.id] = .disconnected
                }
                switch connectionState(for: server.id) {
                case .connecting, .connected:
                    continue
                case .disconnected, .failed:
                    let resource = resources?.first { $0.clientIdentifier == server.id }
                    group.addTask { [weak self] in
                        await self?.connect(server, resource: resource)
                    }
                }
            }
        }
        if autoSync, NSClassFromString("XCTestCase") == nil {
            autoSyncConnectedServers(minimumInterval: Self.launchAutoSyncCooldown)
        }
    }

    func handleForegroundSession() async {
        let alreadyConnected = PlexServerStore.shared.servers.map(\.id).filter { connectionState(for: $0).isConnected }
        await connectAll(autoSync: false)
        // Newly connected servers read their watch state while connecting.
        for serverID in alreadyConnected {
            await refreshWatchStates(forServerID: serverID)
        }
        if NSClassFromString("XCTestCase") == nil {
            autoSyncConnectedServers(minimumInterval: Self.foregroundAutoSyncInterval)
        }
    }

    func autoSyncConnectedServers(minimumInterval: TimeInterval) {
        for server in PlexServerStore.shared.servers {
            guard server.syncAutomatically,
                  !server.selectedLibraryIDs.isEmpty,
                  connectionState(for: server.id).isConnected else { continue }
            if case .syncing = syncState(for: server.id) { continue }
            guard Self.isSyncDue(
                lastSyncDate: server.lastSyncDate,
                lastAttemptDate: server.lastSyncAttemptDate,
                minimumInterval: minimumInterval
            ) else { continue }
            sync(server)
        }
    }

    /// Due once `minimumInterval` has passed since the later of the last
    /// finished sync and the last attempt, so a failed sync waits as long as
    /// a finished one.
    nonisolated static func isSyncDue(
        lastSyncDate: Date?,
        lastAttemptDate: Date? = nil,
        minimumInterval: TimeInterval,
        now: Date = Date()
    ) -> Bool {
        guard let last = [lastSyncDate, lastAttemptDate].compactMap({ $0 }).max() else { return true }
        return now.timeIntervalSince(last) >= minimumInterval
    }

    /// Before a stream list reads the Plex titles: syncs the servers that are
    /// due and waits for them, at most `timeout`. A slower sync carries on in
    /// the background and its titles show the next time the list opens.
    func syncDueServersBeforeStreamList(
        minimumInterval: TimeInterval = PlexSessionManager.streamListAutoSyncInterval,
        timeout: TimeInterval = PlexSessionManager.streamListSyncWait
    ) async {
        guard NSClassFromString("XCTestCase") == nil else { return }
        autoSyncConnectedServers(minimumInterval: minimumInterval)
        let running = PlexServerStore.shared.servers.compactMap { server -> Task<Void, Never>? in
            guard case .syncing = syncState(for: server.id) else { return nil }
            return syncTasks[server.id]
        }
        guard !running.isEmpty else { return }
        let gate = PlexWaitGate<Void>()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                for task in running { await task.value }
                gate.resume(continuation, returning: ())
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                gate.resume(continuation, returning: ())
            }
        }
    }

    /// Finds an address that answers as this server, preferring local ones,
    /// then lists its libraries. Without a fresh plex.tv listing it falls back
    /// to the last address that worked.
    func connect(_ server: PlexServerConfig, resource: PlexResource? = nil) async {
        let profileID = activeProfileID
        let generation = (connectionGenerations[server.id] ?? 0) &+ 1
        connectionGenerations[server.id] = generation
        connectionProfileIDs[server.id] = profileID
        clients[server.id] = nil
        connectionStates[server.id] = .connecting

        func isCurrent() -> Bool {
            connectionGenerations[server.id] == generation && activeProfileID == profileID && !Task.isCancelled
        }

        var resource = resource
        if resource == nil {
            resource = try? await PlexClient.servers(accountToken: PlexCredentialStore.accountToken())
                .first { $0.clientIdentifier == server.id }
            guard isCurrent() else { return }
        }

        var baseURL: URL?
        if let resource {
            baseURL = await PlexClient.reachableBaseURL(for: resource)
        }
        if baseURL == nil, let saved = server.baseURL,
           await PlexClient.isServer(saved, machineIdentifier: server.id) {
            baseURL = saved
        }
        guard isCurrent() else { return }
        guard let baseURL else {
            connectionStates[server.id] = .failed(L10n.string(
                "plex_unreachable",
                fallback: "No address for this server answered. Check that it's running and on the same network."
            ))
            return
        }

        let client = PlexClient(baseURL: baseURL, token: PlexCredentialStore.token(forServerID: server.id))
        do {
            let libraries = try await client.libraries()
            guard isCurrent() else { return }
            if server.baseURLString != baseURL.absoluteString,
               var updated = PlexServerStore.shared.server(id: server.id) {
                updated.baseURLString = baseURL.absoluteString
                PlexServerStore.shared.upsert(updated)
            }
            clients[server.id] = client
            connectionStates[server.id] = .connected(libraries: libraries)
            await refreshWatchStates(forServerID: server.id)
        } catch {
            guard isCurrent() else { return }
            if (error as? PlexClient.ClientError)?.isUnauthorized == true { needsSignIn = true }
            connectionStates[server.id] = .failed(error.localizedDescription)
        }
    }

    func disconnect(_ server: PlexServerConfig) {
        connectionGenerations[server.id] = (connectionGenerations[server.id] ?? 0) &+ 1
        syncTasks[server.id]?.cancel()
        syncTasks[server.id] = nil
        clients[server.id] = nil
        connectionProfileIDs[server.id] = nil
        connectionStates[server.id] = .disconnected
        syncStates[server.id] = .idle
    }

    // MARK: - Watch state

    /// Reads what was played on the server since the last read: one small
    /// request per selected library and type. Runs on every connect, so a
    /// position saved by another Plex app is known before anything plays here.
    func refreshWatchStates(forServerID serverID: String) async {
        guard let server = PlexServerStore.shared.server(id: serverID),
              let since = server.watchStateReadAt,
              let client = client(forServerID: serverID),
              case .connected(let libraries) = connectionState(for: serverID) else { return }
        let readAt = Int64(Date().timeIntervalSince1970)
        var states: [String: PlexWatchState] = [:]
        do {
            for library in libraries where server.selectedLibraryIDs.contains(library.id) {
                let type: PlexClient.ItemType = library.type == "movie" ? .movie : .episode
                // A minute of overlap covers clock differences with the server.
                for item in try await client.items(libraryID: library.id, type: type, viewedSince: since - 60) {
                    states[item.ratingKey] = PlexWatchState(item)
                }
            }
        } catch {
            return
        }
        PlexLibraryIndex.shared.setWatchStates(states, forServerID: serverID, merging: true)
        if var updated = PlexServerStore.shared.server(id: serverID) {
            updated.watchStateReadAt = readAt
            PlexServerStore.shared.upsert(updated)
        }
    }

    // MARK: - Sync

    /// Lists the selected libraries and stores their titles. A library whose
    /// contents haven't changed since its last sync is kept as it is, so a
    /// routine sync of a large, unchanged library is one small request.
    /// `force` lists everything again (the Sync button).
    ///
    /// Each library stands alone: one whose listing fails keeps its titles
    /// from the last sync while the others sync, and one too large to sync
    /// is skipped and looked up a title at a time by stream lists
    /// (`lookUpInOversizedLibraries`). The sync fails only when no library
    /// synced.
    func sync(_ server: PlexServerConfig, force: Bool = false) {
        guard !server.selectedLibraryIDs.isEmpty,
              let client = client(forServerID: server.id),
              case .connected(let connectedLibraries) = connectionState(for: server.id) else { return }
        let profileID = activeProfileID
        syncTasks[server.id]?.cancel()
        syncStates[server.id] = .syncing(found: 0, library: "")
        if var attempted = PlexServerStore.shared.server(id: server.id) {
            attempted.lastSyncAttemptDate = Date()
            PlexServerStore.shared.upsert(attempted)
        }

        syncTasks[server.id] = Task { [weak self] in
            guard let self else { return }
            do {
                // Fresh change markers; the connected list can be hours old.
                let libraries = (try? await client.libraries()) ?? connectedLibraries
                let selected = libraries.filter { server.selectedLibraryIDs.contains($0.id) }
                let previousTitles = PlexLibraryIndex.shared.titlesByServerID[server.id] ?? []
                let readAt = Int64(Date().timeIntervalSince1970)
                let serverID = server.id
                let outcome = try await Self.syncLibraries(
                    selected,
                    client: client,
                    serverID: serverID,
                    previousTitles: previousTitles,
                    previousMarkers: server.libraryChangeMarkers ?? [:],
                    knownOversized: server.oversizedLibraries ?? [:],
                    force: force,
                    onProgress: { found, libraryName in
                        Task { @MainActor [weak self] in
                            guard let self, case .syncing = self.syncStates[serverID] else { return }
                            self.syncStates[serverID] = .syncing(found: found, library: libraryName)
                        }
                    }
                )
                try Task.checkCancellation()
                guard self.activeProfileID == profileID else { return }
                // Nothing synced: report why, and leave the index as it was.
                if let failure = outcome.firstFailure, outcome.syncedLibraries == 0, outcome.oversized.isEmpty {
                    throw failure
                }
                let titles = outcome.titles
                if titles != previousTitles {
                    try PlexLibraryIndex.shared.replace(titles: titles, forServerID: server.id)
                }
                // Kept, failed and oversized libraries keep their states; what
                // was played in them since the last read arrives through
                // `refreshWatchStates`.
                PlexLibraryIndex.shared.setWatchStates(outcome.states, forServerID: server.id, merging: !outcome.replacesWatchStates)
                if !outcome.replacesWatchStates { await self.refreshWatchStates(forServerID: server.id) }
                if var updated = PlexServerStore.shared.server(id: server.id) {
                    updated.lastSyncDate = Date()
                    updated.lastSyncTitleCount = titles.count
                    updated.libraryChangeMarkers = outcome.markers
                    updated.oversizedLibraries = outcome.oversized.isEmpty ? nil : outcome.oversized
                    if outcome.listedEverything { updated.watchStateReadAt = readAt }
                    PlexServerStore.shared.upsert(updated)
                }
                self.syncStates[server.id] = .done(PlexSyncReport(
                    titles: titles.count,
                    episodes: titles.filter { $0.type == "series" }.reduce(0) { $0 + $1.items.count },
                    oversizedLibraries: outcome.oversizedLibraries,
                    failedLibraries: outcome.failures
                ))
            } catch is CancellationError {
                // Superseded by a newer sync or a disconnect.
            } catch {
                if self.activeProfileID == profileID {
                    if (error as? PlexClient.ClientError)?.isUnauthorized == true { self.needsSignIn = true }
                    self.syncStates[server.id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Lists each library that changed since the last sync and keeps the rest
    /// as they were. A library whose listing fails keeps its titles and
    /// marker from the last sync; one too large to sync is skipped, and one
    /// already known to be too large isn't asked again unless `force`.
    /// Throws only for cancellation and a refused token.
    nonisolated static func syncLibraries(
        _ libraries: [PlexLibrary],
        client: PlexClient,
        serverID: String,
        previousTitles: [PlexIndexedTitle],
        previousMarkers: [String: String],
        knownOversized: [String: Int],
        force: Bool,
        onProgress: @escaping (_ found: Int, _ library: String) -> Void = { _, _ in }
    ) async throws -> PlexLibrarySyncOutcome {
        var outcome = PlexLibrarySyncOutcome()
        var found = 0
        for library in libraries {
            try Task.checkCancellation()
            // Only the Sync button checks again: a library past the limit
            // rarely drops under it, and each check downloads a page of it.
            if !force, let count = knownOversized[library.id] {
                outcome.oversized[library.id] = count
                outcome.oversizedLibraries.append(PlexSyncReport.OversizedLibrary(name: library.name, itemCount: count))
                continue
            }
            let kept = previousTitles.filter { $0.libraryID == library.id }
            // Titles synced before file formats were kept are listed once more.
            let hasFileDetails = kept.isEmpty || kept.contains { $0.items.contains { $0.details != nil } }
            if !force, hasFileDetails, let marker = library.changeMarker, previousMarkers[library.id] == marker {
                outcome.markers[library.id] = marker
                outcome.titles += kept
                found += kept.reduce(0) { $0 + $1.items.count }
                outcome.listedEverything = false
                outcome.syncedLibraries += 1
                continue
            }
            let foundBefore = found
            let progress: (Int, Int?) -> Void = { count, _ in onProgress(foundBefore + count, library.name) }
            do {
                if library.type == "movie" {
                    let movies = try await client.items(libraryID: library.id, type: .movie, onPageFetched: progress)
                    found += movies.count
                    for movie in movies { outcome.states[movie.ratingKey] = PlexWatchState(movie) }
                    outcome.titles += PlexLibraryResolver.resolve(movies: movies, shows: [], episodes: [], serverID: serverID, library: library)
                } else {
                    // Episodes first: in a library too large to sync they are
                    // what passes the limit, and the first page says so.
                    let episodes = try await client.items(libraryID: library.id, type: .episode, onPageFetched: progress)
                    let shows = try await client.items(
                        libraryID: library.id,
                        type: .show,
                        onPageFetched: { count, total in progress(episodes.count + count, total) }
                    )
                    found += episodes.count + shows.count
                    for episode in episodes { outcome.states[episode.ratingKey] = PlexWatchState(episode) }
                    outcome.titles += PlexLibraryResolver.resolve(movies: [], shows: shows, episodes: episodes, serverID: serverID, library: library)
                }
                outcome.markers[library.id] = library.changeMarker
                outcome.syncedLibraries += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as PlexClient.ClientError where error.isUnauthorized {
                throw error
            } catch let error as PlexClient.ClientError where error.isLibraryTooLarge {
                outcome.oversized[library.id] = error.itemCount ?? 0
                outcome.oversizedLibraries.append(PlexSyncReport.OversizedLibrary(name: library.name, itemCount: error.itemCount ?? 0))
            } catch {
                if let count = knownOversized[library.id] {
                    // The Sync button couldn't check it again: still too large.
                    outcome.oversized[library.id] = count
                    outcome.oversizedLibraries.append(PlexSyncReport.OversizedLibrary(name: library.name, itemCount: count))
                    continue
                }
                outcome.titles += kept
                if let marker = previousMarkers[library.id] { outcome.markers[library.id] = marker }
                outcome.failures.append(PlexSyncReport.LibraryFailure(name: library.name, reason: error.localizedDescription))
                outcome.firstFailure = outcome.firstFailure ?? error
                outcome.listedEverything = false
            }
        }
        return outcome
    }

    // MARK: - Libraries too large to sync

    /// How long the answer for one title in a library too large to sync is
    /// used before the server is asked again.
    nonisolated static let oversizedLookupInterval: TimeInterval = 15 * 60

    /// How long a stream list waits for that lookup, counted from when it
    /// starts, before it shows what it has.
    nonisolated static let streamListLookupWait: TimeInterval = 2.5

    /// Starts looking a stream list's title up in libraries too large to
    /// sync. Nil when no connected server has one.
    func startOversizedLookup(contentId: String, type: String) -> Task<Bool, Never>? {
        guard hasOversizedLibraries, NSClassFromString("XCTestCase") == nil else { return nil }
        return Task { await self.lookUpInOversizedLibraries(contentId: contentId, type: type) }
    }

    /// Whether `lookup` finished within `timeout`. It keeps running either way.
    func waitForLookup(_ lookup: Task<Bool, Never>, timeout: TimeInterval) async -> Bool {
        let gate = PlexWaitGate<Bool>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            Task { @MainActor in
                _ = await lookup.value
                gate.resume(continuation, returning: true)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                gate.resume(continuation, returning: false)
            }
        }
    }

    /// Whether a connected server has a selected library too large to sync.
    var hasOversizedLibraries: Bool {
        PlexServerStore.shared.servers.contains { server in
            guard let oversized = server.oversizedLibraries,
                  server.selectedLibraryIDs.contains(where: { oversized[$0] != nil }) else { return false }
            return connectionState(for: server.id).isConnected
        }
    }

    /// Asks each connected server about one title in its libraries too large
    /// to sync, and adds what it finds to `PlexLibraryIndex` for stream lists
    /// and playback, with Plex's watch state for each movie or episode found.
    /// The name and year come from the metadata cache, filled when the
    /// title's details load; without them nothing is asked.
    /// - Returns: whether anything was found.
    @discardableResult
    func lookUpInOversizedLibraries(contentId: String, type: String) async -> Bool {
        guard let meta = CinemetaCatalogRepository.cachedMetadata(for: contentId) else { return false }
        let target = PlexLargeLibraryLookup.Target(contentId: contentId, meta: meta)
        let wantsShows = type == "series" || meta.isSeries
        let index = PlexLibraryIndex.shared
        var requests: [(serverID: String, library: PlexLibrary, client: PlexClient)] = []
        for server in PlexServerStore.shared.servers {
            guard let oversized = server.oversizedLibraries,
                  let client = client(forServerID: server.id),
                  case .connected(let libraries) = connectionState(for: server.id) else { continue }
            for library in libraries where oversized[library.id] != nil
                && server.selectedLibraryIDs.contains(library.id)
                && (library.type == "show") == wantsShows {
                if index.wasLookedUp(contentId: contentId, serverID: server.id, libraryID: library.id, within: Self.oversizedLookupInterval) {
                    continue
                }
                requests.append((server.id, library, client))
            }
        }
        guard !requests.isEmpty else { return false }
        let profileID = activeProfileID
        let results = await withTaskGroup(of: (serverID: String, library: PlexLibrary, found: PlexLargeLibraryLookup.Found?).self) { group in
            for request in requests {
                group.addTask {
                    let found = try? await PlexLargeLibraryLookup.find(
                        target, in: request.library, serverID: request.serverID, client: request.client
                    )
                    return (request.serverID, request.library, found)
                }
            }
            var results: [(serverID: String, library: PlexLibrary, found: PlexLargeLibraryLookup.Found?)] = []
            for await result in group { results.append(result) }
            return results
        }
        guard activeProfileID == profileID else { return false }
        // A failed request is asked again on the next stream list.
        let answered = results.compactMap { result -> (serverID: String, libraryID: String, found: PlexLargeLibraryLookup.Found)? in
            result.found.map { (serverID: result.serverID, libraryID: result.library.id, found: $0) }
        }
        guard !answered.isEmpty else { return false }
        for (serverID, lookups) in Dictionary(grouping: answered, by: { $0.serverID }) {
            let states = lookups.reduce(into: [String: PlexWatchState]()) { all, lookup in
                all.merge(lookup.found.states) { _, new in new }
            }
            if !states.isEmpty { index.setWatchStates(states, forServerID: serverID, merging: true) }
        }
        let titles = answered.flatMap { $0.found.titles }
        index.recordLookup(
            contentId: contentId,
            libraries: answered.map { (serverID: $0.serverID, libraryID: $0.libraryID) },
            found: titles
        )
        return !titles.isEmpty
    }
}
