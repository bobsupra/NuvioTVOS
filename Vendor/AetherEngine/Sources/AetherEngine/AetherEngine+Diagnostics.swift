import Foundation
import Darwin.Mach
import AVFoundation

extension AetherEngine {

    /// #220 diagnostic opt-in: appends a live large-block census (blocks >= 1 MB, bucketed by
    /// size class) to the 30 s memprobe line. A flat `mallocBlocks` with a rising `mallocMB`
    /// identifies "one large buffer is growing" but not which one; the census names the size
    /// class so the search does not depend on having guessed the site.
    ///
    /// Off by default and intended for triage builds only: the walk holds every malloc zone
    /// through `force_lock`, which briefly blocks allocating threads.
    ///
    /// Enabling also arms a jump trigger on its own queue (see `MallocBlockCensusTrigger`). The 30 s
    /// memprobe cannot catch a failure that completes inside one sample, which is what every kill on
    /// #220 turned out to be, so the counter is polled at `triggerPollHz` and the zone walk runs once
    /// it climbs `triggerThresholdMB` above its running high-water. Pass `triggerPollHz: 0` for the
    /// plain 30 s census with no watcher.
    public nonisolated static func setLargeAllocationCensusEnabled(
        _ enabled: Bool,
        triggerThresholdMB: Int = 64,
        triggerPollHz: Double = 8
    ) {
        MallocBlockCensus.isEnabled = enabled
        if enabled {
            MallocBlockCensus.startTriggerWatch(thresholdMB: triggerThresholdMB, pollHz: triggerPollHz)
        } else {
            MallocBlockCensus.stopTriggerWatch()
        }
    }

    // MARK: - Buffer probe

