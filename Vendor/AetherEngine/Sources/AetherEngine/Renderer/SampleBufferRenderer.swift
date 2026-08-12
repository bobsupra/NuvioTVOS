import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

/// Video renderer using AVSampleBufferDisplayLayer for optimal frame pacing.
///
/// Includes a small reorder buffer (4 frames) to handle B-frame decode
/// order from VTDecompressionSession. Frames are sorted by PTS before
/// being enqueued to the display layer in strict presentation order.
/// Which display-layer flush operation a flush request maps to. Split out of SampleBufferRenderer.flush()
/// as a pure value so the seek-holds-frame contract (issue #90) is testable without a live
/// AVSampleBufferDisplayLayer.
enum DisplayFlushOp: Equatable {
    /// tvOS 18+/iOS 18+/macOS 15+: AVSampleBufferVideoRenderer.flush(removingDisplayedImage:).
    case rendererFlush(removingDisplayedImage: Bool)
    /// Legacy AVSampleBufferDisplayLayer.flushAndRemoveImage(), clears the visible frame.
    case removeImage
    /// Legacy AVSampleBufferDisplayLayer.flush(), keeps the last frame on screen (hold through seek).
    case holdImage

    static func resolve(removingDisplayedImage: Bool, modernRenderer: Bool) -> DisplayFlushOp {
        if modernRenderer {
            return .rendererFlush(removingDisplayedImage: removingDisplayedImage)
        }
        return removingDisplayedImage ? .removeImage : .holdImage
    }
}

final class SampleBufferRenderer: @unchecked Sendable {

    @MainActor private(set) var displayLayer: AVSampleBufferDisplayLayer
    /// AVFoundation permits this queue interface to be used from a background thread.
    /// Capture it once on the main actor instead of reaching through the actor-isolated layer
    /// for every decoded frame.
    private let renderingTarget: any AVQueuedSampleBufferRendering

    /// SW-PiP Phase C: composites active subtitle cues into frames while PiP is active (the system
    /// window renders only this layer, the host overlay cannot reach it).
    let subtitleCompositor = SubtitleFrameCompositor()

    /// B-frame reorder buffer (4 frames): collects decoder output, flushes to display layer in ascending PTS order. Third tuple slot carries per-frame HDR10+ T.35 SEI bytes, paired through the reorder to kCMSampleAttachmentKey_HDR10PlusPerFrameData.
    private let reorderLock = NSLock()
    private var reorderBuffer: [(CVPixelBuffer, CMTime, Data?)] = []
    private let reorderDepth = 4  // handles up to 3 consecutive B-frames

    /// Drop frames before this PTS after a seek (prevents keyframe-to-target fast-forward). Cleared after the first passing frame.
    private var skipUntilPTS: CMTime?

    /// #311: fires for every frame handed to the queue target, on the decode thread. Guarded by
    /// `reorderLock` for the swap only; the call itself happens with no lock held, so a host that
    /// re-enters the renderer from it cannot deadlock.
    private var _frameEnqueuedObserver: SoftwareVideoFrameTimeObserver?
    func setFrameEnqueuedObserver(_ observer: SoftwareVideoFrameTimeObserver?) {
        reorderLock.lock()
        _frameEnqueuedObserver = observer
        reorderLock.unlock()
    }

    /// #311: moved on by every flush, so a consumer can drop the frame times it recorded for frames the
    /// compositor has since discarded. Guarded by `reorderLock`.
    ///
    /// Drawn from a process-wide allocator rather than counted from zero (#314). A load builds a new
    /// renderer, and a renderer that started at zero would report below the outgoing one, which is the
    /// order a consumer reads as "stale". The first value is drawn at init for the same reason: the
    /// generation a renderer reports before its first flush has to rank above the previous renderer's
    /// last, not tie with it. Successive values are therefore strictly increasing but not consecutive.
    private static let flushGenerations = FrameTimeSequence()
    private var _flushGeneration: UInt64 = SampleBufferRenderer.flushGenerations.next()
    var flushGeneration: UInt64 {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _flushGeneration
    }

