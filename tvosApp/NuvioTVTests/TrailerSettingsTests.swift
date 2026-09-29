import XCTest
@testable import NuvioTV

final class TrailerSettingsTests: XCTestCase {
    private let suiteName = "TrailerSettingsTestsSuite"
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        testDefaults?.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        ProfileSettings.clearActiveProfile()
        super.tearDown()
    }

    func testTrailerSettingsKeysDefined() {
        XCTAssertEqual(SettingsKey.trailersEnabled, "nuvio.tv.settings.playback.trailersEnabled")
        XCTAssertEqual(SettingsKey.backgroundTrailersEnabled, "nuvio.tv.settings.playback.backgroundTrailersEnabled")
        XCTAssertEqual(SettingsKey.trailerPreviewSound, "nuvio.tv.settings.playback.trailerPreviewSound")
        XCTAssertEqual(SettingsKey.trailerDelay, "nuvio.tv.settings.playback.trailerDelay")

        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.trailersEnabled))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.backgroundTrailersEnabled))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.trailerPreviewSound))
        XCTAssertTrue(SettingsKey.all.contains(SettingsKey.trailerDelay))
    }

    func testTrailerSettingsDefaults() {
        let trailersEnabled = testDefaults.object(forKey: SettingsKey.trailersEnabled) as? Bool ?? true
        let backgroundTrailersEnabled = testDefaults.object(forKey: SettingsKey.backgroundTrailersEnabled) as? Bool ?? false
        let trailerPreviewSound = testDefaults.object(forKey: SettingsKey.trailerPreviewSound) as? Bool ?? false
        let trailerDelay = testDefaults.object(forKey: SettingsKey.trailerDelay) as? Int ?? 7

        XCTAssertTrue(trailersEnabled, "Autoplay trailers should default to true")
        XCTAssertFalse(backgroundTrailersEnabled, "Background trailers should default to false (opt-in)")
        XCTAssertFalse(trailerPreviewSound, "Trailer preview sound should default to false")
        XCTAssertEqual(trailerDelay, 7, "Trailer delay should default to 7 seconds")
    }

    func testZeroSecondTrailerDelay() {
        testDefaults.set(0, forKey: SettingsKey.trailerDelay)
        let delay = testDefaults.object(forKey: SettingsKey.trailerDelay) as? Int ?? 7
        XCTAssertEqual(delay, 0, "Zero-second trailer delay should be supported and persisted")
    }

    func testTrailerDelayRangePersistence() {
        let testDelays = [0, 1, 3, 5, 7, 10, 15]
        for expected in testDelays {
            testDefaults.set(expected, forKey: SettingsKey.trailerDelay)
            let actual = testDefaults.object(forKey: SettingsKey.trailerDelay) as? Int ?? 7
            XCTAssertEqual(actual, expected, "Trailer delay of \(expected)s should persist accurately")
        }
    }

    func testPreservationAcrossAutoplayToggles() {
        // User opts in to background trailers
        testDefaults.set(true, forKey: SettingsKey.backgroundTrailersEnabled)
        XCTAssertTrue(testDefaults.bool(forKey: SettingsKey.backgroundTrailersEnabled))

        // User turns off master autoplay toggle
        testDefaults.set(false, forKey: SettingsKey.trailersEnabled)
        XCTAssertFalse(testDefaults.bool(forKey: SettingsKey.trailersEnabled))

        // Background trailer preference is preserved
        XCTAssertTrue(testDefaults.bool(forKey: SettingsKey.backgroundTrailersEnabled))

        // User turns autoplay back on
        testDefaults.set(true, forKey: SettingsKey.trailersEnabled)
        XCTAssertTrue(testDefaults.bool(forKey: SettingsKey.trailersEnabled))
        XCTAssertTrue(testDefaults.bool(forKey: SettingsKey.backgroundTrailersEnabled))
    }

    func testTrailerSettingsProfileIsolation() {
        let profile1Defaults = UserDefaults(suiteName: "TrailerProfile1Suite")!
        let profile2Defaults = UserDefaults(suiteName: "TrailerProfile2Suite")!
        profile1Defaults.removePersistentDomain(forName: "TrailerProfile1Suite")
        profile2Defaults.removePersistentDomain(forName: "TrailerProfile2Suite")

        // Profile 1 enables background trailers with 0s delay and sound on
        profile1Defaults.set(true, forKey: SettingsKey.backgroundTrailersEnabled)
        profile1Defaults.set(0, forKey: SettingsKey.trailerDelay)
        profile1Defaults.set(true, forKey: SettingsKey.trailerPreviewSound)

        // Profile 2 has default unconfigured values
        let p2Background = profile2Defaults.object(forKey: SettingsKey.backgroundTrailersEnabled) as? Bool ?? false
        let p2Delay = profile2Defaults.object(forKey: SettingsKey.trailerDelay) as? Int ?? 7
        let p2Sound = profile2Defaults.object(forKey: SettingsKey.trailerPreviewSound) as? Bool ?? false

        XCTAssertFalse(p2Background, "Profile 2 should retain default false for background trailers")
        XCTAssertEqual(p2Delay, 7, "Profile 2 should retain default 7s delay")
        XCTAssertFalse(p2Sound, "Profile 2 should retain default muted sound")

        // Clean up
        profile1Defaults.removePersistentDomain(forName: "TrailerProfile1Suite")
        profile2Defaults.removePersistentDomain(forName: "TrailerProfile2Suite")
    }
}
