import SwiftUI
import AetherEngine

/// Host-rendered subtitle layer for Aether sessions.
/// Placed above the video surface and below transport controls.
struct PlayerSubtitleOverlay: View {
    @ObservedObject var playback: AetherSubtitleOverlayState
    @ObservedObject var translation: AISubtitleTranslationState
    let subtitleDelaySeconds: Double
    let videoNaturalSize: CGSize
    let aspectMode: PlayerAspectMode
    let style: SubtitleStyle

    private var textSize: CGFloat {
        min(max(CGFloat(style.textSize) / 100 * 55, 24), 125)
    }
    private var textColor: Color { Color(hex: style.textColorHex) }
    private var outlineColor: Color { Color(hex: style.outlineColorHex) }
    private var textOpacity: Double { Double(min(max(style.textOpacity, 0), 100)) / 100 }
    private var outlineWidth: CGFloat { style.outlineEnabled ? 2 : 0 }
    private var bottomOffset: CGFloat { CGFloat(22 + min(max(style.bottomOffset, 0), 160)) }
    private var horizontalMargin: CGFloat { CGFloat(min(max(style.horizontalMargin, 0), 200)) }
    private var fontWeight: Font.Weight { style.bold ? .bold : .regular }

    private var evaluationTime: Double {
        playback.sourceTime - subtitleDelaySeconds
    }

    private var activeCues: [SubtitleCue] {
        playback.cues.filter { cue in
            evaluationTime >= cue.startTime && evaluationTime <= cue.endTime
        }
    }

    private var activeTextCues: [SubtitleCue] {
        activeCues.filter {
            if case .image = $0.body { return false }
            return $0.placement == nil
        }
    }

    private var placedTextCues: [SubtitleCue] {
        activeCues.filter {
            if case .image = $0.body { return false }
            return $0.placement != nil
        }
    }

    private var activeBitmapCues: [SubtitleCue] {
        activeCues.filter {
            if case .image = $0.body { return true }
            return false
        }
    }

