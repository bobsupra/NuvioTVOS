import Foundation

/// MPV keep-open retains the file at EOF, so END_FILE need not be emitted.
/// This probe is only for full-screen trailers; it never changes the engine's
/// completion flags or the rules used for watched/progress tracking.
struct TrailerEndConfirmation {
    private struct Candidate {
        let generation: UInt64
        let beganAt: TimeInterval
        var lastSeenAt: TimeInterval
    }

    private var candidate: Candidate?

    mutating func reset() {
        candidate = nil
    }

    mutating func observe(
        isTrailer: Bool,
        usesMPV: Bool,
        reachedEOF: Bool,
        isStable: Bool,
        position: Double,
        duration: Double,
        loadGeneration: UInt64,
        uptime: TimeInterval
    ) -> Bool {
        // EOF is mandatory. Being paused or merely near the end is insufficient.
        guard isTrailer, usesMPV, reachedEOF, isStable,
              position.isFinite, duration.isFinite, uptime.isFinite,
              duration > 0, position >= 0, uptime >= 0,
              abs(duration - position) <= 1 else {
            reset()
            return false
        }

        guard var previous = candidate,
              previous.generation == loadGeneration,
              uptime >= previous.lastSeenAt,
              uptime - previous.lastSeenAt <= 1 else {
            candidate = Candidate(generation: loadGeneration, beganAt: uptime, lastSeenAt: uptime)
            return false
        }

        previous.lastSeenAt = uptime
        candidate = previous
        // Let asynchronous errors/seek transitions invalidate a transient EOF
        // before asking the existing trailer completion callback to navigate.
        return uptime - previous.beganAt >= 0.5
    }
}
