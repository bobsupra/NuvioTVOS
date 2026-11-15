import XCTest
import UIKit
@testable import NuvioTV

final class CardAppearanceTests: XCTestCase {
    func testEmptyStoreGivesTheCardDefaults() {
        let suite = "nuvio.tests.cardAppearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(CardAppearance.stored(in: defaults), CardAppearance())
        XCTAssertTrue(CardAppearance().liquidGlassCards)
        XCTAssertTrue(CardAppearance().smoothFocus)
        XCTAssertEqual(CardAppearance().trailerDelay, 7)
    }

    func testSavedSettingsAreRead() {
        let suite = "nuvio.tests.cardAppearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SettingsKey.liquidGlassCards)
        defaults.set(true, forKey: SettingsKey.posterLabels)
        defaults.set(12, forKey: SettingsKey.trailerDelay)
        defaults.set(CardCornerRadiusOption.pill.rawValue, forKey: SettingsKey.cardCornerRadius)
        defaults.set(true, forKey: SettingsKey.amoled)

        let appearance = CardAppearance.stored(in: defaults)
        XCTAssertFalse(appearance.liquidGlassCards)
        XCTAssertTrue(appearance.posterLabels)
        XCTAssertEqual(appearance.trailerDelay, 12)
        XCTAssertEqual(appearance.cardCornerRadius, CardCornerRadiusOption.pill.rawValue)
        XCTAssertTrue(appearance.amoled)
        XCTAssertFalse(appearance.amoledSurfaces)
    }

    func testLabelAndSpoilerSettingsAreRead() {
        let suite = "nuvio.tests.cardAppearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(CardAppearance().focusedPosterBackdropEnabled)
        XCTAssertEqual(CardAppearance().continueWatchingLabels, CardLabelVisibility.always.rawValue)
        XCTAssertFalse(CardAppearance().blurUnwatchedEpisodes)

        defaults.set(false, forKey: SettingsKey.focusedPosterBackdropEnabled)
        defaults.set(CardLabelVisibility.focused.rawValue, forKey: SettingsKey.continueWatchingLabels)
        defaults.set(true, forKey: SettingsKey.continueWatchingBlurNextUp)
        defaults.set(true, forKey: SettingsKey.blurUnwatchedEpisodes)
        defaults.set(true, forKey: SettingsKey.hideUnwatchedEpisodeTitles)
        defaults.set(true, forKey: SettingsKey.hideUnwatchedEpisodeDescriptions)
        let appearance = CardAppearance.stored(in: defaults)
        XCTAssertFalse(appearance.focusedPosterBackdropEnabled)
        XCTAssertEqual(appearance.continueWatchingLabels, CardLabelVisibility.focused.rawValue)
        XCTAssertTrue(appearance.continueWatchingBlurNextUp)
        XCTAssertTrue(appearance.blurUnwatchedEpisodes)
        XCTAssertTrue(appearance.hideUnwatchedEpisodeTitles)
        XCTAssertTrue(appearance.hideUnwatchedEpisodeDescriptions)
    }

    func testDetailsBackdropIsBlurredOnceAtASmallSize() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 720), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 720))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 640, y: 0, width: 640, height: 720))
        }
        let blurred = try XCTUnwrap(TvDetailsBlurredBackdrop.render(source))
        let cgImage = try XCTUnwrap(blurred.cgImage)
        XCTAssertEqual(cgImage.width, 640)
        XCTAssertEqual(cgImage.height, 360)
    }
}
