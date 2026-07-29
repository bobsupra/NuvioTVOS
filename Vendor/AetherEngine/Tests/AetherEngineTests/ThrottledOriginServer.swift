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
    let port: UInt16
    private let listenFD: Int32
    private let totalSize: Int64
    private let chunkBytes: Int
    private let throttleUs: useconds_t
    private let lock = NSLock()
    private var _bytesWritten: Int64 = 0
    private var _connFDs: [Int32] = []
    private var _stopped = false
    private var _requestedRanges: [(start: Int64, end: Int64?)] = []

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

    private var stopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return _stopped
    }

    init?(totalSize: Int64, chunkBytes: Int = 256 * 1024, throttleUs: useconds_t = 5000) {
        self.totalSize = totalSize
        self.chunkBytes = chunkBytes
        self.throttleUs = throttleUs

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
        var offset: Int64 = 0
        var rangeEnd: Int64? = nil
        if let rangeLine = request.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }),
           let eq = rangeLine.range(of: "bytes="),
           let dash = rangeLine.range(of: "-", range: eq.upperBound..<rangeLine.endIndex) {
            if let start = Int64(rangeLine[eq.upperBound..<dash.lowerBound]) { offset = start }
            let tail = rangeLine[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if !tail.isEmpty, let end = Int64(tail) { rangeEnd = min(end, totalSize - 1) }
        }
        lock.lock()
        _requestedRanges.append((offset, rangeEnd))
        lock.unlock()

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
            let n = Int(min(Int64(chunkBytes), remaining - served))
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
