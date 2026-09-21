import Foundation

@main
struct SoftwarePacketCoverageTests {
    static func main() {
        reorderedPresentationPackets()
        negativeAndFractionalTimestamps()
        selectedStreamIntersection()
        resetPruneAndCapacity()
        malformedAndOverflow()
        exhaustiveSmallUnion()
        print("PASS: PTS coverage, B-frame holes, fractional boundaries, selected A/V, reset/prune, bounded gaps, malformed input and overflow")
    }

    static func reorderedPresentationPackets() {
        var coverage = SoftwarePacketCoverage()
        precondition(coverage.insert(pts: 0, duration: 1001))
        // Decode order: I, future P, then the two intervening B pictures.
        precondition(coverage.insert(pts: 3003, duration: 1001))
        precondition(coverage.frontier(containing: 0) == 1001)
        precondition(coverage.frontier(containing: 1001) == nil)
        precondition(coverage.frontier(containing: 2002) == nil)
        precondition(coverage.insert(pts: 2002, duration: 1001))
        precondition(coverage.frontier(containing: 0) == 1001)
        precondition(coverage.frontier(containing: 2002) == 4004)
        precondition(coverage.insert(pts: 1001, duration: 1001))
        precondition(coverage.rangeCount == 1)
        precondition(coverage.frontier(containing: 0) == 4004)
        precondition(coverage.frontier(containing: 4003) == 4004)
        precondition(coverage.frontier(containing: 4004) == nil)
        // Overlap/duplicate insertion neither splits coverage nor inflates its endpoint.
        precondition(coverage.insert(pts: 500, duration: 1500))
        precondition(coverage.insert(pts: 0, duration: 1001))
        precondition(coverage.rangeCount == 1)
        precondition(coverage.frontier(containing: 500) == 4004)
    }

    static func negativeAndFractionalTimestamps() {
        var coverage = SoftwarePacketCoverage()
        precondition(coverage.insert(pts: -1001, duration: 1001))
        precondition(coverage.insert(pts: 0, duration: 1001))
        precondition(coverage.frontier(containing: -1001) == 1001)
        precondition(coverage.frontier(containing: -1002) == nil)
        let start = -1001.0 / 30000.0
        let end = 1001.0 / 30000.0
        func seconds(_ time: Double) -> Double? {
            coverage.frontierSeconds(containing: time, timeBaseNumerator: 1, timeBaseDenominator: 30000)
        }
        precondition(seconds(start.nextDown) == nil)
        precondition(seconds(start) == end)
        precondition(seconds(0) == end)
        precondition(seconds(end.nextDown) == end)
        precondition(seconds(end) == nil)
        // A real one-tick gap must not disappear at NTSC fractional-frame boundaries.
        precondition(coverage.insert(pts: 1002, duration: 1001))
        precondition(seconds(end) == nil)
        precondition(seconds(1001.5 / 30000.0) == nil)
        precondition(seconds(1002.0 / 30000.0) == 2003.0 / 30000.0)
        precondition(coverage.insert(pts: 1001, duration: 1))
        precondition(seconds(end) == 2003.0 / 30000.0)

        var rational = SoftwarePacketCoverage()
        precondition(rational.insert(pts: 3, duration: 2))
        precondition(rational.frontierSeconds(containing: 3 * 1001.0 / 30000.0,
            timeBaseNumerator: 1001, timeBaseDenominator: 30000) == 5 * 1001.0 / 30000.0)
    }

    static func selectedStreamIntersection() {
        let combine = SoftwarePacketCoverage.combinedFrontier
        precondition(combine(10, 7, true) == 7)
        precondition(combine(7, 10, true) == 7)
        precondition(combine(10, nil, true) == nil)
        precondition(combine(nil, 10, true) == nil)
        precondition(combine(10, nil, false) == 10)
        precondition(combine(10, .nan, false) == 10)
        precondition(combine(10, .nan, true) == nil)
        precondition(combine(.infinity, 10, false) == nil)
        precondition(combine(-1, -2, true) == -2)

        var video = SoftwarePacketCoverage()
        var audio = SoftwarePacketCoverage()
        video.insert(pts: 0, duration: 300300)
        audio.insert(pts: 0, duration: 336000)
        let videoEnd = video.frontierSeconds(containing: 1, timeBaseNumerator: 1, timeBaseDenominator: 30000)
        let audioEnd = audio.frontierSeconds(containing: 1, timeBaseNumerator: 1, timeBaseDenominator: 48000)
        precondition(combine(videoEnd, audioEnd, true) == 7)
    }

