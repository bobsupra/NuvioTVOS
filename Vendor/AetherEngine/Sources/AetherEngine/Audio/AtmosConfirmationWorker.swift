import Foundation

// #214 follow-up: opt-in confirmation of E-AC-3 JOC on the session's own audio tracks, so
// `TrackInfo.isAtmos` is an answer rather than the pre-decode guess a host cannot act on. Nothing in
// libavformat sets AV_PROFILE_EAC3_DDP_ATMOS, so the flag only ever appeared when find_stream_info
// happened to decode an audio frame by itself. This runs the same bounded pass as
// `AetherEngine.probeDetectingAtmos` (AtmosDetectionProbe.swift) on a second handle to the source,
// after the session is up, and republishes `audioTracks` as tracks confirm.
extension AetherEngine {

    /// Stream indices worth a pass: E-AC-3 (the sole carrier of JOC), not already confirmed, and backed by
    /// a real AVStream. External tracks are host-registered subtitles with synthetic ids and never audio.
    nonisolated static func atmosConfirmationCandidates(in tracks: [TrackInfo]) -> [Int32] {
        tracks.compactMap { track in
            guard track.codec.lowercased() == "eac3", !track.isAtmos, !track.isExternal,
                  let index = Int32(exactly: track.id), index >= 0 else { return nil }
            return index
        }
    }

    /// Re-apply the ledger to whatever `audioTracks` currently holds.
    ///
    /// Every republish has to run through here. The native demuxed-audio path swaps the whole list in
    /// `syncPublishedAudioStateFromNativeSession()`, and a disc title switch re-applies the probe-derived
    /// lists, so a confirmation set once at load would silently vanish on the next audio switch.
    func applyConfirmedAtmos() {
        guard !confirmedAtmosStreamIndices.isEmpty, loadedURL == confirmedAtmosSource else { return }
        audioTracks = Self.applyingConfirmedAtmos(to: audioTracks, confirmed: confirmedAtmosStreamIndices)
    }

    /// Pure half of `applyConfirmedAtmos`, so the ledger-to-track-list mapping is testable without a
    /// session. Additive: a track the base probe already marked stays marked, nothing is ever cleared.
    nonisolated static func applyingConfirmedAtmos(to tracks: [TrackInfo], confirmed: Set<Int32>) -> [TrackInfo] {
        guard !confirmed.isEmpty else { return tracks }
        return tracks.map { track in
            guard let index = Int32(exactly: track.id), confirmed.contains(index), !track.isAtmos else {
                return track
            }
            var flipped = track
            flipped.isAtmos = true
            return flipped
        }
    }

