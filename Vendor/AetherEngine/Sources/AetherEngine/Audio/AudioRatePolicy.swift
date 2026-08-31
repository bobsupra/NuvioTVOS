import AVFoundation

/// Pitch handling for host-driven rate changes (#434).
///
/// Both transport surfaces pitch-correct. On the native path that is `AVPlayerItem`; on the
/// software path it is `AVSampleBufferAudioRenderer`, whose algorithm applies to the timebase
/// rate `AVSampleBufferRenderSynchronizer` is driven with. Neither said so in code: both
/// inherited `AVAudioTimePitchAlgorithmTimeDomain`, the default AVFoundation hands an app
/// linked on or after iOS 15 / macOS 12, while the `setRate` documentation asserted the
/// software path ran uncorrected. Pinning the algorithm makes the guarantee a property of the
/// engine instead of the host app's link age (the default has moved once already, and differs
/// per platform below those versions), and makes it identical across all four hosts.
///
/// TimeDomain is pitch-preserving over a variable rate from 1/32 to 32, comfortably past
/// `maxSupportedRate` (2.0 video, 3.0 audio-only); a rate the algorithm does not support is
/// muted rather than played. Spectral costs more and is aimed at music, Varispeed is the one
/// that deliberately lets pitch ride the rate.
enum AudioRatePolicy {

    static let pitchAlgorithm: AVAudioTimePitchAlgorithm = .timeDomain

    /// Apply while the timebase is stopped: AVFoundation documents a write at a non-zero rate as
    /// possibly dropping the rate to 0 for a moment.
    static func apply(to renderer: AVSampleBufferAudioRenderer) {
        renderer.audioTimePitchAlgorithm = pitchAlgorithm
    }

    static func apply(to item: AVPlayerItem) {
        item.audioTimePitchAlgorithm = pitchAlgorithm
    }
}
