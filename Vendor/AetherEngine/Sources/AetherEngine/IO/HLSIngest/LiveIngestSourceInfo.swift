import Foundation

/// A SUBTITLES rendition of the picked variant, resolved to an absolute playlist URL (AE#359).
/// Metadata only: nothing is fetched until the host selects the track, so a channel nobody watches
/// with subtitles costs no second HTTP loop.
struct LiveSubtitleRenditionInfo: Equatable, Sendable {
    let name: String
    let language: String?
    let isDefault: Bool
    let isForced: Bool
    let playlistURL: URL
}

/// Implemented by live readers to expose upstream cadence and companion audio; the engine uses these to shape the local playlist and side-demuxer.
protocol LiveIngestSourceInfo: AnyObject, Sendable {
    /// EXT-X-TARGETDURATION in seconds, nil until the resolver has fetched the first media playlist. This
    /// is the upstream's *self-declared* value: a valid lower bound on segment duration, but NOT evidence
    /// of real delivery cadence. Use `observedLiveCadenceSeconds` for blocking-reload / TARGETDURATION
    /// shaping (AetherEngine#167).
    var upstreamTargetDuration: Double? { get }

    /// OBSERVED upstream segment-arrival cadence in seconds (recent max inter-arrival interval, widened by
    /// the currently-open gap), nil until the first arrival. Unlike `upstreamTargetDuration` this reflects
    /// how the origin actually delivers, so the engine can detect bursty relays that advertise a normal
    /// TARGETDURATION but push segments in irregular batches (AetherEngine#167).
    var observedLiveCadenceSeconds: Double? { get }

    /// Companion reader for a demuxed audio rendition (ARD-style: video-only variant + separate EXT-X-MEDIA:TYPE=AUDIO,URI=... playlist). nil means muxed audio. Installed before the first main-stream FIFO byte so any consumer that has received main bytes can trust nil to mean muxed. The companion is lazy (starts on its first read()) and closed by the main reader's close().
    var companionAudioReader: IOReader? { get }

    /// SUBTITLES renditions the picked variant declares, empty when the master offers none or the
    /// source is a direct media playlist (AE#359). Set by the resolver before any main-stream byte
    /// flows, like `companionAudioReader`, so it is final once the load reads it.
    var subtitleRenditions: [LiveSubtitleRenditionInfo] { get }

    /// EXT-X-PROGRAM-DATE-TIME of the segment this reader joined at, nil when the upstream carries no
    /// PDT. Together with the engine's clock at session start this is the wall-to-player mapping a
    /// sibling rendition needs (AE#359).
    var joinWallClock: Date? { get }

    /// FFmpeg demuxer name for THIS reader ("mpegts" or "aac"). Blocks, bounded, until the first segment is classified. Classification happens before any FIFO byte; resolving consumes no stream data. Returns nil when the ingest went terminal or timed out.
    func resolveSegmentFormatHint() -> String?

    /// Apple ID3v2 PRIV "com.apple.streaming.transportStreamTimestamp" of the first segment: 33-bit 90 kHz program-clock anchor for synthesized side-audio timestamps. nil for TS streams. Guaranteed non-nil when `resolveSegmentFormatHint()` returned "aac" (packed audio without a parsable PRIV goes terminal with `demuxedAudioNotSupported`).
    var packedAudioTimestampOffset90k: Int64? { get }
}
