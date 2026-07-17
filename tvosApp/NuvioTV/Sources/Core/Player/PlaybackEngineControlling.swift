import Foundation
import CoreGraphics

/// Shared surface that `PlayerViewModel` polls and drives, implemented by both
/// the libmpv host and the AVPlayer host so Auto can switch backends.
@MainActor
protocol PlaybackEngineControlling: AnyObject {
    var onPlaybackSuspended: ((Int64, Int64) -> Void)? { get set }

    var audioTracks: [TrackInfo] { get }
    var subtitleTracks: [TrackInfo] { get }

    var isPlayerLoading: Bool { get }
    var isPlayerPlaying: Bool { get }
    var isPlayerEnded: Bool { get }
    var isAtEndOfFile: Bool { get }
    var hasCoherentTimeSample: Bool { get }
    var durationMs: Int64 { get }
    var positionMs: Int64 { get }
    var bufferedMs: Int64 { get }
    var currentSpeed: Float { get }
    var currentErrorMessage: String { get }
    var videoFrameSize: CGSize { get }

    func loadFile(_ urlString: String)
    func playPlayback()
    func pausePlayback()
    func seekToMs(_ ms: Int64)
    func setSpeed(_ speed: Float)
    func setAspectMode(_ mode: PlayerAspectMode)
    func setSubtitleDelay(_ seconds: Double)
    func setAudioDelay(_ seconds: Double)
    func setAudioVolumeGain(dB: Double)
    func selectAudio(_ trackId: Int)
    func selectSubtitle(_ trackId: Int)
    func addSubtitle(_ subtitle: NuvioSubtitle, select: Bool)
    func addAudioUrl(_ url: String)
    func applySubtitleStyle()
    func destroyPlayer()
    func refreshPlaybackState()
}
