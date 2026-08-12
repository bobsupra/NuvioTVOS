// #255 (dlev02): opening a 12.4 GB progressive HTTP source killed the app outright on a 6 GB iPhone,
// EXC_BREAKPOINT on a URLSession delegate queue before a frame played. `ChunkFetchDelegate` reserved
// whatever the response declared: `body.reserveCapacity(Int(http.expectedContentLength))`. One of the
// requests that reaches that line is the HEAD size probe, which declares the entire source and
// delivers no body at all, so the delegate asked malloc for 12.4 GB in order to buffer nothing. The
// allocation returned NULL and `__DataStorage.init(capacity:)` force-unwrapped it: a trap, not a
// throw, so a host app can neither catch it nor degrade.
//
// The same line is reached by ordinary bounded chunk fetches whenever an origin ignores `Range` and
// answers `200` with the whole source's length, so the second half of the fix is that the body itself
// is bounded by what the request asked for: past that, the reader hangs up instead of buffering a
// movie it would only reject afterwards.
//
// The arithmetic is unit-tested without a network; the wiring is measured against a scripted origin,
// because what must hold is that no response on the chunk path can size an allocation from a number
// the origin made up. On macOS an oversized reservation succeeds as untouched VM (which is why the
// crash is an iOS/tvOS report), so the observable here is the reservation itself, not a crash.
import Foundation
import Testing
@testable import AetherEngine

/// Minimal blocking HTTP origin on 127.0.0.1 whose reply to each request the test scripts. Keeps the
/// connection alive by default, so the reader's pooled chunk session behaves as it does in the field.
/// What a reply DECLARES and what it SENDS are independent, which is the whole point: both are the
/// origin's choice, and neither is a safe allocation size.
final class ScriptedOriginServer: @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let range: String?
    }

    struct Reply {
        var status: Int = 200
        /// Content-Length to declare. Nil means no length header at all (a chunked / length-less
        /// origin), which forces connection-close framing.
        var declaredLength: Int64?
        var contentRange: String?
        /// Filler bytes actually written. May be far below or above `declaredLength`.
        var bodyBytes: Int = 0
        var close: Bool = false
    }

    private let listenFD: Int32
    private let reply: @Sendable (Recorded) -> Reply
    private let lock = NSLock()
    private var _requests: [Recorded] = []
    private var _bodyBytesWritten = 0
    private var _connFDs: [Int32] = []
    private var _stopped = false

    let port: UInt16

    var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var bodyBytesWritten: Int {
        lock.lock(); defer { lock.unlock() }
        return _bodyBytesWritten
    }

    private var stopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopped
    }

    init?(reply: @escaping @Sendable (Recorded) -> Reply) {
        self.reply = reply
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            return nil
        }
        var named = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let gotName = withUnsafeMutablePointer(to: &named) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard gotName == 0 else {
            close(fd)
            return nil
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: named.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() {
        lock.lock()
        let fds = _connFDs
        _connFDs = []
        let already = _stopped
        _stopped = true
        lock.unlock()
        guard !already else { return }
        // shutdown unblocks a write parked on a full socket buffer; close alone may not.
        for fd in fds {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
    }

    private func acceptLoop() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            if _stopped {
                lock.unlock()
                shutdown(fd, SHUT_RDWR)
                close(fd)
                return
            }
            _connFDs.append(fd)
            lock.unlock()
            Thread.detachNewThread { [self] in
                while serveOneRequest(fd) {}
                closeConnection(fd)
            }
        }
    }

    /// Closes a connection exactly once. `stop()` closes every descriptor still registered, so a socket
    /// whose serving thread is done has to leave the registry before it closes: otherwise the kernel
    /// hands that number to the next opener (in practice a guarded descriptor), `stop()` closes it a
    /// second time, and the EXC_GUARD kills the whole test process instead of failing one test. The run
    /// then ends with no failing test and a bare exit 1.
    private func closeConnection(_ fd: Int32) {
        lock.lock()
        guard let index = _connFDs.firstIndex(of: fd) else {
            lock.unlock()
            return  // stop() owns this descriptor now
        }
        _connFDs.remove(at: index)
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }

    /// Returns false when the connection is done (client gone, malformed request, or a scripted close).
    private func serveOneRequest(_ fd: Int32) -> Bool {
        guard !stopped, let header = readRequestHeader(fd) else { return false }
        let lines = header.components(separatedBy: "\r\n")
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? "GET"
        let range = lines.first(where: { $0.lowercased().hasPrefix("range:") })
            .map { String($0.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces) }
        let recorded = Recorded(method: method, range: range)
        lock.lock()
        _requests.append(recorded)
        lock.unlock()

        let r = reply(recorded)
        let keepAlive = !r.close && r.declaredLength != nil
        var head = "HTTP/1.1 \(r.status) \(r.status == 206 ? "Partial Content" : "OK")\r\n"
        if let declared = r.declaredLength { head += "Content-Length: \(declared)\r\n" }
        if let cr = r.contentRange { head += "Content-Range: \(cr)\r\n" }
        head += "Accept-Ranges: bytes\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        guard writeFully(fd, Array(head.utf8)) else { return false }
        // A HEAD carries no body no matter what it declares: that disagreement IS the defect.
        guard method != "HEAD" else { return keepAlive }

        let sliceBytes = 256 * 1024
        let slice = [UInt8](repeating: 0x5A, count: sliceBytes)
        var sent = 0
        while sent < r.bodyBytes && !stopped {
            let n = min(sliceBytes, r.bodyBytes - sent)
            guard writeCounting(fd, Array(slice[0..<n])) else { return false }
            sent += n
            usleep(2000)                      // ~128 MB/s: leaves room for a cancel to land
        }
        return keepAlive
    }

    private func readRequestHeader(_ fd: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        var collected = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while collected.range(of: terminator) == nil {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return nil }
            collected.append(contentsOf: buf[0..<n])
            if collected.count > 64 * 1024 { return nil }
        }
        return String(data: collected, encoding: .utf8)
    }

    private func writeFully(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }

    private func writeCounting(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { raw in write(fd, raw.baseAddress, raw.count) }
            guard n > 0 else { return false }
            lock.lock()
            _bodyBytesWritten += n
            lock.unlock()
            sent += n
        }
        return true
    }
}

