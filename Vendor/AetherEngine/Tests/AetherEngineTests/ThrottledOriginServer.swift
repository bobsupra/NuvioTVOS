import Foundation

/// Shared test origin for the reader's network paths (#174, #220).
///
/// Minimal blocking HTTP server on 127.0.0.1 that serves Range requests, honours a finite
/// range end, keeps the connection alive across requests, and counts every body byte it
/// manages to write. When the client stops reading, `write()` parks on the full socket
/// buffer, so `bytesWritten` plateauing IS the observable for working flow control.
/// Minimal blocking HTTP origin on 127.0.0.1: serves `Range: bytes=X-` with a 206 and
/// an endless zero body, throttled to ~50 MB/s, counting bytes actually written. When
/// the client stops reading, write() parks on the full socket buffer, so `bytesWritten`
/// plateauing IS the observable for working flow control.
final class ThrottledOriginServer: @unchecked Sendable {
    /// Per-request response override for failure-path tests. The default keeps every
    /// existing test on the historical always-206 behaviour.
    enum Directive {
        case serve206
        case status(Int, retryAfter: Int? = nil)
        case redirect(to: String)
        case dropConnection
        /// #309: answer with the 206 header, deliver `afterBytes` of the promised body, then stop
        /// writing WITHOUT closing the socket and without a FIN. The client keeps an established
        /// connection that delivers nothing and never errors, which is the reader-observable state
        /// behind #309 (the field case was a transport that died with URLSession surfacing nothing).
        /// `afterBytes: 0` is the headers-but-no-body variant, i.e. a generation that never sees a
        /// first byte.
        case serveThenGoSilent(afterBytes: Int64)
        /// Sequential-origin drop shape: answer the 206 header promising the full remaining body,
        /// deliver `afterBytes`, then close the socket outright. The client sees a connection that
        /// ended SHORT of its Content-Length - the observable behind the sequential reader's
        /// EIO-not-EOF distinction (a lost source must not read as end-of-media).
        case serveThenDrop(afterBytes: Int64)
    }

    let port: UInt16
    private let listenFD: Int32
    private let totalSize: Int64
    private let chunkBytes: Int
    private let throttleUs: useconds_t
    private let firstByteDelayUs: @Sendable (_ isSuffix: Bool) -> useconds_t
    private let respond: @Sendable (_ requestIndex: Int, _ offset: Int64, _ path: String) -> Directive
    private let lock = NSLock()
    private var _bytesWritten: Int64 = 0
    private var _connFDs: [Int32] = []
    private var _stopped = false
    private var _requestedRanges: [(start: Int64, end: Int64?)] = []
    private var _requestLog: [(path: String, start: Int64, end: Int64?)] = []
    private var _rangeHeaderPresent: [Bool] = []

