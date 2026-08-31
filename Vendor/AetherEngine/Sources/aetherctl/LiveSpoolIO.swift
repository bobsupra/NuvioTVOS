import Foundation
import AetherEngine

// MARK: - customio --live

/// AE#445 repro shape: a host-owned live spool behind `MediaSource.custom`.
///
/// The reporter's adapter is a ring over a disk-backed spool fed by one continuous upstream
/// socket. Four properties of that shape decide how the engine treats the source, and all four
/// are reproduced here rather than approximated:
///
///  - **Never EOF.** At the live edge `read` blocks until the pacer releases more bytes; it never
///    returns 0, so nothing downstream can terminate on end of stream.
///  - **Paced at the mux rate.** A file read at disk speed parks the producer on backpressure
///    within seconds and then reads almost nothing, which is the opposite of a live session. The
///    pacer releases `rateBytesPerSecond` against a wall clock, so the demux thread spends the
///    session where a real one does: blocked at the edge.
///  - **Unknown size.** `AVSEEK_SIZE` answers negative (`--unknown-size`, the default here), so
///    the engine has no byte axis to bound anything by.
///  - **Seekable by logical offset.** `SEEK_SET`/`SEEK_CUR` succeed inside the delivered span,
///    which is what makes `CustomIOReaderBridge.isSeekable` true. A forward-only reader takes a
///    different route through the engine and would answer a different question.
///
/// **The reader allocates nothing per read, and that is the point.** AE#445 round 1 measured this
/// harness with a `FileHandle.readData` reader, which strands one autoreleased `Data` per read on
/// the pump thread. It reproduced the reporter's signature exactly (retention ratio 1.00) and the
/// pool fix flattened it, but the reporter's own adapter reads with `pread` into the engine's
/// buffer and allocates nothing, so that run measured the HARNESS rather than his case. The default
/// arm is therefore the allocation-free one: what it measures is the engine. `--foundation-reader`
/// restores the allocating arm, which is now a control for the pool rather than the subject.
/// AE#445 round 3: the ingest-side carry, as a POSITIVE control.
///
/// The reporter's census named his growing block precisely: one `REALLOC`-tagged allocation on an
/// exact x1.25 ladder whose content is every byte the session consumed. That factor is Foundation's,
/// not libav's (`Data.__DataStorage._grow` adds `newLength >> 2` above 128 KB; `av_fast_realloc`
/// adds a sixteenth, the AVIO dynamic buffer a half), so the block is a Swift `Data`, and the one
/// `Data` shape that grows like that while its `count` stays small is a parse carry consumed from
/// the front with `removeFirst`: that only advances the slice's lower bound, so the backing store
/// keeps every byte below it and reallocs to fit the ever-rising upper bound. The engine paid for
/// this lesson twice on its own readers (70430de, `ByteFIFO`) and re-bases with `subdata` in both.
///
/// `--host-carry removeFirst` puts that shape back into the harness on purpose, so the tool that
/// measures the engine at ratio 0.00 can also produce the reporter's ratio 1.00 on demand and name
/// the cause. `--host-carry subdata` is the same carry re-based, which is the fix.
enum HostCarryTrim: String {
    case none, removeFirst, subdata
}

final class PacedLiveSpoolIOReader: IOReader, @unchecked Sendable {
    private let path: String
    /// Foundation arm only. The POSIX arm reads through `fd` and never builds an object.
    private let handle: FileHandle?
    private let fd: Int32
    private let fileSize: Int64
    private let rateBytesPerSecond: Double
    private let reportsSize: Bool
    private let wraps: Bool

    private let lock = NSLock()
    private var position: Int64 = 0
    /// Total bytes the pacer has released; the live edge in logical-offset terms.
    private var released: Int64 = 0
    private var startTime = Date()
    private var cancelled = false

    /// Lifetime bytes handed to the engine, for the harness's own throughput line.
    private(set) var bytesRead: Int64 = 0