@Suite("#255 a declared Content-Length never sizes an allocation", .serialized)
struct Issue255BodyReserveTests {

    /// The reported source: 12.4 GB, the number the HEAD declared and malloc refused.
    private static let reportedLength: Int64 = 13_304_315_904
    /// Far below the 12.4 GB reservation the defect made, far above any legitimate one on this path
    /// (a chunk span or `maxBodyReserve`), so a parallel suite's own fetch cannot tip it.
    private static let reserveCeiling = 64 * 1024 * 1024

    // MARK: - What the request can deliver

    @Test("a HEAD can deliver no body at all")
    func headExpectsNothing() {
        var request = URLRequest(url: URL(string: "https://example.test/big.mkv")!)
        request.httpMethod = "HEAD"
        #expect(AVIOReader.expectedBodyBytes(for: request) == 0)
    }

    @Test("a bounded Range can deliver exactly its span")
    func boundedRangeExpectsSpan() {
        var request = URLRequest(url: URL(string: "https://example.test/big.mkv")!)
        request.setValue("bytes=0-4194303", forHTTPHeaderField: "Range")
        #expect(AVIOReader.expectedBodyBytes(for: request) == 4 * 1024 * 1024)
        request.setValue("bytes=8388608-8388608", forHTTPHeaderField: "Range")
        #expect(AVIOReader.expectedBodyBytes(for: request) == 1)
    }

    @Test("an open-ended or absent Range bounds nothing")
    func openEndedExpectsNil() {
        var request = URLRequest(url: URL(string: "https://example.test/big.mkv")!)
        #expect(AVIOReader.expectedBodyBytes(for: request) == nil)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        #expect(AVIOReader.expectedBodyBytes(for: request) == nil)
    }

    @Test("suffix, multi and malformed ranges bound nothing rather than the wrong thing")
    func unusableRangeFormsExpectNil() {
        #expect(AVIOReader.boundedRangeSpan("bytes=-500") == nil)
        #expect(AVIOReader.boundedRangeSpan("bytes=0-99,200-299") == nil)
        #expect(AVIOReader.boundedRangeSpan("bytes=100-0") == nil)
        #expect(AVIOReader.boundedRangeSpan("bytes=0-1-2") == nil)
        #expect(AVIOReader.boundedRangeSpan("items=0-10") == nil)
        #expect(AVIOReader.boundedRangeSpan("garbage") == nil)
    }

    // MARK: - What gets reserved

    @Test("the bodyless HEAD probe reserves nothing, whatever it declares")
    func headReservesNothing() {
        #expect(AVIOReader.bodyReservation(declaredLength: Self.reportedLength, limit: 0) == 0)
    }

    @Test("a whole-source declared length is clamped to the chunk the request asked for")
    func wholeSourceLengthClampedToSpan() {
        let reserve = AVIOReader.bodyReservation(
            declaredLength: Self.reportedLength, limit: 4 * 1024 * 1024)
        #expect(reserve == 4 * 1024 * 1024)
    }

