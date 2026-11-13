import CryptoKit
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
    case syncing(JellyfinSyncProgress)
    case done(JellyfinSyncReport)
    case failed(String)
}

struct JellyfinSyncProgress: Equatable {
    enum Stage: Equatable {
        case items
        case episodes
        case resolving
        case saving
    }

    var found: Int
    var total: Int?
    var currentLibrary: String
    var stage: Stage
}

/// Summary of a completed sync, shown in the library-selection sheet.
struct JellyfinSyncReport: Equatable {
    var matchedTitles: Int
    var matchedEpisodes: Int
    var unmatched: [String]
}

private struct JellyfinSyncCheckpoint: Codable {
    struct Identity: Codable, Equatable {
        var profileID: String
        var serverID: String
        var baseURL: String
        var userID: String
        var selectedLibraryIDs: [String]
    }

    var identity: Identity
    var runID: String
    var leaseID: String
    var pageOffsets: [String: [Int]] = [:]
    var pageCounts: [String: [Int: Int]] = [:]
    var nextStartIndices: [String: Int] = [:]
    var knownTotals: [String: Int] = [:]
    var completedEntities: Set<String> = []

    var fetchedCount: Int {
        pageCounts.values.reduce(0) { $0 + $1.values.reduce(0, +) }
    }
}

/// Writes each page separately and then advances a small manifest. If the
/// process stops between those writes, the same offset is fetched again and
/// safely overwrites its unreferenced page file.
private final class JellyfinSyncCheckpointStore: @unchecked Sendable {
    struct PageProgress {
        var found: Int
        var total: Int?
    }

    enum StoreError: LocalizedError {
        case persistenceFailed
        case missingPage
        case staleSync

        var errorDescription: String? {
            switch self {
            case .persistenceFailed: return "The Jellyfin sync checkpoint could not be saved."
            case .missingPage: return "A saved Jellyfin sync page could not be read."
            case .staleSync: return "This Jellyfin sync was superseded."
            }
        }
    }

    private static let directory = "jellyfinSyncCheckpoints"
    private static let lock = NSRecursiveLock()
    private let key: String
    private var checkpoint: JellyfinSyncCheckpoint

    init(identity: JellyfinSyncCheckpoint.Identity) throws {
        key = Self.checkpointKey(profileID: identity.profileID, serverID: identity.serverID)
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let data = LargePayloadStore.read(key: key, directory: Self.directory),
           let saved = try? JSONDecoder().decode(JellyfinSyncCheckpoint.self, from: data),
           saved.identity == identity {
            checkpoint = saved
            checkpoint.leaseID = UUID().uuidString
            try persist(checkpoint)
            return
        }

        if let data = LargePayloadStore.read(key: key, directory: Self.directory),
           let previous = try? JSONDecoder().decode(JellyfinSyncCheckpoint.self, from: data) {
            Self.removePages(previous, key: key)
        }
        checkpoint = JellyfinSyncCheckpoint(identity: identity, runID: UUID().uuidString, leaseID: UUID().uuidString)
        try persist(checkpoint)
    }

    func nextStartIndex(for entity: String) -> Int {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return checkpoint.nextStartIndices[entity] ?? 0
    }