    /// AE#445: the furthest the engine ever reached BACK from the live edge, in bytes, and how many
    /// seeks it took. A live host's ring has to keep everything the engine might still ask for, so
    /// this is the figure that sizes it. Bounded means a ring can be bounded; growing with the
    /// session means the host is being asked to keep the whole stream, which is a retention defect
    /// on the engine's side of the seam even though it shows up in the host's footprint.
    private(set) var maxLookbackBytes: Int64 = 0
    private(set) var seekCount: Int = 0

    /// Host-side parse carry (see `HostCarryTrim`). Bounded in `count` by construction: everything
    /// but the partial trailing TS packet is consumed on every fill.
    private let carryTrim: HostCarryTrim
    private var carry = Data()
    private(set) var carryCount = 0
    /// The slice's lower bound, which is the whole tell: for a re-based carry it stays 0, for a
    /// `removeFirst` one it equals every byte ever consumed, and the backing store is that large.
    private(set) var carryStartIndex = 0

    init(path: String, rateKbps: Int, reportsSize: Bool, wraps: Bool,
         foundationRead: Bool = false, carryTrim: HostCarryTrim = .none) throws {
        self.path = path
        self.carryTrim = carryTrim
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        self.fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if foundationRead {
            guard let h = FileHandle(forReadingAtPath: path) else {
                throw NSError(domain: "aetherctl", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"])
            }
            self.handle = h
            self.fd = -1
        } else {
            let descriptor = open(path, O_RDONLY)
            guard descriptor >= 0 else {
                throw NSError(domain: "aetherctl", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "cannot open \(path)"])
            }
            self.handle = nil
            self.fd = descriptor
        }
        self.rateBytesPerSecond = Double(rateKbps) * 1000.0 / 8.0
        self.reportsSize = reportsSize
        self.wraps = wraps
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer = buffer, size > 0 else { return -1 }
        let want = Int(size)

        // Block at the live edge exactly as a ring over an upstream socket does: wait until the
        // pacer has released bytes past the read cursor. Polling rather than a condition variable
        // keeps the reader honest about `cancel()` unblocking a parked read.
        while true {
            lock.lock()
            if cancelled { lock.unlock(); return -1 }
            let elapsed = Date().timeIntervalSince(startTime)
            // Release in whole chunks, not in whatever fraction of a byte the clock has earned since
            // the last call. A byte-granular pacer answers every callback with a handful of bytes and
            // turns one leaked object per read into hundreds of thousands per second, which measures
            // the harness rather than the source: a ring over a socket hands out what has ARRIVED.
            let earned = Int64(elapsed * rateBytesPerSecond) / Self.releaseChunk * Self.releaseChunk
            released = min(earned, wraps ? .max : fileSize)
            let available = released - position
            if available > 0 {
                let n = min(want, Int(min(available, Int64(want))))
                let offset = wraps ? position % fileSize : position
                let contiguous = Int(min(Int64(n), fileSize - offset))
                let got: Int
                if let handle {
                    handle.seek(toFileOffset: UInt64(offset))
                    let chunk = handle.readData(ofLength: contiguous)
                    if chunk.isEmpty {
                        lock.unlock()
                        return 0  // genuine EOF: non-wrapping spool ran out of file
                    }
                    chunk.copyBytes(to: buffer, count: chunk.count)
                    got = chunk.count
                } else {
                    // The reporter's hot path: pread straight into the engine's buffer. No object is
                    // created, so no pool can drain anything, and whatever this arm retains is the
                    // engine's own.
                    got = pread(fd, buffer, contiguous, off_t(offset))
                    if got == 0 {
                        lock.unlock()
                        return 0  // genuine EOF: non-wrapping spool ran out of file
                    }
                    if got < 0 { lock.unlock(); return -1 }
                }
                position += Int64(got)
                bytesRead += Int64(got)
                feedCarryLocked(buffer, count: got)
                lock.unlock()
                return Int32(got)
            }
            if !wraps && position >= fileSize { lock.unlock(); return 0 }
            lock.unlock()
            usleep(20_000)
        }
    }

