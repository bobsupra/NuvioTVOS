import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if os(tvOS) || os(iOS) || os(visionOS)
import os
#endif

// AE#377 / #310 / #220: the mechanics behind the four arms in TransportProbe.swift.
//
// Nothing here imports AetherEngine. The question is a property of the transport, so the probe
// talks to the origin the way a client would and never through the reader that is under suspicion.

// MARK: - Configuration

/// Everything the probe reads from the environment. Absent `AE_PROBE_URL` disables the whole suite,
/// which is what keeps `swift test` and CI from reaching the network.
struct ProbeConfig: Sendable {
    var source: URL
    /// How long an arm issues no reads at all. 60 s is past any viewer-pause the engine tolerates
    /// and short enough that an unbounded sender hits the abort guard rather than jetsam.
    var holdSeconds: Double
    /// How long the held-connection arm runs. Must exceed the origin's serve window (about six
    /// minutes on the source that opened #377) or it proves nothing.
    var windowSeconds: Double
    /// Consumption rate for the held-connection arm, in bytes per second. A probe that reads as
    /// fast as it can is not a player; the interesting state is a reader that stays behind the CDN.
    var readRateBytesPerSecond: Double
    /// Bytes to consume before an arm stops reading.
    var warmupBytes: Int
    /// A host that is not the origin, so a refusal can be told apart from the process's networking
    /// going deaf (#310). Empty string disables it.
    var neutralCanary: URL?
    /// Footprint growth that ends an arm early. Unbounded delivery is the finding; being killed by
    /// jetsam while proving it is not.
    var footprintAbortBytes: UInt64

    /// Environment first, so a macOS run stays a one-liner; then `ProbeTarget`, which is the only
    /// channel that reaches a test process on a device. Nil disables the suite.
    static func resolve() -> ProbeConfig? {
        let env = ProcessInfo.processInfo.environment
        let raw = (env["AE_PROBE_URL"] ?? ProbeTarget.sourceURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw), url.host != nil else { return nil }

        func number(_ key: String, edited: Double, fallback: Double) -> Double {
            if let text = env[key], let value = Double(text) { return value }
            return edited > 0 ? edited : fallback
        }

        var canaryRaw = env["AE_PROBE_CANARY_URL"] ?? ProbeTarget.neutralCanaryURL
        if canaryRaw.isEmpty { canaryRaw = "https://captive.apple.com/hotspot-detect.html" }
        if canaryRaw == "none" { canaryRaw = "" }

        return ProbeConfig(
            source: url,
            holdSeconds: number("AE_PROBE_HOLD_SECONDS", edited: ProbeTarget.holdSeconds, fallback: 60),
            windowSeconds: number("AE_PROBE_WINDOW_SECONDS", edited: ProbeTarget.windowSeconds, fallback: 900),
            readRateBytesPerSecond: number("AE_PROBE_MBPS", edited: ProbeTarget.megabitsPerSecond, fallback: 65)
                * 1_000_000 / 8,
            warmupBytes: Int(number("AE_PROBE_WARMUP_MB", edited: ProbeTarget.warmupMegabytes, fallback: 16))
                * 1024 * 1024,
            neutralCanary: canaryRaw.isEmpty ? nil : URL(string: canaryRaw),
            footprintAbortBytes: UInt64(number("AE_PROBE_ABORT_MB", edited: ProbeTarget.abortMegabytes, fallback: 400))
                * 1024 * 1024
        )
    }

    var summary: String {
        """
        source            \(source.absoluteString)
        hold              \(Int(holdSeconds)) s
        window arm        \(Int(windowSeconds)) s at \(String(format: "%.1f", readRateBytesPerSecond * 8 / 1_000_000)) Mbps
        warmup            \(warmupBytes / 1_048_576) MB
        neutral canary    \(neutralCanary?.host ?? "disabled")
        abort at          +\(footprintAbortBytes / 1_048_576) MB footprint
        """
    }
}

// MARK: - Output

/// Prints with an arm-relative clock. The report is the deliverable, so every line carries the time
/// it happened at rather than the time someone reads it.
final class ProbeLog: @unchecked Sendable {
    private let started = Date()
    private let name: String
    private let lock = NSLock()

    init(_ name: String) {
        self.name = name
        note("---- \(name) ----")
    }

    var elapsed: Double { Date().timeIntervalSince(started) }

    func note(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        print(String(format: "[%@ %7.1fs] %@", name, Date().timeIntervalSince(started), message))
        fflush(stdout)
    }

    /// A block meant to be pasted into the issue verbatim.
    func report(_ lines: [String]) {
        lock.lock()
        defer { lock.unlock() }
        print("")
        print("===== \(name): paste this =====")
        for line in lines { print(line) }
        print("===== end \(name) =====")
        print("")
        fflush(stdout)
    }
}

// MARK: - Memory witnesses

/// Bytes CFNetwork holds for us are bytes the origin was allowed to send. On a remote origin the
/// server's own books are out of reach, so the process footprint is the witness that a sender kept
/// sending: #220 measured 911 MB arriving after a suspend, which no bounded buffer can hide.
func physFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

