import Foundation

@main
struct SoftwareVideoPacketCoverageTests {
    static func main() {
        observedVariableFrameRateSequence()
        pendingBFramesStayBehindWatermark()
        boundedFieldReordering()
        discontinuitiesAndFinalPicture()
        invalidationResetAndBounds()
        pruneAndRationalPolicy()
        print("PASS: observed VFR successor holds, pending B-frame watermark, 32-field reorder bound, one-second discontinuities, unknown final end, invalid PTS/late arrival/reset, rational boundaries and pruning")
    }

    static func model(depth: Int = 32) -> SoftwareVideoPacketCoverage {
        SoftwareVideoPacketCoverage(timeBaseNumerator: 1, timeBaseDenominator: 30000,
                                    reorderDepth: depth)
    }

    static func observedVariableFrameRateSequence() {
        let packets: [(pts: Int64, dts: Int64, duration: Int64)] = [
            (1261260, 1259258, 1001),
            (1277276, 1260259, 1001),
            (1280279, 1261260, 16016),
            (1279278, 1277276, 1001),
            (1278277, 1278277, 1001),
        ]
        var old = SoftwarePacketCoverage()
        var video = model()
        for packet in packets {
            old.insert(pts: packet.pts, duration: packet.duration)
            precondition(video.insert(pts: packet.pts))
        }
        precondition(old.frontier(containing: packets[0].pts) == 1262261)
        precondition(old.frontier(containing: 1265000) == nil)
        // These first five packets alone have not crossed the 32-entry reorder watermark.
        precondition(video.frontier(containing: packets[0].pts) == nil)
        // Subsequent retained packets release the exact observed successor pair without EOF.
        for index in 1...32 { precondition(video.insert(pts: 1280279 + Int64(index) * 1001)) }
        precondition(!video.isInvalidated)
        precondition(video.frontier(containing: 1265000) == 1280279)
        precondition(video.frontierSeconds(containing: 1265000.0 / 30000.0,
            timeBaseNumerator: 1, timeBaseDenominator: 30000) == 1280279.0 / 30000.0)
        // No input packet was rewritten: the long hold is between PTS 1261260 and 1277276,
        // not the unrelated packet carrying the 16016-tick decode duration.
        precondition(packets[0].duration == 1001)
        precondition(packets[2].duration == 16016)

        var eof = model()
        for packet in packets { precondition(eof.insert(pts: packet.pts)) }
        eof.finish()
        precondition(eof.frontier(containing: 1265000) == 1280279)
        precondition(eof.frontier(containing: 1280279) == nil)
    }

    static func pendingBFramesStayBehindWatermark() {
        var video = model()
        video.insert(pts: 0)
        video.insert(pts: 3003)
        for index in 4...33 { video.insert(pts: Int64(index) * 1001) }
        precondition(video.pendingCount == 32)
        precondition(video.frontier(containing: 0) == nil)
        // Late-arriving B pictures fit inside the pending window. A future P picture must not
        // prematurely expose its PTS as a playable frontier while these are unresolved.
        video.insert(pts: 1001)
        precondition(video.frontier(containing: 0) == nil)
        video.insert(pts: 2002)
        precondition(video.frontier(containing: 0) == 1001)
        precondition(video.frontier(containing: 1001) == nil)
        precondition(!video.isInvalidated)
        precondition(video.pendingCount == 32)
    }

    static func boundedFieldReordering() {
        var video = model()
        // Thirty-two field timestamps arrive in reverse order, then later fields arrive normally.
        for field in (0..<32).reversed() {
            precondition(video.insert(pts: Int64(field) * 500))
            precondition(video.pendingCount <= 32)
            precondition(video.frontier(containing: 0) == nil)
        }
        for field in 32..<96 {
            precondition(video.insert(pts: Int64(field) * 500))
            precondition(video.pendingCount == 32)
            precondition(!video.isInvalidated)
        }
        precondition(video.frontier(containing: 0) == 63 * 500)
        video.finish()
        precondition(video.pendingCount == 0)
        precondition(video.frontier(containing: 0) == 95 * 500)
        precondition(video.frontier(containing: 95 * 500) == nil)
    }

