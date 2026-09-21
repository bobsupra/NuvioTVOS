import Foundation

/// Lossless packet envelope for the software VOD read-ahead store. No decoded pixels or
/// source URL is retained. In particular DTS, duration and side data must survive a cache hit.
struct SoftwareStoredPacket: Codable, Sendable, Equatable {
    struct SideData: Codable, Sendable, Equatable {
        let type: UInt32
        let bytes: Data
    }
    let pts: Int64
    let dts: Int64
    let duration: Int64
    let position: Int64
    let streamIndex: Int32
    let flags: Int32
    let timeBaseNumerator: Int32
    let timeBaseDenominator: Int32
    let bytes: Data
    let sideData: [SideData]

    func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        try PropertyListDecoder().decode(Self.self, from: data)
    }
}
