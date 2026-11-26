import SwiftUI
import UIKit
import os

private let brandingLog = Logger(subsystem: "com.pyksel.nuviotvos", category: "branding")

/// Settings > Look > Appearance > Nuvio Android TV Styling > Nuvio Branding:
/// the Nuvio look of the Android TV and desktop apps, that is the Nuvio app
/// icon, the launch banner, the sign-in screen and the profile loading screen.
/// Off by default, which keeps the app's own look.
///
/// The choice belongs to this Apple TV, not to a profile or the account: the
/// sign-in screen shows before any profile exists, and the icon belongs to the
/// app. Both keys live in the standard defaults, outside settings sync.
enum NuvioBranding {
    static let key = "nuvio.tv.device.nuvioBranding"
    /// The Nuvio icon chosen under App Icon, used while the switch is on.
    static let appIconKey = "nuvio.tv.device.appIcon"

    /// Reads the switch as `@AppStorage` does, so a `-nuvio.tv.device.nuvioBranding YES`
    /// launch argument counts too.
    static var isOn: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static var appIcon: NuvioAppIcon {
        NuvioAppIcon(rawValue: UserDefaults.standard.string(forKey: appIconKey) ?? "") ?? .original
    }

    /// Puts the Home Screen icon in line with the switch and the chosen icon:
    /// the app's own icon with the switch off, the chosen Nuvio icon with it
    /// on. tvOS shows its own notice when the icon changes.
    @MainActor
    static func applyIcon() {
        let app = UIApplication.shared
        guard app.supportsAlternateIcons else { return }
        let wanted: String? = isOn ? appIcon.alternateIconName : nil
        guard app.alternateIconName != wanted else { return }
        app.setAlternateIconName(wanted) { error in
            if let error {
                brandingLog.error("App icon change failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

/// The Nuvio app icons, the same six the desktop app offers. All six are
/// alternate icons; the app's primary icon stays its own.
enum NuvioAppIcon: String, CaseIterable, Identifiable {
    case original
    case arcticBlue = "arctic_blue"
    case emerald
    case roseGold = "rose_gold"
    case copper
    case graphite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: return L10n.string("tvos_app_icon_original", fallback: "Original")
        case .arcticBlue: return L10n.string("tvos_app_icon_arctic_blue", fallback: "Arctic Blue")
        case .emerald: return L10n.string("tvos_app_icon_emerald", fallback: "Emerald")
        case .roseGold: return L10n.string("tvos_app_icon_rose_gold", fallback: "Rose Gold")
        case .copper: return L10n.string("tvos_app_icon_copper", fallback: "Copper")
        case .graphite: return L10n.string("tvos_app_icon_graphite", fallback: "Graphite")
        }
    }

    private var assetSuffix: String {
        switch self {
        case .original: return "Original"
        case .arcticBlue: return "ArcticBlue"
        case .emerald: return "Emerald"
        case .roseGold: return "RoseGold"
        case .copper: return "Copper"
        case .graphite: return "Graphite"
        }
    }

    /// The icon's name in the asset catalog. Project.swift lists every name in
    /// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`.
    var alternateIconName: String { "NuvioIcon\(assetSuffix)" }

    var previewImageName: String { "NuvioIconPreview\(assetSuffix)" }
}

/// The splash over the app's first second: the Nuvio banner with Nuvio
/// Branding on, or the app's own wordmark with it off. It stands in for the
/// launch screen, which tvOS fixes at build time and so can't follow the
/// switch. The launch screen itself shows only the splash background colour.
struct LaunchSplashOverlay: View {
    @State private var visible = true
    /// Read once: the splash belongs to this launch.
    private let nuvioBranding = NuvioBranding.isOn

    private static let banner: UIImage? = {
        guard let path = Bundle.main.path(forResource: "NuvioLaunchBanner", ofType: "png") else { return nil }
        return UIImage(contentsOfFile: path)
    }()

    var body: some View {
        if visible {
            Group {
                if nuvioBranding, let banner = Self.banner {
                    Image(uiImage: banner)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    // The app's own launch screen: the wordmark fitted to
                    // the screen on the splash background.
                    ZStack {
                        Color("SplashScreenBackground")
                        Image("SplashScreenLegacy")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
            .task {
                try? await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeOut(duration: 0.35)) { visible = false }
            }
        }
    }
}
