import SwiftUI
import UIKit

/// Removal effect for Continue Watching: the focused card breaks into dust that
/// drifts up and to the right, starting at its top-right corner, before the
/// card is actually removed and the row closes the gap.
///
/// The card is captured from the screen as it is shown (still focused and
/// lifted), hidden, and replaced by an overlay that draws the capture and its
/// particles. With Reduce Motion on, or when no card can be captured, the
/// removal runs at once.
@MainActor
final class CardDisintegration: ObservableObject {
    static let shared = CardDisintegration()

    /// Length of the dissolve, from the first particle leaving to the last one fading.
    static let duration: TimeInterval = 1.0
    /// Smallest side of one particle cell in points.
    private static let minCellSize: CGFloat = 5
    /// Most particles one card makes. Larger cards get larger cells, so a
    /// dissolve costs about the same to draw whatever the card's size.
    static let maxParticles = 1500

    struct Particle {
        let cell: CGRect
        let color: Color
        /// 0 at the top-right corner, 1 at the bottom-left: the order cells leave in.
        let start: Double
        let direction: CGVector
        let distance: CGFloat
    }

    struct Run: Identifiable {
        let id = UUID()
        let image: Image
        /// Where the card was on screen, in window coordinates.
        let frame: CGRect
        let particles: [Particle]
        let startDate: Date
    }

    @Published private(set) var runs: [Run] = []
    /// Content IDs whose card is hidden while its dust is shown.
    @Published private(set) var hiddenContentIds: Set<String> = []
    /// Where each removable card is on screen, in window coordinates, as the
    /// rows report it. Not published: it changes on every scroll and nothing
    /// draws from it.
    private var cardFrames: [String: CGRect] = [:]

    /// Settings → Appearance → Continue Watching Perish Animation. The switch
    /// saves to the active profile's settings, like the other Appearance
    /// switches, so it is read from there.
    static func perishAnimationEnabled(in defaults: UserDefaults = ProfileSettings.current) -> Bool {
        defaults.bool(forKey: SettingsKey.continueWatchingPerishAnimation)
    }

    /// Records where the card for `contentId` is, or forgets it with `nil`.
    func setFrame(_ frame: CGRect?, for contentId: String) {
        cardFrames[contentId] = frame
    }

    /// Dissolves the card of `contentId`, then calls `removal`. The card is
    /// found by the frame its row reported: when a context menu asks for the
    /// removal, focus is still in the closing menu, not on the card.
    /// When `continueWatchingPerishAnimation` is disabled (the default),
    /// removal runs immediately.
    func dissolveCard(contentId: String, removal: @escaping () -> Void) {
        guard Self.perishAnimationEnabled() else {
            removal()
            return
        }
        dissolve(
            contentId: contentId,
            capture: UIAccessibility.isReduceMotionEnabled ? nil : cardFrames[contentId].flatMap(Self.capture(frame:)),
            removal: removal
        )
    }

