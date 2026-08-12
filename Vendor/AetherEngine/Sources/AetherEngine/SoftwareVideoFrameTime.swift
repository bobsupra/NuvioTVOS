import Foundation
import CoreMedia

/// #311: the presentation time of one software-decoded frame, reported as it is handed to the
/// compositor.
///
/// Separate from `NativeVideoFrameTime` on purpose. That type answers a question this path does not
/// have: the native path muxes what it demuxes, so a frame lives on two axes that differ, in a
/// segment, under a producer epoch that a restart invalidates. Here the engine decodes and enqueues
/// the source timestamp unchanged, so source and presentation coincide by construction and there are
/// no segments to index. Reusing the wider type would have meant three fields carrying a value with
/// no meaning on this path, and a consumer cannot tell a placeholder from a measurement.
///
/// Frames arrive in **ascending presentation order**, unlike the native path's decode-order stream:
/// they are reported past the reorder buffer, so a B-frame run is already sorted. Everything reported
/// here also passed the unschedulable-timestamp gate and any post-seek skip, so each one is a frame
/// the compositor has been given, not merely one that was decoded.
public struct SoftwareVideoFrameTime: Sendable, Equatable {

    /// Presentation timestamp of the enqueued frame, in the source time base. This is the axis
    /// subtitle cues and chapters live on, and the axis the timebase from
    /// `AetherEngine.softwarePresentationTimebase` reads, so no conversion stands between them.
    public let presentation: CMTime

    /// Renderer flush generation. Moves on whenever the renderer discards what it holds, which is what
    /// a seek does, so entries recorded under an older generation describe frames the compositor will
    /// never show. Drop a table's older generations when this changes. Same role as
    /// `NativeVideoFrameTime.epoch`, different cause: there a producer restart re-muxes, here a flush
    /// empties the queue.
    ///
    /// Strictly increasing process-wide, across `load()` calls as well as within one session (#314). A
    /// load builds a new renderer, and the sequence continues there rather than restarting, so a frame
    /// the outgoing renderer still hands over always ranks below the new one's first. Successive
    /// generations are not consecutive and the values carry no meaning beyond their order.
    public let generation: UInt64

    public init(presentation: CMTime, generation: UInt64) {
        self.presentation = presentation
        self.generation = generation
    }
}

/// Called once per enqueued software-decoded frame, on the decode thread. Must not block: it runs
/// inline with the frame handover, so time spent here is time the next frame is not being decoded.
public typealias SoftwareVideoFrameTimeObserver = @Sendable (SoftwareVideoFrameTime) -> Void