    @Test("a short body still reserves exactly its own length, not the span")
    func shortBodyKeepsItsLength() {
        let reserve = AVIOReader.bodyReservation(
            declaredLength: 1024 * 1024, limit: 4 * 1024 * 1024)
        #expect(reserve == 1024 * 1024)
    }

    @Test("an unbounded request falls back to the flat ceiling")
    func unboundedRequestUsesCeiling() {
        #expect(AVIOReader.bodyReservation(declaredLength: Self.reportedLength, limit: nil)
                == AVIOReader.maxBodyReserve)
        #expect(AVIOReader.bodyReservation(declaredLength: 4096, limit: nil) == 4096)
    }

    @Test("an unknown or absurd declared length reserves nothing")
    func unknownLengthReservesNothing() {
        #expect(AVIOReader.bodyReservation(declaredLength: -1, limit: 4 * 1024 * 1024) == 0)
        #expect(AVIOReader.bodyReservation(declaredLength: 0, limit: nil) == 0)
    }

    // MARK: - Wiring, against a scripted origin

    /// The crash as reported: the range probes resolve no size, so the HEAD fallback runs, and its
    /// response declares the whole 12.4 GB source while delivering nothing.
    @Test("the HEAD size probe does not reserve the source it declares")
    func headProbeReservesNothingEndToEnd() throws {
        let server = try #require(ScriptedOriginServer { request in
            if request.method == "HEAD" {
                return .init(status: 200, declaredLength: Issue255BodyReserveTests.reportedLength)
            }
            // Length-less GET: no probe can resolve a size from it, which is what drives the
            // reader down to the HEAD fallback.
            return .init(status: 200, declaredLength: nil, bodyBytes: 8 * 1024 * 1024, close: true)
        })
        defer { server.stop() }

        AVIOReader.peakBodyReserveForTesting = 0
        // The budget matters here, because it bounds the wait for the staggered probe ladder:
        // `sizeProbeStaggerSeconds + min(25, chunkRequestTimeout) + 2`. At 5 that is 7.75 s, and a
        // loaded CI runner took longer than that to get the HEAD fallback's closure onto a thread:
        // `open()` broke out of the wait, the reader fell back to streaming mode, and this test read
        // "the HEAD fallback never ran" from a request log that only held the primary probe (one
        // observed failure, green on the next run of the same commit). The wait exits as soon as a
        // size resolves, so a wider ceiling costs nothing in the healthy case and only buys the
        // fallback the room to actually be measured.
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/big.mkv")!,
                                chunkSize: 1024 * 1024, prefetchEnabled: false,
                                chunkRequestTimeout: 15)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        #expect(server.requests.contains { $0.method == "HEAD" },
                "the HEAD fallback never ran, so this exercised nothing: \(server.requests)")
        #expect(reader.isSeekable, "the HEAD probe stopped resolving the size")
        let peak = AVIOReader.peakBodyReserveForTesting
        #expect(peak <= Self.reserveCeiling,
                "a response reserved \(peak / 1024 / 1024) MB up front")
    }

    /// The other way in: the origin ignores `Range` and answers a bounded chunk request with `200`
    /// plus the whole source's length. Pre-fix that reserved 12.4 GB and then buffered the film in
    /// order to hand it to a caller that rejects it.
    @Test("an origin that ignores Range is hung up on at the requested span")
    func rangeIgnoringOriginIsTruncated() throws {
        let bodyBytes = 64 * 1024 * 1024
        let server = try #require(ScriptedOriginServer { _ in
            .init(status: 200, declaredLength: Issue255BodyReserveTests.reportedLength,
                  bodyBytes: bodyBytes)
        })
        defer { server.stop() }

        AVIOReader.peakBodyReserveForTesting = 0
        let chunk = 1024 * 1024
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/big.mkv")!,
                                chunkSize: chunk, prefetchEnabled: false,
                                chunkRequestTimeout: 5, chunkMaxRetries: 1)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let want = 64 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: want)
        defer { buf.deallocate() }
        #expect(reader.read(into: buf, size: Int32(want)) == Int32(want),
                "the truncated chunk did not serve the reader's first read")

        let peak = AVIOReader.peakBodyReserveForTesting
        #expect(peak <= Self.reserveCeiling,
                "a response reserved \(peak / 1024 / 1024) MB up front")
        #expect(server.bodyBytesWritten < bodyBytes / 2,
                "the reader kept reading past its own range: origin wrote \(server.bodyBytesWritten / 1024 / 1024) MB")
    }
}
