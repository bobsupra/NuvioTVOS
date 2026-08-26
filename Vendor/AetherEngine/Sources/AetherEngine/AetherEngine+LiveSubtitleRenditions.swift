import Foundation

/// AE#359: subtitles carried as a separate HLS rendition on the live ingest path.
///
/// The loopback live path demuxes the picked video variant, so a `SUBTITLES` group in the upstream
/// master never reaches the demuxer and no subtitle track exists, however many the channel offers.
/// This surfaces the group's renditions as tracks and, once one is selected, fetches its WebVTT
/// segments and publishes their cues on the host-overlay surface the closed-caption tap already uses.
///
/// Deliberately lazy: the tracks come from the master's declaration alone, and nothing is fetched
/// until the host asks for one. A channel watched without subtitles must not pay a second HTTP loop.
extension AetherEngine {
    /// Base for the synthetic ids of live subtitle renditions. Sits clear of the A53 caption track
    /// (99_608), the host's external tracks (100_000) and the remote-HLS renditions (200_000).
    public static let liveSubtitleRenditionTrackIDBase = 300_000

    /// How far behind the playhead a freshly selected rendition is fetched. Covers a viewer who turns
    /// subtitles on and then jumps back a little, without paying for a provider's whole DVR window.
    static let liveSubtitleBackfillSeconds: TimeInterval = 120

    static func isLiveSubtitleRenditionTrackID(_ id: Int) -> Bool {
        id >= liveSubtitleRenditionTrackIDBase && id < liveSubtitleRenditionTrackIDBase + 1_000
    }

    /// Publish the renditions the live ingest resolved. Called once per load, before playback settles;
    /// the master's declaration is proof enough that the track exists, so unlike the caption tap there
    /// is nothing to wait for.
    func surfaceLiveSubtitleRenditions(_ renditions: [LiveSubtitleRenditionInfo]) {
        guard !renditions.isEmpty else { return }
        liveSubtitleRenditions = renditions
        for (ordinal, rendition) in renditions.enumerated() {
            subtitleTracks.append(TrackInfo(
                id: Self.liveSubtitleRenditionTrackIDBase + ordinal,
                name: rendition.name.isEmpty ? (rendition.language ?? "Subtitles") : rendition.name,
                codec: "webvtt",
                language: rendition.language,
                isDefault: rendition.isDefault,
                isForced: rendition.isForced
            ))
        }
        EngineLog.emit(
            "[AetherEngine] surfaced \(renditions.count) live subtitle rendition(s) from id "
            + "\(Self.liveSubtitleRenditionTrackIDBase)",
            category: .engine
        )
    }

    /// Select a rendition: take over the subtitle state the way the caption tap does (no drain target,
    /// no side demuxer), then start the fetch loop.
    func selectLiveSubtitleRendition(id: Int) {
        let ordinal = id - Self.liveSubtitleRenditionTrackIDBase
        guard ordinal >= 0, ordinal < liveSubtitleRenditions.count else { return }
        let rendition = liveSubtitleRenditions[ordinal]

        cancelSidecarTask()
        clearSubtitleDrainTarget(channel: .primary)
        liveSubtitleFetchTask?.cancel()
        isSubtitleActive = true
        activeEmbeddedSubtitleStreamIndex = -1
        activeSubtitleTrackIndex = id
        isLoadingSubtitles = false
        subtitleCues = []

        EngineLog.emit(
            "[LiveSubs] selected rendition \(rendition.language ?? "und") -> \(rendition.playlistURL.lastPathComponent)",
            category: .engine
        )
        liveSubtitleFetchTask = Task { [weak self] in
            await self?.runLiveSubtitleFetchLoop(rendition: rendition, trackID: id)
        }
    }

