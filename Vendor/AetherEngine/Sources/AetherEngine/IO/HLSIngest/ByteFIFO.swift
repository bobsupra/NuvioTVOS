import Foundation

/// Bounded blocking byte queue between the HLS fetch loop (writer) and demux thread (reader). NSCondition-based; `finish()` signals EOF, `cancel()` signals error. Capacity is a soft bound: write blocks while at/above capacity then appends the whole chunk (overshoot = at most one chunk). Storage uses `subdata` re-base on consume, never `removeFirst` (Data.removeFirst slice-leak, AetherEngine 70430de).
final class ByteFIFO: @unchecked Sendable {
    private let capacity: Int
    private let condition = NSCondition()
    private var storage = Data()
    private var finished = false
    private var cancelled = false

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Append, blocking while at capacity. Returns false when finished or cancelled.
    func write(_ data: Data) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while storage.count >= capacity && !finished && !cancelled {
            condition.wait()
        }
        if finished || cancelled { return false }
        storage.append(data)
        condition.broadcast()
        return true
    }

    /// Blocking read. Returns: >0 bytes copied; 0 = EOF (finished + drained); -1 = cancelled.
    func read(into buffer: UnsafeMutablePointer<UInt8>, maxLength: Int) -> Int {
        condition.lock()
        defer { condition.unlock() }
        while storage.isEmpty && !finished && !cancelled {
            condition.wait()
        }
        if cancelled { return -1 }
        if storage.isEmpty { return 0 } // finished + drained
        let n = min(maxLength, storage.count)
        storage.copyBytes(to: UnsafeMutableBufferPointer(start: buffer, count: n), from: 0..<n)
        storage = storage.subdata(in: n..<storage.count) // subdata re-base: Data.removeFirst retains backing storage
        condition.broadcast()
        return n
    }

    func finish() {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        condition.lock()
        cancelled = true
        condition.broadcast()
        condition.unlock()
    }
}
