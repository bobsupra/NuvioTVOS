import Foundation
import Darwin.Mach

/// AE#445: names the VM region a rising `phys_footprint` is rising in.
///
/// The 30 s memprobe already carries `vmInt/vmExt/vmCmp/vmIOS` and a malloc census, and three
/// rounds of AE#445 still ended in the same sentence: footprint climbs at the source mux rate,
/// every itemized bucket is flat. Those buckets are totals or heap-only, so retention that lives
/// outside malloc (a CoreMedia pool, an IOSurface, an anonymous `vm_allocate`, a mapped file kept
/// dirty) is invisible to all of them at once. That is not a gap in the theory, it is a gap in the
/// instrument: a slope with no name attached cannot aim the next dig.
///
/// This walks the task's own VM map and tallies DIRTY plus SWAPPED pages per `user_tag`. A tag is
/// not a call site, but it is the difference between "something grew by 428 MB" and "CM_MEMORYPOOL
/// grew by 428 MB", which is one subsystem instead of a process.
///
/// **What it reports is GROWTH, not a total, because only growth is calibrated.** Dirty pages of a
/// mapped file belong to the file rather than to the process, so they are skipped; but even the
/// anonymous total still overshoots `phys_footprint` (measured: 100 MB against 56 MB), because
/// IOSurface and video-bitstream mappings look anonymous in this map while the kernel charges them
/// to whoever created them, usually the media server. An absolute total that cannot be checked
/// against the line beside it is worse than none, so the fragment states `vmGrewMB`, the summed
/// POSITIVE deltas since the baseline. That figure has a meaning a reader can verify: hold it
/// against the rise in `physFP` over the same span, and the gap is the part no tag explains.
///
/// Opt-in for the same reason the malloc census is: the walk is O(regions) and takes the map lock.
enum VMRegionCensus {

    /// Diagnostic opt-in, set through `AetherEngine.setLargeAllocationCensusEnabled`.
    nonisolated(unsafe) static var isEnabled = false

    /// tag -> footprint bytes at the moment `markBaseline` ran. Deltas are measured against this,
    /// because the absolute figure is dominated by whatever the process was already holding.
    nonisolated(unsafe) private static var baseline: [Int: Int]?
    private static let lock = NSLock()

    struct Tally: Sendable {
        let tag: Int
        /// Anonymous dirty + swapped bytes, i.e. what this tag contributes to `phys_footprint`.
        let footprintBytes: Int
        /// Growth since the baseline, 0 when no baseline was taken.
        let deltaBytes: Int
        var name: String { VMRegionCensus.tagName(tag) }
    }

    struct Result: Sendable {
        var totalFootprintBytes: Int
        var regionCount: Int
        /// Descending by `footprintBytes`.
        var tallies: [Tally]
    }

    /// Anchor deltas here. Called once a session is actually running, so the load burst is part of
    /// the baseline rather than part of the finding.
    static func markBaseline() {
        guard isEnabled, let snapshot = walk() else { return }
        lock.lock()
        baseline = snapshot.reduce(into: [Int: Int]()) { $0[$1.key] = $1.value }
        lock.unlock()
    }

    static func clearBaseline() {
        lock.lock(); baseline = nil; lock.unlock()
    }

    static func census() -> Result? {
        guard isEnabled, let tags = walk() else { return nil }
        lock.lock()
        let base = baseline
        lock.unlock()

        var total = 0
        var tallies: [Tally] = []
        tallies.reserveCapacity(tags.count)
        for (tag, bytes) in tags {
            total += bytes
            tallies.append(Tally(tag: tag,
                                 footprintBytes: bytes,
                                 deltaBytes: base.map { bytes - ($0[tag] ?? 0) } ?? 0))
        }
        tallies.sort { $0.footprintBytes > $1.footprintBytes }
        return Result(totalFootprintBytes: total, regionCount: regionCount, tallies: tallies)
    }

    /// One memprobe fragment. Ordered by DELTA rather than by size, because the tag holding the most
    /// is almost always the same one every session and says nothing; the tag that grew is the finding.
    /// The first fragment of a session doubles as the baseline, so a reporter gets deltas without
    /// having to know there is a baseline to take. That makes the load burst part of the anchor
    /// rather than part of the finding, which is what the anchor is for.
    static func probeFragment(top: Int = 3) -> String {
        guard let result = census() else { return "" }
        lock.lock()
        if baseline == nil {
            baseline = result.tallies.reduce(into: [Int: Int]()) { $0[$1.tag] = $1.footprintBytes }
        }
        lock.unlock()
        let ranked = result.tallies.sorted { $0.deltaBytes > $1.deltaBytes }.prefix(top)
        let listed = ranked
            .filter { $0.footprintBytes >= 1 << 20 }
            .map { "\($0.name):\($0.deltaBytes >= 0 ? "+" : "")\($0.deltaBytes >> 20)MB(\($0.footprintBytes >> 20))" }
            .joined(separator: ",")
        let grown = result.tallies.reduce(0) { $0 + max(0, $1.deltaBytes) }
        return "vmGrewMB=\(grown >> 20) vmRegions=\(result.regionCount) "
            + "vmTagTop=\(listed.isEmpty ? "none" : listed) "
    }

