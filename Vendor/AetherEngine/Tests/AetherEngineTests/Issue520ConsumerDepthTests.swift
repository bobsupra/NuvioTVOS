import Foundation
import Testing
@testable import AetherEngine

/// AE#520 round 2: the outage close spends a depth, and it could only see half of one.
///
/// The runway it measured is the content the window LISTS above the consumer's fetch point, which
/// leaves out everything the consumer has already fetched and still holds. For a viewer at the live
/// edge that half is most of what they have: measured on the harness at TARGETDURATION 6, the window
/// closed with 4.0 s listed while AVPlayer held another 4.9 s, so a decision that read 4.0 s was taken
/// on a consumer that could play for 8.9 s, and the source delivered again 1.84 s later.
///
///     [+70.51s] the source stopped delivering ... 4.0s of runway left, at or under the 6.0s the
///               close itself needs to reach the consumer
///     [+72.35s] live seg-22 finalized
///
/// Deferring costs nothing in the seam it was avoiding, because the swap does not happen when the
/// ENDLIST is served: it happens when the consumer reaches the end of the closed window
/// (`didPlayToEndTime`), which is the same instant whenever the decision was taken. Measured in the
/// same run: closed at +70.51, swapped at +89.5 with 0.79 s of buffer left.
@Suite("AE#520 round 2 the close spends what the consumer can still play")
struct Issue520ConsumerDepthTests {

    /// 4 s segments seal TARGETDURATION 6, so the close needs 6.0 s in front of the consumer.
    private func makeLiveProvider(segments segmentCount: Int, buffered: Double?)
        -> (provider: VideoSegmentProvider, cache: SegmentCache) {
        let cache = SegmentCache(forwardWindow: 40, backwardWindow: 40)
        let provider = VideoSegmentProvider(
            cache: cache,
            segments: [],
            codecsString: "avc1.640029,mp4a.40.2",
            supplementalCodecs: nil,
            resolution: (1920, 1080),
            videoRange: .sdr,
            frameRate: 25,
            hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            isLive: true,
            liveWindowSizing: LiveWindowSizing(targetSegmentDurationSeconds: 4.0,
                                               dvrWindowSeconds: 1800)
        )
        if let buffered { provider.consumerBufferedSecondsProvider = { buffered } }
        for i in 0..<segmentCount {
            provider.appendLiveSegment(index: i, startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
        #expect(provider.liveTargetDurationSeconds(maxSegmentDuration: 4.0) == 6)
        return (provider, cache)
    }

    /// The field shape, as the provider sees it: one segment listed, one already in hand.
    @Test("a consumer the window has run out of content for can still be carried by its own buffer")
    func theBufferCarriesTheWait() {
        let (provider, cache) = makeLiveProvider(segments: 20, buffered: 4.9)
        cache.declareTarget(18) // 1 segment / 4.0 s listed, under the 6.0 s reserve on its own
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 13.1) // late, as measured

        // 4.0 + 4.9 = 8.9 s of playable depth, so the decision that used to close here does not.
        #expect(!provider.liveOutageEndlist)
        #expect(!provider.liveOutageEndlistLatched)
    }

    @Test("the same consumer with an empty buffer is closed on exactly as before")
    func anEmptyBufferIsTheOldReading() {
        let (provider, cache) = makeLiveProvider(segments: 20, buffered: 0)
        cache.declareTarget(18)
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 13.1)

        #expect(provider.liveOutageEndlist)
    }

    /// The software path mounts no item, so nothing can report a depth. The close then reads what it
    /// always read, rather than treating "nobody answered" as "the consumer has nothing".
    @Test("no reading at all is the old behaviour, not a zero")
    func noReadingIsTheOldBehaviour() {
        let (withNone, noneCache) = makeLiveProvider(segments: 20, buffered: nil)
        noneCache.declareTarget(18)
        withNone.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 13.1)
        #expect(withNone.liveOutageEndlist)

        let (deep, deepCache) = makeLiveProvider(segments: 20, buffered: nil)
        deepCache.declareTarget(2) // 68 s listed: closed on by nothing but the ceiling
        deep.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 13.1)
        #expect(!deep.liveOutageEndlist)
    }

    /// A consumer that has fetched the whole window and is playing out of its own buffer. Nothing is
    /// listed above its fetch point, so the reading the close used to take is exactly zero, and the
    /// gate that asked for listed segments refused to close at all: measured on the harness, an edge
    /// viewer against a 30 s freeze walked down to 0.1 s that way and then rejoined forward, 4 segments
    /// skipped. The depth decides both halves now, the gate and the threshold.
    @Test("a consumer playing out of its own buffer is still closed on, and only once the depth is out")
    func theCloseFollowsTheDepth() {
        // Deeper than the reserve: the wait still has something to spend.
        for buffered in [6.1, 12.0, 30.0] {
            let (provider, cache) = makeLiveProvider(segments: 20, buffered: buffered)
            cache.declareTarget(19) // everything fetched, so nothing is listed above the fetch point
            provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 13.1)
            #expect(!provider.liveOutageEndlist)
        }
        // At or under it: the last moment the ENDLIST still reaches a consumer with something to play
        // out, which is the controlled swap this decision exists to buy.
        for buffered in [6.0, 2.1, 0.5] {
            let (provider, cache) = makeLiveProvider(segments: 20, buffered: buffered)
            cache.declareTarget(19)
            provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 13.1)
            #expect(provider.liveOutageEndlist)
        }
        // And nothing at all is not a close: an ENDLIST served to a consumer with nothing left to play
        // converts a stall into an end, which is what the old gate was right about.
        let (dry, dryCache) = makeLiveProvider(segments: 20, buffered: 0)
        dryCache.declareTarget(19)
        dry.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 13.1)
        #expect(!dry.liveOutageEndlist)
    }

    /// A negative or absurd reading must not buy patience: the mirror is written by a sampler that can
    /// be mid-swap, and a close deferred on a figure about an item that is gone is the failure this
    /// whole thread is about.
    @Test("a reading that cannot be true is worth nothing")
    func anImpossibleReadingBuysNothing() {
        let (provider, cache) = makeLiveProvider(segments: 20, buffered: -50)
        cache.declareTarget(18)
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 13.1)
        #expect(provider.liveOutageEndlist)
    }

    /// And the ceiling still ends it: a consumer with minutes in hand is not a reason to hold a source
    /// the producer is about to give up on.
    @Test("a deep buffer does not outlive the producer's own patience")
    func theCeilingStillHolds() {
        let (provider, cache) = makeLiveProvider(segments: 20, buffered: 300)
        cache.declareTarget(18)
        provider.backdateLastLiveSegmentFinalizeForTesting(bySeconds: 26.5) // past 35 - 9
        #expect(provider.liveOutageEndlist)
    }
}
