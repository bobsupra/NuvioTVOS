import XCTest
@testable import NuvioTV

final class GestureAnimationTests: XCTestCase {
    // MARK: Looping pictures

    func testALongSwipeCrossesThePadAndAShortOneDoesNot() throws {
        let long = try XCTUnwrap(GestureAnimation.frame(of: .swipe(.right, long: true), at: 0.62).finger)
        let short = try XCTUnwrap(GestureAnimation.frame(of: .swipe(.right, long: false), at: 0.50).finger)
        XCTAssertGreaterThan(long.x, 0.6)
        XCTAssertLessThan(short.x, 0.4)
        XCTAssertEqual(long.y, 0, accuracy: 0.001)
        let trail = GestureAnimation.frame(of: .swipe(.right, long: true), at: 0.4).trail
        XCTAssertGreaterThan(trail.count, 2)
        XCTAssertLessThan(try XCTUnwrap(trail.first).x, try XCTUnwrap(trail.last).x)
    }

    func testASwipeUpGoesUp() throws {
        let finger = try XCTUnwrap(GestureAnimation.frame(of: .swipe(.up, long: true), at: 0.62).finger)
        XCTAssertGreaterThan(finger.y, 0.6)
    }

    func testThereAndBackComesBack() throws {
        let out = try XCTUnwrap(GestureAnimation.frame(of: .swipeBack(.left), at: 0.42).finger)
        let back = try XCTUnwrap(GestureAnimation.frame(of: .swipeBack(.left), at: 0.69).finger)
        XCTAssertLessThan(out.x, -0.5)
        XCTAssertGreaterThan(back.x, -0.1)
    }

    func testCirclesTurnTheirWayFromTheTop() throws {
        let clockwise = try XCTUnwrap(GestureAnimation.frame(of: .circle(clockwise: true), at: 0.2).finger)
        let counter = try XCTUnwrap(GestureAnimation.frame(of: .circle(clockwise: false), at: 0.2).finger)
        XCTAssertGreaterThan(clockwise.x, 0)
        XCTAssertLessThan(counter.x, 0)
        XCTAssertGreaterThan(clockwise.y, 0)
    }

    func testClicksPressTheirButtonOnceOrTwice() {
        func presses(_ gesture: RemoteGesture) -> Int {
            var count = 0
            var wasDown = false
            for step in 0..<200 {
                let down = GestureAnimation.frame(of: gesture, at: Double(step) / 200).pressed != nil
                if down, !wasDown { count += 1 }
                wasDown = down
            }
            return count
        }
        XCTAssertEqual(presses(.click(.right, .single)), 1)
        XCTAssertEqual(presses(.click(.select, .double)), 2)
        XCTAssertEqual(presses(.click(.up, .long)), 1)
        XCTAssertEqual(GestureAnimation.frame(of: .click(.left, .single), at: 0.35).pressed, .left)
    }

    func testALongPressFillsItsRingBeforeItCounts() throws {
        let early = GestureAnimation.frame(of: .click(.down, .long), at: 0.3)
        let late = GestureAnimation.frame(of: .click(.down, .long), at: 0.7)
        XCTAssertLessThan(try XCTUnwrap(early.progress), 1)
        XCTAssertFalse(early.isLong)
        XCTAssertEqual(late.progress, 1)
        XCTAssertTrue(late.isLong)
    }

    func testATapRipplesWhereItTouched() throws {
        let frame = GestureAnimation.frame(of: .tap(.topRight, double: false), at: 0.3)
        XCTAssertEqual(try XCTUnwrap(frame.ripple).center, PadSide.topRight.padPoint)
        let double = (0..<200).map { GestureAnimation.frame(of: .tap(.left, double: true), at: Double($0) / 200) }
        let touches = zip(double, double.dropFirst()).filter { $0.0.finger == nil && $0.1.finger != nil }.count
        XCTAssertEqual(touches, 2)
    }

    func testTheLoopRepeats() {
        XCTAssertEqual(
            GestureAnimation.frame(of: .swipe(.left, long: true), at: 0.5),
            GestureAnimation.frame(of: .swipe(.left, long: true), at: 3.5)
        )
    }

    // MARK: The overview

    func testTheFamiliesHaveEveryVariant() {
        XCTAssertEqual(GestureFamily.click.variants.count, RemoteButton.allCases.count)
        XCTAssertEqual(GestureFamily.tap.variants, [.tap(.center, double: false), .tap(.left, double: false), .tap(.right, double: false), .tap(.top, double: false), .tap(.bottom, double: false)])
        XCTAssertEqual(GestureFamily.circle.variants, [.circle(clockwise: true), .circle(clockwise: false)])
        let all = GestureFamily.allCases.flatMap(\.variants)
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertTrue(all.contains(.swipeBack(.down)))
        XCTAssertTrue(all.contains(.hold(.bottom)))
        XCTAssertFalse(all.contains(.hold(.bottomLeft)), "no corners in the player")
    }

