import Foundation
import Testing
@testable import AetherEngine

/// #112 round 9 (ijuniorfu, 0.9.18, remote ISO): subtitles arrived ~45 s late after a seek, and never at all
/// after a fast-forward or audio switch, while the same ISO played fine locally. Both round-8 mechanisms were
/// wired to `avioProvider as? AVIOReader`: a disc image opens through HTTPDiscIOReader -> DiscReader ->
/// CustomIOReaderBridge, so on exactly those sources `seekBounded` armed no deadline (one positioning seek sat
/// wedged for ~230 s, device log 2) and `seekByteEstimate` had no byte size ("byte-estimate fallback
/// unavailable", device logs 1 + 2). The deadline and the resolved byte size now live on the AVIOProvider
/// protocol; these tests lock the bridge's implementation.
struct Issue112DiscProviderSeekBoundsTests {

    private final class UnsizedReader: IOReader, @unchecked Sendable {
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 { 0 }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
    }

    @Test("bridge reports the reader's AVSEEK_SIZE as its resolved byte size")
    func bridgeResolvedByteSize() {
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: Data(repeating: 0, count: 4096)))
        #expect(bridge.resolvedByteSize == 4096)
    }

    @Test("bridge resolved byte size is nil when the reader cannot report a size")
    func bridgeResolvedByteSizeNil() {
        let bridge = CustomIOReaderBridge(reader: UnsizedReader())
        #expect(bridge.resolvedByteSize == nil)
    }

    @Test("an expired read deadline aborts the bridge read and latches the flag")
    func bridgeDeadlineAbortsRead() {
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: Data([1, 2, 3, 4])))
        bridge.beginReadDeadline(secondsFromNow: -1)
        var buf = [UInt8](repeating: 0, count: 4)
        let n = buf.withUnsafeMutableBufferPointer { bridge.performRead(into: $0.baseAddress!, size: 4) }
        #expect(n == -1)
        #expect(bridge.readDeadlineFired == true)
    }

    @Test("a live deadline lets reads through and does not latch")
    func bridgeLiveDeadlinePassesRead() {
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: Data([1, 2, 3, 4])))
        bridge.beginReadDeadline(secondsFromNow: 60)
        var buf = [UInt8](repeating: 0, count: 4)
        let n = buf.withUnsafeMutableBufferPointer { bridge.performRead(into: $0.baseAddress!, size: 4) }
        #expect(n == 4)
        #expect(bridge.readDeadlineFired == false)
    }

    @Test("ending the deadline disarms it and re-arming resets the fired flag")
    func bridgeDeadlineDisarmAndRearm() {
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: Data([1, 2, 3, 4])))
        bridge.beginReadDeadline(secondsFromNow: -1)
        var buf = [UInt8](repeating: 0, count: 2)
        _ = buf.withUnsafeMutableBufferPointer { bridge.performRead(into: $0.baseAddress!, size: 2) }
        #expect(bridge.readDeadlineFired == true)
        bridge.endReadDeadline()
        let n = buf.withUnsafeMutableBufferPointer { bridge.performRead(into: $0.baseAddress!, size: 2) }
        #expect(n == 2)
        bridge.beginReadDeadline(secondsFromNow: 60)
        #expect(bridge.readDeadlineFired == false)
    }
}
