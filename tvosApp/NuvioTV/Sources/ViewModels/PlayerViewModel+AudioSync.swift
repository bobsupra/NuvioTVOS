import Foundation
import AetherEngine

/// What Sync by Audio is doing, for the AutoSubSync tab.
struct AudioSyncStatus: Equatable {
    enum Phase: Equatable {
        case reading
        case listening
        case following
        case stopped(String)
    }

    struct Change: Equatable {
        /// Where in the video (subtitle clock) the delay changed.
        var at: Double
        var shift: Double
    }

    var phase: Phase
    /// The add-on subtitle it runs for.
    var subtitleURL: String
    /// The external subtitle file that was selected when the run started.
    var loadedURL: String? = nil
    /// The absolute delay before audio sync changed it.
    var originalDelayMs: Int? = nil
    /// The latest absolute delay actually applied by audio sync.
    var syncedDelayMs: Int? = nil
    /// Whether the captured pre-sync delay is currently selected.
    var isOriginalTimingSelected = false
    var lines = 0
    /// Seconds of audio heard in the last window.
    var heard: Double = 0
    var last: AudioSyncEstimate?
    var estimates = 0
    var applied: Double?
    /// A change waiting for a moment without a line on screen.
    var pending: Double?
    var changes: [Change] = []
    var note: String?

    var isRunning: Bool {
        if case .stopped = phase { return false }
        return true
    }
}

/// The audio heard during one playback, as speech levels.
actor AudioSyncListener {
    private var meter = SpeechLevelMeter()
    private var timeline = SpeechLevelTimeline()
    private(set) var lastBufferUptime: TimeInterval = 0

    func take(_ tap: AudioTapBuffer) {
        lastBufferUptime = ProcessInfo.processInfo.systemUptime
        let pcm = tap.buffer
        guard let channel = pcm.floatChannelData?[0], pcm.frameLength > 0 else { return }
        if pcm.format.sampleRate > 0, meter.sampleRate != pcm.format.sampleRate {
            meter = SpeechLevelMeter(sampleRate: pcm.format.sampleRate)
        }
        let frames = meter.add(
            UnsafeBufferPointer(start: channel, count: Int(pcm.frameLength)),
            at: tap.sourceTime, discontinuity: tap.discontinuity)
        for frame in frames { timeline.set(frame.level, at: frame.frame) }
    }

    /// The audio around the playhead against the lines: seconds heard there, and the estimate
    /// once there is enough.
    func estimate(around playhead: Double, lines: [ClosedRange<Double>]) -> (heard: Double, estimate: AudioSyncEstimate?) {
        let fps = Double(AudioSubtitleSync.framesPerSecond)
        let first = max(0, Int(((playhead - AudioSubtitleSync.windowBefore) * fps).rounded(.down)))
        let last = max(first, Int(((playhead + AudioSubtitleSync.windowAfter) * fps).rounded(.up)))
        let levels = timeline.levels(from: first, count: last - first)
        let heard = Double(levels.filter { !$0.isNaN }.count) / fps
        guard heard >= AudioSubtitleSync.minHeard else { return (heard, nil) }
        return (heard, AudioSubtitleSync.estimate(levels: levels, firstFrame: first, lines: lines))
    }
}

/// One Sync by Audio run.
@MainActor
final class AudioSyncRun {
    let subtitleURL: String
    /// The file the engine shows (the add-on subtitle or its AutoSubSync copy).
    let loadedURL: String
    let generation: UInt64
    let listener: AudioSyncListener
    var lines: [ClosedRange<Double>] = []
    var shown: [ClosedRange<Double>] = []
    var tracker = AudioShiftTracker()
    /// The delay as Sync by Audio left it: anything else means it was changed by hand.
    var expectedDelayMs: Int
    var pending: Double?
    var pendingSince: TimeInterval = 0
    var subscription: UUID?
    var subscribedAt: TimeInterval = 0
    var consumer: Task<Void, Never>?
    var control: Task<Void, Never>?
    var nextEstimateAt: TimeInterval = 0
    var nextQuietCheckAt: TimeInterval = 0