    func testAFamilyCardGoesThroughItsVariants() {
        let loop = GestureAnimation.loopDuration
        XCTAssertEqual(GestureFamily.longSwipe.variant(at: 0).gesture, GestureFamily.longSwipe.variants[0])
        let second = GestureFamily.longSwipe.variant(at: loop * 1.5)
        XCTAssertEqual(second.gesture, GestureFamily.longSwipe.variants[1])
        XCTAssertEqual(second.phase, 0.5, accuracy: 0.0001)
        let wrapped = GestureFamily.circle.variant(at: loop * 2.25)
        XCTAssertEqual(wrapped.gesture, .circle(clockwise: true))
    }

    func testWhatAGestureDoesNow() {
        let bindings = PlayerGestureBindings.defaults
        XCTAssertEqual(PlayerGestureMeaning(of: .swipe(.right, long: true), in: bindings), .action(.nextChapter))
        XCTAssertEqual(PlayerGestureMeaning(of: .click(.right, .single), in: bindings), .builtIn(.seekForward))
        XCTAssertEqual(PlayerGestureMeaning(of: .circle(clockwise: false), in: bindings), .free)
        XCTAssertEqual(PlayerGestureMeaning.free.title, "free")
        XCTAssertEqual(PlayerGestureMeaning.builtIn(.seekForward).title, "player: seek forward")
    }

    // MARK: Recording twice

    func testTheSameGestureTwiceIsSaved() {
        var session = GestureRecordingSession()
        XCTAssertEqual(session.record(.swipe(.right, long: true)), .confirm(.swipe(.right, long: true)))
        XCTAssertEqual(session.record(.swipe(.right, long: true)), .done(.swipe(.right, long: true)))
        XCTAssertEqual(session.record(.click(.up, .single)), .done(.swipe(.right, long: true)))
    }

    func testADifferentSecondGestureStartsOver() {
        var session = GestureRecordingSession()
        session.record(.swipe(.right, long: true))
        XCTAssertEqual(
            session.record(.swipe(.right, long: false)),
            .mismatch(first: .swipe(.right, long: true), second: .swipe(.right, long: false))
        )
        XCTAssertEqual(session.record(.circle(clockwise: true)), .confirm(.circle(clockwise: true)))
        XCTAssertEqual(session.record(.circle(clockwise: true)), .done(.circle(clockwise: true)))
    }

    // MARK: The live trace

    func testTheTraceFollowsTheFingerAndNamesTheSwipe() throws {
        let trace = GestureLiveTrace()
        trace.handle(.touchBegan(10))
        XCTAssertEqual(trace.status(at: 10.05), "Finger on the pad…")
        trace.handle(.touchMoved(10.02, PadPoint(x: -0.5, y: 0.02)))
        trace.handle(.touchMoved(10.05, PadPoint(x: 0.1, y: 0.03)))
        trace.handle(.touchMoved(10.08, PadPoint(x: 0.4, y: 0.05)))
        trace.handle(.touchTranslation(10.08, dx: 400, dy: 20))
        XCTAssertEqual(trace.status(at: 10.1), "Swipe right…")
        let frame = trace.frame(at: 10.1)
        XCTAssertEqual(frame.finger, PadPoint(x: 0.4, y: 0.05))
        XCTAssertEqual(frame.trail.count, 3)
        trace.handle(.touchTranslation(10.2, dx: 1000, dy: 30))
        XCTAssertEqual(trace.status(at: 10.2), "Long swipe right…")
        trace.handle(.touchEnded(10.3))
        XCTAssertNil(trace.status(at: 10.31))
        XCTAssertNil(trace.frame(at: 10.31).finger)
        XCTAssertFalse(trace.frame(at: 10.31).trail.isEmpty)
        XCTAssertTrue(trace.frame(at: 10.3 + GestureLiveTrace.fadeOut + 0.01).trail.isEmpty)
    }

