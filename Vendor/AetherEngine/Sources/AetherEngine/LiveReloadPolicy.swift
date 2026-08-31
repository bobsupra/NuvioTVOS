import Foundation

/// Positioning policy for pipeline reloads (audio-track switch, background-return reopen). Pure decisions, testable and centralized so the rule cannot drift across `reloadWithAudioOverride`'s two backend branches and `reloadAtCurrentPosition`.
///
/// Live rules exist because of a device-verified stall (tvOS 26, Jellyfin live `stream.ts`, 2026-06): reloading a live session against the same URL caused Jellyfin to re-serve its transcode backlog (~60 s, segments 0..19) at I/O speed before AVPlayer's first playlist fetch. The pre-readiness seek-to-0 then pointed 60 s behind the live edge while AVPlayer targeted edge-minus-holdback; the item fetched init.mp4 + all segments but never reached `readyToPlay`, parking in `waitingToPlay` forever (frozen frame). Fix: treat any live reload as a fresh join -- no stale-clock resume, no explicit start seek.
enum LiveReloadPolicy {

    /// Start position handed to `loadNative` / `loadSoftware` / `load(url:)`.
    ///
    /// - VOD: pre-reload playhead; positions <= 1 s collapse to nil to skip the seek at head.
    /// - Live: always nil. The DVR window restarts at rejoin; a position would be stale and could wedge AVPlayer against the backlog.
    static func resumePosition(isLive: Bool, currentTime: Double) -> Double? {
        if isLive { return nil }
        return currentTime > 1 ? currentTime : nil
    }

    /// Whether the native host should skip its explicit initial seek and let AVPlayer choose the join position.
    ///
    /// - Live REJOIN: true. Skipping gives AVPlayer edge-minus-holdback (3x TARGETDURATION), same as `loadRemoteHLS`. The zero-tolerance seek-to-0 is the prime suspect for the never-ready AVPlayerItem against Jellyfin's backlog.
    /// - Initial live JOIN: false. The first manifest is held until the 2-segment startup cushion exists; seg0 is already the cushioned edge; the explicit seek-to-0 reinforces it (device-verified; do not change).
    /// - VOD: false. Explicit seek makes replay-from-beginning land at 0:00.
    static func skipInitialSeek(isLive: Bool, isRejoin: Bool) -> Bool {
        isLive && isRejoin
    }

    /// AE#442: where a live REJOIN that swapped the item IN PLACE should come back.
    ///
    /// The rules above describe a reload that rebuilt the pipeline: `HLSVideoEngine` and its segment
    /// cache went with `stopInternal`, so the pre-reload position is not discarded, it stops existing.
    /// The stage-2 / #65 recovery reload is a different animal. It calls `host.load(inPlaceSwap: true)`
    /// under a session that stays whole: same producer, same cache, same served playlist. A playhead
    /// parked minutes inside the DVR window is still resident content at the moment that reload picks
    /// its join point, and rejoining at the edge throws away something that is provably still there.
    ///
    /// `behindWhenLastAdvancing` is deliberately NOT the live `behindLiveSeconds`. A stall inflates
    /// that by its own duration (the edge runs on while the playhead does not), so at the moment of a
    /// recovery it cannot tell a viewer parked in the window from an edge viewer whose picture just
    /// froze. The last sample where the clock actually moved can.
    ///
    /// `targetDurationSeconds` is the threshold rather than an invented constant: the edge advances one
    /// segment at a time, so a healthy playhead's distance from it oscillates within exactly one
    /// TARGETDURATION by construction. Beyond that the distance is a position, not the oscillation.
    ///
    /// Returns nil for every case that must keep today's edge rejoin: not live, no cache that can vouch
    /// for the position (remote-HLS live and the software live path both pass `residentRange: nil`), or
    /// a viewer who was at the edge anyway.
    static func recoveryRejoinPosition(
        isLive: Bool,
        playhead: Double,
        behindWhenLastAdvancing: Double,
        residentRange: ClosedRange<Double>?,
        targetDurationSeconds: Double?
    ) -> Double? {
        guard isLive, let range = residentRange else { return nil }
        // No served TARGETDURATION means no live playlist of ours to reason about; keep the edge rejoin.
        guard let targetDuration = targetDurationSeconds,
              behindWhenLastAdvancing > targetDuration else { return nil }
        // Clamped rather than refused: a position that slid out from under the stall is gone, and the
        // oldest surviving second is a far better answer for a viewer who was minutes back than the edge.
        return Swift.min(Swift.max(playhead, range.lowerBound), range.upperBound)
    }
}
