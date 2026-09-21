import Testing
import Foundation
@testable import AetherEngine

/// #551: the store a prewarm fills and a later `load()` empties.
///
/// The rule the tests are here to pin is that adoption TAKES the entry. A session that has the
/// bytes owns them through its own reader, so a copy left behind would hold megabytes for an item
/// that is now playing, and the cap would then be spent on sources nobody is going to open.
@Suite("Source prewarm store (#551)")
struct SourcePrewarmStoreTests {

    private func url(_ name: String) -> URL {
        URL(string: "http://origin.test/\(name).mkv")!
    }

    private func entry(head: Int, at start: Int64 = 0, contentLength: Int64 = 1 << 30) -> PrewarmedSource {
        PrewarmedSource(head: ResidentSpan(start: start, data: Data(count: head)),
                        tail: nil,
                        contentLength: contentLength,
                        requestHeaders: [:])
    }

    @Test("a stored source is served once and then gone")
    func adoptionTakesTheEntry() {
        let store = SourcePrewarmStore(totalByteCap: 1 << 20)
        store.store(entry(head: 4096, contentLength: 900), for: url("a"))

        let first = store.take(for: url("a"))
        #expect(first?.head.data.count == 4096)
        #expect(first?.contentLength == 900)
        #expect(store.take(for: url("a")) == nil, "the entry survived its adoption")
        #expect(store.retainedBytes == 0)
    }

    @Test("a source nobody warmed is a miss, not an empty span")
    func missIsNil() {
        let store = SourcePrewarmStore(totalByteCap: 1 << 20)
        #expect(store.take(for: url("never-warmed")) == nil)
    }

    @Test("the cap evicts the least recently stored source, not the newest one")
    func capEvictsOldest() {
        let store = SourcePrewarmStore(totalByteCap: 3000)
        store.store(entry(head: 1000), for: url("a"))
        store.store(entry(head: 1000), for: url("b"))
        store.store(entry(head: 1000), for: url("c"))
        #expect(store.retainedBytes == 3000)

        store.store(entry(head: 1000), for: url("d"))

        #expect(store.take(for: url("a")) == nil, "the oldest entry should have gone first")
        #expect(store.take(for: url("d"))?.head.data.count == 1000)
        #expect(store.take(for: url("b")) != nil)
        #expect(store.take(for: url("c")) != nil)
    }

    /// A budget larger than the whole store would otherwise evict every other entry to make room
    /// for one it cannot hold either. Refusing is the honest answer, and the caller hears it.
    @Test("an entry larger than the cap is refused and displaces nothing")
    func oversizedEntryIsRefused() {
        let store = SourcePrewarmStore(totalByteCap: 2000)
        store.store(entry(head: 1500), for: url("keeper"))

        let accepted = store.store(entry(head: 4000), for: url("too-big"))

        #expect(accepted == false)
        #expect(store.take(for: url("too-big")) == nil)
        #expect(store.take(for: url("keeper"))?.head.data.count == 1500,
                "an oversized store evicted an entry it then could not replace")
    }

    @Test("re-warming a source replaces its entry rather than counting twice")
    func restoreReplaces() {
        let store = SourcePrewarmStore(totalByteCap: 1 << 20)
        store.store(entry(head: 1000), for: url("a"))
        store.store(entry(head: 2000), for: url("a"))

        #expect(store.retainedBytes == 2000)
        #expect(store.take(for: url("a"))?.head.data.count == 2000)
    }

    @Test("the tail span counts toward the cap and travels with the entry")
    func tailCountsAndTravels() {
        let store = SourcePrewarmStore(totalByteCap: 1 << 20)
        let withTail = PrewarmedSource(head: ResidentSpan(start: 0, data: Data(count: 1000)),
                                       tail: ResidentSpan(start: 9000, data: Data(count: 500)),
                                       contentLength: 9500,
                                       requestHeaders: [:])
        store.store(withTail, for: url("a"))
        #expect(store.retainedBytes == 1500)

        let taken = store.take(for: url("a"))
        #expect(taken?.tail?.start == 9000)
        #expect(taken?.tail?.data.count == 500)
    }

    @Test("clear empties the store")
    func clearEmpties() {
        let store = SourcePrewarmStore(totalByteCap: 1 << 20)
        store.store(entry(head: 1000), for: url("a"))
        store.clear()
        #expect(store.retainedBytes == 0)
        #expect(store.take(for: url("a")) == nil)
    }
}