    var bytesWritten: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _bytesWritten
    }

    /// #220: what each request actually asked for. `end` is nil for an open-ended
    /// `bytes=X-`, which is what live sources and unresolved sizes keep using.
    var requestedRanges: [(start: Int64, end: Int64?)] {
        lock.lock(); defer { lock.unlock() }
        return _requestedRanges
    }

    var rangeRequestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _requestedRanges.count
    }

    /// Every request with its path, so a redirect test can tell source-URL hits from
    /// pinned-URL hits.
    var requestLog: [(path: String, start: Int64, end: Int64?)] {
        lock.lock(); defer { lock.unlock() }
        return _requestLog
    }

    /// Whether each logged request carried a Range header at all. A range-less GET is logged in
    /// `requestLog` as (start 0, end nil), indistinguishable from `bytes=0-`; the sequential-origin
    /// reader's whole contract is that it never sends Range, so its tests assert on THIS.
    var rangeHeaderPresence: [Bool] {
        lock.lock(); defer { lock.unlock() }
        return _rangeHeaderPresent
    }

    private var stopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopped
    }

    /// #281 retest: how long this origin sits on a request before its response header, per request
    /// form. A loopback origin answers instantly, which is the one thing a real one never does, and
    /// that difference is what let the speculative tail fetch pass every test while never once
    /// winning its race in the field. `isSuffix` is true for the `bytes=-n` form.
    init?(totalSize: Int64, chunkBytes: Int = 256 * 1024, throttleUs: useconds_t = 5000,
          firstByteDelayUs: @escaping @Sendable (_ isSuffix: Bool) -> useconds_t = { _ in 0 },
          respond: @escaping @Sendable (_ requestIndex: Int, _ offset: Int64, _ path: String) -> Directive = { _, _, _ in .serve206 }) {
        self.totalSize = totalSize
        self.chunkBytes = chunkBytes
        self.throttleUs = throttleUs
        self.firstByteDelayUs = firstByteDelayUs
        self.respond = respond

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(fd, 4) == 0 else {
            close(fd)
            return nil
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            return nil
        }
        self.listenFD = fd
        self.port = UInt16(bigEndian: bound.sin_port)

        Thread.detachNewThread { [self] in acceptLoop() }
    }

    func stop() {
        lock.lock()
        let fds = _connFDs
        _connFDs = []
        let alreadyStopped = _stopped
        _stopped = true
        lock.unlock()
        guard !alreadyStopped else { return }
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
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    /// One connection, many requests: a bounded-range reader issues the next range on the
    /// same socket, so serving exactly one and hanging up would force a new connection per
    /// range and make the pooling measurement meaningless.
    private func serve(_ fd: Int32) {
        while !stopped {
            if !serveOneRequest(fd) { return }
        }
    }

    /// Returns false when the connection should close (client gone, or a malformed request).
    private func serveOneRequest(_ fd: Int32) -> Bool {
        guard let request = readRequestHeader(fd) else { return false }
        let path = request.components(separatedBy: "\r\n").first
            .flatMap { line -> String? in
                let parts = line.components(separatedBy: " ")
                return parts.count >= 2 ? parts[1] : nil
            } ?? "?"
        var offset: Int64 = 0
        var rangeEnd: Int64? = nil
        var isSuffix = false
        var hadRangeHeader = false
        if let rangeLine = request.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }),
           let eq = rangeLine.range(of: "bytes="),
           let dash = rangeLine.range(of: "-", range: eq.upperBound..<rangeLine.endIndex) {
            hadRangeHeader = true
            let head = rangeLine[eq.upperBound..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = rangeLine[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if head.isEmpty, let suffixLength = Int64(tail) {
                // #281: the suffix form `bytes=-n`, the last n bytes, which is what the speculative
                // tail fetch uses because it needs no size. Logged in its resolved form so a test
                // asserts against real offsets.
                offset = max(0, totalSize - suffixLength)
                rangeEnd = totalSize - 1
                isSuffix = true
            } else {
                if let start = Int64(head) { offset = start }
                if !tail.isEmpty, let end = Int64(tail) { rangeEnd = min(end, totalSize - 1) }
            }
        }
        lock.lock()
        _requestedRanges.append((offset, rangeEnd))
        _requestLog.append((path, offset, rangeEnd))
        _rangeHeaderPresent.append(hadRangeHeader)
        let requestIndex = _requestLog.count - 1
        lock.unlock()

        var silentAfter: Int64? = nil
        var dropAfter: Int64? = nil
        switch respond(requestIndex, offset, path) {
        case .serve206:
            break
        case .serveThenGoSilent(let afterBytes):
            silentAfter = max(0, afterBytes)
        case .serveThenDrop(let afterBytes):
            dropAfter = max(0, afterBytes)
        case .status(let code, let retryAfter):
            let header = "HTTP/1.1 \(code) Status\r\n"
                + (retryAfter.map { "Retry-After: \($0)\r\n" } ?? "")
                + "Content-Length: 0\r\n"
                + "Connection: keep-alive\r\n\r\n"
            return writeFully(fd, Array(header.utf8))
        case .redirect(let location):
            let header = "HTTP/1.1 302 Found\r\n"
                + "Location: \(location)\r\n"
                + "Content-Length: 0\r\n"
                + "Connection: keep-alive\r\n\r\n"
            return writeFully(fd, Array(header.utf8))
        case .dropConnection:
            // `serve` leaves closing to `stop()`, which closes every fd still in `_connFDs`.
            // Closing here without deregistering first frees a descriptor number the process
            // can hand straight to the next socket, and `stop()` would then shut down whatever
            // took it over. Deregister under the lock, then close exactly once.
            lock.lock()
            _connFDs.removeAll { $0 == fd }
            lock.unlock()
            shutdown(fd, SHUT_RDWR)
            close(fd)
            return false
        }

        var pendingDelay = firstByteDelayUs(isSuffix)
        while pendingDelay > 0 && !stopped {
            let slice = min(pendingDelay, 100_000)   // usleep is only defined below one second
            usleep(slice)
            pendingDelay -= slice
        }

        let last = rangeEnd ?? (totalSize - 1)
        let remaining = last - offset + 1
        // Keep-alive, not close: a bounded range that tears the socket down would make every
        // refill a fresh connection and would hide exactly the pooling question under test.
        let header = "HTTP/1.1 206 Partial Content\r\n"
            + "Content-Range: bytes \(offset)-\(last)/\(totalSize)\r\n"
            + "Content-Length: \(remaining)\r\n"
            + "Accept-Ranges: bytes\r\n"
            + "Connection: keep-alive\r\n\r\n"
        guard writeFully(fd, Array(header.utf8)) else { return false }

        let chunk = [UInt8](repeating: 0x55, count: chunkBytes)
        var served: Int64 = 0
        while served < remaining && !stopped {
            // #309: the silent-death point. Neither close() nor shutdown(): the peer must keep an
            // established connection with an unfinished body, so the reader sees no bytes, no EOF
            // and no error. `stop()` is what releases this thread and the socket.
            if let silentAfter, served >= silentAfter {
                while !stopped { usleep(200_000) }
                return false
            }
            // Sequential-drop point: the body ends short of the promised Content-Length, which is
            // what the client's transport has to surface as a lost connection.
            //
            // Half-close, not close(). A full close tears down the receive direction too, and
            // anything still in flight can then be answered with an RST, which discards whatever
            // the peer has not handed to its application yet. The bytes this origin says it served
            // would silently stop being the bytes the reader can see, and a test asserting on the
            // amount delivered would be measuring the machine's scheduling (the 2026-08-11 CI
            // failure: 327212 of 2 MiB arrived). FIN keeps the sent bytes deliverable; `stop()`
            // closes the descriptor, which is why it stays registered in `_connFDs`.
            if let dropAfter, served >= dropAfter {
                shutdown(fd, SHUT_WR)
                return false
            }
            var n = Int(min(Int64(chunkBytes), remaining - served))
            if let silentAfter { n = Int(min(Int64(n), silentAfter - served)) }
            if let dropAfter { n = Int(min(Int64(n), dropAfter - served)) }
            guard writeBody(fd, Array(chunk[0..<n])) else { return false }
            served += Int64(n)
            if throttleUs > 0 { usleep(throttleUs) }
        }
        return true
    }

    private func readRequestHeader(_ fd: Int32) -> String? {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var collected = Data()
        let terminator = Data("\r\n\r\n".utf8)
        while collected.range(of: terminator) == nil {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { return nil }
            collected.append(contentsOf: buf[0..<n])
            if collected.count > 128 * 1024 { return nil }
        }
        return String(data: collected, encoding: .utf8)
    }

    private func writeFully(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress, raw.count)
            }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }

    /// Like writeFully but counts every byte the kernel actually accepted, including a
    /// final partial write, so a park mid-chunk is still measured accurately.
    private func writeBody(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress, raw.count)
            }
            guard n > 0 else { return false }
            lock.lock()
            _bytesWritten += Int64(n)
            lock.unlock()
            sent += n
        }
        return true
    }
}
