import Foundation

// What the remote's pad shows: the looping pictures of every gesture, the live
// trace while one is recorded, and the steps of recording one twice.

/// One picture of the pad: the finger and its trail, a pressed button, a filling ring, a ripple.
/// Positions in pad units (−1…1, y up).
struct GesturePadFrame: Equatable {
    var finger: PadPoint?
    /// Oldest first.
    var trail: [PadPoint] = []
    var pressed: RemoteButton?
    /// The press (or the still finger) has lasted long enough to count as long.
    var isLong = false
    /// 0…1: a long press or a held finger on its way to counting.
    var progress: Double?
    var ripple: Ripple?

    struct Ripple: Equatable {
        var center: PadPoint
        /// 0 just touched … 1 gone.
        var phase: Double
    }

    static let empty = GesturePadFrame()
}

extension PadSide {
    /// The places a touch can be in the player: the middle and the four sides (no corners).
    static let playerSides: [PadSide] = [.center, .left, .right, .top, .bottom]

    /// Where a touch on this side is drawn.
    var padPoint: PadPoint {
        switch self {
        case .center: return PadPoint(x: 0, y: 0)
        case .left: return PadPoint(x: -0.6, y: 0)
        case .right: return PadPoint(x: 0.6, y: 0)
        case .top: return PadPoint(x: 0, y: 0.6)
        case .bottom: return PadPoint(x: 0, y: -0.6)
        case .topLeft: return PadPoint(x: -0.45, y: 0.45)
        case .topRight: return PadPoint(x: 0.45, y: 0.45)
        case .bottomLeft: return PadPoint(x: -0.45, y: -0.45)
        case .bottomRight: return PadPoint(x: 0.45, y: -0.45)
        }
    }
}

extension SwipeDirection {
    var unit: PadPoint {
        switch self {
        case .left: return PadPoint(x: -1, y: 0)
        case .right: return PadPoint(x: 1, y: 0)
        case .up: return PadPoint(x: 0, y: 1)
        case .down: return PadPoint(x: 0, y: -1)
        }
    }
}

/// The looping picture of a gesture: `frame(of:at:)` with the loop's phase 0…1.
enum GestureAnimation {
    /// One loop, in seconds.
    static let loopDuration: Double = 2.2

    static func frame(of gesture: RemoteGesture, at phase: Double) -> GesturePadFrame {
        let t = phase - phase.rounded(.down)
        switch gesture {
        case let .click(button, kind):
            return click(button, kind, t)
        case let .swipe(direction, long):
            let from = long ? -0.7 : -0.2
            let to = long ? 0.75 : 0.3
            let (start, length, visible) = long ? (0.15, 0.45, 0.10..<0.75) : (0.20, 0.25, 0.15..<0.60)
            let path = { (time: Double) -> PadPoint in
                let k = ease(clamp((time - start) / length))
                return scaled(direction.unit, by: from + (to - from) * k)
            }
            return traced(path, t, visible: visible, trailSteps: long ? 12 : 8)
        case let .swipeBack(direction):
            let path = { (time: Double) -> PadPoint in
                let k = clamp((time - 0.15) / 0.55)
                return scaled(direction.unit, by: 0.65 * sin(k * .pi))
            }
            return traced(path, t, visible: 0.10..<0.80, trailSteps: 10)
        case let .tap(side, double):
            let starts = double ? [0.20, 0.42] : [0.25]
            for start in starts.reversed() where t >= start && t < start + 0.32 {
                return GesturePadFrame(
                    finger: t < start + 0.08 ? side.padPoint : nil,
                    ripple: GesturePadFrame.Ripple(center: side.padPoint, phase: (t - start) / 0.32)
                )
            }
            return .empty
        case let .hold(side):
            guard t >= 0.15, t < 0.80 else { return .empty }
            let progress = clamp((t - 0.15) / 0.5)
            return GesturePadFrame(finger: side.padPoint, isLong: progress >= 1, progress: progress)
        case let .circle(clockwise):
            let path = { (time: Double) -> PadPoint in
                let k = clamp((time - 0.10) / 0.70)
                // From the top; clockwise turns right first (y up, so the angle falls).
                let angle = Double.pi / 2 + (clockwise ? -1 : 1) * k * 2 * .pi * 0.92
                return PadPoint(x: 0.6 * cos(angle), y: 0.6 * sin(angle))
            }
            return traced(path, t, visible: 0.08..<0.85, trailSteps: 18)
        case let .custom(id):
            guard let drawing = CustomGestureStore.shape(id: id)?.drawings.first else { return .empty }
            return customFrame(drawing, t)
        }
    }

