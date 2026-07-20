import Foundation
import Testing
@testable import AetherEngine

/// #112 round 10 (ijuniorfu, 0.9.19, remote Blu-ray ISO): "the 45-second delay mentioned in item 1 persists".
/// Device log timeline (media clock): seek lands at 901.9s, three positioning cycles all fall back to the
/// byte estimate, and the reader that finally runs parks at demuxPos=1712.2s (source) against a playhead of
/// 1520.9s: the estimate landed 227s PAST the target and the forward-only read loop could never recover.
///
/// Root cause, confirmed arithmetically against the log: `byteEstimateTarget` mapped the ABSOLUTE source PTS
/// onto the byte axis (fraction = target / duration), but a Blu-ray title's byte range covers source times
/// [startOrigin, startOrigin + duration] with startOrigin = 600s on this disc. Predicted wrong landing:
/// (1485.42 / 7508.9 - 0.05) x 7508.9 + 600 = 1710.0s source. Observed: 1712.2s. Two coupled amplifiers:
/// the 5% early bias is fraction-of-file (375s on a 2h05 title, minutes of remote forward read even when the
/// origin math is right), and a late landing was never detected, so the reader silently parked ahead.
///
/// These tests lock the pure pieces: origin-corrected proportion, absolute-seconds bias, start-origin
/// resolution from stream metadata, and the landing-verification probe decision.
struct Issue112ByteEstimateOriginTests {

    // MARK: byteEstimateTarget: origin-corrected proportion, absolute bias

