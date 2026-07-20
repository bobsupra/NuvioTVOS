import Foundation
import os

/// Central log sink. Two outputs: (1) os.Logger per category (always on, survives Release builds, filterable in Console.app);
/// (2) optional host handler for in-app overlays and aetherctl stdout. No stdio fallback; install a handler for that.
public enum EngineLog {

    /// OSLog category (raw value = category string for Console.app filters).
    public enum Category: String, Sendable, CaseIterable {
        case engine       // session start/stop, lifecycle, cross-subsystem
        case ffmpeg       // FFmpegLogBridge av_log forwarding (AV_LOG_WARNING threshold by default)
        case session      // HLSVideoEngine orchestration: segment plan, cache, muxer resets
        case muxer        // HLSSegmentProducer internals: init segment, packet writes, flush
        case demux        // Demuxer/AVIOReader: source open, seek, packet reads
        case hlsServer = "hls.server"    // HLSLocalServer: incoming GETs, playlist, segment dispatch
        case audioBridge = "audio.bridge" // AudioBridge: decode->S16PCM->FLAC, PTS rebase, lifecycle
        case swPlayback = "sw.playback"   // SoftwarePlaybackHost pipeline: SoftwareVideoDecoder, HardwareVideoDecoder, SampleBufferRenderer
        case scrub        // seek diagnostics: backward-seek detection, reset reasons, A/V watermarks
    }

    /// Optional host handler for every diagnostic line (in-app overlay, aetherctl stdout).
    /// Called on whatever thread emitted the line; must be thread-safe and non-blocking.
    /// Lock-guarded: multi-word closure swap against concurrent reads is a data race.
    public static var handler: ((String) -> Void)? {
        get { handlerLock.lock(); defer { handlerLock.unlock() }; return _handler }
        set { handlerLock.lock(); _handler = newValue; handlerLock.unlock() }
    }
    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var _handler: ((String) -> Void)?

    public static let subsystem: String = "de.superuser404.AetherEngine"

    private static let loggers: [Category: Logger] = {
        var map: [Category: Logger] = [:]
        for cat in Category.allCases {
            map[cat] = Logger(subsystem: subsystem, category: cat.rawValue)
        }
        return map
    }()

    public enum Level: Sendable {
        /// Default: OSLog default level + host handler (in-app overlay, aetherctl stdout).
        case info
        /// Per-segment/per-request trace: OSLog .debug only, NOT mirrored to host handler.
        /// Retrieve with `log stream --level debug --predicate 'subsystem == "de.superuser404.AetherEngine"'`.
        case verbose
    }

    /// Emit under `.engine`. Kept for source compatibility; prefer the typed-category overload.
    public static func emit(_ line: String) {
        emit(line, category: .engine)
    }

    /// Emit under a specific category. `.public` privacy so Console shows the full string instead of `<private>`.
    public static func emit(_ line: String, category: Category) {
        loggers[category]?.log("\(line, privacy: .public)")
        handler?(line)
    }

    public static func emit(_ line: String, category: Category, level: Level) {
        switch level {
        case .info:
            loggers[category]?.log("\(line, privacy: .public)")
            handler?(line)
        case .verbose:
            loggers[category]?.debug("\(line, privacy: .public)")
        }
    }
}
