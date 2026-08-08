import Foundation

/// #250: one line stating the absolute source-time span the subtitle path has decoded display
/// state over, fenced by the engine's own generation counters.
///
/// The question it answers is the one no existing surface can: after a far seek lands, has the
/// pipeline DETERMINED the display state at the rendered position, or has it merely not produced
/// anything yet? On a PGS track with no acquisition point those two are indistinguishable from
/// outside, and every other subtitle diagnostic is playhead-relative, ungated by generation, or
/// states the harvest frontier rather than how far determination has advanced.
///
/// Neither of the two obvious candidates for `resolvedThrough` can be used:
///
/// - The drain window's own end (`playhead + subtitleDrainLeadSeconds`) claims determination over
///   bytes nobody has read. An empty window is ambiguous between "no cue here" and "not harvested
///   yet", which is precisely the ambiguity this line exists to remove.
/// - The drain cursor (`lastDecodedPts`) is the last actual cue. On a sparse track it stands still
///   for minutes, so every dialogue pause would read as unresolved.
///
/// So it is the decode window clamped to a harvest frontier, and the frontier's SOURCE travels with
/// it. `via=prefetch` is exact: since #230 the #151 reader's banked position is the read position on
/// the source axis (a cue PTS for a harvested packet, the monotone read DTS for a pacing one), so
/// everything below it that is not in the store genuinely carries no subtitle packet. `via=eof` is
/// the strongest state: the reader reached end of stream, so the whole window is determined.
/// `via=pump` is the weak one and says so: the producer tap has no read-position surface at all,
/// so the claim collapses to the drain cursor, a lower bound rather than a contiguity claim. A
/// `via=pump` line is itself the answer "not determined beyond what is already on screen".
enum SubtitleResolutionStatement {

    /// What bounds `resolvedThrough`, and therefore how much the number is worth.
    enum Frontier: String, Sendable {
        /// The #151 side reader's banked read position. Exact.
        case prefetch
        /// The side reader reached end of stream; the window is determined in full.
        case eof
        /// No usable side-reader frontier (never started, exited, or fenced to a superseded
        /// generation). Falls back to the drain cursor: a lower bound, not a contiguity claim.
        case pump
    }

    /// Why the line was emitted. Deliberately not every drain tick: the drainer runs at 2 Hz per
    /// channel and a statement per tick would bury the transitions that carry the information.
    enum Reason: String, Sendable {
        /// A post-seek reconstruction window finished decoding.
        case reconstruction
        /// Steady-state cadence, riding the 30 s memory probe.
        case tick
        /// The forward prefetcher reached end of stream.
        case eof
        /// The frontier's source changed, e.g. the prefetcher died and the pump is all that is left.
        case frontier
    }

    /// The engine's fence for a subtitle-resolution claim. A side-reader frontier is only usable
    /// while both counters still match the engine's live ones: `loadGeneration` rules out a
    /// different source entirely, `seekGeneration` rules out a position banked before the seek in
    /// question. Counting log lines cannot do this, which is the whole reason the numbers are here.
    struct Fence: Equatable, Sendable {
        var loadGeneration: UInt64
        var seekGeneration: UInt64

        init(loadGeneration: UInt64 = 0, seekGeneration: UInt64 = 0) {
            self.loadGeneration = loadGeneration
            self.seekGeneration = seekGeneration
        }
    }

    /// #276: the RETAINED contiguous decoded run, folded across seeks.
    ///
    /// `coveredFrom` is the current run's window start and resets on every discontinuity, so after
    /// a far seek it can neither affirm nor refute that determination still reaches back to track
    /// start. That is the one truth class the statement could not express: "empty because nothing
    /// was ever authored before this point" needs coverage back to the earliest point that could
    /// change the answer, and on a PGS track a composition established minutes earlier is still
    /// the displayed state.
    ///
    /// The engine does retain that determination: `reanchorSubtitleOverlays` deliberately leaves a
    /// drained channel's cues in place across a seek and only rebuilds the decoder and the stale
    /// arrival gate. What was missing is the bookkeeping, not the state. This is it.
    struct Retention: Equatable, Sendable {
        /// Earliest source time from which the retained decoded display state is contiguous. Like
        /// `coveredFrom` it is an upper bound on where determination begins and is deliberately
        /// unclamped: on a container with `start_time != 0` a clamp to zero would claim coverage
        /// below the first PTS, the exact over-claim this whole line exists to avoid.
        var from: Double
        /// High-water of the retained run's determined end. nil until a run states one. Advanced
        /// only by ticks that actually decoded, so an idle tick's unobserved frontier growth is
        /// never folded in: a high-water that lags reads as a gap at the next reset, which
        /// restarts the run and under-claims. That is the safe direction.
        var through: Double?
    }

    struct Statement: Equatable, Sendable {
        var fence: Fence
        var streamIndex: Int32
        var coveredFrom: Double
        /// nil when nothing inside the window is determined at all.
        var resolvedThrough: Double?
        var via: Frontier
        /// The last packet actually handed to the overlay decoder. Kept alongside
        /// `resolvedThrough` so a sparse stretch stays distinguishable from a starved one.
        var decodedThrough: Double
        /// #276: `Retention.from`, or nil when nothing is retained yet. Never later than
        /// `coveredFrom`; the two are separate claims and neither substitutes for the other.
        var retainedFrom: Double?
        var reason: Reason
    }