    @Test("byte-estimate subtracts the source start origin before mapping onto the byte axis")
    func byteEstimateSubtractsOrigin() {
        // 1000 bytes over 100 s of media starting at source 600 s. Target source 650 s is the file's
        // midpoint; with the bias suppressed the estimate must land at byte 500, not byte 1000's clamp.
        #expect(Demuxer.byteEstimateTarget(
            fileSize: 1000, duration: 100, target: 650, startOrigin: 600, earlyBiasSeconds: 0) == 500)
    }

    @Test("device regression: remote Blu-ray title lands at or slightly before the target, never past it")
    func discOffsetRegression() {
        // Exact numbers from the round-10 device log: 63,403,425,792-byte title, duration 7508.9 s,
        // video stream start 600.0 s, positioning target source 1485.42 s.
        let size: Int64 = 63_403_425_792
        let duration = 7508.9
        let origin = 600.0
        let target = 1485.42
        let byte = Demuxer.byteEstimateTarget(
            fileSize: size, duration: duration, target: target, startOrigin: origin)
        let b = try! #require(byte)
        // Uniform-bitrate implied landing on the source axis.
        let impliedSourceLanding = Double(b) / Double(size) * duration + origin
        #expect(impliedSourceLanding <= target)
        #expect(impliedSourceLanding >= target - 30)  // bias is seconds, not 5% of the file (375 s)
        // The 0.9.19 math landed at source 1710 (observed 1712.2); the fix must land far below that byte.
        let buggyByte = Int64((target / duration - 0.05) * Double(size))
        #expect(b < buggyByte)
    }

    @Test("bias is absolute seconds, not a fraction of the file")
    func biasIsAbsoluteSeconds() {
        // 100 s file: default bias must shave whole seconds (12), not 5.
        #expect(Demuxer.byteEstimateTarget(fileSize: 1000, duration: 100, target: 50) == 380)
    }

    @Test("byte-estimate clamps at the file edges with an origin in play")
    func byteEstimateClampsWithOrigin() {
        // Target before the file's first byte clamps to 0 instead of going negative.
        #expect(Demuxer.byteEstimateTarget(
            fileSize: 1000, duration: 100, target: 590, startOrigin: 600) == 0)
        // Target past the end caps at the file size.
        #expect(Demuxer.byteEstimateTarget(
            fileSize: 1000, duration: 100, target: 900, startOrigin: 600) == 1000)
    }

    @Test("byte-estimate stays nil for unknown size, duration, or nonsense targets")
    func byteEstimateNilGuards() {
        #expect(Demuxer.byteEstimateTarget(fileSize: 0, duration: 100, target: 50) == nil)
        #expect(Demuxer.byteEstimateTarget(fileSize: -1, duration: 100, target: 50) == nil)
        #expect(Demuxer.byteEstimateTarget(fileSize: 1000, duration: 0, target: 50) == nil)
        #expect(Demuxer.byteEstimateTarget(fileSize: 1000, duration: 100, target: -1) == nil)
    }

    // MARK: start-origin resolution from stream metadata

    @Test("origin prefers a valid format start time")
    func originFromFormatStart() {
        let origin = Demuxer.sourceStartOrigin(
            formatStartUs: 600_740_000, videoStreamStart: 54_000_000,
            videoTimeBaseNum: 1, videoTimeBaseDen: 90_000)
        #expect(abs(origin - 600.74) < 0.001)
    }

    @Test("origin falls back to the video stream start when the format start is NOPTS")
    func originFromVideoStream() {
        // The device log's exact metadata: format.start_time NOPTS, videoStart 54000000 in 1/90000.
        let origin = Demuxer.sourceStartOrigin(
            formatStartUs: Int64.min, videoStreamStart: 54_000_000,
            videoTimeBaseNum: 1, videoTimeBaseDen: 90_000)
        #expect(abs(origin - 600.0) < 0.001)
    }

    @Test("origin is zero when neither format nor video stream declare a start")
    func originZeroWhenUnknown() {
        let origin = Demuxer.sourceStartOrigin(
            formatStartUs: Int64.min, videoStreamStart: Int64.min,
            videoTimeBaseNum: 1, videoTimeBaseDen: 90_000)
        #expect(origin == 0)
    }

    // MARK: landing verification probe decisions

    @Test("a landing at or slightly before the target is accepted")
    func landingAcceptedWithinWindow() {
        let decision = Demuxer.byteEstimateCorrection(
            landed: 1473.4, target: 1485.42, startOrigin: 600, duration: 7508.9,
            fileSize: 63_403_425_792, currentByte: 7_374_000_000, attempt: 0)
        #expect(decision == .accept)
    }

    @Test("device regression: a late landing re-probes proportionally below the current byte")
    func lateLandingReprobes() {
        // The log's failure: landed source 1712.2 for target 1485.42. The correction must land
        // at target minus bias under the slope calibrated by the landing itself.
        let currentByte: Int64 = 9_371_675_000
        let decision = Demuxer.byteEstimateCorrection(
            landed: 1712.2, target: 1485.42, startOrigin: 600, duration: 7508.9,
            fileSize: 63_403_425_792, currentByte: currentByte, attempt: 0)
        guard case .probe(let byte) = decision else {
            Issue.record("expected a corrective probe, got \(decision)")
            return
        }
        #expect(byte < currentByte)
        // Calibrated slope: currentByte covers (1712.2 - 600) s, so the probe's implied landing
        // is (target - bias): (1485.42 - 12 - 600) / (1712.2 - 600) x currentByte.
        let implied = Double(byte) / Double(currentByte) * (1712.2 - 600) + 600
        #expect(abs(implied - (1485.42 - 12)) < 1.0)
    }

    @Test("a landing far too early re-probes forward to spare the remote forward read")
    func farEarlyLandingReprobesForward() {
        let currentByte: Int64 = 2_500_000_000
        let decision = Demuxer.byteEstimateCorrection(
            landed: 900, target: 1485.42, startOrigin: 600, duration: 7508.9,
            fileSize: 63_403_425_792, currentByte: currentByte, attempt: 0)
        guard case .probe(let byte) = decision else {
            Issue.record("expected a forward probe, got \(decision)")
            return
        }
        #expect(byte > currentByte)
    }

    @Test("the correction budget caps at two probes, then accepts best effort")
    func correctionBudgetCaps() {
        let decision = Demuxer.byteEstimateCorrection(
            landed: 1712.2, target: 1485.42, startOrigin: 600, duration: 7508.9,
            fileSize: 63_403_425_792, currentByte: 9_371_675_000, attempt: 2)
        #expect(decision == .accept)
    }

    @Test("a landing without a usable calibration span is accepted, not divided by zero")
    func degenerateCalibrationAccepts() {
        let decision = Demuxer.byteEstimateCorrection(
            landed: 600.0, target: 1485.42, startOrigin: 600, duration: 7508.9,
            fileSize: 63_403_425_792, currentByte: 0, attempt: 0)
        #expect(decision == .accept)
    }

    // MARK: sticky timestamp-seek condemnation

    @Test("a demuxer starts with timestamp seeks trusted and condemns them once")
    func timestampSeekCondemnation() {
        let demuxer = Demuxer()
        #expect(demuxer.timestampSeekUnreliable == false)
        demuxer.markTimestampSeekUnreliable()
        #expect(demuxer.timestampSeekUnreliable == true)
    }
}
