import Foundation

/// AE#923: the dynamics half of audio shaping, run on interleaved Float32 PCM after the remix.
///
/// Two stages, both linked across every channel (one gain per sample frame, so the image does not
/// move when one channel is loud):
///
/// 1. the optional compressor: a peak detector, a soft-knee static curve, and attack/release
///    smoothing on the gain in dB (the "smooth branching" detector of Giannoulis, Massberg and Reiss,
///    JAES 2012), then the makeup gain;
/// 2. a peak limiter at `ceilingDBFS` with instant attack and a `limiterReleaseSeconds` release,
///    which is what lets the matrix stay unnormalized and the makeup gain be generous. It has no
///    lookahead, because a lookahead delays the audio against the video by its own length and the
///    engine's timestamps are already committed by the time samples reach this stage; the price is
///    that a transient above the ceiling is clamped within its first sample rather than ramped.
///
/// Stateful across buffers; `reset()` belongs wherever the stream it follows is discontinuous
/// (flush, seek, a rebuilt resampler).
struct AudioDynamicsProcessor {

    /// The limiter's ceiling. One dB under full scale leaves room for the inter-sample overs a lossy
    /// re-encode (the E-AC-3 bridge) adds.
    static let ceilingDBFS: Double = -1
    static let limiterReleaseSeconds: Double = 0.05

    private let compressor: AudioShaping.Compressor?
    private let attackCoefficient: Double
    private let releaseCoefficient: Double
    private let limiterReleaseCoefficient: Float
    private let makeupDB: Double
    private let ceiling: Float

    /// Smoothed compressor gain in dB (<= 0).
    private var smoothedGainDB: Double = 0
    /// Current limiter gain (<= 1).
    private var limiterGain: Float = 1

    init(compressor: AudioShaping.Compressor?, sampleRate: Int32) {
        let k = compressor?.clamped
        self.compressor = k
        let fs = Double(max(sampleRate, 1))
        attackCoefficient = k.map { exp(-1 / ($0.attackMilliseconds / 1000 * fs)) } ?? 0
        releaseCoefficient = k.map { exp(-1 / ($0.releaseMilliseconds / 1000 * fs)) } ?? 0
        limiterReleaseCoefficient = Float(exp(-1 / (Self.limiterReleaseSeconds * fs)))
        makeupDB = k?.makeupGainDB ?? 0
        ceiling = Float(pow(10, Self.ceilingDBFS / 20))
    }

    mutating func reset() {
        smoothedGainDB = 0
        limiterGain = 1
    }

    /// The compressor's static curve: output level in dB for an input level in dB.
    static func staticCurve(inputDB x: Double, compressor k: AudioShaping.Compressor) -> Double {
        let t = k.thresholdDB, r = k.ratio, w = k.kneeDB
        let over = x - t
        if 2 * over < -w { return x }
        if w > 0, 2 * abs(over) <= w {
            let d = over + w / 2
            return x + (1 / r - 1) * d * d / (2 * w)
        }
        return t + over / r
    }

    /// Shape `frames` frames of `channels` interleaved samples in place.
    mutating func process(_ samples: UnsafeMutablePointer<Float>, frames: Int, channels: Int) {
        guard frames > 0, channels > 0 else { return }
        for f in 0..<frames {
            let base = samples + f * channels
            var peak: Float = 0
            for c in 0..<channels {
                let v = base[c]
                if v.isFinite {
                    peak = max(peak, abs(v))
                } else {
                    base[c] = 0
                }
            }

            var gain: Float = 1
            if let k = compressor {
                let x = 20 * log10(Double(max(peak, 1e-9)))
                let target = Self.staticCurve(inputDB: x, compressor: k) - x
                let a = target < smoothedGainDB ? attackCoefficient : releaseCoefficient
                smoothedGainDB = a * smoothedGainDB + (1 - a) * target
                gain = Float(pow(10, (smoothedGainDB + makeupDB) / 20))
            }

            let shapedPeak = peak * gain
            let needed: Float = shapedPeak > ceiling ? ceiling / shapedPeak : 1
            let released = limiterReleaseCoefficient * limiterGain + (1 - limiterReleaseCoefficient)
            limiterGain = min(needed, released)
            gain *= limiterGain

            if gain != 1 {
                for c in 0..<channels { base[c] *= gain }
            }
        }
    }
}