    /// #276: fold a fresh decode run's window start into the retained run.
    ///
    /// The runs join only when the new window starts INSIDE the retained span. Two rejections
    /// matter and both would otherwise be silent over-claims:
    ///
    /// - `windowFrom > through`: a forward seek past everything the old run determined leaves a
    ///   hole nobody decoded, and the 15 s backscan does not reach back over it.
    /// - `windowFrom < from`: a backward seek starting below the retained floor. The union is two
    ///   disjoint intervals until the new run's determination climbs up to the old floor, so the
    ///   retained span restarts on the new window rather than spanning the hole. The old run's
    ///   ceiling is dropped with it, which under-claims the top of a region nobody is asking
    ///   about: questions are asked at the playhead, which just moved below it.
    static func fold(_ retained: Retention?, windowFrom: Double) -> Retention {
        guard let retained, let through = retained.through,
              windowFrom >= retained.from, windowFrom <= through else {
            return Retention(from: windowFrom, through: nil)
        }
        return retained
    }

    /// #276: bank a tick's determined end into the retained run's high-water.
    ///
    /// Called on the tick that produced the value, never reconstructed later: at a reset tick the
    /// engine's `seekGeneration` has already advanced, so the outgoing run's frontier no longer
    /// passes its own fence and asking for it then would be exactly the cross-generation
    /// combination the fence forbids. Stamping it while it is live is not that: the engine is
    /// recording its own history at the moment it was valid.
    static func extend(_ retained: Retention, with determinedThrough: Double?) -> Retention {
        guard let determinedThrough, determinedThrough.isFinite else { return retained }
        var next = retained
        next.through = max(retained.through ?? determinedThrough, determinedThrough)
        return next
    }

    /// Which frontier bounds the claim. Split out because the drain tick needs it every tick to
    /// notice a change of source, and that check must not cost a store scan: it depends only on
    /// the side reader's fenced state.
    static func via(prefetchFrontier: Double?, prefetchAtEndOfFile: Bool) -> Frontier {
        if prefetchAtEndOfFile { return .eof }
        if let prefetchFrontier, prefetchFrontier.isFinite { return .prefetch }
        return .pump
    }

    /// Build the statement from what the drain tick and the prefetch telemetry each know.
    ///
    /// - Parameters:
    ///   - windowThrough: the decode window's lead edge, `playhead + lead`.
    ///   - coveredFrom: the start of the contiguous decoded run, i.e. the window start of the last
    ///     reset. Not the current tick's window start: steady ticks decode forward from the cursor.
    ///   - decodedThrough: the drain cursor, the last packet handed to the overlay decoder. Also
    ///     the pump case's whole answer: the drainer scans its window every tick, so the cursor is
    ///     the last packet stored inside it. A session-wide store frontier could not stand in for
    ///     that, since after a backward seek it sits far ahead of the window and would claim
    ///     determination over a region the pump never revisited.
    ///   - prefetchFrontier: the side reader's banked read position, or nil when it is unusable.
    ///     The caller is responsible for the fence check; an unfenced position is worse than none.
    ///   - prefetchAtEndOfFile: the fenced session ended at EOF.
    ///   - retainedFrom: `Retention.from` for the channel, or nil when nothing is retained. The
    ///     only field on the line that deliberately outlives a seek generation, because it is the
    ///     engine's own reconciliation of runs it fenced itself. It dies with the drain cursor,
    ///     which is cleared by every track switch and every session teardown, so it is still
    ///     load-fenced.
    static func make(
        fence: Fence,
        streamIndex: Int32,
        coveredFrom: Double,
        windowThrough: Double,
        decodedThrough: Double,
        prefetchFrontier: Double?,
        prefetchAtEndOfFile: Bool,
        retainedFrom: Double?,
        reason: Reason
    ) -> Statement {
        let via = self.via(prefetchFrontier: prefetchFrontier,
                           prefetchAtEndOfFile: prefetchAtEndOfFile)
        let bound: Double?
        switch via {
        case .eof: bound = windowThrough
        case .prefetch: bound = prefetchFrontier
        case .pump: bound = decodedThrough
        }
        var resolved: Double? = nil
        if let bound, bound.isFinite, bound >= coveredFrom {
            resolved = min(bound, windowThrough)
        }
        return Statement(fence: fence, streamIndex: streamIndex, coveredFrom: coveredFrom,
                         resolvedThrough: resolved, via: via, decodedThrough: decodedThrough,
                         retainedFrom: retainedFrom, reason: reason)
    }

    static func format(_ s: Statement) -> String {
        let resolved = s.resolvedThrough.map { String(format: "%.2f", $0) } ?? "none"
        let decoded = s.decodedThrough.isFinite ? String(format: "%.2f", s.decodedThrough) : "none"
        let retained = s.retainedFrom.map { String(format: "%.2f", $0) } ?? "none"
        return "[AetherEngine] #250 subtitle-resolution "
            + "loadGen=\(s.fence.loadGeneration) seekGen=\(s.fence.seekGeneration) "
            + "stream=\(s.streamIndex) "
            + "coveredFrom=\(String(format: "%.2f", s.coveredFrom)) "
            + "retainedFrom=\(retained) "
            + "resolvedThrough=\(resolved) "
            + "via=\(s.via.rawValue) "
            + "decodedThrough=\(decoded) "
            + "reason=\(s.reason.rawValue)"
    }
}
