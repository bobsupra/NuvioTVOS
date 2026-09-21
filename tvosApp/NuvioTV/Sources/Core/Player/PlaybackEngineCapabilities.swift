import Foundation

/// Feature surface advertised by a backend so the coordinator can force MPV when needed.
struct PlaybackEngineCapabilities: Equatable {
    var supportsSeparateAudioURL: Bool
    var supportsAudioDelay: Bool
    var supportsAudioAmplification: Bool
    var supportsAuthoredASS: Bool
    var supportsHostSubtitleOverlay: Bool
    var supportsHTTPHeaders: Bool
    var supportsDirectHTTPS: Bool

    static let aether = PlaybackEngineCapabilities(
        supportsSeparateAudioURL: false,
        supportsAudioDelay: true,
        supportsAudioAmplification: false,
        supportsAuthoredASS: false,
        supportsHostSubtitleOverlay: true,
        supportsHTTPHeaders: true,
        supportsDirectHTTPS: true
    )

    static let mpv = PlaybackEngineCapabilities(
        supportsSeparateAudioURL: true,
        supportsAudioDelay: true,
        supportsAudioAmplification: true,
        supportsAuthoredASS: true,
        supportsHostSubtitleOverlay: false,
        supportsHTTPHeaders: true,
        // MPVKit ships FFmpeg with network protocols and TLS enabled. The
        // old false value forced every remote session back to AetherEngine,
        // which made the ASS-capable player impossible to select.
        supportsDirectHTTPS: true
    )
}
