import SwiftUI
import UIKit

/// Nuvio Branding: the profile loading screen drawn the way the Android TV
/// app's `StartupSplashScreen` draws it.
///
/// - Background: the profile's background image filling the screen when it
///   has one; otherwise Android's two gradients tinted with the profile
///   colour over `#121212`.
/// - The standard Nuvio wordmark (colourful play mark and "nuvio"), 48 dp tall.
/// - Android's `LoadingIndicator` arc, 48 dp, in the theme's accent colour,
///   32 dp below the wordmark.
///
/// Android TV lays out 1080p at 2x density, so 1 dp is 2 points here.
/// Android only switches to another wordmark for its supporter themes (Gold,
/// Jade, Rose Gold, Arctic Blue, Graphite), none of which exist on tvOS, so
/// every tvOS theme uses the default wordmark, as Android does for them.
struct ProfileLoadingSplash: View {
    let profile: Profile?
    let profileColor: Color

    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue

    private static let dp: CGFloat = 2
    private static let baseBackground = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255)
    private static let elevatedBackground = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x1E / 255)

    private var backgroundURL: URL? {
        ProfileBackgroundCatalogStore.shared.effectiveBackgroundURL(
            backgroundUrl: profile?.profileBackgroundUrl,
            backgroundId: profile?.profileBackgroundId
        )
    }

    var body: some View {
        ZStack {
            Color.black

            if let url = backgroundURL {
                backgroundImage(url)
            } else {
                gradientBackground
            }

            VStack(spacing: 32 * Self.dp) {
                Image("NuvioWordmark")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(height: 48 * Self.dp)
                    .accessibilityLabel(Text("Nuvio"))
                NuvioLoadingIndicator(color: SettingsAccent.color(for: theme))
                    .frame(width: 48 * Self.dp, height: 48 * Self.dp)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func backgroundImage(_ url: URL) -> some View {
        Group {
            if Self.isGIF(url) {
                AnimatedRemoteGIFView(urlString: url.absoluteString, contentMode: .scaleAspectFill, maxPixelSize: 1920)
            } else {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        gradientBackground
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var gradientBackground: some View {
        let top = Self.blend(Self.elevatedBackground, profileColor, 0.3)
        let mid = Self.blend(Self.baseBackground, profileColor, 0.14)
        return ZStack {
            LinearGradient(
                stops: [
                    .init(color: top, location: 0),
                    .init(color: mid, location: 0.42),
                    .init(color: Self.baseBackground, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: profileColor.opacity(0.26), location: 0),
                    .init(color: profileColor.opacity(0.08), location: 0.45),
                    .init(color: .clear, location: 0.72),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private static func isGIF(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "gif" { return true }
        let query = url.query?.lowercased() ?? ""
        return query.contains("format=gif") || query.contains("image/gif")
    }

    /// Compose's `lerp(Color, Color, fraction)` on sRGB components.
    private static func blend(_ from: Color, _ to: Color, _ fraction: CGFloat) -> Color {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard UIColor(from).getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              UIColor(to).getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return from }
        let f = max(0, min(1, fraction))
        return Color(
            red: Double(r1 + (r2 - r1) * f),
            green: Double(g1 + (g2 - g1) * f),
            blue: Double(b1 + (b2 - b1) * f),
            opacity: Double(a1 + (a2 - a1) * f)
        )
    }
}

/// Android Nuvio's `LoadingIndicator`: a round-capped arc whose head and tail
/// chase each other around the circle over a 60-frame, 2-second loop, with
/// `CubicBezierEasing(0.333, 0, 0.667, 1)`.
struct NuvioLoadingIndicator: View {
    var color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            let frame = seconds.truncatingRemainder(dividingBy: 2) / 2 * 60
            Canvas { canvas, size in
                let scale = min(size.width, size.height) * 0.75 / 350
                let radius = 150 * scale
                let start = Self.lerp(0, 99, Self.ease(Self.clamp((frame - 10) / 50)))
                let end = Self.lerp(1, 100, Self.ease(Self.clamp(frame / 50)))
                let startAngle = -90 + frame / 60 * 363 + start * 3.6
                let sweep = (end - start) * 3.6
                var arc = Path()
                arc.addArc(
                    center: CGPoint(x: size.width / 2, y: size.height / 2),
                    radius: radius,
                    startAngle: .degrees(startAngle),
                    endAngle: .degrees(startAngle + sweep),
                    clockwise: false
                )
                canvas.stroke(arc, with: .color(color), style: StrokeStyle(lineWidth: 50 * scale, lineCap: .round))
            }
        }
        .accessibilityLabel(Text(L10n.string("loading", fallback: "Loading")))
    }

    private static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// Solves the cubic Bézier (0,0) (0.333,0) (0.667,1) (1,1) for x, returns y.
    private static func ease(_ x: Double) -> Double {
        func bezier(_ t: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if bezier(mid, 0.333, 0.667) < x { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, 0, 1)
    }
}
