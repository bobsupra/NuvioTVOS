import SwiftUI

/// The app's top-level destinations. The raw value is the stable selection
/// identity; `title` and `symbol` are what the sidebar shows.
enum TVTab: String, CaseIterable, Identifiable {
    case profile = "Profile"
    case home = "Home"
    case search = "Search"
    case library = "Library"
    case settings = "Settings"

    var id: String { rawValue }

    /// Localized tab label (rawValue remains stable for selection identity).
    var title: String {
        switch self {
        case .profile:
            return L10n.string("settings_profiles", fallback: "Profile")
        case .home:
            return L10n.string("nav_home", fallback: "Home")
        case .search:
            return L10n.string("nav_search", fallback: "Search")
        case .library:
            return L10n.string("nav_library", fallback: "Library")
        case .settings:
            return L10n.string("nav_settings", fallback: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .home: return "house"
        case .search: return "magnifyingglass"
        case .library: return "rectangle.stack"
        case .settings: return "gearshape"
        }
    }
}
