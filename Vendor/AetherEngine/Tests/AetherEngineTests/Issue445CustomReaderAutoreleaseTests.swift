import Foundation
import Testing
@testable import AetherEngine

/// AE#445 (cmcpherson274, tvOS 26.6, live MPEG-TS behind `MediaSource.custom`): a live custom-reader
/// session retained approximately one byte for every byte it consumed. `phys_footprint` climbed at the
/// source mux rate for the life of the session and jetsam took the process at ~11.5 min, while every
/// itemized bucket on the engine's own memprobe stayed flat (`cacheMB`, `pumpWinMB`, `pktAlive`,
/// `audioFifo`) and the URL arm of the same channel held at 29 MB across 3.4 GB fetched.
///
/// The owner is the thread, not the reader. `HLSSegmentProducer` runs its pump on a bare `Thread`,
/// which has no autorelease pool of its own, and FFmpeg's read callback reaches the host's `IOReader`
/// from inside that loop. Any autoreleased object the host makes per read (an `NSData` out of
/// `FileHandle`, anything Foundation hands back +0) is therefore stranded for the whole session.
///
/// The engine had already paid for this lesson twice and both times fixed it one reader down:
/// `FileIOReader.read` (#243: "one leaked byte per byte played", 625 MB in-use after 624 MB read) and
/// `HTTPDiscIOReader.rangeGet`. Neither pool can cover a reader the HOST wrote, and a host cannot be
/// asked to know which of the engine's threads its callback lands on. So the pool belongs at the seam
/// the engine owns: `CustomIOReaderBridge`, which is the single door every custom reader comes through.
/// Serialized: the witness counter is process-wide, so parallel cases would net each other's
/// allocations out and report a number that belongs to no test.
@Suite(.serialized)
struct Issue445CustomReaderAutoreleaseTests {

    /// Counts objects that are alive only because nothing drained the pool they were autoreleased into.
    private final class PoolWitness: NSObject {
        nonisolated(unsafe) static var live = 0
        override init() {
            super.init()
            PoolWitness.live += 1
        }
        deinit { PoolWitness.live -= 1 }
    }

    /// Stands in for a host reader built on Foundation: every call leaves one autoreleased object
    /// behind, exactly as `FileHandle.readData` and friends do.
    private final class AutoreleasingReader: IOReader, @unchecked Sendable {
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            _ = Unmanaged.passRetained(PoolWitness()).autorelease()
            guard let buffer, size > 0 else { return -1 }
            buffer.update(repeating: 0, count: Int(size))
            return size
        }

        func seek(offset: Int64, whence: Int32) -> Int64 {
            _ = Unmanaged.passRetained(PoolWitness()).autorelease()
            return whence == 65536 ? -1 : max(0, offset)
        }

        func close() {}
    }

    /// Drives the bridge from a bare `Thread`, which is the pump's own shape, and reports the witness
    /// count from INSIDE that thread.
    ///
    /// Both halves matter. On the test runner's own thread the runner drains between cases and would
    /// collect the witnesses whatever the bridge did; and reading the count after the thread has
    /// JOINED is just as blind, because `NSThread` pops a top-level pool when its body returns, which
    /// is a teardown the pump never reaches in a session that runs for hours. The number that
    /// describes AE#445 is the one standing while the loop is still running.
    private func witnessesLiveDuring(_ body: @escaping @Sendable () -> Void) -> Int {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var observed = -1
        let thread = Thread {
            body()
            observed = PoolWitness.live
            done.signal()
        }
        thread.stackSize = 1 << 20
        thread.start()
        done.wait()
        return observed
    }

    @Test("a host reader's autoreleased temporaries do not outlive the read that made them")
    func bridgeDrainsPerRead() {
        PoolWitness.live = 0
        let bridge = CustomIOReaderBridge(reader: AutoreleasingReader())
        let live = witnessesLiveDuring {
            var buf = [UInt8](repeating: 0, count: 4096)
            buf.withUnsafeMutableBufferPointer { p in
                for _ in 0..<512 { _ = bridge.performRead(into: p.baseAddress!, size: 4096) }
            }
        }
        // Without a pool at the seam this is 512, and on a real session it is one stranded object per
        // read for as long as the channel is up.
        #expect(live == 0)
    }

    @Test("a host reader's autoreleased temporaries do not outlive the seek that made them")
    func bridgeDrainsPerSeek() {
        PoolWitness.live = 0
        let bridge = CustomIOReaderBridge(reader: AutoreleasingReader())
        let live = witnessesLiveDuring {
            for i in 0..<512 { _ = bridge.performSeek(offset: Int64(i * 188), whence: 0) }
        }
        #expect(live == 0)
    }

    /// The size probe runs at open, on whichever thread opened the demuxer, and asks the host the same
    /// kind of question. Cheap to cover, and it is the one call every custom source makes exactly once.
    @Test("the bridge's size probe drains what the host allocated for it")
    func bridgeDrainsSizeProbe() {
        PoolWitness.live = 0
        let bridge = CustomIOReaderBridge(reader: AutoreleasingReader())
        let live = witnessesLiveDuring {
            for _ in 0..<64 { _ = bridge.resolvedByteSize }
        }
        #expect(live == 0)
    }

    /// The pool must not change what the bridge reports, only what it leaves behind.
    @Test("draining does not alter the bridge's read and seek results")
    func bridgeContractUnchanged() {
        let bridge = CustomIOReaderBridge(reader: DataIOReader(data: Data([1, 2, 3, 4, 5, 6, 7, 8])))
        var buf = [UInt8](repeating: 0, count: 4)
        let n = buf.withUnsafeMutableBufferPointer { bridge.performRead(into: $0.baseAddress!, size: 4) }
        #expect(n == 4)
        #expect(buf == [1, 2, 3, 4])
        #expect(bridge.performSeek(offset: 2, whence: 0) == 2)
        #expect(bridge.resolvedByteSize == 8)
    }
}
