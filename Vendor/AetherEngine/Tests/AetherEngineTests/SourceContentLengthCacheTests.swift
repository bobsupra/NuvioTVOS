import Foundation
import Testing
@testable import AetherEngine

/// #112: the producer resolves a remote MPEG-TS's byte length from its persistent open; a subtitle side demuxer
/// opening the same origin under load can be starved of a length and collapse to forward-only (every seek -1).
/// The cache lets the side demuxer reuse the producer's resolved length. Unique URLs per test avoid cross-test
/// interference on the process-wide store (no `clear()`, which would wipe a parallel test's entry).
struct SourceContentLengthCacheTests {

    @Test("a stored positive size is returned for the same URL")
    func storeAndLookup() {
        let url = URL(string: "https://example.test/store-and-lookup.ts")!
        #expect(SourceContentLengthCache.lookup(url) == nil)
        SourceContentLengthCache.store(1_234_567, for: url)
        #expect(SourceContentLengthCache.lookup(url) == 1_234_567)
    }

    @Test("non-positive sizes are never stored, so a genuinely length-less source stays streaming")
    func nonPositiveNotStored() {
        let url = URL(string: "https://example.test/length-less.ts")!
        SourceContentLengthCache.store(0, for: url)
        SourceContentLengthCache.store(-1, for: url)
        #expect(SourceContentLengthCache.lookup(url) == nil)
    }

    @Test("distinct URLs do not share a resolved size")
    func distinctURLsIsolated() {
        let a = URL(string: "https://example.test/isolated-a.ts")!
        let b = URL(string: "https://example.test/isolated-b.ts")!
        SourceContentLengthCache.store(999, for: a)
        #expect(SourceContentLengthCache.lookup(b) == nil)
        #expect(SourceContentLengthCache.lookup(a) == 999)
    }
}
