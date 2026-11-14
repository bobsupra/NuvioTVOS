import Foundation
import CoreGraphics
import AVFoundation

extension AetherEngine {
    /// One frame and its capture-time provenance for analysis surfaces.
    public struct VideoFrameAnalysisCapture: @unchecked Sendable {
        public let image: CGImage?
        /// The engine's requested source timestamp sampled before any asynchronous capture/decode.
        public let sourceTime: Double
        /// Immutable route, source format/profile, target, result reason, and per-frame metadata.
        public let diagnostics: String

        public init(image: CGImage?, sourceTime: Double, diagnostics: String) {
            self.image = image
            self.sourceTime = sourceTime
            self.diagnostics = diagnostics
        }
    }
}

/// Thread-safe mirror of the active session's starvation inputs for extractor yield closures,
/// which run on the extractor's decode queue off the main actor. MainActor writes (load / stop /
/// telemetry tick), off-main reads. The session reference stays weak so a dangling extractor
/// from a previous session can never gate or retain a torn-down pipeline.
final class ExtractorYieldState: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _session: HLSVideoEngine?
    /// Consecutive 1 Hz ticks with a healthy (>= floor) forward buffer; any thin or unknown
    /// tick resets the run. Hysteresis against post-load buffer spikes (#93 startup).
    private var _consecutiveHealthyTicks = 0

    func activate(session: HLSVideoEngine) {
        lock.lock()
        _session = session
        _consecutiveHealthyTicks = 0
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        _session = nil
        _consecutiveHealthyTicks = 0
        lock.unlock()
    }

    func setForwardBuffer(_ seconds: Double?) {
        lock.lock()
        if let seconds, seconds >= FrameExtractor.yieldMinForwardBufferSeconds {
            _consecutiveHealthyTicks += 1
        } else {
            _consecutiveHealthyTicks = 0
        }
        lock.unlock()
    }

    /// Session returned outside the lock so its own lock-guarded accessors are never
    /// nested under this one.
    func snapshot() -> (session: HLSVideoEngine?, consecutiveHealthyTicks: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_session, _consecutiveHealthyTicks)
    }
}

extension AetherEngine {
    /// Vends a `FrameExtractor` for the currently loaded source, or nil if nothing
    /// loaded. URL sources use URL + HTTP headers; custom IOReader sources use an
    /// independent reader clone (nil when the reader is forward-only / one-shot).
    /// Caller owns the extractor's lifecycle (engine does not retain it); call
    /// shutdown() for prompt teardown, else the idle-close timer cleans up.
    /// Session-coupled: elective thumbnail decodes yield while the playback pipeline
    /// is starved (#93 startup). For arbitrary items with no active session (Recents),
    /// construct FrameExtractor(url:httpHeaders:) directly.
    public func makeFrameExtractor() -> FrameExtractor? {
        if isCustomSource {
            // Scrub preview runs a second demuxer concurrently with playback, so it
            // needs an independent reader; nil (scrub skipped) if the source can't clone.
            guard let clone = customReader?.makeIndependentReader() else { return nil }
            return FrameExtractor(reader: clone, formatHint: customFormatHint,
                                  yieldWhile: sessionYieldSignal())
        }
        guard let url = loadedURL else { return nil }
        // For a disc image, pin the extractor to the currently-selected title so stills follow the
        // title switch instead of always decoding the default one (AE#105). The host rebuilds the
        // extractor when the disc title changes.
        return FrameExtractor(url: url, requestHeaderStore: sessionRequestHeaders,
                              selectTitleID: activeDiscTitleID,
                              discImageHint: loadedOptions.discImageHint,
                              yieldWhile: sessionYieldSignal())
    }

    /// Session-coupled extractor over a HOST-chosen URL: stills often come from the original
    /// file even while playback runs a different representation (e.g. a transcode), so the
    /// extraction URL cannot be derived from the loaded one. The yield coupling is the same
    /// as `makeFrameExtractor()`: the extractor's link traffic defers to a starved pipeline.
    public func makeFrameExtractor(url: URL, httpHeaders: [String: String] = [:]) -> FrameExtractor {
        FrameExtractor(url: url, httpHeaders: httpHeaders, yieldWhile: sessionYieldSignal())
    }

    /// Starvation signal for session-coupled extractors. Reads live state at call time (the
    /// host may build the extractor before the session finishes wiring); no active native
    /// session means no gate.
    private func sessionYieldSignal() -> (@Sendable () -> Bool) {
        let state = extractorYieldState
        return {
            let snap = state.snapshot()
            guard let session = snap.session else { return false }
            return FrameExtractor.shouldYield(
                restartInFlight: session.restartInFlight,
                consecutiveHealthyTicks: snap.consecutiveHealthyTicks
            )
        }
    }