    /// Seconds of AVPlayer buffer ahead of the current playhead (sum of loadedTimeRanges beyond now). 0 on SW path / pre-start.
    /// Surfaced in the 30 s memprobe and the #65 VOD shift-publish diagnostic so a stale cross-epoch buffer is visible.
    func avPlayerBufferAheadSeconds() -> Double {
        guard let avPlayer = currentAVPlayer, let item = avPlayer.currentItem else { return 0 }
        let now = item.currentTime().seconds
        var ahead = 0.0
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = (range.start + range.duration).seconds
            if end > now { ahead += end - max(start, now) }
        }
        return ahead
    }

    // MARK: - Memory diagnostic

    /// Cancel any prior probe, then emit one EngineLog line every 30 s under `.engine`. Line shape is documented on `memoryProbeTask`.
    func startMemoryProbe() {
        memoryProbeTask?.cancel()
        let sessionStart = Date()
        // #243: the disc pull path's byte tally is session-scoped like `elapsed`, so it can be read
        // as a rate off two probe lines.
        HTTPDiscIOReader.resetLifetimeFetchedBytes()
        // #134: currentTime()/loadedTimeRanges are sync XPC reads; hop them off the main actor.
        let probeReadQueue = DispatchQueue(label: "engine.memprobe.avfread", qos: .utility)
        memoryProbeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if Task.isCancelled { return }
                guard let self = self else { return }

                // AVPlayer buffer probe: if ahead > preferredForwardBufferDuration, suspect linear-growth memory leak.
                var bufferAheadSec = 0.0
                var bufferBehindSec = 0.0
                if let avPlayer = self.currentAVPlayer,
                   let item = avPlayer.currentItem {
                    (bufferAheadSec, bufferBehindSec) = await AVFoundationOffMain.read(item, on: probeReadQueue) { item in
                        let now = item.currentTime().seconds
                        var ahead = 0.0
                        var behind = 0.0
                        for value in item.loadedTimeRanges {
                            let range = value.timeRangeValue
                            let start = range.start.seconds
                            let end = (range.start + range.duration).seconds
                            if end > now { ahead += end - max(start, now) }
                            if start < now { behind += min(end, now) - start }
                        }
                        return (ahead, behind)
                    }
                    if Task.isCancelled { return }
                }
                let elapsed = Int(Date().timeIntervalSince(sessionStart))
                let rssMB = Self.residentMemoryMB()
                let cueCount = self.subtitleCues.count

                // Zero on SW path or pre-start; 30 s cadence makes non-atomic field drift irrelevant.
                let stats = self.nativeVideoSession?.diagnosticStats()
                let avioMB = (stats?.avioBytesFetched ?? 0) / 1024 / 1024
                let discFetchedMB = HTTPDiscIOReader.lifetimeFetchedBytes / 1024 / 1024
                let cacheMB = (stats?.segmentCacheBytes ?? 0) / 1024 / 1024
                let cacheCount = stats?.segmentCacheCount ?? 0
                let packetsWritten = stats?.producerPacketsWritten ?? 0
                let audioFifo = stats?.audioFifoSamples ?? 0
                let abFifoKB = (stats?.audioBridgeFifoBytes ?? 0) / 1024
                let abSwrKB = (stats?.audioBridgeSwrBytes ?? 0) / 1024
                let abTotKB = (stats?.audioBridgeTotalBytes ?? 0) / 1024
                let muxBytesMB = (stats?.muxerLifetimeFragmentBytes ?? 0) / 1024 / 1024
                let muxCuts = stats?.muxerFragmentCuts ?? 0
                let srvConns = stats?.serverConnectionCount ?? 0
                let srvBytesMB = (stats?.serverLifetimeBytesSent ?? 0) / 1024 / 1024
                let srvSfMB = (stats?.serverSendfileBytesSent ?? 0) / 1024 / 1024
                let pktAlive = stats?.packetsAlive ?? 0
                let pktTotal = stats?.packetsTotalAllocs ?? 0

                // VM buckets: internal=heap, external=mmap/dyld, compressed=kernel-compressed, iosurfaces=decoded video frames.
                let vmStr: String
                if let vm = Self.vmBreakdownMB() {
                    vmStr = "vmInt=\(vm.internalMB)MB "
                        + "vmExt=\(vm.externalMB)MB "
                        + "vmCmp=\(vm.compressedMB)MB "
                        + "vmIOS=\(vm.iosurfaceMB)MB "
                        + "physFP=\(vm.physFootprintMB)MB "
                } else {
                    vmStr = ""
                }

                let mallocStr: String
                if let m = Self.mallocZoneSummary() {
                    mallocStr = "mallocBlocks=\(m.blocksInUse) mallocMB=\(m.sizeInUseMB) "
                } else {
                    mallocStr = ""
                }

                // #220: the two readers of a subtitled VOD session, separately attributable.
                // `ahead` above winHighWater (16 MB) with `susp=0` is backpressure that never
                // engaged; the pump's own window is the control.
                //
                // Both paths, not just software. On a direct-play source the native path runs
                // the HLS loopback, so `HLSVideoEngine` demuxes from the origin through an
                // AVIOReader of its own and only the remuxed segments reach AVPlayer. Its
                // producer parks whenever the forward buffer is full, which is exactly the
                // shape that lets a connection ignoring the suspend keep filling the window,
                // and the #174 field crash it was built against (HTTPS origin, boringssl in
                // the stack) was on this path. Reporting software-only hid that.
                let pumpWin = self.softwareHost?.ioWindowDiagnostics
                    ?? self.nativeVideoSession?.demuxer?.ioWindowDiagnostics
                let prefetchWin = self.subtitleForwardPrefetchDemuxer?.ioWindowDiagnostics
                let readerStr = Self.readerWindowFragment(
                    pump: pumpWin, prefetch: prefetchWin,
                    pumpFetchedBytes: self.softwareHost?.demuxerBytesFetched
                        ?? self.nativeVideoSession?.demuxerBytesFetched,
                    prefetchFetchedBytes: self.subtitleForwardPrefetchDemuxer?.avioBytesFetched)

                // #303: the software path's own read-ahead, and what the display did with it.
                // `avBufAhead` covers the AVPlayer path only, and `frameAhead` is the native
                // producer-shift fold that reads 0 here whatever the buffer is doing, so a software
                // session used to leave a trace with no cushion figure in it at all.
                let swStr = Self.softwareReadAheadFragment(
                    cushionSeconds: self.softwareHost?.displayCushionSeconds,
                    metrics: await self.softwareHost?.loadRenderMetrics())

                let line = "[AetherEngine] memprobe t=\(elapsed)s "
                    + "rss=\(rssMB)MB "
                    + vmStr
                    + mallocStr
                    // #220: empty unless the host opted in. A flat mallocBlocks with a rising
                    // mallocMB says one large buffer is growing but not which; this names the
                    // size class. `peak` is the watcher's high-water, which survives a step the
                    // 30 s cadence never sampled.
                    + MallocBlockCensus.probeFragment()
                    + (MallocBlockCensus.isEnabled ? "peakMB=\(MallocBlockCensus.peakSizeInUseMB) " : "")
                    + "avioFetchedMB=\(avioMB) "
                    // #243: only the disc pull path fills this, and only then is it printed. On a
                    // remote ISO every reader fork pulls through HTTPDiscIOReader, which
                    // `avioFetchedMB` does not see at all, so without it the one path doing the
                    // reading is the one path with no counter.
                    + (discFetchedMB > 0 ? "discFetchedMB=\(discFetchedMB) " : "")
                    + "cacheCount=\(cacheCount) cacheMB=\(cacheMB) "
                    + "packetsWritten=\(packetsWritten) "
                    + "audioFifo=\(audioFifo) "
                    + "abFifoKB=\(abFifoKB) abSwrKB=\(abSwrKB) abTotKB=\(abTotKB) "
                    + "muxBytesMB=\(muxBytesMB) muxCuts=\(muxCuts) "
                    + "srvConns=\(srvConns) srvBytesMB=\(srvBytesMB) srvSfMB=\(srvSfMB) "
                    + "pktAlive=\(pktAlive) pktTotal=\(pktTotal) "
                    + "subCues=\(cueCount) "
                    + readerStr
                    // #220: the lead is the live tell. It is visible minutes before a kill and
                    // separates "reads fast while building its lead" from "the lead never settles".
                    + SubtitlePrefetchTelemetry.probeFragment(playhead: self.sourceTime)
                    + "swFrames=\(self.softwareHostFramesEnqueued) "
                    + swStr
                    + "audioTracks=\(self.audioTracks.count) "
                    + "subTracks=\(self.subtitleTracks.count) "
                    + "subActive=\(self.isSubtitleActive) "
                    + "avBufAhead=\(String(format: "%.1f", bufferAheadSec))s "
                    + "avBufBehind=\(String(format: "%.1f", bufferBehindSec))s "
                    // Shift coherence: prodShift is the producer edge, hostShift the shift the clock folds
                    // with, and frameAhead their difference. Since #260 a VOD restart records a seam instead
                    // of collapsing the history, so a non-zero frameAhead now means the producer has moved to
                    // a new epoch while AVPlayer still presents the previous one, which is a real state and
                    // not a defect on its own; seams counts the epochs still on record.
                    + "frameAhead=\(String(format: "%.2f", self.frameAhead))s "
                    + "prodShift=\(String(format: "%.2f", self.activeProducerShiftSeconds))s "
                    + "hostShift=\(String(format: "%.2f", self.playlistShiftSeconds))s "
                    + "seams=\(self.presentationAxis.seams.count)"

                EngineLog.emit(line, category: .engine)

                // #250: the steady-state cadence for the subtitle-resolution statement. It rides
                // the memprobe rather than the 2 Hz drain tick because it states a span, and a
                // span restated four times a second per channel buries the transitions that carry
                // the information. Silent when no subtitle drain target is active.
                self.emitSubtitleResolutionStatements(reason: .tick)
            }
        }
    }

    /// Cancel any prior sampler, then start a fresh 1 Hz LiveTelemetrySampler. Mirrors `startMemoryProbe` lifecycle.
    func startLiveTelemetrySampler() {
        liveTelemetrySampler?.stop()
        let sampler = LiveTelemetrySampler(engine: self)
        liveTelemetrySampler = sampler
        sampler.start()
    }

    /// Resident memory via `mach_task_basic_info`, in MB. Returns 0 on error. Allocation-free; safe from any thread.
    static func residentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Int(info.resident_size / 1024 / 1024)
    }

    /// VM breakdown via `task_vm_info`: internal=heap/malloc, external=mmap/dyld, compressed=kernel-compressed, iosurfaces=HEVC frame pool.
    /// Surfaced in the 30 s memprobe so investigations can see which bucket moved.
    static func vmBreakdownMB() -> (internalMB: Int,
                                    externalMB: Int,
                                    compressedMB: Int,
                                    iosurfaceMB: Int,
                                    physFootprintMB: Int)? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return (
            internalMB: Int(info.internal / 1024 / 1024),
            externalMB: Int(info.external / 1024 / 1024),
            compressedMB: Int(info.compressed / 1024 / 1024),
            iosurfaceMB: Int(info.device / 1024 / 1024),
            physFootprintMB: Int(info.phys_footprint / 1024 / 1024)
        )
    }

    /// `malloc_zone_statistics(nil, ...)` summed across all zones. Rising block count = allocation leak; flat count + rising size = single large buffer growing.
    static func mallocZoneSummary() -> (blocksInUse: Int, sizeInUseMB: Int)? {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return (blocksInUse: Int(stats.blocks_in_use),
                sizeInUseMB: Int(stats.size_in_use / 1024 / 1024))
    }

    /// #220: one memprobe fragment per live `AVIOReader` window. `win` is the whole buffer,
    /// `ahead` the undrained forward extent that `appendPersistentData` gates the suspend on.
    /// `ahead` far above winHighWater (16 MB) while `susp=0` means the backpressure never
    /// engaged, which is a different defect from a transport overshoot past a suspend that did.
    /// `postMB` is what the transport delivered after the suspend was issued. #174 priced that
    /// as a bounded in-flight overshoot; a value tracking the whole window says `suspend()` is
    /// not stopping delivery, so the high water bounds nothing at all.
    ///
    /// #240: `FetchedMB` per reader is the link attribution. The aggregate `avioFetchedMB` cannot
    /// answer "who took the bandwidth", and the reporter of #240 had to infer a second reader from
    /// connection-start lines that carried no identity. Two counters side by side answer it directly:
    /// a session whose `prefFetchedMB` tracks `pumpFetchedMB` is reading the stream twice.
    nonisolated static func readerWindowFragment(
        pump: (windowBytes: Int, aheadBytes: Int, suspended: Bool, postSuspendBytes: Int64)?,
        prefetch: (windowBytes: Int, aheadBytes: Int, suspended: Bool, postSuspendBytes: Int64)?,
        pumpFetchedBytes: Int64? = nil,
        prefetchFetchedBytes: Int64? = nil
    ) -> String {
        func fragment(
            _ prefix: String,
            _ w: (windowBytes: Int, aheadBytes: Int, suspended: Bool, postSuspendBytes: Int64)?,
            _ fetched: Int64?
        ) -> String {
            guard let w else { return "" }
            return "\(prefix)WinMB=\(w.windowBytes / 1024 / 1024) "
                + "\(prefix)AheadMB=\(w.aheadBytes / 1024 / 1024) "
                + "\(prefix)Susp=\(w.suspended ? 1 : 0) "
                + "\(prefix)PostMB=\(w.postSuspendBytes / 1024 / 1024) "
                + (fetched.map { "\(prefix)FetchedMB=\($0 / 1024 / 1024) " } ?? "")
        }
        return fragment("pump", pump, pumpFetchedBytes)
            + fragment("pref", prefetch, prefetchFetchedBytes)
    }

    /// #303: the software path's read-ahead, and the display's own account of what it did with it.
    /// Empty on a native session, so the line does not carry three fields that can only read zero
    /// there. Each half is independently optional: the cushion exists as soon as a frame has been
    /// enqueued, while the metrics need an OS and a queue target that can answer for them.
    nonisolated static func softwareReadAheadFragment(
        cushionSeconds: Double?,
        metrics: SampleBufferRenderer.RenderMetrics?
    ) -> String {
        var out = ""
        if let cushionSeconds {
            out += "swAhead=\(String(format: "%.2f", cushionSeconds))s "
        }
        if let metrics {
            out += "swDropped=\(metrics.dropped)/\(metrics.total) "
            if metrics.corrupted > 0 { out += "swCorrupt=\(metrics.corrupted) " }
            out += "swDelay=\(String(format: "%.2f", metrics.accumulatedDelay))s "
        }
        return out
    }

    // MARK: - Live telemetry bridge

    /// Single write-through point: sampler never reaches into `EngineDiagnostics` directly.
    func applyLiveTelemetry(_ snapshot: LiveTelemetry) {
        diagnostics.liveTelemetry = snapshot
    }


    /// `Demuxer.avioBytesFetched` via HLSVideoEngine. Used by `LiveTelemetrySampler` for instant + average bitrate. 0 on SW path or pre-start.
    var demuxerBytesFetched: Int64 {
        nativeVideoSession?.demuxerBytesFetched ?? 0
    }

    /// Resident bytes in the loopback HLS segment cache. nil when no native session is active.
    var cachedBytes: Int64? {
        guard let bytes = nativeVideoSession?.segmentCacheTotalBytes else { return nil }
        return Int64(bytes)
    }

    /// Freshly stat-ed on-disk footprint of the segment cache. nil when no native session is active. Used by `aetherctl live --report-cache-bytes`.
    public var segmentCacheDiskBytes: Int64? {
        nativeVideoSession?.segmentCacheDiskBytes
    }

    /// Frames the SW host enqueued into AVSampleBufferDisplayLayer. Zero on native path or pre-start.
    ///
    /// #288: the software-path answer to "is there a picture, or is this audio into a black view".
    /// `AVPlayerItemVideoOutput.hasNewPixelBuffer` answers it on the native path, but a software
    /// session has no AVPlayer at all, so a host watchdog built on that probe alone reads every
    /// dav1d/libavcodec session as picture-less and kills healthy playback. Pair it with
    /// `currentAVPlayer == nil` to pick the backend, then watch this counter for movement.
    ///
    /// Monotonic within a session only: it belongs to the current SW host, and a `load()` that
    /// builds a new one restarts it at zero. A watchdog measuring deltas must treat a decrease as
    /// a new session, not as a stall.
    public var softwareHostFramesEnqueued: Int {
        softwareHost?.framesEnqueued ?? 0
    }

    /// Producer restart count for the current session. Zero on SW path or pre-start.
    var producerRestartCount: Int {
        nativeVideoSession?.producerRestartCount ?? 0
    }

    var muxedBytesLifetime: Int64 {
        Int64(nativeVideoSession?.muxedBytesLifetime ?? 0)
    }

    var serverBytesSentLifetime: Int64 {
        Int64(nativeVideoSession?.serverLifetimeBytesSent ?? 0)
    }

    var serverRequestCount: Int {
        nativeVideoSession?.serverRequestCount ?? 0
    }

    /// AudioBridge FIFO + swr-delay bytes. Zero when bridge is not active (stream-copy path or video-only source).
    var audioBridgeLiveBytes: Int {
        nativeVideoSession?.audioBridgeLiveBytes ?? 0
    }

    /// Cumulative encoded-audio bytes the bridge has emitted this session. Zero when bridge is not active
    /// (stream-copy path or video-only source). The telemetry sampler diffs it into a live bridge output bitrate.
    var audioBridgeOutputBytesLifetime: Int64 {
        nativeVideoSession?.audioBridgeOutputBytesLifetime ?? 0
    }

    /// Last A/V gate gap in source-clock ms. 0 before the first audio gate opens.
    var lastAVGapMs: Double {
        nativeVideoSession?.lastAVGapMs ?? 0
    }
}
