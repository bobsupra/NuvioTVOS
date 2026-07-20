import Foundation

/// Converts between the two time axes a session exposes (AE#105).
///
/// - **Source-PTS axis**: the timestamps the decoder/producer/subtitle readers work in. For a normal file
///   this starts at ~0; for a Blu-ray/DVD title it starts at clip 0's STC base (the TRON multi-clip titles
///   start at 599s / 4199s), because the raw m2ts/VOB clocks are not zero-based.
/// - **Display axis**: the 0-based `[0, duration]` axis the scrubber shows and the host seeks against. A disc
///   title's `duration` is the 0-based MPLS/IFO playlist length, so the published playhead must match it.
///
/// `sourcePresentationOrigin` is the source PTS that maps to display-0 (0 for normal/live, clip 0's base for a
/// disc title). These helpers keep every public playhead/seek conversion in one place so the sign is obvious
/// and unit-testable; `sourceTime` and the internal producer/subtitle axes stay on the source-PTS axis.
enum PresentationAxis {
    /// Published playhead / seek-target on the 0-based display axis, from a source-PTS value.
    /// Inverse of `source(displayTime:origin:)`. Identity when `origin == 0`.
    static func display(sourcePTS: Double, origin: Double) -> Double {
        sourcePTS - origin
    }

    /// Source PTS from a 0-based display value (host seek input, resume position).
    /// Inverse of `display(sourcePTS:origin:)`. Identity when `origin == 0`.
    static func source(displayTime: Double, origin: Double) -> Double {
        displayTime + origin
    }
}