    /// A shape of one's own, drawn along its first drawing (normalized: size 1, so ×1.2 on the pad).
    static func customFrame(_ drawing: [PadPoint], _ t: Double) -> GesturePadFrame {
        guard drawing.count > 1 else { return .empty }
        let path = { (time: Double) -> PadPoint in
            let position = clamp((time - 0.10) / 0.65) * Double(drawing.count - 1)
            let index = min(Int(position), drawing.count - 2)
            let k = position - Double(index)
            let a = drawing[index], b = drawing[index + 1]
            return PadPoint(x: (a.x + (b.x - a.x) * k) * 1.2, y: (a.y + (b.y - a.y) * k) * 1.2)
        }
        return traced(path, t, visible: 0.08..<0.85, trailSteps: 24)
    }

    /// A drawing as a still picture (the whole shape as a trail), for the list of shapes.
    static func still(_ drawing: [PadPoint]) -> GesturePadFrame {
        GesturePadFrame(finger: drawing.last.map { PadPoint(x: $0.x * 1.2, y: $0.y * 1.2) },
                        trail: drawing.map { PadPoint(x: $0.x * 1.2, y: $0.y * 1.2) })
    }

    private static func click(_ button: RemoteButton, _ kind: ClickKind, _ t: Double) -> GesturePadFrame {
        switch kind {
        case .single:
            return GesturePadFrame(pressed: (0.30..<0.45).contains(t) ? button : nil)
        case .double:
            let down = (0.25..<0.35).contains(t) || (0.45..<0.55).contains(t)
            return GesturePadFrame(pressed: down ? button : nil)
        case .long:
            guard t >= 0.15, t < 0.80 else { return .empty }
            let progress = clamp((t - 0.15) / 0.45)
            return GesturePadFrame(pressed: button, isLong: progress >= 1, progress: progress)
        }
    }

    private static func traced(
        _ path: (Double) -> PadPoint,
        _ t: Double,
        visible: Range<Double>,
        trailSteps: Int
    ) -> GesturePadFrame {
        guard visible.contains(t) else { return .empty }
        let trail = (0...trailSteps).reversed().compactMap { step -> PadPoint? in
            let time = t - Double(step) * 0.025
            return time >= visible.lowerBound ? path(time) : nil
        }
        return GesturePadFrame(finger: path(t), trail: trail)
    }

