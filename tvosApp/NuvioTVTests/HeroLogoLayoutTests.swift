import XCTest
import UIKit
@testable import NuvioTV

final class HeroLogoLayoutTests: XCTestCase {
    func testLogosOfDifferentShapesGetTheSameArea() {
        let wide = HeroLogoLayout.size(aspect: 4, maxWidth: 520, maxHeight: 136)
        let narrower = HeroLogoLayout.size(aspect: 3, maxWidth: 520, maxHeight: 136)
        let area = HeroLogoLayout.areaShare * 520 * 136

        XCTAssertEqual(wide.width * wide.height, area, accuracy: area * 0.01)
        XCTAssertEqual(narrower.width * narrower.height, area, accuracy: area * 0.01)
        XCTAssertLessThan(wide.height, narrower.height)
    }

    func testASquareLogoStopsAtTheMaximumHeight() {
        XCTAssertEqual(
            HeroLogoLayout.size(aspect: 1, maxWidth: 520, maxHeight: 136),
            CGSize(width: 136, height: 136)
        )
    }

    func testAVeryWideLogoStopsAtTheMaximumWidth() {
        XCTAssertEqual(
            HeroLogoLayout.size(aspect: 10, maxWidth: 520, maxHeight: 136),
            CGSize(width: 520, height: 52)
        )
    }

    func testTransparentMarginsAreLeftOut() {
        let image = Self.logo(canvas: CGSize(width: 100, height: 40), visible: CGRect(x: 10, y: 5, width: 60, height: 20))

        XCTAssertEqual(HeroLogoLayout.visibleRect(of: image), CGRect(x: 10, y: 5, width: 60, height: 20))
    }

    func testTheVisiblePartIsInPoints() {
        let image = Self.logo(canvas: CGSize(width: 50, height: 20), visible: CGRect(x: 5, y: 3, width: 30, height: 10), scale: 2)

        XCTAssertEqual(HeroLogoLayout.visibleRect(of: image), CGRect(x: 5, y: 3, width: 30, height: 10))
    }

    func testALogoWithoutMarginsIsShownWhole() {
        let image = Self.logo(canvas: CGSize(width: 50, height: 20), visible: CGRect(x: 0, y: 0, width: 50, height: 20))

        XCTAssertEqual(HeroLogoLayout.visibleRect(of: image), CGRect(x: 0, y: 0, width: 50, height: 20))
    }

    func testAnEmptyLogoIsShownWhole() {
        let image = Self.logo(canvas: CGSize(width: 50, height: 20), visible: .zero)

        XCTAssertEqual(HeroLogoLayout.visibleRect(of: image), CGRect(x: 0, y: 0, width: 50, height: 20))
    }

    private static func logo(canvas: CGSize, visible: CGRect, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor.red.setFill()
            context.fill(visible)
        }
    }
}