    /// Dissolves `capture`, then calls `removal`. Without a capture the removal
    /// runs at once. While `contentId` is already dissolving, nothing happens:
    /// its removal is on the way, and running it twice would repeat the
    /// tracker updates.
    func dissolve(contentId: String, capture: Capture?, removal: @escaping () -> Void) {
        guard !hiddenContentIds.contains(contentId) else { return }
        guard let capture else {
            removal()
            return
        }
        let run = Run(
            image: Image(decorative: capture.image, scale: capture.scale),
            frame: capture.frame,
            particles: Self.particles(from: capture.image, frame: capture.frame),
            startDate: Date()
        )
        hiddenContentIds.insert(contentId)
        runs.append(run)

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) { [weak self] in
            removal()
            self?.runs.removeAll { $0.id == run.id }
            // Keep the card hidden until the row has dropped it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.hiddenContentIds.remove(contentId)
            }
        }
    }

    // MARK: Capture

    struct Capture {
        let image: CGImage
        let frame: CGRect
        let scale: CGFloat
    }

    private static func capture(frame cardFrame: CGRect) -> Capture? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        // The app's own window, not a menu's: right after a context menu closes,
        // the key window can still be the menu's.
        guard let window = windows.first(where: { !$0.isHidden && $0.windowLevel == .normal && $0.rootViewController != nil })
            ?? windows.first(where: \.isKeyWindow) else { return nil }

        let frame = cardFrame.intersection(window.bounds)
        // Only a card-sized area that is mostly on screen.
        guard !frame.isNull,
              frame.width >= 80, frame.height >= 60,
              frame.width * frame.height >= cardFrame.width * cardFrame.height * 0.5,
              frame.width <= window.bounds.width * 0.6,
              frame.height <= window.bounds.height * 0.6 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let image = UIGraphicsImageRenderer(bounds: frame, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        guard let cgImage = image.cgImage else { return nil }
        return Capture(image: cgImage, frame: frame, scale: format.scale)
    }

    // MARK: Particles

    /// One particle per cell, colored with the cell's average color. Cells that
    /// are transparent (the card's rounded corners) are skipped.
    static func particles(from image: CGImage, frame: CGRect) -> [Particle] {
        let area = max(frame.width * frame.height, 1)
        let cellSize = max(minCellSize, (area / CGFloat(maxParticles)).squareRoot())
        let columns = max(1, Int(frame.width / cellSize))
        let rows = max(1, Int(frame.height / cellSize))
        var pixels = [UInt8](repeating: 0, count: columns * rows * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: columns,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: columns * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
            return true
        }
        guard drawn else { return [] }

        let cellWidth = frame.width / CGFloat(columns)
        let cellHeight = frame.height / CGFloat(rows)
        var generator = SystemRandomNumberGenerator()
        var result: [Particle] = []
        result.reserveCapacity(columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let offset = (row * columns + column) * 4
                let alpha = Double(pixels[offset + 3]) / 255
                guard alpha > 0.1 else { continue }
                let color = Color(
                    .sRGB,
                    red: Double(pixels[offset]) / 255 / alpha,
                    green: Double(pixels[offset + 1]) / 255 / alpha,
                    blue: Double(pixels[offset + 2]) / 255 / alpha,
                    opacity: alpha
                )
                let u = (Double(column) + 0.5) / Double(columns)
                let v = (Double(row) + 0.5) / Double(rows)
                let jitter = Double.random(in: 0...1, using: &generator)
                // Up and to the right, spread by about 35 degrees either way.
                let angle = (-38.0 + Double.random(in: -35...35, using: &generator)) * .pi / 180
                result.append(Particle(
                    cell: CGRect(
                        x: CGFloat(column) * cellWidth,
                        y: CGFloat(row) * cellHeight,
                        width: cellWidth,
                        height: cellHeight
                    ),
                    color: color,
                    start: ((1 - u) + v) / 2 * 0.85 + jitter * 0.15,
                    direction: CGVector(dx: cos(angle), dy: sin(angle)),
                    distance: CGFloat.random(in: 70...220, using: &generator)
                ))
            }
        }
        return result
    }
}

/// Draws every running dissolve. Sits above the app's content and ignores input.
struct CardDisintegrationOverlay: View {
    @ObservedObject private var center = CardDisintegration.shared

    var body: some View {
        GeometryReader { proxy in
            if !center.runs.isEmpty {
                let origin = proxy.frame(in: .global).origin
                TimelineView(.animation) { timeline in
                    Canvas { context, _ in
                        context.translateBy(x: -origin.x, y: -origin.y)
                        for run in center.runs {
                            Self.draw(run, at: timeline.date, in: &context)
                        }
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Share of the run during which the sweep starts new cells; each cell then
    /// takes the rest of the run to fly off and fade.
    private static let sweepShare = 0.55

    private static func draw(_ run: CardDisintegration.Run, at date: Date, in context: inout GraphicsContext) {
        let progress = min(max(date.timeIntervalSince(run.startDate) / CardDisintegration.duration, 0), 1)
        let flight = 1 - sweepShare

        // The part of the card the sweep has not reached yet, drawn from the capture.
        var intact = Path()
        for particle in run.particles where particle.start * sweepShare >= progress {
            intact.addRect(particle.cell.offsetBy(dx: run.frame.minX, dy: run.frame.minY))
        }
        if !intact.isEmpty {
            var clipped = context
            clipped.clip(to: intact)
            clipped.draw(run.image, in: run.frame)
        }

        // Cells already let go, as fading dust.
        for particle in run.particles {
            let local = (progress - particle.start * sweepShare) / flight
            guard local > 0, local < 1 else { continue }
            let eased = 1 - pow(1 - local, 2)
            let travel = particle.distance * CGFloat(eased)
            let size = particle.cell.width * CGFloat(1 - 0.55 * local)
            let rect = CGRect(
                x: run.frame.minX + particle.cell.midX + particle.direction.dx * travel - size / 2,
                y: run.frame.minY + particle.cell.midY + particle.direction.dy * travel - size / 2,
                width: size,
                height: size
            )
            context.fill(
                Path(rect),
                with: .color(particle.color.opacity(pow(1 - local, 1.3)))
            )
        }
    }
}
