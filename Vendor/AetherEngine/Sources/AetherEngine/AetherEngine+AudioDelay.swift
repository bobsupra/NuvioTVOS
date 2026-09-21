import Foundation

/// AE#464: the audio presentation offset as a live setting.
///
/// Lip-sync error belongs to the viewer's chain (a soundbar or AVR adding video-processing latency,
/// or the reverse), not to the file, so it is a per-setup nudge people set once and expect a player
/// to honour on every session. AVFoundation offers a host nothing to set it with: `AVPlayerItem`
/// carries no audio-delay control, and an HLS-streamed asset vends no `AVAssetTrack` for an
/// `AVAudioMix` to bind to. Where the timestamps still exist is inside the engine, which is why this
/// lives here rather than on top.
extension AetherEngine {

    /// The audio presentation offset in force for this session, in seconds. Positive presents audio
    /// LATER relative to video. 0 (the default) means untouched.
    public var audioDelaySeconds: Double { loadedOptions.audioDelaySeconds }

    /// Change the audio presentation offset while playback runs.
    ///
    /// Positive delays audio, negative advances it; the value is clamped to
    /// `AudioDelayPolicy.maxAbsSeconds` and survives every rebuild the session makes on its own
    /// (reload at position, audio-track switch, AirPlay LAN swap, background return), because it is
    /// stored in the options those rebuilds replay. Passing the value already in force does nothing.
    ///
    /// **What it costs, per route.** The offset moves audio at the last place the engine still holds
    /// its timestamps, and on both routes the media between there and the speaker is already
    /// committed to the previous value: up to `AudioLookaheadPolicy.targetLeadSeconds` of decoded
    /// audio on `.software`, and on `.loopback` the segments AVPlayer has already fetched, whose cut
    /// audio cannot be re-timed in place (the seam would gain a gap or an overlap of exactly the
    /// change, and a change that moves audio earlier is eaten by the muxer's strictly-increasing DTS
    /// rule). So a change is brought to the playhead rather than left to arrive when that media
    /// drains, and what that costs differs:
    ///
    /// - `.software`: a seek to the current position. Measured on a 30 fps H.264 fixture: set at
    ///   t=4.90 s, landed at 4.90 s, the new offset delivered on the next buffer.
    /// - `.loopback`: the session-preserving reload (#460). A seek is not enough and measuring it is
    ///   what settled this: seeking to the position AVPlayer already holds is a buffer hit, so it
    ///   plays its old-offset segments out regardless, and dropping those segments under it only
    ///   turns the hand-over into a rebuffer (6 s measured). Replacing the item is the one thing that
    ///   makes AVPlayer let go. Measured on the same fixture: about 0.3 s of held picture, position
    ///   preserved to the sample (7.80 s to 7.80 s).
    ///
    /// This is why it is not free the way `setRate` is. A session that cannot re-anchor (live without
    /// a DVR window) keeps the value and lets it arrive at the next seam the session makes on its
    /// own, rather than being denied it.
    ///
    /// On `.remoteBypass` AVPlayer owns the whole media selection and the engine never sees the
    /// timestamps, and an audio-only session has no video for audio to be early or late against. Both
    /// keep the value for a later load and log the no-op, in `selectAudioTrack`'s style: a host that
    /// set it and heard nothing change cannot otherwise tell "this route cannot" from "it did not
    /// arrive".
    public func setAudioDelay(_ seconds: Double) {
        let requested = seconds
        let clamped = AudioDelayPolicy.clamp(requested)
        if AudioDelayPolicy.isOutOfRange(requested) {
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay \(Self.ms(requested)) is outside "
                + "+/-\(Self.ms(AudioDelayPolicy.maxAbsSeconds)); using \(Self.ms(clamped))",
                category: .engine
            )
        }
        guard AudioDelayPolicy.isChange(from: loadedOptions.audioDelaySeconds, to: clamped) else { return }
        setLoadedAudioDelay(clamped)

