import Foundation

// Tried first on a real remote in a small test app (Gesture Lab).

/// What the remote sent, with `ProcessInfo.systemUptime` times (the clock
/// UITouch and UIPress timestamps use).
enum InputEvent: Equatable, Sendable {
    /// The system (UIKit) says a finger is on the touch surface. Only this
    /// starts a touch; pad positions alone never do.
    case touchBegan(TimeInterval)
    /// Absolute finger position from GameController.
    case touchMoved(TimeInterval, PadPoint)
    /// The system's own movement since the touch began, in points, y up.
    /// Swipes and taps are measured with it: it has none of the pad's jumps.
    case touchTranslation(TimeInterval, dx: Double, dy: Double)
    case touchEnded(TimeInterval)
    case pressBegan(TimeInterval, RemoteButton)
    case pressEnded(TimeInterval, RemoteButton)
    /// Sent regularly (every frame), so pending decisions resolve.
    case tick(TimeInterval)
}

/// The system's movement of a touch, in points, y up.
struct TouchMovement: Equatable, Sendable {
    let dx: Double
    let dy: Double

    init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

/// How a touch went, for the log.
struct TouchSummary: Equatable, Sendable {
    let duration: TimeInterval
    /// Nil when the system reported no movement at all.
    let movement: TouchMovement?
    /// Cleaned pad positions: first and last, and all of them (to draw).
    let padStart: PadPoint?
    let padEnd: PadPoint?
    let points: [PadPoint]
    /// A click came with the touch, so it is no swipe or tap.
    let withClick: Bool
}

enum RecognizerOutput: Equatable, Sendable {
    /// `inputTime` is when the deciding input happened (release, lift);
    /// `decidedTime - inputTime` is the delay the recognizer added.
    case gesture(RemoteGesture, inputTime: TimeInterval, decidedTime: TimeInterval)
    case touchSummary(TouchSummary)
}

/// Turns raw remote input into gestures. One instance per test screen; feed
/// every event to `handle` and act on what it returns.
///
/// What the Siri Remote does that this has to cope with (seen on a device):
/// the pad reports where the finger landed about 20 ms before the system
/// says a touch began, and a finger that stays still reports nothing more;
/// that first position has y exactly 0 (x arrives first); when the finger
/// lifts, positions slide towards the middle and (0, 0) may come before the
/// touch ends; the system may end the touch around a click.
final class RemoteGestureRecognizer {
    var tuning: RemoteGestureTuning
    /// Whether a single click or tap has to wait `doubleWindow` for a second
    /// one: true when its double is in use. Otherwise singles come at once.
    var waitsForDouble: (RemoteGesture) -> Bool
    /// Shapes of one's own, looked for in every touch.
    var customShapes: [CustomGestureShape] = []

    // Touch
    private struct Sample {
        let time: TimeInterval
        let point: PadPoint
    }
    private var touchActive = false
    private var touchStart: TimeInterval = 0
    private var samples: [Sample] = []
    /// The pad reported (0, 0): later positions of this touch are noise.
    private var padLiftTime: TimeInterval?
    /// Positions that came before the system reported the touch.
    private var preSamples: [Sample] = []
    /// How long before the touch's start such a position still belongs to it.
    static let preTouchWindow: TimeInterval = 0.10
    private var movement: TouchMovement?
    private var pressDuringTouch = false
    private var lastPressEvent: TimeInterval = -.infinity
    private var lastTouchEnd: TimeInterval = -.infinity
    /// Positions this soon after a lift are the pad settling, not the next touch.
    static let liftSettleTime: TimeInterval = 0.08

    /// A finished touch waiting `clickGuard` in case a click turns up.
    private enum TouchKind {
        case swipe(SwipeDirection, long: Bool)
        case swipeBack(SwipeDirection)
        case tap(PadSide)
        case hold(PadSide)
        case circle(clockwise: Bool)
        case custom(String)
    }
    private var pendingTouch: (kind: TouchKind, start: TimeInterval, end: TimeInterval)?

    // Presses
    private var pressDown: [RemoteButton: TimeInterval] = [:]
    private var longHandled: Set<RemoteButton> = []
    /// A single click waiting for a possible second one; `time` is its release.
    private var pendingClick: (button: RemoteButton, time: TimeInterval)?
    /// A single tap waiting for a possible second one; `time` is its lift.
    private var pendingTap: (side: PadSide, time: TimeInterval)?

    init(tuning: RemoteGestureTuning = RemoteGestureTuning(), waitsForDouble: @escaping (RemoteGesture) -> Bool = { _ in true }) {
        self.tuning = tuning
        self.waitsForDouble = waitsForDouble
    }

