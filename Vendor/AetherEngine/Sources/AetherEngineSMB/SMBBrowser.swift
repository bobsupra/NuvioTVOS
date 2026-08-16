import Foundation
import os
import SMBClient

/// A share advertised by `NetShareEnum`. `isAdmin` flags shares a host app's
/// picker should default to unchecked ($-suffixed shares and IPC$, which
/// carries no browsable files).
public struct SMBShareInfo: Sendable, Hashable {
    public let name: String
    public let comment: String
    public let isDiskTree: Bool
    public let isAdmin: Bool

    init(_ share: Share) {
        name = share.name
        comment = share.comment
        isDiskTree = !share.type.contains(.ipc)
            && !share.type.contains(.printQueue)
            && !share.type.contains(.device)
        isAdmin = Self.isAdminShare(name: share.name, isIPC: share.type.contains(.ipc))
    }

    /// Pulled out of `init` so the classification rule is testable without
    /// constructing a `SMBClient.Share` (its initializer isn't public).
    static func isAdminShare(name: String, isIPC: Bool) -> Bool {
        name.hasSuffix("$") || isIPC
    }
}

/// One directory entry from a `listDirectory` call. `path` is the full
/// share-relative path (including `name`), so callers can recurse without
/// re-joining path components themselves.
public struct SMBEntry: Sendable, Hashable {
    public let share: String
    public let path: String
    public let name: String
    public let size: Int64
    public let isDirectory: Bool
    public let isHidden: Bool
    public let modified: Date

    init(share: String, path: String, file: File) {
        self.share = share
        self.path = path
        name = file.name
        size = Int64(exactly: file.size) ?? Int64.max
        isDirectory = file.isDirectory
        isHidden = file.isHidden || file.isSystem
        modified = file.lastWriteTime
    }
}

/// Browses an SMB server: enumerates its shares and lists directories, for a
/// host app's server-configuration UI (connect / test / scan). Distinct from
/// `SMBConnection`, which opens exactly one known file for streaming playback;
/// this type never reads file bytes.
///
/// `@unchecked Sendable` class rather than `actor`, matching `SMBConnection`
/// in this same module: `SMBClient`/`TreeAccessor` are plain (non-Sendable)
/// classes whose async methods are not actor-isolated, so an `actor` here
/// would have the compiler flag every call as "sending" its self-isolated
/// `client` across an isolation boundary. `SMBClient`'s `Connection` already
/// serialises request/response round-trips internally, so the lock below only
/// ever guards the two stored references — it is never held across an
/// `await`.
public final class SMBBrowser: @unchecked Sendable {
    public struct BrowserError: Error, CustomStringConvertible, LocalizedError {
        public let message: String
        public var description: String { "SMB: \(message)" }
        public var errorDescription: String? { description }
    }

    private struct State {
        var client: SMBClient?
        var accessors: [String: TreeAccessor] = [:]
    }

    private let host: String
    private let port: Int?
    private let auth: SMBAuthMode
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init(host: String, port: Int? = nil, auth: SMBAuthMode) {
        self.host = host
        self.port = port
        self.auth = auth
    }

    /// Negotiates and authenticates. Idempotent: a second call while already
    /// connected is a no-op.
    public func connect() async throws {
        let alreadyConnected = state.withLockUnchecked { $0.client != nil }
        guard !alreadyConnected else { return }
        let client = port.map { SMBClient(host: host, port: $0) } ?? SMBClient(host: host)
        do {
            try await SMBAuth.login(client, mode: auth)
        } catch {
            client.session.disconnect()
            throw error
        }
        state.withLockUnchecked { $0.client = client }
    }

    /// Shares advertised by the server via `NetShareEnum`.
    public func shares() async throws -> [SMBShareInfo] {
        guard let client = state.withLockUnchecked({ $0.client }) else {
            throw BrowserError(message: "not connected")
        }
        return try await client.listShares().map(SMBShareInfo.init)
    }

    /// Lists one directory of `share`. `path` is share-relative; pass `""`
    /// for the share root. Tree-connects to `share` on first use and reuses
    /// the connection for subsequent calls to the same share.
    public func list(share: String, path: String) async throws -> [SMBEntry] {
        guard let client = state.withLockUnchecked({ $0.client }) else {
            throw BrowserError(message: "not connected")
        }
        let accessor = treeAccessor(for: share, client: client)
        let files = try await accessor.listDirectory(path: path)
        return files
            .filter { $0.name != "." && $0.name != ".." }
            .map { SMBEntry(share: share, path: path.isEmpty ? $0.name : "\(path)/\($0.name)", file: $0) }
    }

    /// Round-trips an SMB2 Echo request. Used as the "Test connection" action:
    /// distinguishes a live, responsive session from one that has silently
    /// dropped.
    public func echo() async throws {
        guard let client = state.withLockUnchecked({ $0.client }) else {
            throw BrowserError(message: "not connected")
        }
        _ = try await client.keepAlive()
    }

    /// Logs off and tears down the underlying TCP connection.
    public func disconnect() async {
        guard let client = state.withLockUnchecked({ state in
            let client = state.client
            state.client = nil
            state.accessors = [:]
            return client
        }) else { return }
        _ = try? await client.logoff()
        client.session.disconnect()
    }

    private func treeAccessor(for share: String, client: SMBClient) -> TreeAccessor {
        state.withLockUnchecked { state in
            if let existing = state.accessors[share] { return existing }
            let accessor = client.treeAccessor(share: share)
            state.accessors[share] = accessor
            return accessor
        }
    }
}
