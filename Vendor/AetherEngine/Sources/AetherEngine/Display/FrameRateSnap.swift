import Foundation

/// Snap a raw frame rate from the demuxer (libavformat
/// `avg_frame_rate` / `r_frame_rate`) to the nearest standard rate
/// supported by tvOS' Match Frame Rate. Real-world sources rarely
/// probe at exact rates (a 23.976 fps film commonly probes at
/// 23.97-23.98 depending on container rounding), so a tolerance
/// is necessary.
///
/// Returns `nil` for zero or out-of-range rates, in which case the
/// caller should program the display criteria without a refresh-rate
/// hint and let the panel keep its current rate.
enum FrameRateSnap {
    /// Standard rates Apple TV's HDMI handshake will switch to.
    /// Source: AVDisplayManager documentation + empirical testing on
    /// LG / Sony / Philips panels. Anything outside this set is either
    /// VFR / weird capture rates or a probe failure.
    static let standard: [Double] = [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60]

    /// How close a probe has to be to 24.000 to be programmed as 24 Hz:
    /// a fifth of the 0.024 gap to 23.976.
    static let exact24Tolerance: Double = 0.005

    /// Snap `raw` to the nearest member of `standard` within ±0.5 fps,
    /// or `nil` if it falls outside that tolerance from every standard
    /// rate. Special case: the [23.5, 24.05] window goes to 23.976 except
    /// for a probe within `exact24Tolerance` of 24.000, which goes to 24.
    static func snap(_ raw: Double) -> Double? {
        guard raw > 0, raw.isFinite else { return nil }

        // AE#884: 24.000 fps on a 23.976 Hz panel repeats a frame every
        // ~42 s, so a true 24p source needs 24 Hz. A Matroska track with
        // DefaultDuration probes as an exact 24/1 or 24000/1001, so 24p
        // is told apart by an exact match and anything noisier stays 23.976.
        if abs(raw - 24) <= exact24Tolerance {
            return 24
        }
        if raw >= 23.5 && raw <= 24.05 {
            return 23.976
        }

        var best: (rate: Double, delta: Double)?
        for candidate in standard where candidate != 23.976 {
            let delta = abs(candidate - raw)
            if delta <= 0.5 {
                if let current = best {
                    if delta < current.delta { best = (candidate, delta) }
                } else {
                    best = (candidate, delta)
                }
            }
        }
        return best?.rate
    }
}
