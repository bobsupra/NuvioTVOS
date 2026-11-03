import XCTest
@testable import NuvioTV

final class RemoteGestureRecognizerTests: XCTestCase {
    private func gestures(_ outputs: [RecognizerOutput]) -> [RemoteGesture] {
        outputs.compactMap {
            if case let .gesture(gesture, _, _) = $0 { return gesture }
            return nil
        }
    }

    private func run(_ recognizer: RemoteGestureRecognizer, _ events: [InputEvent]) -> [RecognizerOutput] {
        events.flatMap { recognizer.handle($0) }
    }

    /// A finger moving in a straight line, with the system's movement in
    /// points (`points` per pad unit) and a short hold before lifting.
    private func stroke(from: PadPoint, to: PadPoint, start: TimeInterval, duration: TimeInterval,
                        points: Double = 600, steps: Int = 10) -> [InputEvent] {
        var events: [InputEvent] = [.touchBegan(start)]
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let time = start + duration * t
            events.append(.touchMoved(time, PadPoint(x: from.x + (to.x - from.x) * t + 0.011,
                                                     y: from.y + (to.y - from.y) * t + 0.013)))
            events.append(.touchTranslation(time, dx: (to.x - from.x) * t * points, dy: (to.y - from.y) * t * points))
        }
        events.append(.touchEnded(start + duration + 0.1))
        return events
    }

    // MARK: - Clicks

    func testSingleClickWaitsOnlyWhenTheDoubleIsUsed() {
        let waiting = RemoteGestureRecognizer(waitsForDouble: { _ in true })
        XCTAssertTrue(run(waiting, [.pressBegan(0, .right), .pressEnded(0.1, .right), .tick(0.2)]).isEmpty)
        let late = run(waiting, [.tick(0.5)])
        XCTAssertEqual(gestures(late), [.click(.right, .single)])
        if case let .gesture(_, input, decided) = late[0] {
            XCTAssertEqual(input, 0.1)
            XCTAssertEqual(decided, 0.5)
        }

        let immediate = RemoteGestureRecognizer(waitsForDouble: { _ in false })
        XCTAssertEqual(gestures(run(immediate, [.pressBegan(0, .right), .pressEnded(0.1, .right)])),
                       [.click(.right, .single)])
    }

    func testDoubleClick() {
        let recognizer = RemoteGestureRecognizer()
        let outputs = run(recognizer, [
            .pressBegan(0, .right), .pressEnded(0.08, .right), .tick(0.15),
            .pressBegan(0.2, .right), .pressEnded(0.28, .right), .tick(0.9),
        ])
        XCTAssertEqual(gestures(outputs), [.click(.right, .double)])
    }

    func testSecondClickHeldPastTheWindowIsStillADouble() {
        let recognizer = RemoteGestureRecognizer()
        XCTAssertTrue(gestures(run(recognizer, [
            .pressBegan(0, .left), .pressEnded(0.1, .left), .pressBegan(0.3, .left), .tick(0.5),
        ])).isEmpty)
        XCTAssertEqual(gestures(run(recognizer, [.pressEnded(0.6, .left), .tick(1.2)])), [.click(.left, .double)])
    }

    func testTwoClicksTooFarApartAreTwoSingles() {
        let recognizer = RemoteGestureRecognizer()
        let outputs = run(recognizer, [
            .pressBegan(0, .left), .pressEnded(0.1, .left), .tick(0.5),
            .pressBegan(0.6, .left), .pressEnded(0.7, .left), .tick(1.2),
        ])
        XCTAssertEqual(gestures(outputs), [.click(.left, .single), .click(.left, .single)])
    }

    func testLongPressFiresWhileHeldAndNotAgainOnRelease() {
        let recognizer = RemoteGestureRecognizer()
        XCTAssertTrue(run(recognizer, [.pressBegan(0, .up), .tick(0.3)]).isEmpty)
        XCTAssertEqual(gestures(run(recognizer, [.tick(0.55)])), [.click(.up, .long)])
        XCTAssertTrue(gestures(run(recognizer, [.pressEnded(1.0, .up), .tick(1.5)])).isEmpty)
    }

    // MARK: - Clicks on the edge (what the device does)

    func testClickOnTheEdgeIsNoSwipeEvenWhenTheTouchEndsFirst() {
        let recognizer = RemoteGestureRecognizer(waitsForDouble: { _ in false })
        let outputs = run(recognizer, [
            .touchBegan(0), .touchMoved(0.02, PadPoint(x: 0.1, y: -0.2)),
            .touchMoved(0.06, PadPoint(x: 0.05, y: -0.95)), .touchTranslation(0.06, dx: 5, dy: -400),
            .touchEnded(0.08),
            .pressBegan(0.1, .down), .pressEnded(0.18, .down), .tick(0.6),
        ])
        XCTAssertEqual(gestures(outputs), [.click(.down, .single)])
    }

    func testDoubleClickOnTheEdge() {
        let recognizer = RemoteGestureRecognizer()
        let outputs = run(recognizer, [
            .touchBegan(0), .touchMoved(0.02, PadPoint(x: 0.05, y: -0.9)),
            .pressBegan(0.03, .down), .pressEnded(0.12, .down), .touchEnded(0.15),
            .touchBegan(0.25), .touchMoved(0.26, PadPoint(x: 0.04, y: -0.95)),
            .pressBegan(0.27, .down), .pressEnded(0.36, .down), .touchEnded(0.4), .tick(1.0),
        ])
        XCTAssertEqual(gestures(outputs), [.click(.down, .double)])
    }

    // MARK: - Swipes

    func testSwipesFollowTheSystemMovement() {
        let recognizer = RemoteGestureRecognizer()
        var outputs = run(recognizer, stroke(from: PadPoint(x: -0.4, y: 0), to: PadPoint(x: 0.4, y: 0.05),
                                             start: 0, duration: 0.2))
        outputs += run(recognizer, [.tick(0.6)])
        XCTAssertEqual(gestures(outputs), [.swipe(.right, long: false)])

        outputs = run(recognizer, stroke(from: PadPoint(x: 0.8, y: 0.1), to: PadPoint(x: -0.7, y: 0),
                                         start: 1, duration: 0.3))
        outputs += run(recognizer, [.tick(1.8)])
        XCTAssertEqual(gestures(outputs), [.swipe(.left, long: true)])

        outputs = run(recognizer, stroke(from: PadPoint(x: 0, y: 0.5), to: PadPoint(x: 0.1, y: -0.4),
                                         start: 3, duration: 0.25))
        outputs += run(recognizer, [.tick(3.8)])
        XCTAssertEqual(gestures(outputs), [.swipe(.down, long: false)])
    }

    func testSlowOrDiagonalMovesAreNoSwipe() {
        let recognizer = RemoteGestureRecognizer()
        var outputs = run(recognizer, stroke(from: PadPoint(x: -0.5, y: 0), to: PadPoint(x: 0.5, y: 0),
                                             start: 0, duration: 2))
        outputs += run(recognizer, [.tick(2.6)])
        XCTAssertTrue(gestures(outputs).isEmpty)
        outputs = run(recognizer, stroke(from: PadPoint(x: -0.5, y: -0.5), to: PadPoint(x: 0.4, y: 0.4),
                                         start: 3, duration: 0.2))
        outputs += run(recognizer, [.tick(3.8)])
        XCTAssertTrue(gestures(outputs).isEmpty)
    }

    func testTouchWithAClickIsNoSwipeOrTap() {
        let recognizer = RemoteGestureRecognizer(waitsForDouble: { _ in false })
        let outputs = run(recognizer, [
            .touchBegan(0), .touchMoved(0.01, PadPoint(x: 0.6, y: 0.02)),
            .pressBegan(0.02, .right), .pressEnded(0.1, .right),
            .touchMoved(0.12, PadPoint(x: 0.6, y: 0.02)), .touchEnded(0.15), .tick(0.6),
        ])
        XCTAssertEqual(gestures(outputs), [.click(.right, .single)])
    }

    // MARK: - Light taps

    func testLightTapsBySideAndDoubleTap() {
        let recognizer = RemoteGestureRecognizer()
        let right = run(recognizer, [.touchBegan(0), .touchMoved(0.02, PadPoint(x: 0.7, y: 0.1)),
                                     .touchEnded(0.1), .tick(0.6)])
        XCTAssertEqual(gestures(right), [.tap(.right, double: false)])

        let double = run(recognizer, [
            .touchBegan(1), .touchMoved(1.02, PadPoint(x: -0.6, y: 0.02)), .touchEnded(1.1),
            .touchBegan(1.25), .touchMoved(1.27, PadPoint(x: -0.65, y: 0.05)), .touchEnded(1.33), .tick(1.9),
        ])
        XCTAssertEqual(gestures(double), [.tap(.left, double: true)])
    }

    /// Seen on the device: a light touch on the left edge, the first position
    /// with y = 0, positions sliding to the middle on lift, (0, 0) before the
    /// touch ends. That is a tap on the left, not a swipe to the right.
    func testEdgeTouchSlidingToTheMiddleIsATap() {
        let recognizer = RemoteGestureRecognizer(waitsForDouble: { _ in false })
        let outputs = run(recognizer, [
            .touchBegan(0),
            .touchMoved(0.008, PadPoint(x: -0.86, y: 0)),
            .touchMoved(0.03, PadPoint(x: -0.86, y: 0.02)),
            .touchMoved(0.1, PadPoint(x: -0.85, y: 0.01)),
            .touchTranslation(0.1, dx: 3, dy: -2),
            .touchMoved(0.17, PadPoint(x: -0.6, y: -0.1)),
            .touchMoved(0.2, PadPoint(x: -0.3, y: -0.3)),
            .touchMoved(0.215, PadPoint(x: 0, y: 0)),
            .touchEnded(0.224),
            .tick(0.5),
        ])
        XCTAssertEqual(gestures(outputs), [.tap(.left, double: false)])
        let summary = outputs.compactMap { output -> TouchSummary? in
            if case let .touchSummary(summary) = output { return summary }
            return nil
        }.first
        XCTAssertEqual(summary?.padStart, PadPoint(x: -0.86, y: 0.02))
        XCTAssertEqual(summary?.padEnd, PadPoint(x: -0.85, y: 0.01))
    }

    func testTapsOnTheTopAndBottomEdge() {
        let recognizer = RemoteGestureRecognizer(waitsForDouble: { _ in false })
        let bottom = run(recognizer, [.touchBegan(0), .touchMoved(0.02, PadPoint(x: 0.08, y: -0.82)),
                                      .touchEnded(0.12), .tick(0.4)])
        XCTAssertEqual(gestures(bottom), [.tap(.bottom, double: false)])
        let top = run(recognizer, [.touchBegan(1), .touchMoved(1.02, PadPoint(x: -0.1, y: 0.75)),
                                   .touchEnded(1.12), .tick(1.4)])
        XCTAssertEqual(gestures(top), [.tap(.top, double: false)])
        let middle = run(recognizer, [.touchBegan(2), .touchMoved(2.02, PadPoint(x: 0.1, y: 0.12)),
                                      .touchEnded(2.12), .tick(2.4)])
        XCTAssertEqual(gestures(middle), [.tap(.center, double: false)])
    }

    func testSideIsTheNearestEdge() {
        XCTAssertEqual(RemoteGestureRecognizer.side(of: [PadPoint(x: -0.7, y: 0.5)], threshold: 0.3), .left)
        XCTAssertEqual(RemoteGestureRecognizer.side(of: [PadPoint(x: 0.4, y: -0.6)], threshold: 0.3), .bottom)
        XCTAssertEqual(RemoteGestureRecognizer.side(of: [PadPoint(x: 0.2, y: -0.25)], threshold: 0.3), .center)
        XCTAssertEqual(RemoteGestureRecognizer.side(of: [], threshold: 0.3), .center)
    }

    func testCornersWhenTurnedOn() {
        // Points from the device video: about 35° off the horizontal.
        XCTAssertEqual(RemoteGestureRecognizer.side(of: [PadPoint(x: -0.67, y: -0.43)], threshold: 0.3,
                                              corners: true, cornerWidth: 40), .bottomLeft)
        XCTAssertEqual(RemoteGestureRecognizer.side(of: [PadPoint(x: 0.66, y: 0.45)], threshold: 0.3,
                                              corners: true, cornerWidth: 40), .topRight)
        XCTAssertEqual(RemoteGestureRecognizer.side(of: [PadPoint(x: -0.8, y: 0.1)], threshold: 0.3,
                                              corners: true, cornerWidth: 40), .left)
        XCTAssertEqual(RemoteGestureRecognizer.side(of: [PadPoint(x: 0.05, y: 0.8)], threshold: 0.3,
                                              corners: true, cornerWidth: 40), .top)
        XCTAssertEqual(RemoteGestureRecognizer.side(of: [PadPoint(x: -0.67, y: -0.43)], threshold: 0.3,
                                              corners: false), .left)
    }

    /// Seen on the device: the pad reports the landing ~20 ms before the
    /// system's touch, half first (y = 0), and a still finger sends no more.
    func testStillTapUsesThePositionFromJustBeforeTheTouch() {
        let recognizer = RemoteGestureRecognizer(waitsForDouble: { _ in false })
        let outputs = run(recognizer, [
            .touchMoved(0.000, PadPoint(x: -0.71, y: 0)),
            .touchMoved(0.004, PadPoint(x: -0.71, y: -0.43)),
            .touchBegan(0.02),
            .touchEnded(0.2), .tick(0.5),
        ])
        XCTAssertEqual(gestures(outputs), [.tap(.bottomLeft, double: false)])
    }

    func testAHalfPositionAloneStillCounts() {
        let recognizer = RemoteGestureRecognizer(waitsForDouble: { _ in false })
        let outputs = run(recognizer, [
            .touchMoved(0, PadPoint(x: -0.8, y: 0)), .touchBegan(0.02), .touchEnded(0.15), .tick(0.4),
        ])
        XCTAssertEqual(gestures(outputs), [.tap(.left, double: false)])
    }

    func testOldPositionsDontBelongToTheNextTouch() {
        let recognizer = RemoteGestureRecognizer(waitsForDouble: { _ in false })
        let outputs = run(recognizer, [
            .touchMoved(0, PadPoint(x: 0.8, y: 0.05)),
            .touchMoved(0.05, PadPoint(x: 0, y: 0)),
            .touchBegan(0.5), .touchEnded(0.6), .tick(0.9),
        ])
        XCTAssertEqual(gestures(outputs), [.tap(.center, double: false)])
    }

    func testStillFingerIsAHold() {
        let recognizer = RemoteGestureRecognizer()
        var events: [InputEvent] = [.touchMoved(0, PadPoint(x: 0.66, y: 0.45)), .touchBegan(0.02)]
        for step in 1...16 {
            let wobble = Double(step % 3) * 0.02
            events.append(.touchMoved(0.02 + Double(step) * 0.05, PadPoint(x: 0.66 + wobble, y: 0.45 - wobble)))
        }
        events += [.touchTranslation(0.8, dx: -60, dy: 20), .touchEnded(0.9), .tick(1.2)]
        XCTAssertEqual(gestures(run(recognizer, events)), [.hold(.topRight)])
    }

    func testWanderingFingerIsNoHold() {
        let recognizer = RemoteGestureRecognizer()
        var events: [InputEvent] = [.touchBegan(0)]
        for step in 0...16 {
            let t = Double(step) / 16
            events.append(.touchMoved(0.05 * Double(step), PadPoint(x: 0.6 - 0.9 * t, y: 0.4 - 0.6 * t)))
        }
        events += [.touchTranslation(0.8, dx: -200, dy: -120), .touchEnded(0.9), .tick(1.3)]
        XCTAssertTrue(gestures(run(recognizer, events)).isEmpty)
    }

    func testPadPositionsAloneNeverStartATouch() {
        let recognizer = RemoteGestureRecognizer()
        XCTAssertTrue(run(recognizer, [
            .touchMoved(0.1, PadPoint(x: 0.02, y: 0.01)), .touchMoved(0.2, PadPoint(x: -0.7, y: 0.03)),
            .tick(1.0),
        ]).isEmpty)
    }

    func testCircleDirection() {
        let recognizer = RemoteGestureRecognizer()
        // Counterclockwise in pad coordinates (y up): angle increases.
        var events: [InputEvent] = [.touchBegan(0)]
        for step in 0...36 {
            let angle = (Double(step) * 10 + 5) * .pi / 180
            events.append(.touchMoved(0.02 * Double(step), PadPoint(x: 0.8 * cos(angle), y: 0.8 * sin(angle))))
        }
        events += [.touchEnded(0.85), .tick(1.2)]
        XCTAssertEqual(gestures(run(recognizer, events)), [.circle(clockwise: false)])

        var clockwise: [InputEvent] = [.touchBegan(2)]
        for step in 0...36 {
            let angle = -(Double(step) * 10 + 5) * .pi / 180
            clockwise.append(.touchMoved(2 + 0.02 * Double(step), PadPoint(x: 0.8 * cos(angle), y: 0.8 * sin(angle))))
        }
        clockwise += [.touchEnded(2.85), .tick(3.2)]
        XCTAssertEqual(gestures(run(recognizer, clockwise)), [.circle(clockwise: true)])
    }

    func testLongPressOnTheCentre() {
        let recognizer = RemoteGestureRecognizer()
        XCTAssertEqual(gestures(run(recognizer, [.pressBegan(0, .select), .tick(0.6)])), [.click(.select, .long)])
        XCTAssertTrue(gestures(run(recognizer, [.pressEnded(0.9, .select), .tick(1.5)])).isEmpty)
    }

    // MARK: - There and back

    /// A finger following `path` (straight between its points) over
    /// `duration`, with the system's net movement at the end.
    private func path(_ path: [PadPoint], start: TimeInterval, duration: TimeInterval,
                      movement: (dx: Double, dy: Double), steps: Int = 60) -> [InputEvent] {
        var events: [InputEvent] = [.touchBegan(start)]
        let legs = path.count - 1
        for step in 0...steps {
            let position = Double(step) / Double(steps) * Double(legs)
            let leg = min(Int(position), legs - 1)
            let t = position - Double(leg)
            let a = path[leg], b = path[leg + 1]
            events.append(.touchMoved(start + duration * Double(step) / Double(steps),
                                      PadPoint(x: a.x + (b.x - a.x) * t + 0.011, y: a.y + (b.y - a.y) * t + 0.013)))
        }
        events.append(.touchTranslation(start + duration, dx: movement.dx, dy: movement.dy))
        events.append(.touchEnded(start + duration + 0.1))
        return events
    }

    /// From the device video: slow, 1.4–1.8 s, the way back a little past the start.
    func testThereAndBackInFourDirections() {
        let recognizer = RemoteGestureRecognizer()
        var outputs = run(recognizer, path([PadPoint(x: -0.5, y: -0.2), PadPoint(x: 0.85, y: -0.05),
                                            PadPoint(x: -0.75, y: -0.2)],
                                           start: 0, duration: 1.5, movement: (-6, 100)))
        outputs += run(recognizer, [.tick(2.0)])
        XCTAssertEqual(gestures(outputs), [.swipeBack(.right)])

        outputs = run(recognizer, path([PadPoint(x: 0.89, y: 0.1), PadPoint(x: -0.6, y: 0.0),
                                        PadPoint(x: 0.85, y: 0.05)],
                                       start: 3, duration: 1.6, movement: (-12, -155)))
        outputs += run(recognizer, [.tick(5.0)])
        XCTAssertEqual(gestures(outputs), [.swipeBack(.left)])

        outputs = run(recognizer, path([PadPoint(x: 0.17, y: -0.75), PadPoint(x: 0.05, y: 0.85),
                                        PadPoint(x: 0.1, y: -0.8)],
                                       start: 6, duration: 1.6, movement: (24, -373)))
        outputs += run(recognizer, [.tick(8.0)])
        XCTAssertEqual(gestures(outputs), [.swipeBack(.up)])

        outputs = run(recognizer, path([PadPoint(x: 0.01, y: 0.69), PadPoint(x: 0.0, y: -0.85),
                                        PadPoint(x: 0.02, y: 0.8)],
                                       start: 9, duration: 1.4, movement: (-32, -142)))
        outputs += run(recognizer, [.tick(11.0)])
        XCTAssertEqual(gestures(outputs), [.swipeBack(.down)])
    }

    func testQuickThereAndBackPastTheMiddle() {
        let recognizer = RemoteGestureRecognizer()
        var outputs = run(recognizer, path([PadPoint(x: 0, y: 0), PadPoint(x: 0.8, y: 0.05),
                                            PadPoint(x: -0.9, y: 0)],
                                           start: 0, duration: 0.5, movement: (-450, 0)))
        outputs += run(recognizer, [.tick(1.0)])
        XCTAssertEqual(gestures(outputs), [.swipeBack(.right)])
    }

    /// The arcs from the device video are no there and back.
    func testArcIsNoThereAndBack() {
        let recognizer = RemoteGestureRecognizer()
        let arc = stride(from: 150.0, through: 300.0, by: 15).map { degrees -> PadPoint in
            let angle = degrees * .pi / 180
            return PadPoint(x: 0.75 * cos(angle), y: 0.75 * sin(angle))
        }
        var outputs = run(recognizer, path(arc, start: 0, duration: 1.05, movement: (1076, -1003)))
        outputs += run(recognizer, [.tick(1.6)])
        XCTAssertTrue(gestures(outputs).isEmpty, "\(gestures(outputs))")
    }

    func testShortWayBackIsAnOrdinarySwipe() {
        let recognizer = RemoteGestureRecognizer()
        var outputs = run(recognizer, path([PadPoint(x: -0.7, y: 0), PadPoint(x: 0.8, y: 0.05),
                                            PadPoint(x: 0.5, y: 0.05)],
                                           start: 0, duration: 0.4, movement: (700, 10)))
        outputs += run(recognizer, [.tick(1.0)])
        XCTAssertEqual(gestures(outputs), [.swipe(.right, long: false)])
    }

    func testLiftSlideAfterASwipeIsNoWayBack() {
        let recognizer = RemoteGestureRecognizer()
        var events = path([PadPoint(x: -0.7, y: 0), PadPoint(x: 0.85, y: 0.02)],
                          start: 0, duration: 0.3, movement: (750, 5))
        events.removeLast()
        // The finger comes off: positions slide to the middle within ~60 ms.
        events += [.touchMoved(0.33, PadPoint(x: 0.6, y: 0.01)), .touchMoved(0.35, PadPoint(x: 0.2, y: 0)),
                   .touchMoved(0.36, PadPoint(x: 0, y: 0)), .touchEnded(0.37), .tick(1.0)]
        XCTAssertEqual(gestures(run(recognizer, events)), [.swipe(.right, long: false)])
    }
}
