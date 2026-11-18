import UIKit
import XCTest
@testable import NuvioTV

final class StreamSymbolTextTests: XCTestCase {
    func testEveryMappedSymbolExists() {
        for (emoji, symbol) in StreamSymbolText.symbols {
            XCTAssertNotNil(UIImage(systemName: symbol), "\(emoji) maps to \(symbol), which is not an SF Symbol")
        }
    }

    func testCommonFormatterEmojiAreMapped() {
        for emoji in ["🎬", "🔊", "🌐", "📝", "⚡"] {
            XCTAssertNotNil(StreamSymbolText.symbols[emoji], "\(emoji) has no symbol")
        }
    }

    func testSymbolsAreOffByDefault() {
        XCTAssertFalse(StreamListStyle().symbolIcons)
    }
}