/// Headroom before jetsam. Device only: it does not exist on macOS and returns 0 on a simulator,
/// and a reported "0.0 MB" of headroom would read as a device about to be killed.
func availableAppMemoryBytes() -> UInt64? {
#if os(tvOS) || os(iOS) || os(visionOS)
    let value = os_proc_available_memory()
    return value > 0 ? UInt64(value) : nil
#else
    return nil
#endif
}

func mb(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
func mb(_ bytes: Int) -> String { mb(UInt64(max(0, bytes))) }

// MARK: - Resolution

struct ResolvedTarget: Sendable {
    var url: URL
    var host: String
    var port: Int
    var requestTarget: String
    var secure: Bool
    var status: Int
    var protocolName: String?
    var totalLength: Int64?
    var acceptsRanges: Bool
    var server: String?

    var originKey: String { "\(secure ? "https" : "http")://\(host):\(port)" }
}

/// Collects `networkProtocolName`, which is the only place that says whether the edge speaks h2 or
/// http/1.1. The stream-task arms frame HTTP/1.1 by hand, so an h2-only edge would be a finding in
/// itself rather than a probe bug.
private final class MetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var name: String?

    var protocolName: String? {
        lock.lock()
        defer { lock.unlock() }
        return name
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        defer { lock.unlock() }
        name = metrics.transactionMetrics.last?.networkProtocolName
    }
}

