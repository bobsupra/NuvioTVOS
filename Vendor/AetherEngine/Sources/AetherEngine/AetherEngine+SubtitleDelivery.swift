import Foundation

/// #357: emission of the subtitle-delivery statement. See `SubtitleDeliveryStatement` for what the
/// line reports and why neither the per-cue apply log nor the #250 resolution line can answer the
/// question it answers.
///
/// Emitted from the decoding path of `subtitleDrainTick` only. An idle tick decoded nothing and has
/// no counts to state; leaving its outcome unrecorded is deliberate, so that the next decoding tick
/// still compares against the last tick that actually did something.
extension AetherEngine {

    /// State the tick's outcome when it differs from the channel's last one, or whenever a reset
    /// window decoded. The fence is the live one, read here rather than passed in: a delivery count
    /// belongs to the generation that produced it, and the tick has not awaited anything since.
    func emitSubtitleDeliveryStatementIfTransitioned(
        channel: SubtitleChannel, streamIndex: Int32, playhead: Double,
        tally: SubtitleDeliveryStatement.Tally, isReset: Bool
    ) {
        let outcome = tally.outcome
        defer { subtitleDeliveryLastOutcome[channel] = outcome }
        guard SubtitleDeliveryStatement.shouldEmit(
            outcome: outcome,
            last: subtitleDeliveryLastOutcome[channel],
            isReset: isReset
        ) else { return }
        let statement = SubtitleDeliveryStatement.Statement(
            fence: subtitleResolutionFence,
            streamIndex: streamIndex,
            playhead: playhead,
            tally: tally)
        EngineLog.emit(SubtitleDeliveryStatement.format(statement), category: .engine)
    }
}
