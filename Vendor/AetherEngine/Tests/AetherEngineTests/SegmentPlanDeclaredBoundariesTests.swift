// Segment plan built from a segmented source's OWN boundaries (AE#268).
//
// The reporter's source is a finite HEVC-in-MPEG-TS HLS VOD: 10 s segments, one I-frame per segment,
// PTS origin 1.48 s. Its keyframe index is sparse (MPEG-TS carries no upfront table), so the plan fell
// back to the uniform 4 s stride, which advertises boundaries no keyframe sits on: only every fifth
// grid boundary coincided with an IRAP. A restart at any other index made the producer's scan-forward
// gate open up to 8 s (two whole plan segments) late, every downstream index mapping skewed by that
// overshoot, and AVPlayer starved on a segment that never arrived (CoreMediaErrorDomain -12889). The
// seek that passed on device (122.000 s -> plan index 30 -> 120 s, a multiple of both 4 and 10) was
// exactly the one-in-five aligned case.
import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

@Suite("Segment plan from source-declared boundaries (AE#268)")
struct SegmentPlanDeclaredBoundariesTests {

    private let ts90k = AVRational(num: 1, den: 90_000)

    /// 1.48 s PTS origin, the reporter's (and ffmpeg's default) MPEG-TS start.
    private let anchor: Int64 = Int64(1.48 * 90_000)

    /// 120 x 10 s starts, the fixture that reproduces the report.
    private var tenSecondStarts: [Double] { (0..<120).map { Double($0) * 10 } }

    /// Every I-frame of a 10 s-GOP source, in source PTS.
    private func irapsEvery10s(count: Int) -> [Int64] {
        (0..<count).map { anchor + Int64(Double($0) * 10 * 90_000) }
    }

    /// The property the whole fix rests on: for every advertised boundary, the first IRAP at-or-after
    /// it must still fall inside that segment. Where it does not, the producer's gate opens in a LATER
    /// segment than the one the restart was aimed at.
    private func firstIRAPStaysInsideItsSegment(plan: [HLSVideoEngine.Segment], iraps: [Int64]) -> Bool {
        for (i, segment) in plan.enumerated() where i + 1 < plan.count {
            guard let firstAtOrAfter = iraps.first(where: { $0 >= segment.startPts }) else { continue }
            if firstAtOrAfter >= plan[i + 1].startPts { return false }
        }
        return true
    }

    @Test("Declared boundaries keep every segment's own IRAP inside it")
    func declaredBoundariesAreProducible() {
        let plan = HLSVideoEngine.buildSegmentedSourcePlan(
            segmentStartsSeconds: tenSecondStarts,
            videoTimeBase: ts90k,
            sourceDurationSeconds: 1200,
            startPts0: anchor
        )
        #expect(plan.count == 120)
        #expect(firstIRAPStaysInsideItsSegment(plan: plan, iraps: irapsEvery10s(count: 120)))
    }

    @Test("The uniform 4 s grid does not: that is the reported defect")
    func uniformGridStrandsMostBoundaries() {
        // Same source, the pre-fix plan. Four boundaries in five have their IRAP in a later segment,
        // which is what a restart at those indices runs into.
        let plan = HLSVideoEngine.buildUniformSegmentPlan(
            videoTimeBase: ts90k,
            sourceDurationSeconds: 1200,
            startPts0: anchor
        )
        #expect(plan.count == 300)
        #expect(firstIRAPStaysInsideItsSegment(plan: plan, iraps: irapsEvery10s(count: 120)) == false)
    }

    @Test("The item axis stays the manifest's own: startSeconds are the EXTINF sums")
    func itemAxisMatchesTheManifest() {
        let plan = HLSVideoEngine.buildSegmentedSourcePlan(
            segmentStartsSeconds: tenSecondStarts,
            videoTimeBase: ts90k,
            sourceDurationSeconds: 1200,
            startPts0: anchor
        )
        #expect(plan[0].startSeconds == 0)
        #expect(plan[63].startSeconds == 630)
        #expect(plan[63].durationSeconds == 10)
        #expect(plan.last?.startSeconds == 1190)
    }

