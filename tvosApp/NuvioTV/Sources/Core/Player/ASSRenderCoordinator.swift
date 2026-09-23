import Foundation
import Combine
import CoreText
import QuartzCore
import AetherEngine
import SwiftAssRenderer
import SwiftLibass

/// Bridges AetherEngine's raw ASS events to SwiftAssRenderer.
///
/// AetherEngine supplies the per-track ASS header (`TrackInfo.assHeader`, or
/// `sidecarASSHeader` for an external subtitle) and emits event lines when
/// `LoadOptions.preserveASSMarkup` is enabled.  The coordinator keeps the
/// renderer lifecycle on the main actor while writing embedded fonts off-main.
@MainActor
final class ASSRenderCoordinator {
    enum ReloadEvent {
        case began
        case finished(ProcessedImage?)
    }

    private(set) var renderer: AssSubtitlesRenderer?
    let reloadSignal = PassthroughSubject<ReloadEvent, Never>()
    var onRendererChanged: ((AssSubtitlesRenderer?) -> Void)?

    private let player: AetherEngine
    private var builder: ASSScriptBuilder?
    private var cancellables = Set<AnyCancellable>()
    private var generation = 0
    private var offered = Set<OfferKey>()
    private var pendingReload = false
    private var earliestPendingStart = Double.infinity
    private var lastSourceTime = 0.0
    private var lastSourceTimeWallClock = CACurrentMediaTime()
    private var lastReloadAt = Date.distantPast
    private var hasLoadedInitialTrack = false
    private var subtitleDelaySeconds = 0.0
    private var displayLink: CADisplayLink?
    private var isRendering = false
    private var pendingRender: (offset: TimeInterval, reloadRevision: Int?, isRequiredReloadRender: Bool)?
    private var scheduledReload: DispatchWorkItem?
    private var scheduledReloadDeadline: Date?
    private var reloadRevision = 0
    private var reloadInFlightRevision: Int?
    private var requiredReloadPasses = 0

    private struct OfferKey: Hashable {
        let id: Int
        let endTime: Double
    }