    func isComplete(_ entity: String) -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return checkpoint.completedEntities.contains(entity)
    }

    func fetchedCount() -> Int {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return checkpoint.fetchedCount
    }

    func record(_ page: JellyfinItemsPage, for entity: String) throws -> PageProgress {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try ensureCurrentLease()

        let pageKey = Self.pageKey(key: key, runID: checkpoint.runID, entity: entity, startIndex: page.startIndex)
        let pageData = try JSONEncoder().encode(page.items)
        guard LargePayloadStore.write(pageData, key: pageKey, directory: Self.directory) else {
            throw StoreError.persistenceFailed
        }

        var updated = checkpoint
        var offsets = updated.pageOffsets[entity] ?? []
        var counts = updated.pageCounts[entity] ?? [:]
        if !offsets.contains(page.startIndex) {
            offsets.append(page.startIndex)
            counts[page.startIndex] = page.items.count
        }
        updated.pageOffsets[entity] = offsets.sorted()
        updated.pageCounts[entity] = counts
        updated.nextStartIndices[entity] = page.nextStartIndex
        if let total = page.totalRecordCount {
            updated.knownTotals[entity] = total
        }
        try persist(updated)
        checkpoint = updated

        let entityCount = counts.values.reduce(0, +)
        let otherCount = updated.fetchedCount - entityCount
        return PageProgress(
            found: updated.fetchedCount,
            total: updated.knownTotals[entity].map { otherCount + $0 }
        )
    }

    func markComplete(_ entity: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try ensureCurrentLease()
        var updated = checkpoint
        updated.completedEntities.insert(entity)
        try persist(updated)
        checkpoint = updated
    }

    func reset(_ entity: String) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try ensureCurrentLease()
        let offsets = checkpoint.pageOffsets[entity] ?? []
        var updated = checkpoint
        updated.pageOffsets.removeValue(forKey: entity)
        updated.pageCounts.removeValue(forKey: entity)
        updated.nextStartIndices.removeValue(forKey: entity)
        updated.knownTotals.removeValue(forKey: entity)
        updated.completedEntities.remove(entity)
        try persist(updated)
        checkpoint = updated
        for startIndex in offsets {
            LargePayloadStore.remove(
                key: Self.pageKey(key: key, runID: checkpoint.runID, entity: entity, startIndex: startIndex),
                directory: Self.directory
            )
        }
    }

    func items(for entity: String) throws -> [JellyfinMediaItem] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try ensureCurrentLease()
        let offsets = (checkpoint.pageOffsets[entity] ?? []).sorted()
        let runID = checkpoint.runID
        let decoded: [JellyfinMediaItem] = try offsets.flatMap { startIndex in
            let pageKey = Self.pageKey(key: key, runID: runID, entity: entity, startIndex: startIndex)
            guard let data = LargePayloadStore.read(key: pageKey, directory: Self.directory) else {
                throw StoreError.missingPage
            }
            do {
                return try JSONDecoder().decode([JellyfinMediaItem].self, from: data)
            } catch {
                throw StoreError.missingPage
            }
        }
        var seenIDs = Set<String>()
        return decoded.filter { seenIDs.insert($0.id).inserted }
    }

    func remove() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        guard (try? ensureCurrentLease()) != nil else { return }
        Self.removePages(checkpoint, key: key)
        LargePayloadStore.remove(key: key, directory: Self.directory)
    }

    private func persist(_ value: JellyfinSyncCheckpoint) throws {
        let data = try JSONEncoder().encode(value)
        guard LargePayloadStore.write(data, key: key, directory: Self.directory) else {
            throw StoreError.persistenceFailed
        }
    }

    private func ensureCurrentLease() throws {
        guard let data = LargePayloadStore.read(key: key, directory: Self.directory),
              let current = try? JSONDecoder().decode(JellyfinSyncCheckpoint.self, from: data),
              current.identity == checkpoint.identity,
              current.runID == checkpoint.runID,
              current.leaseID == checkpoint.leaseID else {
            throw StoreError.staleSync
        }
    }

    /// Drops a server's checkpoint and its pages for one profile, whatever run left them.
    /// The pages hold the server's library listing, so they must not outlive the server.
    static func remove(profileID: String, serverID: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = checkpointKey(profileID: profileID, serverID: serverID)
        if let data = LargePayloadStore.read(key: key, directory: directory),
           let saved = try? JSONDecoder().decode(JellyfinSyncCheckpoint.self, from: data) {
            removePages(saved, key: key)
        }
        LargePayloadStore.remove(key: key, directory: directory)
    }

    /// Sign-out: every profile's checkpoints and pages.
    static func eraseAll() {
        lock.lock()
        defer { lock.unlock() }
        LargePayloadStore.removeDirectory(directory)
    }

    private static func checkpointKey(profileID: String, serverID: String) -> String {
        "jellyfinSyncCheckpoint.v1.\(shortHash("\(profileID)|\(serverID)"))"
    }

    private static func pageKey(key: String, runID: String, entity: String, startIndex: Int) -> String {
        "jellyfinSyncPage.\(shortHash("\(key)|\(runID)|\(entity)|\(startIndex)"))"
    }

    private static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func removePages(_ checkpoint: JellyfinSyncCheckpoint, key: String) {
        for (entity, offsets) in checkpoint.pageOffsets {
            for startIndex in offsets {
                LargePayloadStore.remove(
                    key: pageKey(key: key, runID: checkpoint.runID, entity: entity, startIndex: startIndex),
                    directory: directory
                )
            }
        }
    }
}

/// Removal of interrupted Jellyfin sync checkpoints (a finished sync removes its own).
enum JellyfinSyncCheckpoints {
    static func remove(profileID: String, serverID: String) {
        JellyfinSyncCheckpointStore.remove(profileID: profileID, serverID: serverID)
    }

    static func eraseAll() {
        JellyfinSyncCheckpointStore.eraseAll()
    }
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
    private var syncGenerations: [String: Int] = [:]
    private var syncProfileIDs: [String: String] = [:]
    private var connectionProfileIDs: [String: String] = [:]