    @Test("Boundaries are backed off below their IRAP, never past the previous one")
    func boundariesBackOffBelowTheirIRAP() {
        let plan = HLSVideoEngine.buildSegmentedSourcePlan(
            segmentStartsSeconds: tenSecondStarts,
            videoTimeBase: ts90k,
            sourceDurationSeconds: 1200,
            startPts0: anchor
        )
        let backoff = HLSVideoEngine.segmentedPlanBoundaryBackoff(shortestSegmentSeconds: 10)
        #expect(backoff == 0.5)
        // Segment 0 keeps the content start itself; every later boundary sits `backoff` below its IRAP.
        #expect(plan[0].startPts == anchor)
        for i in [1, 2, 63, 119] {
            let irap = anchor + Int64(plan[i].startSeconds * 90_000)
            #expect(plan[i].startPts == irap - Int64(backoff * 90_000))
            #expect(plan[i].startPts > anchor + Int64((plan[i].startSeconds - 10) * 90_000))
        }
    }

    @Test("Short segments cap the backoff below half a segment")
    func shortSegmentsCapTheBackoff() {
        #expect(HLSVideoEngine.segmentedPlanBoundaryBackoff(shortestSegmentSeconds: 0.4) == 0.2)
        #expect(HLSVideoEngine.segmentedPlanBoundaryBackoff(shortestSegmentSeconds: 0) == 0)
        let plan = HLSVideoEngine.buildSegmentedSourcePlan(
            segmentStartsSeconds: [0, 0.4, 0.8, 1.2],
            videoTimeBase: ts90k,
            sourceDurationSeconds: 1.6,
            startPts0: anchor
        )
        #expect(plan.count == 4)
        // A backed-off boundary must stay strictly above the previous segment's start, or a restart
        // would open on the previous segment's IRAP.
        for i in 1..<plan.count {
            #expect(plan[i].startPts > anchor + Int64(plan[i - 1].startSeconds * 90_000))
        }
    }

    @Test("A manifest that cannot be trusted leaves the source on the existing builders")
    func rejectsUnusableManifests() {
        // Fewer than two starts, a non-zero first start, and a non-monotonic list all return empty so
        // the caller falls through to the keyframe / uniform plan.
        #expect(HLSVideoEngine.buildSegmentedSourcePlan(
            segmentStartsSeconds: [0], videoTimeBase: ts90k,
            sourceDurationSeconds: 100, startPts0: anchor).isEmpty)
        #expect(HLSVideoEngine.buildSegmentedSourcePlan(
            segmentStartsSeconds: [10, 20], videoTimeBase: ts90k,
            sourceDurationSeconds: 100, startPts0: anchor).isEmpty)
        #expect(HLSVideoEngine.buildSegmentedSourcePlan(
            segmentStartsSeconds: [0, 10, 10], videoTimeBase: ts90k,
            sourceDurationSeconds: 100, startPts0: anchor).isEmpty)
        #expect(HLSVideoEngine.buildSegmentedSourcePlan(
            segmentStartsSeconds: [0, 10, 20], videoTimeBase: ts90k,
            sourceDurationSeconds: 0, startPts0: anchor).isEmpty)
    }

    @Test("A trailing short segment keeps its own EXTINF, and the plan spans the source")
    func trailingSegmentIsPreserved() {
        // The reporter's playlist ends on an 8.76 s segment.
        var starts = (0..<270).map { Double($0) * 10 }
        starts[269] = 2690
        let plan = HLSVideoEngine.buildSegmentedSourcePlan(
            segmentStartsSeconds: starts,
            videoTimeBase: ts90k,
            sourceDurationSeconds: 2698.76,
            startPts0: anchor
        )
        #expect(plan.count == 270)
        #expect(abs((plan.last?.durationSeconds ?? 0) - 8.76) < 0.001)
        let spanned = (plan.last?.startSeconds ?? 0) + (plan.last?.durationSeconds ?? 0)
        #expect(abs(spanned - 2698.76) < 0.001)
    }
}
