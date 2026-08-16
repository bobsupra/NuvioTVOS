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

    @Published private(set) var connectionStates: [String: JellyfinConnectionState] = [:]
    @Published private(set) var syncStates: [String: JellyfinSyncState] = [:]

    private var clients: [String: JellyfinClient] = [:]
    private var syncTasks: [String: Task<Void, Never>] = [:]

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
    /// `SMBSessionManager.connectAll()`.
    func connectAll() async {
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
    }

    func connect(_ server: JellyfinServerConfig) async {
        guard let baseURL = server.baseURL else {
            connectionStates[server.id] = .failed(L10n.string("jellyfin_invalid_url", fallback: "Invalid server URL"))
            return
        }
        connectionStates[server.id] = .connecting
        do {
            let token = JellyfinCredentialStore.token(forServerID: server.id)
            var resolvedUserId = server.userId
            if resolvedUserId.isEmpty {
                resolvedUserId = try await JellyfinClient.currentUserId(baseURL: baseURL, apiKey: token)
                var updated = server
                updated.userId = resolvedUserId
                JellyfinServerStore.shared.upsert(updated)
            }
            let client = JellyfinClient(baseURL: baseURL, accessToken: token)
            try await client.ping()
            let libraries = try await client.libraries(userId: resolvedUserId)
            clients[server.id] = client
            connectionStates[server.id] = .connected(libraries: libraries)
        } catch {
            connectionStates[server.id] = .failed(error.localizedDescription)
        }
    }

    func disconnect(_ server: JellyfinServerConfig) async {
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
        guard let client = clients[server.id] else { return }
        syncTasks[server.id]?.cancel()
        syncStates[server.id] = .syncing(found: 0, currentLibrary: "")

        syncTasks[server.id] = Task { [weak self] in
            guard let self else { return }
            do {
                var allItems: [JellyfinMediaItem] = []
                for library in server.selectedLibraryIDs {
                    try Task.checkCancellation()
                    await MainActor.run { self.syncStates[server.id] = .syncing(found: allItems.count, currentLibrary: library) }
                    let items = try await client.items(userId: server.userId, libraryId: library)
                    allItems.append(contentsOf: items)
                }
                try Task.checkCancellation()

                let resolution = JellyfinLibraryResolver.resolve(allItems, serverID: server.id)
                try Task.checkCancellation()

                JellyfinLibraryIndex.shared.replace(titles: resolution.titles, forServerID: server.id)

                var updatedServer = server
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

    // MARK: - Login

    /// Exchanges username/password for an access token and user id, storing
    /// the token in Keychain immediately — called from the edit sheet before
    /// the server config itself is saved.
    static func login(baseURL: URL, username: String, password: String) async throws -> JellyfinClient.AuthResult {
        try await JellyfinClient.authenticate(baseURL: baseURL, username: username, password: password)
    }
}