    /// Cached CMVideoFormatDescription keyed by dimensions + pixel format + colorimetry + pixel aspect ratio. CMVideoFormatDescriptionCreateForImageBuffer snapshots color AND aspect attachments at creation, so a mid-stream change at same dimensions must invalidate the cache; a PAR-less first frame froze a PAR-less description for the whole stream and collapsed anamorphic content to coded dimensions (#177). Guarded by reorderLock; nil'd by flush().
    private var cachedFormatDesc: CMVideoFormatDescription?
    private var cachedFormatKey: FormatDescriptionKey?

    /// Cache key for cachedFormatDesc. Colorimetry fields are Strings (not CF references) so the struct stays Equatable without CF identity traps.
    struct FormatDescriptionKey: Equatable {
        var width: Int
        var height: Int
        var pixelFormat: OSType
        var primaries: String?
        var transfer: String?
        var matrix: String?
        var parH: Int?
        var parV: Int?
    }

    private let diagnosticsLock = NSLock()
    private var diagnosticsRefreshPending = false
    private var loggedLayerFailed = false
    private var cachedQueueStatusName = "unknown"
    private var cachedQueueErrorDescription: String?
    private var loggedNotReady = false
    /// Internal (not private) for #298 tests: the gate's job is that untimed frames never get here.
    private(set) var enqueueCount = 0
    private var hdr10PlusAttachedCount = 0

    /// #298: frames refused at the enqueue gate for carrying an unschedulable PTS. Guarded by `reorderLock`.
    private var _untimedFramesDropped = 0
    var untimedFramesDropped: Int {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _untimedFramesDropped
    }

    /// #303: newest presentation timestamp this renderer has admitted, in seconds on the source
    /// axis, nil before the first frame. Recorded at admission into the reorder buffer, so it is
    /// past the unschedulable-PTS gate and the post-seek skip: everything counted here is decoded
    /// and will be displayed. Its lead over the synchronizer is the cushion an IO hiccup eats into.
    /// Guarded by `reorderLock`.
    private var _newestEnqueuedPtsSeconds: Double?
    var newestEnqueuedPtsSeconds: Double? {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _newestEnqueuedPtsSeconds
    }

    /// #353: the size the picture presents at, which is the coded frame under the pixel aspect ratio
    /// the decoder attached; nil before the first sample buffer is built. Read off the description
    /// that is enqueued rather than recomputed from the SAR: the ratio is resolved per frame across
    /// three sources (#177) and a ratio whose display aspect is impossible is dropped (#290), so a
    /// second computation of the same answer is a second thing that can disagree with the screen.
    /// Guarded by `reorderLock`.
    private var _displaySize: CGSize?
    var displaySize: CGSize? {
        reorderLock.lock()
        defer { reorderLock.unlock() }
        return _displaySize
    }

    /// #353: fires when the settled display size CHANGES, on the decode thread, plus once on
    /// installation if the picture already settled. Compared against the value and not against the
    /// description, because `flush()` drops the cached description and every seek therefore rebuilds
    /// one for a picture that never changed shape. The late-installation call is what a host relies
    /// on: on a source with one format, the only report ever due has already happened.
    private var _displaySizeObserver: (@Sendable (CGSize) -> Void)?
    func setDisplaySizeObserver(_ observer: (@Sendable (CGSize) -> Void)?) {
        reorderLock.lock()
        _displaySizeObserver = observer
        let settled = _displaySize
        reorderLock.unlock()
        if let settled { observer?(settled) }
    }

