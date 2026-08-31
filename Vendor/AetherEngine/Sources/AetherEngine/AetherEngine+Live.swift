import Foundation
import CoreGraphics

extension AetherEngine {

    /// Frame from the DVR segment cache at `atSessionSeconds` (seekableLiveRange axis). No network: converts session time to raw output via seam history, then decodes locally. nil when no native live session, time outside resident window, or decode fails.
    public func liveScrubThumbnail(atSessionSeconds seconds: Double, maxWidth: Int = 320) async -> CGImage? {
        guard isLive, let session = nativeVideoSession else { return nil }
        // seekableLiveRange is output-time + seam shift; segment table and tfdt live on raw output. Resolve newest seam (inverts $currentTime fold).
        let outputSeconds: Double
        outputSeconds = presentationAxis.itemSeconds(forSourceSeconds: seconds)
            ?? (seconds - playlistShiftSeconds)
        let gen = loadGeneration
        let source = await Task.detached(priority: .userInitiated) { [session] in
            session.scrubThumbnailSource(atSeconds: outputSeconds)
        }.value
        guard let source else { return nil }
        // Guard against zap/stop clearing the LRU: a stale extractor's segment indices collide with the next channel's.
        guard loadGeneration == gen else { return nil }
        let extractor: FrameExtractor
        if let idx = scrubThumbnailExtractors.firstIndex(where: { $0.segmentIndex == source.segmentIndex }) {
            let hit = scrubThumbnailExtractors.remove(at: idx)
            scrubThumbnailExtractors.append(hit)
            extractor = hit.extractor
        } else {
            extractor = FrameExtractor(reader: DataIOReader(data: source.data), formatHint: "mp4")
            scrubThumbnailExtractors.append((source.segmentIndex, extractor))
            while scrubThumbnailExtractors.count > 2 {
                let evicted = scrubThumbnailExtractors.removeFirst()
                Task { await evicted.extractor.shutdown() }
            }
        }
        return await extractor.thumbnail(at: outputSeconds, maxWidth: maxWidth)
    }

