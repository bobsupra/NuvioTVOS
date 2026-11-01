import Foundation

/// State of a configured server's connection, published for the Settings row
/// (Connect / Disconnect button, status dot, library list).
enum JellyfinConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(libraries: [JellyfinLibrary])
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// State of a library sync, published for the library-selection sheet's
/// progress view and result report.
enum JellyfinSyncState: Equatable {
    case idle
    case syncing(found: Int, currentLibrary: String)
    case done(JellyfinSyncReport)
    case failed(String)
}

/// Summary of a completed sync, shown in the library-selection sheet.
struct JellyfinSyncReport: Equatable {
    var matchedTitles: Int
    var matchedEpisodes: Int
    var unmatched: [String]
}

/// Owns the live connection for each configured Jellyfin server and drives
/// Connect / Disconnect / Sync from Settings. Mirrors `SMBSessionManager`'s
/// shape; the main simplification is that Jellyfin already hands back
/// structured items with provider ids, so there's no separate scanner —
/// `sync(_:)` fetches and resolves in one pass.
@MainActor
final class JellyfinSessionManager: ObservableObject {
    static let shared = JellyfinSessionManager()

    nonisolated static let foregroundAutoSyncInterval: TimeInterval = 6 * 3600
    nonisolated static let launchAutoSyncCooldown: TimeInterval = 60

    @Published private(set) var connectionStates: [String: JellyfinConnectionState] = [:]
    @Published private(set) var syncStates: [String: JellyfinSyncState] = [:]

    private var clients: [String: JellyfinClient] = [:]
    private var syncTasks: [String: Task<Void, Never>] = [:]
    private var connectionGenerations: [String: Int] = [:]

    private init() {}

    func connectionState(for serverID: String) -> JellyfinConnectionState {
        connectionStates[serverID] ?? .disconnected
    }

    func syncState(for serverID: String) -> JellyfinSyncState {
        syncStates[serverID] ?? .idle
    }

    // MARK: - Connect / Disconnect

    /// Best-effort connect to every configured server, run once at cold
    /// launch (and again on profile switch) so Home doesn't require a
    /// manual "Connect" tap in Settings first. Mirrors
    /// `SMBSessionManager.connectAll()`. If `autoSync` is true, automatically
    /// triggers a background refresh for eligible servers.
    func connectAll(autoSync: Bool = true) async {
        await withTaskGroup(of: Void.self) { group in
            for server in JellyfinServerStore.shared.servers {
                switch connectionState(for: server.id) {
                case .connecting, .connected:
                    continue
                case .disconnected, .failed:
                    group.addTask { [weak self] in
                        await self?.connect(server)
                    }
                }
            }
        }
        if autoSync, NSClassFromString("XCTestCase") == nil {
            autoSyncConnectedServers(minimumInterval: Self.launchAutoSyncCooldown)
        }
    }

    /// Called when the app returns to the foreground. Re-connects any dropped
    /// servers and runs background sync for any server whose lastSyncDate is
    /// older than `minimumInterval` (default 6 hours).
    func handleForegroundSession(minimumInterval: TimeInterval = foregroundAutoSyncInterval) async {
        await connectAll(autoSync: false)
        if NSClassFromString("XCTestCase") == nil {
            autoSyncConnectedServers(minimumInterval: minimumInterval)
        }
    }

    /// Evaluates configured connected servers for automatic background sync.
    /// Skips servers where `syncAutomatically` is false, libraries are not selected,
    /// a sync is already in flight, or `lastSyncDate` is fresher than `minimumInterval`.
    func autoSyncConnectedServers(minimumInterval: TimeInterval? = nil) {
        for server in JellyfinServerStore.shared.servers {
            guard server.syncAutomatically,
                  !server.selectedLibraryIDs.isEmpty,
                  connectionState(for: server.id).isConnected else {
                continue
            }
            if case .syncing = syncState(for: server.id) {
                continue
            }
            if let lastSync = server.lastSyncDate, let minimumInterval {
                guard Date().timeIntervalSince(lastSync) >= minimumInterval else {
                    continue
                }
            }
            sync(server)
        }
    }