    /// Arm the pass for the loaded session. Called at the end of `load()` on every backend, so it runs
    /// after playback is up and never sits in front of the first frame.
    ///
    /// Skipped for live sources: a second connection to a live origin costs a tuner on some backends, the
    /// pass would start at the live edge rather than where playback is, and a live Atmos badge does not
    /// justify either. Skipped for forward-only custom readers, which cannot hand out a second cursor.
    func startAtmosConfirmation() {
        cancelAtmosConfirmation()
        guard loadedOptions.confirmAtmos, !isLive, let url = loadedURL else { return }
        // A session-preserving reload of the same item keeps what the previous pass already learned and
        // only chases what is still open; a new item starts from scratch.
        if confirmedAtmosSource != url {
            confirmedAtmosSource = url
            confirmedAtmosStreamIndices = []
        }
        applyConfirmedAtmos()
        let candidates = Self.atmosConfirmationCandidates(in: audioTracks)
        guard !candidates.isEmpty else { return }
        if isCustomSource, customReader?.makeIndependentReader() == nil { return }

        let headers = loadedOptions.httpHeaders
        let formatHint = customFormatHint
        let probesize = loadedOptions.probesize
        let maxAnalyzeDuration = loadedOptions.maxAnalyzeDuration
        atmosConfirmationTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runAtmosConfirmation(
                url: url, formatHint: formatHint, headers: headers,
                callerProbesize: probesize, callerMaxAnalyzeDuration: maxAnalyzeDuration,
                candidates: candidates)
        }
    }

    /// Teardown. `markClosed()` on the side demuxer so a parked AVIO read cannot outlive the session,
    /// the same rule the native subtitle readers follow.
    func cancelAtmosConfirmation() {
        atmosConfirmationTask?.cancel()
        atmosConfirmationTask = nil
        atmosConfirmationDemuxer?.markClosed()
        atmosConfirmationDemuxer = nil
    }

    /// One bounded pass per candidate, sequentially. Each opens its own demuxer and closes it before the
    /// next starts, so at most one extra handle on the source exists at a time. Every failure is silent
    /// and terminal for that track: the badge simply does not appear.
    nonisolated private func runAtmosConfirmation(
        url: URL, formatHint: String?, headers: [String: String],
        callerProbesize: Int64?, callerMaxAnalyzeDuration: Int64?,
        candidates: [Int32]
    ) async {
        var confirmed: [Int32] = []
        for index in candidates {
            guard !Task.isCancelled else { break }
            if await confirmAtmosForOneTrack(
                url: url, formatHint: formatHint, headers: headers,
                callerProbesize: callerProbesize, callerMaxAnalyzeDuration: callerMaxAnalyzeDuration,
                targetIndex: index
            ) {
                confirmed.append(index)
                await MainActor.run { [weak self] in
                    guard let self, self.loadedURL == self.confirmedAtmosSource else { return }
                    self.confirmedAtmosStreamIndices.insert(index)
                    self.applyConfirmedAtmos()
                }
            }
        }
        guard !Task.isCancelled else { return }
        EngineLog.emit(
            "[AtmosConfirmation] scanned \(candidates.count) E-AC-3 track(s), confirmed JOC on "
            + (confirmed.isEmpty ? "none" : confirmed.map(String.init).joined(separator: ", ")),
            category: .engine
        )
    }

    /// Open, detect, close. Returns whether this track is authoritatively JOC.
    nonisolated private func confirmAtmosForOneTrack(
        url: URL, formatHint: String?, headers: [String: String],
        callerProbesize: Int64?, callerMaxAnalyzeDuration: Int64?,
        targetIndex: Int32
    ) async -> Bool {
        // A fresh clone per pass: a demuxer owns its reader's cursor, so the passes cannot share one.
        let reader: IOReader? = await MainActor.run { [weak self] in
            guard let self, self.isCustomSource else { return nil }
            return self.customReader?.makeIndependentReader()
        }
        let demuxer = Demuxer()
        let registered = await MainActor.run { [weak self] () -> Bool in
            guard !Task.isCancelled, let self else { return false }
            self.atmosConfirmationDemuxer = demuxer
            return true
        }
        guard registered else {
            reader?.close()
            return false
        }
        defer {
            demuxer.close()
            reader?.close()
            Task { @MainActor [weak self, weak demuxer] in
                if let self, let demuxer, self.atmosConfirmationDemuxer === demuxer {
                    self.atmosConfirmationDemuxer = nil
                }
            }
        }

        guard AetherEngine.openAtmosConfirmationDemuxer(
            demuxer, url: url, reader: reader, formatHint: formatHint, headers: headers,
            callerProbesize: callerProbesize, callerMaxAnalyzeDuration: callerMaxAnalyzeDuration
        ) else { return false }
        guard !Task.isCancelled else { return false }
        return AetherEngine.detectAtmos(
            demuxer: demuxer, targetIndex: targetIndex, options: AtmosDetectionOptions()
        ).confirmedAtmos
    }

    /// Open `demuxer` on the source the way the confirmation pass wants it. Extracted so a test can drive
    /// the real open profile against real media without a session; the engine keeps ownership of the
    /// demuxer so `cancelAtmosConfirmation` can still `markClosed()` a parked read. An unopenable source
    /// is a false, never a throw: a background enrichment must not surface an error the host did not ask for.
    nonisolated static func openAtmosConfirmationDemuxer(
        _ demuxer: Demuxer, url: URL, reader: IOReader?, formatHint: String?,
        headers: [String: String], callerProbesize: Int64?, callerMaxAnalyzeDuration: Int64?
    ) -> Bool {
        let profile = DemuxerOpenProfile.atmosConfirmationDemuxer(
            callerProbesize: callerProbesize, callerMaxAnalyzeDuration: callerMaxAnalyzeDuration)
        do {
            if let reader {
                try demuxer.open(reader: reader, formatHint: formatHint, profile: profile)
            } else {
                try demuxer.open(url: url, extraHeaders: headers, profile: profile)
            }
            return true
        } catch {
            return false
        }
    }
}
