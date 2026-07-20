import SwiftUI
import AetherEngine

/// Host-rendered subtitle layer for Aether sessions.
/// Placed above the video surface and below transport controls.
struct PlayerSubtitleOverlay: View {
    let cues: [SubtitleCue]
    let sourceTime: Double
    let subtitleDelaySeconds: Double
    let videoNaturalSize: CGSize
    let aspectMode: PlayerAspectMode
    let style: SubtitleStyle

    private var textSize: CGFloat {
        min(max(CGFloat(style.textSize) / 100 * 42, 24), 92)
    }
    private var textColor: Color { Color(hex: style.textColorHex) }
    private var outlineColor: Color { Color(hex: style.outlineColorHex) }
    private var textOpacity: Double { Double(min(max(style.textOpacity, 0), 100)) / 100 }
    private var outlineWidth: CGFloat { style.outlineEnabled ? 2 : 0 }
    private var bottomOffset: CGFloat { CGFloat(22 + min(max(style.bottomOffset, 0), 160)) }
    private var horizontalMargin: CGFloat { CGFloat(min(max(style.horizontalMargin, 0), 200)) }
    private var fontWeight: Font.Weight { style.bold ? .bold : .regular }

    private var evaluationTime: Double {
        sourceTime - subtitleDelaySeconds
    }

    private var activeCues: [SubtitleCue] {
        cues.filter { cue in
            evaluationTime >= cue.startTime && evaluationTime <= cue.endTime
        }
    }

    private var activeTextCues: [SubtitleCue] {
        activeCues.filter {
            if case .image = $0.body { return false }
            return true
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
            let videoRect = displayedVideoRect(
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

                // Multiple simultaneous dialogue cues stack above the video
                // bottom instead of being painted on the same baseline.
                VStack(spacing: 10) {
                    ForEach(activeTextCues) { cue in
                        textBody(cue)
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
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func textBody(_ cue: SubtitleCue) -> some View {
        switch cue.body {
        case .text(let string):
            outlinedText(string)
        case .richText(let runs):
            outlinedRichText(runs)
        case .image:
            EmptyView()
        }
    }

    private func outlinedText(_ string: String) -> some View {
        Text(string)
            .font(.system(size: textSize, weight: fontWeight))
            .foregroundStyle(textColor.opacity(textOpacity))
            .tracking(CGFloat(style.letterSpacing))
            .multilineTextAlignment(.center)
            .subtitleOutline(color: outlineColor, width: outlineWidth)
    }

    private func outlinedRichText(_ runs: [SubtitleTextRun]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                Text(run.text)
                    .font(.system(size: textSize, weight: fontWeight))
                    .foregroundStyle(runColor(run).opacity(textOpacity))
                    .tracking(CGFloat(style.letterSpacing))
            }
        }
        .subtitleOutline(color: outlineColor, width: outlineWidth)
    }

    private func runColor(_ run: SubtitleTextRun) -> Color {
        guard let c = run.color else { return textColor }
        return Color(
            red: Double(c.r) / 255.0,
            green: Double(c.g) / 255.0,
            blue: Double(c.b) / 255.0
        )
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
        }
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
