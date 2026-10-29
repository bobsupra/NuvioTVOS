import Testing
import Foundation
@testable import AetherEngine

/// A live session on the software host starts near the newest media once the source's connect burst
/// has landed, instead of at the burst's first packet, where it would run the whole burst behind the
/// broadcast for the rest of the channel.
@Suite("Software live join placement")
struct SoftwareLiveJoinPlacementTests {

    /// A panel that sends 12 s of media in the first half second, then real time: the join waits
    /// for the burst to calm and starts `leadSeconds` behind the newest media.
    @Test("a connect burst is landed before the start is placed behind the newest media")
    func burstIsLandedThenPlaced() throws {
        var policy = SoftwareLiveJoinPolicy()
        let first = 1000.0
        var decision: SoftwareLiveJoinPolicy.Decision?
        var decidedAt: TimeInterval?
        var now: TimeInterval = 0
        while now <= 2, decision == nil {
            // 12 s of media over the first 0.5 s, then one second of media per second.
            let newest = now < 0.5 ? first + 24 * now : first + 12 + (now - 0.5)
            decision = policy.observe(firstPts: first, newestPts: newest, at: now)
            if decision != nil { decidedAt = now }
            now += 0.05
        }
        let at = try #require(decidedAt)
        // Calm is judged from 0.3 s on, over a quarter-second window.
        #expect(at >= 0.3 && at <= 1.0, "decided at \(at)s")
        let newestThen = first + 12 + (at - 0.5)
        #expect(decision == .place(targetPts: newestThen - SoftwareLiveJoinPolicy.leadSeconds))
    }

    @Test("a source that delivers in real time starts from its first packet, soon")
    func realTimeSourceStartsFromTheFirstPacket() throws {
        var policy = SoftwareLiveJoinPolicy()
        let first = 50.0
        var decision: SoftwareLiveJoinPolicy.Decision?
        var decidedAt: TimeInterval?
        var now: TimeInterval = 0
        while now <= 2, decision == nil {
            decision = policy.observe(firstPts: first, newestPts: first + now, at: now)
            if decision != nil { decidedAt = now }
            now += 0.05
        }
        #expect(decision == .fromStart)
        let at = try #require(decidedAt)
        #expect(at >= SoftwareLiveJoinPolicy.minimumSettleSeconds && at <= 0.7, "decided at \(at)s")
    }

    @Test("a burst still landing at the deadline is placed on what has arrived")
    func slowLinkPlacesAtTheDeadline() throws {
        var policy = SoftwareLiveJoinPolicy()
        let first = 0.0
        var decision: SoftwareLiveJoinPolicy.Decision?
        var decidedAt: TimeInterval?
        var now: TimeInterval = 0
        while now <= 3, decision == nil {
            // Six seconds of media per second for as long as it takes: never calm.
            decision = policy.observe(firstPts: first, newestPts: first + 6 * now, at: now)
            if decision != nil { decidedAt = now }
            now += 0.05
        }
        let at = try #require(decidedAt)
        #expect(abs(at - SoftwareLiveJoinPolicy.maximumSettleSeconds) < 0.06, "decided at \(at)s")
        #expect(decision == .place(targetPts: 6 * at - SoftwareLiveJoinPolicy.leadSeconds))
    }

    @Test("a short burst is not worth a later start")
    func shortBurstPlaysFromTheStart() {
        var policy = SoftwareLiveJoinPolicy()
        let first = 10.0
        var decision: SoftwareLiveJoinPolicy.Decision?
        var now: TimeInterval = 0
        while now <= 2, decision == nil {
            // Five seconds of media at once, then real time: a lead of four leaves one to skip.
            decision = policy.observe(firstPts: first, newestPts: first + 5 + now, at: now)
            now += 0.05
        }
        #expect(decision == .fromStart)
    }

    @Test("media whose timestamps run backwards is played from the start")
    func backwardsTimestampsPlayFromTheStart() {
        var policy = SoftwareLiveJoinPolicy()
        var decision: SoftwareLiveJoinPolicy.Decision?
        var now: TimeInterval = 0
        while now <= 2, decision == nil {
            decision = policy.observe(firstPts: 5000, newestPts: 20 + now, at: now)
            now += 0.05
        }
        #expect(decision == .fromStart)
    }

    // MARK: - The resume after an edge rebuffer

    /// The feeder watches a resume with the same rule, from the clock instead of the ring's first
    /// packet: a source that paused and then handed its whole backlog over at once leaves the picture
    /// the length of the pause behind the newest media, so it is moved up the lead behind it.
    @Test("a backlog handed over at once after a pause moves the picture up behind it")
    func backlogAfterAPauseIsCaughtUp() throws {
        var policy = SoftwareLiveJoinPolicy()
        let clock = 35_154.6
        var decision: SoftwareLiveJoinPolicy.Decision?
        var decidedAt: TimeInterval?
        var now: TimeInterval = 0
        while now <= 2, decision == nil {
            // 18 s of backlog over the first 0.4 s, then real time.
            let newest = now < 0.4 ? clock + 2 + 40 * now : clock + 18 + (now - 0.4)
            decision = policy.observe(firstPts: clock, newestPts: newest, at: now)
            if decision != nil { decidedAt = now }
            now += 0.05
        }
        let at = try #require(decidedAt)
        let newestThen = clock + 18 + (at - 0.4)
        #expect(decision == .place(targetPts: newestThen - SoftwareLiveJoinPolicy.leadSeconds))
    }

    /// A source that skipped what it missed comes back a few seconds ahead of the clock: nothing is
    /// worth moving for, and the picture stays where the resume left it.
    @Test("a source that skipped its backlog leaves the picture where it resumed")
    func skippedBacklogStaysPut() {
        var policy = SoftwareLiveJoinPolicy()
        let clock = 35_154.6
        var decision: SoftwareLiveJoinPolicy.Decision?
        var now: TimeInterval = 0
        while now <= 2, decision == nil {
            decision = policy.observe(firstPts: clock, newestPts: clock + 3 + now, at: now)
            now += 0.05
        }
        #expect(decision == .fromStart)
    }

    /// A segmented source resumes on its own up to its cushion plus one unit behind the newest media,
    /// which can pass the join's threshold: 2 x 6 s segments plus a little land 12+ s behind against a
    /// threshold of 12. That is still the edge, so the feeder's catch-up waits for more.
    @Test("an ordinary resume on a segmented source is never caught up",
          arguments: [2.0, 4.0, 6.0, 10.0, 44.0])
    func ordinaryResumeIsNotCaughtUp(unit: Double) throws {
        for cushion in [nil, 3.0, 20.0] {
            let h = SoftwareLiveHoldback(deliveryUnitSeconds: unit, edgeCushionSeconds: cushion)
            let deepestResume = try #require(h.resumeCushionSeconds) + unit
            #expect(deepestResume < h.resumeCatchUpSpanSeconds)
        }
    }

    @Test("a continuous source catches up on the join's own threshold")
    func continuousCatchUpIsTheJoinThreshold() {
        #expect(SoftwareLiveHoldback.continuous.resumeCatchUpSpanSeconds
                == SoftwareLiveJoinPolicy.leadSeconds + SoftwareLiveJoinPolicy.minimumSkipSeconds)
    }
}
