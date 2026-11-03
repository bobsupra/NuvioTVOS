import Foundation

// Tried first on a real remote in a small test app (Gesture Lab).

/// A point on the remote's touch surface: x and y from −1 to 1, y pointing up
/// (GameController's absolute d-pad values).
struct PadPoint: Equatable, Codable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    func distance(to other: PadPoint) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// A button press the remote reports: the clickpad centre, the four
/// directions (ring clicks on the silver remote, edge taps on the black one)
/// and Play/Pause. Menu/Back is not a gesture: it keeps its own meaning.
enum RemoteButton: String, Codable, CaseIterable, Sendable {
    case select, up, down, left, right, playPause

    var title: String {
        switch self {
        case .select: return "center"
        case .up: return "up"
        case .down: return "down"
        case .left: return "left"
        case .right: return "right"
        case .playPause: return "Play/Pause"
        }
    }
}

enum ClickKind: String, Codable, Sendable {
    case single, double, long
}

enum SwipeDirection: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    var title: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        }
    }
}

/// Where a touch rested: one of eight directions from the middle, or the middle.
enum PadSide: String, Codable, CaseIterable, Sendable {
    case left, center, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .left: return "left"
        case .center: return "center"
        case .right: return "right"
        case .top: return "top"
        case .bottom: return "bottom"
        case .topLeft: return "top left"
        case .topRight: return "top right"
        case .bottomLeft: return "bottom left"
        case .bottomRight: return "bottom right"
        }
    }
}

/// Every gesture the recognizer tells apart.
enum RemoteGesture: Hashable, Codable, Sendable {
    case click(RemoteButton, ClickKind)
    case swipe(SwipeDirection, long: Bool)
    /// Out in one direction and back again (left–right or up–down).
    case swipeBack(SwipeDirection)
    case tap(PadSide, double: Bool)
    /// A finger resting still (no click) for a while.
    case hold(PadSide)
    case circle(clockwise: Bool)
    /// A shape drawn on the touchpad, made in the Gestures tab (`CustomGestureShape.id`).
    case custom(String)

    var title: String {
        switch self {
        case let .click(button, kind):
            switch kind {
            case .single: return "Click \(button.title)"
            case .double: return "Double click \(button.title)"
            case .long: return "Long press \(button.title)"
            }
        case let .swipe(direction, long):
            return (long ? "Long swipe " : "Swipe ") + direction.title
        case let .swipeBack(direction):
            return "Swipe \(direction.title) and back"
        case let .tap(side, double):
            return (double ? "Double tap " : "Tap ") + side.title
        case let .hold(side):
            return "Touch and hold " + side.title
        case let .circle(clockwise):
            return clockwise ? "Circle clockwise" : "Circle counterclockwise"
        case let .custom(id):
            return CustomGestureStore.shape(id: id)?.name ?? "Custom shape"
        }
    }

    /// The double version of a single click or tap, which the single one has
    /// to wait for when it is bound.
    var doubled: RemoteGesture? {
        switch self {
        case let .click(button, .single): return .click(button, .double)
        case let .tap(side, false): return .tap(side, double: true)
        default: return nil
        }
    }
}
