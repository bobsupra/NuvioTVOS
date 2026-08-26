import Foundation
import Testing

// AE#377, the deciding measurement. The origin that opened the issue refuses new requests for about
// four minutes out of every ten and recovers on its own. No read-ahead a device can hold reaches
// across that, so the only client shape that survives it is the one ffmpeg uses: one connection,
// held, consumed at playback rate. The engine cannot express that today because a URLSession data
// task has no flow-control contract (#174, #220: 911 MB still arriving after a suspend), and the
// reader therefore ends its connection at winHighWater (16 MB on VOD, #310).
//
// So there are two questions and one of them can kill the plan outright:
//
//   1. Does a HELD connection actually escape the refusal window, or does the origin cut it too?
//      If it gets cut, changing transports buys nothing and nobody should write that code.
//   2. Does URLSessionStreamTask, whose reads are demand-driven, stop the sender when we stop
//      reading, and does holding it across a viewer pause starve the process's networking the way
//      #310 measured for nw flows?
//
// A macOS loopback run answered neither, because the known-bad arm (data task + suspend) behaved
// there too. A harness in which the known failure looks healthy decides nothing. Hence: device,
// real origin, and the positive control in the same run as the question.
//
// Run it (Apple TV, on the same network the failures happen on), from this directory:
//
//   xcodebuild test -scheme TransportProbe-Package \
//     -destination 'platform=tvOS,id=<device-udid>' \
//     -test-timeouts-enabled NO -allowProvisioningUpdates \
//     TEST_RUNNER_AE_PROBE_URL='https://…the source URL…'
//
// The arms are serialized and ordered; the whole set is about 20 minutes. Without AE_PROBE_URL the
// suite is disabled, which is why a bare run never touches the network.

@Suite(.serialized, .enabled(if: ProbeConfig.resolve() != nil))
struct TransportProbe {

    private var config: ProbeConfig {
        get throws {
            guard let config = ProbeConfig.resolve() else {
                throw ProbeError.message("no source URL: set ProbeTarget.sourceURL or AE_PROBE_URL")
            }
            return config
        }
    }

    // MARK: - A. What the origin is

    /// Cheap, and it settles the two things that would make the later arms unreadable: which edge
    /// answers, and whether it speaks http/1.1 at all. The stream arms frame HTTP/1.1 by hand, so an
    /// h2-only edge is a finding rather than a probe bug.
    @Test("A. origin identity, protocol and range support")
    func resolve() async throws {
        let config = try config
        let log = ProbeLog("A-resolve")
        log.note("config:\n\(config.summary)")

        let target = try await waitForServingWindow(config, log: log)
        log.report([
            "status            \(target.status)",
            "edge              \(target.host):\(target.port)",
            "protocol          \(target.protocolName ?? "unknown")",
            "server            \(target.server ?? "unset")",
            "accepts ranges    \(target.acceptsRanges)",
            "total length      \(target.totalLength.map { "\($0) bytes (\(mb(UInt64($0))))" } ?? "unknown")",
            "resolved path     \(target.requestTarget.prefix(120))",
        ])

        if let name = target.protocolName, name.hasPrefix("h2") {
            log.note("NOTE: the edge negotiated \(name) with URLSession. The stream arms request "
                   + "http/1.1 explicitly; if the edge refuses to answer them, that is the answer.")
        }
    }

    // MARK: - B. Does the stream task stop the sender

