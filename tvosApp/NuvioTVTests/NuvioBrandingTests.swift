import UIKit
import XCTest
@testable import NuvioTV

/// Settings > Look > Appearance > Nuvio Branding and App Icon.
final class NuvioBrandingTests: XCTestCase {
    func testBrandingIsOffUntilSwitchedOnAndStaysOutOfSettingsSync() {
        withSavedValue(for: NuvioBranding.key) { defaults in
            defaults.removeObject(forKey: NuvioBranding.key)
            XCTAssertFalse(NuvioBranding.isOn)
            defaults.set(true, forKey: NuvioBranding.key)
            XCTAssertTrue(NuvioBranding.isOn)
            // A `-nuvio.tv.device.nuvioBranding YES` launch argument arrives as text,
            // and the splash must read it as the sign-in screen's @AppStorage does.
            defaults.set("YES", forKey: NuvioBranding.key)
            XCTAssertTrue(NuvioBranding.isOn)
        }
        // The switch and the icon belong to this Apple TV, not to the synced settings.
        XCTAssertFalse(SettingsKey.all.contains(NuvioBranding.key))
        XCTAssertFalse(SettingsKey.all.contains(NuvioBranding.appIconKey))
    }

    func testAnUnknownSavedIconFallsBackToOriginal() {
        withSavedValue(for: NuvioBranding.appIconKey) { defaults in
            defaults.set("no-such-icon", forKey: NuvioBranding.appIconKey)
            XCTAssertEqual(NuvioBranding.appIcon, .original)
            defaults.set(NuvioAppIcon.copper.rawValue, forKey: NuvioBranding.appIconKey)
            XCTAssertEqual(NuvioBranding.appIcon, .copper)
        }
    }

    func testTheDesktopAppsSixIconsInItsOrder() {
        XCTAssertEqual(
            NuvioAppIcon.allCases.map(\.label),
            ["Original", "Arctic Blue", "Emerald", "Rose Gold", "Copper", "Graphite"]
        )
    }

    func testEveryNuvioIconIsBuiltAsAnAlternateIcon() {
        // The asset catalog compiler lists each alternate icon it built here,
        // from ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES in Project.swift:
        // keyed by name, or as a plain list of names.
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let built: Set<String>
        switch icons?["CFBundleAlternateIcons"] {
        case let names as [String]: built = Set(names)
        case let byName as [String: Any]: built = Set(byName.keys)
        default: built = []
        }
        XCTAssertEqual(built, Set(NuvioAppIcon.allCases.map(\.alternateIconName)))
        // The app's own icon stays the primary one.
        let primary = icons?["CFBundlePrimaryIcon"]
        XCTAssertNotNil(primary)
        XCTAssertFalse(String(describing: primary ?? "").contains("NuvioIcon"))
    }

    func testThePreviewsWordmarkAndBannerShipWithTheApp() {
        for icon in NuvioAppIcon.allCases {
            XCTAssertNotNil(UIImage(named: icon.previewImageName), icon.previewImageName)
        }
        XCTAssertNotNil(UIImage(named: "NuvioWordmark"))
        XCTAssertNotNil(Bundle.main.path(forResource: "NuvioLaunchBanner", ofType: "png"))
        // The splash drawn over the first second with Nuvio Branding off.
        XCTAssertNotNil(UIImage(named: "SplashScreenLegacy"))
    }

    private func withSavedValue(for key: String, _ body: (UserDefaults) -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer {
            if let saved {
                defaults.set(saved, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        body(defaults)
    }
}
