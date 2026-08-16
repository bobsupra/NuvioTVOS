import Foundation
import SMBClient

/// A read-only SMB2/3 byte source over one share + file path.
///
/// The transport is [kishikawakatsumi/SMBClient](https://github.com/kishikawakatsumi/SMBClient):
/// a pure-Swift SMB2 client that speaks the wire protocol over `NWConnection`
/// (Network.framework). This replaces the previous AMSMB2/libsmb2 backend, which
/// failed with POSIX `EPERM` ("Operation not permitted") on the very first
/// `connectShare` on tvOS (and iOS), a known, long-standing libsmb2 issue on
/// those platforms (AMSMB2 #32/#63/#64). A raw `NWConnection` to port 445
/// completes a full SMB2 handshake on the same device, so an `NWConnection`-based
/// client works where libsmb2 does not. The public surface here is unchanged, so
/// `SMBIOReader`, `SMBURL`, and existing callers are untouched.
///
/// Concurrency: reads are driven one at a time on the engine's demux thread via
/// `SMBIOReader`'s semaphore, and `SMBClient`'s `Connection` serialises each
/// request/response round-trip internally, so `@unchecked Sendable` is safe for
/// this access pattern (as it was for the AMSMB2 backend).
public final class SMBConnection: ByteRangeSource, @unchecked Sendable {
    public struct SMBError: Error, CustomStringConvertible, LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var description: String { "SMB: \(message)" }
        public var errorDescription: String? { description }
    }

    private let client: SMBClient
    private let reader: FileReader
    public let byteSize: Int64

    private init(client: SMBClient, reader: FileReader, byteSize: Int64) {
        self.client = client
        self.reader = reader
        self.byteSize = byteSize
    }

    /// Connect, authenticate (NTLMv2 / guest / anonymous), tree-connect to
    /// `share`, open `path` read-only, and stat it for its size. `server` is
    /// e.g. `smb://host` or `smb://host:445`. An empty `user` means "no
    /// explicit account" and drives a guest-then-anonymous fallback — see
    /// `SMBAuth.loginCredentialLess`. Prefer `connect(server:share:path:auth:)`
    /// when the caller already has an explicit `SMBAuthMode` (e.g. from a host
    /// app's saved server config): it authenticates exactly as chosen, with no
    /// implicit fallback.
    public static func connect(
        server: URL, share: String, path: String,
        user: String, password: String, domain: String = ""
    ) async throws -> SMBConnection {
        try await connect(server: server, share: share, path: path) { client in
            try await SMBAuth.loginCredentialLess(client, user: user, password: password, domain: domain)
        }
    }

    /// Connect using an explicit `SMBAuthMode` — the same authentication
    /// `SMBBrowser` performs for a Settings server row, so a stream configured
    /// there plays back with identical auth behavior (no implicit fallback for
    /// `.anonymous`/`.guest`; a rejected login surfaces as a real error).
    public static func connect(
        server: URL, share: String, path: String, auth: SMBAuthMode
    ) async throws -> SMBConnection {
        try await connect(server: server, share: share, path: path) { client in
            try await SMBAuth.login(client, mode: auth)
        }
    }

    private static func connect(
        server: URL, share: String, path: String,
        login: (SMBClient) async throws -> Void
    ) async throws -> SMBConnection {
        guard let host = server.host, !host.isEmpty else {
            throw SMBError(message: "no host in \(server.absoluteString)")
        }
        let client = server.port.map { SMBClient(host: host, port: $0) }
            ?? SMBClient(host: host)

        // `login` negotiates and opens the NWConnection before it can throw, so
        // any failure past this point leaves a live socket. Tear it down before
        // rethrowing so failed connects don't leak a connection until dealloc.
        do {
            try await login(client)

            try await client.connectShare(share)

            let reader = client.fileReader(path: path)
            let size = try await reader.fileSize
            guard size > 0 else {
                throw SMBError(message: "SMB file has zero size or could not be stat'd: \(path)")
            }
            return SMBConnection(client: client, reader: reader, byteSize: Int64(size))
        } catch {
            client.session.disconnect()
            throw error
        }
    }

    public func read(at offset: Int64, length: Int) async throws -> Data {
        guard length > 0, offset >= 0, offset < byteSize else { return Data() }
        let upper = min(offset &+ Int64(length), byteSize)
        let want = UInt32(truncatingIfNeeded: upper - offset)
        return try await reader.read(offset: UInt64(offset), length: want)
    }

    public func close() {
        // Fire-and-forget teardown; SMBClient's close/logoff are async.
        let reader = self.reader
        let client = self.client
        Task {
            try? await reader.close()
            _ = try? await client.logoff()
            // logoff() only ends the SMB session; tear down the underlying TCP
            // connection too so the socket doesn't linger until dealloc.
            client.session.disconnect()
        }
    }
}
