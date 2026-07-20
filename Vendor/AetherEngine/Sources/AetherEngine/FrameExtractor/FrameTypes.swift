import Foundation

/// Which extraction mode produced (or is requested for) a frame.
///
/// - `thumbnail`: nearest keyframe, no forward decode, downscaled. Cheap; scrub/Recents.
/// - `snapshot`: frame-accurate (decode forward to exact PTS), full/requested res; stills.
public enum FrameMode: Sendable, Hashable {
    case thumbnail
    case snapshot
}