    init(subtitleURL: String, loadedURL: String, generation: UInt64, listener: AudioSyncListener, delayMs: Int) {
        self.subtitleURL = subtitleURL
        self.loadedURL = loadedURL
        self.generation = generation
        self.listener = listener
        expectedDelayMs = delayMs
    }
}

/// Sync by Audio: lines the playing add-on subtitle up with the speech in the
/// soundtrack and keeps following it, through AetherEngine's audio tap.
extension PlayerViewModel {
    var isAudioSyncRunning: Bool { audioSyncRun != nil }

    private var selectedAudioSyncExternalSubtitleURL: String? {
        aetherController?.subtitleTracks.first(where: {
            $0.selected && !$0.externalFilename.isEmpty
        })?.externalFilename
    }

    /// A completed audio sync can be restored only while its source and selected delay are
    /// still the ones it captured. This remains available after the listener stops.
    var audioSyncTimingStatusForCurrentSubtitle: AudioSyncStatus? {
        guard let audioSyncStatus,
              activeEngineKind == .aether,
              audioSyncStatus.subtitleURL == activeAddonSubtitle?.url,
              audioSyncStatus.applied != nil,
              let loadedURL = audioSyncStatus.loadedURL,
              let originalDelayMs = audioSyncStatus.originalDelayMs,
              let syncedDelayMs = audioSyncStatus.syncedDelayMs else {
            return nil
        }
        guard selectedAudioSyncExternalSubtitleURL == loadedURL
                || (selectedAudioSyncExternalSubtitleURL == nil && loadedURL == audioSyncStatus.subtitleURL),
              subtitleDelayMs == (audioSyncStatus.isOriginalTimingSelected ? originalDelayMs : syncedDelayMs) else {
            return nil
        }
        return audioSyncStatus
    }

    /// Switches between the captured original delay and the latest delay audio sync applied.
    func toggleAudioSyncTiming() {
        guard let status = audioSyncTimingStatusForCurrentSubtitle,
              let originalDelayMs = status.originalDelayMs,
              let syncedDelayMs = status.syncedDelayMs,
              originalDelayMs != syncedDelayMs else { return }

        let selectingOriginal = !status.isOriginalTimingSelected
        let targetDelayMs = selectingOriginal ? originalDelayMs : syncedDelayMs
        if let run = audioSyncRun {
            guard run.subtitleURL == status.subtitleURL, run.loadedURL == status.loadedURL else { return }
            // The next listener tick must treat this as an intentional timing selection.
            run.expectedDelayMs = targetDelayMs
        }

        audioSyncStatus?.isOriginalTimingSelected = selectingOriginal
        setSubtitleDelayMs(targetDelayMs)

        // Keep pending estimates while original timing is selected. When synced timing is
        // restored, let the normal quiet-gap check decide whether a pending follow can apply.
        if !selectingOriginal, let run = audioSyncRun {
            applyPendingAudioShift(run)
        }
    }

    func toggleAudioSync() {
        if audioSyncRun != nil {
            stopAudioSync(reason: "Stopped")
        } else {
            startAudioSync()
        }
    }

