import Foundation

/// A random-access, read-only byte source addressed by absolute offset.
/// Isolates the network backend from the cursor/seek logic in `SMBIOReader`,
/// so the reader is testable without a live server.
public protocol ByteRangeSource: AnyObject, Sendable {
    /// Total size of the underlying object in bytes.
    var byteSize: Int64 { get }

    /// Read up to `length` bytes starting at absolute `offset`. May return
    /// fewer bytes than requested at end of file, and an empty `Data` at or
    /// past EOF. Throws on a genuine I/O error.
    func read(at offset: Int64, length: Int) async throws -> Data

    /// Release the underlying resource. Must be idempotent.
    func close()
}