    static func discontinuitiesAndFinalPicture() {
        var video = model(depth: 1)
        for pts: Int64 in [0, 30000, 60001, 61002, 62003] { video.insert(pts: pts) }
        video.finish()
        precondition(video.frontier(containing: 0) == 30000) // Exactly 1 s is permitted.
        precondition(video.frontier(containing: 30000) == nil) // 1 s + 1 tick is not.
        precondition(video.frontier(containing: 40000) == nil)
        precondition(video.frontier(containing: 60001) == 62003)
        precondition(video.frontier(containing: 62003) == nil)
        precondition(!video.isInvalidated)
        video.finish()
        precondition(video.frontier(containing: 60001) == 62003)
        precondition(!video.insert(pts: 63004)) // EOF must be reset before another generation.

        var one = model()
        one.insert(pts: 1001)
        one.finish()
        precondition(one.rangeCount == 0)
        precondition(one.frontier(containing: 1001) == nil)
    }

    static func invalidationResetAndBounds() {
        var video = model(depth: 1)
        for pts: Int64 in [0, 1001, 2002, 3003] { video.insert(pts: pts) }
        precondition(video.frontier(containing: 0) == 2002)
        precondition(!video.insert(pts: 1000)) // Behind already emitted PTS 2002.
        precondition(video.isInvalidated)
        precondition(video.lateTimestampCount == 1)
        precondition(video.pendingCount == 0)
        precondition(video.rangeCount == 0)
        precondition(video.frontier(containing: 0) == nil)
        precondition(!video.insert(pts: 4004))
        video.reset()
        precondition(!video.isInvalidated)
        precondition(video.lateTimestampCount == 0)
        for pts: Int64 in [-3003, -2002, -1001] { video.insert(pts: pts) }
        video.finish()
        precondition(video.frontier(containing: -3003) == -1001)
        precondition(video.frontier(containing: 0) == nil)
        video.reset()
        precondition(!video.insert(pts: .min))
        precondition(video.isInvalidated)
        precondition(video.rangeCount == 0)

        for depth in [Int.min, -1, 0, 33, Int.max] {
            var invalid = model(depth: depth)
            precondition(invalid.isInvalidated)
            precondition(!invalid.insert(pts: 0))
            precondition((1...32).contains(invalid.reorderDepth))
            invalid.reset()
            precondition(invalid.isInvalidated)
        }
        for (num, den): (Int32, Int32) in [(0, 1), (1, 0), (-1, 30000), (1, -1)] {
            var invalid = SoftwareVideoPacketCoverage(timeBaseNumerator: num, timeBaseDenominator: den)
            precondition(invalid.isInvalidated)
            precondition(!invalid.insert(pts: 0))
        }

        var overflow = model(depth: 1)
        overflow.insert(pts: .min + 1)
        overflow.insert(pts: .max)
        overflow.finish()
        precondition(overflow.isInvalidated)
        precondition(overflow.rangeCount == 0)

        var duplicates = model(depth: 1)
        for _ in 0..<1000 { precondition(duplicates.insert(pts: 0)) }
        precondition(duplicates.pendingCount == 1)
        precondition(duplicates.frontier(containing: 0) == nil)
        duplicates.insert(pts: 1001)
        precondition(duplicates.insert(pts: 0)) // Equal to watermark, not a late older PTS.
        duplicates.insert(pts: 2002)
        precondition(duplicates.frontier(containing: 0) == 1001)
    }

    static func pruneAndRationalPolicy() {
        var video = model(depth: 1)
        for pts: Int64 in [0, 1001, 50000, 51001, 100000, 101001] { video.insert(pts: pts) }
        video.finish()
        precondition(video.rangeCount == 3)
        video.prune(before: 50500)
        precondition(video.rangeCount == 2)
        precondition(video.frontier(containing: 50000) == 51001)
        precondition(video.frontier(containing: 25000) == nil)
        precondition(video.frontierSeconds(containing: 50000.0 / 30000.0,
            timeBaseNumerator: 1, timeBaseDenominator: 48000) == nil)

        var rational = SoftwareVideoPacketCoverage(timeBaseNumerator: 1001,
                                                   timeBaseDenominator: 30000, reorderDepth: 1)
        for pts: Int64 in [0, 29, 59, 60] { rational.insert(pts: pts) }
        rational.finish()
        precondition(rational.frontier(containing: 0) == 29)
        precondition(rational.frontier(containing: 29) == nil) // 30 * 1001 / 30000 > 1 s.
        precondition(rational.frontier(containing: 59) == 60)
    }
}