    private static func scaled(_ point: PadPoint, by factor: Double) -> PadPoint {
        PadPoint(x: point.x * factor, y: point.y * factor)
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private static func ease(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}

/// The kinds of gesture, each with every variant it has (the Gesture overview's cards).
enum GestureFamily: String, CaseIterable, Identifiable {
    case click, doubleClick, longClick
    case swipe, longSwipe, swipeBack
    case tap, doubleTap, hold, circle
    /// Shapes of one's own (none until some are made).
    case custom

    var id: String { rawValue }

    /// The kinds with something in them (no custom card before there is a shape).
    static var shown: [GestureFamily] {
        allCases.filter { !$0.variants.isEmpty }
    }

    var title: String {
        switch self {
        case .click: return "Click"
        case .doubleClick: return "Double click"
        case .longClick: return "Long press"
        case .swipe: return "Swipe"
        case .longSwipe: return "Long swipe"
        case .swipeBack: return "Swipe and back"
        case .tap: return "Tap"
        case .doubleTap: return "Double tap"
        case .hold: return "Touch and hold"
        case .circle: return "Circle"
        case .custom: return "Custom"
        }
    }

    var variants: [RemoteGesture] {
        switch self {
        case .click: return RemoteButton.allCases.map { .click($0, .single) }
        case .doubleClick: return RemoteButton.allCases.map { .click($0, .double) }
        case .longClick: return RemoteButton.allCases.map { .click($0, .long) }
        case .swipe: return SwipeDirection.allCases.map { .swipe($0, long: false) }
        case .longSwipe: return SwipeDirection.allCases.map { .swipe($0, long: true) }
        case .swipeBack: return SwipeDirection.allCases.map { .swipeBack($0) }
        case .tap: return PadSide.playerSides.map { .tap($0, double: false) }
        case .doubleTap: return PadSide.playerSides.map { .tap($0, double: true) }
        case .hold: return PadSide.playerSides.map { .hold($0) }
        case .circle: return [.circle(clockwise: true), .circle(clockwise: false)]
        case .custom: return PlayerGestureSettings.activeShapes().map { .custom($0.id) }
        }
    }

    /// Which variant a looping card shows at `time` (seconds), and how far into its loop.
    func variant(at time: Double) -> (gesture: RemoteGesture, phase: Double) {
        let variants = self.variants
        let loops = max(time, 0) / GestureAnimation.loopDuration
        guard !variants.isEmpty else { return (.custom(""), loops - loops.rounded(.down)) }
        let index = Int(loops.rounded(.down)) % variants.count
        return (variants[index], loops - loops.rounded(.down))
    }
}

/// What a gesture does during playback now.
enum PlayerGestureMeaning: Equatable {
    case action(PlayerGestureAction)
    case builtIn(PlayerBuiltInGesture)
    case free

    init(of gesture: RemoteGesture, in bindings: PlayerGestureBindings) {
        if let action = bindings.action(for: gesture) {
            self = .action(action)
        } else if let builtIn = PlayerBuiltInGesture.action(for: gesture) {
            self = .builtIn(builtIn)
        } else {
            self = .free
        }
    }

    var title: String {
        switch self {
        case let .action(action): return action.title
        case let .builtIn(builtIn): return "player: \(builtIn.title)"
        case .free: return "free"
        }
    }
}

/// Recording a gesture: done twice, so a gesture that came out other than meant isn't saved.
struct GestureRecordingSession: Equatable {
    enum Step: Equatable {
        case first
        case confirm(RemoteGesture)
        /// The second didn't match; the next gesture starts over.
        case mismatch(first: RemoteGesture, second: RemoteGesture)
        case done(RemoteGesture)
    }

    private(set) var step: Step = .first

    @discardableResult
    mutating func record(_ gesture: RemoteGesture) -> Step {
        switch step {
        case .first, .mismatch:
            step = .confirm(gesture)
        case let .confirm(first):
            step = first == gesture ? .done(gesture) : .mismatch(first: first, second: gesture)
        case .done:
            break
        }
        return step
    }
}

/// The live picture while recording: where the finger is and was, which button is down and for
/// how long, and what that looks like so far. Fed the capture's input; asked at drawing time.
final class GestureLiveTrace {
    private var tuning: RemoteGestureTuning
    private var touching = false
    private var touchStart: TimeInterval = 0
    private var points: [(time: TimeInterval, point: PadPoint)] = []
    private var movement: TouchMovement?
    private var press: (button: RemoteButton, since: TimeInterval)?
    /// After a lift the trail fades out.
    private var liftTime: TimeInterval?
    /// The pad reported (0, 0): it is letting go, and what it reports after is no place.
    private var padLifted = false
    private var ripple: (center: PadPoint, time: TimeInterval)?

    static let fadeOut: TimeInterval = 0.6
    static let rippleDuration: TimeInterval = 0.35
    static let maxPoints = 90

    init(tuning: RemoteGestureTuning = RemoteGestureTuning()) {
        self.tuning = tuning
    }

    func setTuning(_ tuning: RemoteGestureTuning) {
        self.tuning = tuning
    }

    func handle(_ event: InputEvent) {
        switch event {
        case let .touchBegan(time):
            touching = true
            touchStart = time
            liftTime = nil
            padLifted = false
            movement = nil
            // The pad reports where the finger landed just before the touch begins.
            points = points.filter { $0.time >= time - 0.05 }
        case let .touchMoved(time, point):
            if point.x == 0, point.y == 0 {
                if touching { padLifted = true }
                return
            }
            // The first position of a touch has only x (y exactly 0): it is no place yet.
            guard !padLifted, point.y != 0 else { return }
            points.append((time, point))
            if points.count > Self.maxPoints { points.removeFirst(points.count - Self.maxPoints) }
        case let .touchTranslation(_, dx, dy):
            if touching { movement = TouchMovement(dx: dx, dy: dy) }
        case let .touchEnded(time):
            guard touching else { return }
            touching = false
            liftTime = time
            // As the finger comes off, the positions slide towards the middle: not where it was.
            let kept = points.filter { $0.time <= time - tuning.liftTrim }
            if !kept.isEmpty { points = kept }
            let short = time - touchStart <= tuning.tapMaxDuration
            let still = (movement.map { hypot($0.dx, $0.dy) } ?? 0) <= tuning.tapMaxMovePoints
            if short, still, press == nil, let center = Self.median(points.map { $0.point }) {
                ripple = (center, time)
            }
        case let .pressBegan(time, button):
            press = (button, time)
        case let .pressEnded(_, button):
            if press?.button == button { press = nil }
        case .tick:
            break
        }
    }

    /// The recognizer's cleaned positions of the touch that just ended (drawn instead of the raw ones).
    func handle(_ summary: TouchSummary) {
        guard !touching, !summary.points.isEmpty, let lift = liftTime else { return }
        let step = summary.duration / Double(max(summary.points.count - 1, 1))
        let start = lift - summary.duration
        points = summary.points.enumerated().map { (time: start + Double($0.offset) * step, point: $0.element) }
        if let ripple, let center = Self.median(summary.points) {
            self.ripple = (center, ripple.time)
        }
    }

    /// Where a touch was, as the recognizer reads it: the middle value of x and of y.
    static func median(_ points: [PadPoint]) -> PadPoint? {
        guard !points.isEmpty else { return nil }
        let xs = points.map(\.x).sorted(), ys = points.map(\.y).sorted()
        return PadPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])
    }

