import SwiftUI

/// The remote's clickpad, drawn from a `GesturePadFrame`: the ring with its
/// direction clicks, the touch surface, Play/Pause below, the finger and its trail, a ring that
/// fills on a long press or a held finger, a tap's ripple. With `zones`, also where the middle and
/// the corners end (the sensitivity in the Gestures tab).
struct RemotePadCanvas: View {
    let frame: GesturePadFrame
    var zones: RemoteGestureTuning?

    static let aspect: CGFloat = 1.22
    static let accent = Color(red: 0.40, green: 0.68, blue: 1.0)
    static let hot = Color(red: 1.0, green: 0.62, blue: 0.32)

    var body: some View {
        Canvas { context, size in
            Self.draw(frame, zones: zones, in: &context, size: size)
        }
        .aspectRatio(1 / Self.aspect, contentMode: .fit)
    }

    private static func draw(_ frame: GesturePadFrame, zones: RemoteGestureTuning?, in context: inout GraphicsContext, size: CGSize) {
        let diameter = min(size.width, size.height / aspect)
        let center = CGPoint(x: size.width / 2, y: diameter / 2)
        // Room around the pad for the ring of a long press (it was cut off by the card).
        let radius = diameter * 0.42
        let inner = radius * 0.62
        let lineWidth = max(diameter / 160, 1.2)
        func point(_ p: PadPoint) -> CGPoint {
            CGPoint(x: center.x + p.x * radius, y: center.y - p.y * radius)
        }
        func onCircle(_ r: CGFloat, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        }
        func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
            Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        /// Screen angles: 0 right, π/2 down.
        func arc(_ r: CGFloat, from start: Double, to end: Double) -> Path {
            var path = Path()
            let steps = max(Int(abs(end - start) / 0.05), 2)
            for i in 0...steps {
                let p = onCircle(r, start + (end - start) * Double(i) / Double(steps))
                if i == 0 {
                    path.move(to: p)
                } else {
                    path.addLine(to: p)
                }
            }
            return path
        }

        // The pad.
        context.fill(circle(center, radius), with: .color(.white.opacity(0.06)))
        context.stroke(circle(center, radius), with: .color(.white.opacity(0.38)), lineWidth: lineWidth * 1.4)
        context.stroke(circle(center, inner), with: .color(.white.opacity(0.16)), lineWidth: lineWidth)

        // Where the middle ends and the corners begin.
        if let zones {
            let half = zones.sideThreshold * radius
            let square = Path(CGRect(x: center.x - half, y: center.y - half, width: half * 2, height: half * 2))
            context.stroke(square, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: lineWidth, dash: [6, 6]))
            let quarter = Double.pi / 2
            let boundaries: [Double] = zones.cornerTouches
                ? [45 - zones.cornerWidth / 2, 45 + zones.cornerWidth / 2].map { $0 * .pi / 180 }
                : [Double.pi / 4]
            for q in 0..<4 {
                for b in boundaries {
                    let angle = Double(q) * quarter + b
                    var line = Path()
                    line.move(to: onCircle(half * 1.2, angle))
                    line.addLine(to: onCircle(radius, angle))
                    context.stroke(line, with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: lineWidth, dash: [5, 7]))
                }
            }
        }

        // Play/Pause, under the pad.
        let playCenter = CGPoint(x: center.x, y: diameter * 1.11)
        let playRadius = diameter * 0.075
        let pressColor = frame.isLong ? hot : accent
        if frame.pressed == .playPause {
            context.fill(circle(playCenter, playRadius), with: .color(pressColor.opacity(0.75)))
        }
        context.stroke(circle(playCenter, playRadius), with: .color(.white.opacity(0.38)), lineWidth: lineWidth)
        let symbol = context.resolve(
            Text(Image(systemName: "playpause.fill"))
                .font(.system(size: playRadius * 0.9, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
        )
        context.draw(symbol, at: playCenter)

        // A click.
        if let pressed = frame.pressed, pressed != .playPause {
            if pressed == .select {
                context.fill(circle(center, inner * 0.55), with: .color(pressColor.opacity(0.55)))
            } else {
                let direction: Double
                switch pressed {
                case .right: direction = 0
                case .down: direction = .pi / 2
                case .left: direction = .pi
                default: direction = -.pi / 2
                }
                // The ring between the touch surface and the edge, around the direction.
                var segment = Path()
                let steps = 24
                let outer = (0...steps).map { onCircle(radius - lineWidth, direction - 0.6 + 1.2 * Double($0) / Double(steps)) }
                let innerEdge = (0...steps).reversed().map { onCircle(inner + lineWidth, direction - 0.6 + 1.2 * Double($0) / Double(steps)) }
                segment.addLines(outer + innerEdge)
                segment.closeSubpath()
                context.fill(segment, with: .color(pressColor.opacity(0.55)))
            }
        }

        // A long press or a held finger filling up.
        if let progress = frame.progress, progress > 0 {
            let ring = arc(radius + lineWidth * 3.5, from: -.pi / 2, to: -.pi / 2 + progress * 2 * .pi)
            context.stroke(ring, with: .color(hot), style: StrokeStyle(lineWidth: lineWidth * 4, lineCap: .round))
        }

        // A tap.
        if let ripple = frame.ripple {
            let r = radius * (0.08 + 0.32 * ripple.phase)
            context.stroke(circle(point(ripple.center), r), with: .color(accent.opacity(max(0, 1 - ripple.phase))), lineWidth: lineWidth * 2.5)
        }

        // The finger and where it went.
        let trail = frame.trail
        if trail.count > 1 {
            for i in 1..<trail.count {
                var segment = Path()
                segment.move(to: point(trail[i - 1]))
                segment.addLine(to: point(trail[i]))
                let alpha = 0.15 + 0.75 * Double(i) / Double(trail.count)
                context.stroke(segment, with: .color(accent.opacity(alpha)), style: StrokeStyle(lineWidth: lineWidth * 3.5, lineCap: .round))
            }
        }
        if let finger = frame.finger {
            let dot = circle(point(finger), diameter * 0.045)
            context.fill(dot, with: .color(.white))
            context.stroke(dot, with: .color(accent), lineWidth: lineWidth * 2)
        }
    }
}

/// One gesture, looping (from `start`, so a fresh recognition plays from the beginning).
struct AnimatedGesturePad: View {
    let gesture: RemoteGesture
    var start: Date = .distantPast

    var body: some View {
        TimelineView(.animation) { timeline in
            let phase = timeline.date.timeIntervalSince(start) / GestureAnimation.loopDuration
            RemotePadCanvas(frame: GestureAnimation.frame(of: gesture, at: phase))
        }
    }
}

/// A kind of gesture, looping through its variants; `offset` keeps neighbouring cards apart.
struct AnimatedGestureFamilyPad: View {
    let family: GestureFamily
    var offset: Double = 0
    var showsVariant = true

    var body: some View {
        TimelineView(.animation) { timeline in
            let current = family.variant(at: timeline.date.timeIntervalSinceReferenceDate + offset)
            VStack(spacing: 10) {
                RemotePadCanvas(frame: GestureAnimation.frame(of: current.gesture, at: current.phase))
                if showsVariant {
                    Text(current.gesture.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }
}
