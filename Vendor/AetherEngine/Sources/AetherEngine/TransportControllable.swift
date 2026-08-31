import Foundation

/// Common transport surface for all four playback hosts so `AetherEngine` resolves ownership once (`activeTransportHost`). The cascade had drifted before: the volume setter wrote into every host, including the inactive audio host, silently changing the next music session's volume.
@MainActor
protocol TransportControllable: AnyObject {
    func play()
    func pause()
    func setRate(_ rate: Float)
    /// The rate a later `play()` comes back at (#436). Never starts, stops, or re-rates playback:
    /// this seeds the memory a resume reads, which is what carries a speed across the host rebuilds
    /// a session makes on its own. Zero is a pause rather than a speed and is ignored here.
    func setResumeRate(_ rate: Float)
    var volume: Float { get set }
}

extension SoftwarePlaybackHost: TransportControllable {}
extension AudioPlaybackHost: TransportControllable {}
extension AudioAVPlayerHost: TransportControllable {}
extension NativeAVPlayerHost: TransportControllable {}
