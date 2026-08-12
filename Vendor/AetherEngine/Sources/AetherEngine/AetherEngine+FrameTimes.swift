import Foundation
import CoreMedia

extension AetherEngine {

    /// Report the presentation time of every muxed video frame on both axes (#260).
    ///
    /// Only the native (loopback HLS) path produces these: it is the path where the engine muxes and
    /// AVPlayer presents, so the two axes exist and differ. The software and audio paths present what
    /// they decode, with no shift to reconcile.
    ///
    /// The observer is called on the producer's pump thread and must not block. It survives producer
    /// restarts and outlives a `load()`, so install it once; pass nil to remove it. Use
    /// `presentationAxisMap` to convert positions that are not frames (a cue time, a clock reading).
    ///
    /// A load is not a seam a consumer has to reason about: `NativeVideoFrameTime.epoch` keeps rising
    /// across it (#314), so the same retire-the-older-epoch rule separates the outgoing item's frames
    /// from the incoming one's. The superseded session is also detached at teardown, so in the ordinary
    /// case it falls silent rather than racing the new one.
    public func setNativeVideoFrameTimeObserver(_ observer: NativeVideoFrameTimeObserver?) {
        nativeVideoFrameTimeObserver = observer
        nativeVideoSession?.setNativeVideoFrameTimeObserver(observer)
    }

    /// Report the presentation time of every video frame the software path enqueues (#311).
    ///
    /// The software-path counterpart to `setNativeVideoFrameTimeObserver`, and a separate call
    /// because it answers a differently shaped question: this path decodes and presents the source
    /// timestamp unchanged, so there is one axis rather than two, and no segments or producer epochs
    /// to key a table by. See `SoftwareVideoFrameTime`.
    ///
    /// The observer is called on the decode thread and must not block. It outlives a `load()`, so
    /// install it once; pass nil to remove it. `SoftwareVideoFrameTime.generation` keeps rising across
    /// that load (#314), so the item seam needs no separate handling. Silent on every other path,
    /// including the remote-HLS bypass, where AVPlayer owns decode and the engine never sees a frame.
    public func setSoftwareVideoFrameTimeObserver(_ observer: SoftwareVideoFrameTimeObserver?) {
        softwareVideoFrameTimeObserver = observer
        softwareHost?.setVideoFrameTimeObserver(observer)
    }

    /// The timebase the software path presents against, or nil on every other path and before a
    /// session exists (#311).
    ///
    /// This is the master clock: the render synchronizer drives both the audio renderer and the video
    /// display layer, so a `CALayer` overlay timed against it is timed against the same clock the
    /// frames are. It reads the SOURCE axis, which is the axis of `SoftwareVideoFrameTime.presentation`
    /// and of the subtitle cues the engine emits, so nothing has to be converted between them.
    ///
    /// Read-only in intent: `CMTimebase` is mutable and Core Media cannot enforce that, but the engine
    /// owns transport here. Setting rate or time on it fights `play()`, `pause()` and `seek(to:)` and
    /// desynchronises audio from video.
    public var softwarePresentationTimebase: CMTimebase? {
        softwareHost?.presentationTimebase
    }
}