    func startAudioSync() {
        stopAudioSync(reason: nil)
        guard let subtitle = activeAddonSubtitle else { return }
        guard activeEngineKind == .aether, let aether = aetherController else {
            audioSyncStatus = AudioSyncStatus(phase: .stopped("Needs AetherEngine (playing on MPV)"), subtitleURL: subtitle.url)
            return
        }
        let loadedURL = aether.subtitleTracks.first(where: { $0.selected && !$0.externalFilename.isEmpty })?.externalFilename
            ?? subtitle.url
        let generation = sessionCoordinator.loadGeneration
        // The audio heard earlier in this playback still counts.
        let listener: AudioSyncListener
        if let heard = audioSyncHeard, heard.generation == generation {
            listener = heard.listener
        } else {
            listener = AudioSyncListener()
            audioSyncHeard = (generation, listener)
        }
        let run = AudioSyncRun(
            subtitleURL: subtitle.url, loadedURL: loadedURL, generation: generation,
            listener: listener, delayMs: subtitleDelayMs)
        audioSyncRun = run
        audioSyncStatus = AudioSyncStatus(
            phase: .reading, subtitleURL: subtitle.url, loadedURL: loadedURL,
            originalDelayMs: subtitleDelayMs)
        run.control = Task { @MainActor [weak self] in
            let cues = await PlayerViewModel.audioSyncCues(loadedURL)
            guard !Task.isCancelled, let self, self.audioSyncRun === run else { return }
            self.beginListening(run, cues: cues)
        }
    }

    func stopAudioSync(reason: String?) {
        guard let run = audioSyncRun else { return }
        audioSyncRun = nil
        run.control?.cancel()
        run.consumer?.cancel()
        if let id = run.subscription { sceneAudioTapBroker.unsubscribe(id: id) }
        if let reason {
            audioSyncStatus?.phase = .stopped(reason)
            audioSyncStatus?.pending = nil
        }
    }

    /// A new file, or the player closing.
    func resetAudioSync() {
        stopAudioSync(reason: nil)
        audioSyncStatus = nil
        audioSyncHeard = nil
    }

    private static func audioSyncCues(_ url: String) async -> [SubtitleTimingCue]? {
        guard let data = try? await SubtitleAutoSync.download(url),
              let text = SubtitleTiming.decodeText(data),
              let format = SubtitleTiming.format(of: text) else { return nil }
        return SubtitleTiming.cues(in: text, format: format)
    }

