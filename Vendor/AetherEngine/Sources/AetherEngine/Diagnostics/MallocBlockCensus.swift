import Foundation
import Darwin

/// #220: in-process census of live malloc blocks by size class.
///
/// The 30 s memprobe already reports `mallocBlocks` + `mallocMB`. A flat block count with a
/// rising size means one or a few large buffers growing rather than many small ones leaking
/// (rrgomes measured exactly that: blocks 598025 -> 597127 while size went 437 -> 876 MB).
/// Those two numbers cannot say WHICH allocation grew, and guessing from the shape has
/// already cost two wrong hypotheses on that issue. This walks the malloc zones and tallies
/// live blocks per power-of-two bucket, so the growing allocation is named by its size class
/// instead of inferred.
///
/// Two rules make this safe enough to hand to a reporter:
///
/// - The heap is live during the walk, so every zone is held through
///   `introspect->force_lock` and released through `force_unlock`. Without that, a concurrent
///   allocation can move the structures the enumerator is reading.
/// - The recorder callback runs while that lock is held, so it MUST NOT allocate. It writes
///   into a buffer reserved before the lock is taken. No Swift arrays, dictionaries or
///   strings are touched inside it.
///
/// Opt-in only. `isEnabled` defaults to false and normal playback never enumerates.
enum MallocBlockCensus {

    /// Diagnostic opt-in. Set once during host start-up, read from the memprobe tick.
    nonisolated(unsafe) static var isEnabled = false

    /// Buckets are powers of two; anything below this is aggregated away because the
    /// interesting signal is a handful of multi-megabyte blocks, not the small-object churn
    /// the block count already covers.
    static let minimumTrackedBytes = 1 << 20   // 1 MB

    /// Highest bucket, i.e. blocks >= 2^40. Sized so the index arithmetic cannot run off the
    /// scratch buffer even for an absurd allocation.
    static let bucketCount = 41

    /// Exact sizes of the largest individual blocks are kept alongside the buckets: a power-of-two
    /// bucket says "something doubled", the exact size says WHICH cap it is riding (a block of
    /// exactly 64 MiB names a watermark; an arbitrary size does not).
    static let topExactCount = 6

    struct Result {
        /// Live blocks at or above `minimumTrackedBytes`.
        var count: Int
        /// Their summed size.
        var bytes: Int
        /// (bucketBytes, blockCount) for non-empty buckets, largest first.
        var buckets: [(bytes: Int, count: Int)]
        /// Exact sizes of the largest individual blocks, descending.
        var largest: [Int]
    }

    /// Walk every malloc zone and tally live blocks >= `minimumTrackedBytes`.
    /// Returns nil when disabled or when the zone list cannot be read.
    static func census() -> Result? {
        guard isEnabled else { return nil }

        var zones: UnsafeMutablePointer<vm_address_t>?
        var zoneCount: UInt32 = 0
        guard malloc_get_all_zones(mach_task_self_, aeCensusReadLocal, &zones, &zoneCount) == KERN_SUCCESS,
              let zones, zoneCount > 0
        else { return nil }

        // Reserved BEFORE any zone lock is taken: bucket counts, then bucket bytes, then the
        // running top-N exact sizes.
        let slotCount = bucketCount * 2 + topExactCount
        let slots = UnsafeMutablePointer<Int>.allocate(capacity: slotCount)
        slots.initialize(repeating: 0, count: slotCount)
        defer { slots.deallocate() }

        for i in 0..<Int(zoneCount) {
            let address = zones[i]
            guard let raw = UnsafeMutableRawPointer(bitPattern: UInt(address)) else { continue }
            let zone = raw.assumingMemoryBound(to: malloc_zone_t.self)
            guard let introspect = zone.pointee.introspect?.pointee,
                  let enumerator = introspect.enumerator
            else { continue }
            // Hold the zone across the walk; a concurrent allocation would otherwise move the
            // structures the enumerator reads. force_lock/force_unlock are the documented pair.
            introspect.force_lock?(zone)
            _ = enumerator(mach_task_self_, slots, UInt32(MALLOC_PTR_IN_USE_RANGE_TYPE),
                           address, aeCensusReadLocal, aeCensusRecord)
            introspect.force_unlock?(zone)
        }

        var total = 0
        var totalBytes = 0
        var buckets: [(bytes: Int, count: Int)] = []
        for bucket in stride(from: bucketCount - 1, through: 0, by: -1) {
            let n = slots[bucket]
            guard n > 0 else { continue }
            total += n
            totalBytes += slots[bucketCount + bucket]
            buckets.append((bytes: 1 << bucket, count: n))
        }
        var largest: [Int] = []
        for i in 0..<topExactCount where slots[bucketCount * 2 + i] > 0 {
            largest.append(slots[bucketCount * 2 + i])
        }
        return Result(count: total, bytes: totalBytes, buckets: buckets, largest: largest)
    }

