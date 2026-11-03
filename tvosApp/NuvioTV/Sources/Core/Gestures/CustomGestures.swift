import Foundation

// Custom gestures: a shape drawn on the touchpad three times becomes a gesture
// of its own. A drawing is compared with the shapes point by point after both are brought to
// the same size and place, so where on the pad and how big it is drawn don't matter, but its
// orientation and the way it is drawn do (an L is not a Γ).

/// A shape someone drew three times.
struct CustomGestureShape: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// The three drawings, normalized (`CustomGestureMatcher.normalized`).
    var drawings: [[PadPoint]]
}

enum CustomGestureMatcher {
    /// Every drawing is resampled to this many evenly spaced points.
    static let pointCount = 32
    /// Shorter drawings (pad units, the pad is 2 wide) are taps or a resting finger.
    static let minLength = 0.8
    /// The next best shape this much farther away (or less) makes a match ambiguous.
    static let rivalMargin = 0.03

    /// The drawing resampled, its centre moved to (0, 0), and scaled so its larger extent is 1.
    static func normalized(_ points: [PadPoint]) -> [PadPoint]? {
        guard points.count >= 2, pathLength(points) >= minLength else { return nil }
        let resampled = resample(points, count: pointCount)
        let cx = resampled.map(\.x).reduce(0, +) / Double(resampled.count)
        let cy = resampled.map(\.y).reduce(0, +) / Double(resampled.count)
        let xs = resampled.map(\.x), ys = resampled.map(\.y)
        let extent = max((xs.max() ?? 0) - (xs.min() ?? 0), (ys.max() ?? 0) - (ys.min() ?? 0))
        guard extent > 0.0001 else { return nil }
        return resampled.map { PadPoint(x: ($0.x - cx) / extent, y: ($0.y - cy) / extent) }
    }

    /// Mean distance of the matching points of two normalized drawings.
    static func distance(_ a: [PadPoint], _ b: [PadPoint]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return zip(a, b).map { $0.distance(to: $1) }.reduce(0, +) / Double(a.count)
    }

    /// How far a normalized drawing is from a shape: from the closest of its drawings.
    static func distance(_ drawing: [PadPoint], to shape: CustomGestureShape) -> Double {
        shape.drawings.map { distance(drawing, $0) }.min() ?? .infinity
    }

    /// The shape this touch drew, when one is close enough and no other comes near it.
    static func match(_ points: [PadPoint], shapes: [CustomGestureShape], within limit: Double) -> String? {
        guard !shapes.isEmpty, let drawing = normalized(points) else { return nil }
        let scored = shapes
            .map { (id: $0.id, distance: distance(drawing, to: $0)) }
            .sorted { $0.distance < $1.distance }
        guard let best = scored.first, best.distance <= limit else { return nil }
        if scored.count > 1, scored[1].distance - best.distance < rivalMargin { return nil }
        return best.id
    }

    static func pathLength(_ points: [PadPoint]) -> Double {
        zip(points, points.dropFirst()).map { $0.distance(to: $1) }.reduce(0, +)
    }

    /// `count` points evenly spaced along the drawing.
    static func resample(_ points: [PadPoint], count: Int) -> [PadPoint] {
        let total = pathLength(points)
        guard total > 0, count > 1 else { return Array(repeating: points.first ?? PadPoint(x: 0, y: 0), count: max(count, 1)) }
        let step = total / Double(count - 1)
        var result = [points[0]]
        var carried = 0.0
        var previous = points[0]
        var index = 1
        while index < points.count, result.count < count {
            let next = points[index]
            let segment = previous.distance(to: next)
            if carried + segment >= step, segment > 0 {
                let k = (step - carried) / segment
                let point = PadPoint(x: previous.x + (next.x - previous.x) * k, y: previous.y + (next.y - previous.y) * k)
                result.append(point)
                previous = point
                carried = 0
            } else {
                carried += segment
                previous = next
                index += 1
            }
        }
        while result.count < count { result.append(points[points.count - 1]) }
        return result
    }
}

/// Making a shape: each drawing is checked as it comes, the three together at the end.
enum CustomGestureMaker {
    enum Problem: Equatable {
        case tooShort
        /// A straight line, or out and back along one: that is a swipe.
        case likeASwipe
        case likeACircle
        /// The three drawings aren't the same shape.
        case drawingsDiffer
        case likeAnother(name: String)

        var message: String {
            switch self {
            case .tooShort: return "Draw it bigger: across most of the touchpad"
            case .likeASwipe: return "That's a swipe. Draw a shape with a corner or a turn"
            case .likeACircle: return "That's a circle. Draw a different shape"
            case .drawingsDiffer: return "The three drawings differ. Start again"
            case let .likeAnother(name): return "Too much like \(name). Draw a different shape"
            }
        }
    }

