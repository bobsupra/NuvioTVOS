import XCTest
@testable import NuvioTV

final class PlayerGestureBindingTests: XCTestCase {
    func testLongSwipesJumpChaptersByDefault() {
        let bindings = PlayerGestureBindings.defaults
        XCTAssertEqual(bindings.action(for: .swipe(.right, long: true)), .nextChapter)
        XCTAssertEqual(bindings.action(for: .swipe(.left, long: true)), .previousChapter)
        XCTAssertNil(bindings.action(for: .click(.right, .single)))
    }

    func testBindingTakesTheGestureFromAnotherAction() {
        var bindings = PlayerGestureBindings.defaults
        let previous = bindings.bind(.swipe(.right, long: true), to: .skipIntro)
        XCTAssertEqual(previous, .nextChapter)
        XCTAssertEqual(bindings.action(for: .swipe(.right, long: true)), .skipIntro)
        XCTAssertNil(bindings.gesture(for: .nextChapter))
    }

    func testAnActionHasOneGesture() {
        var bindings = PlayerGestureBindings.defaults
        bindings.bind(.click(.right, .double), to: .nextChapter)
        XCTAssertEqual(bindings.gesture(for: .nextChapter), .click(.right, .double))
        XCTAssertNil(bindings.action(for: .swipe(.right, long: true)))
        bindings.unbind(.nextChapter)
        XCTAssertNil(bindings.gesture(for: .nextChapter))
    }

    func testBindingsAreKeptInTheProfile() throws {
        let suite = "PlayerGestureBindingTests.saved"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        XCTAssertFalse(PlayerGestureSettings.isEnabled(in: settings))
        XCTAssertEqual(PlayerGestureSettings.bindings(in: settings), .defaults)

        var bindings = PlayerGestureBindings.defaults
        bindings.bind(.circle(clockwise: true), to: .faster)
        bindings.bind(.click(.up, .long), to: .toggleSubtitles)
        PlayerGestureSettings.save(bindings, in: settings)
        PlayerGestureSettings.setEnabled(true, in: settings)
        XCTAssertEqual(PlayerGestureSettings.bindings(in: settings), bindings)
        XCTAssertTrue(PlayerGestureSettings.isEnabled(in: settings))
    }

    func testUnboundGesturesKeepThePlayersOwnMeaning() {
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .click(.right, .single)), .seekForward)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .click(.left, .long)), .holdSeekBack)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .click(.select, .single)), .select)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .click(.down, .single)), .openPanel)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .swipe(.up, long: false)), .revealControls)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .tap(.bottomLeft, double: false)), .seekBack)
        XCTAssertEqual(PlayerBuiltInGesture.action(for: .tap(.center, double: false)), .peek)
        // Free while playing: nothing happens unless a gesture is bound.
        XCTAssertNil(PlayerBuiltInGesture.action(for: .swipe(.right, long: true)))
        XCTAssertNil(PlayerBuiltInGesture.action(for: .circle(clockwise: true)))
        XCTAssertNil(PlayerBuiltInGesture.action(for: .hold(.left)))
    }

    func testTitles() {
        XCTAssertEqual(RemoteGesture.click(.right, .double).title, "Double click right")
        XCTAssertEqual(RemoteGesture.click(.select, .single).title, "Click center")
        XCTAssertEqual(RemoteGesture.swipe(.left, long: true).title, "Long swipe left")
        XCTAssertEqual(RemoteGesture.swipeBack(.right).title, "Swipe right and back")
        XCTAssertEqual(RemoteGesture.tap(.center, double: true).title, "Double tap center")
        XCTAssertEqual(RemoteGesture.hold(.top).title, "Touch and hold top")
        XCTAssertEqual(PlayerGestureAction.nextChapter.title, "Next chapter")
    }

    // MARK: Expert mode

    func testTheReadyMadeGesturesKeepClearOfThePlayer() {
        let bindings = PlayerGestureBindings.defaults.bindings
        XCTAssertEqual(bindings.count, 8)
        XCTAssertEqual(Set(bindings.map(\.action)).count, bindings.count, "one gesture per action")
        for binding in bindings {
            XCTAssertNil(PlayerBuiltInGesture.action(for: binding.gesture), "\(binding.gesture.title) is the player's")
            if case .tap(_, double: true) = binding.gesture { XCTFail("a double tap makes a single one wait") }
            if case .click = binding.gesture { XCTFail("clicks stay the player's") }
        }
        XCTAssertTrue(PlayerGesturePassive.waitingTapSides(.defaults).isEmpty)
    }

    func testExpertModeKeepsOnesOwnGestures() throws {
        let suite = "PlayerGestureBindingTests.expert"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        XCTAssertFalse(PlayerGestureSettings.isExpert(in: settings))

        var own = PlayerGestureBindings.defaults
        own.bind(.tap(.left, double: true), to: .back30)
        PlayerGestureSettings.save(own, in: settings)
        var sensitivity = PlayerGestureSensitivity()
        sensitivity.cycle(.doubleWindow)
        PlayerGestureSettings.save(sensitivity, in: settings)
        let shape = CustomGestureShape(id: "shape-z", name: "Shape 1", drawings: [[PadPoint(x: 0, y: 0), PadPoint(x: 1, y: 1)]])
        CustomGestureStore.save([shape], in: settings)

        // Off: the ready-made gestures, the default sensitivity, no shapes.
        XCTAssertEqual(PlayerGestureSettings.activeBindings(in: settings), .defaults)
        XCTAssertEqual(PlayerGestureSettings.activeSensitivity(in: settings), PlayerGestureSensitivity())
        XCTAssertEqual(PlayerGestureSettings.activeShapes(in: settings), [])

        // On: one's own, as they were saved.
        PlayerGestureSettings.setExpert(true, in: settings)
        XCTAssertTrue(PlayerGestureSettings.isExpert(in: settings))
        XCTAssertEqual(PlayerGestureSettings.activeBindings(in: settings), own)
        XCTAssertEqual(PlayerGestureSettings.activeSensitivity(in: settings), sensitivity)
        XCTAssertEqual(PlayerGestureSettings.activeShapes(in: settings), [shape])
    }

    func testExpertModeStartsFromTheReadyMadeGestures() throws {
        let suite = "PlayerGestureBindingTests.expertStart"
        let settings = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { settings.removePersistentDomain(forName: suite) }
        PlayerGestureSettings.setExpert(true, in: settings)
        XCTAssertEqual(PlayerGestureSettings.activeBindings(in: settings), .defaults)
        XCTAssertEqual(PlayerGestureSettings.activeBindings(in: settings).action(for: .hold(.center)), .openChapters)
    }
}