    /// memprobe fragment: total, summed size, and the largest buckets.
    /// Empty string when disabled, so the line shape is unchanged for normal sessions.
    static func probeFragment(topBuckets: Int = 4) -> String {
        guard let result = census() else { return "" }
        let top = result.buckets.prefix(topBuckets)
            .map { "\($0.bytes / (1 << 20))MBx\($0.count)" }
            .joined(separator: ",")
        let exact = result.largest.map { String($0) }.joined(separator: ",")
        return "bigBlocks=\(result.count) bigMB=\(result.bytes / (1 << 20)) "
            + "bigTop=\(top.isEmpty ? "none" : top) "
            + "bigExact=\(exact.isEmpty ? "none" : exact) "
    }
}

/// In-process memory reader: the "remote" address IS the local address, so hand it back.
/// A plain `func` on purpose; a C function pointer cannot be formed from a stored closure.
private func aeCensusReadLocal(
    _ task: task_t,
    _ address: vm_address_t,
    _ size: vm_size_t,
    _ local: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> kern_return_t {
    local?.pointee = UnsafeMutableRawPointer(bitPattern: UInt(address))
    return KERN_SUCCESS
}

/// Tallies each in-use range into the scratch buffer addressed by `context`.
/// Runs under the zone lock: no allocation, no Swift runtime calls that could allocate.
private func aeCensusRecord(
    _ task: task_t,
    _ context: UnsafeMutableRawPointer?,
    _ type: UInt32,
    _ ranges: UnsafeMutablePointer<vm_range_t>?,
    _ count: UInt32
) {
    guard type & UInt32(MALLOC_PTR_IN_USE_RANGE_TYPE) != 0,
          let ranges, let context
    else { return }
    let slots = context.assumingMemoryBound(to: Int.self)
    // Hand-rolled counter, not `for i in 0..<Int(count)`. Unspecialized, a Range iterates
    // through IndexingIterator's protocol witness, which allocates; doing that under the zone
    // lock recursively locks it and libplatform aborts the process ("Trying to recursively
    // lock an os_unfair_lock"). Optimized builds specialize the range away and never hit it,
    // so the old form killed a debug build on the first census and left release builds fine,
    // which is the worst possible failure mode for an instrument that is supposed to be
    // watchable. A while loop has no iterator to specialize.
    var i = 0
    let n = Int(count)
    while i < n {
        let size = Int(ranges[i].size)
        i += 1
        if size < MallocBlockCensus.minimumTrackedBytes { continue }
        // Bucket by floor(log2(size)), clamped into the scratch buffer.
        var bucket = 0
        var probe = size
        while probe > 1 { probe >>= 1; bucket += 1 }
        if bucket >= MallocBlockCensus.bucketCount { bucket = MallocBlockCensus.bucketCount - 1 }
        slots[bucket] += 1
        slots[MallocBlockCensus.bucketCount + bucket] += size

        // Descending insert into the top-N exact-size tail. Fixed slots, no allocation:
        // a power-of-two bucket only says "something doubled", the exact size names the cap
        // the buffer is riding.
        let tail = MallocBlockCensus.bucketCount * 2
        var slot = 0
        while slot < MallocBlockCensus.topExactCount, slots[tail + slot] >= size { slot += 1 }
        if slot < MallocBlockCensus.topExactCount {
            var shift = MallocBlockCensus.topExactCount - 1
            while shift > slot { slots[tail + shift] = slots[tail + shift - 1]; shift -= 1 }
            slots[tail + slot] = size
        }
    }
}
