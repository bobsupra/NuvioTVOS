import Foundation

/// Terminal errors from the live HLS ingest. Every case causes a host fallback to the Jellyfin-mediated path. Phase-1 limits (encryption, fMP4) fall back deliberately rather than half-work.
public enum HLSIngestError: Error, Equatable, CustomStringConvertible {
    case playlistUnreachable(status: Int)
    case playlistInvalid(reason: String)
    /// SAMPLE-AES / SAMPLE-AES-CTR, or AES-128 tag with no URI. Plain AES-128 clear-key is handled by `HLSSegmentDecryptor`.
    case encryptedNotSupported
    /// AES-128 key fetch failed or CommonCrypto rejected key/IV/ciphertext. Falls back rather than feeding ciphertext to the demuxer.
    case segmentDecryptFailed(reason: String)
    /// EXT-X-MAP present, or first segment is not TS (main) or TS/packed-audio (companion). fMP4-segment HLS is a later phase.
    case unsupportedSegmentFormat
    case ingestStalled
    /// Demuxed-audio rendition in a shape the ingest cannot handle: unresolvable URI, packed audio without a parsable PRIV timestamp (ARD-style, device repro: Das Erste HD), or no program-clock anchor to align audio without risking silent A/V desync.
    case demuxedAudioNotSupported

    public var description: String {
        switch self {
        case .playlistUnreachable(let status): "playlistUnreachable(\(status))"
        case .playlistInvalid(let reason): "playlistInvalid(\(reason))"
        case .encryptedNotSupported: "encryptedNotSupported"
        case .segmentDecryptFailed(let reason): "segmentDecryptFailed(\(reason))"
        case .unsupportedSegmentFormat: "unsupportedSegmentFormat"
        case .ingestStalled: "ingestStalled"
        case .demuxedAudioNotSupported: "demuxedAudioNotSupported"
        }
    }
}
