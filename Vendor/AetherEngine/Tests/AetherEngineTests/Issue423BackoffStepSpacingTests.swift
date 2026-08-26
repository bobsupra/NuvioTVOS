import Testing
import Foundation
@testable import AetherEngine

/// AE#423: a re-aimed gate opened on the first sync sample at or above where it aimed, and the
/// doubling backoff aimed past the sample that would have covered the boundary.
///
/// Found while measuring AE#418 and only visible once the clock stopped hiding it: until the axis
/// was published honestly, the landing claimed the target either way. Measured on `tc-cues-lie.mkv`
/// (sync samples at 38.417 and 43.0, then a drought to 55.0), resuming at 53 s with the boundary at
/// 52.0:
///
/// ```
/// before   aims 48.0, 44.0, 36.0   gate opens 38.417   presentedShift=-13583
/// after    aims 48.0, 44.0, 40.0   gate opens 43.000   presentedShift=-9000
/// ```
///
/// Three attempts either way; the doubling step simply jumped over the 43.0 sitting between 36.0 and
/// the boundary. `seektest` settles the same improvement from the seek side: `settleError` 8.38 s
/// before, 3.80 s after, same burst and same throttle. The control fixture, whose Cues ARE its sync
/// samples, re-aims zero times on both arms and reads `axisErr=+0.000` throughout.
///
/// The reason even steps are affordable is `gateProvenEmptyFromPts`: it stops each scan at the
/// PREVIOUS aim rather than at the boundary, so an attempt reads its own window and the walk costs
/// the same whether the list doubles or not. A doubling list buys reach that the last entry already
/// provides, and pays for it in the one place the accuracy comes from.
struct Issue423BackoffStepSpacingTests {

    private static var steps: [Double] { HLSSegmentProducer.gateBackoffStepsSeconds }

    @Test("no gap between attempts exceeds the first step, because a gap IS the worst-case overshoot")
    func gapsNeverExceedTheFirstStep() {
        // Each attempt opens on the first sync sample at or above its aim, and everything above the
        // previous aim is already proven empty, so the distance between two aims bounds how far past
        // the best covering sample the gate can open. The old list had gaps of 4, 8 and 16.
        let steps = Self.steps
        #expect(steps.count >= 2)
        let first = steps[0]
        for (a, b) in zip(steps, steps.dropFirst()) {
            #expect(b - a <= first, "gap \(a) -> \(b) is wider than the first step \(first)")
        }
    }

    @Test("the steps stay ordered and start close to the boundary")
    func stepsAreOrderedAndStartShort() {
        let steps = Self.steps
        #expect(steps == steps.sorted())
        #expect(steps.allSatisfy { $0 > 0 })
        // The near case is what most sources are: one GOP short of the boundary.
        #expect(steps[0] <= 4)
    }

    @Test("reach is unchanged, so no source that used to be recoverable stops being one")
    func reachIsPreserved() {
        #expect(Self.steps.last == 32)
    }

    @Test("the fixture's drought is walked without stepping over its covering sample")
    func fixtureGeometryIsCovered() {
        // Boundary 52.0 with the last covering sync sample at 43.0: some aim must land in
        // (38.417, 43.0] so that the first sample at or above it is 43.0 rather than 38.417.
        let boundary = 52.0
        let aims = Self.steps.map { boundary - $0 }
        #expect(aims.contains { $0 > 38.417 && $0 <= 43.0 })
    }
}