    private func beginListening(_ run: AudioSyncRun, cues: [SubtitleTimingCue]?) {
        guard let cues else {
            stopAudioSync(reason: "Couldn't read the subtitle")
            return
        }
        run.lines = AudioSubtitleSync.intervals(of: cues)
        run.shown = AudioSubtitleSync.shown(cues)
        audioSyncStatus?.lines = run.lines.count
        guard run.lines.count >= 20 else {
            stopAudioSync(reason: "Only \(run.lines.count) dialogue lines")
            return
        }
        audioSyncStatus?.phase = .listening
        subscribeAudioSync(run)
        run.control = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, self.audioSyncRun === run else { return }
                await self.audioSyncTick(run)
            }
        }
    }

    private func subscribeAudioSync(_ run: AudioSyncRun) {
        if let id = run.subscription { sceneAudioTapBroker.unsubscribe(id: id) }
        run.consumer?.cancel()
        sceneAudioTapBroker.updateEngine(aetherController?.engine)
        let (id, stream) = sceneAudioTapBroker.subscribe()
        run.subscription = id
        run.subscribedAt = ProcessInfo.processInfo.systemUptime
        let listener = run.listener
        run.consumer = Task.detached(priority: .utility) {
            for await buffer in stream {
                if Task.isCancelled { break }
                await listener.take(buffer)
            }
        }
        if !sceneAudioTapBroker.hasDeliverySource {
            audioSyncStatus?.note = "No audio from the player yet"
        }
    }

    private var audioSyncClock: Double {
        aetherController?.sourceTimeSeconds ?? time.current
    }

    private func audioSyncTick(_ run: AudioSyncRun) async {
        if let reason = audioSyncStopReason(run) {
            stopAudioSync(reason: reason)
            return
        }
        applyPendingAudioShift(run)
        let now = ProcessInfo.processInfo.systemUptime

        // The tap ends with an audio-track switch or a reload: listen again.
        if now >= run.nextQuietCheckAt {
            run.nextQuietCheckAt = now + 2
            let last = await run.listener.lastBufferUptime
            guard audioSyncRun === run else { return }
            if status == .playing, now - max(last, run.subscribedAt) > 6 {
                subscribeAudioSync(run)
                audioSyncStatus?.note = "Audio stopped coming, listening again"
            }
        }

        guard now >= run.nextEstimateAt else { return }
        run.nextEstimateAt = now + (run.tracker.applied == nil ? AudioSubtitleSync.searchEvery : AudioSubtitleSync.followEvery)
        let reading = await run.listener.estimate(around: audioSyncClock, lines: run.lines)
        guard audioSyncRun === run else { return }
        audioSyncStatus?.heard = reading.heard
        guard let estimate = reading.estimate else {
            if run.tracker.applied == nil {
                audioSyncStatus?.note = String(format: "Listening: %.0f of %.0f s needed", reading.heard, AudioSubtitleSync.minHeard)
            }
            return
        }
        takeAudioEstimate(estimate, run: run)
    }

    private func audioSyncStopReason(_ run: AudioSyncRun) -> String? {
        if sessionCoordinator.loadGeneration != run.generation { return "New video" }
        if activeEngineKind != .aether { return "Engine switched to MPV" }
        if activeAddonSubtitle?.url != run.subtitleURL { return "Subtitle changed" }
        if let loadedURL = selectedAudioSyncExternalSubtitleURL, loadedURL != run.loadedURL {
            return "Subtitle timing switched"
        }
        if subtitleDelayMs != run.expectedDelayMs { return "Delay changed by hand" }
        return nil
    }

    private func takeAudioEstimate(_ estimate: AudioSyncEstimate, run: AudioSyncRun) {
        audioSyncStatus?.last = estimate
        audioSyncStatus?.estimates += 1
        if estimate.isSure, abs(estimate.shift) > AudioSubtitleSync.maxDelay {
            audioSyncStatus?.note = String(format: "Fits at %+.1f s, beyond the ±30 s delay", estimate.shift)
            return
        }
        switch run.tracker.take(estimate) {
        case .apply(let shift):
            run.pending = shift
            run.pendingSince = ProcessInfo.processInfo.systemUptime
            audioSyncStatus?.pending = shift
            audioSyncStatus?.note = nil
            applyPendingAudioShift(run)
        case .hold:
            if let doubt = estimate.doubt {
                audioSyncStatus?.note = "Not sure yet: " + doubt
            } else {
                audioSyncStatus?.note = String(format: "Seen %+.2f s once, checking again", estimate.shift)
            }
        case .keep:
            audioSyncStatus?.note = nil
        }
    }

    /// Changes the delay, the first time at once, after that when no line is on screen.
    private func applyPendingAudioShift(_ run: AudioSyncRun) {
        guard let shift = run.pending else { return }
        guard audioSyncStatus?.isOriginalTimingSelected != true else { return }
        let first = run.tracker.applied == nil
        let waited = ProcessInfo.processInfo.systemUptime - run.pendingSince
        let at = audioSyncClock
        guard first || waited >= AudioSubtitleSync.maxGapWait
                || AudioSyncGap.isClear(at: at, shown: run.shown, from: Double(subtitleDelayMs) / 1000, to: shift) else { return }
        let ms = min(max(Int((shift * 1000).rounded()), -30_000), 30_000)
        run.expectedDelayMs = ms
        run.pending = nil
        run.tracker.didApply(shift)
        setSubtitleDelayMs(ms)
        audioSyncStatus?.phase = .following
        audioSyncStatus?.applied = shift
        audioSyncStatus?.syncedDelayMs = ms
        audioSyncStatus?.isOriginalTimingSelected = false
        audioSyncStatus?.pending = nil
        audioSyncStatus?.changes.append(AudioSyncStatus.Change(at: at, shift: shift))
        if (audioSyncStatus?.changes.count ?? 0) > 8 { audioSyncStatus?.changes.removeFirst() }
        showPlayerToast(String(format: first ? "Synced by audio (%+.2f s)" : "Audio sync: %+.2f s", shift))
    }
}