    /// Read 16 MB, then issue no reads at all for the hold. Three witnesses run at once:
    ///
    ///  - footprint: bytes CFNetwork holds are bytes the origin was allowed to send. Flat means the
    ///    sender was actually stopped; hundreds of MB means it was not, and that is #220's shape.
    ///  - canaries at 1 Hz against the origin and against a neutral host: #310's finding was that a
    ///    held URLSession flow took every other nw flow in the process down with it. A canary that
    ///    goes deaf during the hold and recovers after it is that failure, not a refusal window.
    ///  - the first read after the hold: an instant multi-MB drain means the bytes were already
    ///    bought and paid for; a connection that is simply gone is its own answer to the viewer-pause
    ///    question and the one shape a media reader cannot live with.
    @Test("B. stream task: reads stopped for the hold")
    func streamBackpressure() async throws {
        let config = try config
        let log = ProbeLog("B-stream-hold")
        let target = try await waitForServingWindow(config, log: log)
        log.note("edge \(target.host), protocol via URLSession: \(target.protocolName ?? "unknown")")

        let connection = StreamConnection(host: target.host, port: target.port, secure: target.secure)
        let head = try await connection.sendOpenEndedGET(target: target, fromOffset: 0)
        log.note("response: \(head.rawStatusLine)")
        guard head.status == 200 || head.status == 206 else {
            await connection.close()
            log.report(["stream task got \(head.status) instead of a body; the edge does not serve this shape"])
            throw ProbeError.message("stream GET answered \(head.status)")
        }

        var consumed = head.leftoverBody.count
        let warmupStart = Date()
        while consumed < config.warmupBytes {
            let (chunk, eof) = try await connection.readChunk(maxLength: 256 * 1024, timeout: 30)
            consumed += chunk.count
            if eof || chunk.isEmpty { break }
        }
        let warmupRate = Double(consumed) * 8 / 1_000_000 / max(0.001, Date().timeIntervalSince(warmupStart))
        log.note(String(format: "consumed %@ at %.0f Mbps, now issuing NO reads for %.0fs",
                        mb(consumed), warmupRate, config.holdSeconds))

        let sink = SampleSink()
        let originCanary = startCanary(label: "origin", url: target.url, everySeconds: 1, sink: sink, log: log)
        let neutralCanary = config.neutralCanary.map {
            startCanary(label: "neutral", url: $0, everySeconds: 1, sink: sink, log: log)
        }

        let baseline = physFootprintBytes()
        var peak = baseline
        var abortedAt: Double?
        let deadline = Date().addingTimeInterval(config.holdSeconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            let now = physFootprintBytes()
            peak = max(peak, now)
            if now > baseline + config.footprintAbortBytes {
                abortedAt = log.elapsed
                log.note("ABORT: footprint grew \(mb(now - baseline)) with no reads issued")
                break
            }
        }

        originCanary.cancel()
        neutralCanary?.cancel()

        var firstReadLatency = -1.0
        var drain = 0
        var resumeNote = ""
        do {
            let started = Date()
            let (chunk, eof) = try await connection.readChunk(maxLength: 1024 * 1024, timeout: 30)
            firstReadLatency = Date().timeIntervalSince(started)
            drain = chunk.count
            // 250 ms of unthrottled reading tells buffered bytes (instant) from wire bytes (paced).
            let burstUntil = Date().addingTimeInterval(0.25)
            while Date() < burstUntil, !eof {
                let (more, done) = try await connection.readChunk(maxLength: 1024 * 1024, timeout: 10)
                drain += more.count
                if done || more.isEmpty { break }
            }
            resumeNote = eof ? "stream reported EOF on resume" : "stream continued"
        } catch {
            resumeNote = "first read after the hold FAILED: \(error)"
        }
        await connection.close()

        // 250 ms of wire at the rate this connection just demonstrated. A drain far above it was
        // bought during the hold, i.e. the sender was never stopped. On loopback the budget is
        // gigabytes and the comparison says nothing, which is one more reason this runs on a device.
        let wireBudget = warmupRate * 1_000_000 / 8 * 0.25
        let verdict: String
        if abortedAt != nil || peak > baseline + 64 * 1_048_576 {
            verdict = "NO backpressure: the footprint grew while no read was issued"
        } else if resumeNote.contains("FAILED") || resumeNote.contains("EOF") {
            verdict = "connection did not survive the hold: \(resumeNote)"
        } else if Double(drain) > wireBudget * 4 {
            verdict = "inconclusive: the drain is well past what the wire could deliver in 250 ms"
        } else {
            verdict = "backpressure held: nothing was bought while reads were stopped"
        }

        var lines = [
            "hold                  \(Int(config.holdSeconds)) s, no reads issued",
            "consumed before hold  \(mb(consumed)) at \(String(format: "%.0f", warmupRate)) Mbps",
            "footprint baseline    \(mb(baseline))",
            "footprint peak        \(mb(peak))  (delta \(mb(peak > baseline ? peak - baseline : 0)))",
            "available memory      \(availableAppMemoryBytes().map(mb) ?? "n/a (macOS or simulator)")",
            "aborted early         \(abortedAt.map { String(format: "yes at %.0fs", $0) } ?? "no")",
            "first read after hold \(String(format: "%.3f", firstReadLatency)) s, \(mb(drain)) in 250 ms",
            "250 ms of wire is      \(mb(UInt64(max(0, wireBudget)))) at the rate measured above",
            "resume                \(resumeNote)",
            "VERDICT               \(verdict)",
            "canaries at 1 Hz during the hold:",
        ]
        lines += await sink.condensed(label: "origin")
        lines += await sink.condensed(label: "neutral")
        log.report(lines)
    }

    // MARK: - C. The positive control

