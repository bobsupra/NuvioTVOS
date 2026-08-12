import Foundation
import AetherEngineSMB

/// State of a configured server's browser session, published for the
/// Settings row (Connect / Disconnect button, status dot, share list).
enum SMBConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(shares: [SMBShareInfo])
    case failed(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// State of a "Test connection" round-trip, surfaced inline on the server row.
enum SMBTestState: Equatable {
    case idle
    case testing
    case reachable(latencyMs: Int)
    case failed(String)
}

/// State of a library scan, published for the share-selection sheet's
/// progress view and result report.
enum SMBScanState: Equatable {
    case idle
    case scanning(found: Int, currentPath: String)
    case done(SMBScanReport)
    case failed(String)
}

/// Summary of a completed scan, shown in the share-selection sheet.
struct SMBScanReport: Equatable {
    var matchedTitles: Int
    var matchedEpisodes: Int
    var unmatched: [String]
    var skipped: Int
}

/// Owns the live `SMBBrowser` for each configured server and drives Connect /
/// Disconnect / Test / Scan from Settings. Also the single place that turns a
/// `SMBServerConfig` into an `AetherEngineSMB.SMBAuthMode`, so a stream
/// resolved at playback time (`AetherPlaybackController`) authenticates
/// identically to what "Connect" already verified.
@MainActor
final class SMBSessionManager: ObservableObject {
    static let shared = SMBSessionManager()

    @Published private(set) var connectionStates: [String: SMBConnectionState] = [:]
    @Published private(set) var testStates: [String: SMBTestState] = [:]
    @Published private(set) var scanStates: [String: SMBScanState] = [:]

    private var browsers: [String: SMBBrowser] = [:]
    private var scanTasks: [String: Task<Void, Never>] = [:]

    private init() {}

    func connectionState(for serverID: String) -> SMBConnectionState {
        connectionStates[serverID] ?? .disconnected
    }

    func testState(for serverID: String) -> SMBTestState {
        testStates[serverID] ?? .idle
    }

    func scanState(for serverID: String) -> SMBScanState {
        scanStates[serverID] ?? .idle
    }

    // MARK: - Connect / Disconnect

    func connect(_ server: SMBServerConfig) async {
        connectionStates[server.id] = .connecting
        let browser = SMBBrowser(host: server.host, port: server.port, auth: authMode(for: server))
        do {
            try await browser.connect()
            let shares = try await browser.shares()
            browsers[server.id] = browser
            connectionStates[server.id] = .connected(shares: shares)
        } catch {
            connectionStates[server.id] = .failed(error.localizedDescription)
        }
    }

    func disconnect(_ server: SMBServerConfig) async {
        scanTasks[server.id]?.cancel()
        scanTasks[server.id] = nil
        if let browser = browsers.removeValue(forKey: server.id) {
            await browser.disconnect()
        }
        connectionStates[server.id] = .disconnected
        testStates[server.id] = .idle
        scanStates[server.id] = .idle
    }

    /// "Test connection": only meaningful once connected — round-trips an
    /// SMB2 Echo so a silently dropped session shows as failed rather than
    /// stale "Connected" state.
    func test(_ server: SMBServerConfig) async {
        guard let browser = browsers[server.id] else { return }
        testStates[server.id] = .testing
        let started = DispatchTime.now()
        do {
            try await browser.echo()
            let elapsedMs = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
            testStates[server.id] = .reachable(latencyMs: elapsedMs)
        } catch {
            testStates[server.id] = .failed(error.localizedDescription)
        }
    }

    // MARK: - Scan

    /// Recursively walks `server.selectedShares` and indexes matched titles.
    /// Only meaningful once connected. Cancels a prior in-flight scan for the
    /// same server.
    func scan(_ server: SMBServerConfig) {
        guard let browser = browsers[server.id] else { return }
        scanTasks[server.id]?.cancel()
        scanStates[server.id] = .scanning(found: 0, currentPath: "")

        scanTasks[server.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let scanResult = try await SMBLibraryScanner.scan(
                    server: server,
                    browser: browser
                ) { found, path in
                    Task { @MainActor in
                        self.scanStates[server.id] = .scanning(found: found, currentPath: path)
                    }
                }
                try Task.checkCancellation()

                let resolution = await SMBLibraryResolver.resolve(scanResult.files, serverID: server.id)
                try Task.checkCancellation()

                SMBLibraryIndex.shared.replace(titles: resolution.titles, forServerID: server.id)

                var updatedServer = server
                updatedServer.lastScanDate = resolution.completedAt
                updatedServer.lastScanTitleCount = resolution.titles.count
                SMBServerStore.shared.upsert(updatedServer)

                scanStates[server.id] = .done(
                    SMBScanReport(
                        matchedTitles: resolution.titles.count,
                        matchedEpisodes: resolution.titles.reduce(0) { $0 + $1.files.count },
                        unmatched: resolution.unmatched,
                        skipped: scanResult.skippedCount
                    )
                )
            } catch is CancellationError {
                // A new scan or a disconnect superseded this one; leave state to them.
            } catch {
                scanStates[server.id] = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan(forServerID serverID: String) {
        scanTasks[serverID]?.cancel()
        scanTasks[serverID] = nil
    }

    // MARK: - Auth

    /// Builds the auth mode "Connect" already verified, from a saved server
    /// config's non-secret fields plus its Keychain password.
    func authMode(for server: SMBServerConfig) -> SMBAuthMode {
        switch server.authKind {
        case .anonymous:
            return .anonymous
        case .guest:
            return .guest
        case .credentials:
            return .user(
                name: server.username,
                password: SMBCredentialStore.password(forServerID: server.id),
                domain: server.domain
            )
        }
    }
}
