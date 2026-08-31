import Testing
import Foundation
@testable import AetherEngine

/// AE#445 round 3: the census named ONE growing block, and the question left over was whose it was.
///
/// The answer turned out to be readable off the block itself. Every allocator family grows a large
/// buffer by its own fixed factor, so the ratio between two consecutive census walks identifies the
/// family without a symbol, a stack or a rebuild: Foundation's `Data` adds a quarter, FFmpeg's AVIO
/// dynamic buffer a half, `av_fast_realloc` a sixteenth, Swift's `Array` doubles. The reporter's
/// ladder measured 1.2500 to 1.2502 across nine steps, which is `Data` and nothing else.
///
/// Serialized: the trackers and the census are process-wide, and Swift Testing runs cases in parallel.
@Suite(.serialized)
struct Issue445GrowthLadderTests {

    /// The reporter's own `bigExact` column, verbatim. A fixture that encodes the case is the only
    /// kind that can fail for the reason it was written.
    static let reporterLadder = [
        117_981_184, 184_385_536, 230_506_496, 288_178_176, 360_251_392, 450_330_624,
        562_921_472, 703_660_032, 879_591_424, 1_099_530_240, 1_374_486_528,
    ]

    @Test("the reporter's ladder classifies as Foundation Data at every step")
    func reporterLadderIsData() {
        for (previous, current) in zip(Self.reporterLadder, Self.reporterLadder.dropFirst()) {
            let step = MallocBlockCensus.growthFamily(previousBytes: previous, currentBytes: current)
            #expect(step?.family == "Data",
                    "\(previous) -> \(current) classified as \(step?.family ?? "nil")")
        }
    }

    @Test("several rungs between two walks still name the same family")
    func multipleRungsClassify() {
        // 1.25^2 and 1.25^3: the reporter's first gap spanned two steps, a slower sampler spans more.
        #expect(MallocBlockCensus.growthFamily(previousBytes: 100_000_000, currentBytes: 156_250_000)?.family == "Data")
        #expect(MallocBlockCensus.growthFamily(previousBytes: 100_000_000, currentBytes: 195_312_500)?.family == "Data")
    }

    @Test("the other families are told apart, and an unknown ratio is not rounded into one")
    func familiesAreDistinct() {
        #expect(MallocBlockCensus.growthFamily(previousBytes: 100_000_000, currentBytes: 150_000_000)?.family == "dyn_buf")
        #expect(MallocBlockCensus.growthFamily(previousBytes: 100_000_000, currentBytes: 200_000_000)?.family == "Array")
        #expect(MallocBlockCensus.growthFamily(previousBytes: 100_000_000, currentBytes: 106_250_000)?.family == "av_fast_realloc")
        let odd = MallocBlockCensus.growthFamily(previousBytes: 100_000_000, currentBytes: 137_000_000)
        #expect(odd?.family == nil, "an unrecognised ratio must stay unlabelled, got \(odd?.family ?? "nil")")
        #expect(odd?.ratio == 1.37)
    }

    @Test("a block that did not grow reports flat rather than nothing")
    func flatIsStated() {
        #expect(MallocBlockCensus.growthFamily(previousBytes: 100_000_000, currentBytes: 100_000_000) == nil)
        let tracker = MallocBlockCensus.GrowthTracker()
        #expect(tracker.fragment(largest: 100_000_000) == "bigGrowth=flat ")
        #expect(tracker.fragment(largest: 125_000_000).contains("(Data)"))
        #expect(tracker.fragment(largest: 125_000_000) == "bigGrowth=flat ")
    }

    @Test("two trackers do not report each other's interval")
    func trackersAreIndependent() {
        let memprobe = MallocBlockCensus.GrowthTracker()
        let trigger = MallocBlockCensus.GrowthTracker()
        _ = memprobe.fragment(largest: 100_000_000)
        _ = trigger.fragment(largest: 100_000_000)
        _ = memprobe.fragment(largest: 125_000_000)
        // The trigger's own step is still 1.25x from ITS last read, not 1.0 from the memprobe's.
        #expect(trigger.fragment(largest: 125_000_000).contains("(Data)"))
    }

    /// The mechanism itself, not a table of numbers: a parse carry consumed from the front with
    /// `removeFirst` keeps its `count` under one TS packet while its slice's lower bound, and with it
    /// the backing allocation, tracks every byte ever appended. `subdata` re-bases and stays flat.
    /// The engine paid for this twice (70430de on AVIOReader's window, ByteFIFO's consume) and both
    /// sites re-base; this test keeps the trap itself on file, because a `count` that stays small is
    /// what makes the leak invisible to the host that owns it.
    @Test("a front-consumed Data carry keeps count bounded and its backing store unbounded")
    func removeFirstCarryRidesItsBackingStore() {
        let chunk = Data(repeating: 0xAB, count: 64 * 1024)
        var leaking = Data()
        var rebased = Data()
        var appended = 0
        for _ in 0..<512 {
            leaking.append(chunk)
            rebased.append(chunk)
            appended += chunk.count
            let consumable = (leaking.count / 188) * 188
            if consumable > 0 {
                leaking.removeFirst(consumable)
                rebased = rebased.subdata(in: consumable..<rebased.count)
            }
        }
        #expect(leaking.count < 188, "the carry's length is bounded by construction")
        #expect(rebased.count == leaking.count)
        #expect(leaking.startIndex >= appended - 188,
                "the slice's lower bound must track the consumed stream, saw \(leaking.startIndex) of \(appended)")
        #expect(rebased.startIndex == 0, "a re-based carry starts at 0, saw \(rebased.startIndex)")
    }

    /// And the census sees it: pushed far enough, the leaking carry IS the largest live block, and
    /// consecutive census reads of it land on the Data rung. This is the reporter's line reproduced
    /// end to end in-process, with no engine involved.
    @Test("the leaking carry shows up as one growing block on the Data ladder")
    func leakingCarryIsVisibleToTheCensus() {
        MallocBlockCensus.isEnabled = true
        defer { MallocBlockCensus.isEnabled = false }

        let chunk = Data(repeating: 0xCD, count: 256 * 1024)
        var carry = Data()
        var sizes: [Int] = []
        for i in 0..<1536 {                       // 384 MB through a carry that stays under a packet
            carry.append(chunk)
            let consumable = (carry.count / 188) * 188
            if consumable > 0 { carry.removeFirst(consumable) }
            if i % 256 == 255, let largest = MallocBlockCensus.census()?.largest.first {
                sizes.append(largest)
            }
        }
        #expect(carry.count < 188)
        #expect((sizes.last ?? 0) >= 256 << 20,
                "the carry should dominate the heap after 384 MB, largest was \((sizes.last ?? 0) >> 20) MB")
        let families = zip(sizes, sizes.dropFirst()).compactMap {
            MallocBlockCensus.growthFamily(previousBytes: $0, currentBytes: $1)?.family
        }
        #expect(families.contains("Data"),
                "expected a Data rung across \(sizes.map { $0 >> 20 }) MB, classified \(families)")
    }
}