    @MainActor
    init() {
        let layer = Self.makeDisplayLayer(isHDR: false)
        displayLayer = layer
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            renderingTarget = layer.sampleBufferRenderer
        } else {
            renderingTarget = layer
        }
    }

    /// #303: what the display did with the frames, as the renderer itself counts them. Our own
    /// counters can only see what we refuse; `numberOfDroppedFrames` also covers frames dropped for
    /// missing their display deadline, which is the class that shows up as a stutter.
    struct RenderMetrics: Sendable {
        let total: Int
        let dropped: Int
        let corrupted: Int
        let accumulatedDelay: TimeInterval
    }

    /// nil where the metrics cannot be asked for: an OS predating the API, or the pre-tvOS-18 path
    /// where the queue target is the display layer itself rather than an `AVSampleBufferVideoRenderer`.
    ///
    /// #313: main-actor isolated, and reading through the completion-handler accessor rather than
    /// the async one, because the two halves of that constraint come from different toolchains and
    /// no single `await` on `videoPerformanceMetrics` satisfies both. An SDK that isolates the layer
    /// to the main actor refuses to hand `sampleBufferRenderer` to any other domain; a toolchain
    /// that imports the async accessor as `nonisolated` refuses to take that non-Sendable renderer
    /// from the main actor. The completion form suspends without moving the renderer anywhere, so it
    /// holds on both. Every caller is main-actor isolated already, so the annotation costs no hop.
    ///
    /// #344: the version list gates the metrics accessor (tvOS/iOS 17.4, macOS 14.4, visionOS 1.1),
    /// not the renderer, which exists from visionOS 1.0. tvOS/iOS 18 and macOS 15 stay as they are:
    /// below them `queueTarget` is the display layer, so there is no renderer to ask.
    @MainActor
    func loadRenderMetrics() async -> RenderMetrics? {
        guard #available(tvOS 18.0, iOS 18.0, macOS 15.0, visionOS 1.1, *) else { return nil }
        let renderer = displayLayer.sampleBufferRenderer
        return await withCheckedContinuation { (cont: CheckedContinuation<RenderMetrics?, Never>) in
            renderer.loadVideoPerformanceMetrics { m in
                guard let m else { return cont.resume(returning: nil) }
                cont.resume(returning: RenderMetrics(total: m.totalNumberOfFrames,
                                                     dropped: m.numberOfDroppedFrames,
                                                     corrupted: m.numberOfCorruptedFrames,
                                                     accumulatedDelay: m.totalAccumulatedFrameDelay))
            }
        }
    }

    // MARK: - Queue rendering target

    /// tvOS 18+ / iOS 18+ / macOS 15+: use AVSampleBufferVideoRenderer via displayLayer.sampleBufferRenderer. Calling the deprecated layer enqueue/flush/isReadyForMoreMediaData on tvOS 26+ with AVSampleBufferRenderSynchronizer fails with FigVideoQueueRemote -12080 after the first enqueue. Older OSes use the layer directly via AVQueuedSampleBufferRendering. visionOS is not named because it has the renderer from 1.0, which is the package floor, so the `*` arm is the renderer arm there and naming it would be a check that is always true.
    var queueTarget: any AVQueuedSampleBufferRendering {
        renderingTarget
    }

    /// Demux-loop back-pressure gate. Post-tvOS 18 split: reading the layer's own isReadyForMoreMediaData stays optimistically true even when the sampleBufferRenderer queue is full, causing FigVideoQueueRemote -12080 on over-enqueue.
    var isReadyForMoreMediaData: Bool {
        queueTarget.isReadyForMoreMediaData
    }

    @MainActor
    private static func makeDisplayLayer(isHDR: Bool, gravity: AVLayerVideoGravity = .resizeAspect) -> AVSampleBufferDisplayLayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = gravity
        // Unavailable on visionOS, which has no display-sleep timer to hold off: the wearer's
        // displays follow presence, not an idle timer.
        #if !os(visionOS)
        layer.preventsDisplaySleepDuringVideoPlayback = true
        #endif
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            layer.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            if #available(iOS 17.0, macOS 14.0, *) {
                layer.wantsExtendedDynamicRangeContent = isHDR
            }
            #endif
        }
        return layer
    }

    /// Opt the display layer into HDR mode. Pass true only when the decoder delivers raw HDR10/DV pixel buffers; false for SDR or tone-mapped output.
    @MainActor
    func setHDROutput(_ isHDR: Bool) {
        if #available(tvOS 26.0, iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            displayLayer.preferredDynamicRange = isHDR ? .high : .standard
        } else {
            #if os(iOS) || os(macOS)
            if #available(iOS 17.0, macOS 14.0, *) {
                displayLayer.wantsExtendedDynamicRangeContent = isHDR
            }
            #endif
        }
    }

    func setSkipThreshold(_ time: CMTime?) {
        reorderLock.lock()
        skipUntilPTS = time
        reorderLock.unlock()
    }

    /// #298: whether a frame's presentation timestamp can be scheduled at all. AV_NOPTS_VALUE reaches
    /// the decoder callback as `CMTime.invalid`, and CoreMedia builds a sample buffer from it without
    /// complaint (`CMSampleBufferCreateReadyWithImageBuffer` returns noErr, the sample's PTS reads back
    /// as NaN seconds), so the display queue is the first place it can do damage: the render
    /// synchronizer cannot pace an untimed sample. The deinterlace path already drops its untimestamped
    /// output for exactly this reason (see `SoftwareVideoDecoder.drainDecodedFrames`); this is the same
    /// rule one layer lower, so no producer can put an unschedulable sample in the queue.
    static func isSchedulable(_ pts: CMTime) -> Bool { pts.isNumeric }

    /// Enqueue a decoded frame through the B-frame reorder buffer. `hdr10PlusData` carries per-frame ST 2094-40 metadata serialised to T.35 SEI format for kCMSampleAttachmentKey_HDR10PlusPerFrameData.
    func enqueue(pixelBuffer: CVPixelBuffer, pts: CMTime, hdr10PlusData: Data? = nil) {
        reorderLock.lock()

        // Refused before the reorder buffer, not at flush: `CMTimeGetSeconds(.invalid)` is NaN and
        // every comparison against NaN is false, so an untimed frame lands past frames it should
        // precede and reorders its neighbours on the way out.
        guard Self.isSchedulable(pts) else {
            _untimedFramesDropped += 1
            let dropped = _untimedFramesDropped
            reorderLock.unlock()
            if dropped == 1 || dropped % 250 == 0 {
                EngineLog.emit("[Renderer] dropped \(dropped) frame(s) with no usable timestamp (unschedulable)",
                               category: .swPlayback)
            }
            return
        }

        if let threshold = skipUntilPTS {
            if CMTimeCompare(pts, threshold) < 0 {
                reorderLock.unlock()
                return
            }
            skipUntilPTS = nil
        }

        let ptsSeconds = CMTimeGetSeconds(pts)
        // #303: the frontier is the newest timestamp HELD, not the newest handed over. A B-frame run
        // arrives out of order, so taking the last call's timestamp would report a cushion that
        // shrinks and grows with the coding pattern rather than with the buffer.
        if ptsSeconds > (_newestEnqueuedPtsSeconds ?? -.greatestFiniteMagnitude) {
            _newestEnqueuedPtsSeconds = ptsSeconds
        }
        let insertIdx = reorderBuffer.firstIndex(where: {
            CMTimeGetSeconds($0.1) > ptsSeconds
        }) ?? reorderBuffer.endIndex
        reorderBuffer.insert((pixelBuffer, pts, hdr10PlusData), at: insertIdx)

        while reorderBuffer.count > reorderDepth {
            let (pb, t, hdr) = reorderBuffer.removeFirst()
            reorderLock.unlock()
            flushFrame(pixelBuffer: pb, pts: t, hdr10PlusData: hdr)
            reorderLock.lock()
        }

        reorderLock.unlock()
    }

    /// Discard all buffered frames. `removingDisplayedImage: true` (stop/teardown) also clears the visible
    /// frame; `false` (seek) holds the last frame on screen until the post-seek frame is enqueued, so a seek
    /// doesn't flash black between the old and new positions (matches the hardware path's hold-last-frame).
    @MainActor
    func flush(removingDisplayedImage: Bool = true) {
        reorderLock.lock()
        reorderBuffer.removeAll()
        // #303: nothing is held any more, so the frontier is not a frontier. Left standing, a
        // backward seek would keep reporting the pre-seek timestamp and read as a cushion of
        // however far the seek travelled.
        _newestEnqueuedPtsSeconds = nil
        // #311: everything reported before this point describes frames that are now gone.
        _flushGeneration = SampleBufferRenderer.flushGenerations.next()
        // Invalidate the format description cache; the next load() may open a stream with different colorimetry at the same resolution.
        cachedFormatDesc = nil
        cachedFormatKey = nil
        reorderLock.unlock()

        let modern: Bool
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) { modern = true } else { modern = false }
        switch DisplayFlushOp.resolve(removingDisplayedImage: removingDisplayedImage, modernRenderer: modern) {
        case .rendererFlush(let remove):
            if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
                displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: remove) { }
            }
        case .removeImage:
            displayLayer.flushAndRemoveImage()
        case .holdImage:
            displayLayer.flush()
        }
    }

    /// Send all buffered frames to the display layer (call at EOF).
    func drainReorderBuffer() {
        reorderLock.lock()
        let remaining = reorderBuffer
        reorderBuffer.removeAll()
        reorderLock.unlock()

        for (pb, t, hdr) in remaining {
            flushFrame(pixelBuffer: pb, pts: t, hdr10PlusData: hdr)
        }
    }

    // MARK: - Internal

    private func flushFrame(pixelBuffer: CVPixelBuffer, pts: CMTime, hdr10PlusData: Data?) {
        let outputBuffer = subtitleCompositor.composite(pixelBuffer, ptsSeconds: pts.seconds)
        guard let sampleBuffer = createSampleBuffer(from: outputBuffer, pts: pts) else {
            return
        }
        // HDR10+ attachment overrides any payload baked into the bitstream (VT may strip per-frame SEI on decode).
        if let hdr10PlusData {
            CMSetAttachment(
                sampleBuffer,
                key: kCMSampleAttachmentKey_HDR10PlusPerFrameData,
                value: hdr10PlusData as CFData,
                attachmentMode: CMAttachmentMode(kCMAttachmentMode_ShouldPropagate)
            )
            hdr10PlusAttachedCount += 1
            if hdr10PlusAttachedCount == 1 || hdr10PlusAttachedCount == 30 || hdr10PlusAttachedCount % 600 == 0 {
                EngineLog.emit("[Renderer] HDR10+ attachment count: \(hdr10PlusAttachedCount) (last payload \(hdr10PlusData.count) bytes)", category: .swPlayback)
            }
        }
        let target = queueTarget
        if !target.isReadyForMoreMediaData, !loggedNotReady {
            loggedNotReady = true
            EngineLog.emit("[Renderer] isReadyForMoreMediaData=false at enqueue #\(enqueueCount + 1) status=\(statusName)", category: .swPlayback)
        }
        if !target.isReadyForMoreMediaData {
            scheduleQueueDiagnosticsRefresh()
        }
        target.enqueue(sampleBuffer)

        // #311: reported here rather than at admission, so it describes frames the compositor has
        // been given. A frame refused for an unschedulable timestamp, skipped after a seek, or lost
        // to a failed sample-buffer creation never reaches this line and is never reported.
        reorderLock.lock()
        let observer = _frameEnqueuedObserver
        let generation = _flushGeneration
        reorderLock.unlock()
        observer?(SoftwareVideoFrameTime(presentation: pts, generation: generation))

        enqueueCount += 1
        // Sparse milestones so a stall is distinguishable from "logging stopped at #30"; bounded to 4 lines/hour at 60 fps.
        if enqueueCount == 1 || enqueueCount == 30 || enqueueCount == 100 || enqueueCount == 1000 || enqueueCount == 5000 {
            scheduleQueueDiagnosticsRefresh()
            EngineLog.emit("[Renderer] enqueue #\(enqueueCount): status=\(statusName) ready=\(queueTarget.isReadyForMoreMediaData) error=\(queueErrorDescription ?? "nil")", category: .swPlayback)
        }
    }

    private var statusName: String {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return cachedQueueStatusName
    }

    private var queueErrorDescription: String? {
        diagnosticsLock.lock()
        defer { diagnosticsLock.unlock() }
        return cachedQueueErrorDescription
    }

    private func scheduleQueueDiagnosticsRefresh() {
        diagnosticsLock.lock()
        guard !diagnosticsRefreshPending else {
            diagnosticsLock.unlock()
            return
        }
        diagnosticsRefreshPending = true
        diagnosticsLock.unlock()

        Task { @MainActor [weak self] in
            self?.refreshQueueDiagnostics()
        }
    }

    /// Status/error are UI-object diagnostics in Xcode 27 even though enqueueing is explicitly
    /// background-safe. Sample them on the main actor and keep only Sendable values off-actor.
    @MainActor
    private func refreshQueueDiagnostics() {
        let status: AVQueuedSampleBufferRenderingStatus
        let errorDescription: String?
        if #available(tvOS 18.0, iOS 18.0, macOS 15.0, *) {
            let renderer = displayLayer.sampleBufferRenderer
            status = renderer.status
            errorDescription = renderer.error?.localizedDescription
        } else {
            status = displayLayer.status
            errorDescription = displayLayer.error?.localizedDescription
        }

        let statusText: String
        switch status {
        case .unknown: statusText = "unknown"
        case .rendering: statusText = "rendering"
        case .failed: statusText = "failed"
        @unknown default: statusText = "?"
        }

        diagnosticsLock.lock()
        cachedQueueStatusName = statusText
        cachedQueueErrorDescription = errorDescription
        diagnosticsRefreshPending = false
        let shouldLogFailure = status == .failed && !loggedLayerFailed
        if shouldLogFailure { loggedLayerFailed = true }
        diagnosticsLock.unlock()

        guard status == .failed else { return }
        if shouldLogFailure {
            EngineLog.emit(
                "[Renderer] queue target failed at enqueue #\(enqueueCount + 1): \(errorDescription ?? "nil"), attempting recovery via flush()",
                category: .swPlayback
            )
        }
        renderingTarget.flush()
    }

    /// [SWDiag] surface: current queue-target status for the 1 Hz diagnostic line. A mid-session
    /// flip away from `rendering` is the layer-side stall the per-frame counters cannot show.
    var diagStatusName: String { statusName }

    /// #353: what the layer will draw the description at. Pixel aspect ratio and clean aperture are
    /// extensions of the description itself, so this asks the description what it presents at
    /// instead of repeating the decision that built it.
    static func presentationSize(of desc: CMVideoFormatDescription) -> CGSize {
        CMVideoFormatDescriptionGetPresentationDimensions(
            desc, usePixelAspectRatio: true, useCleanAperture: true)
    }

    /// Internal (not private) for #177 regression tests: the PAR-keyed cache behavior is the fix.
    func createSampleBuffer(from pixelBuffer: CVPixelBuffer, pts: CMTime) -> CMSampleBuffer? {
        // Cache hit avoids CMVideoFormatDescriptionCreateForImageBuffer allocation + CF refcount churn on every frame.
        let par = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferPixelAspectRatioKey, nil) as? NSDictionary
        let key = FormatDescriptionKey(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            pixelFormat: CVPixelBufferGetPixelFormatType(pixelBuffer),
            primaries: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, nil) as? String,
            transfer: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String,
            matrix: CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String,
            parH: (par?[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? NSNumber)?.intValue,
            parV: (par?[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? NSNumber)?.intValue
        )

        // Guarded by reorderLock: flush() nils the cache from other threads.
        reorderLock.lock()
        let cachedDesc: CMVideoFormatDescription? =
            (cachedFormatKey == key) ? cachedFormatDesc : nil
        reorderLock.unlock()

        let desc: CMVideoFormatDescription
        if let cachedDesc {
            desc = cachedDesc
        } else {
            var formatDesc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDesc
            )
            guard status == noErr, let new = formatDesc else { return nil }
            // #353: a new description is the only moment the picture can change shape, so the
            // settled size is taken here and reported outside the lock.
            let settled = Self.presentationSize(of: new)
            reorderLock.lock()
            cachedFormatDesc = new
            cachedFormatKey = key
            let changed = settled != _displaySize
            if changed { _displaySize = settled }
            let sizeObserver = changed ? _displaySizeObserver : nil
            reorderLock.unlock()
            sizeObserver?(settled)
            desc = new
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: desc,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr else { return nil }
        return sampleBuffer
    }
}
