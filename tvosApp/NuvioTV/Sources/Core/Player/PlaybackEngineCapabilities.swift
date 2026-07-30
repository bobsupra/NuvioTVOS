import Foundation

/// Feature surface advertised by a backend so the coordinator can force MPV when needed.
struct PlaybackEngineCapabilities: Equatable {
    var supportsSeparateAudioURL: Bool
    var supportsAudioDelay: Bool
    var supportsAudioAmplification: Bool
    var supportsAuthoredASS: Bool
    var supportsHostSubtitleOverlay: Bool
    var supportsHTTPHeaders: Bool

    static let aether = PlaybackEngineCapabilities(
        supportsSeparateAudioURL: false,
        supportsAudioDelay: false,
        supportsAudioAmplification: false,
        supportsAuthoredASS: false,
        supportsHostSubtitleOverlay: true,
        supportsHTTPHeaders: true
    )

    static let mpv = PlaybackEngineCapabilities(
        supportsSeparateAudioURL: true,
        supportsAudioDelay: true,
        supportsAudioAmplification: true,
        supportsAuthoredASS: true,
        supportsHostSubtitleOverlay: false,
        supportsHTTPHeaders: true
    )

}