    /// Push the delivered bytes through the carry and consume whole TS packets, which is what a
    /// PCR indexer on the ingest side does. Called under `lock`.
    private func feedCarryLocked(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) {
        guard carryTrim != .none, count > 0 else { return }
        carry.append(buffer, count: count)
        let consumable = (carry.count / 188) * 188
        if consumable > 0 {
            switch carryTrim {
            case .removeFirst: carry.removeFirst(consumable)
            case .subdata:     carry = carry.subdata(in: consumable..<carry.count)
            case .none:        break
            }
        }
        carryCount = carry.count
        carryStartIndex = carry.startIndex
    }

    /// One upstream burst. 32 KB is the size the engine's own file reader is measured in (#243) and
    /// is large enough that the read cadence is set by the source, not by the pacer's resolution.
    private static let releaseChunk: Int64 = 32 * 1024

    private static let avSeekSize: Int32 = 0x10000

    func seek(offset: Int64, whence: Int32) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if whence == Self.avSeekSize { return reportsSize ? fileSize : -1 }
        switch whence {
        case 0: position = max(0, offset)               // SEEK_SET
        case 1: position = max(0, position + offset)    // SEEK_CUR
        case 2: return -1                               // no end to seek to on a live spool
        default: return -1
        }
        seekCount += 1
        maxLookbackBytes = max(maxLookbackBytes, released - position)
        return position
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    /// The reporter's spool hands out independent cursors; the engine uses them for the subtitle
    /// side reader. Same pacing, same edge.
    func makeIndependentReader() -> IOReader? {
        try? PacedLiveSpoolIOReader(path: path, rateKbps: Int(rateBytesPerSecond * 8.0 / 1000.0),
                                    reportsSize: reportsSize, wraps: wraps,
                                    foundationRead: handle != nil, carryTrim: carryTrim)
    }

    var discImageProbeEnabled: Bool { false }

    func close() {
        try? handle?.close()
        if fd >= 0 { Darwin.close(fd) }
    }
}

/// Long-running live session over a custom reader, with a memory trace.
///
/// The engine's own 30 s `memprobe` carries the itemized buckets; this loop adds the one figure
/// jetsam actually enforces (`phys_footprint`) at a 10 s cadence plus its slope, so a retention
/// defect states itself as MB/s against the source's own mux rate rather than as a shape in a
/// graph. macOS has no jetsam, so the run cannot be killed here: the slope IS the finding.
func runCustomLiveSpool(path: String, seconds: Double, rateKbps: Int, dvrWindow: Double?,
                        reportsSize: Bool, wraps: Bool, mallocCensus: Bool,
                        foundationReader: Bool = false, carryTrim: HostCarryTrim = .none) -> Int32 {
    EngineLog.handler = { print($0) }
    if mallocCensus {
        // Uncapped captures: a steady mux-rate climb spends one capture per threshold climbed, so the
        // default twelve are gone long before a long run ends (AE#445 hit the cap 4.4 min early).
        AetherEngine.setLargeAllocationCensusEnabled(true, triggerThresholdMB: 32, triggerPollHz: 8,
                                                     triggerCaptureCap: 0)
    }
    print("aetherctl customio --live: \(path) (rate=\(rateKbps) kbit/s seconds=\(seconds) "
          + "dvrWindow=\(dvrWindow.map { String($0) } ?? "nil") size=\(reportsSize ? "reported" : "unknown") "
          + "wrap=\(wraps) census=\(mallocCensus) "
          + "reader=\(foundationReader ? "foundation" : "posix") hostCarry=\(carryTrim.rawValue))")
    let box = UncheckedBox<Int32?>(nil)
    Task { @MainActor in
        box.value = await customLiveSpoolRun(path: path, seconds: seconds, rateKbps: rateKbps,
                                             dvrWindow: dvrWindow, reportsSize: reportsSize, wraps: wraps,
                                             foundationReader: foundationReader, carryTrim: carryTrim)
        CFRunLoopStop(CFRunLoopGetMain())
    }
    CFRunLoopRun()
    return box.value ?? 1
}