    func frame(at now: TimeInterval) -> GesturePadFrame {
        var frame = GesturePadFrame()
        let fading = liftTime.map { now - $0 } ?? 0
        if touching || fading < Self.fadeOut {
            frame.trail = points.map { $0.point }
            if touching { frame.finger = points.last?.point }
        }
        if let press {
            frame.pressed = press.button
            let held = now - press.since
            frame.progress = GestureAnimation.clamp(held / tuning.longPress)
            frame.isLong = held >= tuning.longPress
        } else if touching, isStill {
            let held = now - touchStart
            if held > 0.15 {
                frame.progress = GestureAnimation.clamp(held / tuning.holdMinDuration)
                frame.isLong = held >= tuning.holdMinDuration
            }
        }
        if let ripple, now - ripple.time < Self.rippleDuration {
            frame.ripple = GesturePadFrame.Ripple(center: ripple.center, phase: (now - ripple.time) / Self.rippleDuration)
        }
        return frame
    }

    /// What it looks like so far, or nil when nothing is going on.
    func status(at now: TimeInterval) -> String? {
        if let press {
            return now - press.since >= tuning.longPress
                ? "Long press \(press.button.title)"
                : "Pressing \(press.button.title)…"
        }
        guard touching else { return nil }
        if let movement, let direction = Self.direction(of: movement, minimum: tuning.swipeMinPoints) {
            let long = hypot(movement.dx, movement.dy) >= tuning.swipeLongPoints
            return (long ? "Long swipe " : "Swipe ") + direction.title + "…"
        }
        if isStill, now - touchStart >= tuning.holdMinDuration {
            return "Touch and hold…"
        }
        return "Finger on the pad…"
    }

    private var isStill: Bool {
        (movement.map { hypot($0.dx, $0.dy) } ?? 0) <= tuning.tapMaxMovePoints
    }

    static func direction(of movement: TouchMovement, minimum: Double) -> SwipeDirection? {
        guard hypot(movement.dx, movement.dy) >= minimum else { return nil }
        if abs(movement.dx) >= abs(movement.dy) {
            return movement.dx > 0 ? .right : .left
        }
        return movement.dy > 0 ? .up : .down
    }
}
