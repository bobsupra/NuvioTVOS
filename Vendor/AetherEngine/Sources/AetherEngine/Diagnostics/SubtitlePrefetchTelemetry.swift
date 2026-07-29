import Foundation
import os

/// #220: live gauge for the #151 subtitle forward prefetcher.
///
/// The prefetcher is a second reader against the same origin, and server-side per-connection
/// byte totals showed it consuming 2.6x media rate at playhead + 333 s against a 60 s lead
/// allowance while the pump stayed exactly paced. That is visible on the wire minutes before
/// the process dies, so it has to be visible in our own log too: `lead` separates "reads fast
/// while building its lead" (normal) from "the lead never settles" (the defect).
///
/// Written from the prefetch task (off the main actor, one lock acquisition per routed subtitle
/// packet, never per demuxed packet) and read by the 30 s memprobe on the main actor. The
/// generation guard keeps a cancelled session's exit from clearing the successor it was
/// replaced by: `startSubtitleForwardPrefetcher` cancels and restarts in the same call, and
/// the outgoing loop can still be unwinding when the new one begins.
enum SubtitlePrefetchTelemetry {

    struct Snapshot: Sendable {
        var generation = 0
        var running = false
        var parked = false
        /// Subtitle-axis seconds of the most recently routed packet, NaN before the first one.
        var lastPacketSeconds = Double.nan
        var harvested = 0
        /// #220 defect 2: times the stream time-base lookup fell back to 0/1. Non-zero means
        /// the park guard was skipped at least once; historically that fallback was cached and
        /// disarmed the park permanently.
        var timeBaseFallbacks = 0
        /// #240: the reader is holding the link for the video path right now.
        var linkYield = false
        /// #240: cumulative seconds spent yielding the link, counting EVERY priority yield: a seek
        /// in flight, a producer that is fetching, both. It is not the valve's counter, and the
        /// two surfaces are meant to disagree. `#151 forward prefetch yielded the link for` is
        /// logged once per valve grant, so a session can hold seconds of ordinary yield here with
        /// no such line anywhere in the log. On a link with room this stays low but not at zero,
        /// because a seek yields unconditionally; a number that tracks playback time says the
        /// source is barely faster than the content and the lookahead is being paid for out of
        /// the video path's budget.
        var linkYieldSeconds = 0.0
        /// #240: times the continuous-yield cap fired and the reader took the link back anyway.
        /// The escape hatch is the risky half of a strict priority, so it gets a number rather
        /// than only a log line: non-zero says the video path claimed the link for a full
        /// `maxYieldSeconds` without parking, which is a finding whether or not cues went missing.
        var linkValveGrants = 0
        /// Why the loop stopped, nil while it runs. Reported instead of a bare `dead`, which
        /// could not tell the defect apart from the expected end of a session: the reader works
        /// `leadSeconds` ahead, so it reaches EOF a full lead before the playhead does and every
        /// completed playback ends with the loop gone. Flagging that as `dead` cries wolf over
        /// the last minute of every film.
        var exit: SubtitleForwardPrefetcher.Exit? = nil
    }

    private static let state = OSAllocatedUnfairLock(initialState: Snapshot())

    /// Marks a new prefetch session live and returns its generation for the later `ended` call.
    static func sessionStarted() -> Int {
        state.withLock { s in
            let next = s.generation &+ 1
            s = Snapshot(generation: next, running: true)
            return next
        }
    }

    static func sessionEnded(generation: Int, exit: SubtitleForwardPrefetcher.Exit) {
        state.withLock { s in
            guard s.generation == generation else { return }
            s.running = false
            s.parked = false
            s.exit = exit
        }
    }

    static func recordPacket(seconds: Double, harvested: Int) {
        state.withLock { s in
            s.lastPacketSeconds = seconds
            s.harvested = harvested
        }
    }

    static func recordPark(_ parked: Bool) {
        state.withLock { $0.parked = parked }
    }

    /// #240: the continuous-yield cap fired and the reader is taking its grant window.
    static func recordLinkValveGrant() {
        state.withLock { $0.linkValveGrants &+= 1 }
    }

    /// #240: enter or leave a link yield. `seconds` is charged on the way out, so the cumulative
    /// figure counts real waiting rather than poll ticks.
    static func recordLinkYield(_ yielding: Bool, seconds: Double = 0) {
        state.withLock { s in
            s.linkYield = yielding
            s.linkYieldSeconds += seconds
        }
    }

    static func recordTimeBaseFallback() {
        state.withLock { $0.timeBaseFallbacks &+= 1 }
    }

    static var snapshot: Snapshot { state.withLock { $0 } }

    static func probeFragment(playhead: Double) -> String {
        format(snapshot, playhead: playhead)
    }

    /// One memprobe fragment. A stopped loop reports WHY it stopped rather than a bare `dead`.
    /// `eof` is the expected end of every completed playback and carries no finding; `failed` is
    /// the #231 case worth acting on, a read error that ends the session mid-stream; `cancelled`
    /// and `openfail` are the remaining documented exits. Reporting them as one state made the
    /// signal fire over the closing minute of every film and hid the case it exists for.
    static func format(_ s: Snapshot, playhead: Double) -> String {
        guard s.running || s.harvested > 0 else { return "prefetch=off " }
        let lead = s.lastPacketSeconds.isFinite && playhead.isFinite
            ? String(format: "%.1f", s.lastPacketSeconds - playhead)
            : "n/a"
        let stopped: String = {
            switch s.exit {
            case .endOfFile: return "eof"
            case .readFailed: return "failed"
            case .openFailed: return "openfail"
            case .cancelled, nil: return "cancelled"
            }
        }()
        let live = s.linkYield ? "yield" : (s.parked ? "park" : "read")
        return "prefetch=\(s.running ? live : stopped) "
            + "prefetchLead=\(lead)s "
            + "prefetchHarvested=\(s.harvested) "
            + "prefetchTbFallback=\(s.timeBaseFallbacks) "
            + "prefetchYielded=\(String(format: "%.0f", s.linkYieldSeconds))s "
            + "prefetchValve=\(s.linkValveGrants) "
    }
}
