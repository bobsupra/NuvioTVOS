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
    let titles: Int
    let episodes: Int
}

enum PlexSyncState: Equatable {
    case idle
    case syncing(found: Int, library: String)
    case done(PlexSyncReport)
    case failed(String)
}

/// Owns the live connection for each added Plex server and drives Connect /
/// Sync, mirroring `JellyfinSessionManager`. Plex returns a whole section per
/// item type in a few large pages, so a sync is three paged listings per
/// library and needs no per-show requests or resumable checkpoints.
@MainActor
final class PlexSessionManager: ObservableObject {
    static let shared = PlexSessionManager()

    nonisolated static let foregroundAutoSyncInterval: TimeInterval = 6 * 3600
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
            if let last = server.lastSyncDate, Date().timeIntervalSince(last) < minimumInterval { continue }
            sync(server)
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
    func sync(_ server: PlexServerConfig, force: Bool = false) {
        guard !server.selectedLibraryIDs.isEmpty,
              let client = client(forServerID: server.id),
              case .connected(let connectedLibraries) = connectionState(for: server.id) else { return }
        let profileID = activeProfileID
        syncTasks[server.id]?.cancel()
        syncStates[server.id] = .syncing(found: 0, library: "")

        syncTasks[server.id] = Task { [weak self] in
            guard let self else { return }
            do {
                // Fresh change markers; the connected list can be hours old.
                let libraries = (try? await client.libraries()) ?? connectedLibraries
                let selected = libraries.filter { server.selectedLibraryIDs.contains($0.id) }
                let previousMarkers = server.libraryChangeMarkers ?? [:]
                let previousTitles = PlexLibraryIndex.shared.titlesByServerID[server.id] ?? []
                var markers: [String: String] = [:]
                var titles: [PlexIndexedTitle] = []
                var states: [String: PlexWatchState] = [:]
                let readAt = Int64(Date().timeIntervalSince1970)
                var listedEverything = true
                var found = 0
                for library in selected {
                    try Task.checkCancellation()
                    markers[library.id] = library.changeMarker
                    let kept = previousTitles.filter { $0.libraryID == library.id }
                    // Titles synced before file formats were kept are listed once more.
                    let hasFileDetails = kept.isEmpty || kept.contains { $0.items.contains { $0.details != nil } }
                    if !force, hasFileDetails, let marker = library.changeMarker, previousMarkers[library.id] == marker {
                        titles += kept
                        found += kept.reduce(0) { $0 + $1.items.count }
                        listedEverything = false
                        continue
                    }
                    let foundBefore = found
                    let libraryName = library.name
                    let serverID = server.id
                    let progress: (Int, Int?) -> Void = { count, _ in
                        Task { @MainActor [weak self] in
                            guard let self, case .syncing = self.syncStates[serverID] else { return }
                            self.syncStates[serverID] = .syncing(found: foundBefore + count, library: libraryName)
                        }
                    }
                    if library.type == "movie" {
                        let movies = try await client.items(libraryID: library.id, type: .movie, onPageFetched: progress)
                        found += movies.count
                        for movie in movies { states[movie.ratingKey] = PlexWatchState(movie) }
                        titles += PlexLibraryResolver.resolve(movies: movies, shows: [], episodes: [], serverID: server.id, library: library)
                    } else {
                        let shows = try await client.items(libraryID: library.id, type: .show, onPageFetched: progress)
                        found += shows.count
                        let episodes = try await client.items(libraryID: library.id, type: .episode, onPageFetched: progress)
                        found += episodes.count
                        for episode in episodes { states[episode.ratingKey] = PlexWatchState(episode) }
                        titles += PlexLibraryResolver.resolve(movies: [], shows: shows, episodes: episodes, serverID: server.id, library: library)
                    }
                }
                try Task.checkCancellation()
                guard self.activeProfileID == profileID else { return }
                if titles != previousTitles {
                    try PlexLibraryIndex.shared.replace(titles: titles, forServerID: server.id)
                }
                // Kept libraries' states stay; what was played in them since
                // the last read arrives through `refreshWatchStates`.
                PlexLibraryIndex.shared.setWatchStates(states, forServerID: server.id, merging: !listedEverything)
                if !listedEverything { await self.refreshWatchStates(forServerID: server.id) }
                if var updated = PlexServerStore.shared.server(id: server.id) {
                    updated.lastSyncDate = Date()
                    updated.lastSyncTitleCount = titles.count
                    updated.libraryChangeMarkers = markers
                    if listedEverything { updated.watchStateReadAt = readAt }
                    PlexServerStore.shared.upsert(updated)
                }
                self.syncStates[server.id] = .done(PlexSyncReport(
                    titles: titles.count,
                    episodes: titles.filter { $0.type == "series" }.reduce(0) { $0 + $1.items.count }
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
}