    init(player: AetherEngine) {
        self.player = player
    }

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelaySeconds = seconds
        let target = currentPlaybackTime() - seconds
        requestRender(at: target)
    }

    func canvasDidChange(for changedRenderer: AssSubtitlesRenderer) {
        guard let renderer, renderer === changedRenderer else { return }
        let revision: Int
        if let inFlight = reloadInFlightRevision {
            revision = inFlight
        } else {
            reloadRevision &+= 1
            revision = reloadRevision
            reloadInFlightRevision = revision
            reloadSignal.send(.began)
        }
        // If a frame was already queued before setCanvasSize's work, it may consume
        // one pass before the stale zero-offset frame is enqueued behind that work.
        requiredReloadPasses = max(requiredReloadPasses, isRendering ? 3 : 2)
        requestRender(
            at: currentPlaybackTime() - subtitleDelaySeconds,
            reloadRevision: revision,
            isRequiredReloadRender: true
        )
    }

    /// Pass `TrackInfo.assHeader` for an embedded track or `sidecarASSHeader`
    /// for a sidecar track. A missing header leaves the text overlay path active.
    func activate(header: String?, itemID: String) {
        deactivate()
        guard let header, !header.isEmpty else { return }

        generation += 1
        let currentGeneration = generation
        let fonts = player.fontAttachments
        let fontsDirectory = Self.fontsDirectory(itemID: itemID)
        builder = ASSScriptBuilder(header: header)

        if Self.allFontsPresent(fonts, in: fontsDirectory) {
            installRenderer(at: fontsDirectory, fonts: fonts)
            Self.registerFontsAsync(fonts: fonts, in: fontsDirectory)
        } else {
            Task.detached(priority: .userInitiated) { [weak self] in
                Self.write(fonts, to: fontsDirectory)
                Self.registerFontsAsync(fonts: fonts, in: fontsDirectory)
                await self?.installRendererIfCurrent(currentGeneration, at: fontsDirectory, fonts: fonts)
            }
        }

        player.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in self?.consume(cues) }
            .store(in: &cancellables)

        player.clock.$sourceTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sourceTime in
                guard let self else { return }
                if abs(sourceTime - self.lastSourceTime) > 1.0 {
                    // Seek or discontinuity: clear throttling so upcoming cues load immediately
                    self.lastReloadAt = .distantPast
                    self.pendingRender = nil
                }
                self.lastSourceTime = sourceTime
                self.lastSourceTimeWallClock = CACurrentMediaTime()
                self.flushIfDue()
                // When paused or seeking, CADisplayLink is inactive, so clock ticks update the frame
                if self.player.state != .playing {
                    self.requestRender(at: sourceTime - self.subtitleDelaySeconds)
                }
            }
            .store(in: &cancellables)

        player.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .playing {
                    self.startDisplayLink()
                } else {
                    self.stopDisplayLink()
                    let time = self.currentPlaybackTime() - self.subtitleDelaySeconds
                    self.requestRender(at: time)
                }
            }
            .store(in: &cancellables)
    }

    func deactivate() {
        stopDisplayLink()
        scheduledReload?.cancel()
        scheduledReload = nil
        scheduledReloadDeadline = nil
        generation += 1
        cancellables.removeAll()
        renderer = nil
        onRendererChanged?(nil)
        builder = nil
        offered.removeAll(keepingCapacity: false)
        pendingReload = false
        hasLoadedInitialTrack = false
        earliestPendingStart = .infinity
        lastReloadAt = .distantPast
        isRendering = false
        pendingRender = nil
        reloadRevision &+= 1
        reloadInFlightRevision = nil
        requiredReloadPasses = 0
    }

    private func installRenderer(at directory: URL, fonts: [FontAttachment]) {
        let renderer = AssSubtitlesRenderer(
            fontConfig: FontConfig(fontsPath: directory, fontProvider: .coreText),
            librarySetup: { library in
                ass_set_fonts_dir(library, directory.path)
                for font in fonts {
                    font.data.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return }
                        ass_add_font(
                            library,
                            font.filename,
                            base.assumingMemoryBound(to: CChar.self),
                            Int32(raw.count)
                        )
                    }
                }
            }
        )
        self.renderer = renderer
        onRendererChanged?(renderer)
        let initialTime = currentPlaybackTime() - subtitleDelaySeconds
        requestRender(at: initialTime)
        if player.state == .playing {
            startDisplayLink()
        }
        flushIfDue()
    }

    private func installRendererIfCurrent(_ generation: Int, at directory: URL, fonts: [FontAttachment]) {
        guard self.generation == generation else { return }
        installRenderer(at: directory, fonts: fonts)
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        guard player.state == .playing else { return }
        flushIfDue()
        let targetTime = currentPlaybackTime(targetTimestamp: link.targetTimestamp)
        requestRender(at: targetTime - subtitleDelaySeconds)
    }

    /// Evaluates the true presentation time of the playing media.
    /// When AVPlayer is playing, reads its exact hardware timebase directly,
    /// eliminating the 50-150ms quantization and queue delay of periodic observer hops.
    private func currentPlaybackTime(targetTimestamp: CFTimeInterval? = nil) -> Double {
        if let avPlayer = player.currentAVPlayer {
            let t = avPlayer.currentTime()
            if t.isValid && !t.isIndefinite && t.seconds.isFinite && t.seconds >= 0 {
                // The playlist shift is piecewise constant across producer seams. Use the
                // shift attached to this item-time position so buffered frames on either side
                // of a seam stay aligned with source-PTS subtitle cues.
                if let target = targetTimestamp, player.state == .playing {
                    // Compensate for display scanout lead (link.targetTimestamp is when
                    // the prepared frame will physically be scanned out by the display).
                    let rate = Double(avPlayer.rate)
                    let playbackRate = rate.isFinite ? max(0, rate) : 0
                    let lead = max(0, min(0.08, target - CACurrentMediaTime())) * playbackRate
                    let ledItemTime = t.seconds + lead
                    return player.presentationAxisMap.sourceSeconds(forItemSeconds: ledItemTime)
                        ?? (ledItemTime + player.playlistShiftSeconds)
                }
                return player.presentationAxisMap.sourceSeconds(forItemSeconds: t.seconds)
                    ?? (t.seconds + player.playlistShiftSeconds)
            }
        }
        let elapsed = CACurrentMediaTime() - lastSourceTimeWallClock
        var base = lastSourceTime + (elapsed >= 0 && elapsed < 0.5 ? elapsed : 0)
        if let target = targetTimestamp, player.state == .playing {
            let lead = max(0, min(0.08, target - CACurrentMediaTime()))
            base += lead
        }
        return base
    }

    /// Single-in-flight queue gating:
    /// Never allows more than 1 frame render task in `workQueue` at a time.
    /// Intermediate frames during heavy rendering are collapsed into `pendingRender`,
    /// completely preventing work queue backlog (which otherwise causes 200-500ms lag).
    private func requestRender(
        at offset: TimeInterval,
        reloadRevision: Int? = nil,
        isRequiredReloadRender: Bool = false
    ) {
        guard let renderer else { return }
        if isRendering {
            if let pendingRender {
                self.pendingRender = (
                    offset,
                    reloadRevision ?? pendingRender.reloadRevision,
                    pendingRender.isRequiredReloadRender || isRequiredReloadRender
                )
            } else if isRequiredReloadRender {
                self.pendingRender = (offset, reloadRevision, true)
            } else {
                self.pendingRender = (offset, nil, false)
            }
            return
        }

        isRendering = true
        pendingRender = nil
        let captureGeneration = generation
        renderer.loadFrame(offset: offset) { [weak self] image in
            DispatchQueue.main.async {
                guard let self, self.generation == captureGeneration else { return }
                if isRequiredReloadRender, let reloadRevision,
                   self.reloadInFlightRevision == reloadRevision {
                    self.requiredReloadPasses = max(0, self.requiredReloadPasses - 1)
                    if self.requiredReloadPasses > 0 {
                        self.pendingRender = (
                            self.currentPlaybackTime() - self.subtitleDelaySeconds,
                            reloadRevision,
                            true
                        )
                    }
                }
                let hasPendingReloadRender = reloadRevision != nil
                    && self.pendingRender?.reloadRevision == reloadRevision
                    && self.pendingRender?.isRequiredReloadRender == true
                if let reloadRevision,
                   self.reloadInFlightRevision == reloadRevision,
                   self.requiredReloadPasses == 0,
                   !hasPendingReloadRender {
                    self.reloadInFlightRevision = nil
                    self.reloadSignal.send(.finished(image))
                }
                self.isRendering = false
                if let next = self.pendingRender {
                    self.pendingRender = nil
                    self.requestRender(
                        at: next.offset,
                        reloadRevision: next.reloadRevision,
                        isRequiredReloadRender: next.isRequiredReloadRender
                    )
                }
                self.flushIfDue()
            }
        }
    }

    private func consume(_ cues: [SubtitleCue]) {
        guard let builder else { return }
        var added = false
        for cue in cues {
            guard case .text(let raw) = cue.body,
                  offered.insert(OfferKey(id: cue.id, endTime: cue.endTime)).inserted else { continue }
            if builder.add(rawEventText: raw, start: cue.startTime, end: cue.endTime) {
                added = true
                earliestPendingStart = min(earliestPendingStart, cue.startTime)
            }
        }
        if added { pendingReload = true }
        flushIfDue()
    }

    private func flushIfDue() {
        guard pendingReload, let builder, let renderer else { return }
        guard reloadInFlightRevision == nil else { return }
        let elapsed = Date().timeIntervalSince(lastReloadAt)
        if !hasLoadedInitialTrack {
            // First batch of cues: load immediately so subtitles appear without delay
            lastReloadAt = Date()
            hasLoadedInitialTrack = true
            pendingReload = false
            earliestPendingStart = .infinity
            beginReload(renderer: renderer, content: builder.script())
            return
        }

        // Batch background cue arrivals at 2 Hz and urgent arrivals at 10 Hz. This avoids
        // multi-second entry delays without letting full-track reparses flood the renderer.
        let sourceTime = currentPlaybackTime() - subtitleDelaySeconds
        let isImminent = earliestPendingStart <= sourceTime + 1.0
        let minInterval: TimeInterval = isImminent ? 0.1 : 0.5
        guard elapsed >= minInterval else {
            let deadline = Date().addingTimeInterval(minInterval - elapsed)
            if let scheduledReloadDeadline, scheduledReloadDeadline <= deadline { return }
            scheduledReload?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.scheduledReload = nil
                self.scheduledReloadDeadline = nil
                self.flushIfDue()
            }
            scheduledReloadDeadline = deadline
            scheduledReload = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, minInterval - elapsed), execute: work)
            return
        }

        scheduledReload?.cancel()
        scheduledReload = nil
        lastReloadAt = Date()
        pendingReload = false
        earliestPendingStart = .infinity
        beginReload(renderer: renderer, content: builder.script())
    }

    private func beginReload(renderer: AssSubtitlesRenderer, content: String) {
        scheduledReloadDeadline = nil
        reloadRevision &+= 1
        let revision = reloadRevision
        reloadInFlightRevision = revision
        requiredReloadPasses = 1
        reloadSignal.send(.began)
        renderer.loadTrack(content: content)
        let time = currentPlaybackTime() - subtitleDelaySeconds
        requestRender(at: time, reloadRevision: revision, isRequiredReloadRender: true)
    }

    private static func fontsDirectory(itemID: String) -> URL {
        let component = (itemID as NSString).lastPathComponent
        let safeID = component.isEmpty || component == ".." ? "item" : component
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ass-fonts", isDirectory: true)
            .appendingPathComponent(safeID, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private nonisolated static func allFontsPresent(_ fonts: [FontAttachment], in directory: URL) -> Bool {
        fonts.allSatisfy { font in
            let name = (font.filename as NSString).lastPathComponent
            return name.isEmpty || FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    private nonisolated static func write(_ fonts: [FontAttachment], to directory: URL) {
        for font in fonts {
            let name = (font.filename as NSString).lastPathComponent
            guard !name.isEmpty else { continue }
            let destination = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try? font.data.write(to: destination, options: .atomic)
            }
        }
    }

    private nonisolated(unsafe) static let registeredFontsLock = NSLock()
    private nonisolated(unsafe) static var registeredFontNames = Set<String>()

    private nonisolated static func registerFontsAsync(fonts: [FontAttachment], in directory: URL) {
        Task.detached(priority: .utility) {
            for font in fonts {
                let name = (font.filename as NSString).lastPathComponent
                guard !name.isEmpty, !font.data.isEmpty else { continue }
                let shouldRegister: Bool = registeredFontsLock.withLock {
                    if registeredFontNames.contains(name) { return false }
                    registeredFontNames.insert(name)
                    return true
                }
                guard shouldRegister else { continue }
                if let provider = CGDataProvider(data: font.data as CFData),
                   let cgFont = CGFont(provider) {
                    var error: Unmanaged<CFError>?
                    _ = CTFontManagerRegisterGraphicsFont(cgFont, &error)
                }
            }

            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for file in files {
                let ext = file.pathExtension.lowercased()
                guard ext == "ttf" || ext == "otf" || ext == "ttc" || ext == "woff" else { continue }
                let filename = file.lastPathComponent
                let shouldRegister: Bool = registeredFontsLock.withLock {
                    if registeredFontNames.contains(filename) { return false }
                    registeredFontNames.insert(filename)
                    return true
                }
                guard shouldRegister else { continue }
                var error: Unmanaged<CFError>?
                CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error)
            }
        }
    }
}
