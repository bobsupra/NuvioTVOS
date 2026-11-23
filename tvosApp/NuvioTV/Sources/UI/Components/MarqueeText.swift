import SwiftUI
import UIKit

/// One line of text that shows its end when it doesn't fit: while `isActive` (the focused card),
/// after a moment it scrolls to the end, rests there, goes back, and again — as tvOS scrolls a
/// focused title. Inactive, or text that fits, is the usual one line ending in "…". Nothing moves
/// with Reduce Motion on (Settings → Accessibility → Motion).
///
/// Worked out from the clock rather than kept in state: the line's width comes from the font, the
/// box's from the layout, and where the text is from the time since the card got focus, so there
/// is nothing to measure late or to start and stop. Only the focused line redraws while it moves.
struct MarqueeText: View {
    let text: String
    let size: CGFloat
    let weight: Font.Weight
    let color: Color
    let isActive: Bool
    /// As `minimumScaleFactor`: the text shrinks this far before it counts as not fitting, and
    /// scrolls at that size.
    let minimumScaleFactor: CGFloat
    /// Where text that fits sits; scrolling text starts at the leading edge.
    let alignment: Alignment

    static let startDelay: TimeInterval = 1.2
    static let pointsPerSecond: CGFloat = 45
    static let restAtEnds: TimeInterval = 1.6
    static let returnDuration: TimeInterval = 0.6
    static let edgeFade: CGFloat = 14

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isScrolledPhase = false
    @State private var scrollOffset: CGFloat = 0
    @State private var isLeadingEdgeFaded = false

    private struct ScrollTaskKey: Equatable {
        let moving: Bool
        let overflow: CGFloat
        let text: String
        let size: CGFloat
        let weightValue: CGFloat
        let minimumScaleFactor: CGFloat
    }

    init(
        _ text: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        color: Color,
        isActive: Bool,
        minimumScaleFactor: CGFloat = 1,
        alignment: Alignment = .leading
    ) {
        self.text = text
        self.size = size
        self.weight = weight
        self.color = color
        self.isActive = isActive
        self.minimumScaleFactor = minimumScaleFactor
        self.alignment = alignment
    }

    var body: some View {
        let lineWidth = Self.width(of: text, size: size, weight: weight)
        GeometryReader { box in
            let overflow = Self.overflow(fullWidth: lineWidth, boxWidth: box.size.width, scale: minimumScaleFactor)
            let moving = isActive && overflow > 0 && !reduceMotion
            let scrolled = moving && isScrolledPhase
            let taskKey = ScrollTaskKey(
                moving: moving,
                overflow: overflow,
                text: text,
                size: size,
                weightValue: Self.uiWeight(weight).rawValue,
                minimumScaleFactor: minimumScaleFactor
            )
            line(
                boxWidth: box.size.width,
                scrolled: scrolled,
                offset: scrolled ? scrollOffset : 0,
                leadingFadeWidth: scrolled && isLeadingEdgeFaded ? Self.edgeFade : 0
            )
            .task(id: taskKey) {
                await runScrollLoop(moving: moving, overflow: overflow)
            }
            .onChange(of: moving) { _, isMoving in
                guard !isMoving else { return }
                var reset = Transaction(animation: nil)
                reset.disablesAnimations = true
                withTransaction(reset) {
                    isScrolledPhase = false
                    scrollOffset = 0
                    isLeadingEdgeFaded = false
                }
            }
        }
        .frame(height: Self.lineHeight(size: size, weight: weight))
    }