    static func resetPruneAndCapacity() {
        var coverage = SoftwarePacketCoverage(maximumRangeCount: 2)
        precondition(coverage.insert(pts: 0, duration: 10))
        precondition(coverage.insert(pts: 20, duration: 10))
        precondition(!coverage.insert(pts: 40, duration: 10))
        precondition(coverage.rangeCount == 2)
        precondition(coverage.frontier(containing: 40) == nil)
        precondition(coverage.frontier(containing: 0) == 10)
        precondition(coverage.frontier(containing: 15) == nil)
        // Joining existing ranges is allowed at capacity, as is extending an existing range.
        precondition(coverage.insert(pts: 10, duration: 10))
        precondition(coverage.rangeCount == 1)
        precondition(coverage.insert(pts: 40, duration: 10))
        precondition(coverage.insert(pts: 50, duration: 10))
        precondition(coverage.rangeCount == 2)
        coverage.prune(before: 5)
        precondition(coverage.frontier(containing: 0) == 30)
        coverage.prune(before: 30)
        precondition(coverage.frontier(containing: 29) == nil)
        precondition(coverage.frontier(containing: 35) == nil)
        precondition(coverage.frontier(containing: 40) == 60)
        coverage.reset()
        precondition(coverage.rangeCount == 0)
        precondition(coverage.frontier(containing: 45) == nil)
        precondition(coverage.insert(pts: 200, duration: 5))
        precondition(coverage.frontier(containing: 45) == nil)
        precondition(coverage.frontier(containing: 200) == 205)

        var sparse = SoftwarePacketCoverage()
        for index in 0..<4096 { precondition(sparse.insert(pts: Int64(index * 2), duration: 1)) }
        precondition(!sparse.insert(pts: 8192, duration: 1))
        precondition(sparse.rangeCount == 4096)
        precondition(sparse.frontier(containing: 1) == nil)
        precondition(sparse.frontier(containing: 8192) == nil)
        sparse.prune(before: 4096)
        precondition(sparse.rangeCount == 2048)
        precondition(sparse.insert(pts: 8192, duration: 1))
    }

    static func malformedAndOverflow() {
        var coverage = SoftwarePacketCoverage()
        precondition(!coverage.insert(pts: .min, duration: 10))
        precondition(!coverage.insert(pts: 0, duration: 0))
        precondition(!coverage.insert(pts: 0, duration: -1))
        precondition(!coverage.insert(pts: .max, duration: 1))
        precondition(!coverage.insert(pts: .max - 1, duration: 2))
        precondition(coverage.rangeCount == 0)
        precondition(coverage.insert(pts: .max - 1, duration: 1))
        precondition(coverage.frontier(containing: .max - 1) == .max)
        precondition(coverage.frontier(containing: .max) == nil)
        precondition(coverage.frontierSeconds(containing: Double(Int64.max - 1),
            timeBaseNumerator: 1, timeBaseDenominator: 1) == nil)
        coverage.reset()
        precondition(coverage.insert(pts: .min + 1, duration: 1))
        precondition(coverage.frontier(containing: .min + 1) == .min + 2)
        precondition(coverage.frontier(containing: .min) == nil)
        coverage.reset()
        coverage.insert(pts: 0, duration: 10)
        for invalid in [Double.nan, .infinity, -.infinity] {
            precondition(coverage.frontierSeconds(containing: invalid,
                timeBaseNumerator: 1, timeBaseDenominator: 30) == nil)
        }
        for invalid: Int32 in [0, -1, .min] {
            precondition(coverage.frontierSeconds(containing: 0,
                timeBaseNumerator: invalid, timeBaseDenominator: 30) == nil)
            precondition(coverage.frontierSeconds(containing: 0,
                timeBaseNumerator: 1, timeBaseDenominator: invalid) == nil)
        }
        coverage.prune(before: .min)
        precondition(coverage.frontier(containing: 0) == 10)
    }

    static func exhaustiveSmallUnion() {
        // Compare interval merging with an independent per-tick union across many insertion
        // orders, including negative timestamps, overlaps and future islands.
        for seed in 0..<32 {
            var coverage = SoftwarePacketCoverage()
            var ticks = Set<Int64>()
            for step in 0..<80 {
                let start = Int64((step * 29 + seed * 13) % 71 - 35)
                let duration = Int64((step * 7 + seed) % 9 + 1)
                precondition(coverage.insert(pts: start, duration: duration))
                for tick in start..<(start + duration) { ticks.insert(tick) }
                for tick: Int64 in -36...45 {
                    var expected: Int64? = nil
                    if ticks.contains(tick) {
                        var end = tick + 1
                        while ticks.contains(end) { end += 1 }
                        expected = end
                    }
                    precondition(coverage.frontier(containing: tick) == expected)
                }
            }
        }
    }
}
