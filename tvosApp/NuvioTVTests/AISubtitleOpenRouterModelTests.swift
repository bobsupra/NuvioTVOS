import XCTest
@testable import NuvioTV

final class AISubtitleOpenRouterModelTests: XCTestCase {
    func testOpenRouterSubtitleModelIsChosenFromTheList() {
        XCTAssertEqual(AISubtitleTranslationSettings.normalizedOpenRouterModel(nil), "qwen/qwen3.7-flash")
        XCTAssertEqual(
            AISubtitleTranslationSettings.normalizedOpenRouterModel("anthropic/claude-haiku-4.5"),
            "anthropic/claude-haiku-4.5"
        )
        XCTAssertEqual(AISubtitleTranslationSettings.normalizedOpenRouterModel("some/typed-model"), "qwen/qwen3.7-flash")
        XCTAssertEqual(
            AISubtitleTranslationSettings.availableOpenRouterModels.first?.id,
            AISubtitleTranslationSettings.defaultOpenRouterModel
        )
    }
}
