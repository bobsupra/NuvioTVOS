import Foundation
import AetherLibavutil

/// AE#923: shaped interleaved Float32 into the sample format the bridge encoder takes. The limiter
/// has already brought every sample under full scale, so the integer paths only round and clamp.
enum AudioShapingSampleWriter {

    /// Converts `frames` frames and hands the resulting plane pointers (one per channel for a planar
    /// format, one in all for an interleaved one) to `body`, valid only for the duration of the call.
    static func write(
        interleaved src: UnsafePointer<Float>,
        frames: Int,
        channels: Int,
        format: AVSampleFormat,
        _ body: (inout [UnsafeMutablePointer<UInt8>?]) -> Int32
    ) -> Int32 {
        let samples = frames * channels
        switch format {
        case AV_SAMPLE_FMT_FLTP:
            let planes = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
            defer { planes.forEach { $0.deallocate() } }
            for f in 0..<frames {
                for c in 0..<channels { planes[c][f] = src[f * channels + c] }
            }
            var ptrs: [UnsafeMutablePointer<UInt8>?] = planes.map {
                UnsafeMutableRawPointer($0).assumingMemoryBound(to: UInt8.self)
            }
            return body(&ptrs)
        case AV_SAMPLE_FMT_S16:
            let out = UnsafeMutablePointer<Int16>.allocate(capacity: samples)
            defer { out.deallocate() }
            for i in 0..<samples { out[i] = Int16(clampedScaled(src[i], Double(Int16.max))) }
            var ptrs: [UnsafeMutablePointer<UInt8>?] = [UnsafeMutableRawPointer(out).assumingMemoryBound(to: UInt8.self)]
            return body(&ptrs)
        case AV_SAMPLE_FMT_S32:
            let out = UnsafeMutablePointer<Int32>.allocate(capacity: samples)
            defer { out.deallocate() }
            for i in 0..<samples { out[i] = Int32(clampedScaled(src[i], Double(Int32.max))) }
            var ptrs: [UnsafeMutablePointer<UInt8>?] = [UnsafeMutableRawPointer(out).assumingMemoryBound(to: UInt8.self)]
            return body(&ptrs)
        default:
            var ptrs: [UnsafeMutablePointer<UInt8>?] = [UnsafeMutableRawPointer(mutating: src).assumingMemoryBound(to: UInt8.self)]
            return body(&ptrs)
        }
    }

    static func clampedScaled(_ v: Float, _ fullScale: Double) -> Double {
        guard v.isFinite else { return 0 }
        return (min(max(Double(v), -1), 1) * fullScale).rounded()
    }
}
