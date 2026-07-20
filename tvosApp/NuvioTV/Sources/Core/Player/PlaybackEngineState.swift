import Foundation
import CoreGraphics

/// Backend-neutral playback phase observed by `PlayerViewModel`.
enum PlaybackEnginePhase: Equatable {
    case idle
    case loading
    case playing
    case paused
    case buffering
    case stalled
    case ended
    case error(String)

    var isTerminalFailure: Bool {
        if case .error = self { return true }
        return false
    }
}

/// Snapshot polled / published from a backend controller.
struct PlaybackEngineState {
    var phase: PlaybackEnginePhase = .idle
    /// Display / transport position (seconds).
    var currentTime: Double = 0
    /// Subtitle evaluation clock (seconds). On Aether this is `sourceTime`.
    var sourceTime: Double = 0
    var duration: Double = 0
    var bufferedPosition: Double = 0
    var speed: Float = 1
    var videoFrameSize: CGSize = .zero
    var hasCoherentTimeSample: Bool = false
    var isAtEndOfFile: Bool = false
    var audioTracks: [PlaybackTrackInfo] = []
    var subtitleTracks: [PlaybackTrackInfo] = []
    var diagnostics: String?

    var positionMs: Int64 { Int64((currentTime * 1000).rounded()) }
    var durationMs: Int64 { Int64((duration * 1000).rounded()) }
    var bufferedMs: Int64 { Int64((bufferedPosition * 1000).rounded()) }
}
