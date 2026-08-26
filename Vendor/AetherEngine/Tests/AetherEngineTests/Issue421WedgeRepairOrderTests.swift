import Testing
import Foundation
@testable import AetherEngine

/// AE#421 (rrgomes): after a restart, a landing waited out 5 s of park detection plus 6 s of
/// re-engage grace, so a seek took 11.94 s on an Apple TV and 15.75 s on a Mac while the producer
/// had already served its first segment about two seconds in.
///
/// The wedge itself is an AVPlayer state (#65 / #93: zero GETs, `waitingToMinimizeStalls` forever,
/// the item never fails) and is not reproducible here; a seek burst under a 120 kbit/s throttle on
/// the loopback path lands every seek. What IS ours is the repair, and both field logs say the same
/// thing about it:
///
/// ```
/// 21:08:52.498 #65 backpressure WEDGE BROKEN head=15 target=5 cacheTarget=4 parked=5s
/// 21:08:52.503 #65 backpressure wedge: re-anchoring producer to 15.00s -> seg3
/// 21:08:58.508 #65 consumer re-engage: no segment fetch for 6s after wedge re-anchor
/// 21:08:58.748 seek#1 programmatic landed rendered=15.00 target=15.00
/// ```
///
/// The producer was at segment 15 and was sent back to segment 3. Through the whole grace window
/// the consumer fetched nothing, so the re-anchor demonstrably changed nothing; the nudge that
/// followed it landed the seek in 240 ms. Same shape on the Mac (`seg35: served ... restarted=true`
/// at +1.9 s, no further GET, nudge at +15.5 s, landed at +15.75 s).
///
/// So the order was wrong, not the repairs. A re-anchor is the fix for a consumer STARVED of
/// content nobody is producing. A consumer silent about a segment that is already on disk is not
/// starved, and re-anchoring throws the pump's forward work away to rebuild what it already has.
/// The nudge goes first in that case, with the re-anchor kept as the fallback if the nudge does not
/// take within the same grace window.
///
/// Deliberately unchanged: the 5 s park detection. Shortening it needs a measurement of what an
/// honest early signal looks like, and a frozen clock is also what a normal seek landing looks like
/// for a moment. What this removes is the 6 s that were being spent on the repair that could not
/// work, which is the half the logs actually indict.
struct Issue421WedgeRepairOrderTests {

    @Test("a consumer silent about a stored segment gets the nudge, not a producer re-anchor")
    func storedTargetNudgesConsumer() {
        // The reporting case: seg3 was long since produced (the pump had marched to seg15).
        #expect(HLSVideoEngine.wedgeRepair(targetStored: true) == .nudgeConsumerFirst)
    }

    @Test("a consumer starved of an unproduced segment still moves the producer")
    func unstoredTargetReanchorsProducer() {
        // The case #65 was opened for: the pump parked ten segments ahead and the target sat
        // outside the producible window, so nothing the consumer does can fetch it.
        #expect(HLSVideoEngine.wedgeRepair(targetStored: false) == .reanchorProducer)
    }

    @Test("the two repairs are distinct, so a log can name which one ran")
    func repairsAreDistinguishable() {
        #expect(HLSVideoEngine.WedgeRepair.nudgeConsumerFirst != HLSVideoEngine.WedgeRepair.reanchorProducer)
    }
}