@MainActor
private func customLiveSpoolRun(path: String, seconds: Double, rateKbps: Int, dvrWindow: Double?,
                                reportsSize: Bool, wraps: Bool, foundationReader: Bool,
                                carryTrim: HostCarryTrim) async -> Int32 {
    let reader: PacedLiveSpoolIOReader
    do {
        reader = try PacedLiveSpoolIOReader(path: path, rateKbps: rateKbps,
                                            reportsSize: reportsSize, wraps: wraps,
                                            foundationRead: foundationReader, carryTrim: carryTrim)
    } catch {
        print("VERDICT: reader init failed: \(error.localizedDescription)")
        return 1
    }

    let engine: AetherEngine
    do { engine = try AetherEngine() } catch {
        print("VERDICT: engine init failed: \(error.localizedDescription)")
        return 1
    }

    var options = LoadOptions()
    options.suppressDisplayCriteria = true
    options.isLive = true
    options.dvrWindowSeconds = dvrWindow

    do {
        try await engine.load(source: .custom(reader, formatHint: "mpegts"), options: options)
    } catch {
        print("VERDICT: load failed: \(error.localizedDescription)")
        engine.stop()
        return 1
    }

    let start = Date()
    var firstSample: (t: Double, footprint: Int)?
    var lastSample: (t: Double, footprint: Int)?
    var tick = 0
    while Date().timeIntervalSince(start) < seconds {
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        tick += 1
        let elapsed = Date().timeIntervalSince(start)
        let fp = Int(physFootprintBytes() / 1_048_576)
        let srcMB = Double(reader.bytesRead) / 1_048_576.0
        // Settle for a minute before anchoring the slope: load, probe and the first segments are
        // a step, not a rate, and an anchor inside them flatters or damns the run by accident.
        if elapsed >= 60, firstSample == nil { firstSample = (elapsed, fp) }
        lastSample = (elapsed, fp)
        let slope = firstSample.map { f -> String in
            let dt = elapsed - f.t
            guard dt > 1 else { return "n/a" }
            return String(format: "%.2f", Double(fp - f.footprint) / dt)
        } ?? "n/a"
        let carryLine = carryTrim == .none ? "" : String(
            format: " carryCount=%dB carryStart=%.1fMB",
            reader.carryCount, Double(reader.carryStartIndex) / 1_048_576.0)
        print(String(format: "  t=%.0fs state=%@ pos=%.2fs physFP=%dMB srcMB=%.1f growthMBps=%@%@",
                     elapsed, "\(engine.state)", engine.currentTime, fp, srcMB, slope, carryLine))
        if case .error(let msg) = engine.state {
            print("VERDICT: session errored: \(msg)")
            engine.stop()
            return 1
        }
    }

    let srcMBps = Double(rateKbps) * 1000.0 / 8.0 / 1_048_576.0
    let lookbackMB = Double(reader.maxLookbackBytes) / 1_048_576.0
    print(String(format: "LOOKBACK: %d seeks, deepest reach-back %.1f MB behind the live edge "
                 + "(%.0f s of source at this rate)",
                 reader.seekCount, lookbackMB, lookbackMB / srcMBps))
    if carryTrim != .none {
        // The verdict is the lower bound, not the count: a carry that starts at 0 owns exactly its
        // count, and one whose start tracks the consumed stream owns all of it.
        let startMB = Double(reader.carryStartIndex) / 1_048_576.0
        let reading = reader.carryStartIndex > (1 << 20)
            ? "riding a backing store that large"
            : "re-based, so the allocation is the count"
        print(String(format: "HOST CARRY (%@): count=%dB, slice lower bound %.1f MB: %@.",
                     carryTrim.rawValue, reader.carryCount, startMB, reading))
    }
    if let f = firstSample, let l = lastSample, l.t - f.t > 30 {
        let growth = Double(l.footprint - f.footprint) / (l.t - f.t)
        print(String(format: "VERDICT: physFP %d -> %d MB over %.0fs = %.2f MB/s "
                     + "(source mux rate %.2f MB/s, retention ratio %.2f)",
                     f.footprint, l.footprint, l.t - f.t, growth, srcMBps, growth / srcMBps))
    } else {
        print("VERDICT: run too short to state a slope (need > 90s)")
    }
    engine.stop()
    try? await Task.sleep(nanoseconds: 2_000_000_000)
    return 0
}