    static let drawingsNeeded = 3
    /// A drawing whose ends are this much of its length apart is a straight line.
    static let maxStraightness = 0.85
    /// A drawing this thin (its narrow spread against its long one) is a line.
    static let minThickness = 0.2
    /// A drawing that goes round with its ends at most this much of its length apart is a circle.
    static let maxCircleOpening = 0.3

    /// Whether one drawing can be part of a shape.
    static func check(_ points: [PadPoint], tuning: RemoteGestureTuning) -> Problem? {
        let length = CustomGestureMatcher.pathLength(points)
        guard points.count >= 2, length >= CustomGestureMatcher.minLength else { return .tooShort }
        guard let first = points.first, let last = points.last else { return .tooShort }
        let straightness = first.distance(to: last) / length
        if straightness >= maxStraightness { return .likeASwipe }
        if thickness(points) < minThickness { return .likeASwipe }
        // Round and closed (a V turns a lot too, but its ends stay apart).
        if turn(points) * 180 / .pi >= tuning.circleDegrees, straightness < maxCircleOpening { return .likeACircle }
        return nil
    }

    /// The three drawings as a new shape, or why not.
    static func make(
        _ drawings: [[PadPoint]],
        existing: [CustomGestureShape],
        tuning: RemoteGestureTuning
    ) -> Result<CustomGestureShape, MakeFailure> {
        let normalized = drawings.compactMap(CustomGestureMatcher.normalized)
        guard normalized.count == drawings.count, normalized.count >= drawingsNeeded else {
            return .failure(MakeFailure(problem: .tooShort))
        }
        for (i, a) in normalized.enumerated() {
            for b in normalized[(i + 1)...] where CustomGestureMatcher.distance(a, b) > tuning.customShapeDistance * 1.3 {
                return .failure(MakeFailure(problem: .drawingsDiffer))
            }
        }
        for shape in existing {
            let closest = normalized.map { CustomGestureMatcher.distance($0, to: shape) }.min() ?? .infinity
            if closest <= tuning.customShapeDistance + CustomGestureMatcher.rivalMargin {
                return .failure(MakeFailure(problem: .likeAnother(name: shape.name)))
            }
        }
        let numbers = Set(existing.compactMap { Int($0.name.replacingOccurrences(of: "Shape ", with: "")) })
        let number = (1...).first { !numbers.contains($0) } ?? existing.count + 1
        let id = "shape-" + UUID().uuidString.prefix(8).lowercased()
        return .success(CustomGestureShape(id: id, name: "Shape \(number)", drawings: normalized))
    }

    struct MakeFailure: Error, Equatable {
        let problem: Problem
    }

    /// The narrow spread of the points against the long one (0 a line, 1 as wide as long).
    static func thickness(_ points: [PadPoint]) -> Double {
        let n = Double(points.count)
        let cx = points.map(\.x).reduce(0, +) / n, cy = points.map(\.y).reduce(0, +) / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            sxx += (p.x - cx) * (p.x - cx)
            syy += (p.y - cy) * (p.y - cy)
            sxy += (p.x - cx) * (p.y - cy)
        }
        let trace = sxx + syy
        let root = ((sxx - syy) * (sxx - syy) + 4 * sxy * sxy).squareRoot()
        let large = (trace + root) / 2, small = max((trace - root) / 2, 0)
        guard large > 0 else { return 0 }
        return (small / large).squareRoot()
    }

    /// How far round its own centre the drawing turns, in radians (either way).
    static func turn(_ points: [PadPoint]) -> Double {
        let n = Double(points.count)
        let cx = points.map(\.x).reduce(0, +) / n, cy = points.map(\.y).reduce(0, +) / n
        var turned = 0.0
        var last: Double?
        for p in points {
            let dx = p.x - cx, dy = p.y - cy
            guard dx * dx + dy * dy > 0.0025 else { continue }
            let angle = atan2(dy, dx)
            if let last {
                var delta = angle - last
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                turned += delta
            }
            last = angle
        }
        return abs(turned)
    }
}

/// The shapes, per profile. Read often (every frame of an overview card), so the decoded list is
/// kept while the saved data stays the same.
enum CustomGestureStore {
    static let key = "nuvio.tv.settings.playback.remoteGestureCustomShapes"

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var data: Data?
        var shapes: [CustomGestureShape] = []
    }
    private static let cache = Cache()

    static func shapes(in settings: UserDefaults = ProfileSettings.current) -> [CustomGestureShape] {
        let data = settings.data(forKey: key)
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if data == cache.data { return cache.shapes }
        let decoded = data.flatMap { try? JSONDecoder().decode([CustomGestureShape].self, from: $0) } ?? []
        cache.data = data
        cache.shapes = decoded
        return decoded
    }

    static func save(_ shapes: [CustomGestureShape], in settings: UserDefaults = ProfileSettings.current) {
        guard let data = try? JSONEncoder().encode(shapes) else { return }
        settings.set(data, forKey: key)
    }

    static func shape(id: String, in settings: UserDefaults = ProfileSettings.current) -> CustomGestureShape? {
        shapes(in: settings).first { $0.id == id }
    }
}
