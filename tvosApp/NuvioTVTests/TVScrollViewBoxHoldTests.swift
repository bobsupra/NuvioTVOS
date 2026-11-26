import UIKit
import XCTest
@testable import NuvioTV

/// A Home row moves itself through its UIKit scroll view, and holds the offset it set for a
/// moment, because SwiftUI's scroll view could put its own older offset back.
@MainActor
final class TVScrollViewBoxHoldTests: XCTestCase {
    /// A 1000-point-wide row with 5000 points of cards, so offsets run from 0 to 4000.
    private func makeRow() -> (TVScrollViewBox, UIScrollView) {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 1_000, height: 300))
        scrollView.contentSize = CGSize(width: 5_000, height: 300)
        let box = TVScrollViewBox()
        box.scrollView = scrollView
        return (box, scrollView)
    }

    func testHeldOffsetIsPutBackWhenSomethingElseMovesTheRow() {
        let (box, scrollView) = makeRow()
        box.hold(714, for: 1)
        scrollView.contentOffset.x = 714

        scrollView.contentOffset.x = 476

        XCTAssertEqual(scrollView.contentOffset.x, 714)
    }

    func testANewHoldLetsTheRowMoveOn() {
        let (box, scrollView) = makeRow()
        box.hold(714, for: 1)
        scrollView.contentOffset.x = 714

        box.hold(952, for: 1)
        scrollView.contentOffset.x = 952

        XCTAssertEqual(scrollView.contentOffset.x, 952)
    }

    func testOffsetIsNoLongerHeldOnceTheHoldEnds() {
        let (box, scrollView) = makeRow()
        box.hold(714, for: 0)
        scrollView.contentOffset.x = 714

        scrollView.contentOffset.x = 476

        XCTAssertEqual(scrollView.contentOffset.x, 476)
    }

    func testHeldOffsetStaysInsideContentThatShrank() {
        let (box, scrollView) = makeRow()
        box.hold(4_000, for: 1)
        scrollView.contentOffset.x = 4_000

        scrollView.contentSize.width = 4_800
        scrollView.contentOffset.x = 3_000

        XCTAssertEqual(scrollView.contentOffset.x, 3_800)
    }

    func testAnotherScrollViewIsNotHeld() {
        let (box, scrollView) = makeRow()
        box.hold(714, for: 1)
        scrollView.contentOffset.x = 714

        let replacement = UIScrollView(frame: scrollView.frame)
        replacement.contentSize = scrollView.contentSize
        box.scrollView = replacement
        scrollView.contentOffset.x = 476
        replacement.contentOffset.x = 238

        XCTAssertEqual(scrollView.contentOffset.x, 476)
        XCTAssertEqual(replacement.contentOffset.x, 238)
    }
}
