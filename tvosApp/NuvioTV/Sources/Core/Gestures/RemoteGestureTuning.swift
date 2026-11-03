import Foundation

// Tried first on a real remote in a small test app (Gesture Lab).

/// Every threshold the recognizer uses (the values tried on a remote).
/// Pad positions are in pad units (the surface is 2 wide, −1…1); swipe and
/// tap movement in points of the system's own (UIKit) touch movement.
struct RemoteGestureTuning: Codable, Equatable, Sendable {
    /// Longest gap from letting go of the first click (or tap) to the second
    /// one that still makes a double.
    var doubleWindow: Double = 0.35
    /// A press held this long is a long press.
    var longPress: Double = 0.50
    /// Shortest swipe, in UIKit points.
    var swipeMinPoints: Double = 250
    /// A swipe at least this long (UIKit points) is a long swipe.
    var swipeLongPoints: Double = 900
    /// Slower movements are not swipes.
    var swipeMaxDuration: Double = 1.0
    /// There and back: the way out must be at least this long (pad units);
    /// the way back at least half of it.
    var swipeBackMinLength: Double = 0.60
    /// There and back may take this long.
    var swipeBackMaxDuration: Double = 2.5
    /// A light tap is shorter than this…
    var tapMaxDuration: Double = 0.40
    /// …and moves less than this (UIKit points).
    var tapMaxMovePoints: Double = 60
    /// Touches farther from the middle than this are in one of the directions.
    var sideThreshold: Double = 0.20
    /// Corners (left top, right bottom…) as well as the four sides.
    var cornerTouches: Bool = true
    /// How wide a corner is, in degrees around the diagonal; the rest goes
    /// to the nearest side.
    var cornerWidth: Double = 40
    /// A still finger this long (without a click) is a hold.
    var holdMinDuration: Double = 0.50
    /// How far the finger may wander during a hold (pad units).
    var holdMaxSpread: Double = 0.30
    /// Turn needed for a circle, in degrees.
    var circleDegrees: Double = 300
    /// The finger must stay at least this far from the middle while circling.
    var circleMinRadius: Double = 0.45
    /// A touch this close (before or after) to a click belongs to the click:
    /// clicking on the edge is no swipe and no tap.
    var clickGuard: Double = 0.15
    /// Pad positions this long before the lift are dropped: they slide
    /// towards the middle as the finger comes off.
    var liftTrim: Double = 0.07
    /// A drawing this close to a custom shape (mean distance, the shape's size being 1) is that
    /// shape.
    var customShapeDistance: Double = 0.15

    init() {}

    private enum CodingKeys: String, CodingKey {
        case doubleWindow, longPress, swipeMinPoints, swipeLongPoints, swipeMaxDuration
        case swipeBackMinLength, swipeBackMaxDuration
        case tapMaxDuration, tapMaxMovePoints, circleDegrees, circleMinRadius
        /// Saved under a new name: the old saved 0.30 is left behind, so the
        /// smaller middle (0.20) applies after the update.
        case sideThreshold = "centerSize"
        case cornerTouches, cornerWidth, holdMinDuration, holdMaxSpread
        case clickGuard, liftTrim
        case customShapeDistance
    }

    /// Saved settings from an older version: what it has is kept, what is new
    /// (or renamed) starts at its default, so an update never resets everything.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read(_ key: CodingKeys, _ fallback: Double) -> Double {
            (try? c.decodeIfPresent(Double.self, forKey: key)) ?? fallback
        }
        doubleWindow = read(.doubleWindow, doubleWindow)
        longPress = read(.longPress, longPress)
        swipeMinPoints = read(.swipeMinPoints, swipeMinPoints)
        swipeLongPoints = read(.swipeLongPoints, swipeLongPoints)
        swipeMaxDuration = read(.swipeMaxDuration, swipeMaxDuration)
        swipeBackMinLength = read(.swipeBackMinLength, swipeBackMinLength)
        swipeBackMaxDuration = read(.swipeBackMaxDuration, swipeBackMaxDuration)
        tapMaxDuration = read(.tapMaxDuration, tapMaxDuration)
        tapMaxMovePoints = read(.tapMaxMovePoints, tapMaxMovePoints)
        sideThreshold = read(.sideThreshold, sideThreshold)
        cornerWidth = read(.cornerWidth, cornerWidth)
        holdMinDuration = read(.holdMinDuration, holdMinDuration)
        holdMaxSpread = read(.holdMaxSpread, holdMaxSpread)
        cornerTouches = (try? c.decodeIfPresent(Bool.self, forKey: .cornerTouches)) ?? cornerTouches
        circleDegrees = read(.circleDegrees, circleDegrees)
        circleMinRadius = read(.circleMinRadius, circleMinRadius)
        clickGuard = read(.clickGuard, clickGuard)
        liftTrim = read(.liftTrim, liftTrim)
        customShapeDistance = read(.customShapeDistance, customShapeDistance)
    }
}
