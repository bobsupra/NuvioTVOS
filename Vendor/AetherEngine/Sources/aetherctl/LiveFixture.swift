// LiveFixture: a synthetic, offline, never-ending MPEG-TS source for
// the `aetherctl live` harness.
//
// Serves an endless MPEG-TS over HTTP loopback by repeating a finite
// seed `.ts` payload, rewriting per-loop timestamps so the served
// stream looks like a genuine live broadcast with monotonically
// advancing PTS / PCR across loop boundaries (a naive byte-repeat
// would reset timestamps to the seed's start every loop, and the
// demuxer would read every loop seam as a discontinuity / backward
// jump).
//
// What gets rewritten per loop:
//   - PCR (adaptation-field, 33-bit base + 9-bit ext at 27 MHz) gets
//     `loopIndex * loopPeriodTicks * 300` added to the base.
//   - PES PTS and DTS (33-bit, 90 kHz) get `loopIndex * loopPeriodTicks`
//     added. The seed here is PTS-only (no DTS), but DTS is handled too
//     so a different seed still works.
//   - Transport continuity_counter (low nibble of the 2nd header byte
//     group, `packet[3] & 0x0F`) keeps incrementing per-PID across loop
//     boundaries instead of restarting at the seed's first value, so
//     the demuxer sees no continuity error at the seam.
//
// `loopPeriodTicks` is (max PTS - min PTS) + one frame interval, so
// loop N+1's first timestamp sits exactly one frame after loop N's
// last, which is what a real CBR feed produces.
//
// No `Content-Length`. The socket streams TS packets until the client
// disconnects (`Connection: close`), so `AVIOReader` + the demuxer see
// a feed with no end. URL shape: `http://127.0.0.1:<port>/live.ts`.
//
// Socket scaffolding (socket / bind / listen / accept / send) mirrors
// `HLSLocalServer` deliberately: Darwin BSD sockets, not
// Network.framework. See that file's header for the rationale.
//
// YAGNI: a single initializer, no drop / discontinuity injection. Later
// tasks add `--drop-after` / `--discontinuity-at`; this fixture is the
// clean baseline.

import Darwin
import Foundation

final class LiveFixture: @unchecked Sendable {

    // MARK: - Errors

    enum LiveFixtureError: Error, CustomStringConvertible {
        case seedMissing(path: String)
        case seedNotTS(path: String, size: Int)
        case socketCreate(errno: Int32)
        case bind(errno: Int32)
        case listen(errno: Int32)
        case getsockname(errno: Int32)

        var description: String {
            switch self {
            case .seedMissing(let p):
                return "LiveFixture: seed fixture missing at \(p). Expected an H.264 MPEG-TS sample. Pass --seed <path> to override."
            case .seedNotTS(let p, let size):
                return "LiveFixture: seed at \(p) is \(size) bytes, not a whole number of 188-byte TS packets. Not a raw MPEG-TS file."
            case .socketCreate(let e): return "LiveFixture: socket() failed (errno=\(e))"
            case .bind(let e):         return "LiveFixture: bind() failed (errno=\(e))"
            case .listen(let e):       return "LiveFixture: listen() failed (errno=\(e))"
            case .getsockname(let e):  return "LiveFixture: getsockname() failed (errno=\(e))"
            }
        }
    }

    // MARK: - TS constants

    private static let tsPacketSize = 188
    private static let syncByte: UInt8 = 0x47
    /// 90 kHz tick modulus for PCR base; extension runs at 27 MHz (base * 300 + ext).
    private static let pcrExtModulus: Int64 = 300

    // MARK: - Seed

    private let seedPackets: [Data]
    private let loopPeriodTicks: Int64 // per-loop PTS/DTS/PCR-base increment in 90 kHz ticks
    // MARK: - Socket state

    private var listenFd: Int32 = -1
    private var shouldStop = false
    private var clientFds = Set<Int32>()
    private let stateLock = NSLock()
    private(set) var port: UInt16 = 0

    /// Close the first accepted connection after N seconds to simulate a recoverable mid-stream drop. Subsequent connections are served normally.
    var dropAfterSeconds: Double? = nil
    private var didFireDrop = false // latched after the one-shot drop fires