    @MainActor
    private func runScrollLoop(moving: Bool, overflow: CGFloat) async {
        var reset = Transaction(animation: nil)
        reset.disablesAnimations = true
        withTransaction(reset) {
            isScrolledPhase = false
            scrollOffset = 0
            isLeadingEdgeFaded = false
        }
        guard moving, overflow > 0 else { return }

        do {
            try await Task.sleep(nanoseconds: UInt64(Self.startDelay * 1_000_000_000))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        withTransaction(reset) {
            isScrolledPhase = true
            scrollOffset = 0
            isLeadingEdgeFaded = false
        }
        // Let SwiftUI install the un-offset fixed-width text before animating on Core Animation.
        do {
            try await Task.sleep(nanoseconds: 16_000_000)
        } catch {
            return
        }
        guard !Task.isCancelled else { return }

        let distance = overflow + Self.edgeFade
        let outDuration = Double(distance / Self.pointsPerSecond)

        while !Task.isCancelled {
            withAnimation(.linear(duration: outDuration)) {
                scrollOffset = distance
                isLeadingEdgeFaded = true
            }
            do {
                try await Task.sleep(nanoseconds: UInt64((outDuration + Self.restAtEnds) * 1_000_000_000))
            } catch {
                break
            }
            guard !Task.isCancelled else { break }

            withAnimation(.easeInOut(duration: Self.returnDuration)) {
                scrollOffset = 0
                isLeadingEdgeFaded = false
            }
            do {
                try await Task.sleep(nanoseconds: UInt64((Self.returnDuration + Self.restAtEnds) * 1_000_000_000))
            } catch {
                break
            }
        }
    }

    @ViewBuilder
    private func line(
        boxWidth: CGFloat,
        scrolled: Bool,
        offset: CGFloat,
        leadingFadeWidth: CGFloat
    ) -> some View {
        let textContent = ZStack(alignment: scrolled ? .leading : alignment) {
            if scrolled {
                Text(text)
                    .font(.system(size: size, weight: weight))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .scaleEffect(minimumScaleFactor, anchor: .leading)
                    .offset(x: -offset)
            } else {
                Text(text)
                    .font(.system(size: size, weight: weight))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(minimumScaleFactor)
            }
        }
        .frame(width: boxWidth, alignment: scrolled ? .leading : alignment)
        .clipped()

        if scrolled {
            textContent.mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: leadingFadeWidth)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.edgeFade)
                }
            }
        } else {
            textContent
        }
    }

    // MARK: Pure parts (tests)

    /// How far the text runs past its box at the size it scrolls at; 0 = it fits.
    static func overflow(fullWidth: CGFloat, boxWidth: CGFloat, scale: CGFloat) -> CGFloat {
        guard fullWidth > 0, boxWidth > 0 else { return 0 }
        return max(0, (fullWidth * scale - boxWidth).rounded(.up))
    }

    /// How far the text has scrolled `elapsed` seconds after the card got focus: still for
    /// `startDelay`, then out to `distance` at `pointsPerSecond`, a rest, back in
    /// `returnDuration`, a rest, and again.
    static func position(elapsed: TimeInterval, distance: CGFloat) -> CGFloat {
        guard distance > 0, elapsed > startDelay else { return 0 }
        let out = Double(distance / pointsPerSecond)
        let cycle = out + restAtEnds + returnDuration + restAtEnds
        let t = (elapsed - startDelay).truncatingRemainder(dividingBy: cycle)
        if t < out { return distance * CGFloat(t / out) }
        if t < out + restAtEnds { return distance }
        if t < out + restAtEnds + returnDuration {
            let progress = (t - out - restAtEnds) / returnDuration
            let eased = progress * progress * (3 - 2 * progress)
            return distance * CGFloat(1 - eased)
        }
        return 0
    }

    private static let widthCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 512
        return cache
    }()

    /// The width of `text` on one line in the system font, as SwiftUI draws `.system(size:weight:)`.
    static func width(of text: String, size: CGFloat, weight: Font.Weight) -> CGFloat {
        let resolvedWeight = uiWeight(weight)
        let cacheKey = "\(Int((size * 10).rounded()))|\(resolvedWeight.rawValue)|\(text)" as NSString
        if let cached = widthCache.object(forKey: cacheKey) {
            return CGFloat(cached.doubleValue)
        }
        let font = UIFont.systemFont(ofSize: size, weight: resolvedWeight)
        let measured = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        widthCache.setObject(NSNumber(value: Double(measured)), forKey: cacheKey)
        return measured
    }

    static func lineHeight(size: CGFloat, weight: Font.Weight) -> CGFloat {
        ceil(UIFont.systemFont(ofSize: size, weight: uiWeight(weight)).lineHeight)
    }

    private static func uiWeight(_ weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}