        // Round 3: a session being rebuilt has no route to ask. `videoRoute` drops to `.none` at
        // teardown, which is the ABSENCE of a route rather than a route that cannot carry an offset,
        // so the switch below answered `.unavailable` and told the host its session's timestamps were
        // not the engine's to move, while the reload underneath it was already cutting with the new
        // value. The value is in `loadedOptions`, which is exactly what that load reads, so the
        // honest answer is that it is on its way rather than that it cannot arrive.
        guard state != .loading else {
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay = \(Self.ms(clamped)) set while the session is "
                + "being rebuilt; the load in flight reads it from the options and delivers it",
                category: .engine
            )
            return
        }

        let route = videoRoute
        switch AudioDelayPolicy.application(for: route) {
        case .unavailable:
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay = \(Self.ms(clamped)), kept for the next load: "
                + "this session's audio timestamps are not the engine's to move (route=\(route.rawValue))",
                category: .engine
            )

        case .sampleTimestamps:
            // The renderer takes the new stamp on the next buffer. What is already decoded still
            // carries the old one, so re-anchor to bring the change to the playhead: on this path
            // that is a flush and a demuxer reposition, and it lands inside a seek.
            softwareHost?.setAudioDelay(clamped)
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay = \(Self.ms(clamped)) on the software path",
                category: .engine
            )
            reanchorForAudioDelay { position, _ in await self.seek(to: position, origin: .host) }

        case .segmentTimestamps:
            // A seek is NOT enough here, and measuring it is what settled the shape: seeking to the
            // position AVPlayer is already at is a buffer hit, so it holds on to the segments cut
            // with the old offset and plays them out anyway. Dropping them under it does not help
            // either; it just turns the hand-over into a rebuffer (measured: 6 s). The one call that
            // makes AVPlayer let go of an item's media is the one that replaces the item, so the
            // correction rides the session-preserving reload #460 built, which is also the spelling
            // this was filed as an alternative for.
            // Written onto the session that is running, not just carried in the options the reload
            // replays: if the reload below cannot happen (live without a DVR window), this is what
            // makes the next producer the session builds for its own reasons cut with the new value.
            nativeVideoSession?.audioDelaySeconds = clamped
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay = \(Self.ms(clamped)) on the loopback path",
                category: .engine
            )
            reanchorForAudioDelay { _, delay in
                // Round 2 (cmcpherson274): this was `try? await reloadAtCurrentPosition()`, under a
                // line that had already announced the re-cut. Two claims, one of them unverified: a
                // rebuild the session cannot make is not a rebuild, and a rebuild that threw is not
                // one either, so both used to read as a re-cut that happened. The refusal is asked
                // for BEFORE the rebuild, where it still costs nothing (#460 rule 2).
                if let refusal = self.sessionReloadRefusal {
                    EngineLog.emit(
                        "[AetherEngine] AE#464: audio delay = \(Self.ms(delay)) stands, but this "
                        + "session cannot be rebuilt in place (\(refusal.rawValue)); it arrives at "
                        + "the next seam the session makes on its own",
                        category: .engine
                    )
                    return
                }
                do {
                    try await self.reloadAtCurrentPosition()
                    EngineLog.emit(
                        "[AetherEngine] AE#464: re-cut at the playhead with audio delay "
                        + "\(Self.ms(delay))",
                        category: .engine
                    )
                } catch is CancellationError {
                    // Round 3: a superseded rebuild is not a failed one, and saying so cost a host
                    // two lines telling it the nudge it was mid-delivery had not arrived. The load
                    // that took this one's place reads the offset from `loadedOptions`, so the value
                    // in force is the value it cuts with.
                    EngineLog.emit(
                        "[AetherEngine] AE#464: the re-cut at the playhead was superseded by a newer "
                        + "load; the audio delay in force "
                        + "(\(Self.ms(self.loadedOptions.audioDelaySeconds))) is what that load cuts with",
                        category: .engine
                    )
                } catch {
                    EngineLog.emit(
                        "[AetherEngine] AE#464: the re-cut at the playhead failed (\(error)); the "
                        + "audio delay \(Self.ms(delay)) stands and arrives at the next seam",
                        category: .engine
                    )
                }
            }
        }
    }

    /// Bring the change to the playhead instead of leaving it to arrive when the media already
    /// committed to the old value drains. What that costs differs per route, which is why the caller
    /// passes the re-anchor in: a flush and a reposition on the software path, a whole item on the
    /// loopback one. Live without a DVR window has no position to return to, so the value simply
    /// stands from the next seam the session makes on its own.
    ///
    /// Neither route asks for the producer restart directly. A restart raised while no seek of the
    /// engine's own is in flight is reported as a user scrub (`setNativeScrubSeek`), which opened a
    /// second seek ticket aimed at the re-cut segment's START and left it stalled for the rest of the
    /// session, with `phase` stuck at `seeking`.
    ///
    /// **Round 3: presses that arrive during a re-anchor are folded into it.** The setter had no
    /// in-flight latch, so a stepper's three presses in one runloop turn raised three of these.
    /// Round 2 made the damage survivable (the parked position rebuilds a stacked one at the playhead
    /// rather than at the head), but the work was still done three times and the two that lost the
    /// generation race each reported a `CancellationError` as a FAILED re-cut, naming a value that
    /// was already superseded: a host reading its own log was told twice that the nudge it was in the
    /// middle of delivering had not arrived.
    ///
    /// Folding is safe because the value does not ride the call. Every press writes
    /// `loadedOptions.audioDelaySeconds` synchronously before this runs, and both routes read the
    /// offset from there when they rebuild, so a re-anchor that has not reached its rebuild yet
    /// already carries the newest value. Only a press that lands after the rebuild has read it needs
    /// anything more, and that is one catch-up pass: the loop ends as soon as what was delivered is
    /// what is in force, so a stepper held down converges instead of queueing a rebuild per press.
    private func reanchorForAudioDelay(_ reanchor: @escaping (_ position: Double, _ delay: Double) async -> Void) {
        guard Self.audioDelayRecutIsPossible(state: state, isLive: isLive, liveWindow: liveWindow) else {
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay = \(Self.ms(loadedOptions.audioDelaySeconds)) stands, "
                + "but this session cannot re-anchor at the playhead (state=\(state), live=\(isLive)); "
                + "it arrives at the next seam",
                category: .engine
            )
            return
        }
        guard !audioDelayReanchorInFlight else {
            EngineLog.emit(
                "[AetherEngine] AE#464: audio delay = \(Self.ms(loadedOptions.audioDelaySeconds)) folded "
                + "into the re-anchor already in flight; that rebuild delivers it",
                category: .engine
            )
            return
        }
        audioDelayReanchorInFlight = true
        Task { @MainActor in
            defer { self.audioDelayReanchorInFlight = false }
            var delivered = self.loadedOptions.audioDelaySeconds
            await reanchor(self.positionForSessionRebuild, delivered)
            while AudioDelayPolicy.isChange(from: delivered, to: self.loadedOptions.audioDelaySeconds) {
                guard Self.audioDelayRecutIsPossible(
                    state: self.state, isLive: self.isLive, liveWindow: self.liveWindow) else {
                    EngineLog.emit(
                        "[AetherEngine] AE#464: audio delay = "
                        + "\(Self.ms(self.loadedOptions.audioDelaySeconds)) was asked for while the last "
                        + "rebuild ran and this session can no longer re-anchor (state=\(self.state)); "
                        + "it arrives at the next seam",
                        category: .engine
                    )
                    return
                }
                delivered = self.loadedOptions.audioDelaySeconds
                await reanchor(self.positionForSessionRebuild, delivered)
            }
        }
    }

    /// Whether the session has a playhead to come back to. Pure so the rule is testable without a
    /// session: the states that carry no position are the same ones `seek` refuses, and a live source
    /// without a DVR window has no seekable range at all.
    ///
    /// Round 2 (cmcpherson274): this used to take the answer as a `Bool` and the call site derived it
    /// as `liveWindow != nil`, which is true for EVERY live session (`load` builds one for each; the
    /// engine's own field comment says so) and made the live-only branch above unreachable. The
    /// distinction is carried by `windowSeconds`, exactly as `liveSeekRefusedWithoutDVR` reads it. It
    /// takes the window itself now, so there is no derivation left at the call site to get wrong: a
    /// pure gate can only be as right as its arguments, and this one was tested only through its
    /// parameters.
    static func audioDelayRecutIsPossible(state: PlaybackState, isLive: Bool, liveWindow: LiveWindow?) -> Bool {
        switch state {
        case .idle, .loading, .ended, .error: return false
        default: break
        }
        // Live-only (`windowSeconds == nil`): no rewind range, so no position to come back to. The
        // software route's `seek(origin: .host)` would be refused as `liveWithoutDVR` and the loopback
        // route's reload would rejoin at the edge, which throws the viewer's place away to move audio.
        return !isLive || liveWindow?.windowSeconds != nil
    }

    /// Milliseconds, for log lines. The unit the correction is actually reasoned about in.
    static func ms(_ seconds: Double) -> String {
        String(format: "%+.0f ms", seconds * 1000)
    }
}