    /// Poll the rendition playlist and turn its new segments into cues.
    ///
    /// The first pass starts 120 s behind the playhead, not at the head of the playlist: a rendition
    /// playlist can list a whole DVR window (3600 entries at MDR), and walking it from the front means
    /// thousands of fetches for content that gets pruned on arrival. The backfill covers a viewer who
    /// turns subtitles on and then jumps back a little. Afterwards only unseen segment URIs are
    /// fetched, which is what makes a poll arriving before the window moved cost one small request.
    private func runLiveSubtitleFetchLoop(rendition: LiveSubtitleRenditionInfo, trackID: Int) async {
        // The wall time the engine's own timeline starts at. Without it a cue cannot be placed against
        // the picture at all, and guessing would put subtitles minutes away from the dialogue, so the
        // loop states that and stops rather than publishing something plausible and wrong.
        guard let anchorWall = (customReader as? LiveIngestSourceInfo)?.joinWallClock else {
            EngineLog.emit("[LiveSubs] upstream carries no EXT-X-PROGRAM-DATE-TIME, cues cannot be placed",
                           category: .engine)
            return
        }
        var anchorEngineTime = playlistShiftSeconds
        var seen: Set<String> = []
        // The first batch is worth one line of its own: it is the only place an anchor that landed
        // in the wrong hour is visible before any cue is due. The state line below then repeats the
        // same relation periodically.
        var loggedFirstBatch = false
        // The state line is worth having but not every two seconds: LogTap is a ring buffer, and a
        // line that repeats 30 times a minute pushes out everything a reader came for.
        var pollsSinceStateLine = 0
        let headers = loadedOptions.httpHeaders
        while !Task.isCancelled {
            guard activeSubtitleTrackIndex == trackID else { return }
            // The source axis can be re-anchored under a running session (a producer seam republishes
            // the shift). Everything already placed then refers to an axis that no longer exists, so
            // the cues go with it rather than staying behind by the delta, which is the shape a viewer
            // reads as subtitles drifting further out the longer a channel runs.
            if abs(playlistShiftSeconds - anchorEngineTime) > 0.5 {
                EngineLog.emit(String(format: "[LiveSubs] source axis moved %.3f -> %.3f, re-anchoring",
                                      anchorEngineTime, playlistShiftSeconds), category: .engine)
                anchorEngineTime = playlistShiftSeconds
                subtitleCues = []
                seen = []
            }
            var pollInterval = 2.0
            do {
                let text = try await Self.fetchText(rendition.playlistURL, headers: headers)
                guard case .media(let media) = try HLSPlaylistParser.parse(text) else { return }
                pollInterval = max(1, media.targetDuration)
                // Anchor the work at the playhead, not at the start of the playlist. A rendition
                // playlist is not a handful of segments: MDR publishes its whole two hour DVR window,
                // 3600 entries, and walking it from the front means thousands of fetches for content
                // that is hours behind the picture and gets pruned on arrival. Everything older than
                // the backfill span is marked seen without being fetched, so the loop starts at the
                // playhead and the poll after it only ever sees the new tail.
                let playheadWall = anchorWall.addingTimeInterval(clock.currentTime - anchorEngineTime)
                let backfillFrom = playheadWall.addingTimeInterval(-Self.liveSubtitleBackfillSeconds)
                for segment in media.segments {
                    if let end = segment.programDateTime?.addingTimeInterval(segment.duration),
                       end < backfillFrom {
                        seen.insert(segment.uri)
                        continue
                    }
                    if Task.isCancelled { return }
                    guard !seen.contains(segment.uri),
                          let wallStart = segment.programDateTime,
                          let url = HLSPlaylistParser.resolve(uri: segment.uri, against: rendition.playlistURL)
                    else { continue }
                    seen.insert(segment.uri)
                    guard let body = try? await Self.fetchText(url, headers: headers),
                          let parsed = WebVTTSegmentParser.parse(body) else { continue }
                    guard activeSubtitleTrackIndex == trackID else { return }
                    let fresh = WebVTTSegmentParser.cues(from: parsed, segmentWallStart: wallStart,
                                                         segmentDuration: segment.duration,
                                                         anchorWall: anchorWall,
                                                         anchorEngineTime: anchorEngineTime,
                                                         nextID: &liveSubtitleCueID)
                    subtitleCues = pruned(WebVTTSegmentParser.merged(into: subtitleCues, adding: fresh,
                                                                     nextID: &liveSubtitleCueID))
                }
                // One line per poll, the whole alignment in numbers: how far ahead of the picture the
                // newest cue sits. A viewer reporting "the subtitles lag" cannot tell a wrong anchor
                // from a stalled fetch, and these two values separate them.
                if !loggedFirstBatch, let first = subtitleCues.last {
                    loggedFirstBatch = true
                    EngineLog.emit(String(format: "[LiveSubs] anchored at wall %@ = source %.2f, first cue %.2f",
                                          "\(anchorWall)", anchorEngineTime, first.startTime),
                                   category: .engine)
                }
                pollsSinceStateLine += 1
                if let newest = subtitleCues.last,
                   pollsSinceStateLine >= max(1, Int((30 / pollInterval).rounded())) {
                    pollsSinceStateLine = 0
                    EngineLog.emit(String(format: "[LiveSubs] lead=%.1fs cues=%d newest=%.2f source=%.2f shift=%.2f",
                                          newest.startTime - sourceTime, subtitleCues.count,
                                          newest.startTime, sourceTime, playlistShiftSeconds),
                                   category: .engine)
                }
                // A rolling window drops segment URIs eventually; the set must not grow with the session.
                if seen.count > 512 { seen = Set(media.segments.map(\.uri)) }
            } catch {
                EngineLog.emit("[LiveSubs] rendition poll failed: \(error)", category: .engine)
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    /// Keep the published array bounded: a channel left running for hours would otherwise carry every
    /// line it ever showed, and #271 is the standing reminder that this array is paid for per publish.
    private func pruned(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        let horizon = clock.currentTime - (loadedOptions.dvrWindowSeconds ?? 600) - 60
        guard horizon > 0 else { return cues }
        return cues.filter { $0.endTime >= horizon }
    }

    private static func fetchText(_ url: URL, headers: [String: String]) async throws -> String {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSIngestError.playlistInvalid(reason: "rendition payload is not UTF-8")
        }
        return text
    }

    /// Drop the renditions and stop any fetch. Called from the session teardown paths that already
    /// clear `subtitleTracks`; a loop that outlives its channel would keep pulling a playlist that
    /// belongs to nothing.
    func teardownLiveSubtitleRenditions() {
        liveSubtitleFetchTask?.cancel()
        liveSubtitleFetchTask = nil
        liveSubtitleRenditions = []
        liveSubtitleCueID = 0
    }
}
