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
    @State private var activeSince: Date?

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
            TimelineView(.animation(minimumInterval: nil, paused: !moving)) { context in
                let elapsed = activeSince.map { context.date.timeIntervalSince($0) } ?? 0
                let scrolled = moving && elapsed >= Self.startDelay
                line(
                    boxWidth: box.size.width,
                    scrolled: scrolled,
                    offset: scrolled ? Self.position(elapsed: elapsed, distance: overflow + Self.edgeFade) : 0
                )
            }
        }
        .frame(height: Self.lineHeight(size: size, weight: weight))
        .onChange(of: isActive, initial: true) { _, active in
            activeSince = active ? Date() : nil
        }
    }

    @ViewBuilder
    private func line(boxWidth: CGFloat, scrolled: Bool, offset: CGFloat) -> some View {
        ZStack(alignment: scrolled ? .leading : alignment) {
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
        .mask {
            if scrolled {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: offset > 0 ? Self.edgeFade : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.edgeFade)
                }
            } else {
                Rectangle()
            }
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

    /// The width of `text` on one line in the system font, as SwiftUI draws `.system(size:weight:)`.
    static func width(of text: String, size: CGFloat, weight: Font.Weight) -> CGFloat {
        let font = UIFont.systemFont(ofSize: size, weight: uiWeight(weight))
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
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