    /// The same hold with the transport the engine uses today. #220 says this arm must misbehave:
    /// bytes keep being delivered after `suspend()`, and the footprint follows them. If this arm
    /// looks healthy on the device, the run has not encoded the case and arm B proves nothing, which
    /// is exactly what happened on the macOS loopback harness.
    @Test("C. data task + suspend, positive control")
    func dataTaskSuspendControl() async throws {
        let config = try config
        let log = ProbeLog("C-datatask-control")
        let target = try await waitForServingWindow(config, log: log)

        let collector = SuspendingCollector(warmupBytes: config.warmupBytes, log: log)
        let session = URLSession(configuration: .ephemeral, delegate: collector, delegateQueue: nil)
        var request = URLRequest(url: target.url)
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
        request.setValue(probeUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        let task = session.dataTask(with: request)
        task.resume()

        guard await collector.waitForSuspend(timeout: 120) else {
            session.invalidateAndCancel()
            throw ProbeError.message("never reached \(mb(config.warmupBytes)) to suspend at")
        }
        let atSuspend = collector.received
        log.note("suspended after \(mb(atSuspend)); holding \(Int(config.holdSeconds))s")

        let sink = SampleSink()
        let originCanary = startCanary(label: "origin", url: target.url, everySeconds: 1, sink: sink, log: log)
        let neutralCanary = config.neutralCanary.map {
            startCanary(label: "neutral", url: $0, everySeconds: 1, sink: sink, log: log)
        }

        let baseline = physFootprintBytes()
        var peak = baseline
        var abortedAt: Double?
        let deadline = Date().addingTimeInterval(config.holdSeconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            let now = physFootprintBytes()
            peak = max(peak, now)
            if now > baseline + config.footprintAbortBytes {
                abortedAt = log.elapsed
                log.note("ABORT: footprint grew \(mb(now - baseline)) while the task was suspended")
                break
            }
        }
        let deliveredDuringHold = collector.received - atSuspend

        originCanary.cancel()
        neutralCanary?.cancel()
        task.cancel()
        session.invalidateAndCancel()

        // The arm exists to fail. If it behaves, arm B's healthy result describes this host and not
        // the transport, which is exactly how the macOS loopback attempt ended.
        let reproduces = deliveredDuringHold > 32 * 1_048_576 || peak > baseline + 32 * 1_048_576
        let controlVerdict = reproduces
            ? "reproduces #220, so arm B counts on this host"
            : "does NOT reproduce #220 here: the known-bad transport behaved, so arm B decides nothing"

        var lines = [
            "hold                  \(Int(config.holdSeconds)) s, task suspended",
            "delivered at suspend  \(mb(atSuspend))",
            "delivered DURING hold \(mb(deliveredDuringHold))   <- must be large for the arm to count",
            "footprint baseline    \(mb(baseline))",
            "footprint peak        \(mb(peak))  (delta \(mb(peak > baseline ? peak - baseline : 0)))",
            "available memory      \(availableAppMemoryBytes().map(mb) ?? "n/a (macOS or simulator)")",
            "aborted early         \(abortedAt.map { String(format: "yes at %.0fs", $0) } ?? "no")",
            "VERDICT               \(controlVerdict)",
            "canaries at 1 Hz during the hold:",
        ]
        lines += await sink.condensed(label: "origin")
        lines += await sink.condensed(label: "neutral")
        log.report(lines)
    }

    // MARK: - D. Does a held connection cross the refusal window

    /// The arm the issue turns on, and the cheapest one to read: one open-ended request, consumed at
    /// playback rate, running past the origin's serve window while a 1 KB canary knocks on the same
    /// edge every 30 s. The canary flipping to 429 is proof the window closed; the stream delivering
    /// through it without a gap is proof a held connection is exempt. If the stream gaps at the same
    /// moment, the transport change is dead and nobody has to write it.
    @Test("D. one held request across the origin's refusal window")
    func heldAcrossWindow() async throws {
        let config = try config
        let log = ProbeLog("D-window")
        let target = try await waitForServingWindow(config, log: log)

        let connection = StreamConnection(host: target.host, port: target.port, secure: target.secure)
        let head = try await connection.sendOpenEndedGET(target: target, fromOffset: 0)
        log.note("response: \(head.rawStatusLine)")
        guard head.status == 200 || head.status == 206 else {
            await connection.close()
            throw ProbeError.message("stream GET answered \(head.status)")
        }

        let sink = SampleSink()
        let originCanary = startCanary(label: "origin", url: target.url, everySeconds: 20, sink: sink, log: log)
        let neutralCanary = config.neutralCanary.map {
            startCanary(label: "neutral", url: $0, everySeconds: 60, sink: sink, log: log)
        }

        var delivered = head.leftoverBody.count
        var longestStall = 0.0
        var longestStallAt = 0.0
        var stalls: [String] = []
        var nextMinute = 60.0
        var lastMinuteBytes = 0
        var ended: String?
        let started = Date()

        while true {
            let runElapsed = Date().timeIntervalSince(started)
            if runElapsed >= config.windowSeconds { break }
            // Consume at playback rate. A probe that reads as fast as it can is not the case under
            // test: the reader that meets this origin is one that stays behind the CDN.
            let owed = Double(delivered) / config.readRateBytesPerSecond - runElapsed
            if owed > 0 { try await Task.sleep(for: .seconds(min(owed, 1.0))) }

            let readStart = Date()
            do {
                let (chunk, eof) = try await connection.readChunk(maxLength: 256 * 1024, timeout: 120)
                let waited = Date().timeIntervalSince(readStart)
                if waited > longestStall {
                    longestStall = waited
                    longestStallAt = runElapsed
                }
                if waited > 2 {
                    stalls.append(String(format: "  stall %.1fs at %.0fs (%@ delivered)", waited, runElapsed, mb(delivered)))
                    log.note(String(format: "read waited %.1fs", waited))
                }
                delivered += chunk.count
                if eof || chunk.isEmpty {
                    ended = "stream ended (eof) at \(mb(delivered))"
                    break
                }
            } catch {
                ended = String(format: "read FAILED at %.0fs after %@: %@", runElapsed, mb(delivered), "\(error)")
                log.note(ended!)
                break
            }

            if runElapsed >= nextMinute {
                let rate = Double(delivered - lastMinuteBytes) * 8 / 1_000_000 / 60
                log.note(String(format: "minute %.0f: %@ total, %.1f Mbps this minute", nextMinute / 60, mb(delivered), rate))
                lastMinuteBytes = delivered
                nextMinute += 60
            }
        }

        originCanary.cancel()
        neutralCanary?.cancel()
        await connection.close()

        // Without a refused canary the arm never met the thing it was built to cross, and its clean
        // stream is a clean stream during business hours.
        let refused = await sink.outcomes(label: "origin").contains { outcome in
            guard let code = Int(outcome.prefix(3)) else { return true }
            return code >= 400
        }
        let windowVerdict = refused
            ? (longestStall < 2 && ended == nil
                ? "a held connection crossed a closed window without a stall"
                : "the window closed and the held stream was affected too, see the stalls above")
            : "NO closed window in this run: rerun with a longer AE_PROBE_WINDOW_SECONDS"

        var lines = [
            "ran                   \(Int(Date().timeIntervalSince(started))) s at \(String(format: "%.0f", config.readRateBytesPerSecond * 8 / 1_000_000)) Mbps requested",
            "delivered             \(mb(delivered)) on ONE request, one connection",
            "outcome               \(ended ?? "still delivering when the arm ended")",
            String(format: "longest read stall    %.1f s at %.0fs", longestStall, longestStallAt),
        ]
        lines += stalls.isEmpty ? ["  no read waited longer than 2 s"] : stalls
        lines.append("VERDICT               \(windowVerdict)")
        lines.append("canary on the same edge (20 s cadence):")
        lines += await sink.condensed(label: "origin")
        lines += await sink.condensed(label: "neutral")
        log.report(lines)
    }
}

// MARK: - Control-arm delegate

/// Counts what keeps arriving after `suspend()`. The count is the whole point of the arm, so it is
/// taken in the delegate rather than inferred from a footprint that could move for other reasons.
private final class SuspendingCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _received = 0
    private var suspended = false
    private let warmupBytes: Int
    private let log: ProbeLog
    private let reachedSuspend = DispatchSemaphore(value: 0)

    init(warmupBytes: Int, log: ProbeLog) {
        self.warmupBytes = warmupBytes
        self.log = log
    }

    var received: Int {
        lock.lock()
        defer { lock.unlock() }
        return _received
    }

    func waitForSuspend(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [reachedSuspend] in
                continuation.resume(returning: reachedSuspend.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        _received += data.count
        let shouldSuspend = !suspended && _received >= warmupBytes
        if shouldSuspend { suspended = true }
        lock.unlock()

        if shouldSuspend {
            dataTask.suspend()
            reachedSuspend.signal()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            log.note("control task ended: \(error.localizedDescription)")
        }
        reachedSuspend.signal()
    }
}