    func connect(_ server: JellyfinServerConfig) async {
        let generation = (connectionGenerations[server.id] ?? 0) &+ 1
        connectionGenerations[server.id] = generation
        guard let baseURL = server.baseURL else {
            connectionStates[server.id] = .failed(L10n.string("jellyfin_invalid_url", fallback: "Invalid server URL"))
            return
        }
        connectionStates[server.id] = .connecting
        do {
            let token = JellyfinCredentialStore.token(forServerID: server.id)
            var resolvedUserId = server.userId
            if resolvedUserId.isEmpty {
                resolvedUserId = try await JellyfinClient.currentUserId(baseURL: baseURL, apiKey: token, username: server.username)
                guard connectionGenerations[server.id] == generation,
                      !Task.isCancelled else { return }
                var updated = server
                updated.userId = resolvedUserId
                JellyfinServerStore.shared.upsert(updated)
            }
            let client = JellyfinClient(baseURL: baseURL, accessToken: token)
            try await client.ping()
            guard connectionGenerations[server.id] == generation,
                  !Task.isCancelled else { return }
            let libraries = try await client.libraries(userId: resolvedUserId)
            guard connectionGenerations[server.id] == generation,
                  !Task.isCancelled else { return }
            clients[server.id] = client
            connectionStates[server.id] = .connected(libraries: libraries)
        } catch {
            if connectionGenerations[server.id] == generation, !Task.isCancelled {
                connectionStates[server.id] = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect(_ server: JellyfinServerConfig) async {
        connectionGenerations[server.id] = (connectionGenerations[server.id] ?? 0) &+ 1
        syncTasks[server.id]?.cancel()
        syncTasks[server.id] = nil
        clients[server.id] = nil
        connectionStates[server.id] = .disconnected
        syncStates[server.id] = .idle
    }

    // MARK: - Sync

    /// Fetches every selected library's items and groups them into titles —
    /// all metadata comes from Jellyfin's own response, nothing is looked up
    /// elsewhere. Only meaningful once connected. Cancels a prior in-flight
    /// sync for the same server.
    func sync(_ server: JellyfinServerConfig) {
        guard !server.selectedLibraryIDs.isEmpty else { return }
        guard let client = clients[server.id] else { return }
        syncTasks[server.id]?.cancel()
        syncStates[server.id] = .syncing(found: 0, currentLibrary: "")

        syncTasks[server.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let selectedIDs = Set(server.selectedLibraryIDs)
                let connectedLibraries: [JellyfinLibrary]
                if let state = self.connectionStates[server.id],
                   case let .connected(libraries) = state {
                    connectedLibraries = libraries
                } else {
                    connectedLibraries = []
                }
                let knownLibraries = connectedLibraries.filter { selectedIDs.contains($0.id) }
                let knownIDs = Set(knownLibraries.map(\.id))
                // Keep stale configured ids syncable, while making their order
                // stable and their missing display name explicit.
                let missingLibraries = selectedIDs.subtracting(knownIDs).sorted().map {
                    JellyfinLibrary(id: $0, name: $0, collectionType: nil)
                }
                let selectedLibraries = knownLibraries + missingLibraries
                var indexedTitles: [JellyfinIndexedTitle] = []
                var unmatched: [String] = []
                var fetchedItemCount = 0
                for library in selectedLibraries {
                    try Task.checkCancellation()
                    let foundCount = fetchedItemCount
                    await MainActor.run {
                        self.syncStates[server.id] = .syncing(found: foundCount, currentLibrary: library.name)
                    }
                    let items = try await client.items(userId: server.userId, libraryId: library.id)
                    fetchedItemCount += items.count
                    let resolution = JellyfinLibraryResolver.resolve(
                        items,
                        serverID: server.id,
                        libraryID: library.id,
                        libraryName: library.name
                    )
                    indexedTitles.append(contentsOf: resolution.titles)
                    unmatched.append(contentsOf: resolution.unmatched)
                }
                try Task.checkCancellation()

                let resolution = JellyfinLibraryResolution(
                    titles: indexedTitles,
                    unmatched: unmatched,
                    completedAt: Date()
                )

                JellyfinLibraryIndex.shared.replace(titles: resolution.titles, forServerID: server.id)

                var updatedServer = JellyfinServerStore.shared.server(id: server.id) ?? server
                updatedServer.lastSyncDate = resolution.completedAt
                updatedServer.lastSyncTitleCount = resolution.titles.count
                JellyfinServerStore.shared.upsert(updatedServer)

                syncStates[server.id] = .done(
                    JellyfinSyncReport(
                        matchedTitles: resolution.titles.count,
                        matchedEpisodes: resolution.titles.reduce(0) { $0 + $1.items.count },
                        unmatched: resolution.unmatched
                    )
                )
            } catch is CancellationError {
                // A new sync or a disconnect superseded this one; leave state to them.
            } catch {
                syncStates[server.id] = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSync(forServerID serverID: String) {
        syncTasks[serverID]?.cancel()
        syncTasks[serverID] = nil
    }

    func setClientForTesting(_ client: JellyfinClient, forServerID serverID: String) {
        clients[serverID] = client
    }

    func setConnectionStateForTesting(_ state: JellyfinConnectionState, forServerID serverID: String) {
        connectionStates[serverID] = state
    }

    // MARK: - Login

    /// Exchanges username/password for an access token and user id, storing
    /// the token in Keychain immediately — called from the edit sheet before
    /// the server config itself is saved.
    static func login(baseURL: URL, username: String, password: String) async throws -> JellyfinClient.AuthResult {
        try await JellyfinClient.authenticate(baseURL: baseURL, username: username, password: password)
    }
}
