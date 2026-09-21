import Foundation

/// The ladder and the picture order come from @orut34iop's PR #513 measurement: a closed sequence
/// carrying a 25 -> 29.97 transition and its rounding ticks. Those numbers are the fixture here.
@main
struct H264PartialCompositionTests {
    typealias Policy = H264PartialCompositionRepair
    static let slots: [Int64] = [0, 3600, 7200, 10800, 14400, 18000, 21600, 25200, 28800, 32400,
                                 36000, 39600, 42603, 45607, 48610]
    static let pocs: [Int64] = [0, 8, 2, 4, 6, 16, 10, 12, 14, 24, 18, 20, 22, 28, 26]
    static let lead: Int64 = 6006

    /// Feeds the sequence one packet at a time, exactly as the demuxer does, and returns the
    /// presentation times in the order they leave, plus the deepest wait any picture cost.
    static func run(slots: [Int64] = slots, pocs: [Int64] = pocs, lead: Int64 = lead,
                    reorderDepth: Int = 4) -> (times: [Int64], deepestWait: Int, refused: Bool) {
        var ladder = Policy.SlotLadder()
        var queue: [(rank: Int, index: Int)] = []
        var times: [Int64] = []
        var deepest = 0
        for (index, slot) in slots.enumerated() {
            guard ladder.append(dts: slot) else { return (times, deepest, true) }
            queue.append((Int(pocs[index] / 2), index))
            drain: while let first = queue.first {
                switch ladder.claim(rank: first.rank, decodeIndex: first.index, lead: lead, reorderDepth: reorderDepth) {
                case .wait: deepest = max(deepest, queue.count); break drain
                case .refuse: return (times, deepest, true)
                case .time(let pts): times.append(pts); queue.removeFirst()
                }
            }
        }
        return (times, deepest, !queue.isEmpty)
    }

    static func main() {
        let expected = pocs.map { slots[Int($0 / 2)] + lead }
        let plain = run()
        precondition(!plain.refused)
        // Delivery stays in the container's own decode order; only the times move.
        precondition(plain.times == expected)
        precondition(expected.sorted() == slots.map { $0 + lead })
        // A slot is a packet away, never a plan away: the deepest wait is the mini-GOP the
        // reorder created, not the length of the sequence.
        precondition(plain.deepestWait == 3, "deepest wait was \(plain.deepestWait)")
        precondition(slots.count == 15)

        // A far seek moves the whole ladder and nothing else.
        let shifted = run(slots: slots.map { $0 + 63_000_000 })
        precondition(shifted.times == expected.map { $0 + 63_000_000 })

        // A lead too small to cover the reorder would place a picture before its own decode time.
        precondition(run(lead: 3000).refused)
        precondition(run(lead: 0).refused)
        precondition(run(lead: -1).refused)
        // A wait no reorder delay explains is not a wait this policy takes.
        precondition(run(reorderDepth: 2).refused)
        precondition(run(reorderDepth: 3).times == expected)

        // A ladder that does not rise is not a decode ladder.
        var flat = slots; flat[4] = flat[3]
        precondition(run(slots: flat).refused)
        var missing = slots; missing[4] = Int64.min
        precondition(run(slots: missing).refused)

        // Incomplete, field, duplicate and out-of-range picture order.
        for bad: Int64 in [-2, 1, 30, Int64.max] {
            var invalid = pocs; invalid[4] = bad
            precondition(run(pocs: invalid).refused, "poc \(bad) must refuse")
        }
        var duplicate = pocs; duplicate[6] = pocs[2]
        precondition(run(pocs: duplicate).refused)

        // Arithmetic overflow at the top of the axis.
        precondition(run(slots: slots.map { Int64.max - 48610 + $0 }, lead: 6006).refused)

        // A ladder longer than a GOP is not a GOP.
        var long = Policy.SlotLadder()
        for i in 0..<Policy.maximumPictures { precondition(long.append(dts: Int64(i) * 3003)) }
        precondition(!long.append(dts: Int64(Policy.maximumPictures) * 3003))

        print("PASS partial ctts: exact slots across a cadence change, mini-GOP wait depth 3,"
            + " seek translation, unchanged decode axis; insufficient lead, unexplained wait,"
            + " non-rising and missing slots, incomplete/field/duplicate/out-of-range POC,"
            + " overflow and ladder ceiling all refused")
    }
}
