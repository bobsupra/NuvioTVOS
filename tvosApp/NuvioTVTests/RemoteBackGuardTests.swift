import XCTest
import UIKit
@testable import NuvioTV

@MainActor
final class RemoteBackGuardTests: XCTestCase {
    func testBackIsSwallowedWhileNothingIsFocusedOrRightAfterThePreviousOne() {
        XCTAssertTrue(BackGuardHostView.shouldSwallow(nothingFocused: true, sincePreviousBack: .infinity, sinceLastSwallow: .infinity))
        XCTAssertTrue(BackGuardHostView.shouldSwallow(nothingFocused: false, sincePreviousBack: 0.4, sinceLastSwallow: .infinity),
                      "a menu that took the previous Back is still closing")
        XCTAssertFalse(BackGuardHostView.shouldSwallow(nothingFocused: false, sincePreviousBack: 2, sinceLastSwallow: .infinity))
    }

    @MainActor
    func testEveryBackGoesThroughWhileTheExitReminderWaits() {
        defer { BackGuardHostView.passBackUntil = -.infinity }
        BackGuardHostView.passBackUntil = 100
        XCTAssertTrue(BackGuardHostView.isPassingBack(at: 99.5))
        XCTAssertFalse(BackGuardHostView.isPassingBack(at: 100))
        BackGuardHostView.passBackUntil = -.infinity
        XCTAssertFalse(BackGuardHostView.isPassingBack(at: 0))
    }

    func testABackRightAfterASwallowedOneGoesThrough() {
        XCTAssertFalse(BackGuardHostView.shouldSwallow(nothingFocused: true, sincePreviousBack: 0.4, sinceLastSwallow: 0.4))
        XCTAssertTrue(BackGuardHostView.shouldSwallow(nothingFocused: true, sincePreviousBack: 2, sinceLastSwallow: 2))
    }

    func testOverlayBlocksSystemHomeExitWhenFocusIsMissingOrDismissing() {
        XCTAssertTrue(
            BackGuardHostView.shouldSwallow(
                nothingFocused: true,
                sincePreviousBack: 0.4,
                sinceLastSwallow: 0.4,
                allowsAppExit: false
            ),
            "Inside an overlay, rapid Back taps while focus is missing/dismissing must never fall through to Apple TV Home"
        )
        XCTAssertFalse(
            BackGuardHostView.shouldSwallow(
                nothingFocused: false,
                sincePreviousBack: 0.4,
                sinceLastSwallow: 0.4,
                allowsAppExit: false
            ),
            "Inside an overlay, repeated Back taps on an interactive control must still pass through"
        )
    }

    func testFocusUnavailableDetectsNilAndDismissingOrDisabledViewAncestors() {
        XCTAssertTrue(BackGuardHostView.isFocusUnavailable(nil))

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.isHidden = false
        let container = UIView(frame: window.bounds)
        let child = FocusableStubView(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        container.addSubview(child)
        window.addSubview(container)

        XCTAssertFalse(BackGuardHostView.isFocusUnavailable(child))

        // Simulates _UIContextMenuContainerView disabling interaction while animating out after selection.
        container.isUserInteractionEnabled = false
        XCTAssertTrue(BackGuardHostView.isFocusUnavailable(child))

        container.isUserInteractionEnabled = true
        container.alpha = 0
        XCTAssertTrue(BackGuardHostView.isFocusUnavailable(child))

        container.alpha = 1
        container.isHidden = true
        XCTAssertTrue(BackGuardHostView.isFocusUnavailable(child))
    }
}

private final class FocusableStubView: UIView {
    override var canBecomeFocused: Bool { true }
}
