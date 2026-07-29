import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation

/// SW-PiP Phase C: composites active subtitle cues into decoded software-path frames so the system
/// PiP window (which renders only the sample-buffer layer) shows subtitles. Enabled ONLY while
/// pictureInPictureActive; fullscreen subtitles stay with the host's on-frame overlay. Playback wins
/// over subtitles: every failure path returns the original buffer untouched.
final class SubtitleFrameCompositor: @unchecked Sendable {

    struct TextLayout: Equatable {
        let fontSize: CGFloat
        let bottomMargin: CGFloat
        let maxTextWidth: CGFloat
    }

    /// Plain window check; cue times and SW frame PTS share the source axis.
    nonisolated static func activeCues(in cues: [SubtitleCue], at seconds: Double) -> [SubtitleCue] {
        cues.filter { $0.startTime <= seconds && seconds < $0.endTime }
    }

    /// Default look: readable in a small window, resolution-independent.
    nonisolated static func textLayout(frameWidth: CGFloat, frameHeight: CGFloat) -> TextLayout {
        TextLayout(
            fontSize: frameHeight * 0.05,
            bottomMargin: frameHeight * 0.06,
            maxTextWidth: frameWidth * 0.9
        )
    }

    /// Canvas -> frame mapping per the SubtitleImage contract: `position` is NORMALIZED against the
    /// canvas; go to canvas pixels first, then map width-aligned and center-anchored vertically (a
    /// cropped rip's canvas can be taller than the coded video). A .zero canvas means the position is
    /// normalized against the video frame itself.
    nonisolated static func imageRect(position: CGRect, canvasSize: CGSize, frameWidth: CGFloat, frameHeight: CGFloat) -> CGRect {
        guard canvasSize != .zero, canvasSize.width > 0 else {
            return CGRect(
                x: position.minX * frameWidth,
                y: position.minY * frameHeight,
                width: position.width * frameWidth,
                height: position.height * frameHeight
            )
        }
        let px = position.minX * canvasSize.width
        let py = position.minY * canvasSize.height
        let scale = frameWidth / canvasSize.width
        let frameCenterY = frameHeight / 2
        let canvasCenterY = canvasSize.height / 2
        return CGRect(
            x: px * scale,
            y: frameCenterY + (py - canvasCenterY) * scale,
            width: position.width * canvasSize.width * scale,
            height: position.height * canvasSize.height * scale
        )
    }

    // MARK: - State

    private let lock = NSLock()
    private var cues: [SubtitleCue] = []
    private var enabled = false
    /// Cache key of the overlay currently rendered (active cue ids); nil = no overlay cached.
    private var cachedCueIDs: [Int]?
    private var cachedOverlay: CIImage?
    private var loggedFailure = false

    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolFormat: (width: Int, height: Int, pixelFormat: OSType)?

    /// Any thread; called by the engine when its published cues or the PiP flag change.
    func update(cues: [SubtitleCue], enabled: Bool) {
        lock.lock()
        self.cues = cues
        self.enabled = enabled
        lock.unlock()
    }