    func testTheTraceShowsALongPressComing() {
        let trace = GestureLiveTrace()
        trace.handle(.pressBegan(5, .right))
        XCTAssertEqual(trace.status(at: 5.2), "Pressing right…")
        XCTAssertEqual(trace.frame(at: 5.2).pressed, .right)
        XCTAssertEqual(trace.frame(at: 5.25).progress ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(trace.status(at: 5.6), "Long press right")
        XCTAssertTrue(trace.frame(at: 5.6).isLong)
        trace.handle(.pressEnded(5.7, .right))
        XCTAssertNil(trace.frame(at: 5.71).pressed)
    }

    func testAShortStillTouchRipples() throws {
        let trace = GestureLiveTrace()
        trace.handle(.touchMoved(1.0, PadPoint(x: -0.6, y: 0.1)))
        trace.handle(.touchBegan(1.01))
        trace.handle(.touchEnded(1.15))
        let ripple = try XCTUnwrap(trace.frame(at: 1.2).ripple)
        XCTAssertEqual(ripple.center, PadPoint(x: -0.6, y: 0.1))
        XCTAssertNil(trace.frame(at: 1.15 + GestureLiveTrace.rippleDuration + 0.01).ripple)
    }

    func testATapOnTheSideRipplesThereNotWhereTheLiftSlid() throws {
        let trace = GestureLiveTrace()
        // The first position has only x; then the side; then the slide towards the middle and (0, 0).
        trace.handle(.touchMoved(3.00, PadPoint(x: -0.7, y: 0)))
        trace.handle(.touchBegan(3.01))
        trace.handle(.touchMoved(3.02, PadPoint(x: -0.72, y: 0.05)))
        trace.handle(.touchMoved(3.05, PadPoint(x: -0.70, y: 0.04)))
        trace.handle(.touchMoved(3.08, PadPoint(x: -0.71, y: 0.05)))
        trace.handle(.touchMoved(3.14, PadPoint(x: -0.30, y: 0.02)))
        trace.handle(.touchMoved(3.15, PadPoint(x: 0, y: 0)))
        trace.handle(.touchMoved(3.16, PadPoint(x: -0.05, y: 0.01)))
        trace.handle(.touchEnded(3.17))
        let frame = trace.frame(at: 3.2)
        let ripple = try XCTUnwrap(frame.ripple)
        XCTAssertLessThan(ripple.center.x, -0.6)
        XCTAssertTrue(frame.trail.allSatisfy { $0.x < -0.6 }, "no slide towards the middle")
    }

    func testAStillFingerFillsTowardsAHold() {
        let trace = GestureLiveTrace()
        trace.handle(.touchBegan(2))
        trace.handle(.touchMoved(2.01, PadPoint(x: 0.1, y: 0.1)))
        XCTAssertEqual(trace.status(at: 2.6), "Touch and hold…")
        XCTAssertTrue(trace.frame(at: 2.6).isLong)
    }

    // MARK: Sensitivity

    func testTheDefaultsAreGestureLabsWithALargeMiddleAndNoCorners() {
        var expected = RemoteGestureTuning()
        expected.sideThreshold = 0.30
        expected.cornerTouches = false
        XCTAssertEqual(PlayerGestureSensitivity().tuning, expected)
        XCTAssertEqual(PlayerGestureSensitivity().step(.centerSize), 2)
    }

    func testAKnobGoesRoundItsSteps() {
        var sensitivity = PlayerGestureSensitivity()
        sensitivity.cycle(.centerSize)
        XCTAssertEqual(sensitivity.step(.centerSize), 0)
        XCTAssertEqual(sensitivity.tuning.sideThreshold, 0.15)
        sensitivity.cycle(.centerSize)
        XCTAssertEqual(sensitivity.tuning.sideThreshold, 0.20)
        XCTAssertFalse(sensitivity.tuning.cornerTouches)
        sensitivity.cycle(.swipeLength)
        XCTAssertEqual(sensitivity.tuning.swipeMinPoints, 325, accuracy: 0.001)
        XCTAssertEqual(sensitivity.tuning.swipeLongPoints, 1170, accuracy: 0.001)
        sensitivity.cycle(.longPress)
        XCTAssertEqual(sensitivity.tuning.longPress, 0.7)
        XCTAssertEqual(sensitivity.tuning.holdMinDuration, 0.7)
    }

    func testSensitivityIsKeptInTheProfile() throws {
        let suite = "GestureAnimationTests.sensitivity"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        XCTAssertEqual(PlayerGestureSettings.sensitivity(in: settings), PlayerGestureSensitivity())
        var sensitivity = PlayerGestureSensitivity()
        sensitivity.cycle(.doubleWindow)
        PlayerGestureSettings.save(sensitivity, in: settings)
        XCTAssertEqual(PlayerGestureSettings.sensitivity(in: settings), sensitivity)
        XCTAssertEqual(PlayerGestureSettings.sensitivity(in: settings).tuning.doubleWindow, 0.45)
    }

    // MARK: The player's gesture layer

    func testASideTapWaitsOnlyWhenItsDoubleTapIsBound() {
        var bindings = PlayerGestureBindings.defaults
        XCTAssertEqual(PlayerGesturePassive.waitingTapSides(bindings), [])
        bindings.bind(.tap(.left, double: true), to: .back30)
        bindings.bind(.tap(.center, double: true), to: .playPause)
        XCTAssertEqual(PlayerGesturePassive.waitingTapSides(bindings), [.left])
    }

    func testTheGestureLayerKeepsTheRemoteThroughTheWaitAfterASeek() {
        XCTAssertTrue(PlayerGestureCaptureStatus.keepsCapture(.playing))
        XCTAssertTrue(PlayerGestureCaptureStatus.keepsCapture(.buffering))
        XCTAssertFalse(PlayerGestureCaptureStatus.keepsCapture(.paused))
        XCTAssertFalse(PlayerGestureCaptureStatus.keepsCapture(.ended))
        XCTAssertFalse(PlayerGestureCaptureStatus.keepsCapture(.error("x")))
    }
}