    /// Drops everything in progress (leaving the screen).
    func reset() {
        touchActive = false
        samples = []
        preSamples = []
        padLiftTime = nil
        movement = nil
        pendingTouch = nil
        pressDown = [:]
        longHandled = []
        pendingClick = nil
        pendingTap = nil
    }

    func handle(_ event: InputEvent) -> [RecognizerOutput] {
        switch event {
        case let .touchBegan(time):
            return touchActive ? [] : beginTouch(at: time)
        case let .touchMoved(time, point):
            return move(to: point, at: time)
        case let .touchTranslation(_, dx, dy):
            if touchActive { movement = TouchMovement(dx: dx, dy: dy) }
            return []
        case let .touchEnded(time):
            return endTouch(at: time)
        case let .pressBegan(time, button):
            pressDown[button] = time
            lastPressEvent = time
            if touchActive { pressDuringTouch = true }
            // A click right after a touch: that touch was part of the click.
            if pendingTouch != nil { pendingTouch = nil }
            return []
        case let .pressEnded(time, button):
            lastPressEvent = time
            return endPress(button, at: time)
        case let .tick(time):
            return tick(at: time)
        }
    }

    // MARK: - Touch

    private func beginTouch(at time: TimeInterval) -> [RecognizerOutput] {
        touchActive = true
        touchStart = time
        // Where the finger landed came just before the system's touch.
        samples = preSamples.filter { $0.time >= time - Self.preTouchWindow }
        preSamples = []
        padLiftTime = nil
        movement = nil
        pressDuringTouch = !pressDown.isEmpty
        return []
    }

    private func move(to point: PadPoint, at time: TimeInterval) -> [RecognizerOutput] {
        if point.x == 0, point.y == 0 {
            if touchActive, padLiftTime == nil { padLiftTime = time }
            preSamples = []
            return []
        }
        guard touchActive else {
            // Kept for the touch the system is about to report, unless it is
            // the previous touch's lift still settling.
            guard time - lastTouchEnd >= Self.liftSettleTime else { return [] }
            preSamples.append(Sample(time: time, point: point))
            preSamples.removeAll { time - $0.time > 0.5 }
            return []
        }
        guard padLiftTime == nil else { return [] }
        samples.append(Sample(time: time, point: point))
        return []
    }

    /// Positions of the touch without the half first one and the lift slide.
    private func cleanedSamples(liftAt lift: TimeInterval) -> [Sample] {
        var range = samples
        // The first position has only x (y still 0) when y follows; alone it
        // is all there is, so it stays.
        if range.count > 1, let first = range.first?.point, (first.x == 0) != (first.y == 0) {
            range.removeFirst()
        }
        let cutoff = min(lift, padLiftTime ?? lift) - tuning.liftTrim
        let kept = range.filter { $0.time <= cutoff }
        // A very short touch may have nothing left: keep its first position.
        return kept.isEmpty ? Array(range.prefix(1)) : kept
    }

    private func endTouch(at time: TimeInterval) -> [RecognizerOutput] {
        guard touchActive else { return [] }
        touchActive = false
        preSamples = []
        lastTouchEnd = time
        let duration = time - touchStart
        let kept = cleanedSamples(liftAt: time)
        let points = kept.map(\.point)

        let withClick = pressDuringTouch || !pressDown.isEmpty || touchStart - lastPressEvent < tuning.clickGuard
        var outputs: [RecognizerOutput] = [.touchSummary(TouchSummary(
            duration: duration, movement: movement,
            padStart: points.first, padEnd: points.last, points: points, withClick: withClick))]
        guard !withClick, let kind = classify(duration: duration, samples: kept) else { return outputs }
        // A quick second touch: the first one goes out now.
        if let previous = pendingTouch {
            outputs += emitTouch(previous.kind, start: previous.start, end: previous.end, at: time)
        }
        pendingTouch = (kind, touchStart, time)
        return outputs
    }