    var body: some View {
        GeometryReader { geo in
            let videoRect = playback.nativeVideoRect ?? displayedVideoRect(
                container: geo.size,
                video: videoNaturalSize,
                mode: aspectMode
            )
            ZStack {
                ForEach(activeBitmapCues) { cue in
                    if case .image(let image) = cue.body {
                        bitmapCue(image, videoRect: videoRect)
                    }
                }

                if let renderer = playback.assRenderer {
                    ASSRenderedSubtitles(
                        renderer: renderer,
                        reloadSignal: playback.assReloadSignal,
                        sourceTime: evaluationTime,
                        onCanvasSizeChanged: playback.onASSCanvasSizeChanged
                    )
                    .id(ObjectIdentifier(renderer))
                    .frame(width: videoRect.width, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)
                } else if playback.isASSActive {
                    VStack(spacing: 10) {
                        ForEach(activeTextCues) { cue in
                            if let raw = cue.text,
                               let plain = ASSPlainTextFallback.text(from: raw) {
                                outlinedText(plain, alignment: .center)
                            }
                        }
                    }
                    .frame(
                        width: max(videoRect.width - horizontalMargin * 2, 1),
                        height: max(videoRect.height - bottomOffset, 1),
                        alignment: .bottom
                    )
                    .position(
                        x: videoRect.midX,
                        y: videoRect.minY + max(videoRect.height - bottomOffset, 1) / 2
                    )
                } else {
                    ForEach(placedTextCues) { cue in
                        if let placement = cue.placement {
                            SubtitleCuePlacementLayout(
                                placement: placement,
                                horizontalMargin: horizontalMargin,
                                verticalMargin: bottomOffset
                            ) {
                                textBody(cue, alignment: textAlignment(for: placement))
                            }
                            .frame(width: videoRect.width, height: videoRect.height)
                            .position(x: videoRect.midX, y: videoRect.midY)
                        }
                    }

                    // Multiple simultaneous dialogue cues stack above the video
                    // bottom instead of being painted on the same baseline.
                    VStack(spacing: 10) {
                        ForEach(activeTextCues) { cue in
                            textBody(cue)
                        }
                        if translation.isTranslating(cueIDs: (activeTextCues + placedTextCues).map(\.id)) {
                            HStack(spacing: 5) {
                                Image(systemName: "sparkles")
                                Text("AI")
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.72))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.36), in: Capsule())
                        }
                    }
                    .frame(
                        width: max(videoRect.width - horizontalMargin * 2, 1),
                        height: max(videoRect.height - bottomOffset, 1),
                        alignment: .bottom
                    )
                    .position(
                        x: videoRect.midX,
                        y: videoRect.minY + max(videoRect.height - bottomOffset, 1) / 2
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func textBody(_ cue: SubtitleCue, alignment: TextAlignment = .center) -> some View {
        switch cue.body {
        case .text(let string):
            outlinedText(translation.translatedText(for: cue) ?? string, alignment: alignment)
        case .richText(let runs):
            if let translated = translation.translatedText(for: cue) {
                outlinedText(translated, alignment: alignment)
            } else {
                outlinedRichText(runs, alignment: alignment)
            }
        case .image:
            EmptyView()
        }
    }

    private func outlinedText(_ string: String, alignment: TextAlignment) -> some View {
        Text(string)
            .font(.system(size: textSize, weight: fontWeight))
            .foregroundStyle(textColor.opacity(textOpacity))
            .tracking(CGFloat(style.letterSpacing))
            .multilineTextAlignment(alignment)
            .subtitleOutline(color: outlineColor, width: outlineWidth)
            .subtitleBackground(style: style)
    }

    private func outlinedRichText(_ runs: [SubtitleTextRun], alignment: TextAlignment) -> some View {
        runs.reduce(Text("")) { text, run in
            text + styledText(run)
        }
        .multilineTextAlignment(alignment)
        .subtitleOutline(color: outlineColor, width: outlineWidth)
        .subtitleBackground(style: style)
    }

    private func styledText(_ run: SubtitleTextRun) -> Text {
        let size = run.fontSize.map { textSize * CGFloat($0) / 16 } ?? textSize
        let font = run.fontName.map { Font.custom($0, size: size) }
            ?? Font.system(size: size)
        var text = Text(run.text)
            .font(font.weight(run.isBold || style.bold ? .bold : .regular))
            .foregroundColor(runColor(run).opacity(textOpacity))
            .tracking(CGFloat(style.letterSpacing))
        if run.isItalic { text = text.italic() }
        if run.isUnderlined { text = text.underline() }
        if run.isStruckThrough { text = text.strikethrough() }
        return text
    }

    private func runColor(_ run: SubtitleTextRun) -> Color {
        guard let c = run.color else { return textColor }
        return Color(
            red: Double(c.r) / 255.0,
            green: Double(c.g) / 255.0,
            blue: Double(c.b) / 255.0
        )
    }

    private func textAlignment(for placement: SubtitleTextPlacement) -> TextAlignment {
        let alignment = (1...9).contains(placement.alignment ?? 2) ? (placement.alignment ?? 2) : 2
        switch alignment % 3 {
        case 1: return .leading
        case 0: return .trailing
        default: return .center
        }
    }

    private func bitmapCue(_ image: SubtitleImage, videoRect: CGRect) -> some View {
        let canvas = image.canvasSize == .zero ? videoRect.size : image.canvasSize
        // Map composition canvas width-aligned and center-anchored onto the video rect.
        let scale = videoRect.width / max(canvas.width, 1)
        let mappedHeight = canvas.height * scale
        let canvasOriginY = videoRect.midY - mappedHeight / 2
        let frame = CGRect(
            x: videoRect.minX + image.position.origin.x * videoRect.width,
            y: canvasOriginY + image.position.origin.y * mappedHeight,
            width: image.position.width * videoRect.width,
            height: image.position.height * mappedHeight
        )
        return Image(decorative: image.cgImage, scale: 1, orientation: .up)
            .resizable()
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    /// Computes the on-screen video rectangle for the active aspect mode.
    private func displayedVideoRect(container: CGSize, video: CGSize, mode: PlayerAspectMode) -> CGRect {
        guard video.width > 1, video.height > 1,
              container.width > 1, container.height > 1 else {
            return CGRect(origin: .zero, size: container)
        }
        let videoAspect = video.width / video.height
        let containerAspect = container.width / container.height
        switch mode {
        case .stretch:
            return CGRect(origin: .zero, size: container)
        case .fit:
            if videoAspect > containerAspect {
                let h = container.width / videoAspect
                return CGRect(x: 0, y: (container.height - h) / 2, width: container.width, height: h)
            } else {
                let w = container.height * videoAspect
                return CGRect(x: (container.width - w) / 2, y: 0, width: w, height: container.height)
            }
        case .fill:
            if videoAspect > containerAspect {
                let w = container.height * videoAspect
                return CGRect(x: (container.width - w) / 2, y: 0, width: w, height: container.height)
            } else {
                let h = container.width / videoAspect
                return CGRect(x: 0, y: (container.height - h) / 2, width: container.width, height: h)
            }
        case .zoom:
            if videoAspect > containerAspect {
                let fitH = container.width / videoAspect
                let fillH = container.height
                let h = fitH + (fillH - fitH) * 0.5
                let w = h * videoAspect
                return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
            } else {
                let fitW = container.height * videoAspect
                let fillW = container.width
                let w = fitW + (fillW - fitW) * 0.5
                let h = w / videoAspect
                return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
            }
        }
    }
}

/// MPV decodes its active text subtitle through `sub-text`. When AI
/// translation is active MPV's own renderer stays hidden, and this host layer
/// immediately renders the original text until the translated replacement is
/// available. Bitmap subtitles remain entirely under MPV's renderer.
struct MPVSubtitleOverlay: View {
    @ObservedObject var translation: MPVSubtitleTranslationState
    let videoNaturalSize: CGSize
    let aspectMode: PlayerAspectMode
    let style: SubtitleStyle

    private var textSize: CGFloat {
        min(max(CGFloat(style.textSize) / 100 * 55, 24), 125)
    }
    private var textColor: Color { Color(hex: style.textColorHex) }
    private var outlineColor: Color { Color(hex: style.outlineColorHex) }
    private var textOpacity: Double { Double(min(max(style.textOpacity, 0), 100)) / 100 }
    private var outlineWidth: CGFloat { style.outlineEnabled ? 2 : 0 }
    private var bottomOffset: CGFloat { CGFloat(22 + min(max(style.bottomOffset, 0), 160)) }
    private var horizontalMargin: CGFloat { CGFloat(min(max(style.horizontalMargin, 0), 200)) }
    private var fontWeight: Font.Weight { style.bold ? .bold : .regular }

    var body: some View {
        GeometryReader { geo in
            if let text = translation.displayText {
                let videoRect = displayedVideoRect(
                    container: geo.size,
                    video: videoNaturalSize,
                    mode: aspectMode
                )
                VStack(spacing: 8) {
                    Text(text)
                        .font(.system(size: textSize, weight: fontWeight))
                        .foregroundStyle(textColor.opacity(textOpacity))
                        .tracking(CGFloat(style.letterSpacing))
                        .multilineTextAlignment(.center)
                        .subtitleOutline(color: outlineColor, width: outlineWidth)
                        .subtitleBackground(style: style)
                    if translation.isTranslating {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                            Text("AI")
                            ProgressView().controlSize(.mini)
                        }
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.36), in: Capsule())
                    }
                }
                .frame(
                    width: max(videoRect.width - horizontalMargin * 2, 1),
                    height: max(videoRect.height - bottomOffset, 1),
                    alignment: .bottom
                )
                .position(
                    x: videoRect.midX,
                    y: videoRect.minY + max(videoRect.height - bottomOffset, 1) / 2
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func displayedVideoRect(container: CGSize, video: CGSize, mode: PlayerAspectMode) -> CGRect {
        guard video.width > 1, video.height > 1,
              container.width > 1, container.height > 1 else {
            return CGRect(origin: .zero, size: container)
        }
        let videoAspect = video.width / video.height
        let containerAspect = container.width / container.height
        switch mode {
        case .stretch:
            return CGRect(origin: .zero, size: container)
        case .fit:
            if videoAspect > containerAspect {
                let h = container.width / videoAspect
                return CGRect(x: 0, y: (container.height - h) / 2, width: container.width, height: h)
            } else {
                let w = container.height * videoAspect
                return CGRect(x: (container.width - w) / 2, y: 0, width: w, height: container.height)
            }
        case .fill:
            if videoAspect > containerAspect {
                let w = container.height * videoAspect
                return CGRect(x: (container.width - w) / 2, y: 0, width: w, height: container.height)
            } else {
                let h = container.width / videoAspect
                return CGRect(x: 0, y: (container.height - h) / 2, width: container.width, height: h)
            }
        case .zoom:
            if videoAspect > containerAspect {
                let fitH = container.width / videoAspect
                let fillH = container.height
                let h = fitH + (fillH - fitH) * 0.5
                let w = h * videoAspect
                return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
            } else {
                let fitW = container.height * videoAspect
                let fillW = container.width
                let w = fitW + (fillW - fitW) * 0.5
                let h = w / videoAspect
                return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
            }
        }
    }
}

/// Place ASS text at its authored alignment or explicit \pos anchor inside the video frame.
private struct SubtitleCuePlacementLayout: Layout {
    let placement: SubtitleTextPlacement
    let horizontalMargin: CGFloat
    let verticalMargin: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        let alignment = (1...9).contains(placement.alignment ?? 2) ? (placement.alignment ?? 2) : 2
        let anchorX = CGFloat((alignment - 1) % 3) / 2
        let anchorY = 1 - CGFloat((alignment - 1) / 3) / 2
        let point: CGPoint
        if let position = placement.position {
            point = CGPoint(
                x: bounds.minX + position.x * bounds.width,
                y: bounds.minY + position.y * bounds.height
            )
        } else {
            point = CGPoint(
                x: bounds.minX + horizontalMargin + anchorX * max(bounds.width - 2 * horizontalMargin, 0),
                y: bounds.minY + verticalMargin + anchorY * max(bounds.height - 2 * verticalMargin, 0)
            )
        }
        let maxWidth = max(bounds.width - 2 * horizontalMargin, 1)
        let width = min(subview.sizeThatFits(.unspecified).width, maxWidth)
        subview.place(
            at: point,
            anchor: UnitPoint(x: anchorX, y: anchorY),
            proposal: ProposedViewSize(width: width, height: nil)
        )
    }
}

private struct SubtitleBackgroundModifier: ViewModifier {
    let style: SubtitleStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        if style.backgroundEnabled {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Color(hex: style.backgroundColorHex)
                        .opacity(Double(min(max(style.backgroundOpacity, 0), 100)) / 100),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        } else {
            content
        }
    }
}

private extension View {
    func subtitleBackground(style: SubtitleStyle) -> some View {
        modifier(SubtitleBackgroundModifier(style: style))
    }
}

private extension View {
    /// Eight zero-radius shadows form a crisp, inexpensive tvOS text stroke.
    func subtitleOutline(color: Color, width: CGFloat) -> some View {
        let stroke = width > 0 ? color : .clear
        return self
            .shadow(color: stroke, radius: 0, x: -width, y: 0)
            .shadow(color: stroke, radius: 0, x: width, y: 0)
            .shadow(color: stroke, radius: 0, x: 0, y: -width)
            .shadow(color: stroke, radius: 0, x: 0, y: width)
            .shadow(color: stroke, radius: 0, x: -width, y: -width)
            .shadow(color: stroke, radius: 0, x: width, y: -width)
            .shadow(color: stroke, radius: 0, x: -width, y: width)
            .shadow(color: stroke, radius: 0, x: width, y: width)
    }
}