    /// Thread-safe playback-priority gate for an external scene-analysis extractor. It uses the same
    /// weak session snapshot and starvation hysteresis as the engine's own still extractors.
    /// A yield stays latched for this request, even if playback recovers during decoder teardown.
    public func frameAnalysisYieldSignal() -> @Sendable () -> Bool {
        let sourceShouldYield = sessionYieldSignal()
        let observedYield = ProbeCancellation()
        return {
            if sourceShouldYield() { observedYield.cancel() }
            return observedYield.isCancelled
        }
    }

    /// Captures the currently displayed video frame directly from the active playback pipeline.
    /// Operates directly on the decoded CVPixelBuffer in presentation memory.
    ///
    /// Guarantees:
    /// - 0 additional HTTP range requests
    /// - 0 secondary demuxers
    /// - 0 secondary video decoders
    public func captureCurrentVideoFrame(maxWidth: Int = 320) -> CGImage? {
        if let softwareHost {
            return softwareHost.captureCurrentFrame(maxWidth: maxWidth)
        }
        if let nativeHost {
            return nativeHost.captureCurrentFrame(maxWidth: maxWidth)
        }
        return nil
    }

    /// Captures a frame and records the source timestamp and exact conversion path used.
    /// Native P5/P10 sources are decoded only from the currently resident segment and reshaped
    /// through their RPU; a cache miss never falls back to AVPlayer's IPT-PQ base-layer output.
    public func captureVideoFrameForAnalysis(maxWidth: Int = 960) async -> VideoFrameAnalysisCapture {
        let generation = loadGeneration
        let requestedSourceTime = sourceTime
        let sourceFormat = sourceVideoFormat
        let sourceProfile = sourceDVProfile
        let sourceCompatibilityID = sourceDVBLCompatID
        let effectiveFormat = effectiveVideoFormat
        let native = nativeHost
        let software = softwareHost
        let session = nativeVideoSession
        let nativeSessionID = native?.sessionID
        let width = min(960, max(1, maxWidth))
        let route = Self.videoFrameAnalysisRoute(
            sourceVideoFormat: sourceFormat,
            sourceDVProfile: sourceProfile,
            sourceDVBLCompatID: sourceCompatibilityID,
            effectiveVideoFormat: effectiveFormat,
            hasSoftwareHost: software != nil)

        func result(image: CGImage? = nil, reason: String, detail: String? = nil,
                    sourceTime resultSourceTime: Double? = nil) -> VideoFrameAnalysisCapture {
            let profile = sourceProfile.map(String.init) ?? "none"
            let compatibilityID = sourceCompatibilityID.map(String.init) ?? "none"
            let capturedTime = resultSourceTime ?? requestedSourceTime
            let target = String(format: "%.3f", capturedTime)
            let suffix = detail.map { " \($0)" } ?? ""
            return VideoFrameAnalysisCapture(
                image: image,
                sourceTime: capturedTime,
                diagnostics: "route=\(route) sourceFormat=\(sourceFormat) sourceDVProfile=\(profile) "
                    + "sourceDVBLCompatID=\(compatibilityID) effectiveFormat=\(effectiveFormat) "
                    + "loadGeneration=\(generation) targetTime=\(target) "
                    + "reason=\(reason)\(suffix)")
        }

        func requestIsCurrent() -> Bool {
            !Task.isCancelled
                && loadGeneration == generation
                && nativeHost === native
                && softwareHost === software
                && nativeVideoSession === session
                && native?.sessionID == nativeSessionID
        }

        guard !Task.isCancelled else { return result(reason: "cancelled-before-capture") }

        if let software {
            let image = software.captureCurrentFrame(maxWidth: width)
            guard requestIsCurrent() else { return result(reason: "cancelled-or-superseded") }
            return result(image: image, reason: image == nil ? "software-frame-unavailable" : "ok")
        }

        guard let native else { return result(reason: "native-host-unavailable") }
        if route == "resident-dovi-rpu" {
            guard OptionalComponent.dolbyVisionStillReshaping.isBuiltIn else {
                return result(reason: "dv-reshaping-unavailable")
            }
            guard !isLive else { return result(reason: "live-resident-segment-unsupported") }
            if sourceVideoWidth > 1920 || sourceVideoHeight > 1080 {
                return result(reason: "software-4k-dv-unsupported")
            }
            guard let session else { return result(reason: "native-session-unavailable") }
            let itemSeconds = native.avPlayer.currentTime().seconds
            guard itemSeconds.isFinite else { return result(reason: "native-item-time-unavailable") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            let shouldYield = frameAnalysisYieldSignal()
            guard !shouldYield() else { return result(reason: "playback-priority-yield") }

            let source = await BlockingWork.detached(priority: .userInitiated) { [session] in
                session.scrubThumbnailSource(atSeconds: itemSeconds)
            }.value
            guard requestIsCurrent() else { return result(reason: "cancelled-or-superseded") }
            guard let source else { return result(reason: "resident-segment-cache-miss") }
            guard !shouldYield() else {
                return result(reason: "playback-priority-yield", detail: "segment=\(source.segmentIndex)")
            }

            let reader = await BlockingWork.detached(priority: .userInitiated) { [source] in
                source.makeReader()
            }.value
            guard let reader else {
                return result(reason: "resident-segment-read-failed", detail: "segment=\(source.segmentIndex)")
            }
            guard requestIsCurrent() else {
                reader.close()
                return result(reason: "cancelled-or-superseded")
            }
            guard !shouldYield() else {
                reader.close()
                return result(reason: "playback-priority-yield", detail: "segment=\(source.segmentIndex)")
            }

            let firstFrameOffset = max(0, itemSeconds - source.startSeconds)
            guard firstFrameOffset.isFinite else {
                reader.close()
                return result(reason: "resident-segment-offset-invalid")
            }
            let remaining = Self.seconds(until: deadline)
            guard remaining > 0 else {
                reader.close()
                return result(reason: "resident-decode-budget-expired")
            }
            let limits = ProbeLimits(
                maxInputBytes: 64 * 1_024 * 1_024,
                maxPackets: 4_096,
                maxPacketBytes: 16 * 1_024 * 1_024,
                timeBudget: remaining)
            let extractor = FrameExtractor(reader: reader, formatHint: "mp4",
                                           allowsHardwareDecode: false, yieldWhile: shouldYield)
            let cancellation = ProbeCancellation()
            let still = await extractor.boundedSnapshot(
                at: 0,
                maxSize: CGSize(width: width, height: width),
                limits: limits,
                cancellation: cancellation,
                firstFrameOffset: firstFrameOffset,
                requiredDolbyVisionReshaping: true)
            await extractor.shutdown()
            guard requestIsCurrent() else { return result(reason: "cancelled-or-superseded") }
            let yieldedAfterDecode = shouldYield()
            guard let still else {
                let reason = Task.isCancelled
                    ? "cancelled"
                    : yieldedAfterDecode ? "playback-priority-yield" : "resident-dv-decode-failed-or-budget-expired"
                return result(reason: reason,
                              detail: "segment=\(source.segmentIndex) firstFrameOffset=\(String(format: "%.3f", firstFrameOffset))")
            }
            guard !yieldedAfterDecode else {
                return result(reason: "playback-priority-yield",
                              detail: "segment=\(source.segmentIndex) firstFrameOffset=\(String(format: "%.3f", firstFrameOffset))")
            }
            return result(
                image: still.image,
                reason: "ok",
                detail: "segment=\(source.segmentIndex) firstFrameOffset=\(String(format: "%.3f", firstFrameOffset)) "
                    + "decodedPTS=\(still.actualSeconds.map { String(format: "%.3f", $0) } ?? "unknown")")
        }

        if sourceVideoFormat == .dolbyVision,
           !NativeVideoOutputPolicy.allowsNativeVideoOutput(
               sourceVideoFormat: sourceVideoFormat,
               dolbyVisionProfile: sourceDVProfile,
               baseLayerCompatibilityID: sourceDVBLCompatID
           ) {
            // Keep native output off DV5, unknown DV profiles, and DV10 without a compatible
            // base layer; the resident RPU path remains available for those sources.
            return result(reason: "dv-native-output-unsupported")
        }

        let pixelBuffer = await native.captureDisplayedFrame()
        guard requestIsCurrent() else { return result(reason: "cancelled-or-superseded") }
        guard let pixelBuffer else { return result(reason: "native-output-frame-unavailable") }
        var frameMetadata: String?
        let image = native.renderThumbnail(from: pixelBuffer, maxWidth: width, diagnosticsCreated: {
            frameMetadata = $0
        })
        let capturedSourceTime = sourceTime
        guard requestIsCurrent() else { return result(reason: "cancelled-or-superseded") }
        return result(image: image,
                      reason: image == nil ? "native-thumbnail-render-failed" : "ok",
                      detail: frameMetadata,
                      sourceTime: capturedSourceTime)
    }

    /// Compatibility wrapper for callers that only need the image.
    public func captureCurrentVideoFrameOnDemand(maxWidth: Int = 320) async -> CGImage? {
        await captureVideoFrameForAnalysis(maxWidth: maxWidth).image
    }

    nonisolated static func videoFrameAnalysisRoute(
        sourceVideoFormat: VideoFormat,
        sourceDVProfile: Int?,
        sourceDVBLCompatID: Int?,
        effectiveVideoFormat _: VideoFormat,
        hasSoftwareHost: Bool
    ) -> String {
        if hasSoftwareHost { return "software" }
        if sourceVideoFormat == .dolbyVision,
           !NativeVideoOutputPolicy.allowsNativeVideoOutput(
               sourceVideoFormat: sourceVideoFormat,
               dolbyVisionProfile: sourceDVProfile,
               baseLayerCompatibilityID: sourceDVBLCompatID
           ) {
            return "resident-dovi-rpu"
        }
        return "native-output"
    }

    private nonisolated static func seconds(until deadline: ContinuousClock.Instant) -> Double {
        let components = ContinuousClock.now.duration(to: deadline).components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