    private func classify(duration: TimeInterval, samples: [Sample]) -> TouchKind? {
        let points = samples.map(\.point)
        // A shape of one's own first: it is checked not to look like a swipe or a circle.
        if let id = CustomGestureMatcher.match(points, shapes: customShapes, within: tuning.customShapeDistance) {
            return .custom(id)
        }
        if let clockwise = circle(points) { return .circle(clockwise: clockwise) }
        if duration <= tuning.swipeBackMaxDuration, let direction = thereAndBack(samples) {
            return .swipeBack(direction)
        }

        let moved = movement ?? padMovement(points)
        let dx = moved.dx, dy = moved.dy
        let major = max(abs(dx), abs(dy)), minor = min(abs(dx), abs(dy))
        if major >= tuning.swipeMinPoints, duration <= tuning.swipeMaxDuration, major >= minor * 1.5 {
            let direction: SwipeDirection = abs(dx) >= abs(dy)
                ? (dx > 0 ? .right : .left)
                : (dy > 0 ? .up : .down)
            return .swipe(direction, long: major >= tuning.swipeLongPoints)
        }
        if duration <= tuning.tapMaxDuration, major <= tuning.tapMaxMovePoints {
            return .tap(side(of: points))
        }
        if duration >= tuning.holdMinDuration, !points.isEmpty, Self.spread(of: points) <= tuning.holdMaxSpread {
            return .hold(side(of: points))
        }
        return nil
    }

    /// The way back must be at least this part of the way out…
    static let swipeBackReturn = 0.5
    /// …take at least this long (the lift slide is quicker)…
    static let swipeBackMinReturnTime: TimeInterval = 0.12
    /// …and point the other way (cosine of the angle between the two).
    static let swipeBackMaxCosine = -0.85

    /// Out along one axis and back: the turn is the position farthest from
    /// both ends together; the way out decides the direction.
    private func thereAndBack(_ samples: [Sample]) -> SwipeDirection? {
        guard let first = samples.first, let last = samples.last else { return nil }
        func reach(_ sample: Sample) -> Double {
            sample.point.distance(to: first.point) + sample.point.distance(to: last.point)
        }
        guard let turn = samples.max(by: { reach($0) < reach($1) }) else { return nil }
        let outX = turn.point.x - first.point.x, outY = turn.point.y - first.point.y
        let backX = last.point.x - turn.point.x, backY = last.point.y - turn.point.y
        let out = (outX * outX + outY * outY).squareRoot()
        let back = (backX * backX + backY * backY).squareRoot()
        guard out >= tuning.swipeBackMinLength, out > 0,
              back >= out * Self.swipeBackReturn, back > 0,
              last.time - turn.time >= Self.swipeBackMinReturnTime,
              max(abs(outX), abs(outY)) >= min(abs(outX), abs(outY)) * 1.5,
              (outX * backX + outY * backY) / (out * back) <= Self.swipeBackMaxCosine
        else { return nil }
        return abs(outX) >= abs(outY) ? (outX > 0 ? .right : .left) : (outY > 0 ? .up : .down)
    }