    /// Render thread. Returns the input buffer untouched on passthrough or ANY failure.
    func composite(_ buffer: CVPixelBuffer, ptsSeconds: Double) -> CVPixelBuffer {
        lock.lock()
        let enabled = self.enabled
        let cues = self.cues
        lock.unlock()
        guard enabled else { return buffer }

        let active = Self.activeCues(in: cues, at: ptsSeconds)
        guard !active.isEmpty else {
            lock.lock(); cachedCueIDs = nil; cachedOverlay = nil; lock.unlock()
            return buffer
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let overlay: CIImage
        lock.lock()
        let cacheHit = cachedCueIDs == active.map(\.id) ? cachedOverlay : nil
        lock.unlock()
        if let cacheHit {
            overlay = cacheHit
        } else {
            guard let rendered = Self.renderOverlay(for: active, frameWidth: CGFloat(width), frameHeight: CGFloat(height)) else {
                logFailureOnce("overlay render failed")
                return buffer
            }
            overlay = CIImage(cgImage: rendered)
            lock.lock()
            cachedCueIDs = active.map(\.id)
            cachedOverlay = overlay
            lock.unlock()
        }

        guard let output = dequeueBuffer(width: width, height: height, pixelFormat: CVPixelBufferGetPixelFormatType(buffer)) else {
            logFailureOnce("pool exhausted")
            return buffer
        }
        let base = CIImage(cvPixelBuffer: buffer)
        let composited = overlay.composited(over: base)
        ciContext.render(composited, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
        return output
    }

    /// One CGImage per cue-set change: text cues bottom-up in the default look, image cues at their
    /// canvas-mapped rects. CG coordinate origin is bottom-left; layout values are top-left based,
    /// so y flips via frameHeight.
    nonisolated static func renderOverlay(for cues: [SubtitleCue], frameWidth: CGFloat, frameHeight: CGFloat) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: Int(frameWidth), height: Int(frameHeight),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let layout = textLayout(frameWidth: frameWidth, frameHeight: frameHeight)
        var textBaselineFromBottom = layout.bottomMargin

        for cue in cues {
            switch cue.body {
            case .image(let image):
                let rectTopLeft = imageRect(position: image.position, canvasSize: image.canvasSize, frameWidth: frameWidth, frameHeight: frameHeight)
                let rect = CGRect(x: rectTopLeft.minX, y: frameHeight - rectTopLeft.maxY, width: rectTopLeft.width, height: rectTopLeft.height)
                ctx.draw(image.cgImage, in: rect)
            case .text(let text):
                drawTextBlock([SubtitleTextRun(text: text, color: nil)], placement: cue.placement,
                              in: ctx, layout: layout, frameWidth: frameWidth,
                              frameHeight: frameHeight, baselineFromBottom: &textBaselineFromBottom)
            case .richText(let runs):
                drawTextBlock(runs, placement: cue.placement,
                              in: ctx, layout: layout, frameWidth: frameWidth,
                              frameHeight: frameHeight, baselineFromBottom: &textBaselineFromBottom)
            }
        }
        return ctx.makeImage()
    }

    /// Split a run sequence at its line breaks, keeping each run's styling. A run spanning a break
    /// contributes to both lines.
    nonisolated static func lines(from runs: [SubtitleTextRun]) -> [[SubtitleTextRun]] {
        var out: [[SubtitleTextRun]] = [[]]
        for run in runs {
            let parts = run.text.components(separatedBy: "\n")
            for (i, part) in parts.enumerated() {
                if i > 0 { out.append([]) }
                if !part.isEmpty { out[out.count - 1].append(run.withText(part)) }
            }
        }
        return out.filter { !$0.isEmpty }
    }

    /// Font for a run. ASS `\fs` is relative to libavcodec's default style size
    /// (`ASS_DEFAULT_FONT_SIZE` = 16), so it scales the layout's base size rather than naming
    /// pixels, which keeps a cue proportionate at any frame height.
    nonisolated static func font(for run: SubtitleTextRun, baseSize: CGFloat) -> CTFont {
        let size = run.fontSize.map { baseSize * CGFloat($0) / 16.0 } ?? baseSize
        let name = run.fontName ?? "HelveticaNeue-Medium"
        let base = CTFontCreateWithName(name as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if run.isBold { traits.insert(.traitBold) }
        if run.isItalic { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    /// Bottom-left origin for a text block under an explicit placement (#233).
    ///
    /// ASS numpad alignment: 1 to 3 bottom, 4 to 6 middle, 7 to 9 top, left to right within each
    /// row. With a `\pos` the point is the anchor and the alignment says which part of the block
    /// sits on it; without one the alignment picks a corner inset by `margin`. A position with no
    /// alignment takes the ASS default of 2 (bottom centre). Normalized positions measure y from
    /// the top, the context draws bottom-up, so y flips here.
    nonisolated static func blockOrigin(placement: SubtitleTextPlacement, blockSize: CGSize,
                                        frameWidth: CGFloat, frameHeight: CGFloat,
                                        margin: CGFloat) -> CGPoint {
        let an = placement.alignment ?? 2
        let column = (an - 1) % 3     // 0 left, 1 centre, 2 right
        let row = (an - 1) / 3        // 0 bottom, 1 middle, 2 top

        guard let position = placement.position else {
            let x: CGFloat = column == 0 ? margin
                : column == 1 ? (frameWidth - blockSize.width) / 2
                : frameWidth - blockSize.width - margin
            let y: CGFloat = row == 0 ? margin
                : row == 1 ? (frameHeight - blockSize.height) / 2
                : frameHeight - blockSize.height - margin
            return CGPoint(x: x, y: y)
        }

        let anchorX = position.x * frameWidth
        let anchorY = frameHeight - position.y * frameHeight
        let x: CGFloat = column == 0 ? anchorX
            : column == 1 ? anchorX - blockSize.width / 2
            : anchorX - blockSize.width
        let y: CGFloat = row == 0 ? anchorY
            : row == 1 ? anchorY - blockSize.height / 2
            : anchorY - blockSize.height
        return CGPoint(x: x, y: y)
    }

    private nonisolated static func drawTextBlock(_ runs: [SubtitleTextRun],
                                                  placement: SubtitleTextPlacement?,
                                                  in ctx: CGContext, layout: TextLayout,
                                                  frameWidth: CGFloat, frameHeight: CGFloat,
                                                  baselineFromBottom: inout CGFloat) {
        let split = lines(from: runs)
        guard !split.isEmpty else { return }
        let pad = layout.fontSize * 0.4

        // Build every line first: a placed block needs its own measured size before it can be put
        // anywhere, and the default stack needs the same measurements anyway.
        let built: [(line: CTLine, runs: [SubtitleTextRun], bounds: CGRect)] = split.compactMap {
            guard let attributed = attributedLine($0, layout: layout) else { return nil }
            let ctLine = CTLineCreateWithAttributedString(attributed)
            return (ctLine, $0, CTLineGetBoundsWithOptions(ctLine, .useOpticalBounds))
        }
        guard !built.isEmpty else { return }

        let boxWidth = min((built.map(\.bounds.width).max() ?? 0) + pad * 2, layout.maxTextWidth)
        let lineHeights = built.map { $0.bounds.height + pad }

        var originX = (frameWidth - boxWidth) / 2
        var cursorY = baselineFromBottom
        if let placement {
            let blockHeight = lineHeights.reduce(0, +) + layout.fontSize * 0.2 * CGFloat(built.count - 1)
            let origin = blockOrigin(placement: placement,
                                     blockSize: CGSize(width: boxWidth, height: blockHeight),
                                     frameWidth: frameWidth, frameHeight: frameHeight,
                                     margin: layout.bottomMargin)
            originX = origin.x
            cursorY = origin.y
        }

        // Bottom-up, so the last line is drawn first and reads top-down on screen.
        for (index, entry) in built.enumerated().reversed() {
            let boxHeight = lineHeights[index]
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
            ctx.fill(CGRect(x: originX, y: cursorY - pad / 2, width: boxWidth, height: boxHeight)
                .insetBy(dx: -2, dy: -2))
            let textX = originX + pad
            let baseline = cursorY + pad / 2 - entry.bounds.minY
            ctx.textPosition = CGPoint(x: textX, y: baseline)
            CTLineDraw(entry.line, ctx)
            drawStrikethrough(entry.runs, on: entry.line, in: ctx, at: CGPoint(x: textX, y: baseline),
                              layout: layout)
            cursorY += boxHeight + layout.fontSize * 0.2
        }
        if placement == nil { baselineFromBottom = cursorY }
    }

    private nonisolated static func attributedLine(_ runs: [SubtitleTextRun],
                                                   layout: TextLayout) -> CFAttributedString? {
        guard let attributed = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0) else { return nil }
        CFAttributedStringBeginEditing(attributed)
        for run in runs {
            var attributes: [CFString: Any] = [
                kCTFontAttributeName: font(for: run, baseSize: layout.fontSize),
                kCTForegroundColorAttributeName: run.color.map {
                    CGColor(red: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255,
                            blue: CGFloat($0.b) / 255, alpha: 1)
                } ?? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
            ]
            if run.isUnderlined {
                attributes[kCTUnderlineStyleAttributeName] = CTUnderlineStyle.single.rawValue
            }
            guard let piece = CFAttributedStringCreate(
                kCFAllocatorDefault, run.text as CFString, attributes as CFDictionary) else { continue }
            CFAttributedStringReplaceAttributedString(
                attributed, CFRange(location: CFAttributedStringGetLength(attributed), length: 0), piece)
        }
        CFAttributedStringEndEditing(attributed)
        return CFAttributedStringGetLength(attributed) > 0 ? attributed : nil
    }

    /// CoreText has no strikethrough attribute (unlike AppKit's NSAttributedString), so struck runs
    /// get a rule drawn over their own glyph range.
    private nonisolated static func drawStrikethrough(_ runs: [SubtitleTextRun], on line: CTLine,
                                                      in ctx: CGContext, at origin: CGPoint,
                                                      layout: TextLayout) {
        var index = 0
        for run in runs {
            let length = run.text.utf16.count
            defer { index += length }
            guard run.isStruckThrough, length > 0 else { continue }
            let startX = CTLineGetOffsetForStringIndex(line, index, nil)
            let endX = CTLineGetOffsetForStringIndex(line, index + length, nil)
            let size = CTFontGetSize(font(for: run, baseSize: layout.fontSize))
            ctx.setStrokeColor(run.color.map {
                CGColor(red: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255,
                        blue: CGFloat($0.b) / 255, alpha: 1)
            } ?? CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.setLineWidth(max(1, size * 0.06))
            let y = origin.y + size * 0.28
            ctx.move(to: CGPoint(x: origin.x + startX, y: y))
            ctx.addLine(to: CGPoint(x: origin.x + endX, y: y))
            ctx.strokePath()
        }
    }

    private func dequeueBuffer(width: Int, height: Int, pixelFormat: OSType) -> CVPixelBuffer? {
        if poolFormat?.width != width || poolFormat?.height != height || poolFormat?.pixelFormat != pixelFormat {
            let attrs: [CFString: Any] = [
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attrs as CFDictionary, &newPool)
            pool = newPool
            poolFormat = (width, height, pixelFormat)
        }
        guard let pool else { return nil }
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        return out
    }

    private func logFailureOnce(_ reason: String) {
        lock.lock()
        let first = !loggedFailure
        loggedFailure = true
        lock.unlock()
        if first {
            EngineLog.emit("[SubtitleCompositor] degraded to passthrough: \(reason)", category: .swPlayback)
        }
    }

    /// Session teardown: drop cache and pool.
    func reset() {
        lock.lock()
        cues = []
        enabled = false
        cachedCueIDs = nil
        cachedOverlay = nil
        pool = nil
        poolFormat = nil
        loggedFailure = false
        lock.unlock()
    }
}
