import Testing
import Foundation
@testable import AetherEngine

/// #551: whether a warm needs a second request for the source's trailing object.
///
/// The question is worth asking because the answer is usually no, and a second request against a
/// metered origin is the most expensive thing a speculative path can spend. Matroska never reads
/// its cues at open whether they sit at the front or the back (measured across the #281 fixture
/// matrix), and a fast-start MP4 carries its `moov` inside the warm head already. What is left is
/// exactly the layout #281 was reported about: an MP4 whose `moov` is at the end.
@Suite("Source prewarm tail plan (#551)")
struct SourcePrewarmPlanTests {

    private func box(_ type: String, size: Int) -> Data {
        var d = Data()
        withUnsafeBytes(of: UInt32(size).bigEndian) { d.append(contentsOf: $0) }
        d.append(type.data(using: .ascii)!)
        d.append(Data(count: max(0, size - 8)))
        return d
    }

    @Test("a fast-start MP4 carries its moov in the head and needs nothing more")
    func faststartNeedsNoTail() {
        var head = box("ftyp", size: 32)
        head.append(box("moov", size: 4096))
        head.append(box("mdat", size: 65536))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head) == false)
    }

    @Test("an MP4 whose mdat runs past the warm head needs the tail")
    func moovAtEndNeedsTail() {
        var head = box("ftyp", size: 32)
        // An mdat larger than anything the warm holds: the moov is somewhere behind it.
        head.append(box("mdat", size: 512 * 1024 * 1024))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head.prefix(1 << 20)) == true)
    }

    @Test("Matroska never needs the tail, at either end")
    func matroskaNeedsNoTail() {
        var head = Data([0x1A, 0x45, 0xDF, 0xA3])
        head.append(Data(count: 4096))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head) == false)
    }

    @Test("a container the sniffer does not know is left alone")
    func unknownNeedsNoTail() {
        let ts = Data([UInt8](repeating: 0x47, count: 4096))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: ts) == false)
        #expect(SourcePrewarmPlan.needsTrailingObject(head: Data()) == false)
    }

    /// A 64-bit `largesize` is how any real film-sized `mdat` states its length, so a walker that
    /// only reads the 32-bit field would read the first eight bytes of the payload as the next box.
    @Test("a 64-bit largesize box is walked, not misread")
    func largesizeIsWalked() {
        var head = box("ftyp", size: 32)
        var mdat = Data()
        withUnsafeBytes(of: UInt32(1).bigEndian) { mdat.append(contentsOf: $0) }
        mdat.append("mdat".data(using: .ascii)!)
        withUnsafeBytes(of: UInt64(8 * 1024 * 1024 * 1024).bigEndian) { mdat.append(contentsOf: $0) }
        head.append(mdat)
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head) == true)
    }

    /// A truncated header at the very end of the warm is not a box, and reading it as one would
    /// jump to an offset the file never had.
    @Test("a partial box header at the end of the head stops the walk")
    func partialHeaderStopsTheWalk() {
        var head = box("ftyp", size: 32)
        head.append(Data([0x00, 0x00, 0x10]))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head) == true)
    }

    @Test("a box claiming to run to end of file ends the walk")
    func sizeZeroEndsTheWalk() {
        var head = box("ftyp", size: 32)
        var toEOF = Data()
        withUnsafeBytes(of: UInt32(0).bigEndian) { toEOF.append(contentsOf: $0) }
        toEOF.append("mdat".data(using: .ascii)!)
        head.append(toEOF)
        head.append(Data(count: 1024))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head) == true)
    }
}
