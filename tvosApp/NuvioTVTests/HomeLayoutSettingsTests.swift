import XCTest
@testable import NuvioTV

final class HomeLayoutSettingsTests: XCTestCase {
    func testFullscreenHeroBackdropSettingsKeyDefined() {
        XCTAssertEqual(SettingsKey.fullscreenHeroBackdrop, "nuvio.tv.settings.layout.fullscreenHeroBackdrop")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.fullscreenHeroBackdrop))
    }

    func testFullscreenHeroBackdropDefaultIsTrue() {
        let defaults = UserDefaults(suiteName: "HomeLayoutSettingsTestsDefaults")!
        defaults.removePersistentDomain(forName: "HomeLayoutSettingsTestsDefaults")

        // Default should be on (true)
        let isFullscreenDefault = defaults.object(forKey: SettingsKey.fullscreenHeroBackdrop) as? Bool ?? true
        XCTAssertTrue(isFullscreenDefault)

        // Can be toggled to false
        defaults.set(false, forKey: SettingsKey.fullscreenHeroBackdrop)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.fullscreenHeroBackdrop))

        // Can be toggled back to true
        defaults.set(true, forKey: SettingsKey.fullscreenHeroBackdrop)
        XCTAssertTrue(defaults.bool(forKey: SettingsKey.fullscreenHeroBackdrop))
    }

    func testLocalizationStringsExist() {
        let title = L10n.string("layout_fullscreen_hero_backdrop", fallback: "Fullscreen Hero Backdrop")
        let subtitle = L10n.string("layout_fullscreen_hero_backdrop_sub", fallback: "Expand the hero backdrop to fill the entire screen.")
        XCTAssertFalse(title.isEmpty)
        XCTAssertFalse(subtitle.isEmpty)

        L10n.reload(languageTag: "en")
        XCTAssertEqual(L10n.string("layout_fullscreen_hero_backdrop", fallback: "Fullscreen Hero Backdrop"), "Fullscreen Hero Backdrop")
        XCTAssertEqual(L10n.string("layout_fullscreen_hero_backdrop_sub", fallback: "Expand the hero backdrop to fill the entire screen."), "Expand the hero backdrop to fill the entire screen.")
    }

    func testCatalogAddonNamesSetting() {
        XCTAssertEqual(SettingsKey.catalogAddonNames, "nuvio.tv.settings.layout.catalogAddonNames")
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.catalogAddonNames))

        let defaults = UserDefaults(suiteName: "CatalogAddonNamesTestsDefaults")!
        defaults.removePersistentDomain(forName: "CatalogAddonNamesTestsDefaults")

        // Default should be true
        let isAddonNamesDefault = defaults.object(forKey: SettingsKey.catalogAddonNames) as? Bool ?? true
        XCTAssertTrue(isAddonNamesDefault)

        defaults.set(false, forKey: SettingsKey.catalogAddonNames)
        XCTAssertFalse(defaults.bool(forKey: SettingsKey.catalogAddonNames))
    }
}
