import Foundation

/// #250: emission of the subtitle-resolution statement. See `SubtitleResolutionStatement` for what
/// the line claims and why neither the drain window's lead edge nor the drain cursor alone can
/// carry that claim.
///
/// Four emission points, chosen so the line marks transitions rather than ticks: the drainer runs
/// at 2 Hz per channel and a statement per tick would bury the moments that carry information.
///
/// - a drain tick that decoded a post-seek reconstruction window (`reason=reconstruction`)
/// - the 30 s memory probe (`reason=tick`)
/// - the forward prefetcher reaching end of stream (`reason=eof`)
/// - the frontier's source changing under a steady tick, e.g. the prefetcher dying (`reason=frontier`)
extension AetherEngine {

    /// The live fence. Read on the main actor, where both counters are truth; anything the side
    /// reader banked under a different one is a position from a superseded seek or another source.
    var subtitleResolutionFence: SubtitleResolutionStatement.Fence {
        .init(loadGeneration: loadGeneration, seekGeneration: currentSeekGeneration)
    }

    /// Which frontier currently bounds the claim. Deliberately free of any store access: the steady
    /// tick calls this every 500 ms per channel purely to notice a change of source.
    func currentSubtitleResolutionFrontier() -> SubtitleResolutionStatement.Frontier {
        let fence = subtitleResolutionFence
        return SubtitleResolutionStatement.via(
            prefetchFrontier: SubtitlePrefetchTelemetry.resolutionFrontier(matching: fence),
            prefetchAtEndOfFile: SubtitlePrefetchTelemetry.reachedEndOfFile(matching: fence))
    }

    func subtitleResolutionStatement(
        channel: SubtitleChannel, streamIndex: Int32,
        reason: SubtitleResolutionStatement.Reason
    ) -> SubtitleResolutionStatement.Statement {
        let fence = subtitleResolutionFence
        let cursor = subtitleDrainCursors[channel]
        let playhead = sourceTime
        return SubtitleResolutionStatement.make(
            fence: fence,
            streamIndex: streamIndex,
            coveredFrom: cursor?.coverageStart ?? (playhead - Self.subtitleDrainBackscanSeconds),
            // The DRAIN lead, not the prefetcher's: the statement is about decoded display state,
            // and the drainer's window is fixed at `subtitleDrainLeadSeconds` even while the OCR
            // worker has the prefetcher running 270 s ahead to feed it.
            windowThrough: playhead + Self.subtitleDrainLeadSeconds,
            decodedThrough: cursor?.lastDecodedPts ?? .nan,
            prefetchFrontier: SubtitlePrefetchTelemetry.resolutionFrontier(matching: fence),
            prefetchAtEndOfFile: SubtitlePrefetchTelemetry.reachedEndOfFile(matching: fence),
            // #276: the retained run's floor. Read straight off the cursor, which the drain tick
            // has already folded for this tick; nothing is recomputed here.
            retainedFrom: cursor?.retained?.from,
            reason: reason)
    }

    /// Emit an already-built statement. The drain tick builds one per tick either way, because
    /// #276 banks its `resolvedThrough` into the retained run's high-water whether or not the line
    /// is worth printing, and rebuilding it for the print would read the telemetry twice.
    func emitSubtitleResolutionStatement(_ statement: SubtitleResolutionStatement.Statement,
                                         channel: SubtitleChannel) {
        subtitleResolutionLastFrontier[channel] = statement.via
        EngineLog.emit(SubtitleResolutionStatement.format(statement), category: .engine)
    }

    func emitSubtitleResolutionStatement(
        channel: SubtitleChannel, streamIndex: Int32,
        reason: SubtitleResolutionStatement.Reason
    ) {
        emitSubtitleResolutionStatement(
            subtitleResolutionStatement(channel: channel, streamIndex: streamIndex, reason: reason),
            channel: channel)
    }

    /// A change of frontier source is a step change in what the engine can claim, so it is worth a
    /// line whenever it happens rather than waiting up to 30 s for the next cadence tick. The
    /// prefetcher dying mid-session (#231) is the case this exists for: nothing else in the log
    /// says that determination just collapsed to the pump's few seconds of lookahead.
    func emitSubtitleResolutionStatementIfFrontierChanged(
        channel: SubtitleChannel, streamIndex: Int32
    ) {
        let current = currentSubtitleResolutionFrontier()
        guard subtitleResolutionLastFrontier[channel] != current else { return }
        emitSubtitleResolutionStatement(channel: channel, streamIndex: streamIndex,
                                        reason: .frontier)
    }

    /// One line per active drain target. Used by the cadence tick and by the prefetcher's EOF.
    func emitSubtitleResolutionStatements(reason: SubtitleResolutionStatement.Reason) {
        for (channel, streamIndex) in subtitleDrainTargets {
            emitSubtitleResolutionStatement(channel: channel, streamIndex: streamIndex,
                                            reason: reason)
        }
    }
}