    /// One-shot PTS/DTS/PCR forward jump after N seconds of serving, simulating a broadcast program boundary. Engine must survive it.
    var discontinuityAfterSeconds: Double? = nil
    var discontinuityJumpTicks: Int64 = 1000 * 90_000 // +1000s default, well beyond discontinuity-detection threshold

    /// Pace output at ~1x wall-clock so the producer/AVPlayer cannot race ahead of real time. Default false (as-fast-as-socket-drains).
    var paced = false
    var pacingLeadSeconds: Double = 2.0 // max emitter lead before sleeping
    /// Preroll served at full speed before the 1x gate engages, so the producer can finalize its first segment before AVPlayer's initial-buffering stall timer (CoreMedia -12888).
    var pacingPrerollSeconds: Double = 30.0
    private var discontinuityArmed = false // timer-driven so the jump fires even while serve loop is blocked in send()
    private var didFireDiscontinuity = false

    private let acceptQueue = DispatchQueue(
        label: "com.aetherengine.livefixture.accept",
        qos: .userInitiated
    )
    /// Global wall-clock zero; reconnecting clients derive a loop index from "now" so they see the clock having advanced (like a real broadcast).
    private let fixtureStart = Date()

    /// Highest loopIndex emitted across all connections. Reconnects must start above this: wall-clock derivation alone undershoots an unpaced connection that raced far ahead.
    private var highWaterLoopIndex: Int64 = -1

