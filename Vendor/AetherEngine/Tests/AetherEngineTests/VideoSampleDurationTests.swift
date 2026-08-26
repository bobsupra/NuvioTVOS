// Look-behind video sample-duration resolution for the fMP4 stream-copy path (#92).
//
// matroska hands a CONSTANT per-frame duration (TrackEntry DefaultDuration) for every video block,
// but the block timecodes are millisecond-quantized, so the true decode-order DTS deltas jitter (a
// 23.976 fps grid alternates 41/42 ms). Trusting the constant makes movenc's per-track duration
// accumulate ahead of the real DTS; at a fragment boundary movenc derives its reference as
// start_dts + track_duration, and once the accumulated overshoot reaches ~one frame that reference
// passes the next real DTS. check_pkt then reports `Packet duration: -N ... out of range`, clamps the
// DTS, and NULLS the pts (`pts has no value`), which lands as wrong trun timing = the transient blocky
// glitch. These pure cases pin the fix: the written sample duration must telescope to the real DTS
// delta whenever a forward next-DTS is available, so track_duration == elapsed DTS and the reference
// can never overshoot.
import Foundation
import Testing
@testable import AetherEngine

@Suite("Video sample-duration telescoping (#92)")
struct VideoSampleDurationTests {

    @Test("Telescopes to the real DTS delta despite a constant DefaultDuration")
    func telescopesDespiteConstantDefaultDuration() {
        // ms-quantized 23.976 fps decode-order DTS grid; deltas jitter 42/41/42/42/41/...
        let dts: [Int64] = [0, 42, 83, 125, 167, 208, 250, 292, 333, 375]
        let constantDefaultDuration: Int64 = 42  // matroska hands the same value every frame
        let fallback: Int64 = 42

        var accumulated: Int64 = 0
        for i in 0..<(dts.count - 1) {
            let resolved = HLSSegmentProducer.resolveVideoSampleDuration(
                existingDuration: constantDefaultDuration,
                dts: dts[i],
                nextDts: dts[i + 1],
                fallback: fallback,
                capTicks: 10_000   // #369: 10 s in the ms grid; irrelevant to these deltas
            )
            // Each sample duration is the true decode-order delta, not the constant 42.
            #expect(resolved == dts[i + 1] - dts[i])
            accumulated += resolved
        }
        // Telescoping invariant: durations sum to the exact DTS span (no accumulated overshoot that
        // would push movenc's start_dts + track_duration reference past the next real DTS).
        #expect(accumulated == dts[dts.count - 1] - dts[0])
    }

    @Test("Falls back to a positive source duration, then the fallback, when there is no next DTS")
    func fallsBackWithoutForwardDelta() {
        // EOF tail (nextDts == nil): keep the source packet's own positive duration.
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 40, dts: 1_000, nextDts: nil, fallback: 42, capTicks: 10_000) == 40)
        // Source duration missing too: use the configured fallback.
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 0, dts: 1_000, nextDts: nil, fallback: 42, capTicks: 10_000) == 42)
    }

    @Test("A non-forward next DTS never yields a zero or negative sample duration")
    func nonForwardNextDtsStaysPositive() {
        // Equal DTS (delta 0): fall back to the positive source duration.
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 42, dts: 1_000, nextDts: 1_000, fallback: 33, capTicks: 10_000) == 42)
        // Backward DTS with no usable source duration: fall back.
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 0, dts: 1_000, nextDts: 990, fallback: 33, capTicks: 10_000) == 33)
    }

    @Test("A wrap-scale inferred delta is rejected by the discontinuity cap (#369)")
    func wrapScaleDeltaIsCapped() {
        // Device trace: seam-preceding dts 363524400, seam packet wrap-corrected to exactly 2^33.
        // The look-behind delta IS the wrap (8226410192 ticks ≈ 91404 s @ 90 kHz); movenc rejected
        // it ("Application provided duration ... is invalid") and the packet was silently lost.
        // Cap = 10 s of 90 kHz ticks, the shared discontinuity threshold.
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 1800, dts: 363_524_400, nextDts: 8_589_934_592,
            fallback: 3600, capTicks: 900_000) == 1800)
        // No usable source duration either: the configured fallback.
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 0, dts: 363_524_400, nextDts: 8_589_934_592,
            fallback: 3600, capTicks: 900_000) == 3600)
        // A delta exactly at the cap still telescopes.
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 1800, dts: 0, nextDts: 900_000,
            fallback: 3600, capTicks: 900_000) == 900_000)
    }

    @Test("A declared duration wider than a discontinuity is capped like an inferred one (#369)")
    func wrapScaleDeclaredDurationIsCapped() {
        // EOF tail of the same wrapped stream: no forward delta exists, so the source's own
        // duration is what reaches movenc, and a container that derived it from the wrapped clock
        // hands over the same invalid number the inferred path is capped for.
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 8_226_410_192, dts: 363_524_400, nextDts: nil,
            fallback: 3600, capTicks: 900_000) == 3600)
        // Same when the forward delta is unusable rather than absent.
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 8_226_410_192, dts: 363_524_400, nextDts: 363_524_400,
            fallback: 3600, capTicks: 900_000) == 3600)
        // A declared duration exactly at the cap is still trusted.
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 900_000, dts: 1_000, nextDts: nil,
            fallback: 3600, capTicks: 900_000) == 900_000)
    }

    @Test("A NOPTS dts or next-dts cannot produce an overflowing delta")
    func nopts() {
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 42, dts: Int64.min, nextDts: 1_000, fallback: 33, capTicks: 10_000) == 42)
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 0, dts: 1_000, nextDts: Int64.min, fallback: 33, capTicks: 10_000) == 33)
    }
}
