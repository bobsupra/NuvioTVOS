import Foundation
import Darwin

/// #220: jump-triggered capture of the large-block census.
///
/// rrgomes' census runs settled the question the 30 s memprobe was built for: there is no gradual
/// leak. Every kill on record is dead flat and then steps inside a SINGLE 30 s sample, by +439 MB,
/// +1.2 GB and +3.1 GB respectively, after 2 minutes, 60 seconds and 22 minutes of level behaviour.
/// A 30 s sampler therefore cannot ever name the allocation: by the following tick the process is
/// already dying.
///
/// So the sampler is replaced by a watcher. `malloc_zone_statistics` is cheap (a counter read, no
/// enumeration), so it can be polled several times a second; the expensive zone walk runs only once
/// the counter has actually jumped. That turns a 30 s blind spot into a sub-second one.
///
/// Two design points that matter more than they look:
///
/// - The watcher runs on its OWN queue, never the main actor. During the event the main actor may
///   well be blocked, and the existing memprobe is `@MainActor`, so a main-actor sampler could miss
///   the window even at a high poll rate. This one cannot.
/// - The peak is recorded on every poll, not just on a trigger, because the process may be killed
///   before any line can be emitted. Whatever did get logged then still carries the high-water mark.
extension MallocBlockCensus {

    /// Emitted lines are capped: the escalation itself is informative (a step, then a bigger step),
    /// but a sustained explosion must not turn the log into a slideshow of zone walks while the
    /// device is already under pressure.
    static let maxTriggerCaptures = 12

    nonisolated(unsafe) private static var watchQueue: DispatchQueue?
    nonisolated(unsafe) private static var watchTimer: DispatchSourceTimer?
    /// Running high-water of `size_in_use`. Doubles as the level each capture must clear, which is
    /// what makes the trigger monotone (see `poll`).
    nonisolated(unsafe) private static var highWater = 0
    nonisolated(unsafe) private static var triggerCaptures = 0
    nonisolated(unsafe) private static var thresholdBytes = 64 << 20

    /// Live bytes handed out by malloc, summed across zones. Deliberately the same counter the
    /// memprobe reports as `mallocMB`, so a trigger line and a memprobe line can be compared directly.
    static func sizeInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.size_in_use)
    }

    static func blocksInUse() -> Int {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.blocks_in_use)
    }

    /// Start polling for a jump. `thresholdMB` is how far `size_in_use` must rise ABOVE THE RUNNING
    /// HIGH-WATER to arm a capture, so a session that climbs gently spends one capture per threshold
    /// climbed while ordinary oscillation spends none. It should sit well above that gentle climb and
    /// far below the steps being hunted, which run from hundreds of MB to gigabytes.
    static func startTriggerWatch(thresholdMB: Int, pollHz: Double) {
        stopTriggerWatch()
        guard isEnabled, thresholdMB > 0, pollHz > 0 else { return }
        thresholdBytes = thresholdMB << 20
        highWater = sizeInUse()
        triggerCaptures = 0

        let queue = DispatchQueue(label: "com.aetherengine.malloc.census.trigger", qos: .utility)
        watchQueue = queue
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = 1.0 / pollHz
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(10))
        timer.setEventHandler { poll() }
        watchTimer = timer
        timer.resume()

        EngineLog.emit(
            "[AetherEngine] census trigger armed: threshold=\(thresholdMB)MB/poll "
            + "poll=\(String(format: "%.1f", pollHz))Hz baseline=\(highWater >> 20)MB",
            category: .engine
        )
    }

    static func stopTriggerWatch() {
        watchTimer?.cancel()
        watchTimer = nil
        watchQueue = nil
    }

    /// One poll: read the counter, track the peak, and walk the zones only on a new high-water.
    ///
    /// The rule is `now >= lastCapturedLevel + threshold`, NOT a poll-to-poll delta. Measured at
    /// 8 Hz, the allocator routinely swings ~12 MB between two levels without going anywhere, and a
    /// delta rule re-fires on every upswing, burning the capture budget on churn long before the
    /// real event. Requiring each capture to clear the previous captured level makes the trigger
    /// monotone: oscillation cannot re-arm it, while a genuine runaway still yields one capture per
    /// threshold climbed, which is exactly the escalation trace worth having.
    private static func poll() {
        let now = sizeInUse()
        let previousHighWater = highWater
        defer { if now > highWater { highWater = now } }
        guard now >= previousHighWater + thresholdBytes,
              triggerCaptures < maxTriggerCaptures
        else { return }
        triggerCaptures += 1
        let delta = now - previousHighWater

        // The walk happens AFTER the counter has already moved, so it reports the state the jump
        // produced. At several Hz that is early in the ramp rather than after it has completed.
        let blocks = blocksInUse()
        var line = "[AetherEngine] census trigger #\(triggerCaptures) "
            + "jump=+\(delta >> 20)MB sizeInUse=\(now >> 20)MB peak=\(max(now, highWater) >> 20)MB "
            + "mallocBlocks=\(blocks) "
        if let result = census() {
            let top = result.buckets.prefix(4)
                .map { "\($0.bytes / (1 << 20))MBx\($0.count)" }
                .joined(separator: ",")
            let exact = result.largest.map(String.init).joined(separator: ",")
            line += "bigBlocks=\(result.count) bigMB=\(result.bytes >> 20) "
                + "bigTop=\(top.isEmpty ? "none" : top) "
                + "bigExact=\(exact.isEmpty ? "none" : exact)"
        } else {
            line += "census=unavailable"
        }
        EngineLog.emit(line, category: .engine)
        if triggerCaptures == maxTriggerCaptures {
            EngineLog.emit(
                "[AetherEngine] census trigger cap reached (\(maxTriggerCaptures)); "
                + "further jumps are not captured, peak keeps updating",
                category: .engine
            )
        }
    }

    /// Session high-water, for a summary line after the fact.
    static var peakSizeInUseMB: Int { highWater >> 20 }
}