    private init() {}

    func connectionState(for serverID: String) -> JellyfinConnectionState {
        connectionStates[serverID] ?? .disconnected
    }

    func syncState(for serverID: String) -> JellyfinSyncState {
        if let syncProfileID = syncProfileIDs[serverID], syncProfileID != (ProfileSettings.activeProfileID ?? "default") {
            return .idle
        }
        return syncStates[serverID] ?? .idle
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
                let activeProfileID = ProfileSettings.activeProfileID ?? "default"
                if connectionProfileIDs[server.id] != activeProfileID {
                    clients[server.id] = nil
                    connectionStates[server.id] = .disconnected
                }
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
        cancelSync(forServerID: server.id)
        let profileID = ProfileSettings.activeProfileID ?? "default"
        let generation = (connectionGenerations[server.id] ?? 0) &+ 1
        connectionGenerations[server.id] = generation
        clients[server.id] = nil
        connectionProfileIDs[server.id] = profileID
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
                      (ProfileSettings.activeProfileID ?? "default") == profileID,
                      !Task.isCancelled else { return }
                var updated = server
                updated.userId = resolvedUserId
                JellyfinServerStore.shared.upsert(updated)
            }
            let client = JellyfinClient(baseURL: baseURL, accessToken: token)
            try await client.ping()
            guard connectionGenerations[server.id] == generation,
                  (ProfileSettings.activeProfileID ?? "default") == profileID,
                  !Task.isCancelled else { return }
            let libraries = try await client.libraries(userId: resolvedUserId)
            guard connectionGenerations[server.id] == generation,
                  (ProfileSettings.activeProfileID ?? "default") == profileID,
                  !Task.isCancelled else { return }
            clients[server.id] = client
            connectionProfileIDs[server.id] = profileID
            connectionStates[server.id] = .connected(libraries: libraries)
        } catch {
            if connectionGenerations[server.id] == generation,
               (ProfileSettings.activeProfileID ?? "default") == profileID,
               !Task.isCancelled {
                connectionStates[server.id] = .failed(error.localizedDescription)
            }
        }
    }

    func disconnect(_ server: JellyfinServerConfig) async {
        connectionGenerations[server.id] = (connectionGenerations[server.id] ?? 0) &+ 1
        cancelSync(forServerID: server.id)
        clients[server.id] = nil
        connectionProfileIDs[server.id] = nil
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
        let profileID = ProfileSettings.activeProfileID ?? "default"
        guard connectionProfileIDs[server.id] == profileID else {
            connectionStates[server.id] = .disconnected
            return
        }
        guard let client = clients[server.id] else { return }
        syncTasks[server.id]?.cancel()
        let generation = (syncGenerations[server.id] ?? 0) &+ 1
        syncGenerations[server.id] = generation
        syncProfileIDs[server.id] = profileID
        syncStates[server.id] = .syncing(JellyfinSyncProgress(found: 0, total: nil, currentLibrary: "", stage: .items))

        syncTasks[server.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let selectedIDs = Set(server.selectedLibraryIDs)
                let identity = JellyfinSyncCheckpoint.Identity(
                    profileID: profileID,
                    serverID: server.id,
                    baseURL: server.baseURLString,
                    userID: server.userId,
                    selectedLibraryIDs: selectedIDs.sorted()
                )
                let checkpoint = try JellyfinSyncCheckpointStore(identity: identity)
                try Task.checkCancellation()
                guard self.isCurrentSync(server, generation: generation, profileID: profileID) else { return }
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
                for library in selectedLibraries {
                    try Task.checkCancellation()
                    guard self.isCurrentSync(server, generation: generation, profileID: profileID) else { return }
                    let itemEntity = "items:\(library.id)"
                    self.publishSyncProgress(
                        serverID: server.id,
                        server: server,
                        generation: generation,
                        profileID: profileID,
                        progress: JellyfinSyncProgress(found: checkpoint.fetchedCount(), total: nil, currentLibrary: library.name, stage: .items)
                    )
                    var libraryItems: [JellyfinMediaItem]?
                    var savedItemIDs = Set<String>()
                    do {
                        let savedItems = try await Task.detached(priority: .utility) {
                            try checkpoint.items(for: itemEntity)
                        }.value
                        savedItemIDs = Set(savedItems.map(\.id))
                        if checkpoint.isComplete(itemEntity) {
                            libraryItems = savedItems
                        }
                    } catch JellyfinSyncCheckpointStore.StoreError.missingPage {
                        try checkpoint.reset(itemEntity)
                        savedItemIDs.removeAll()
                    }
                    if libraryItems == nil {
                        _ = try await client.items(
                            userId: server.userId,
                            libraryId: library.id,
                            startingAt: checkpoint.nextStartIndex(for: itemEntity),
                            seenItemIDs: savedItemIDs
                        ) { [weak self] page in
                            try Task.checkCancellation()
                            let progress = try checkpoint.record(page, for: itemEntity)
                            Task { @MainActor [weak self] in
                                self?.publishSyncProgress(
                                    serverID: server.id,
                                    server: server,
                                    generation: generation,
                                    profileID: profileID,
                                    progress: JellyfinSyncProgress(found: progress.found, total: progress.total, currentLibrary: library.name, stage: .items)
                                )
                            }
                        }
                        try Task.checkCancellation()
                        guard self.isCurrentSync(server, generation: generation, profileID: profileID) else { return }
                        try checkpoint.markComplete(itemEntity)
                        libraryItems = try await Task.detached(priority: .utility) {
                            try checkpoint.items(for: itemEntity)
                        }.value
                    }
                    guard var libraryItems else { throw JellyfinSyncCheckpointStore.StoreError.missingPage }

                    // On Silo or servers where recursive library items omit episodes, fetch episodes separately per series
                    let existingEpisodeSeriesIds = Set(libraryItems.compactMap { $0.type == "Episode" ? $0.seriesId : nil })
                    let seriesNeedingEpisodes = libraryItems.filter { $0.type == "Series" && !existingEpisodeSeriesIds.contains($0.id) }

                    if !seriesNeedingEpisodes.isEmpty {
                        self.publishSyncProgress(
                            serverID: server.id,
                            server: server,
                            generation: generation,
                            profileID: profileID,
                            progress: JellyfinSyncProgress(found: checkpoint.fetchedCount(), total: nil, currentLibrary: library.name, stage: .episodes)
                        )
                        var savedEpisodeIDsBySeries: [String: Set<String>] = [:]
                        for series in seriesNeedingEpisodes {
                            do {
                                let savedEpisodes = try await Task.detached(priority: .utility) {
                                    try checkpoint.items(for: "episodes:\(series.id)")
                                }.value
                                savedEpisodeIDsBySeries[series.id] = Set(savedEpisodes.map(\.id))
                            } catch JellyfinSyncCheckpointStore.StoreError.missingPage {
                                try checkpoint.reset("episodes:\(series.id)")
                            }
                        }
                        let pendingSeries = seriesNeedingEpisodes.filter { !checkpoint.isComplete("episodes:\($0.id)") }
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            var nextSeriesIndex = 0
                            let concurrencyLimit = min(4, pendingSeries.count)
                            for _ in 0..<concurrencyLimit {
                                let series = pendingSeries[nextSeriesIndex]
                                nextSeriesIndex += 1
                                group.addTask { [weak self] in
                                    try await Self.fetchEpisodes(
                                        for: series,
                                        client: client,
                                        userID: server.userId,
                                        checkpoint: checkpoint,
                                        seenItemIDs: savedEpisodeIDsBySeries[series.id] ?? [],
                                        onProgress: { progress in
                                            Task { @MainActor [weak self] in
                                                self?.publishSyncProgress(
                                                    serverID: server.id,
                                                    server: server,
                                                    generation: generation,
                                                    profileID: profileID,
                                                    progress: JellyfinSyncProgress(found: progress.found, total: nil, currentLibrary: library.name, stage: .episodes)
                                                )
                                            }
                                        }
                                    )
                                }
                            }
                            while try await group.next() != nil {
                                if nextSeriesIndex < pendingSeries.count {
                                    let series = pendingSeries[nextSeriesIndex]
                                    nextSeriesIndex += 1
                                    group.addTask { [weak self] in
                                        try await Self.fetchEpisodes(
                                            for: series,
                                            client: client,
                                            userID: server.userId,
                                            checkpoint: checkpoint,
                                            seenItemIDs: savedEpisodeIDsBySeries[series.id] ?? [],
                                            onProgress: { progress in
                                                Task { @MainActor [weak self] in
                                                    self?.publishSyncProgress(
                                                        serverID: server.id,
                                                        server: server,
                                                        generation: generation,
                                                        profileID: profileID,
                                                        progress: JellyfinSyncProgress(found: progress.found, total: nil, currentLibrary: library.name, stage: .episodes)
                                                    )
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                        }
                        for series in seriesNeedingEpisodes {
                            let episodeItems = try await Task.detached(priority: .utility) {
                                try checkpoint.items(for: "episodes:\(series.id)")
                            }.value
                            libraryItems.append(contentsOf: episodeItems)
                        }
                    }

                    try checkpoint.markComplete("library:\(library.id)")

                    self.publishSyncProgress(
                        serverID: server.id,
                        server: server,
                        generation: generation,
                        profileID: profileID,
                        progress: JellyfinSyncProgress(found: checkpoint.fetchedCount(), total: nil, currentLibrary: library.name, stage: .resolving)
                    )
                    let resolution = JellyfinLibraryResolver.resolve(
                        libraryItems,
                        serverID: server.id,
                        libraryID: library.id,
                        libraryName: library.name
                    )
                    indexedTitles.append(contentsOf: resolution.titles)
                    unmatched.append(contentsOf: resolution.unmatched)
                }
                try Task.checkCancellation()
                guard self.isCurrentSync(server, generation: generation, profileID: profileID) else { return }

                let resolution = JellyfinLibraryResolution(
                    titles: indexedTitles,
                    unmatched: unmatched,
                    completedAt: Date()
                )

                self.syncStates[server.id] = .syncing(
                    JellyfinSyncProgress(found: checkpoint.fetchedCount(), total: nil, currentLibrary: "", stage: .saving)
                )
                try JellyfinLibraryIndex.shared.replace(titles: resolution.titles, forServerID: server.id)

                var updatedServer = JellyfinServerStore.shared.server(id: server.id) ?? server
                updatedServer.lastSyncDate = resolution.completedAt
                updatedServer.lastSyncTitleCount = resolution.titles.count
                JellyfinServerStore.shared.upsert(updatedServer)

                syncStates[server.id] = .done(
                    JellyfinSyncReport(
                        matchedTitles: resolution.titles.count,
                        matchedEpisodes: resolution.titles.filter { $0.type == "series" }.reduce(0) { $0 + $1.items.count },
                        unmatched: resolution.unmatched
                    )
                )
                checkpoint.remove()
            } catch is CancellationError {
                // A new sync or a disconnect superseded this one; leave state to them.
            } catch {
                if self.isCurrentSync(server, generation: generation, profileID: profileID) {
                    syncStates[server.id] = .failed(error.localizedDescription)
                }
            }
        }
    }

    func cancelSync(forServerID serverID: String) {
        syncGenerations[serverID] = (syncGenerations[serverID] ?? 0) &+ 1
        syncTasks[serverID]?.cancel()
        syncTasks[serverID] = nil
        syncProfileIDs.removeValue(forKey: serverID)
        if case .syncing = syncStates[serverID] {
            syncStates[serverID] = .idle
        }
    }

    private func isCurrentSync(_ server: JellyfinServerConfig, generation: Int, profileID: String) -> Bool {
        guard syncGenerations[server.id] == generation else { return false }
        guard (ProfileSettings.activeProfileID ?? "default") == profileID else { return false }
        guard let current = JellyfinServerStore.shared.server(id: server.id),
              current.baseURLString == server.baseURLString,
              current.userId == server.userId,
              Set(current.selectedLibraryIDs) == Set(server.selectedLibraryIDs) else {
            syncStates[server.id] = .idle
            return false
        }
        return true
    }

    private func publishSyncProgress(
        serverID: String,
        server: JellyfinServerConfig,
        generation: Int,
        profileID: String,
        progress: JellyfinSyncProgress
    ) {
        guard isCurrentSync(server, generation: generation, profileID: profileID) else { return }
        if case .syncing = syncStates[serverID] {
            syncStates[serverID] = .syncing(progress)
        }
    }

    private nonisolated static func fetchEpisodes(
        for series: JellyfinMediaItem,
        client: JellyfinClient,
        userID: String,
        checkpoint: JellyfinSyncCheckpointStore,
        seenItemIDs: Set<String>,
        onProgress: @escaping (JellyfinSyncCheckpointStore.PageProgress) -> Void
    ) async throws {
        let entity = "episodes:\(series.id)"
        _ = try await client.episodes(
            seriesId: series.id,
            userId: userID,
            startingAt: checkpoint.nextStartIndex(for: entity),
            seenItemIDs: seenItemIDs
        ) { page in
            try Task.checkCancellation()
            let progress = try checkpoint.record(page, for: entity)
            onProgress(progress)
        }
        try Task.checkCancellation()
        try checkpoint.markComplete(entity)
    }

    func setClientForTesting(_ client: JellyfinClient, forServerID serverID: String) {
        clients[serverID] = client
        connectionProfileIDs[serverID] = ProfileSettings.activeProfileID ?? "default"
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