    // MARK: - Walk

    nonisolated(unsafe) private static var regionCount = 0

    /// `pages_dirtied` counts kernel pages, so the multiplier has to be the kernel's, not a constant.
    private static let pageSizeBytes = Int(sysconf(_SC_PAGESIZE))

    /// tag -> dirty + swapped bytes. `vm_region_recurse_64` rather than `mach_vm_region_recurse`:
    /// the mach_vm entry points are not in the public tvOS/iOS SDK, and on a 64-bit target the
    /// vm_ variants carry the same widths.
    private static func walk() -> [Int: Int]? {
        var tags: [Int: Int] = [:]
        var address: vm_address_t = 0
        var depth: UInt32 = 0
        var regions = 0
        let pageSize = Self.pageSizeBytes

        while true {
            var size: vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<Int32>.size
            )
            let kr = withUnsafeMutablePointer(to: &info) { infoPtr in
                infoPtr.withMemoryRebound(to: Int32.self, capacity: Int(count)) { intPtr in
                    vm_region_recurse_64(mach_task_self_, &address, &size, &depth, intPtr, &count)
                }
            }
            guard kr == KERN_SUCCESS else { break }

            // A submap is a container, not a mapping: descend rather than tally, or its children
            // are counted once as themselves and once inside their parent.
            if info.is_submap != 0 {
                depth += 1
                continue
            }

            regions += 1
            // File-backed dirt is the file's, not the process's: including it inflates the total
            // past the `phys_footprint` it exists to explain.
            if info.external_pager == 0 {
                let footprint = (Int(info.pages_dirtied) + Int(info.pages_swapped_out)) * pageSize
                if footprint > 0 {
                    tags[Int(info.user_tag), default: 0] += footprint
                }
            }

            let next = address.addingReportingOverflow(vm_address_t(size))
            if next.overflow || size == 0 { break }
            address = next.partialValue
        }

        guard regions > 0 else { return nil }
        regionCount = regions
        return tags
    }

    // MARK: - Tag names

    /// The subset worth naming for a playback process. Anything else prints its number, which is
    /// still enough to look up in `<mach/vm_statistics.h>` or to compare across two runs.
    private static let names: [Int: String] = [
        0: "UNTAGGED", 1: "MALLOC", 2: "MALLOC_SMALL", 3: "MALLOC_LARGE", 4: "MALLOC_HUGE",
        5: "SBRK", 6: "REALLOC", 7: "MALLOC_TINY", 8: "MALLOC_LARGE_REUSABLE",
        9: "MALLOC_LARGE_REUSED", 10: "ANALYSIS_TOOL", 11: "MALLOC_NANO", 12: "MALLOC_MEDIUM",
        20: "MACH_MSG", 21: "IOKIT", 30: "STACK", 31: "GUARD", 32: "SHARED_PMAP", 33: "DYLIB",
        34: "OBJC_DISPATCHERS", 35: "UNSHARED_PMAP", 40: "APPKIT", 41: "FOUNDATION",
        42: "COREGRAPHICS", 43: "CORESERVICES", 45: "COREDATA", 50: "ATS", 51: "LAYERKIT",
        52: "CGIMAGE", 53: "TCMALLOC", 54: "COREGRAPHICS_DATA", 55: "COREGRAPHICS_SHARED",
        56: "COREGRAPHICS_FRAMEBUFFERS", 57: "COREGRAPHICS_BACKINGSTORES", 60: "DYLD",
        61: "DYLD_MALLOC", 62: "SQLITE", 63: "JAVASCRIPT_CORE", 66: "GLSL", 67: "OPENCL",
        69: "COREIMAGE", 71: "IMAGEIO", 73: "ASSETSD", 74: "OS_ALLOC_ONCE", 75: "LIBDISPATCH",
        76: "ACCELERATE", 77: "COREUI", 79: "GENEALOGY", 82: "SWIFT_RUNTIME", 83: "SWIFT_METADATA",
        84: "DHMM", 86: "SCENEKIT", 87: "SKYWALK", 88: "IOSURFACE_ALT", 91: "IOSURFACE",
        92: "LIBNETWORK", 93: "AUDIO", 94: "VIDEOBITSTREAM", 95: "CM_XPC", 96: "CM_RPC",
        97: "CM_MEMORYPOOL", 98: "CM_READCACHE", 99: "CM_CRABS", 100: "QUICKLOOK"
    ]

    static func tagName(_ tag: Int) -> String {
        names[tag] ?? "tag\(tag)"
    }
}
