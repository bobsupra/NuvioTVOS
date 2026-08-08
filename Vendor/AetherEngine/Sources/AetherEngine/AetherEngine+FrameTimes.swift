import Foundation

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
    public func setNativeVideoFrameTimeObserver(_ observer: NativeVideoFrameTimeObserver?) {
        nativeVideoFrameTimeObserver = observer
        nativeVideoSession?.setNativeVideoFrameTimeObserver(observer)
    }
}
