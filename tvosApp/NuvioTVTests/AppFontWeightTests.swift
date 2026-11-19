import CoreText
import SwiftUI
import UIKit
import XCTest
@testable import NuvioTV

final class AppFontWeightTests: XCTestCase {
    func testBundledInterHasNoSeparateWeightFonts() {
        // The bundled Inter is one variable font: only the regular name exists,
        // which is why weights must come from its weight axis.
        XCTAssertNotNil(UIFont(name: "Inter-Regular", size: 20))
        XCTAssertNil(UIFont(name: "Inter-Bold", size: 20))
        XCTAssertNil(UIFont(name: "Inter-SemiBold", size: 20))
        XCTAssertNil(UIFont(name: "Inter-Medium", size: 20))
    }

    func testInterWeightsSetTheWeightAxis() {
        let expected: [(Font.Weight, CGFloat)] = [(.regular, 400), (.medium, 500), (.semibold, 600), (.bold, 700)]
        for (weight, value) in expected {
            let font = AppFontManager.interUIFont(size: 32, weight: weight)
            XCTAssertEqual(font.familyName, "Inter", "\(weight) is not Inter")
            let variation = CTFontCopyVariation(font as CTFont) as? [Int: CGFloat]
            XCTAssertEqual(variation?[AppFontManager.wghtAxis] ?? 400, value, accuracy: 0.5, "\(weight)")
        }
    }

    func testBoldIsWiderThanRegular() {
        let text = "Settings" as NSString
        let regular = text.size(withAttributes: [.font: AppFontManager.interUIFont(size: 32, weight: .regular)]).width
        let bold = text.size(withAttributes: [.font: AppFontManager.interUIFont(size: 32, weight: .bold)]).width
        XCTAssertGreaterThan(bold, regular)
    }
}