    /// How far the positions wander from their middle (largest distance from the median).
    static func spread(of points: [PadPoint]) -> Double {
        guard !points.isEmpty else { return 0 }
        let xs = points.map(\.x).sorted(), ys = points.map(\.y).sorted()
        let median = PadPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])
        return points.map { $0.distance(to: median) }.max() ?? 0
    }

    /// Without any system movement: the pad's own, at a rough 500 points per pad unit.
    private func padMovement(_ points: [PadPoint]) -> TouchMovement {
        guard let first = points.first, let last = points.last else { return TouchMovement(dx: 0, dy: 0) }
        return TouchMovement(dx: (last.x - first.x) * 500, dy: (last.y - first.y) * 500)
    }

    /// The direction of where the finger rested, or the middle when it stayed
    /// within `threshold` of it both ways. With corners, a touch within
    /// `cornerWidth / 2` degrees of a diagonal is that corner.
    static func side(of points: [PadPoint], threshold: Double,
                     corners: Bool = false, cornerWidth: Double = 40) -> PadSide {
        guard !points.isEmpty else { return .center }
        let xs = points.map(\.x).sorted(), ys = points.map(\.y).sorted()
        let x = xs[xs.count / 2], y = ys[ys.count / 2]
        guard max(abs(x), abs(y)) > threshold else { return .center }
        let degrees = atan2(abs(y), abs(x)) * 180 / .pi
        if corners, abs(degrees - 45) <= cornerWidth / 2 {
            switch (x < 0, y > 0) {
            case (true, true): return .topLeft
            case (false, true): return .topRight
            case (true, false): return .bottomLeft
            case (false, false): return .bottomRight
            }
        }
        if abs(y) > abs(x) { return y > 0 ? .top : .bottom }
        return x < 0 ? .left : .right
    }

    private func side(of points: [PadPoint]) -> PadSide {
        Self.side(of: points, threshold: tuning.sideThreshold,
                  corners: tuning.cornerTouches, cornerWidth: tuning.cornerWidth)
    }

    /// Clockwise or not, when the finger went far enough round the middle.
    private func circle(_ points: [PadPoint]) -> Bool? {
        var turned = 0.0
        var lastAngle: Double?
        for point in points {
            let radius = (point.x * point.x + point.y * point.y).squareRoot()
            guard radius >= tuning.circleMinRadius else {
                lastAngle = nil
                continue
            }
            let angle = atan2(point.y, point.x)
            if let lastAngle {
                var delta = angle - lastAngle
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                turned += delta
            }
            lastAngle = angle
        }
        guard abs(turned) >= tuning.circleDegrees * .pi / 180 else { return nil }
        return turned < 0
    }

    private func emitTouch(_ kind: TouchKind, start: TimeInterval, end: TimeInterval, at time: TimeInterval) -> [RecognizerOutput] {
        switch kind {
        case let .swipe(direction, long):
            return [.gesture(.swipe(direction, long: long), inputTime: end, decidedTime: time)]
        case let .swipeBack(direction):
            return [.gesture(.swipeBack(direction), inputTime: end, decidedTime: time)]
        case let .circle(clockwise):
            return [.gesture(.circle(clockwise: clockwise), inputTime: end, decidedTime: time)]
        case let .hold(side):
            return [.gesture(.hold(side), inputTime: end, decidedTime: time)]
        case let .custom(id):
            return [.gesture(.custom(id), inputTime: end, decidedTime: time)]
        case let .tap(side):
            return tap(side, start: start, end: end, at: time)
        }
    }

    private func tap(_ side: PadSide, start: TimeInterval, end: TimeInterval, at time: TimeInterval) -> [RecognizerOutput] {
        var outputs: [RecognizerOutput] = []
        if let pending = pendingTap {
            if pending.side == side, start - pending.time <= tuning.doubleWindow {
                pendingTap = nil
                return [.gesture(.tap(side, double: true), inputTime: end, decidedTime: time)]
            }
            outputs.append(.gesture(.tap(pending.side, double: false), inputTime: pending.time, decidedTime: time))
            pendingTap = nil
        }
        let single = RemoteGesture.tap(side, double: false)
        if let double = single.doubled, waitsForDouble(double) {
            pendingTap = (side, end)
        } else {
            outputs.append(.gesture(single, inputTime: end, decidedTime: time))
        }
        return outputs
    }

    // MARK: - Presses

    private func endPress(_ button: RemoteButton, at time: TimeInterval) -> [RecognizerOutput] {
        guard let down = pressDown.removeValue(forKey: button) else { return [] }
        // A long press went out while it was held.
        if longHandled.remove(button) != nil { return [] }

        var outputs: [RecognizerOutput] = []
        if let pending = pendingClick {
            // Double: the second press began soon after the first was released.
            if pending.button == button, down - pending.time <= tuning.doubleWindow {
                pendingClick = nil
                return [.gesture(.click(button, .double), inputTime: time, decidedTime: time)]
            }
            outputs.append(.gesture(.click(pending.button, .single), inputTime: pending.time, decidedTime: time))
            pendingClick = nil
        }
        let single = RemoteGesture.click(button, .single)
        if let double = single.doubled, waitsForDouble(double) {
            pendingClick = (button, time)
        } else {
            outputs.append(.gesture(single, inputTime: time, decidedTime: time))
        }
        return outputs
    }

    // MARK: - Time

    private func tick(at time: TimeInterval) -> [RecognizerOutput] {
        var outputs: [RecognizerOutput] = []

        for (button, down) in pressDown where !longHandled.contains(button) && time - down >= tuning.longPress {
            longHandled.insert(button)
            outputs.append(.gesture(.click(button, .long), inputTime: down + tuning.longPress, decidedTime: time))
        }

        if let pending = pendingTouch, time - pending.end >= tuning.clickGuard {
            pendingTouch = nil
            outputs += emitTouch(pending.kind, start: pending.start, end: pending.end, at: time)
        }

        // A single goes out once no second one can come: not while the same
        // button is down again (or a touch is under way) inside the window.
        if let pending = pendingClick, time - pending.time > tuning.doubleWindow {
            let secondUnderWay = pressDown[pending.button].map { $0 - pending.time <= tuning.doubleWindow } ?? false
            if !secondUnderWay {
                pendingClick = nil
                outputs.append(.gesture(.click(pending.button, .single), inputTime: pending.time, decidedTime: time))
            }
        }
        if let pending = pendingTap, time - pending.time > tuning.doubleWindow {
            let secondUnderWay = (touchActive && touchStart - pending.time <= tuning.doubleWindow)
                || (pendingTouch.map { $0.start - pending.time <= tuning.doubleWindow } ?? false)
            if !secondUnderWay {
                pendingTap = nil
                outputs.append(.gesture(.tap(pending.side, double: false), inputTime: pending.time, decidedTime: time))
            }
        }

        return outputs
    }
}
