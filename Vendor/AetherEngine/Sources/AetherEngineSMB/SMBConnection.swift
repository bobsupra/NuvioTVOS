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
    public struct SMBError: Error { public let message: String }

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
    /// e.g. `smb://host` or `smb://host:445`.
    public static func connect(
        server: URL, share: String, path: String,
        user: String, password: String, domain: String = ""
    ) async throws -> SMBConnection {
        guard let host = server.host, !host.isEmpty else {
            throw SMBError(message: "no host in \(server.absoluteString)")
        }
        let client = server.port.map { SMBClient(host: host, port: $0) }
            ?? SMBClient(host: host)

        // An empty username means "no explicit account": try guest first, then
        // fall back to a fully anonymous NTLM session if the server rejects it.
        // This mirrors the guest/anonymous behaviour of the previous backend.
        // The fallback is scoped to the no-account case (`account == nil`): when
        // an explicit username was supplied, a login failure is a real auth
        // error and must propagate rather than silently downgrading to an
        // anonymous session. Callers signal "no account" with an empty username
        // (see `SMBURL`, which leaves an omitted user empty rather than
        // substituting "guest", otherwise this fallback could never fire).
        let account = user.isEmpty ? nil : user
        let secret = password.isEmpty ? nil : password
        let realm = domain.isEmpty ? nil : domain

        // `login` negotiates and opens the NWConnection before it can throw, so
        // any failure past this point leaves a live socket. Tear it down before
        // rethrowing so failed connects don't leak a connection until dealloc.
        do {
            do {
                try await client.login(username: account ?? "guest", password: secret, domain: realm)
            } catch where account == nil {
                try await client.login(username: nil, password: nil)
            }

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