    /// 1 Hz timer to update live surfaces while paused (the `$currentTime` sink already covers the playing case).
    func startLiveWindowTimer(host: NativeAVPlayerHost) {
        liveWindowTimerTask?.cancel()
        guard isLive else { return }
        liveWindowTimerTask = Task { [weak self, weak host] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let host else { return }
                guard self.isLive else { continue }
                self.publishLiveWindow(edgeSessionTime: host.seekableEnd + self.playlistShiftSeconds)
            }
        }
    }

    /// How far behind a live-only session (no DVR window) must be on resume before the playhead counts as
    /// evicted rather than merely behind. A live-only source retains seconds, not minutes.
    nonisolated static let liveOnlyResumeSnapSeconds: Double = 45
    /// Landing margin above the retained floor, so the resume does not start on the very segment the next
    /// eviction takes.
    nonisolated static let liveResumeClampMarginSeconds: Double = 5

    /// What resuming a behind-live session should do to the playhead, as one pure decision (AE#444).
    ///
    /// Both non-`none` outcomes are recoveries from a position that no longer exists, not policy about
    /// where a viewer should be: a live-only source retains seconds, and a DVR window that has slid past
    /// the playhead has evicted it. `clampsToWindow == false` hands that judgement to the host, which is
    /// the only place semantics like "a pause longer than 90 s re-tunes" can live.
    enum LiveResumeAction: Equatable {
        case none
        /// Live-only: `seek(to:)` refuses targets without a DVR window, so this drives the host directly.
        case edgeSnap
        case seek(to: Double)
    }

    nonisolated static func liveResumeAction(
        clampsToWindow: Bool,
        windowSeconds: Double?,
        behindLiveSeconds: Double,
        seekableLowerBound: Double?,
        edgeTime: Double
    ) -> LiveResumeAction {
        guard clampsToWindow else { return .none }
        let margin = liveResumeClampMarginSeconds
        guard let window = windowSeconds else {
            return behindLiveSeconds > liveOnlyResumeSnapSeconds ? .edgeSnap : .none
        }
        // AE#441 follow-up: the LANDING has read the cache's real floor since 6.52.0, but the TRIGGER
        // was still `behind > window - margin`, pure window arithmetic. The two disagree in exactly the
        // regime the retest confirmed on a real strip: retention short of the window (window 420 s,
        // advertised depth ~405 s). A resume between the real depth and the window then found no clamp
        // for a position the cache no longer held. Measure both from the same bound.
        //
        // The margin belongs to the sliding regime only. Before the window fills, the floor is the
        // session's own start rather than an eviction frontier, so nothing is coming to take it and a
        // margin there would only shove a resume near the start forward.
        let floor = seekableLowerBound ?? Swift.max(0, edgeTime - window)
        let playhead = edgeTime - behindLiveSeconds
        let sliding = edgeTime > window
        guard playhead < floor + (sliding ? margin : 0) else { return .none }
        return .seek(to: (seekableLowerBound ?? edgeTime) + margin)
    }

    /// After a long pause the sliding DVR window may have evicted the playhead. Clamp to the retained
    /// floor plus a margin, or for live-only (no DVR) snap to the edge when far enough behind.
    func clampLiveResumeIfBehindWindow() {
        guard isLive, let w = liveWindow else { return }
        let action = Self.liveResumeAction(
            clampsToWindow: loadedOptions.clampsLiveResumeToWindow,
            windowSeconds: w.windowSeconds,
            behindLiveSeconds: w.behindLiveSeconds,
            seekableLowerBound: w.seekableRange?.lowerBound,
            edgeTime: w.edgeTime
        )
        let behind = String(format: "%.1f", w.behindLiveSeconds)
        let window = w.windowSeconds.map { String(format: "%.0f", $0) } ?? "live-only"
        switch action {
        case .none:
            // AE#444: a resume the host owns says so. Silence here is indistinguishable from a resume
            // that was never behind, and this option exists precisely so somebody else decides.
            if !loadedOptions.clampsLiveResumeToWindow,
               w.behindLiveSeconds > Self.liveOnlyResumeSnapSeconds {
                EngineLog.emit(
                    "[AetherEngine] live resume clamp deferred to host: behind=\(behind)s window=\(window)",
                    category: .session
                )
            }
        case .edgeSnap:
            EngineLog.emit(
                "[AetherEngine] live resume clamp: behind=\(behind)s window=live-only -> edge snap",
                category: .session
            )
            Task { await self.seekToLiveEdge() }
        case .seek(let t):
            EngineLog.emit(
                "[AetherEngine] live resume clamp: behind=\(behind)s window=\(window) "
                + "-> seek \(String(format: "%.1f", t))",
                category: .session
            )
            Task { await self.seek(to: t) }
        }
    }

    /// AE#441: the segment cache's oldest contiguously-playable position, lifted onto the session axis
    /// the live surfaces speak. nil on every path with no such cache to ask (software live), which
    /// leaves `seekableLiveRange` on window arithmetic exactly as before.
    ///
    /// Same axis conversion as `liveScrubThumbnail`, inverted: the segment table and its `startSeconds`
    /// live on raw output, `seekableLiveRange` is output plus the seam shift.
    func residentLiveFloorSessionSeconds() -> Double? {
        guard let session = nativeVideoSession,
              let outputFloor = session.residentFloorOutputSeconds() else { return nil }
        return presentationAxis.sourceSeconds(forItemSeconds: outputFloor)
            ?? (outputFloor + playlistShiftSeconds)
    }

    /// AE#446 round 4: measure how far the current item's own timeline sits below the session's.
    ///
    /// A live item's zero is the first segment ITS playlist listed. The producer's window floor and
    /// the item's own floor slide together, because one rule sizes both (`LiveWindowSizing` is the
    /// single source of truth for the playlist's first visible segment and the cache's eviction), so
    /// their difference is the offset and it holds still while both ends move. Measured on the harness
    /// across twelve seconds of sliding: 50.00 s at every sample, while the item's floor walked from
    /// 0.00 to 15.00 and the producer's from 51.40 to 66.40.
    ///
    /// Latched per item, because it is a property of the playlist that item loaded, and re-measured
    /// when the item under the host changes. It reads 0 for the item a session starts with, which is
    /// why nothing needed it until a swap attached a second one.
    @MainActor
    func measureLiveItemAxisOffset() {
        guard isLive, let host = nativeHost else { return }
        guard host.itemGeneration != liveItemAxisOffsetGeneration else { return }
        // AE#454: everything below this line establishes the axis; until it succeeds there is no
        // measurement for THIS item, and the one above it belongs to the item that just left. See
        // `liveItemAxisUnmeasuredAfterSwap` for what the clock does in the meantime.

        // A range of zero width is an item that has not reported yet, not an item at the origin.
        guard host.seekableEnd > host.seekableStart,
              let producerFloor = residentLiveFloorSessionSeconds() else { return }
        let offset = Self.liveItemAxisOffset(producerFloorSession: producerFloor,
                                             itemSeekableStart: host.seekableStart,
                                             shift: playlistShiftSeconds)
        guard offset.isFinite else { return }
        liveItemAxisOffsetGeneration = host.itemGeneration
        liveItemAxisOffsetSeconds = offset
        guard liveItemAxisOffsetSeconds > 0.01 else { return }
        EngineLog.emit(
            "[AetherEngine] #446 this item's playlist began \(String(format: "%.2f", liveItemAxisOffsetSeconds))s "
            + "into the session, so its own clock reads that much below the session's; folding it into "
            + "every conversion for as long as this item is the one playing",
            category: .engine)
    }

    /// AE#454: a fresh item has no position for the session until it says it can play.
    ///
    /// Two readings are wrong in the window between an in-place swap and the fresh item's readiness,
    /// and they were both being published as the session's playhead:
    ///
    /// - The axis offset is latched per item and re-measured when the item under the host changes,
    ///   but the re-measurement needs the fresh item to have reported a seekable range of its own.
    ///   Until then the RETIRED item's offset was folded into the fresh item's clock, which reads ~0,
    ///   so the session published the retired item's zero: 70 to 80 s below the place it held in the
    ///   field, 80.27 s below it on the harness.
    /// - Even with the axis established, AVPlayer's clock before readiness names the segment it
    ///   fetched first rather than where it will start. Measured on the harness after the placement
    ///   moved into the playlist: the item was placed at 50.14 s and reported 40.17 s, one segment
    ///   below, for 192 ms.
    ///
    /// Neither is a reading of where the session is, and both flowed into `LiveWindow.noteEdge`, which
    /// is a running maximum a single wrong sample latches. So the clock and the window hold across the
    /// hand-off. The hold is bounded by readiness, which every other part of the session already
    /// depends on; an item that never becomes ready leaves the clock on the frame that is actually on
    /// screen, which is the honest report of that session.
    ///
    /// False for the first item of a session, where nothing has been accepted yet and the cold join
    /// publishes exactly as before.
    var liveItemPlacementPending: Bool {
        guard isLive, let host = nativeHost else { return false }
        return Self.liveItemPlacementPending(
            acceptedGeneration: liveAcceptedItemGeneration,
            itemGeneration: host.itemGeneration,
            axisGeneration: liveItemAxisOffsetGeneration,
            itemReportsRange: host.seekableEnd > host.seekableStart)
    }

    /// AE#454: from here on, what the item under the host reports IS what the session reports.
    ///
    /// Taken at readiness on every ordinary path, and one step later on a rejoin: an item that is
    /// ready but has not been placed yet is playing where the playlist put it, not where the session
    /// decided to be, and the placement can still be a seek away.
    @MainActor
    func acceptCurrentItemForPublishing() {
        liveAcceptedItemGeneration = nativeHost?.itemGeneration ?? -1
    }

    /// AE#454: the rule above, on its own so the case can be stated without a session.
    nonisolated static func liveItemPlacementPending(
        acceptedGeneration: Int,
        itemGeneration: Int,
        axisGeneration: Int,
        itemReportsRange: Bool
    ) -> Bool {
        guard acceptedGeneration != -1 else { return false }
        if itemGeneration != acceptedGeneration { return true }
        // Ready and axis-less is not a contradiction: they are separate signals and their order is
        // AVFoundation's business, so the second reading is guarded on its own input.
        return itemGeneration != axisGeneration && !itemReportsRange
    }

    /// AE#446 round 4: the arithmetic behind `measureLiveItemAxisOffset`, on its own so the case can
    /// be stated without a session.
    ///
    /// The producer's floor is on the session axis; the item's floor is on the item's own. One rule
    /// sizes both, so their difference is what separates the axes, and it is a difference rather than
    /// an assumption. Negative is not a case that can be acted on (an item claiming to hold content
    /// older than the producer does), and it folds to 0, which is the pre-swap behaviour.
    nonisolated static func liveItemAxisOffset(
        producerFloorSession: Double, itemSeekableStart: Double, shift: Double
    ) -> Double {
        Swift.max(0, producerFloorSession - (itemSeekableStart + shift))
    }

    /// AE#446 round 4: the three readings a rejoin's placement is argued from, on one line.
    ///
    /// They were only ever available separately, which is why an item's clock and an item's seekable
    /// range could disagree for a whole investigation without anyone being able to say so. Bounded to
    /// the seconds after a swap, so a live session does not pay for it.
    @MainActor
    func auditLiveRejoinPlacement() {
        guard let until = liveRejoinAuditUntil, let host = nativeHost else { return }
        let now = Date()
        guard now < until else { liveRejoinAuditUntil = nil; return }
        if let last = liveRejoinAuditLastEmit, now.timeIntervalSince(last) < 1.0 { return }
        liveRejoinAuditLastEmit = now
        let producer = residentLiveRangeSessionSeconds()
        EngineLog.emit(
            "[AetherEngine] #446 placement audit: item clock \(String(format: "%.2f", nativeClockSeconds))s "
            + "in item range \(String(format: "%.2f", host.seekableStart))..\(String(format: "%.2f", host.seekableEnd))s, "
            + "shift \(String(format: "%.2f", playlistShiftSeconds))s + item offset "
            + "\(String(format: "%.2f", liveItemAxisOffsetSeconds))s -> session \(String(format: "%.2f", currentTime))s; "
            + "the producer holds "
            + (producer.map { "\(String(format: "%.2f", $0.lowerBound))..\(String(format: "%.2f", $0.upperBound))s" } ?? "nothing it can state"),
            category: .engine)
    }

    /// AE#446 round 4: what the producer holds right now, on the session axis, both ends.
    ///
    /// This is the range a rejoin is measured against, and it is deliberately not either of the two
    /// the engine publishes. `LiveWindow.edgeTime` is a running maximum an outage freezes BELOW the
    /// playhead that legitimately ran past it, and a freshly swapped item's `seekableEnd` is a range
    /// it has not finished reporting at the readiness instant the rejoin replays in (measured on the
    /// harness: 43.4 s while the place held was 71.4 s and the producer was cutting past 100 s). The
    /// cache is the only party that is neither ahead of nor behind itself.
    ///
    /// nil where there is no cache to ask, which leaves the rejoin exactly where it was.
    func residentLiveRangeSessionSeconds() -> ClosedRange<Double>? {
        guard let session = nativeVideoSession,
              let floorOutput = session.residentFloorOutputSeconds(),
              let ceilingOutput = session.residentCeilingOutputSeconds() else { return nil }
        let floor = presentationAxis.sourceSeconds(forItemSeconds: floorOutput)
            ?? (floorOutput + playlistShiftSeconds)
        let ceiling = presentationAxis.sourceSeconds(forItemSeconds: ceilingOutput)
            ?? (ceilingOutput + playlistShiftSeconds)
        guard ceiling >= floor else { return nil }
        return floor...ceiling
    }

    /// AE#442: the TARGETDURATION the live playlist is serving, nil on every path that serves none
    /// (remote HLS live, the software live path, and before the first playlist build).
    var liveTargetDurationSeconds: Double? {
        nativeVideoSession?.sealedLiveTargetDurationSeconds().map(Double.init)
    }

    /// Publish `liveEdgeTime`, `seekableLiveRange`, `isAtLiveEdge`, `behindLiveSeconds`. Path-agnostic; no-op when no live window is active.
    @MainActor
    func publishLiveWindow(edgeSessionTime: Double) {
        guard var w = liveWindow else { return }
        w.noteEdge(edgeSessionTime)
        w.notePlayhead(currentTime)
        w.noteResidentFloor(residentLiveFloorSessionSeconds())
        auditLiveRejoinPlacement()
        liveWindow = w
        // AE#442: tick-to-tick advancement, not a running maximum: a backward DVR seek drops the
        // playhead, and the next advancing publish has to be able to record the new, larger distance.
        if let previous = lastPublishedLivePlayhead, currentTime > previous + 0.05 {
            liveBehindWhenLastAdvancing = w.behindLiveSeconds
        }
        lastPublishedLivePlayhead = currentTime
        clock.liveEdgeTime = w.edgeTime
        clock.seekableLiveRange = w.seekableRange
        clock.isAtLiveEdge = w.isAtEdge
        clock.behindLiveSeconds = w.behindLiveSeconds
    }

    /// AE#446 round 4: who asked for a seek. The two differ in exactly two places, both about a live
    /// session that advertises no DVR window: whether the seek is refused outright, and whether its
    /// landing is measured against what the session offers or against what the item holds.
    ///
    /// A host that draws no scrubber can still have a place to come back to. Reported from a device:
    /// the outage swap carried the held position, the replay went out through the public `seek(to:)`
    /// like any host scrub, and the live-only guard refused it before it could land.
    enum SeekOrigin: Sendable {
        /// A scrub the host asked for, bound by the contract `seekableLiveRange` states.
        case host
        /// The engine coming back to a position it decided itself (the AE#446 outage swap, AE#442's
        /// in-place recovery reload). Not a scrub, and not bound by the scrubber's contract.
        case liveRejoin
    }

    /// AE#446 round 4: whether a live seek is refused for having no DVR window to land in.
    ///
    /// The refusal is the host contract's defence-in-depth: hosts hide the scrubber when
    /// `seekableLiveRange` is nil, and one that does not must not put the item somewhere it cannot
    /// play from. It says nothing about the engine's own rejoin, which picked its position out of
    /// content the session itself served.
    nonisolated static func liveSeekRefusedWithoutDVR(origin: SeekOrigin, windowSeconds: Double?) -> Bool {
        guard origin == .host else { return false }
        return windowSeconds == nil
    }

    /// AE#446 round 3: where a live seek lands, decided from ONE sample of the item's own clock.
    ///
    /// The two halves used to read different clocks. The target was clamped against
    /// `LiveWindow.edgeTime`, a running maximum folded over every publish tick of the session, and the
    /// conversion then subtracted that same edge from a `seekableEnd` sampled now. The pair only
    /// agrees while both describe the same epoch, and the two moments where they do not are exactly
    /// the ones a rejoin runs in:
    ///
    /// - An outage freezes the edge. The item that saw the ENDLIST never reloads its playlist, so
    ///   nothing advances `edgeTime` while the playhead legitimately runs on through the runway. The
    ///   held position is then ABOVE the published edge, the clamp pulls it back down onto it,
    ///   `behind` collapses to zero, and the fresh item joins the live edge. Measured on a device: a
    ///   viewer 31 s behind rejoined 29 s of content past the place it held, with its timeshift gone.
    /// - A rebase moves the shift. An edge published on the new shift against an item still
    ///   presenting the old one lands the seek BACKWARD by their difference (reported: 47 s of
    ///   re-watched content, 49.06 s of rebase).
    ///
    /// So the edge comes from the item being seeked, and the session-to-item conversion is the
    /// seam-aware one the rest of the engine already uses, which reads the shift that was in force for
    /// THIS position rather than the newest one the producer has moved to.
    nonisolated static func liveSeekLanding(
        requested: Double,
        window: LiveWindow,
        itemEnd: Double,
        shift: Double,
        axis: PresentationAxisMap,
        origin: SeekOrigin = .host,
        residentRange: ClosedRange<Double>? = nil,
        itemAxisOffset: Double = 0
    ) -> (sessionTarget: Double, clockTarget: Double) {
        // An item with no seekable range of its own yet has nothing to sample; the window's own edge
        // is then the only edge there is, and clamping against `shift` alone would collapse the range.
        let edge = itemEnd > 0 ? itemEnd + shift + itemAxisOffset : window.edgeTime
        // AE#446 round 4: a host scrub is bound by what the session ADVERTISES, and the engine's own
        // rejoin by what the producer HOLDS. They are different questions, and at the moment a rejoin
        // runs they have different answers: the advertised range is measured against an edge that is
        // stale in one direction or the other (see `residentLiveRangeSessionSeconds`), while the
        // carried position is content this same session cut and served, so the only thing that can
        // disqualify it is eviction.
        let sessionTarget: Double
        if origin == .liveRejoin, let resident = residentRange {
            sessionTarget = Swift.min(Swift.max(requested, resident.lowerBound), resident.upperBound)
        } else {
            sessionTarget = window.clamp(requested, edge: edge)
        }
        // AE#446 round 4: and then down onto the item's own axis, which for an item attached after
        // the window slid begins above the session's zero. See `measureLiveItemAxisOffset`.
        let clockTarget = Swift.max(
            0, (axis.itemSeconds(forSourceSeconds: sessionTarget) ?? (sessionTarget - shift))
               - itemAxisOffset)
        return (sessionTarget, clockTarget)
    }

    /// AE#454: how close the fresh item has to be to the place it was asked for before the correcting
    /// seek is not worth its cost.
    ///
    /// Tight on purpose. `EXT-X-START` with `PRECISE=YES` places an item exactly (measured on the
    /// harness: 6 ms from the target), so anything a segment boundary or an ignored tag could produce
    /// is far outside this and still gets the seek. It is a test of whether the placement WORKED, not
    /// a tolerance on where a rejoin may land.
    nonisolated static let liveRejoinPlacementSatisfiedSeconds: Double = 0.5

    /// AE#454: the item-axis position a live rejoin target resolves to right now, or nil with nothing
    /// to resolve it against. Same pure landing rule the seek itself uses, so the comparison cannot
    /// drift from the seek it decides to skip.
    @MainActor
    func liveRejoinItemAxisTarget(_ sessionTarget: Double) -> Double? {
        guard isLive, let window = liveWindow, let host = nativeHost else { return nil }
        return Self.liveSeekLanding(
            requested: sessionTarget,
            window: window,
            itemEnd: host.seekableEnd,
            shift: playlistShiftSeconds,
            axis: presentationAxis,
            origin: .liveRejoin,
            residentRange: residentLiveRangeSessionSeconds(),
            itemAxisOffset: liveItemAxisOffsetSeconds
        ).clockTarget
    }

    /// Seek to the current live edge. No-op when not live.
    public func seekToLiveEdge() async {
        guard isLive, let w = liveWindow else { return }
        // Live-only (no DVR window): seek(to:) refuses; drive native host directly to seekableEnd as the recovery move after eviction.
        guard w.windowSeconds != nil else {
            if let host = nativeHost {
                let clockTarget = max(0, host.seekableEnd)
                EngineLog.emit(
                    "[AetherEngine] live-only edge snap: clockTarget=\(String(format: "%.1f", clockTarget))",
                    category: .engine
                )
                await host.seek(to: clockTarget)
                nativeClockSeconds = clockTarget
                clock.currentTime = clockTarget + playlistShiftSeconds
                clock.sourceTime = currentTime
            }
            return
        }
        await seek(to: w.edgeTime)
    }
}
