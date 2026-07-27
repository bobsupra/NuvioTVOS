import Foundation
import Testing
@testable import AetherEngine

/// #93 retest (rrgomes): a user seek that wedges never lands, so the frozen AVPlayer clock still
/// reports the PRE-seek position (#37 semantics); the stall recovery then nudged/reloaded at that
/// frozen position (391.9 s) instead of the requested target (341.9 s), so the seek was silently
/// lost. The engine now keeps the unlanded seek target as recovery intent: the nudge and the
/// stage-2 reload aim at it. The intent clears when the seek demonstrably lands (rendered near
/// the target) or goes stale (organic playback progress far from the target, meaning AVPlayer
/// abandoned the seek and the user is watching elsewhere).
struct RecoverySeekTargetTests {

    @Test("recovery aims at the pending seek target when one exists")
    func anchorDecision() {
        // rrgomes shape: frozen pre-seek clock 391.9, requested target 341.9. The user's
        // backward seek intent wins even over a rendered clock that ran further ahead.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: 341.9, currentRendered: 400.0) == 341.9)
        // No pending seek, clock frozen: recover in place.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: nil, currentRendered: 391.9) == 391.9)
    }

    @Test("the nudge target is never below the current rendered position (#115)")
    func nudgeNeverRewinds() {
        // #115 shape (dlev02): wedge trips at 391.9, VOD keeps draining buffered segments
        // through the re-engage grace window, on-screen frame is at 400.0 when the nudge
        // fires. Seeking to the pre-grace capture replayed ~8s; the anchor must track the
        // rendered frame instead.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: nil, currentRendered: 400.0) == 400.0)
        // A lagging/zero rendered read must not drag the anchor backward either.
        #expect(AetherEngine.recoveryAnchorPosition(
            frozenPosition: 391.9, pendingSeekTarget: nil, currentRendered: 0.0) == 391.9)
    }

    @Test("a pending target counts as landed once rendered output reaches its neighbourhood")
    func landedDecision() {
        #expect(AetherEngine.pendingSeekLanded(rendered: 341.9, target: 341.9))
        #expect(AetherEngine.pendingSeekLanded(rendered: 344.0, target: 341.9))
        // Frozen at the pre-seek position: not landed.
        #expect(!AetherEngine.pendingSeekLanded(rendered: 391.9, target: 341.9))
    }

    @Test("organic playback progress far from the target marks the intent stale")
    func staleDecision() {
        // A frozen clock accumulates no progress: intent survives the whole wedge.
        #expect(!AetherEngine.isPendingSeekStale(progressWhilePending: 0.0))
        #expect(!AetherEngine.isPendingSeekStale(progressWhilePending: 2.0))
        // AVPlayer abandoned the seek and playback runs elsewhere: drop the intent so a later,
        // unrelated stall cannot teleport to a minutes-old target.
        #expect(AetherEngine.isPendingSeekStale(progressWhilePending: 3.5))
    }

    @Test("deadline recovery restarts a starved producer or one that cannot reach the target")
    func deadlineRestartDecision() {
        #expect(AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: true, targetBeyondProducerCoverage: false))
        // AE#141: a progressing producer whose march cannot reach the pending target must be
        // re-anchored; "healthy at the old position" rode 3x30 s serve timeouts into item death.
        #expect(AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: false, targetBeyondProducerCoverage: true))
        #expect(AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: true, targetBeyondProducerCoverage: true))
        // #129: a healthy march filling toward a reachable target keeps its progress.
        #expect(!AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: false, targetBeyondProducerCoverage: false))
        #expect(AetherEngine.shouldReanchorSubtitlesOnLateSeekLanding(
            alreadyReanchored: false
        ))
        #expect(!AetherEngine.shouldReanchorSubtitlesOnLateSeekLanding(
            alreadyReanchored: true
        ))
    }

    @Test("an extension needs a growing island at the target, budget, and producer coverage")
    func extendSeekDeadlineDecision() {
        let floor = 1.0
        let maxExt = 4
        // DV/SMB slow forward seek: 4s already served AT the target, no earlier sample to compare
        // against (first extension) -> extend instead of running the harmful recovery.
        #expect(AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 4.0, previousIslandSeconds: nil, extensionsUsed: 0,
            maxExtensions: maxExt, islandFloor: floor, targetBeyondProducerCoverage: false))
        // Still filling on a later extension (4.0 -> 6.4) -> keep extending.
        #expect(AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 6.4, previousIslandSeconds: 4.0, extensionsUsed: 3,
            maxExtensions: maxExt, islandFloor: floor, targetBeyondProducerCoverage: false))
        // STATIC island: the producer served 4s and then died. Presence alone must not buy the rest of
        // the budget -- without the growth rule this waits 16s on a dead producer.
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 4.0, previousIslandSeconds: 4.0, extensionsUsed: 1,
            maxExtensions: maxExt, islandFloor: floor, targetBeyondProducerCoverage: false))
        // Growth below the epsilon is noise, not progress.
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 4.1, previousIslandSeconds: 4.0, extensionsUsed: 1,
            maxExtensions: maxExt, islandFloor: floor, targetBeyondProducerCoverage: false))
        // AE#141 veto: a target the producer's march cannot reach must never be extended, however
        // healthy the buffer at the target looks -- it rides serve timeouts into item death.
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 6.4, previousIslandSeconds: nil, extensionsUsed: 0,
            maxExtensions: maxExt, islandFloor: floor, targetBeyondProducerCoverage: true))
        // True wedge: nothing served at the target -> do NOT extend, fall through to recovery.
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 0.0, previousIslandSeconds: nil, extensionsUsed: 0,
            maxExtensions: maxExt, islandFloor: floor, targetBeyondProducerCoverage: false))
        // Sub-floor sliver is not convincing progress.
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 0.5, previousIslandSeconds: nil, extensionsUsed: 0,
            maxExtensions: maxExt, islandFloor: floor, targetBeyondProducerCoverage: false))
        // Budget exhausted even with a healthy, growing island -> stop, bound the total wait.
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 9.0, previousIslandSeconds: 6.4, extensionsUsed: 4,
            maxExtensions: maxExt, islandFloor: floor, targetBeyondProducerCoverage: false))
        // Exactly at the floor, first sample, counts as progress.
        #expect(AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 1.0, previousIslandSeconds: nil, extensionsUsed: 0,
            maxExtensions: maxExt, islandFloor: floor, targetBeyondProducerCoverage: false))
    }

    @Test("the device-trace forward seek extends while the target island fills, then lands not wedges")
    @MainActor
    func deviceTraceForwardSeekPrefersExtension() {
        // Reconstruct the failing repro at deadline (build 2017 trace): rendered==buffered==old playhead,
        // so the contiguous-only metric reads starved, but the producer was serving the TARGET, the island
        // there growing 0.55 -> 4.0 -> 6.4s. The engine must EXTEND, not run the harmful recovery.
        #expect(AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 4.0, previousIslandSeconds: 0.55, extensionsUsed: 1,
            maxExtensions: AetherEngine.nativeSeekMaxDeadlineExtensions,
            islandFloor: AetherEngine.nativeSeekProgressIslandFloorSeconds,
            targetBeyondProducerCoverage: false))
        #expect(AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 6.4, previousIslandSeconds: 4.0, extensionsUsed: 2,
            maxExtensions: AetherEngine.nativeSeekMaxDeadlineExtensions,
            islandFloor: AetherEngine.nativeSeekProgressIslandFloorSeconds,
            targetBeyondProducerCoverage: false))

        // Contrast: a genuinely wedged seek (producer never served the target) must NOT be kept alive by
        // endless extensions, it falls through to recovery + re-anchor.
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 0.0, previousIslandSeconds: nil, extensionsUsed: 0,
            maxExtensions: AetherEngine.nativeSeekMaxDeadlineExtensions,
            islandFloor: AetherEngine.nativeSeekProgressIslandFloorSeconds,
            targetBeyondProducerCoverage: false))
    }

    @Test("the device-trace backward-into-unbuffered seek does not extend and re-anchors, holding at target")
    @MainActor
    func deviceTraceBackwardSeekReanchorsAndHoldsAtTarget() {
        // Reconstruct SEEK 3 (c5f3cd5 trace): BACK 2643.20 -> 741.78 into unbuffered content, at deadline
        // rendered==buffered==2643.50 (AVPlayer drained to its buffer edge at the old position). Nothing is
        // buffered at the backward target, so the island there is 0 and the engine must NOT extend; it
        // falls through to recovery. (The old-position buffer cannot masquerade as the island: the
        // measurement window is bounded above at target + window, far below 2643.)
        #expect(!AetherEngine.shouldExtendSeekDeadlineForProgress(
            targetIslandSeconds: 0.0, previousIslandSeconds: nil, extensionsUsed: 0,
            maxExtensions: AetherEngine.nativeSeekMaxDeadlineExtensions,
            islandFloor: AetherEngine.nativeSeekProgressIslandFloorSeconds,
            targetBeyondProducerCoverage: false))

        // buffered == rendered => no forward buffer => genuinely starved (unlike the forward-island case
        // where the metric misreads a slow-but-working seek as starved).
        let starved = seekIsWedged(renderedTime: 2643.50, bufferedEnd: 2643.50)
        #expect(starved)
        // A starved deadline MUST re-anchor the producer regardless of the producer-coverage read
        // (AE#141), so the segments the target needs get produced.
        #expect(AetherEngine.shouldReanchorProducerAfterSeekDeadline(
            isStarved: starved, targetBeyondProducerCoverage: false))

        // The recovery re-anchor drives the producer to the TARGET (not the frozen old position), so the
        // held clock and the producer converge on 741.78 rather than reverting to 2643.50.
        let anchor = AetherEngine.recoveryAnchorPosition(
            frozenPosition: 2643.50, pendingSeekTarget: 741.78, currentRendered: 2643.50)
        #expect(anchor == 741.78)
    }

    @Test("a forward overshoot landing is accepted, never re-seeked backward")
    func forwardOvershootLandingAccepted() {
        // Device SEEK (83e705e trace, target=1288.14): AVPlayer landed and kept PLAYING past the
        // zero-tolerance target, so at the deadline rendered=1289.70 (1.56s past target). The old
        // abs(rendered-target) <= 0.75 rejected this as "not landed" and re-seeked backward to 1288.14,
        // yanking a playing playhead back and re-stalling it. A forward overshoot must read as LANDED.
        #expect(AetherEngine.seekLandedAtTarget(rendered: 1289.70, target: 1288.14, forward: true))
        // A generous overshoot (a full GOP past) is still landed for a forward seek.
        #expect(AetherEngine.seekLandedAtTarget(rendered: 1293.00, target: 1288.14, forward: true))
        // Exact / near-exact landing is landed either direction.
        #expect(AetherEngine.seekLandedAtTarget(rendered: 1288.14, target: 1288.14, forward: true))

        // Pre-landing: a forward seek's playhead is pinned far BELOW the target (old position). Must NOT
        // read as landed, so the extend/recovery logic still runs.
        #expect(!AetherEngine.seekLandedAtTarget(rendered: 445.30, target: 1288.14, forward: true))

        // Backward seek: the pinned pre-seek playhead sits far ABOVE the target (old position 2643.50 vs
        // target 741.78) and must NOT be mistaken for a landing (that was the false-positive risk of a
        // one-sided "rendered >= target" rule).
        #expect(!AetherEngine.seekLandedAtTarget(rendered: 2643.50, target: 741.78, forward: false))
        // A backward seek that reached the target (or a hair past it, playing forward) is landed.
        #expect(AetherEngine.seekLandedAtTarget(rendered: 741.78, target: 741.78, forward: false))
        #expect(AetherEngine.seekLandedAtTarget(rendered: 742.40, target: 741.78, forward: false))
    }

    @Test("a near backward seek does not count the abandoned playhead's buffer as progress at the target")
    func targetIslandExcludesOldPlayheadBuffer() {
        // Backward seek 1200 -> 1185 (15 s, inside the 30 s measurement window) into unbuffered content.
        // AVPlayer still holds a full forward buffer at the abandoned playhead: 1200 -> 1230.
        let oldPlayheadBuffer = [(start: 1200.0, end: 1230.0)]
        // Without the exclusion bound the old buffer sits inside [1184, 1215] and reads as 15 s of
        // "media served at the target" -- the producer served none of it, and the seek would be granted
        // an extension while the recovery it needs is deferred.
        #expect(NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: oldPlayheadBuffer, target: 1185.0) == 15.0)
        // Excluding at the frozen playhead reports the truth: nothing at the target.
        #expect(NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: oldPlayheadBuffer, target: 1185.0, excludeAtOrAbove: 1200.0) == 0.0)

        // A far backward seek was already clear of it via the window alone; the bound must not change that.
        #expect(NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: [(start: 2643.0, end: 2673.0)], target: 741.78, excludeAtOrAbove: 2643.5) == 0.0)

        // Genuine progress at a backward target still counts, up to the exclusion bound.
        #expect(NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: [(start: 1185.0, end: 1191.0), (start: 1200.0, end: 1230.0)],
            target: 1185.0, excludeAtOrAbove: 1200.0) == 6.0)

        // Forward seek (no bound passed): the disjoint island at the target is what gets measured, and
        // the pre-seek playhead's own buffer is far below the window rather than inside it.
        let forwardIsland = NativeAVPlayerHost.bufferedSecondsInWindow(
            ranges: [(start: 440.0, end: 450.0), (start: 1288.0, end: 1294.4)], target: 1288.14)
        #expect(abs(forwardIsland - 6.4) < 0.001)
    }

    @Test("the sink's landing predicate is looser than the loop's, so the loop must not own the finalize")
    func sinkAndLoopLandingPredicatesDiverge() {
        // Regression anchor for the `programmaticSeekInFlight` guard in the deadline loop. The two
        // landing tests deliberately disagree: the $renderedTime sink accepts anything within +-5 s of
        // the target (symmetric), the loop's poll wants +-0.75 s on the near side. A landing 3 s short
        // of a forward target therefore finalizes through the sink while the loop still reads "pending".
        let target = 1288.14
        let short = target - 3.0
        #expect(AetherEngine.pendingSeekLanded(rendered: short, target: target))
        #expect(!AetherEngine.seekLandedAtTarget(rendered: short, target: target, forward: true))
        // Without the guard the loop would go on to re-anchor the producer and re-seek backward onto an
        // item the sink has already reported as landed and playing -- the yank `seekLandedAtTarget`
        // exists to prevent, reintroduced through the back door.
    }

    @Test("a published completion is the authoritative deadline catch-up signal")
    func completionPublicationDecision() {
        #expect(AetherEngine.shouldCatchUpDeadlineLanding(renderedTimePublished: true))
        #expect(!AetherEngine.shouldCatchUpDeadlineLanding(renderedTimePublished: false))
    }

    @Test("a short seek needs rendered movement or completion evidence")
    func shortSeekLandingEvidence() {
        #expect(!AetherEngine.pendingSeekHasRenderedLandingEvidence(
            rendered: 40,
            target: 43,
            initialRendered: 40,
            completionRenderedTimePublished: false
        ))
        #expect(AetherEngine.pendingSeekHasRenderedLandingEvidence(
            rendered: 43,
            target: 43,
            initialRendered: 40,
            completionRenderedTimePublished: false
        ))
        #expect(AetherEngine.pendingSeekHasRenderedLandingEvidence(
            rendered: 40,
            target: 43,
            initialRendered: 40,
            completionRenderedTimePublished: true
        ))
    }

    @MainActor
    @Test("starting or clearing a recovery target resets deadline lifecycle state")
    func targetLifecycleReset() throws {
        let engine = try AetherEngine()
        engine.setPendingRecoverySeekTarget(42)
        engine.pendingRecoverySeekDeadlineExpired = true
        engine.pendingRecoverySeekSubtitlesReanchored = true

        // A superseding seek to the same target is still a new lifecycle.
        engine.setPendingRecoverySeekTarget(42)
        #expect(!engine.pendingRecoverySeekDeadlineExpired)
        #expect(!engine.pendingRecoverySeekSubtitlesReanchored)

        engine.pendingRecoverySeekDeadlineExpired = true
        engine.pendingRecoverySeekSubtitlesReanchored = true
        engine.setPendingRecoverySeekTarget(nil)
        #expect(!engine.pendingRecoverySeekDeadlineExpired)
        #expect(!engine.pendingRecoverySeekSubtitlesReanchored)
    }

    @Test("seek recovery reasserts only pauses covered by the bounded recovery policy")
    func recoveredStateDecision() {
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: false,
            statusIsPaused: false,
            shouldReassertPausedStatus: true
        ) == .playing)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: false,
            statusIsPaused: true,
            shouldReassertPausedStatus: true
        ) == .paused)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: true,
            statusIsPaused: true,
            shouldReassertPausedStatus: false
        ) == .paused)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: true,
            statusIsPaused: true,
            shouldReassertPausedStatus: true
        ) == .playing)
        #expect(AetherEngine.seekRecoveredState(
            transportIntentIsPlaying: true,
            statusIsPaused: false,
            shouldReassertPausedStatus: false
        ) == .playing)
    }
}
