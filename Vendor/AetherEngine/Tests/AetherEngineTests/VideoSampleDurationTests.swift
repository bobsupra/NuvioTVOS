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
import AetherLibavutil
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

    @Test("CFRFrameGrid transitions between snapped and off-grid frames telescope without overshoot")
    func frameGridTransitionsTelescopeInMuxerTimeBase() throws {
        let ms = AVRational(num: 1, den: 1000)
        let grid = try #require(CFRFrameGrid.make(
            sourceTimeBase: ms,
            frameRate: AVRational(num: 24000, den: 1001),
            startPts: 0
        ))
        let muxerTb = grid.outputTimeBase

        // Field trace shape around t=486..490s:
        // - off-grid frame -> snapped frame (prev duration 42ms=1008 would overshoot by 12 ticks)
        // - PTS-snapped / DTS-off-grid (488239) -> off-grid (488280) (-17 ticks before fix)
        // - PTS-snapped / DTS-off-grid (489782) -> snapped (489823) (-25 ticks before fix)
        // - off-grid (490157) -> snapped (490199) (-23 ticks before fix)
        let samples: [(pts: Int64, dts: Int64, duration: Int64)] = [
            (486_947, 486_945, 42),  // PTS 486947 is 27 ticks off slot 11675 (off-grid)
            (486_987, 486_987, 42),  // snapped to 11676*1001 = 11687676
            (488_238, 488_239, 41),  // PTS snaps (11706*1001), DTS 488239*24=11717736 is 30 ticks off (unsnapped)
            (488_281, 488_280, 42),  // PTS 488281 is 37 ticks off slot 11707 (off-grid)
            (489_781, 489_782, 41),  // PTS snaps (11743*1001), DTS 489782*24=11754768 is 25 ticks off (unsnapped)
            (489_823, 489_823, 42),  // snapped to 11744*1001 = 11755744
            (490_158, 490_157, 42),  // PTS 490158 is 32 ticks off slot 11752 (off-grid)
            (490_198, 490_199, 42),  // PTS snaps (11753*1001), DTS 490199 snaps to 11753*1001 = 11764753
        ]

        let placements = samples.map { s in
            HLSSegmentProducer.placeVideoPacket(
                pts: s.pts,
                dts: s.dts,
                sourceDuration: s.duration,
                sourceTimeBase: ms,
                muxerTimeBase: muxerTb,
                shift: 0,
                frameGrid: grid,
                pulldownRetimer: nil
            )
        }

        for i in 0..<(placements.count - 1) {
            let duration = HLSSegmentProducer.resolveVideoSampleDuration(
                existingDuration: placements[i].duration,
                dts: placements[i].dts,
                nextDts: placements[i + 1].dts,
                fallback: 42 * 24,
                capTicks: 10_000 * 24
            )
            #expect(duration > 0)
            #expect(placements[i].dts + duration == placements[i + 1].dts,
                    "idx \(i): dts+dur \(placements[i].dts + duration) != next \(placements[i + 1].dts)")
        }
    }

    @Test("PulldownCadenceRetimer placements telescope without overshoot in muxer time base")
    func pulldownRetimerTelescopesInMuxerTimeBase() throws {
        let ms = AVRational(num: 1, den: 1000)
        let grid = try #require(CFRFrameGrid.make(
            sourceTimeBase: ms,
            frameRate: AVRational(num: 24000, den: 1001),
            startPts: 0
        ))
        let retimer = try #require(PulldownCadenceRetimer(grid: grid))
        let muxerTb = grid.outputTimeBase

        var placements: [HLSSegmentProducer.VideoOutputPlacement] = []
        for (idx, pts) in PulldownCadenceRetimerTests.clipPts.enumerated() {
            let dts = PulldownCadenceRetimerTests.clipDts[idx] ?? Int64.min
            placements.append(HLSSegmentProducer.placeVideoPacket(
                pts: pts,
                dts: dts,
                sourceDuration: 50,
                sourceTimeBase: ms,
                muxerTimeBase: muxerTb,
                shift: 0,
                frameGrid: grid,
                pulldownRetimer: retimer
            ))
        }

        for i in 0..<(placements.count - 1) {
            let prev = placements[i]
            let next = placements[i + 1]
            guard prev.dts != Int64.min, next.dts != Int64.min, next.dts > prev.dts else { continue }
            let duration = HLSSegmentProducer.resolveVideoSampleDuration(
                existingDuration: prev.duration,
                dts: prev.dts,
                nextDts: next.dts,
                fallback: 42 * 24,
                capTicks: 10_000 * 24
            )
            #expect(prev.dts + duration == next.dts)
        }
    }
}