/// Follows redirects once, exactly like the reader does before it pins, and reports the edge that
/// actually answers. Every arm resolves for itself: a pin held across a fifteen minute arm would be
/// measuring the pin, and #380 already showed what a stale one does.
func resolveTarget(_ config: ProbeConfig) async throws -> ResolvedTarget {
    let collector = MetricsCollector()
    let session = URLSession(configuration: .ephemeral, delegate: collector, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    var request = URLRequest(url: config.source)
    request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
    request.setValue(probeUserAgent, forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 30

    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, let final = http.url, let host = final.host else {
        throw ProbeError.message("resolve produced no HTTP response")
    }

    var total: Int64?
    if let range = http.value(forHTTPHeaderField: "Content-Range"),
       let slash = range.lastIndex(of: "/") {
        total = Int64(range[range.index(after: slash)...])
    } else if http.expectedContentLength > 0 {
        total = http.expectedContentLength
    }

    let secure = (final.scheme?.lowercased() == "https")
    var target = final.path.isEmpty ? "/" : final.path
    if let query = final.query, !query.isEmpty { target += "?" + query }

    return ResolvedTarget(
        url: final,
        host: host,
        port: final.port ?? (secure ? 443 : 80),
        requestTarget: target,
        secure: secure,
        status: http.statusCode,
        protocolName: collector.protocolName,
        totalLength: total,
        acceptsRanges: http.value(forHTTPHeaderField: "Accept-Ranges")?.contains("bytes") ?? (http.statusCode == 206),
        server: http.value(forHTTPHeaderField: "Server")
    )
}

let probeUserAgent = "AetherEngine-TransportProbe/1 (AE#377)"

enum ProbeError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

// MARK: - Canary

struct CanarySample: Sendable {
    var at: Double
    var label: String
    var outcome: String
    var latency: Double
}

actor SampleSink {
    private(set) var samples: [CanarySample] = []
    func add(_ sample: CanarySample) { samples.append(sample) }

    /// One line per distinct outcome run, so a fifteen minute arm reports as a handful of lines
    /// rather than thirty.
    func outcomes(label: String) -> [String] {
        samples.filter { $0.label == label }.map(\.outcome)
    }

    func condensed(label: String) -> [String] {
        let mine = samples.filter { $0.label == label }
        guard !mine.isEmpty else { return ["\(label): no samples"] }
        var lines: [String] = []
        var runStart = mine[0].at
        var runOutcome = mine[0].outcome
        var count = 0
        for sample in mine {
            if sample.outcome == runOutcome {
                count += 1
            } else {
                lines.append(String(format: "  %@ %6.0fs..%6.0fs  %@ (x%d)", label, runStart, sample.at, runOutcome, count))
                runStart = sample.at
                runOutcome = sample.outcome
                count = 1
            }
        }
        lines.append(String(format: "  %@ %6.0fs..%6.0fs  %@ (x%d)", label, runStart, mine[mine.count - 1].at, runOutcome, count))
        return lines
    }
}

/// One fresh request per tick on a fresh session. A reused connection would answer a question
/// nobody asked: the window refuses NEW requests, and #310's starvation kills NEW flows.
func startCanary(
    label: String,
    url: URL,
    everySeconds: Double,
    sink: SampleSink,
    log: ProbeLog,
    announceChanges: Bool = true
) -> Task<Void, Never> {
    Task {
        var lastOutcome = ""
        while !Task.isCancelled {
            let started = Date()
            var outcome: String
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let session = URLSession(configuration: configuration)
            var request = URLRequest(url: url)
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            request.setValue(probeUserAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (_, response) = try await session.data(for: request)
                outcome = "\((response as? HTTPURLResponse)?.statusCode ?? -1)"
            } catch {
                outcome = "error \((error as NSError).code)"
            }
            session.invalidateAndCancel()
            // A canary torn down with its arm is not a sample. Recording it would put an -999 into
            // the next arm's log and read as a failure that belongs to nobody.
            if Task.isCancelled || outcome == "error \(NSURLErrorCancelled)" { break }
            let latency = Date().timeIntervalSince(started)
            if latency > 5 { outcome += String(format: " slow %.0fs", latency) }
            await sink.add(CanarySample(at: log.elapsed, label: label, outcome: outcome, latency: latency))
            if announceChanges, outcome != lastOutcome {
                log.note("canary \(label): \(outcome) after \(String(format: "%.2f", latency))s")
                lastOutcome = outcome
            }
            let remaining = everySeconds - latency
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }
}

/// An arm that opens during a refusal window measures the window, not the transport. Waits for the
/// origin to serve again rather than failing, because the source under test spends four minutes in
/// ten refusing and a run should not need a human to time it.
func waitForServingWindow(_ config: ProbeConfig, log: ProbeLog, upTo limit: Double = 600) async throws -> ResolvedTarget {
    let deadline = Date().addingTimeInterval(limit)
    var attempt = 0
    while true {
        attempt += 1
        do {
            let target = try await resolveTarget(config)
            if (200...299).contains(target.status) {
                if attempt > 1 { log.note("origin serving again after \(attempt) probes") }
                return target
            }
            log.note("origin answers \(target.status), waiting for its window (probe \(attempt))")
        } catch {
            log.note("probe \(attempt) failed: \(error)")
        }
        guard Date() < deadline else {
            throw ProbeError.message("origin did not serve within \(Int(limit))s")
        }
        try await Task.sleep(for: .seconds(20))
    }
}

// MARK: - HTTP/1.1 over URLSessionStreamTask

struct StreamResponseHead: Sendable {
    var status: Int
    var headers: [String: String]
    var leftoverBody: Data
    var rawStatusLine: String
}

/// The transport under test. `URLSessionStreamTask` is available and not deprecated on the tvOS 26
/// SDK (tvos(9.0), no deprecation), its reads are demand-driven, and `startSecureConnection()` is
/// OS TLS with the normal challenge path. Request and response framing is ours, which is the
/// bounded work this whole question turns on.
actor StreamConnection {
    private let session: URLSession
    private let task: URLSessionStreamTask
    private var buffered = Data()
    private(set) var bytesFromWire = 0

    init(host: String, port: Int, secure: Bool) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        session = URLSession(configuration: configuration)
        task = session.streamTask(withHostName: host, port: port)
        task.resume()
        if secure { task.startSecureConnection() }
    }

    func close() {
        task.closeRead()
        task.closeWrite()
        session.invalidateAndCancel()
    }

    private func write(_ data: Data, timeout: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.write(data, timeout: timeout) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Returns (bytes, atEOF). A timeout surfaces as a thrown error so an arm can call it a gap
    /// rather than reading it as end of stream.
    func readChunk(maxLength: Int, timeout: TimeInterval) async throws -> (Data, Bool) {
        if !buffered.isEmpty {
            let slice = buffered.prefix(maxLength)
            buffered.removeFirst(slice.count)
            return (Data(slice), false)
        }
        let (data, eof): (Data, Bool) = try await withCheckedThrowingContinuation { continuation in
            task.readData(ofMinLength: 1, maxLength: maxLength, timeout: timeout) { data, eof, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data ?? Data(), eof))
                }
            }
        }
        bytesFromWire += data.count
        return (data, eof)
    }

    func sendOpenEndedGET(target: ResolvedTarget, fromOffset: Int64) async throws -> StreamResponseHead {
        var request = "GET \(target.requestTarget) HTTP/1.1\r\n"
        request += "Host: \(target.host)\r\n"
        request += "Range: bytes=\(fromOffset)-\r\n"
        request += "User-Agent: \(probeUserAgent)\r\n"
        request += "Accept: */*\r\n"
        request += "Connection: keep-alive\r\n\r\n"
        try await write(Data(request.utf8), timeout: 20)

        var head = Data()
        let separator = Data("\r\n\r\n".utf8)
        while head.range(of: separator) == nil {
            let (chunk, eof) = try await readChunk(maxLength: 64 * 1024, timeout: 30)
            if chunk.isEmpty || eof {
                throw ProbeError.message("connection closed before a response header arrived")
            }
            head.append(chunk)
            if head.count > 128 * 1024 {
                throw ProbeError.message("no header terminator in the first 128 KB")
            }
        }

        guard let split = head.range(of: separator) else {
            throw ProbeError.message("header terminator vanished")
        }
        let body = Data(head[split.upperBound...])
        buffered = body + buffered
        let text = String(decoding: head[..<split.lowerBound], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.isEmpty ? "" : lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        let status = parts.count > 1 ? Int(parts[1]) ?? -1 : -1

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[String(key)] = value
        }

        return StreamResponseHead(status: status, headers: headers, leftoverBody: body, rawStatusLine: statusLine)
    }
}
