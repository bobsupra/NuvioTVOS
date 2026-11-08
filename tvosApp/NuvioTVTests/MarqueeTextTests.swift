import XCTest
@testable import NuvioTV

/// Long titles scroll on the focused card only when they don't fit (`MarqueeText`).
final class MarqueeTextTests: XCTestCase {
    func testOnlyTextThatDoesNotFitScrolls() {
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 300, boxWidth: 200, scale: 1), 100)
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 180, boxWidth: 200, scale: 1), 0)
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 200.4, boxWidth: 200, scale: 1), 1)
        // Text that may shrink first: it fits at 82 %, so it doesn't scroll…
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 240, boxWidth: 200, scale: 0.82), 0)
        // …and longer text scrolls at the smaller size.
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 400, boxWidth: 200, scale: 0.82), 128)
        // Not measured yet.
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 0, boxWidth: 200, scale: 1), 0)
        XCTAssertEqual(MarqueeText.overflow(fullWidth: 300, boxWidth: 0, scale: 1), 0)
    }

    func testTheLineGoesOutRestsAndComesBack() {
        // 90 pt at 45 pt/s: out in 2 s after the 1.2 s wait, 1.6 s rest, back in 0.6 s, 1.6 s rest.
        let distance: CGFloat = 90
        XCTAssertEqual(MarqueeText.position(elapsed: 0, distance: distance), 0)
        XCTAssertEqual(MarqueeText.position(elapsed: 1.0, distance: distance), 0)
        XCTAssertEqual(MarqueeText.position(elapsed: 2.2, distance: distance), 45, accuracy: 0.01)
        XCTAssertEqual(MarqueeText.position(elapsed: 3.2, distance: distance), 90, accuracy: 0.01)
        XCTAssertEqual(MarqueeText.position(elapsed: 4.5, distance: distance), 90, accuracy: 0.01)
        XCTAssertEqual(MarqueeText.position(elapsed: 5.1, distance: distance), 45, accuracy: 0.01)
        XCTAssertEqual(MarqueeText.position(elapsed: 6.0, distance: distance), 0, accuracy: 0.01)
        // The next round, one 5.8 s cycle later.
        XCTAssertEqual(MarqueeText.position(elapsed: 8.0, distance: distance), 45, accuracy: 0.01)
        // Nothing to scroll.
        XCTAssertEqual(MarqueeText.position(elapsed: 3.2, distance: 0), 0)
    }

    func testTheLineIsMeasuredInTheFontItIsDrawnIn() {
        let short = MarqueeText.width(of: "Naruto", size: 20, weight: .semibold)
        let long = MarqueeText.width(of: "JoJo's Bizarre Adventure: Steel Ball Run", size: 20, weight: .semibold)
        XCTAssertGreaterThan(short, 0)
        XCTAssertGreaterThan(long, short * 3)
        XCTAssertGreaterThan(MarqueeText.width(of: "Naruto", size: 28, weight: .semibold), short)
        XCTAssertGreaterThan(MarqueeText.lineHeight(size: 20, weight: .regular), 20)
    }
}
