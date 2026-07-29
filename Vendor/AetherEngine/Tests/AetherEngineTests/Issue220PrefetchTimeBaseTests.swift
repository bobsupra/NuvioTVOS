import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

/// #220 (rrgomes): the #151 prefetcher memoized its own time-base lookup failure. A nil
/// `stream(at:)` fell back to `0/1`, that value went into the cache for the session, and the
/// park guard (`tb.num > 0`) then skipped every subsequent packet on the stream, so the reader
/// ran the rest of the session with no forward park: exactly the "reads straight past dozens of
/// parkable packets" shape seen on the wire, from a single transient lookup and with no
/// allocator pathology needed. The same value also reached the packet store, where the harvest
/// rate is `num/den` and a zero rate lands every cue at second 0.
struct Issue220PrefetchTimeBaseTests {

    private static let matroska = AVRational(num: 1, den: 1000)

    @Test("a usable time base is resolved and memoized")
    func usableTimeBaseIsCached() {
        var cache: [Int32: AVRational] = [:]
        var lookups = 0
        let first = SubtitleForwardPrefetcher.resolveTimeBase(streamIndex: 2, cache: &cache) { _ in
            lookups += 1
            return Self.matroska
        }
        let second = SubtitleForwardPrefetcher.resolveTimeBase(streamIndex: 2, cache: &cache) { _ in
            lookups += 1
            return Self.matroska
        }
        #expect(first?.den == 1000)
        #expect(second?.den == 1000)
        #expect(lookups == 1, "second call must be served from the cache")
    }

    /// The defect: this failure used to be stored, and every later packet read the stored 0/1.
    @Test("a failed lookup is not memoized and the next packet retries")
    func failedLookupIsNotCached() {
        var cache: [Int32: AVRational] = [:]
        let failed = SubtitleForwardPrefetcher.resolveTimeBase(streamIndex: 2, cache: &cache) { _ in nil }
        #expect(failed == nil)
        #expect(cache.isEmpty, "a failed lookup must leave the cache clean")

        let recovered = SubtitleForwardPrefetcher.resolveTimeBase(streamIndex: 2, cache: &cache) { _ in
            Self.matroska
        }
        #expect(recovered?.den == 1000, "the stream must resolve once the lookup works again")
    }

    /// `0/1` and `1/0` are both unusable: the first zeroes every harvested PTS, the second
    /// divides by zero. Neither may be treated as a resolved time base.
    @Test("a degenerate time base counts as a failed lookup")
    func degenerateTimeBaseRejected() {
        var cache: [Int32: AVRational] = [:]
        #expect(SubtitleForwardPrefetcher.resolveTimeBase(streamIndex: 2, cache: &cache) { _ in
            AVRational(num: 0, den: 1)
        } == nil)
        #expect(SubtitleForwardPrefetcher.resolveTimeBase(streamIndex: 2, cache: &cache) { _ in
            AVRational(num: 1, den: 0)
        } == nil)
        #expect(cache.isEmpty)
    }

    @Test("streams are cached independently")
    func perStreamCaching() {
        var cache: [Int32: AVRational] = [:]
        _ = SubtitleForwardPrefetcher.resolveTimeBase(streamIndex: 2, cache: &cache) { _ in
            AVRational(num: 1, den: 1000)
        }
        let other = SubtitleForwardPrefetcher.resolveTimeBase(streamIndex: 3, cache: &cache) { _ in
            AVRational(num: 1, den: 90000)
        }
        #expect(other?.den == 90000)
        #expect(cache[2]?.den == 1000)
    }
}