    private let workQueue = DispatchQueue(
        label: "com.aetherengine.livefixture.work",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // MARK: - Init

    /// Build the fixture from a seed `.ts` file (must be a whole-packet MPEG-TS).
    init(seedPath: String) throws {
        guard FileManager.default.fileExists(atPath: seedPath) else {
            throw LiveFixtureError.seedMissing(path: seedPath)
        }
        let raw = try Data(contentsOf: URL(fileURLWithPath: seedPath))
        guard raw.count > 0,
              raw.count % LiveFixture.tsPacketSize == 0,
              raw[raw.startIndex] == LiveFixture.syncByte else {
            throw LiveFixtureError.seedNotTS(path: seedPath, size: raw.count)
        }

        var packets: [Data] = []
        packets.reserveCapacity(raw.count / LiveFixture.tsPacketSize)
        var idx = raw.startIndex
        while idx < raw.endIndex {
            let end = raw.index(idx, offsetBy: LiveFixture.tsPacketSize)
            packets.append(raw.subdata(in: idx..<end))
            idx = end
        }
        self.seedPackets = packets

        // loopPeriod = PTS span + one frame interval so next loop starts exactly one frame after the previous loop's last.
        let span = LiveFixture.measureTimestampSpan(packets: packets)
        let frameInterval = span.frameInterval > 0 ? span.frameInterval : 3750 // fallback ~30fps
        let rawPeriod = (span.maxPTS - span.minPTS) + frameInterval
        self.loopPeriodTicks = rawPeriod > 0 ? rawPeriod : 450_000 // 5s fallback when no parseable PTS
    }

    // MARK: - Lifecycle

    /// Bind + listen, spawn the accept/serve loop, and return the live URL.
    func start() throws -> URL {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw LiveFixtureError.socketCreate(errno: errno) }

        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on,
                       socklen_t(MemoryLayout<Int32>.size))
        // SO_NOSIGPIPE: send() returns EPIPE instead of raising SIGPIPE on disconnect.
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                       socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno; close(fd)
            throw LiveFixtureError.bind(errno: err)
        }

        guard listen(fd, 16) == 0 else {
            let err = errno; close(fd)
            throw LiveFixtureError.listen(errno: err)
        }

        var actual = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getNameResult = withUnsafeMutablePointer(to: &actual) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &actualLen)
            }
        }
        guard getNameResult == 0 else {
            let err = errno; close(fd)
            throw LiveFixtureError.getsockname(errno: err)
        }
        let assignedPort = UInt16(bigEndian: actual.sin_port)

        stateLock.lock()
        listenFd = fd
        port = assignedPort
        shouldStop = false
        stateLock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }

        guard let url = URL(string: "http://127.0.0.1:\(assignedPort)/live.ts") else {
            throw LiveFixtureError.getsockname(errno: 0) // unreachable
        }
        return url
    }

    func stop() {
        stateLock.lock()
        shouldStop = true
        let fdToClose = listenFd
        listenFd = -1
        port = 0
        let clients = clientFds
        clientFds.removeAll()
        stateLock.unlock()

        if fdToClose >= 0 { close(fdToClose) }
        for fd in clients { close(fd) }
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while true {
            stateLock.lock()
            let stopping = shouldStop
            let fd = listenFd
            stateLock.unlock()
            if stopping || fd < 0 { return }

            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &clientLen)
                }
            }
            if clientFd < 0 {
                let err = errno
                if err == EBADF || err == EINVAL { return }
                if err == EINTR || err == EAGAIN { continue }
                // Unexpected errno (e.g. EMFILE): print so it is not silently confused with an engine-side connect failure.
                print("[LiveFixture] accept failed: errno=\(err); accept loop exiting")
                return
            }

            var on: Int32 = 1
            _ = setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &on,
                           socklen_t(MemoryLayout<Int32>.size))

            stateLock.lock()
            clientFds.insert(clientFd)
            stateLock.unlock()

            workQueue.async { [weak self] in
                self?.serve(clientFd)
            }
        }
    }

    // MARK: - Per-connection serve

    /// Stream rewritten TS packets until peer disconnects or stop() runs. Optionally injects one mid-stream drop.
    private func serve(_ fd: Int32) {
        // Close ownership: whichever of the drop timer, stop(), or this defer removes fd from clientFds (under stateLock) owns the close. This prevents double-close on recycled fd numbers.
        defer {
            stateLock.lock()
            let owned = clientFds.remove(fd) != nil
            stateLock.unlock()
            if owned {
                close(fd)
            }
        }

        guard readRequest(fd) else { return } // drain request headers

        let header =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: video/mp2t\r\n" +
            "Cache-Control: no-cache, no-store\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        guard writeAll(fd: fd, bytes: Array(header.utf8)) else { return }

        // Schedule an RST (SO_LINGER=0) after dropAfterSeconds on the first connection: URLSession gets a network error, exercising the reader's reconnect path.
        stateLock.lock()
        let shouldScheduleDrop = (dropAfterSeconds != nil && !didFireDrop)
        let dropDelay = dropAfterSeconds ?? 0
        stateLock.unlock()

        if shouldScheduleDrop {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                // Claim fd by removing from clientFds; if the connection already ended the fd may be recycled, so skip close and re-arm the drop.
                let owned = !self.didFireDrop && self.clientFds.remove(fd) != nil
                if owned { self.didFireDrop = true }
                self.stateLock.unlock()
                if owned {
                    print("[LiveFixture] Injecting mid-stream drop after ~\(Int(dropDelay))s (fd=\(fd))")
                    // SO_LINGER l_linger=0 causes close() to send RST.
                    var ling = Darwin.linger()
                    ling.l_onoff = 1
                    ling.l_linger = 0
                    _ = setsockopt(fd, SOL_SOCKET, SO_LINGER,
                                   &ling, socklen_t(MemoryLayout<Darwin.linger>.size))
                    Darwin.close(fd)
                }
            }
            workQueue.asyncAfter(deadline: .now() + dropDelay, execute: item)
        }

        var ccByPID: [Int: UInt8] = [:] // per-PID continuity counter, carried across loop seams
        // Derive the starting loop index from wall-clock elapsed since fixture start; clamp above the high-water mark so reconnects don't jump backward.
        let wallDerived: Int64 = loopPeriodTicks > 0
            ? Int64((Date().timeIntervalSince(fixtureStart) * 90_000.0) / Double(loopPeriodTicks))
            : 0
        stateLock.lock()
        let startLoopIndex = max(wallDerived, highWaterLoopIndex + 1)
        stateLock.unlock()
        var loopIndex: Int64 = startLoopIndex

        // One-shot discontinuity: armed by a timer so it fires on schedule even while serve() is blocked in send().
        stateLock.lock()
        let discontinuityAfter = discontinuityAfterSeconds
        let discontinuityJump = discontinuityJumpTicks
        let scheduleDiscontinuity = (discontinuityAfter != nil && !didFireDiscontinuity)
        stateLock.unlock()
        if let after = discontinuityAfter, scheduleDiscontinuity {
            workQueue.asyncAfter(deadline: .now() + after) { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                if !self.didFireDiscontinuity {
                    self.didFireDiscontinuity = true
                    self.discontinuityArmed = true
                    print("[LiveFixture] Arming one-shot PTS/PCR discontinuity "
                          + "after ~\(Int(after))s (+\(discontinuityJump / 90_000)s jump)")
                }
                self.stateLock.unlock()
            }
        }
        var discontinuityOffset: Int64 = 0

        var scratch = [UInt8](repeating: 0, count: LiveFixture.tsPacketSize) // reused per-packet; no steady-state alloc

        let loopPeriodSeconds = Double(loopPeriodTicks) / 90_000.0
        let packetsPerLoop = max(1, seedPackets.count)
        var pacingClockStart: Date? = nil // wall-clock zero for the 1x gate (set after preroll)

        while true {
            stateLock.lock()
            let stopping = shouldStop
            stateLock.unlock()
            if stopping { return }

            for (packetIndex, packet) in seedPackets.enumerated() {
                // Real-time gate: hold the average emit rate at ~1x. Sleep in
                // coarse slices whenever the emitted media-time runs more than
                // `pacingLeadSeconds` ahead of wall-clock elapsed. Coarse on
                // purpose (no per-packet sleep): we only re-check + nap when the
                // lead is exceeded, which keeps overhead negligible while still
                // holding the long-run rate.
                if paced {
                    let emittedMedia = Double(loopIndex - startLoopIndex) * loopPeriodSeconds
                        + (Double(packetIndex) / Double(packetsPerLoop)) * loopPeriodSeconds
                    if emittedMedia > pacingPrerollSeconds {
                        if pacingClockStart == nil { pacingClockStart = Date() }
                        let mediaPastPreroll = emittedMedia - pacingPrerollSeconds
                        while paced {
                            stateLock.lock()
                            let stopNow = shouldStop
                            stateLock.unlock()
                            if stopNow { return }
                            let wall = Date().timeIntervalSince(pacingClockStart!)
                            let lead = mediaPastPreroll - wall
                            if lead <= pacingLeadSeconds { break }
                            let nap = min(lead - pacingLeadSeconds, 0.25) // cap each nap so stop() is honoured promptly
                            usleep(useconds_t(max(0.005, nap) * 1_000_000))
                        }
                    }
                }
                // Poll armed flag per packet: the loop can be parked in a back-pressured send() for many seconds.
                if discontinuityOffset == 0 {
                    stateLock.lock()
                    let armed = discontinuityArmed
                    stateLock.unlock()
                    if armed {
                        discontinuityOffset = discontinuityJump
                        print("[LiveFixture] Injecting one-shot PTS/PCR discontinuity "
                              + "(+\(discontinuityJump / 90_000)s jump, fd=\(fd))")
                    }
                }
                let tsOffset = loopIndex * loopPeriodTicks &+ discontinuityOffset
                packet.copyBytes(to: &scratch, count: LiveFixture.tsPacketSize)
                rewritePacket(&scratch, tsOffset: tsOffset, ccByPID: &ccByPID)
                if !writeAll(fd: fd, bytes: scratch) {
                    return // peer gone or fd closed by drop timer
                }
            }

            loopIndex &+= 1
            stateLock.lock()
            if loopIndex > highWaterLoopIndex { highWaterLoopIndex = loopIndex }
            stateLock.unlock()
        }
    }

    /// Read until `\r\n\r\n` (end of HTTP headers) or EOF.
    private func readRequest(_ fd: Int32) -> Bool {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { ptr -> Int in
                recv(fd, ptr.baseAddress, ptr.count, 0)
            }
            if n == 0 { return !buffer.isEmpty }
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                return false
            }
            buffer.append(contentsOf: chunk[0..<n])
            if headersComplete(buffer) {
                return true
            }
            if buffer.count > 8192 { return false }
        }
    }

    private func headersComplete(_ buf: [UInt8]) -> Bool {
        guard buf.count >= 4 else { return false }
        var i = 0
        while i <= buf.count - 4 {
            if buf[i] == 0x0D && buf[i + 1] == 0x0A
                && buf[i + 2] == 0x0D && buf[i + 3] == 0x0A {
                return true
            }
            i += 1
        }
        return false
    }

    private func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var written = 0
        let total = bytes.count
        if total == 0 { return true }
        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            while written < total {
                let result = send(fd, base.advanced(by: written), total - written, 0)
                if result < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    return false // EPIPE / ECONNRESET / etc.
                }
                if result == 0 { return false }
                written += result
            }
            return true
        }
    }

    // MARK: - TS packet rewrite

    /// Add `tsOffset` (90 kHz ticks) to PCR/PTS/DTS in place and rewrite the continuity_counter per-PID across loop boundaries.
    private func rewritePacket(_ p: inout [UInt8], tsOffset: Int64, ccByPID: inout [Int: UInt8]) {
        guard p[0] == LiveFixture.syncByte else { return }

        let pid = (Int(p[1] & 0x1F) << 8) | Int(p[2])
        let afc = (p[3] >> 4) & 0x3            // adaptation_field_control
        let hasAF = (afc & 0x2) != 0
        let hasPayload = (afc & 0x1) != 0
        let pusi = (p[1] >> 6) & 0x1           // payload_unit_start_indicator

        // Per H.222: CC increments only on payload-carrying packets (afc 0x1 or 0x3); adaptation-only packets repeat the previous CC.
        if pid != 0x1FFF {
            if hasPayload {
                let next = (ccByPID[pid].map { ($0 &+ 1) & 0x0F }) ?? (p[3] & 0x0F)
                ccByPID[pid] = next
                p[3] = (p[3] & 0xF0) | next
            } else {
                // Adaptation-only: repeat last CC for this PID if we have one.
                if let last = ccByPID[pid] {
                    p[3] = (p[3] & 0xF0) | last
                }
            }
        }

        if tsOffset == 0 { return } // loop 0: timestamps unchanged

        // --- adaptation field: PCR ---
        var payloadOffset = 4
        if hasAF {
            let afLen = Int(p[4])
            if afLen > 0 {
                let flags = p[5]
                let pcrFlag = (flags >> 4) & 0x1
                if pcrFlag != 0 {
                    // PCR: p[6..<12] = 33-bit base, 6 reserved bits, 9-bit ext. value = base * 300 + ext.
                    let b0 = Int64(p[6]), b1 = Int64(p[7]), b2 = Int64(p[8])
                    let b3 = Int64(p[9]), b4 = Int64(p[10]), b5 = Int64(p[11])
                    let base = (b0 << 25) | (b1 << 17) | (b2 << 9) | (b3 << 1) | (b4 >> 7)
                    let ext = ((b4 & 0x1) << 8) | b5
                    var full = base * LiveFixture.pcrExtModulus + ext
                    full &+= tsOffset * LiveFixture.pcrExtModulus
                    let newBase = (full / LiveFixture.pcrExtModulus) & 0x1_FFFF_FFFF
                    let newExt = full % LiveFixture.pcrExtModulus
                    p[6] = UInt8((newBase >> 25) & 0xFF)
                    p[7] = UInt8((newBase >> 17) & 0xFF)
                    p[8] = UInt8((newBase >> 9) & 0xFF)
                    p[9] = UInt8((newBase >> 1) & 0xFF)
                    // p[10] = (baseLSB<<7) | (0x3F<<1) | extHigh; reconstruct preserving reserved bits.
                    let baseLSB: Int64 = (newBase & 0x1) << 7
                    let reserved: Int64 = 0x3F << 1
                    let extHigh: Int64 = (newExt >> 8) & 0x1
                    p[10] = UInt8((baseLSB | reserved | extHigh) & 0xFF)
                    p[11] = UInt8(newExt & 0xFF)
                }
            }
            payloadOffset = 5 + afLen
        }

        guard hasPayload, pusi != 0, payloadOffset <= 184 else { return }
        let pl = payloadOffset
        guard pl + 9 <= LiveFixture.tsPacketSize,
              p[pl] == 0x00, p[pl + 1] == 0x00, p[pl + 2] == 0x01 else { return }
        let ptsDtsFlags = (p[pl + 7] >> 6) & 0x3
        guard ptsDtsFlags & 0x2 != 0 else { return }

        if pl + 14 <= LiveFixture.tsPacketSize { // PTS at p[pl+9..<pl+14]
            rewriteTimestampField(&p, at: pl + 9, offset: tsOffset, marker: ptsDtsFlags == 0x3 ? 0x3 : 0x2)
        }
        if ptsDtsFlags == 0x3, pl + 19 <= LiveFixture.tsPacketSize { // DTS at p[pl+14..<pl+19]
            rewriteTimestampField(&p, at: pl + 14, offset: tsOffset, marker: 0x1)
        }
    }

    /// Decode a 5-byte PTS/DTS field, add `offset` mod 2^33, re-encode preserving the 4-bit prefix marker and marker bits.
    private func rewriteTimestampField(_ p: inout [UInt8], at i: Int, offset: Int64, marker: UInt8) {
        let b0 = Int64(p[i]), b1 = Int64(p[i + 1]), b2 = Int64(p[i + 2])
        let b3 = Int64(p[i + 3]), b4 = Int64(p[i + 4])
        let value =
            (((b0 >> 1) & 0x7) << 30) |
            (b1 << 22) |
            (((b2 >> 1) & 0x7F) << 15) |
            (b3 << 7) |
            (b4 >> 1)
        let nv = (value &+ offset) & 0x1_FFFF_FFFF // wrap at 33 bits
        // Re-encode: prefix nibble = marker (0010 PTS-only / 0011 PTS-with-DTS / 0001 DTS); each sub-field ends with marker_bit = 1.
        p[i] = UInt8((marker << 4) | UInt8(((nv >> 30) & 0x7) << 1) | 0x1)
        p[i + 1] = UInt8((nv >> 22) & 0xFF)
        p[i + 2] = UInt8(UInt8(((nv >> 15) & 0x7F) << 1) | 0x1)
        p[i + 3] = UInt8((nv >> 7) & 0xFF)
        p[i + 4] = UInt8(UInt8((nv & 0x7F) << 1) | 0x1)
    }

    // MARK: - Seed timestamp measurement

    private struct TimestampSpan {
        var minPTS: Int64
        var maxPTS: Int64
        var frameInterval: Int64
    }

    /// Scan all packets for min/max PES PTS and the most common adjacent-PTS delta (frame interval).
    private static func measureTimestampSpan(packets: [Data]) -> TimestampSpan {
        var ptsValues: [Int64] = []
        for packet in packets {
            let p = [UInt8](packet)
            guard p.count == tsPacketSize, p[0] == syncByte else { continue }
            let afc = (p[3] >> 4) & 0x3
            let hasPayload = (afc & 0x1) != 0
            let pusi = (p[1] >> 6) & 0x1
            var payloadOffset = 4
            if (afc & 0x2) != 0 {
                payloadOffset = 5 + Int(p[4])
            }
            guard hasPayload, pusi != 0, payloadOffset <= 184,
                  payloadOffset + 14 <= tsPacketSize else { continue }
            let pl = payloadOffset
            guard p[pl] == 0x00, p[pl + 1] == 0x00, p[pl + 2] == 0x01 else { continue }
            let ptsDtsFlags = (p[pl + 7] >> 6) & 0x3
            guard ptsDtsFlags & 0x2 != 0 else { continue }
            let b0 = Int64(p[pl + 9]), b1 = Int64(p[pl + 10]), b2 = Int64(p[pl + 11])
            let b3 = Int64(p[pl + 12]), b4 = Int64(p[pl + 13])
            let pts =
                (((b0 >> 1) & 0x7) << 30) |
                (b1 << 22) |
                (((b2 >> 1) & 0x7F) << 15) |
                (b3 << 7) |
                (b4 >> 1)
            ptsValues.append(pts)
        }

        guard !ptsValues.isEmpty else {
            return TimestampSpan(minPTS: 0, maxPTS: 0, frameInterval: 0)
        }
        let sorted = ptsValues.sorted()
        var deltaCounts: [Int64: Int] = [:]
        for i in 1..<sorted.count {
            let d = sorted[i] - sorted[i - 1]
            if d > 0 { deltaCounts[d, default: 0] += 1 }
        }
        let frameInterval = deltaCounts.max(by: { $0.value < $1.value })?.key ?? 0
        return TimestampSpan(minPTS: sorted.first!, maxPTS: sorted.last!, frameInterval: frameInterval)
    }
}
