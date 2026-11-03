import XCTest
@testable import NuvioTV

final class CustomGestureTests: XCTestCase {
    /// Points every 0.05 pad units along straight pieces through `corners`.
    private func drawing(_ corners: [(Double, Double)]) -> [PadPoint] {
        var points: [PadPoint] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let length = hypot(b.0 - a.0, b.1 - a.1)
            let steps = max(Int(length / 0.05), 1)
            for i in 0..<steps {
                let k = Double(i) / Double(steps)
                points.append(PadPoint(x: a.0 + (b.0 - a.0) * k, y: a.1 + (b.1 - a.1) * k))
            }
        }
        if let last = corners.last { points.append(PadPoint(x: last.0, y: last.1)) }
        return points
    }

    private var letterL: [PadPoint] { drawing([(-0.5, 0.6), (-0.5, -0.6), (0.5, -0.6)]) }
    private var letterV: [PadPoint] { drawing([(-0.6, 0.6), (0, -0.6), (0.6, 0.6)]) }
    private var letterZ: [PadPoint] { drawing([(-0.5, 0.5), (0.5, 0.5), (-0.5, -0.5), (0.5, -0.5)]) }

    /// The same shape smaller, elsewhere on the pad and a little shaky.
    private func shaky(_ points: [PadPoint]) -> [PadPoint] {
        points.enumerated().map { i, p in
            PadPoint(x: p.x * 0.8 + 0.2 + 0.01 * sin(Double(i)), y: p.y * 0.8 + 0.1 + 0.01 * cos(Double(i)))
        }
    }

    private func shape(_ id: String, _ name: String, _ points: [PadPoint]) throws -> CustomGestureShape {
        let normalized = try XCTUnwrap(CustomGestureMatcher.normalized(points))
        return CustomGestureShape(id: id, name: name, drawings: [normalized, normalized, normalized])
    }

    // MARK: Matching

    func testADrawingIsBroughtToOneSizeAndPlace() throws {
        let normalized = try XCTUnwrap(CustomGestureMatcher.normalized(letterL))
        XCTAssertEqual(normalized.count, CustomGestureMatcher.pointCount)
        let cx = normalized.map(\.x).reduce(0, +) / Double(normalized.count)
        XCTAssertEqual(cx, 0, accuracy: 0.0001)
        let height = (normalized.map(\.y).max() ?? 0) - (normalized.map(\.y).min() ?? 0)
        XCTAssertEqual(height, 1, accuracy: 0.0001)
        XCTAssertNil(CustomGestureMatcher.normalized([PadPoint(x: 0.1, y: 0.1), PadPoint(x: 0.2, y: 0.2)]), "a tap is no drawing")
    }

    func testTheSameShapeElsewhereAndSmallerMatches() throws {
        let shapes = [try shape("l", "Shape 1", letterL), try shape("v", "Shape 2", letterV)]
        XCTAssertEqual(CustomGestureMatcher.match(shaky(letterL), shapes: shapes, within: 0.15), "l")
        XCTAssertEqual(CustomGestureMatcher.match(shaky(letterV), shapes: shapes, within: 0.15), "v")
        XCTAssertNil(CustomGestureMatcher.match(letterZ, shapes: shapes, within: 0.15))
        XCTAssertNil(CustomGestureMatcher.match(drawing([(-0.7, 0.02), (0.7, 0.03)]), shapes: shapes, within: 0.15), "a swipe")
    }

    func testTheWayItIsDrawnMatters() throws {
        let shapes = [try shape("l", "Shape 1", letterL)]
        XCTAssertNil(CustomGestureMatcher.match(Array(letterL.reversed()), shapes: shapes, within: 0.15))
    }

    // MARK: Making a shape

    func testAShapeMustNotBeATapASwipeOrACircle() {
        let tuning = RemoteGestureTuning()
        XCTAssertEqual(CustomGestureMaker.check([PadPoint(x: 0, y: 0.1), PadPoint(x: 0.1, y: 0.1)], tuning: tuning), .tooShort)
        XCTAssertEqual(CustomGestureMaker.check(drawing([(-0.7, 0.02), (0.7, 0.03)]), tuning: tuning), .likeASwipe)
        XCTAssertEqual(CustomGestureMaker.check(drawing([(-0.6, 0.01), (0.6, 0.0), (-0.4, 0.02)]), tuning: tuning), .likeASwipe, "there and back")
        let circle = (0...40).map { i -> PadPoint in
            let angle = Double(i) / 40 * 2 * .pi
            return PadPoint(x: 0.6 * cos(angle), y: 0.6 * sin(angle))
        }
        XCTAssertEqual(CustomGestureMaker.check(circle, tuning: tuning), .likeACircle)
        XCTAssertNil(CustomGestureMaker.check(letterL, tuning: tuning))
        XCTAssertNil(CustomGestureMaker.check(letterV, tuning: tuning))
        XCTAssertNil(CustomGestureMaker.check(letterZ, tuning: tuning))
    }

    func testThreeDrawingsOfOneShapeMakeIt() throws {
        let tuning = RemoteGestureTuning()
        let made = try CustomGestureMaker.make([letterL, shaky(letterL), letterL], existing: [], tuning: tuning).get()
        XCTAssertEqual(made.name, "Shape 1")
        XCTAssertEqual(made.drawings.count, 3)
        XCTAssertTrue(made.id.hasPrefix("shape-"))

        XCTAssertEqual(
            CustomGestureMaker.make([letterL, letterV, letterL], existing: [], tuning: tuning),
            .failure(CustomGestureMaker.MakeFailure(problem: .drawingsDiffer))
        )
        XCTAssertEqual(
            CustomGestureMaker.make([letterL, letterL, shaky(letterL)], existing: [made], tuning: tuning),
            .failure(CustomGestureMaker.MakeFailure(problem: .likeAnother(name: "Shape 1")))
        )
        let second = try CustomGestureMaker.make([letterV, letterV, shaky(letterV)], existing: [made], tuning: tuning).get()
        XCTAssertEqual(second.name, "Shape 2")
    }

    // MARK: Recognizing it

    func testTheRecognizerTellsAShapeFromASwipe() throws {
        let recognizer = RemoteGestureRecognizer(waitsForDouble: { _ in false })
        recognizer.customShapes = [try shape("shape-l", "Shape 1", letterL)]
        var events: [InputEvent] = [.touchBegan(1.0)]
        let points = shaky(letterL)
        for (i, point) in points.enumerated() {
            let time = 1.01 + Double(i) * 0.012
            events.append(.touchMoved(time, point))
            events.append(.touchTranslation(time, dx: (point.x - points[0].x) * 600, dy: (point.y - points[0].y) * 600))
        }
        let end = 1.01 + Double(points.count) * 0.012 + 0.1
        events.append(.touchEnded(end))
        events.append(.tick(end + 0.5))
        let found = events.flatMap { recognizer.handle($0) }.compactMap { output -> RemoteGesture? in
            if case let .gesture(gesture, _, _) = output { return gesture }
            return nil
        }
        XCTAssertEqual(found, [.custom("shape-l")])
    }

    // MARK: Keeping it

    func testShapesAreKeptAndADeletedOneLeavesNoBinding() throws {
        let suite = "CustomGestureTests.store"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CustomGestureStore.shapes(in: settings), [])
        let l = try shape("shape-l", "Shape 1", letterL)
        CustomGestureStore.save([l], in: settings)
        XCTAssertEqual(CustomGestureStore.shapes(in: settings), [l])
        XCTAssertEqual(CustomGestureStore.shape(id: "shape-l", in: settings)?.name, "Shape 1")

        var bindings = PlayerGestureBindings.defaults
        bindings.bind(.custom("shape-l"), to: .skipIntro)
        XCTAssertEqual(bindings.action(for: .custom("shape-l")), .skipIntro)
        bindings.unbind(gesture: .custom("shape-l"))
        XCTAssertNil(bindings.gesture(for: .skipIntro))
        XCTAssertEqual(bindings.action(for: .swipe(.right, long: true)), .nextChapter)
    }

    func testAShapeIsDrawnAlongItsFirstDrawing() throws {
        let normalized = try XCTUnwrap(CustomGestureMatcher.normalized(letterL))
        let start = GestureAnimation.customFrame(normalized, 0.11)
        let end = GestureAnimation.customFrame(normalized, 0.8)
        XCTAssertGreaterThan(try XCTUnwrap(start.finger).y, 0.6, "starts at the top of the L")
        XCTAssertLessThan(try XCTUnwrap(start.finger).x, 0, "on its left")
        XCTAssertGreaterThan(try XCTUnwrap(end.finger).x, 0.3, "ends at the foot's right")
        XCTAssertFalse(end.trail.isEmpty)
    }
}
