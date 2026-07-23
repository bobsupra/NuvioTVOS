import SwiftUI
import UIKit

enum AppFocusOutline {
    static var color: Color {
        let theme = ProfileSettings.current.string(forKey: SettingsKey.theme)
            ?? SettingsAccent.white.rawValue
        return SettingsAccent.color(for: theme)
    }
    static let width: CGFloat = 4
    static let emphasizedWidth: CGFloat = 6
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case account = "Account & Profiles"
    case appearance = "Appearance"
    case layout = "Layout & Discovery"
    case integrations = "Integrations"
    case playback = "Playback"
    case subtitles = "Subtitle Style"
    case advanced = "Advanced"
    case about = "About"

    var id: String { rawValue }

    /// Localized category title. `rawValue` stays English for stable identity.
    var title: String {
        switch self {
        case .account:
            return L10n.string("settings_account", fallback: "Account")
        case .appearance:
            return L10n.string("appearance_title", fallback: "Appearance")
        case .layout:
            return L10n.string("settings_layout", fallback: "Layout")
        case .integrations:
            return L10n.string("settings_integration", fallback: "Integrations")
        case .playback:
            return L10n.string("settings_playback", fallback: "Playback")
        case .subtitles:
            return L10n.string("tvos_settings_subtitle_style", fallback: "Subtitle Style")
        case .advanced:
            return L10n.string("settings_advanced", fallback: "Advanced")
        case .about:
            return L10n.string("about_title", fallback: "About")
        }
    }

    var subtitle: String {
        switch self {
        case .account:
            return L10n.string(
                "settings_account_subtitle",
                fallback: "Account and sync status"
            )
        case .appearance:
            return L10n.string(
                "appearance_subtitle",
                fallback: "Choose your color theme, font and language"
            )
        case .layout:
            return L10n.string(
                "settings_layout_subtitle",
                fallback: "Home structure and poster styles"
            )
        case .integrations:
            return L10n.string(
                "settings_integrations_section_subtitle",
                fallback: "Manage available integrations"
            )
        case .playback:
            return L10n.string(
                "settings_playback_subtitle",
                fallback: "Player, subtitles, and auto-play"
            )
        case .subtitles:
            return L10n.string(
                "tvos_settings_subtitle_style_subtitle",
                fallback: "How subtitles look on every video you watch"
            )
        case .advanced:
            return L10n.string(
                "settings_advanced_subtitle",
                fallback: "Performance, navigation, cache, and diagnostics"
            )
        case .about:
            return L10n.string(
                "about_subtitle",
                fallback: "App information, updates, and legal links"
            )
        }
    }

    var iconName: String {
        switch self {
        case .account: return "person.crop.circle"
        case .appearance: return "paintpalette"
        case .layout: return "rectangle.grid.2x2"
        case .integrations: return "link"
        case .playback: return "play.circle"
        case .subtitles: return "captions.bubble"
        case .advanced: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

enum SettingsKey {
    static let profileName = "nuvio.tv.settings.profile.name"
    static let profilePinEnabled = "nuvio.tv.settings.profile.pinEnabled"
    static let profileAutoSelectLast = "nuvio.tv.settings.profile.autoSelectLast"
    static let accountSyncWatchState = "nuvio.tv.settings.account.syncWatchState"

    static let theme = "nuvio.tv.settings.appearance.theme"
    static let bodyColor = "nuvio.tv.settings.appearance.bodyColor"
    static let font = "nuvio.tv.settings.appearance.font"
    static let language = "nuvio.tv.settings.appearance.language"
    static let amoled = "nuvio.tv.settings.appearance.amoled"
    static let amoledSurfaces = "nuvio.tv.settings.appearance.amoledSurfaces"
    static let reduceMotion = "nuvio.tv.settings.appearance.reduceMotion"

    static let homeLayout = "nuvio.tv.settings.layout.homeLayout"
    /// JSON `[String]` of home section ids in the user's preferred order.
    static let homeCatalogOrder = "nuvio.tv.settings.layout.homeCatalogOrder"
    /// JSON `[String: String]` snapshot of section id → title, written by Home
    /// on every load so the Settings reorder list knows the display names.
    /// Local-only derived data (not part of `all`).
    static let homeCatalogTitles = "nuvio.tv.settings.layout.homeCatalogTitles"
    /// JSON `[String]` of account catalog keys (`<addonId>_<type>_<catalogId>`)
    /// the user has hidden from Home. Pulled from the account's home-catalog
    /// settings; the repository skips these rows. Not part of `all` — it syncs
    /// through its own RPC, not the tvOS settings blob.
    static let homeCatalogDisabled = "nuvio.tv.settings.layout.homeCatalogDisabled"
    /// Collection ids hidden from Home via the account layout sync.
    static let homeCollectionDisabled = "nuvio.tv.settings.layout.homeCollectionDisabled"
    /// JSON `[String]` of account catalog keys (`<addonId>_<type>_<catalogId>`)
    /// in the account's Home order. The repository orders the add-on catalog
    /// rows by this; kept separate from `homeCatalogOrder` (the local tvOS
    /// reorder) so a pull never disturbs the built-in rows or a local reorder.
    static let homeCatalogSyncedOrder = "nuvio.tv.settings.layout.homeCatalogSyncedOrder"
    static let heroEnabled = "nuvio.tv.settings.layout.heroEnabled"
    /// JSON `[String]` of Home section ids selected as Grid View hero sources.
    /// Empty means all available catalog rows.
    static let heroCatalogs = "nuvio.tv.settings.layout.heroCatalogs"
    static let posterLabels = "nuvio.tv.settings.layout.posterLabels"
    static let catalogAddonNames = "nuvio.tv.settings.layout.catalogAddonNames"
    static let discoverLocation = "nuvio.tv.settings.layout.discoverLocation"
    static let continueWatchingSort = "nuvio.tv.settings.layout.continueWatchingSort"
    static let showUnairedNextUp = "nuvio.tv.settings.layout.showUnairedNextUp"
    static let hideUnreleased = "nuvio.tv.settings.layout.hideUnreleased"
    static let showFullDates = "nuvio.tv.settings.layout.showFullDates"

    static let traktConnected = "nuvio.tv.settings.integrations.traktConnected"
    static let traktClientID = "nuvio.tv.settings.integrations.traktClientID"
    static let traktClientSecret = "nuvio.tv.settings.integrations.traktClientSecret"
    static let traktContinueWatchingDaysCap = "nuvio.tv.settings.integrations.traktContinueWatchingDaysCap"
    static let traktShowMetaComments = "nuvio.tv.settings.integrations.traktShowMetaComments"
    static let traktWatchProgressSource = "nuvio.tv.settings.integrations.traktWatchProgressSource"
    static let traktLibrarySourceMode = "nuvio.tv.settings.integrations.traktLibrarySourceMode"
    static let traktMoreLikeThisSource = "nuvio.tv.settings.integrations.traktMoreLikeThisSource"
    static let tmdbEnabled = "nuvio.tv.settings.integrations.tmdbEnabled"
    static let tmdbApiKey = "nuvio.tv.settings.integrations.tmdbApiKey"
    static let mdbListEnabled = "nuvio.tv.settings.integrations.mdbListEnabled"
    static let mdbListApiKey = "nuvio.tv.settings.integrations.mdbListApiKey"
    static let debridProvider = "nuvio.tv.settings.integrations.debridProvider"
    static let debridApiKey = "nuvio.tv.settings.integrations.debridApiKey"
    /// Provider-specific device-flow tokens. Keeping them separate matches the
    /// Android TV debrid screen so multiple providers can stay linked.
    static let torboxAccessToken = "nuvio.tv.settings.integrations.torboxAccessToken"
    static let premiumizeAccessToken = "nuvio.tv.settings.integrations.premiumizeAccessToken"
    static let realDebridAccessToken = "nuvio.tv.settings.integrations.realDebridAccessToken"
    static let streamAddonManifestURL = "nuvio.tv.settings.integrations.streamAddonManifestURL"
    static let streamAddonManifestURLs = "nuvio.tv.settings.integrations.streamAddonManifestURLs"
    static let streamAddonManifestStates = "nuvio.tv.settings.integrations.streamAddonManifestStates"

    static let playerEngine = "nuvio.tv.settings.playback.playerEngine"
    static let externalPlayer = "nuvio.tv.settings.playback.externalPlayer"
    static let smartStreamSelection = "nuvio.tv.settings.playback.smartStreamSelection"
    static let smartStreamQuality = "nuvio.tv.settings.playback.smartStreamQuality"
    static let smartSubtitleMatching = "nuvio.tv.settings.playback.smartSubtitleMatching"
    static let cachedOnlyStreams = "nuvio.tv.settings.playback.cachedOnlyStreams"
    static let autoPlayNext = "nuvio.tv.settings.playback.autoPlayNext"
    static let trailersEnabled = "nuvio.tv.settings.playback.trailersEnabled"
    static let trailerDelay = "nuvio.tv.settings.playback.trailerDelay"
    static let audioLanguage = "nuvio.tv.settings.playback.audioLanguage"
    static let subtitleLanguages = "nuvio.tv.settings.playback.subtitleLanguages"
    static let subtitleLanguage = "nuvio.tv.settings.playback.subtitleLanguage"
    static let subtitleLanguageSecondary = "nuvio.tv.settings.playback.subtitleLanguage.secondary"
    static let subtitleLanguageTertiary = "nuvio.tv.settings.playback.subtitleLanguage.tertiary"
    static let forcedSubtitles = "nuvio.tv.settings.playback.forcedSubtitles"
    static let subtitleSize = "nuvio.tv.settings.playback.subtitleSize"
    static let frameRateMatching = "nuvio.tv.settings.playback.frameRateMatching"
    static let networkCache = "nuvio.tv.settings.playback.networkCache"
    static let playbackTrackSelections = "nuvio.tv.settings.playback.trackSelections"
    static let externalPlayerForwardSubtitles = "nuvio.tv.settings.playback.externalPlayerForwardSubtitles"
    static let assOverrideMode = "nuvio.tv.settings.playback.assOverrideMode"

    static let fastNavigation = "nuvio.tv.settings.advanced.fastNavigation"
    static let smoothFocus = "nuvio.tv.settings.advanced.smoothFocus"
    static let playbackDiagnostics = "nuvio.tv.settings.advanced.playbackDiagnostics"
    static let focusHighlighter = "nuvio.tv.settings.advanced.focusHighlighter"

    /// API app credentials must remain on the Apple TV and never enter the
    /// account settings payload.
    static let deviceLocal = Set([traktClientID, traktClientSecret])

    static let all = [
        profileName, profilePinEnabled, profileAutoSelectLast, accountSyncWatchState,
        theme, bodyColor, font, language, amoled, amoledSurfaces, reduceMotion,
        homeLayout, heroEnabled, heroCatalogs, posterLabels, catalogAddonNames, discoverLocation,
        continueWatchingSort, showUnairedNextUp, hideUnreleased, showFullDates,
        traktConnected, traktClientID, traktClientSecret,
        traktContinueWatchingDaysCap, traktShowMetaComments,
        traktWatchProgressSource, traktLibrarySourceMode, traktMoreLikeThisSource,
        tmdbEnabled, tmdbApiKey, mdbListEnabled, mdbListApiKey,
        debridProvider, debridApiKey, torboxAccessToken, premiumizeAccessToken, realDebridAccessToken,
        streamAddonManifestURL, streamAddonManifestURLs,
        streamAddonManifestStates,
        playerEngine, externalPlayer, smartStreamSelection, smartStreamQuality, smartSubtitleMatching,
        cachedOnlyStreams, autoPlayNext, trailersEnabled, trailerDelay, audioLanguage,
        subtitleLanguages, subtitleLanguage, subtitleLanguageSecondary, subtitleLanguageTertiary,
        forcedSubtitles, subtitleSize, frameRateMatching, networkCache, playbackTrackSelections,
        externalPlayerForwardSubtitles, assOverrideMode,
        fastNavigation, smoothFocus, playbackDiagnostics, focusHighlighter
    ] + SubtitleStyleKey.all
}

// MARK: - Subtitle styling (applied to every MPV playback session)

enum SubtitleStyleKey {
    static let textSize = "nuvio.tv.settings.subtitleStyle.textSize"
    static let bold = "nuvio.tv.settings.subtitleStyle.bold"
    static let bottomOffset = "nuvio.tv.settings.subtitleStyle.bottomOffset"
    static let horizontalMargin = "nuvio.tv.settings.subtitleStyle.horizontalMargin"
    static let letterSpacing = "nuvio.tv.settings.subtitleStyle.letterSpacing"
    static let textColor = "nuvio.tv.settings.subtitleStyle.textColor"
    static let textOpacity = "nuvio.tv.settings.subtitleStyle.textOpacity"
    static let outlineEnabled = "nuvio.tv.settings.subtitleStyle.outlineEnabled"
    static let outlineColor = "nuvio.tv.settings.subtitleStyle.outlineColor"

    static let all = [
        textSize, bold, bottomOffset, horizontalMargin, letterSpacing,
        textColor, textOpacity, outlineEnabled, outlineColor
    ]
}

enum SubtitleStyleDefaults {
    static let textSize = 100        // percent, 60...220
    static let bold = false
    static let bottomOffset = 20     // 0...160, raises subtitles off the bottom edge
    static let horizontalMargin = 25 // 0...200, left+right inset (mpv default is 25)
    static let letterSpacing = 0     // -8...40, negative squeezes, positive opens the text
    static let textColor = "#FFFFFF"
    static let textOpacity = 100     // percent, 20...100
    static let outlineEnabled = true
    static let outlineColor = "#000000"
}

/// Curated swatch palette shared by the text-color and outline-color pickers.
enum SubtitlePalette {
    static let colors: [String] = [
        "#FFFFFF", "#F2C94C", "#56CCF2", "#EB5757", "#6FCF97",
        "#9B51E0", "#F2994A", "#27AE60", "#2F80ED", "#000000"
    ]
}

/// Snapshot of the persisted subtitle appearance. Read by the player to style
/// every libmpv session and by the settings live preview. Defaults mirror
/// `SubtitleStyleDefaults` so a fresh install renders white, outlined captions.
struct SubtitleStyle {
    var textSize: Int
    var bold: Bool
    var bottomOffset: Int
    var horizontalMargin: Int
    var letterSpacing: Int
    var textColorHex: String
    var textOpacity: Int
    var outlineEnabled: Bool
    var outlineColorHex: String

    static var current: SubtitleStyle {
        let defaults = ProfileSettings.current
        func intValue(_ key: String, _ fallback: Int) -> Int {
            defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
        }
        func boolValue(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        func stringValue(_ key: String, _ fallback: String) -> String {
            defaults.string(forKey: key) ?? fallback
        }
        return SubtitleStyle(
            textSize: intValue(SubtitleStyleKey.textSize, SubtitleStyleDefaults.textSize),
            bold: boolValue(SubtitleStyleKey.bold, SubtitleStyleDefaults.bold),
            bottomOffset: intValue(SubtitleStyleKey.bottomOffset, SubtitleStyleDefaults.bottomOffset),
            horizontalMargin: intValue(SubtitleStyleKey.horizontalMargin, SubtitleStyleDefaults.horizontalMargin),
            letterSpacing: intValue(SubtitleStyleKey.letterSpacing, SubtitleStyleDefaults.letterSpacing),
            textColorHex: stringValue(SubtitleStyleKey.textColor, SubtitleStyleDefaults.textColor),
            textOpacity: intValue(SubtitleStyleKey.textOpacity, SubtitleStyleDefaults.textOpacity),
            outlineEnabled: boolValue(SubtitleStyleKey.outlineEnabled, SubtitleStyleDefaults.outlineEnabled),
            outlineColorHex: stringValue(SubtitleStyleKey.outlineColor, SubtitleStyleDefaults.outlineColor)
        )
    }

    // MARK: libmpv property mapping

    /// `sub-scale` — relative subtitle text size.
    var subScale: Double { min(max(Double(textSize) / 100.0, 0.4), 3.0) }
    /// `sub-margin-y` — lifts captions off the bottom edge (22 is mpv's default).
    var subMarginY: Int { 22 + min(max(bottomOffset, 0), 160) }
    /// `sub-margin-x` — left+right screen inset in scaled pixels.
    var subMarginX: Int { min(max(horizontalMargin, 0), 200) }
    /// `sub-spacing` — extra letter spacing; negative squeezes, positive opens.
    var subSpacing: Int { min(max(letterSpacing, -8), 40) }
    /// `sub-outline-size` — 0 collapses the border entirely.
    var subOutlineSize: Double { outlineEnabled ? 3.0 : 0.0 }
    /// `sub-color` — `#AARRGGBB`, alpha carries Text Opacity.
    var subColor: String { Self.mpvColor(hex: textColorHex, opacity: textOpacity) }
    /// `sub-outline-color` — always fully opaque.
    var subOutlineColor: String { Self.mpvColor(hex: outlineColorHex, opacity: 100) }

    /// mpv expects colors as `#AARRGGBB`. Opacity is a 0–100 percentage.
    static func mpvColor(hex: String, opacity: Int) -> String {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let rgb = raw.count >= 6 ? String(raw.prefix(6)) : "FFFFFF"
        let alpha = Int((Double(min(max(opacity, 0), 100)) / 100.0 * 255.0).rounded())
        return String(format: "#%02X%@", alpha, rgb.uppercased())
    }
}

enum SubtitleLanguagePreferences {
    static let disabledValues = ["System", "None"]
    static let supportedLanguages = [
        "English", "Arabic", "Bulgarian", "Chinese", "Croatian", "Czech",
        "Danish", "Dutch", "Finnish", "French", "German", "Greek", "Hebrew",
        "Hindi", "Hungarian", "Indonesian", "Italian", "Japanese", "Korean",
        "Norwegian", "Polish", "Portuguese", "Romanian", "Russian", "Spanish",
        "Swedish", "Thai", "Turkish", "Ukrainian", "Vietnamese"
    ]
    static let settingsOptions = ["System"] + supportedLanguages

    private static let languageCodes: [String: [String]] = [
        "Arabic": ["ara", "ar"],
        "Bulgarian": ["bul", "bg"],
        "Chinese": ["chi", "zho", "zh", "cn"],
        "Croatian": ["hrv", "hr"],
        "Czech": ["cze", "ces", "cs"],
        "Danish": ["dan", "da"],
        "Dutch": ["dut", "nld", "nl"],
        "English": ["eng", "en"],
        "Finnish": ["fin", "fi"],
        "French": ["fre", "fra", "fr"],
        "German": ["ger", "deu", "de"],
        "Greek": ["gre", "ell", "el"],
        "Hebrew": ["heb", "he"],
        "Hindi": ["hin", "hi"],
        "Hungarian": ["hun", "hu"],
        "Indonesian": ["ind", "id"],
        "Italian": ["ita", "it"],
        "Japanese": ["jpn", "ja"],
        "Korean": ["kor", "ko"],
        "Norwegian": ["nor", "nb", "no"],
        "Polish": ["pol", "pl"],
        "Portuguese": ["por", "pt", "pob", "pb"],
        "Romanian": ["rum", "ron", "ro"],
        "Russian": ["rus", "ru"],
        "Spanish": ["spa", "es"],
        "Swedish": ["swe", "sv"],
        "Thai": ["tha", "th"],
        "Turkish": ["tur", "tr"],
        "Ukrainian": ["ukr", "uk"],
        "Vietnamese": ["vie", "vi"]
    ]

    private static let languageAliases: [String: [String]] = [
        "Chinese": ["chinese", "mandarin", "cantonese"],
        "Dutch": ["dutch", "nederlands"],
        "Greek": ["greek", "ellinika"],
        "Norwegian": ["norwegian", "norsk", "bokmal", "bokmaal"],
        "Portuguese": ["portuguese", "portugues", "português", "brazilian", "brasil"],
        "Russian": ["russian", "russkiy", "русский"],
        "Spanish": ["spanish", "espanol", "español", "castellano"],
        "Turkish": ["turkish", "turkce", "türkçe"]
    ]

    static func ordered(_ languages: [String]) -> [String] {
        var seen: Set<String> = []
        return languages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { language in
                !language.isEmpty &&
                !isDisabled(language) &&
                seen.insert(normalized(language)).inserted
            }
    }

    static func ordered(primary: String, secondary: String, tertiary: String) -> [String] {
        // System is an explicit no-filter mode. It must override stale legacy
        // secondary/tertiary slots so every language remains visible.
        guard primary.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("System") != .orderedSame else {
            return []
        }
        return ordered([primary, secondary, tertiary])
    }

    /// Reads the unlimited ordered selection. A present JSON `[]` is an
    /// intentional System choice; an absent/invalid value falls back to the
    /// legacy three slots so existing profiles migrate without losing choices.
    static func ordered(
        encoded: String,
        primary: String,
        secondary: String,
        tertiary: String
    ) -> [String] {
        if let decoded = decodedLanguages(encoded) {
            return decoded
        }
        return ordered(primary: primary, secondary: secondary, tertiary: tertiary)
    }

    static func orderedFromDefaults(defaults: UserDefaults = ProfileSettings.current) -> [String] {
        let encoded = defaults.string(forKey: SettingsKey.subtitleLanguages) ?? ""
        if let decoded = decodedLanguages(encoded) {
            return decoded
        }
        return ordered(
            primary: defaults.string(forKey: SettingsKey.subtitleLanguage) ?? "System",
            secondary: defaults.string(forKey: SettingsKey.subtitleLanguageSecondary) ?? "None",
            tertiary: defaults.string(forKey: SettingsKey.subtitleLanguageTertiary) ?? "None"
        )
    }

    static func encode(_ languages: [String]) -> String {
        let normalizedLanguages = ordered(languages)
        guard let data = try? JSONEncoder().encode(normalizedLanguages),
              let value = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return value
    }

    private static func decodedLanguages(_ encoded: String) -> [String]? {
        guard !encoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = encoded.data(using: .utf8),
              let languages = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return ordered(languages)
    }

    static func smartMatchingEnabled(defaults: UserDefaults = ProfileSettings.current) -> Bool {
        (defaults.object(forKey: SettingsKey.smartSubtitleMatching) as? Bool) ?? true
    }

    static func matches(_ languageText: String?, target: String) -> Bool {
        guard let languageText else { return false }
        let text = normalized(languageText)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = Set(trimmed.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let codes = exactCodes(for: target)
        if codes.contains(trimmed) { return true }
        if let primaryCode = trimmed.components(separatedBy: CharacterSet(charactersIn: "-_")).first,
           codes.contains(primaryCode) { return true }
        if !tokens.isDisjoint(with: codes) { return true }
        return aliases(for: target).contains { alias in
            text.contains(normalized(alias))
        }
    }

    static func exactCodes(for language: String) -> [String] {
        languageCodes[language] ?? [normalized(language)]
    }

    static func aliases(for language: String) -> [String] {
        [normalized(language)] + (languageAliases[language] ?? [])
    }

    static func mpvLanguageList(for languages: [String]) -> String? {
        var seen: Set<String> = []
        let codes = languages.flatMap { exactCodes(for: $0) }
            .filter { seen.insert($0).inserted }
        return codes.isEmpty ? nil : codes.joined(separator: ",")
    }

    static func preferredAudioLanguage(defaults: UserDefaults = ProfileSettings.current) -> String? {
        let preferred = defaults.string(forKey: SettingsKey.audioLanguage) ?? "System"
        if !disabledValues.contains(preferred) { return preferred }

        // App language is stored as a BCP-47 tag (or empty / "System" for device).
        let appLanguage = AppLanguage.fromStored(defaults.string(forKey: SettingsKey.language))
        if let name = appLanguage.audioLanguageName, supportedLanguages.contains(name) {
            return name
        }

        return Locale.preferredLanguages.lazy.compactMap { identifier in
            let normalizedIdentifier = normalized(identifier)
            let pieces = normalizedIdentifier.components(separatedBy: CharacterSet(charactersIn: "-_"))
            let code = pieces.first ?? normalizedIdentifier
            return supportedLanguages.first { exactCodes(for: $0).contains(code) }
        }.first
    }

    private static func isDisabled(_ value: String) -> Bool {
        disabledValues.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

enum SettingsAccent: String, CaseIterable, Identifiable {
    case white = "White"
    case sky = "Sky"
    case emerald = "Emerald"
    case rose = "Rose"
    case amber = "Amber"
    case violet = "Violet"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .white: return .white
        case .sky: return Color(red: 0.25, green: 0.62, blue: 0.96)
        case .emerald: return Color(red: 0.19, green: 0.78, blue: 0.48)
        case .rose: return Color(red: 0.95, green: 0.31, blue: 0.48)
        case .amber: return Color(red: 0.97, green: 0.72, blue: 0.26)
        case .violet: return Color(red: 0.60, green: 0.45, blue: 0.95)
        }
    }

    static func color(for rawValue: String) -> Color {
        SettingsAccent(rawValue: rawValue)?.color ?? SettingsAccent.white.color
    }
}

/// Dark background tints for the app body. Distinct from `SettingsAccent`
/// (which are bright focus/accent colors unsuitable as a full-screen fill).
enum SettingsBackground: String, CaseIterable, Identifiable {
    case charcoal = "Charcoal"
    case black = "Black"
    case midnight = "Midnight"
    case forest = "Forest"
    case plum = "Plum"
    case slate = "Slate"
    case wine = "Wine"
    case ocean = "Ocean"
    case indigo = "Indigo"
    case crimson = "Crimson"
    case rust = "Rust"
    case teal = "Teal"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .charcoal: return Color(red: 13.0 / 255.0, green: 13.0 / 255.0, blue: 13.0 / 255.0)
        case .black: return .black
        case .midnight: return Color(red: 0.020, green: 0.030, blue: 0.065)
        case .forest: return Color(red: 0.018, green: 0.048, blue: 0.036)
        case .plum: return Color(red: 0.045, green: 0.020, blue: 0.060)
        case .slate: return Color(red: 0.040, green: 0.046, blue: 0.056)
        case .wine: return Color(red: 0.110, green: 0.015, blue: 0.040)
        case .ocean: return Color(red: 0.012, green: 0.055, blue: 0.085)
        case .indigo: return Color(red: 0.035, green: 0.028, blue: 0.100)
        case .crimson: return Color(red: 0.130, green: 0.012, blue: 0.025)
        case .rust: return Color(red: 0.100, green: 0.040, blue: 0.012)
        case .teal: return Color(red: 0.012, green: 0.070, blue: 0.065)
        }
    }

    /// A slightly brighter swatch fill so dark tints stay visible in the picker.
    var swatchColor: Color {
        switch self {
        case .charcoal: return Color(red: 0.16, green: 0.16, blue: 0.18)
        case .black: return Color(red: 0.07, green: 0.07, blue: 0.07)
        case .midnight: return Color(red: 0.12, green: 0.18, blue: 0.34)
        case .forest: return Color(red: 0.10, green: 0.28, blue: 0.20)
        case .plum: return Color(red: 0.26, green: 0.12, blue: 0.34)
        case .slate: return Color(red: 0.24, green: 0.27, blue: 0.32)
        case .wine: return Color(red: 0.52, green: 0.09, blue: 0.20)
        case .ocean: return Color(red: 0.09, green: 0.36, blue: 0.50)
        case .indigo: return Color(red: 0.24, green: 0.19, blue: 0.56)
        case .crimson: return Color(red: 0.64, green: 0.11, blue: 0.14)
        case .rust: return Color(red: 0.56, green: 0.27, blue: 0.09)
        case .teal: return Color(red: 0.07, green: 0.42, blue: 0.39)
        }
    }

    static func color(for rawValue: String) -> Color {
        SettingsBackground(rawValue: rawValue)?.color ?? SettingsBackground.charcoal.color
    }
}

/// True while focus is still in the sidebar and hasn't entered the detail pane.
/// Every focusable detail row reads this and disables itself when set, so the
/// only focusable target on a right-press is the pane's first row (which opts out
/// via `.settingsEntryAnchor()`). That makes "right" always land on the first row
/// instead of whichever row happens to line up with the sidebar pill's height.
private struct SettingsEntryLockedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsEntryLocked: Bool {
        get { self[SettingsEntryLockedKey.self] }
        set { self[SettingsEntryLockedKey.self] = newValue }
    }
}

extension View {
    /// Marks the detail pane's first row so it stays focusable while the rest of
    /// the pane is entry-locked — i.e. the row a right-press should land on.
    func settingsEntryAnchor() -> some View {
        environment(\.settingsEntryLocked, false)
    }

    /// Conditional variant: anchors only when `isActive`, otherwise leaves the
    /// inherited lock untouched. For panes whose first focusable row changes
    /// (e.g. Account & Profiles swaps its first row for a non-focusable info
    /// row when signed out).
    func settingsEntryAnchor(_ isActive: Bool) -> some View {
        modifier(ConditionalSettingsEntryAnchor(isActive: isActive))
    }

    /// Disables this focusable row whenever the pane is entry-locked (focus still
    /// in the sidebar), reading the flag from the environment so call sites don't
    /// have to thread it. Composes with any other `.disabled(...)` on the row.
    func entryLockable() -> some View {
        modifier(EntryLockable())
    }
}

private struct EntryLockable: ViewModifier {
    @Environment(\.settingsEntryLocked) private var locked
    func body(content: Content) -> some View {
        content.disabled(locked)
    }
}

private struct ConditionalSettingsEntryAnchor: ViewModifier {
    let isActive: Bool
    @Environment(\.settingsEntryLocked) private var locked
    func body(content: Content) -> some View {
        content.environment(\.settingsEntryLocked, isActive ? false : locked)
    }
}

private enum LanguagePickerKind: Hashable {
    case appLanguage
    case audio
    case subtitles
}

struct SettingsView: View {
    let activeProfile: Profile?
    let accountEmail: String?
    let isAuthenticated: Bool
    let onChangeProfileName: ((String, String) -> Void)?
    let onChangeProfileAvatar: ((String, String) -> Void)?
    let onChangeProfilePin: ((String, String?, String?) async -> Bool)?
    let onVerifyProfilePin: ((String, String) async -> Bool)?
    let onSignIn: (() -> Void)?
    let onSignOut: (() -> Void)?

    init(
        activeProfile: Profile? = nil,
        accountEmail: String? = nil,
        isAuthenticated: Bool = false,
        onChangeProfileName: ((String, String) -> Void)? = nil,
        onChangeProfileAvatar: ((String, String) -> Void)? = nil,
        onChangeProfilePin: ((String, String?, String?) async -> Bool)? = nil,
        onVerifyProfilePin: ((String, String) async -> Bool)? = nil,
        onSignIn: (() -> Void)? = nil,
        onSignOut: (() -> Void)? = nil
    ) {
        self.activeProfile = activeProfile
        self.accountEmail = accountEmail
        self.isAuthenticated = isAuthenticated
        self.onChangeProfileName = onChangeProfileName
        self.onChangeProfileAvatar = onChangeProfileAvatar
        self.onChangeProfilePin = onChangeProfilePin
        self.onVerifyProfilePin = onVerifyProfilePin
        self.onSignIn = onSignIn
        self.onSignOut = onSignOut
    }

    @State private var selectedCategory: SettingsCategory = .account
    @State private var presentedLanguagePicker: LanguagePickerKind?
    @FocusState private var focusedCategory: SettingsCategory?
    @FocusState private var focusedLanguagePreference: LanguagePickerKind?
    /// Whether focus has entered the current category's detail pane at least once.
    /// The entry lock (land on the first row) only fires on the first entry; after
    /// that, re-entry stays unlocked so the detail's own focus restoration can
    /// return to the last row instead of being blocked by the lock.
    @State private var detailVisited = false
    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    /// BCP-47 app UI language tag; empty string means System default.
    @AppStorage(SettingsKey.language) private var appLanguageTag = ""
    @AppStorage(SettingsKey.audioLanguage) private var audioLanguage = "System"
    @AppStorage(SettingsKey.subtitleLanguages) private var subtitleLanguages = ""
    @AppStorage(SettingsKey.subtitleLanguage) private var subtitleLanguage = "System"
    @AppStorage(SettingsKey.subtitleLanguageSecondary) private var subtitleLanguageSecondary = "None"
    @AppStorage(SettingsKey.subtitleLanguageTertiary) private var subtitleLanguageTertiary = "None"

    private let pickerLanguages = SubtitleLanguagePreferences.settingsOptions
    /// Display labels for the app-language panel (System first, then native endonyms).
    private var appLanguagePickerOptions: [String] {
        AppLanguage.pickerLanguages.map { language in
            language == .system ? "System" : language.nativeDisplayName
        }
    }

    private var accentColor: Color {
        SettingsAccent.color(for: theme)
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                categoryGrid
                    .focusSection()
                    .defaultFocusIfAvailable($focusedCategory, selectedCategory)
                    .onChange(of: focusedCategory) { newValue in
                        // focusedCategory goes nil exactly when focus leaves the
                        // sidebar for the detail pane — record that so re-entry is
                        // no longer locked to the first row.
                        if newValue == nil { detailVisited = true }
                    }
                    .onChange(of: selectedCategory) { _ in
                        // A newly opened category should lock to its first row again.
                        detailVisited = false
                    }

                Group {
                    if selectedCategory == .subtitles {
                        VStack(alignment: .leading, spacing: 28) {
                            selectedCategoryHeader
                            SubtitleStyleSettingsView(accentColor: accentColor)
                        }
                        .padding(.leading, 44)
                        .padding(.trailing, 72)
                        // No bottom padding: the scrolling controls run all the way
                        // to the screen edge (the preview above stays pinned), so the
                        // list isn't cut short with dead space below it.
                        .padding(.top, 56)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 28) {
                                selectedCategoryHeader
                                selectedCategoryContent
                            }
                            .padding(.leading, 44)
                            .padding(.trailing, 72)
                            .padding(.vertical, 56)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
                // Lock every detail row except the first while focus is still in
                // the sidebar and this category hasn't been entered yet, so the
                // first right-press lands on the first row regardless of which pill
                // it came from. Cleared once focus enters so re-entry isn't blocked.
                .environment(\.settingsEntryLocked, focusedCategory != nil && !detailVisited)
            }
            .disabled(presentedLanguagePicker != nil)
            .allowsHitTesting(presentedLanguagePicker == nil)

            if let picker = presentedLanguagePicker {
                LanguagePickerWindow(
                    title: languagePickerTitle(picker),
                    subtitle: languagePickerSubtitle(picker),
                    systemImage: languagePickerSystemImage(picker),
                    selection: languagePickerSelection(picker),
                    languages: picker == .appLanguage ? appLanguagePickerOptions : pickerLanguages,
                    allowsMultiple: picker == .subtitles,
                    accentColor: accentColor
                ) {
                    dismissLanguagePicker(picker)
                }
                .id(picker)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(1)
            }
        }
        .background(Color.nuvioBackground(amoled: amoled, body: bodyColor).ignoresSafeArea())
        .animation(.easeOut(duration: 0.16), value: presentedLanguagePicker != nil)
    }

    private var audioLanguageSelection: Binding<[String]> {
        Binding(
            get: {
                SubtitleLanguagePreferences.supportedLanguages.contains(audioLanguage)
                    ? [audioLanguage]
                    : []
            },
            set: { selection in
                audioLanguage = selection.first ?? "System"
            }
        )
    }

    private var subtitleLanguageSelection: Binding<[String]> {
        Binding(
            get: {
                SubtitleLanguagePreferences.ordered(
                    encoded: subtitleLanguages,
                    primary: subtitleLanguage,
                    secondary: subtitleLanguageSecondary,
                    tertiary: subtitleLanguageTertiary
                )
            },
            set: { selection in
                let ordered = SubtitleLanguagePreferences.ordered(selection)
                subtitleLanguages = SubtitleLanguagePreferences.encode(ordered)

                // Mirror the first three choices for older synced app builds.
                subtitleLanguage = ordered.indices.contains(0) ? ordered[0] : "System"
                subtitleLanguageSecondary = ordered.indices.contains(1) ? ordered[1] : "None"
                subtitleLanguageTertiary = ordered.indices.contains(2) ? ordered[2] : "None"
            }
        )
    }

    /// Single-select binding for app UI language. Empty selection = System (same
    /// contract LanguagePickerWindow uses for Preferred Audio).
    private var appLanguageSelection: Binding<[String]> {
        Binding(
            get: {
                let language = AppLanguage.fromStored(appLanguageTag)
                return language == .system ? [] : [language.nativeDisplayName]
            },
            set: { selection in
                let choice = selection.first
                let language: AppLanguage
                if choice == nil || choice == "System" {
                    language = .system
                } else if let match = AppLanguage.pickerLanguages.first(where: {
                    $0 != .system && $0.nativeDisplayName == choice
                }) {
                    language = match
                } else {
                    language = .system
                }
                appLanguageTag = language.tag
                AppLocaleManager.shared.setLanguage(language, persist: true)
            }
        )
    }

    private func languagePickerTitle(_ picker: LanguagePickerKind) -> String {
        switch picker {
        case .appLanguage:
            return L10n.string("appearance_language", fallback: "App Language")
        case .audio:
            return L10n.string("tvos_playback_preferred_audio", fallback: "Preferred Audio")
        case .subtitles:
            return L10n.string("tvos_playback_preferred_subtitle", fallback: "Preferred Subtitle")
        }
    }

    private func languagePickerSubtitle(_ picker: LanguagePickerKind) -> String {
        switch picker {
        case .appLanguage:
            return L10n.string(
                "appearance_language_subtitle",
                fallback: "Override system language"
            )
        case .audio:
            return L10n.string(
                "tvos_playback_choose_audio",
                fallback: "Choose the default audio language."
            )
        case .subtitles:
            return L10n.string(
                "tvos_playback_choose_subtitle",
                fallback: "Choose any languages in priority order. System shows every language in the player."
            )
        }
    }

    private func languagePickerSystemImage(_ picker: LanguagePickerKind) -> String {
        switch picker {
        case .appLanguage: return "globe"
        case .audio: return "speaker.wave.2.fill"
        case .subtitles: return "captions.bubble.fill"
        }
    }

    private func languagePickerSelection(_ picker: LanguagePickerKind) -> Binding<[String]> {
        switch picker {
        case .appLanguage: return appLanguageSelection
        case .audio: return audioLanguageSelection
        case .subtitles: return subtitleLanguageSelection
        }
    }

    private func dismissLanguagePicker(_ picker: LanguagePickerKind) {
        presentedLanguagePicker = nil
        DispatchQueue.main.async {
            focusedLanguagePreference = picker
        }
    }

    private var categoryGrid: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.string("nav_settings", fallback: "Settings"))
                .font(.system(size: 42, weight: .bold))
                .foregroundColor(.white)
                .padding(.leading, 10)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(SettingsCategory.allCases) { category in
                    let isSelectedCategory = selectedCategory == category
                    let isFocusedCategory = focusedCategory == category
                    // Fixes "left out of the detail pane flashes the wrong pill":
                    // while focus is in the detail pane (focusedCategory == nil), only
                    // the open category stays focusable. A left-press is directional
                    // and tvOS lands on the geometric nearest *focusable* pill, so
                    // with a single candidate it goes straight to the open one — no
                    // wrong pill ever receives focus, so none can flash. All pills
                    // become focusable again the moment focus is back in the sidebar,
                    // so up/down still moves between every category. Disabling is safe
                    // visually here: PosterCardButtonStyle ignores isEnabled, so a
                    // non-focusable pill looks identical to a focusable one.
                    let isFocusable = isSelectedCategory || focusedCategory != nil

                    SettingsCategoryPill(
                        category: category,
                        isSelected: isSelectedCategory,
                        isFocused: isFocusedCategory,
                        accentColor: accentColor
                    ) {
                        selectedCategory = category
                    }
                    .focused($focusedCategory, equals: category)
                    .disabled(!isFocusable)
                }
            }
        }
        .padding(.leading, 58)
        .padding(.trailing, 22)
        .padding(.top, 58)
        .frame(width: 510)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private var selectedCategoryHeader: some View {
        SettingsDetailHeader(
            title: selectedCategory.title,
            subtitle: selectedCategory.subtitle,
            iconName: selectedCategory.iconName,
            accentColor: accentColor
        )
    }

    @ViewBuilder
    private var selectedCategoryContent: some View {
        switch selectedCategory {
        case .account:
            AccountSettingsView(
                accentColor: accentColor,
                activeProfile: activeProfile,
                accountEmail: accountEmail,
                isAuthenticated: isAuthenticated,
                onChangeProfileName: onChangeProfileName,
                onChangeProfileAvatar: onChangeProfileAvatar,
                onChangeProfilePin: onChangeProfilePin,
                onVerifyProfilePin: onVerifyProfilePin,
                onSignIn: onSignIn,
                onSignOut: onSignOut
            )
        case .appearance:
            AppearanceSettingsView(
                accentColor: accentColor,
                languageFocus: $focusedLanguagePreference,
                onAppLanguage: {
                    focusedLanguagePreference = .appLanguage
                    presentedLanguagePicker = .appLanguage
                }
            )
        case .layout:
            LayoutDiscoverySettingsView(accentColor: accentColor)
        case .integrations:
            IntegrationSettingsView(
                accentColor: accentColor,
                profileID: activeProfile?.id
            )
                .id(activeProfile?.id ?? "none")
        case .playback:
            PlaybackSettingsView(
                accentColor: accentColor,
                languageFocus: $focusedLanguagePreference,
                onAudioLanguage: {
                    focusedLanguagePreference = .audio
                    presentedLanguagePicker = .audio
                },
                onSubtitleLanguages: {
                    focusedLanguagePreference = .subtitles
                    presentedLanguagePicker = .subtitles
                }
            )
        case .subtitles:
            SubtitleStyleSettingsView(accentColor: accentColor)
        case .advanced:
            AdvancedSettingsView(accentColor: accentColor)
        case .about:
            AboutSettingsView(accentColor: accentColor)
        }
    }
}

private struct SettingsCategoryPill: View {
    let category: SettingsCategory
    let isSelected: Bool
    let isFocused: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 22) {
                Image(systemName: category.iconName)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundColor(iconColor)
                    .frame(width: 48, height: 48)

                Text(category.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(textColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 26)
            .frame(width: 430, height: 92, alignment: .leading)
            .modifier(SettingsCategoryPillBackground(isSelected: isSelected, isFocused: isFocused))
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: isFocused ? AppFocusOutline.width : 1)
            )
            .animation(.easeOut(duration: 0.14), value: isSelected)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1.0)
        .zIndex(isFocused ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    private var iconColor: Color {
        if isFocused { return .black }
        return isSelected ? .white.opacity(0.90) : .white.opacity(0.78)
    }

    private var textColor: Color {
        if isFocused { return .black }
        return isSelected ? .white.opacity(0.96) : .white.opacity(0.82)
    }

    private var borderColor: Color {
        if isFocused {
            return .clear
        }
        return Color.white.opacity(isSelected ? 0.14 : 0.07)
    }
}

private struct SettingsCategoryPillBackground: ViewModifier {
    let isSelected: Bool
    let isFocused: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isFocused {
            content.background(Color.white, in: Capsule())
        } else if isSelected {
            content.settingsGlass(shape: Capsule(), isProminent: true)
        } else {
            content.settingsGlass(shape: Capsule(), isProminent: false)
        }
    }
}

private struct AccountSettingsView: View {
    let accentColor: Color
    let activeProfile: Profile?
    let accountEmail: String?
    let isAuthenticated: Bool
    let onChangeProfileName: ((String, String) -> Void)?
    let onChangeProfileAvatar: ((String, String) -> Void)?
    let onChangeProfilePin: ((String, String?, String?) async -> Bool)?
    let onVerifyProfilePin: ((String, String) async -> Bool)?
    let onSignIn: (() -> Void)?
    let onSignOut: (() -> Void)?

    @AppStorage(SettingsKey.profileName) private var profileName = "Nuvio User"
    @AppStorage(SettingsKey.profileAutoSelectLast) private var autoSelectLastProfile = true
    @AppStorage(SettingsKey.accountSyncWatchState) private var syncWatchState = true
    @State private var editableProfileName = ""
    @State private var showingAvatarPicker = false
    @State private var pinSheetMode: ProfilePinSheetMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(
                title: L10n.string("settings_profiles", fallback: "Profiles"),
                subtitle: L10n.string(
                    "profile_subtitle",
                    fallback: "Manage user profiles for this account"
                )
            ) {
                HStack(spacing: 22) {
                    ProfileAvatarView(
                        avatarId: activeProfile?.avatarId ?? ProfileAvatarCatalog.defaultId,
                        size: 84
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayProfileName)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(
                            isPinProtected
                                ? L10n.string(
                                    "profile_pin_enabled_subtitle",
                                    fallback: "This profile requires a 4-digit PIN before switching."
                                )
                                : L10n.string(
                                    "profile_pin_disabled_subtitle",
                                    fallback: "Set a 4-digit PIN to lock this profile."
                                )
                        )
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(.white.opacity(0.58))
                    }

                    Spacer()
                }
                .padding(.bottom, 6)

                // First focusable row in the pane carries the entry anchor —
                // without one the entry lock leaves the pane unenterable.
                SettingsTextFieldRow(
                    title: L10n.string("profile_name_placeholder", fallback: "Profile name"),
                    subtitle: L10n.string(
                        "tvos_profile_name_subtitle",
                        fallback: "Change the name shown for this profile"
                    ),
                    placeholder: L10n.string("profile_name_placeholder", fallback: "Profile name"),
                    text: $editableProfileName,
                    fieldWidth: 340,
                    onCommit: saveProfileName
                )
                .settingsEntryAnchor(activeProfile != nil && onChangeProfileName != nil)
                .disabled(activeProfile == nil || onChangeProfileName == nil)

                SettingsActionRow(
                    title: L10n.string("profile_choose_avatar", fallback: "Choose Avatar"),
                    subtitle: L10n.string(
                        "tvos_profile_avatar_subtitle",
                        fallback: "Choose the avatar shown across Nuvio"
                    ),
                    value: L10n.string("profile_edit_label", fallback: "Edit"),
                    accentColor: accentColor
                ) {
                    showingAvatarPicker = true
                }
                .opacity(activeProfile != nil && onChangeProfileAvatar != nil ? 1 : 0.46)
                .disabled(activeProfile == nil || onChangeProfileAvatar == nil)

                SettingsToggleRow(
                    title: L10n.string("profile_pin_title", fallback: "Profile PIN lock"),
                    subtitle: L10n.string(
                        "profile_pin_enabled_subtitle",
                        fallback: "This profile requires a 4-digit PIN before switching."
                    ),
                    isOn: pinProtectionBinding,
                    accentColor: accentColor
                )
                .settingsEntryAnchor(activeProfile == nil || onChangeProfileName == nil)
                .opacity(canManagePin ? 1 : 0.46)
                .disabled(!canManagePin)

                SettingsToggleRow(
                    title: L10n.string(
                        "advanced_remember_last_profile",
                        fallback: "Remember Last Profile"
                    ),
                    subtitle: L10n.string(
                        "advanced_remember_last_profile_subtitle",
                        fallback: "Remember last selected profile at startup"
                    ),
                    isOn: $autoSelectLastProfile,
                    accentColor: accentColor
                )
            }

            SettingsGroup(
                title: L10n.string("settings_account", fallback: "Account"),
                subtitle: L10n.string(
                    "settings_account_section_subtitle",
                    fallback: "Account and sync status"
                )
            ) {
                SettingsInfoRow(
                    title: L10n.string("tvos_account_status", fallback: "Status"),
                    value: isAuthenticated
                        ? L10n.string("tvos_account_signed_in", fallback: "Signed In")
                        : L10n.string("tvos_account_not_signed_in", fallback: "Not Signed In")
                )

                if let accountEmail, !accountEmail.isEmpty {
                    SettingsInfoRow(
                        title: L10n.string("tvos_account_email", fallback: "Email"),
                        value: accountEmail
                    )
                }

                SettingsToggleRow(
                    title: L10n.string(
                        "tvos_account_sync_watched",
                        fallback: "Sync Watched State"
                    ),
                    subtitle: L10n.string(
                        "tvos_account_sync_watched_subtitle",
                        fallback: "Keep watched history, resume points, and library state eligible for sync"
                    ),
                    isOn: $syncWatchState,
                    accentColor: accentColor
                )

                if isAuthenticated {
                    SettingsActionRow(
                        title: L10n.string("tvos_account_sign_out", fallback: "Sign Out"),
                        subtitle: L10n.string(
                            "tvos_account_sign_out_subtitle",
                            fallback: "Remove this Nuvio account from this Apple TV"
                        ),
                        value: L10n.string("action_disconnect", fallback: "Disconnect"),
                        accentColor: Color(red: 1.0, green: 0.43, blue: 0.43)
                    ) {
                        onSignOut?()
                    }
                    .opacity(onSignOut != nil ? 1 : 0.46)
                    .disabled(onSignOut == nil)
                } else {
                    SettingsActionRow(
                        title: L10n.string("tvos_account_sign_in", fallback: "Sign In"),
                        subtitle: L10n.string(
                            "tvos_account_sign_in_subtitle",
                            fallback: "Connect a Nuvio account to sync profiles, add-ons, and progress"
                        ),
                        value: L10n.string("action_connect", fallback: "Connect"),
                        accentColor: accentColor
                    ) {
                        onSignIn?()
                    }
                    .opacity(onSignIn != nil ? 1 : 0.46)
                    .disabled(onSignIn == nil)
                }
            }
        }
        .onAppear { refreshEditableName() }
        .onChange(of: activeProfile) { _ in refreshEditableName() }
        .sheet(isPresented: $showingAvatarPicker) {
            if let profile = activeProfile {
                ProfileAvatarPickerSheet(
                    isPresented: $showingAvatarPicker,
                    title: displayProfileName,
                    selectedAvatarId: profile.avatarId.isEmpty
                        ? ProfileAvatarCatalog.defaultId
                        : profile.avatarId
                ) { avatarId in
                    onChangeProfileAvatar?(profile.id, avatarId)
                }
            }
        }
        .sheet(item: $pinSheetMode) { mode in
            if let profile = activeProfile {
                ProfilePinManagementView(
                    mode: mode,
                    profileName: displayProfileName,
                    onVerify: { pin in
                        await onVerifyProfilePin?(profile.id, pin) == true
                    },
                    onSave: { pin, currentPin in
                        await onChangeProfilePin?(profile.id, pin, currentPin) == true
                    }
                ) {
                    pinSheetMode = nil
                }
            }
        }
    }

    private var displayProfileName: String {
        if !isAuthenticated, activeProfile == nil { return L10n.string("tvos_settings_nuvio_guest", fallback: "Nuvio Guest") }
        return ProfileDisplayName.resolve(profile: activeProfile, settingsName: profileName)
    }

    private var isPinProtected: Bool {
        activeProfile?.isPinProtected == true
    }

    private var canManagePin: Bool {
        activeProfile != nil && onChangeProfilePin != nil && onVerifyProfilePin != nil
    }

    private var pinProtectionBinding: Binding<Bool> {
        Binding(
            get: { isPinProtected },
            set: { requestedValue in
                guard requestedValue != isPinProtected else { return }
                pinSheetMode = requestedValue ? .enable : .disable
            }
        )
    }

    private func refreshEditableName() {
        editableProfileName = displayProfileName
    }

    private func saveProfileName() {
        let name = editableProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let profileId = activeProfile?.id, !name.isEmpty else {
            refreshEditableName()
            return
        }
        editableProfileName = name
        profileName = name
        onChangeProfileName?(profileId, name)
    }
}

private enum ProfilePinSheetMode: String, Identifiable {
    case enable
    case disable

    var id: String { rawValue }
}

private struct ProfilePinManagementView: View {
    let mode: ProfilePinSheetMode
    let profileName: String
    let onVerify: (String) async -> Bool
    let onSave: (String?, String?) async -> Bool
    let onDismiss: () -> Void

    @State private var enteredPin = ""
    @State private var pendingPin: String?
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.52).ignoresSafeArea()

            VStack(spacing: 24) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)

                Text(instructions)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.64))
                    .multilineTextAlignment(.center)

                HStack(spacing: 18) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < enteredPin.count ? Color.white : Color.white.opacity(0.24))
                            .frame(width: 18, height: 18)
                    }
                }
                .padding(.vertical, 4)

                Text(isWorking ? L10n.string("tvos_settings_saving_pin", fallback: "Saving PIN…") : (errorMessage ?? " "))
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(isWorking ? .white.opacity(0.72) : .red)
                    .frame(height: 24)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(80)), count: 3),
                    spacing: 18
                ) {
                    ForEach(1...9, id: \.self) { number in
                        PinButton(number: "\(number)") {
                            addDigit("\(number)")
                        }
                    }

                    PinButton(number: "", isDisabled: true) {}
                    PinButton(number: "0") { addDigit("0") }

                    PinDeleteButton(action: deleteDigit)
                }

                PinSheetActionButton(title: L10n.string("action_cancel", fallback: "Cancel"), action: onDismiss)
                    .padding(.top, 4)
            }
            .frame(width: 520)
            .padding(48)
            .loginGlassPanel()
            .shadow(color: .black.opacity(0.38), radius: 32, y: 18)
        }
    }

    private var title: String {
        switch mode {
        case .enable:
            return pendingPin == nil ? "Create PIN" : "Confirm PIN"
        case .disable:
            return L10n.string("tvos_settings_turn_off_pin_protection", fallback: "Turn Off PIN Protection")
        }
    }

    private var instructions: String {
        switch mode {
        case .enable:
            return pendingPin == nil
                ? "Enter a 4-digit PIN for \(profileName)."
                : "Enter the same PIN again."
        case .disable:
            return L10n.format(
                "tvos_settings_enter_pin_for_profile",
                fallback: "Enter the current PIN for %@.",
                profileName
            )
        }
    }

    private func addDigit(_ digit: String) {
        guard !isWorking, enteredPin.count < 4 else { return }
        let completedPin = enteredPin + digit
        enteredPin = completedPin
        errorMessage = nil
        guard completedPin.count == 4 else { return }

        switch mode {
        case .enable:
            if pendingPin == nil {
                pendingPin = completedPin
                enteredPin = ""
            } else if pendingPin != completedPin {
                enteredPin = ""
                errorMessage = "PINs did not match. Try again."
            } else {
                savePin(completedPin, currentPin: nil)
            }

        case .disable:
            disablePin(currentPin: completedPin)
        }
    }

    private func savePin(_ pin: String, currentPin: String?) {
        isWorking = true
        Task { @MainActor in
            let saved = await onSave(pin, currentPin)
            isWorking = false
            if saved {
                onDismiss()
            } else {
                enteredPin = ""
                errorMessage = "The PIN could not be saved. Check your connection and try again."
            }
        }
    }

    private func disablePin(currentPin: String) {
        isWorking = true
        Task { @MainActor in
            guard await onVerify(currentPin) else {
                isWorking = false
                enteredPin = ""
                errorMessage = "Incorrect PIN"
                return
            }

            let cleared = await onSave(nil, currentPin)
            isWorking = false
            if cleared {
                onDismiss()
            } else {
                enteredPin = ""
                errorMessage = "PIN protection could not be turned off. Check your connection and try again."
            }
        }
    }

    private func deleteDigit() {
        guard !isWorking, !enteredPin.isEmpty else { return }
        enteredPin.removeLast()
        errorMessage = nil
    }
}

private struct PinDeleteButton: View {
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: "delete.left")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .frame(width: 80, height: 80)
                .loginGlassCapsule(highlighted: isFocused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.06 : 1)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

private struct PinSheetActionButton: View {
    let title: String
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(isFocused ? .black : .white)
                .padding(.horizontal, 30)
                .frame(height: 56)
                .loginGlassCapsule(highlighted: isFocused)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(isFocused ? 1.04 : 1)
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

private struct AppearanceSettingsView: View {
    let accentColor: Color
    let languageFocus: FocusState<LanguagePickerKind?>.Binding
    let onAppLanguage: () -> Void

    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    /// BCP-47 language tag; empty string means System default (matches Android TV).
    @AppStorage(SettingsKey.language) private var languageTag = ""
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.amoledSurfaces) private var amoledSurfaces = false
    @ObservedObject private var localeManager = AppLocaleManager.shared

    private var accentSwatches: [SettingsSwatch] {
        SettingsAccent.allCases.map { SettingsSwatch(id: $0.rawValue, label: $0.rawValue, color: $0.color) }
    }

    private var backgroundSwatches: [SettingsSwatch] {
        SettingsBackground.allCases.map { SettingsSwatch(id: $0.rawValue, label: $0.rawValue, color: $0.swatchColor) }
    }

    private var appLanguageSummary: String {
        AppLanguage.fromStored(languageTag).nativeDisplayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(
                title: L10n.string("tvos_appearance_focus_outline", fallback: "Focus Outline"),
                subtitle: L10n.string(
                    "tvos_appearance_focus_outline_subtitle",
                    fallback: "Accent color used for focused cards and controls"
                )
            ) {
                SettingsSwatchRow(swatches: accentSwatches, selection: $theme, accentColor: accentColor)
                    .settingsEntryAnchor()
            }

            SettingsGroup(
                title: L10n.string("tvos_appearance_app_background", fallback: "App Background"),
                subtitle: L10n.string(
                    "tvos_appearance_app_background_subtitle",
                    fallback: "Body background color behind every screen"
                )
            ) {
                SettingsSwatchRow(swatches: backgroundSwatches, selection: $bodyColor, accentColor: accentColor)

                SettingsToggleRow(
                    title: L10n.string("appearance_amoled_mode", fallback: "AMOLED Mode"),
                    subtitle: L10n.string(
                        "appearance_amoled_mode_subtitle",
                        fallback: "Force a pure black background, overriding the choice above"
                    ),
                    isOn: $amoled,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: L10n.string("appearance_amoled_surfaces_mode", fallback: "AMOLED Surfaces"),
                    subtitle: L10n.string(
                        "appearance_amoled_surfaces_mode_subtitle",
                        fallback: "Flatten card and row surfaces when AMOLED mode is enabled"
                    ),
                    isOn: $amoledSurfaces,
                    accentColor: accentColor
                )
                .opacity(amoled ? 1 : 0.46)
                .disabled(!amoled)
            }

            SettingsGroup(
                title: L10n.string("appearance_font_and_language", fallback: "Language"),
                subtitle: L10n.string(
                    "appearance_font_and_language_subtitle",
                    fallback: "Choose the locale used throughout the app"
                )
            ) {
                // Same SettingsActionRow + LanguagePickerWindow pattern as Preferred Audio.
                SettingsActionRow(
                    title: L10n.string("appearance_language", fallback: "App Language"),
                    subtitle: L10n.string(
                        "appearance_language_subtitle",
                        fallback: "Override system language for the entire app"
                    ),
                    value: appLanguageSummary,
                    accentColor: accentColor
                ) {
                    onAppLanguage()
                }
                .focused(languageFocus, equals: .appLanguage)
            }
        }
        .onAppear {
            // Migrate legacy English display names (e.g. "English") to BCP-47 tags.
            let resolved = AppLanguage.fromStored(languageTag)
            if languageTag != resolved.tag {
                languageTag = resolved.tag
            }
            localeManager.applyStoredTag(languageTag)
        }
        .onChange(of: languageTag) { newValue in
            localeManager.applyStoredTag(newValue)
        }
        .onChange(of: localeManager.revision) { _ in
            // Keep summary in sync when the picker writes via AppLocaleManager.
            let resolved = AppLocaleManager.shared.language
            if languageTag != resolved.tag {
                languageTag = resolved.tag
            }
        }
    }
}

private struct LayoutDiscoverySettingsView: View {
    let accentColor: Color

    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.heroEnabled) private var heroEnabled = true
    @AppStorage(SettingsKey.heroCatalogs) private var heroCatalogsData = Data()
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.catalogAddonNames) private var catalogAddonNames = true
    @AppStorage(SettingsKey.discoverLocation) private var discoverLocation = "Search"
    @AppStorage(SettingsKey.continueWatchingSort) private var continueWatchingSort = "Default"
    @AppStorage(SettingsKey.showUnairedNextUp) private var showUnairedNextUp = true
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false
    @AppStorage(SettingsKey.showFullDates) private var showFullDates = true

    /// Classic was never a distinct layout (behaved like Modern).
    private let layouts = ["Modern", "Compact", "Grid View"]
    private let discoverLocations = ["Search", "Home", "Library", "Off"]
    private let continueWatchingSorts = ["Default", "Recently watched", "Release order", "Next up"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(
                title: L10n.string("tvos_layout_home", fallback: "Home Layout"),
                subtitle: L10n.string(
                    "tvos_layout_home_subtitle",
                    fallback: "How the home screen presents rows and artwork"
                )
            ) {
                SettingsOptionRow(
                    title: L10n.string("tvos_layout_layout", fallback: "Layout"),
                    subtitle: L10n.string(
                        "tvos_layout_layout_subtitle",
                        fallback: "Modern and Compact use rows; Grid View shows each catalog in a 6 by 3 poster grid"
                    ),
                    selection: $homeLayout,
                    options: layouts,
                    accentColor: accentColor
                )
                .settingsEntryAnchor()
                .onAppear {
                    if homeLayout == "Classic" { homeLayout = "Modern" }
                }

                SettingsToggleRow(
                    title: L10n.string("tvos_layout_hero", fallback: "Hero Section"),
                    subtitle: L10n.string(
                        "tvos_layout_hero_subtitle",
                        fallback: "Show featured artwork above catalog rows"
                    ),
                    isOn: $heroEnabled,
                    accentColor: accentColor
                )

                if homeLayout == "Grid View" {
                    HeroCatalogSelectionRow(
                        selectionData: $heroCatalogsData,
                        accentColor: accentColor
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                SettingsToggleRow(
                    title: L10n.string("tvos_layout_poster_labels", fallback: "Poster Labels"),
                    subtitle: L10n.string(
                        "tvos_layout_poster_labels_subtitle",
                        fallback: "Show titles below poster cards"
                    ),
                    isOn: $posterLabels,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: L10n.string(
                        "tvos_layout_catalog_addon_names",
                        fallback: "Catalog Add-on Names"
                    ),
                    subtitle: L10n.string(
                        "tvos_layout_catalog_addon_names_subtitle",
                        fallback: "Show source add-on names beside catalog titles"
                    ),
                    isOn: $catalogAddonNames,
                    accentColor: accentColor
                )
            }

            HomeCatalogOrderSection(accentColor: accentColor)

            CollectionsSettingsSection(accentColor: accentColor)

            SettingsGroup(
                title: L10n.string("tvos_layout_discovery", fallback: "Discovery"),
                subtitle: L10n.string(
                    "tvos_layout_discovery_subtitle",
                    fallback: "Visibility rules for discovery and continue watching"
                )
            ) {
                SettingsOptionRow(
                    title: L10n.string("tvos_layout_discover_entry", fallback: "Discover Entry"),
                    subtitle: L10n.string(
                        "tvos_layout_discover_entry_subtitle",
                        fallback: "Where the discover surface appears"
                    ),
                    selection: $discoverLocation,
                    options: discoverLocations,
                    accentColor: accentColor
                )

                SettingsOptionRow(
                    title: L10n.string("tvos_layout_continue_watching", fallback: "Continue Watching"),
                    subtitle: L10n.string(
                        "tvos_layout_continue_watching_subtitle",
                        fallback: "Default order for resume rows"
                    ),
                    selection: $continueWatchingSort,
                    options: continueWatchingSorts,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: L10n.string("tvos_layout_show_unaired", fallback: "Show Unaired Next Up"),
                    subtitle: L10n.string(
                        "tvos_layout_show_unaired_subtitle",
                        fallback: "Keep upcoming episodes in Continue Watching with their air date"
                    ),
                    isOn: $showUnairedNextUp,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: L10n.string(
                        "tvos_layout_hide_unreleased",
                        fallback: "Hide Unreleased Content"
                    ),
                    subtitle: L10n.string(
                        "tvos_layout_hide_unreleased_subtitle",
                        fallback: "Filter titles before their known release date"
                    ),
                    isOn: $hideUnreleased,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: L10n.string(
                        "tvos_layout_full_dates",
                        fallback: "Show Full Release Dates"
                    ),
                    subtitle: L10n.string(
                        "tvos_layout_full_dates_subtitle",
                        fallback: "Prefer exact dates when metadata provides them"
                    ),
                    isOn: $showFullDates,
                    accentColor: accentColor
                )
            }
        }
    }
}

/// Grid View-only multi-select for choosing which Home catalogs feed the hero
/// carousel. An empty saved selection represents the default "all catalogs".
private struct HeroCatalogSelectionRow: View {
    @Binding var selectionData: Data
    let accentColor: Color
    @State private var catalogs: [(id: String, title: String)] = []

    private var explicitlySelected: Set<String> {
        guard let ids = try? JSONDecoder().decode([String].self, from: selectionData) else { return [] }
        return Set(ids)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.string("layout_hero_catalogs", fallback: "Hero Catalogs"))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                Text(L10n.string(
                    "layout_hero_catalogs_sub",
                    fallback: "Select one or more catalogs for hero content."
                ))
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.white.opacity(0.56))
            }

            if catalogs.isEmpty {
                SettingsInfoRow(
                    title: L10n.string("tvos_settings_no_rows_recorded_yet", fallback: "No catalogs recorded yet"),
                    value: L10n.string("tvos_settings_open_home_once", fallback: "Open Home once")
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(catalogs, id: \.id) { catalog in
                            CollectionChipButton(
                                title: catalog.title,
                                isSelected: isSelected(catalog.id)
                            ) {
                                toggle(catalog.id)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                }
                .focusSection()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: selectionData)
        .onAppear { loadCatalogs() }
        .onReceive(NotificationCenter.default.publisher(for: TVHomeCatalogOrder.changedNotification)) { _ in
            loadCatalogs()
        }
    }

    private func isSelected(_ id: String) -> Bool {
        explicitlySelected.isEmpty || explicitlySelected.contains(id)
    }

    private func toggle(_ id: String) {
        var selected = explicitlySelected
        if selected.isEmpty { selected = Set(catalogs.map(\.id)) }
        if selected.contains(id) {
            guard selected.count > 1 else { return }
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        selectionData = (try? JSONEncoder().encode(catalogs.map(\.id).filter(selected.contains))) ?? Data()
    }

    private func loadCatalogs() {
        catalogs = TVHomeCatalogOrder.snapshotRows().filter {
            $0.id != TVHomeSection.continueWatchingId
                && !$0.id.hasPrefix(TVHomeSection.collectionIdPrefix)
        }
    }
}

private struct IntegrationSettingsView: View {
    let accentColor: Color

    @StateObject private var traktViewModel: TraktSettingsViewModel
    @AppStorage private var traktClientID: String
    @AppStorage private var traktClientSecret: String
    @AppStorage(SettingsKey.tmdbEnabled) private var tmdbEnabled = false
    @AppStorage(SettingsKey.tmdbApiKey) private var tmdbApiKey = ""
    @AppStorage(SettingsKey.mdbListEnabled) private var mdbListEnabled = false
    @AppStorage(SettingsKey.mdbListApiKey) private var mdbListApiKey = ""
    @AppStorage(SettingsKey.debridProvider) private var debridProvider = "None"
    @AppStorage(SettingsKey.debridApiKey) private var debridApiKey = ""
    @AppStorage(SettingsKey.torboxAccessToken) private var torboxAccessToken = ""
    @AppStorage(SettingsKey.premiumizeAccessToken) private var premiumizeAccessToken = ""
    @AppStorage(SettingsKey.realDebridAccessToken) private var realDebridAccessToken = ""
    @State private var debridAccountToConnect: DebridAccountProvider?
    @State private var showingTraktLogin = false
    @State private var showingTraktSettings = false
    @StateObject private var debridConnection = DebridAccountConnectionViewModel()

    init(accentColor: Color, profileID: String?) {
        self.accentColor = accentColor
        let profileStore = ProfileSettings.store(for: profileID)
        _traktViewModel = StateObject(
            wrappedValue: TraktSettingsViewModel(store: profileStore)
        )
        _traktClientID = AppStorage(
            wrappedValue: "",
            SettingsKey.traktClientID,
            store: profileStore
        )
        _traktClientSecret = AppStorage(
            wrappedValue: "",
            SettingsKey.traktClientSecret,
            store: profileStore
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            AddonsSettingsSection(accentColor: accentColor)

            SettingsGroup(
                title: L10n.string("mdblist_trakt_title", fallback: "Trakt"),
                subtitle: L10n.string(
                    "tvos_integrations_trakt_subtitle",
                    fallback: "Watchlist, progress, history, comments, and recommendations"
                )
            ) {
                SettingsTextFieldRow(
                    title: "Trakt Client ID",
                    subtitle: "Create an API app at trakt.tv/oauth/applications",
                    placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                    text: $traktClientID,
                    onCommit: { traktViewModel.credentialsDidChange() }
                )

                SettingsTextFieldRow(
                    title: "Trakt Client Secret",
                    subtitle: L10n.string(
                        "tvos_settings_stored_locally_on_this_apple_tv",
                        fallback: "Stored locally on this Apple TV"
                    ),
                    placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                    text: $traktClientSecret,
                    isSecure: true,
                    onCommit: { traktViewModel.credentialsDidChange() }
                )

                SettingsInfoRow(title: "Trakt Redirect URI", value: TraktConfig.redirectURI)

                TraktConnectionSettingsCard(
                    viewModel: traktViewModel,
                    accentColor: accentColor,
                    onStartLogin: { showingTraktLogin = true },
                    onOpenSettings: { showingTraktSettings = true }
                )
            }

            SettingsGroup(
                title: L10n.string("tvos_integrations_metadata", fallback: "Metadata Providers"),
                subtitle: L10n.string(
                    "tvos_integrations_metadata_subtitle",
                    fallback: "Optional API keys for richer metadata and rating badges"
                )
            ) {
                SettingsToggleRow(
                    title: L10n.string("tvos_integrations_tmdb", fallback: "TMDB Metadata"),
                    subtitle: L10n.string(
                        "tvos_integrations_tmdb_subtitle",
                        fallback: "Enable custom TMDB metadata enrichment"
                    ),
                    isOn: $tmdbEnabled,
                    accentColor: accentColor
                )

                SettingsTextFieldRow(
                    title: L10n.string("tvos_settings_tmdb_api_key", fallback: "TMDB API Key"),
                    subtitle: L10n.string("tvos_settings_stored_locally_on_this_apple_tv", fallback: "Stored locally on this Apple TV"),
                    placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                    text: $tmdbApiKey,
                    isSecure: true
                )

                SettingsToggleRow(
                    title: L10n.string("mdblist_title", fallback: "MDBList Ratings"),
                    subtitle: L10n.string("tvos_settings_show_ratings_from_imdb_tmdb_rotten_tomat_b0d57bb8", fallback: "Show ratings from IMDb, TMDB, Rotten Tomatoes, and Metacritic"),
                    isOn: $mdbListEnabled,
                    accentColor: accentColor
                )

                SettingsTextFieldRow(
                    title: L10n.string("mdblist_dialog_title", fallback: "MDBList API Key"),
                    subtitle: L10n.string("tvos_settings_stored_locally_on_this_apple_tv", fallback: "Stored locally on this Apple TV"),
                    placeholder: L10n.string("debrid_not_set", fallback: "Not set"),
                    text: $mdbListApiKey,
                    isSecure: true
                )
            }

            SettingsGroup(
                title: L10n.string("tvos_integrations_debrid", fallback: "Debrid"),
                subtitle: L10n.string(
                    "tvos_integrations_debrid_subtitle",
                    fallback: "Link providers used to resolve torrent streams"
                )
            ) {
                SettingsActionRow(
                    title: L10n.string("tvos_settings_real_debrid", fallback: "Real-Debrid"),
                    subtitle: L10n.string(
                        "tvos_settings_real_debrid_qr_subtitle",
                        fallback: "Scan the QR and approve on real-debrid.com"
                    ),
                    value: isConnected(.realDebrid) ? L10n.string("debrid_connected", fallback: "Connected") : L10n.string("debrid_not_set", fallback: "Not set"),
                    accentColor: accentColor
                ) {
                    debridAccountToConnect = .realDebrid
                }

                SettingsActionRow(
                    title: L10n.string("tvos_settings_torbox", fallback: "TorBox"),
                    subtitle: L10n.string("tvos_settings_link_your_torbox_account_in_the_browser", fallback: "Link your TorBox account in the browser"),
                    value: isConnected(.torbox) ? L10n.string("debrid_connected", fallback: "Connected") : L10n.string("debrid_not_set", fallback: "Not set"),
                    accentColor: accentColor
                ) {
                    debridAccountToConnect = .torbox
                }

                SettingsActionRow(
                    title: L10n.string("tvos_settings_premiumize", fallback: "Premiumize"),
                    subtitle: PremiumizeOAuthConfiguration.isDeviceOAuthConfigured
                        ? "Link with QR when a client ID is configured"
                        : "Paste API key from premiumize.me/account",
                    value: isConnected(.premiumize) ? L10n.string("debrid_connected", fallback: "Connected") : L10n.string("debrid_not_set", fallback: "Not set"),
                    accentColor: accentColor
                ) {
                    debridAccountToConnect = .premiumize
                }
            }
        }
        .onAppear {
            traktViewModel.reload()
            traktViewModel.loadConnectedData()
        }
        .onChange(of: traktClientID) { _ in traktViewModel.credentialsDidChange() }
        .onChange(of: traktClientSecret) { _ in traktViewModel.credentialsDidChange() }
        .sheet(item: $debridAccountToConnect) { provider in
            if provider == .premiumize && !PremiumizeOAuthConfiguration.isDeviceOAuthConfigured {
                PremiumizeApiKeySheet(
                    isConnected: isConnected(.premiumize),
                    accentColor: accentColor
                )
            } else {
                DebridDeviceAuthorizationSheet(
                    provider: provider,
                    isConnected: isConnected(provider),
                    viewModel: debridConnection
                )
            }
        }
        .sheet(isPresented: $showingTraktLogin, onDismiss: {
            if traktViewModel.mode == .connected {
                showingTraktSettings = true
            }
        }) {
            TraktDeviceLoginSheet(viewModel: traktViewModel, accentColor: accentColor)
                .modifier(ClearPresentationBackgroundIfAvailable())
        }
        .sheet(isPresented: $showingTraktSettings) {
            TraktConnectedSettingsSheet(viewModel: traktViewModel, accentColor: accentColor)
                .modifier(ClearPresentationBackgroundIfAvailable())
        }
        .onChange(of: traktViewModel.mode) { mode in
            if mode == .connected { showingTraktLogin = false }
        }
    }

    private func isConnected(_ provider: DebridAccountProvider) -> Bool {
        switch provider {
        case .torbox:
            if !torboxAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        case .premiumize:
            if !premiumizeAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        case .realDebrid:
            if !realDebridAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        return debridProvider == provider.debridKind.rawValue &&
            !debridApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Premiumize has no public open-source device OAuth — paste the account API key.
private struct PremiumizeApiKeySheet: View {
    let isConnected: Bool
    let accentColor: Color

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var statusMessage: String?
    @State private var isValidating = false
    @State private var validationFailed = false

    var body: some View {
        VStack(spacing: 28) {
            Text(isConnected ? L10n.string("tvos_settings_premiumize_connected", fallback: "Premiumize Connected") : L10n.string("tvos_settings_connect_premiumize", fallback: "Connect Premiumize"))
                .font(.system(size: 42, weight: .regular))
                .foregroundColor(.white)

            if isConnected {
                Text(L10n.string("tvos_settings_this_apple_tv_is_linked_with_your_premiu_0e52cefa", fallback: "This Apple TV is linked with your Premiumize API key."))
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.66))
                    .multilineTextAlignment(.center)

                HStack(spacing: 18) {
                    dialogButton(title: L10n.string("action_cancel", fallback: "Cancel"), isPrimary: false) { dismiss() }
                    dialogButton(title: L10n.string("debrid_disconnect", fallback: "Disconnect"), isPrimary: true) {
                        DebridCredentials.remove(provider: .premiumize, store: ProfileSettings.current)
                        dismiss()
                    }
                }
            } else {
                Text(L10n.string("tvos_settings_premiumize_does_not_offer_public_qr_devi_f6f201eb", fallback: "Premiumize does not offer public QR/device OAuth for open-source apps. Paste the API key from your account page."))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("premiumize.me/account")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(accentColor)

                SettingsSearchStyleField(
                    text: $apiKey,
                    placeholder: L10n.string("tvos_settings_api_key", fallback: "API key"),
                    autoFocus: true,
                    showsMagnifier: false,
                    height: 64,
                    fontSize: 22,
                    horizontalPadding: 24
                )
                .frame(maxWidth: 720)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(validationFailed
                            ? Color(red: 1.0, green: 0.43, blue: 0.43)
                            : .white.opacity(0.64))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 18) {
                    dialogButton(title: L10n.string("action_cancel", fallback: "Cancel"), isPrimary: false) { dismiss() }
                    dialogButton(
                        title: isValidating ? L10n.string("tvos_settings_checking", fallback: "Checking…") : L10n.string("action_save", fallback: "Save"),
                        isPrimary: true
                    ) {
                        Task { await save() }
                    }
                }
            }
        }
        .frame(width: 960)
        .padding(.horizontal, 88)
        .padding(.vertical, 64)
        .background(Color(red: 0.11, green: 0.11, blue: 0.11))
    }

    @MainActor
    private func save() async {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            validationFailed = true
            statusMessage = "Paste your Premiumize API key first."
            return
        }

        isValidating = true
        validationFailed = false
        statusMessage = "Checking key…"
        defer { isValidating = false }

        var request = URLRequest(url: URL(string: "https://www.premiumize.me/api/account/info")!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                validationFailed = true
                statusMessage = "Could not reach Premiumize."
                return
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                validationFailed = true
                statusMessage = "Invalid API key."
                return
            }
            guard (200...299).contains(http.statusCode) else {
                validationFailed = true
                statusMessage = "Premiumize returned HTTP \(http.statusCode)."
                return
            }
            // Soft-check status field when present.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = (json["status"] as? String)?.lowercased(),
               status == "error" {
                validationFailed = true
                statusMessage = (json["message"] as? String) ?? "Premiumize rejected this key."
                return
            }

            DebridCredentials.save(key, for: .premiumize, store: ProfileSettings.current)
            validationFailed = false
            statusMessage = "Premiumize connected."
            dismiss()
        } catch {
            validationFailed = true
            statusMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func dialogButton(title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(isPrimary ? .black : .white)
                .padding(.horizontal, 34)
                .padding(.vertical, 16)
                .background(
                    isPrimary ? Color.white : Color.white.opacity(0.14),
                    in: Capsule()
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
        .disabled(isValidating && isPrimary)
    }
}

/// QR / device-code dialog for Real-Debrid, TorBox, and Premiumize when OAuth client id is set.
private struct DebridDeviceAuthorizationSheet: View {
    let provider: DebridAccountProvider
    let isConnected: Bool
    @ObservedObject var viewModel: DebridAccountConnectionViewModel

    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 28) {
            Text(
                isConnected
                    ? L10n.format(
                        "tvos_settings_provider_connected",
                        fallback: "%@ Connected",
                        provider.displayName
                    )
                    : L10n.format(
                        "tvos_settings_connect_provider",
                        fallback: "Connect %@",
                        provider.displayName
                    )
            )
                .font(.system(size: 42, weight: .regular))
                .foregroundColor(.white)

            if isConnected {
                Text(
                    L10n.format(
                        "tvos_settings_linked_to_provider_account",
                        fallback: "This Apple TV is linked to your %@ account.",
                        provider.displayName
                    )
                )
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.66))
                    .multilineTextAlignment(.center)

                HStack(spacing: 18) {
                    dialogButton(title: L10n.string("action_cancel", fallback: "Cancel"), isPrimary: false) { dismiss() }
                    dialogButton(title: L10n.string("debrid_disconnect", fallback: "Disconnect"), isPrimary: true) {
                        DebridCredentials.remove(provider: provider, store: ProfileSettings.current)
                        dismiss()
                    }
                }
            } else if viewModel.state == .starting {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(height: 380)
                statusText
            } else if let authorization = viewModel.authorization {
                Text(L10n.string("debrid_device_auth_instructions", fallback: "Scan the QR and enter this code to approve Nuvio."))
                    .font(.system(size: 25, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
                    .multilineTextAlignment(.center)

                if let image = QRCode.image(from: authorization.friendlyVerificationURL, scale: 10) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 300, height: 300)
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }

                VStack(spacing: 12) {
                    Text(authorization.userCode)
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .tracking(4)
                        .foregroundColor(.white)
                    Text(authorization.friendlyVerificationURL)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.54))
                        .lineLimit(1)
                }

                statusText
                dialogButton(title: L10n.string("action_cancel", fallback: "Cancel"), isPrimary: true) { dismiss() }
            } else {
                Text(viewModel.statusMessage ?? L10n.string("tvos_settings_unable_to_start_account_linking", fallback: "Unable to start account linking."))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(Color(red: 1.0, green: 0.43, blue: 0.43))
                    .multilineTextAlignment(.center)
                HStack(spacing: 18) {
                    dialogButton(title: L10n.string("action_cancel", fallback: "Cancel"), isPrimary: false) { dismiss() }
                    dialogButton(title: L10n.string("action_retry", fallback: "Retry"), isPrimary: true) { viewModel.connect(provider) }
                }
            }
        }
        .frame(width: 960)
        .padding(.horizontal, 88)
        .padding(.vertical, 64)
        .background(Color(red: 0.11, green: 0.11, blue: 0.11))
        .task(id: provider.id) {
            if !isConnected { viewModel.connect(provider) }
        }
        .onChange(of: viewModel.state) { state in
            if state == .connected { dismiss() }
        }
        .onDisappear { viewModel.cancel() }
    }

    private var statusText: some View {
        HStack(spacing: 10) {
            if viewModel.isPolling { ProgressView().tint(.white) }
            Text(viewModel.statusMessage ?? L10n.string("trakt_waiting_approval", fallback: "Waiting for approval…"))
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.white.opacity(0.64))
        }
    }

    @ViewBuilder
    private func dialogButton(title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(isPrimary ? .black : .white)
                .padding(.horizontal, 34)
                .padding(.vertical, 16)
                .background(
                    isPrimary ? Color.white : Color.white.opacity(0.14),
                    in: Capsule()
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
    }
}

private struct TraktConnectionSettingsCard: View {
    @ObservedObject var viewModel: TraktSettingsViewModel
    let accentColor: Color
    let onStartLogin: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(red: 0.94, green: 0.10, blue: 0.17))
                    Text("trakt")
                        .font(.system(size: 24, weight: .black))
                        .foregroundColor(.white)
                }
                .frame(width: 92, height: 62)

                VStack(alignment: .leading, spacing: 8) {
                    Text(statusTitle)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)

                    Text(statusSubtitle)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 16)
            }

            switch viewModel.mode {
            case .disconnected, .awaitingApproval:
                SettingsActionRow(
                    title: viewModel.mode == .awaitingApproval ? L10n.string("tvos_settings_continue_trakt_login", fallback: "Continue Trakt Login") : L10n.string("tvos_settings_connect_with_trakt", fallback: "Connect with Trakt"),
                    subtitle: viewModel.credentialsConfigured
                        ? "Scan the QR or enter the code at trakt.tv/activate"
                        : "Enter your Trakt Client ID and Client Secret first",
                    value: viewModel.mode == .awaitingApproval ? L10n.string("tvos_settings_resume", fallback: "Resume") : L10n.string("tvos_settings_connect", fallback: "Connect"),
                    accentColor: accentColor
                ) {
                    onStartLogin()
                }
                .opacity(viewModel.credentialsConfigured ? 1 : 0.5)
                .disabled(!viewModel.credentialsConfigured)
            case .connected:
                connectedBody
            }

            if let message = viewModel.statusMessage, !message.isEmpty, viewModel.mode == .connected {
                Text(message)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
            }

            if let error = viewModel.errorMessage, !error.isEmpty, viewModel.mode != .awaitingApproval {
                Text(error)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.43, blue: 0.43))
            }
        }
    }

    private var connectedBody: some View {
        SettingsActionRow(
            title: "Trakt Settings",
            subtitle: "Account status, watched statistics, library, progress, comments, and recommendations",
            value: L10n.string("tvos_settings_open", fallback: "Open"),
            accentColor: accentColor,
            action: onOpenSettings
        )
    }

    private var statusTitle: String {
        switch viewModel.mode {
        case .disconnected:
            return L10n.string("tvos_settings_not_connected", fallback: "Not connected")
        case .awaitingApproval:
            return L10n.string("tvos_settings_waiting_for_approval", fallback: "Waiting for approval")
        case .connected:
            let name = (viewModel.username?.isEmpty == false) ? (viewModel.username ?? "Trakt User") : "Trakt User"
            return L10n.format(
                "tvos_settings_connected_as_user",
                fallback: "Connected as %@",
                name
            )
        }
    }

    private var statusSubtitle: String {
        switch viewModel.mode {
        case .disconnected:
            return L10n.string(
                "tvos_settings_connect_trakt_qr_hint",
                fallback: "Connect with a QR code or activation code at trakt.tv/activate."
            )
        case .awaitingApproval:
            return L10n.string(
                "tvos_settings_finish_approving_trakt",
                fallback: "Finish approving this Apple TV in Trakt, or resume the login sheet."
            )
        case .connected:
            return L10n.string(
                "tvos_settings_trakt_profile_ready",
                fallback: "This profile can use Trakt-backed sync and metadata settings."
            )
        }
    }

}

/// Dedicated post-login Trakt page, matching the Android TV account screen.
private struct TraktConnectedSettingsSheet: View {
    @ObservedObject var viewModel: TraktSettingsViewModel
    let accentColor: Color

    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()
    @State private var showingDisconnectConfirmation = false

    private let continueWatchingOptions = [14, 30, 60, 90, 180, 365, TraktDefaults.continueWatchingDaysCapAll]

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.055, blue: 0.055).ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                    header

                    SettingsGroup(title: "Account Login", subtitle: tokenRefreshLabel) {
                        SettingsActionRow(
                            title: L10n.string("debrid_disconnect", fallback: "Disconnect"),
                            subtitle: L10n.string(
                                "tvos_settings_remove_this_profile_s_trakt_tokens_from__60ff1f28",
                                fallback: "Remove this profile's Trakt tokens from this Apple TV"
                            ),
                            value: L10n.string("debrid_disconnect", fallback: "Disconnect"),
                            accentColor: accentColor
                        ) {
                            showingDisconnectConfirmation = true
                        }
                    }

                    SettingsGroup(
                        title: "Cached",
                        subtitle: "Watched activity currently loaded from your Trakt account"
                    ) {
                        TraktConnectedStatsStrip(
                            stats: viewModel.connectedStats,
                            isLoading: viewModel.isStatsLoading
                        )

                        SettingsActionRow(
                            title: L10n.string("tvos_settings_sync_now", fallback: "Sync Now"),
                            subtitle: L10n.string(
                                "tvos_settings_refresh_trakt_user_info_and_cached_stats",
                                fallback: "Refresh Trakt watch progress, user info, and cached stats"
                            ),
                            value: viewModel.isLoading
                                ? L10n.string("tvos_settings_syncing", fallback: "Syncing")
                                : L10n.string("tvos_settings_refresh", fallback: "Refresh"),
                            accentColor: accentColor
                        ) {
                            viewModel.refreshNow()
                        }
                        .disabled(viewModel.isLoading)
                    }

                    SettingsGroup(
                        title: "Trakt Features",
                        subtitle: "Choose how Trakt is used throughout Nuvio"
                    ) {
                        SettingsChoiceRow(
                            title: L10n.string("trakt_library_source_dialog_title", fallback: "Library Source"),
                            subtitle: "Choose which library to use for saving and viewing your collection",
                            selection: librarySourceSelection,
                            options: ["Trakt", "Nuvio Library"],
                            accentColor: accentColor
                        )

                        SettingsChoiceRow(
                            title: L10n.string("trakt_watch_progress_dialog_title", fallback: "Watch Progress"),
                            subtitle: L10n.string(
                                "tvos_settings_choose_the_source_for_resume_and_continu_53af657c",
                                fallback: "Choose the source for Resume and Continue Watching"
                            ),
                            selection: watchProgressSelection,
                            options: ["Trakt", "Nuvio Sync"],
                            accentColor: accentColor
                        )

                        SettingsChoiceRow(
                            title: L10n.string("trakt_continue_watching_window", fallback: "Continue Watching Window"),
                            subtitle: "Choose how much Trakt activity appears in Continue Watching",
                            selection: continueWatchingSelection,
                            options: continueWatchingOptions.map(continueWatchingLabel),
                            accentColor: accentColor
                        )

                        SettingsChoiceRow(
                            title: L10n.string("trakt_comments_dialog_title", fallback: "Comments"),
                            subtitle: L10n.string(
                                "tvos_settings_show_trakt_reviews_on_metadata_screens",
                                fallback: "Show Trakt reviews on metadata screens"
                            ),
                            selection: commentsSelection,
                            options: [onLabel, offLabel],
                            accentColor: accentColor
                        )

                        SettingsChoiceRow(
                            title: L10n.string("tmdb_more_like_this_title", fallback: "More Like This"),
                            subtitle: L10n.string(
                                "tvos_settings_recommendation_source_for_related_titles",
                                fallback: "Choose where recommendations come from on detail pages"
                            ),
                            selection: moreLikeThisSelection,
                            options: ["Trakt", "TMDB"],
                            accentColor: accentColor
                        )
                    }

                    if let message = viewModel.statusMessage, !message.isEmpty {
                        Text(message)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.62))
                    }

                    }
                    .frame(maxWidth: 1120)
                    .padding(.horizontal, 64)
                    .padding(.top, 52)
                    .padding(.bottom, 24)
                }

                HStack {
                    Button { dismiss() } label: {
                        Text(L10n.string("tvos_settings_back", fallback: "Back"))
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 34)
                            .padding(.vertical, 16)
                            .background(Color.white.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()

                    Spacer()
                }
                .frame(maxWidth: 1120)
                .padding(.horizontal, 64)
                .padding(.bottom, 40)
            }
        }
        .task {
            viewModel.reload()
            viewModel.loadConnectedData()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                now = Date()
            }
        }
        .onChange(of: viewModel.mode) { mode in
            if mode != .connected { dismiss() }
        }
        .confirmationDialog(
            "Disconnect Trakt?",
            isPresented: $showingDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.string("debrid_disconnect", fallback: "Disconnect"), role: .destructive) {
                viewModel.disconnect()
            }
            Button(L10n.string("action_cancel", fallback: "Cancel"), role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(red: 0.94, green: 0.10, blue: 0.17))
                Text("trakt")
                    .font(.system(size: 27, weight: .black))
                    .foregroundColor(.white)
            }
            .frame(width: 108, height: 76)

            VStack(alignment: .leading, spacing: 6) {
                Text("Trakt")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.white)
                Text("Connected as \(connectedUsername)")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
            }

            Spacer()
        }
    }

    private var tokenRefreshLabel: String {
        guard let expiresAt = viewModel.tokenExpiresAtMillis else {
            return "Trakt access token refresh time is unavailable"
        }
        let seconds = max(Int((expiresAt - now.timeIntervalSince1970 * 1000) / 1000), 0)
        return seconds == 0
            ? "Trakt access token refresh is due"
            : "Trakt access token refreshes in \(durationLabel(seconds: seconds))"
    }

    private var connectedUsername: String {
        let username = viewModel.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return username.isEmpty ? "Trakt User" : username
    }

    private func durationLabel(seconds: Int) -> String {
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private var librarySourceSelection: Binding<String> {
        Binding(
            get: { viewModel.librarySourceMode == .trakt ? "Trakt" : "Nuvio Library" },
            set: { viewModel.setLibrarySourceMode($0 == "Trakt" ? .trakt : .local) }
        )
    }

    private var watchProgressSelection: Binding<String> {
        Binding(
            get: { viewModel.watchProgressSource == .trakt ? "Trakt" : "Nuvio Sync" },
            set: { viewModel.setWatchProgressSource($0 == "Trakt" ? .trakt : .nuvioSync) }
        )
    }

    private var continueWatchingSelection: Binding<String> {
        Binding(
            get: { continueWatchingLabel(viewModel.continueWatchingDaysCap) },
            set: { label in
                guard let days = continueWatchingOptions.first(where: { continueWatchingLabel($0) == label }) else { return }
                viewModel.setContinueWatchingDaysCap(days)
            }
        )
    }

    private var commentsSelection: Binding<String> {
        Binding(
            get: { viewModel.showMetaComments ? onLabel : offLabel },
            set: { viewModel.setShowMetaComments($0 == onLabel) }
        )
    }

    private var moreLikeThisSelection: Binding<String> {
        Binding(
            get: { viewModel.moreLikeThisSource == .trakt ? "Trakt" : "TMDB" },
            set: { viewModel.setMoreLikeThisSource($0 == "Trakt" ? .trakt : .tmdb) }
        )
    }

    private var onLabel: String { L10n.string("subtitle_on", fallback: "On") }
    private var offLabel: String { L10n.string("playback_afr_off", fallback: "Off") }

    private func continueWatchingLabel(_ days: Int) -> String {
        days == TraktDefaults.continueWatchingDaysCapAll ? "All history" : "\(days) days"
    }
}

private struct TraktConnectedStatsStrip: View {
    let stats: TraktCachedStats?
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 0) {
            stat(value: stats?.moviesWatched, label: L10n.string("nav_movies", fallback: "Movies"))
            divider
            stat(value: stats?.showsWatched, label: L10n.string("trakt_stat_shows", fallback: "Shows"))
            divider
            stat(value: stats?.episodesWatched, label: L10n.string("tmdb_episodes_title", fallback: "Episodes"))
            divider
            stat(
                text: stats?.totalWatchedHours.map { "\($0)h" },
                label: L10n.string("tvos_settings_hours", fallback: "Watched Hours")
            )
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Divider().overlay(Color.white.opacity(0.16)) }
        .overlay(alignment: .bottom) { Divider().overlay(Color.white.opacity(0.16)) }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.16))
            .frame(width: 1, height: 72)
    }

    private func stat(value: Int?, label: String) -> some View {
        stat(text: value.map(String.init), label: label)
    }

    private func stat(text: String?, label: String) -> some View {
        VStack(spacing: 7) {
            Text(text ?? (isLoading ? "..." : "-"))
                .font(.system(size: 27, weight: .semibold))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white.opacity(0.62))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Full-screen-style device login: large QR + activation code + auto-poll.
private struct TraktDeviceLoginSheet: View {
    @ObservedObject var viewModel: TraktSettingsViewModel
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss

    private var activationURL: String {
        if let code = viewModel.deviceUserCode, !code.isEmpty {
            return "https://trakt.tv/activate/\(code)"
        }
        return viewModel.verificationURL ?? "https://trakt.tv/activate"
    }

    var body: some View {
        VStack(spacing: 28) {
            Text(viewModel.mode == .connected ? L10n.string("tvos_settings_trakt_connected", fallback: "Trakt Connected") : L10n.string("tvos_settings_connect_trakt", fallback: "Connect Trakt"))
                .font(.system(size: 42, weight: .regular))
                .foregroundColor(.white)

            if viewModel.mode == .connected {
                Text(
                    viewModel.username.map {
                        L10n.format("tvos_settings_signed_in_as", fallback: "Signed in as %@", $0)
                    } ?? L10n.string(
                        "tvos_settings_this_apple_tv_is_linked_to_trakt",
                        fallback: "This Apple TV is linked to Trakt."
                    )
                )
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.66))
                    .multilineTextAlignment(.center)
                dialogButton(title: L10n.string("tvos_settings_done", fallback: "Done"), isPrimary: true) { dismiss() }
            } else if viewModel.isLoading && viewModel.deviceUserCode == nil {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(height: 320)
                Text(viewModel.statusMessage ?? L10n.string("tvos_settings_starting_trakt_login", fallback: "Starting Trakt login…"))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.64))
                dialogButton(title: L10n.string("action_cancel", fallback: "Cancel"), isPrimary: false) {
                    viewModel.cancelDeviceFlow()
                    dismiss()
                }
            } else if let code = viewModel.deviceUserCode, !code.isEmpty {
                Text(L10n.string("tvos_settings_trakt_qr_scan_hint", fallback: "Scan the QR on your phone, or open trakt.tv/activate and enter the code."))
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let image = QRCode.image(from: activationURL, scale: 10) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 300, height: 300)
                        .padding(16)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }

                VStack(spacing: 12) {
                    Text(code)
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .tracking(4)
                        .foregroundColor(.white)
                        .accessibilityLabel(
                            L10n.format(
                                "tvos_settings_trakt_activation_code",
                                fallback: "Trakt activation code %@",
                                code
                            )
                        )
                    Text(activationURL)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.54))
                        .lineLimit(1)
                }

                HStack(spacing: 10) {
                    if viewModel.isPolling { ProgressView().tint(.white) }
                    Text(viewModel.statusMessage ?? L10n.string("trakt_waiting_approval", fallback: "Waiting for approval…"))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.64))
                }

                if let error = viewModel.errorMessage, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(red: 1.0, green: 0.43, blue: 0.43))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 18) {
                    dialogButton(title: L10n.string("action_cancel", fallback: "Cancel"), isPrimary: false) {
                        viewModel.cancelDeviceFlow()
                        dismiss()
                    }
                    dialogButton(title: L10n.string("action_retry", fallback: "Retry"), isPrimary: true) {
                        viewModel.cancelDeviceFlow()
                        viewModel.connect()
                    }
                }
            } else {
                Text(viewModel.errorMessage ?? L10n.string("tvos_settings_unable_to_start_trakt_login", fallback: "Unable to start Trakt login."))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(Color(red: 1.0, green: 0.43, blue: 0.43))
                    .multilineTextAlignment(.center)
                HStack(spacing: 18) {
                    dialogButton(title: L10n.string("action_close", fallback: "Close"), isPrimary: false) { dismiss() }
                    dialogButton(title: L10n.string("action_retry", fallback: "Retry"), isPrimary: true) { viewModel.connect() }
                }
            }
        }
        .frame(width: 960)
        .padding(.horizontal, 88)
        .padding(.vertical, 64)
        .background(Color(red: 0.11, green: 0.11, blue: 0.11))
        .onAppear {
            if viewModel.mode != .connected && viewModel.deviceUserCode == nil {
                viewModel.connect()
            } else if viewModel.mode == .awaitingApproval {
                viewModel.retryPolling()
            }
        }
        .onChange(of: viewModel.mode) { mode in
            if mode == .connected {
                // Brief success state then close.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private func dialogButton(title: String, isPrimary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(isPrimary ? .black : .white)
                .padding(.horizontal, 34)
                .padding(.vertical, 16)
                .background(
                    isPrimary ? Color.white : Color.white.opacity(0.14),
                    in: Capsule()
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
    }
}

private struct PlaybackSettingsView: View {
    let accentColor: Color
    let languageFocus: FocusState<LanguagePickerKind?>.Binding
    let onAudioLanguage: () -> Void
    let onSubtitleLanguages: () -> Void

    @AppStorage(SettingsKey.playerEngine) private var playerEngine = "Auto"
    @AppStorage(SettingsKey.externalPlayer) private var externalPlayer = ExternalPlayer.builtIn.rawValue
    @AppStorage(SettingsKey.externalPlayerForwardSubtitles) private var externalPlayerForwardSubtitles = true
    @AppStorage(SettingsKey.smartStreamSelection) private var smartStreamSelection = false
    @AppStorage(SettingsKey.smartStreamQuality) private var smartStreamQuality = "Highest"
    @AppStorage(SettingsKey.smartSubtitleMatching) private var smartSubtitleMatching = true
    @AppStorage(SettingsKey.cachedOnlyStreams) private var cachedOnlyStreams = false
    @AppStorage(SettingsKey.autoPlayNext) private var autoPlayNext = true
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    @AppStorage(SettingsKey.audioLanguage) private var audioLanguage = "System"
    @AppStorage(SettingsKey.subtitleLanguages) private var subtitleLanguages = ""
    @AppStorage(SettingsKey.subtitleLanguage) private var subtitleLanguage = "System"
    @AppStorage(SettingsKey.subtitleLanguageSecondary) private var subtitleLanguageSecondary = "None"
    @AppStorage(SettingsKey.subtitleLanguageTertiary) private var subtitleLanguageTertiary = "None"
    @AppStorage(SettingsKey.forcedSubtitles) private var forcedSubtitles = true
    @AppStorage(SettingsKey.frameRateMatching) private var frameRateMatching = "Always"
    @AppStorage(SettingsKey.networkCache) private var networkCache = "Auto"
    @AppStorage(SettingsKey.assOverrideMode) private var assOverrideMode = "Strip"

    private let engines = ["Auto", "AetherEngine", "MPVKit"]
    private let externalPlayers = ExternalPlayer.settingsOptions
    private let streamQualities = ["Highest", "4K", "1080p", "720p", "Smallest"]
    private let frameRateModes = ["Off", "On start/stop", "Always"]
    /// Buffer profiles: Auto scales to RAM; Conservative/Large match product names;
    /// legacy Small/Medium/Large keys still work via PlaybackCacheSettings.
    private let cacheModes = ["Auto", "Conservative", "Medium", "Large", "Max"]
    private let assModes = ["Strip", "Scale", "Force"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(
                title: L10n.string("tvos_playback_player", fallback: "Player"),
                subtitle: L10n.string(
                    "tvos_playback_player_subtitle",
                    fallback: "Playback engine and episode flow"
                )
            ) {
                SettingsOptionRow(
                    title: L10n.string("tvos_settings_player_engine", fallback: "Player Engine"),
                    subtitle: L10n.string(
                        "tvos_settings_player_engine_aether",
                        fallback: "Auto: AetherEngine (native AV or software) with one-way MPVKit fallback. Force AetherEngine or MPVKit for diagnostics."
                    ),
                    selection: $playerEngine,
                    options: engines,
                    accentColor: accentColor
                )
                .settingsEntryAnchor()

                SettingsOptionRow(
                    title: L10n.string("tvos_settings_external_player", fallback: "External Player"),
                    subtitle: L10n.string("tvos_settings_hand_streams_to_infuse_vlc_outplayer_npl_fb341610", fallback: "Hand streams to Infuse, VLC, Outplayer, nPlayer, or VidHub when installed"),
                    selection: $externalPlayer,
                    options: externalPlayers,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: L10n.string("tvos_settings_forward_subtitles_externally", fallback: "Forward Subtitles Externally"),
                    subtitle: L10n.string("tvos_settings_pass_preferred_subtitle_urls_to_infuse_v_c96faef0", fallback: "Pass preferred subtitle URLs to Infuse/VLC when handing off"),
                    isOn: $externalPlayerForwardSubtitles,
                    accentColor: accentColor
                )
                .opacity(externalPlayer == ExternalPlayer.builtIn.rawValue ? 0.46 : 1)
                .disabled(externalPlayer == ExternalPlayer.builtIn.rawValue)

                SettingsToggleRow(
                    title: L10n.string("tvos_settings_auto_play_next_episode", fallback: "Auto-Play Next Episode"),
                    subtitle: L10n.string("tvos_settings_play_the_next_episode_automatically_with_d5810d0b", fallback: "Play the next episode automatically with a 10-second countdown. Off keeps the Next Episode card with a manual Play."),
                    isOn: $autoPlayNext,
                    accentColor: accentColor
                )

                SettingsOptionRow(
                    title: L10n.string("tvos_settings_frame_rate_matching", fallback: "Frame Rate Matching"),
                    subtitle: L10n.string("tvos_settings_match_display_refresh_to_video_apple_tv__eb667d81", fallback: "Match display refresh to video; Apple TV Match Content must also be enabled"),
                    selection: $frameRateMatching,
                    options: frameRateModes,
                    accentColor: accentColor
                )

                SettingsOptionRow(
                    title: L10n.string("tvos_settings_buffer_profile", fallback: "Buffer Profile"),
                    subtitle: L10n.string(
                        "tvos_settings_buffer_profile_aether",
                        fallback: "Disk-backed forward buffer (Aether segments) / MPV demuxer cache. Auto scales to device RAM."
                    ),
                    selection: $networkCache,
                    options: cacheModes,
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: L10n.string("tvos_settings_smart_playback", fallback: "Smart Playback"), subtitle: L10n.string("tvos_settings_automatically_choose_streams_and_matchin_9ca69e9f", fallback: "Automatically choose streams and matching subtitles")) {
                SettingsToggleRow(
                    title: L10n.string("tvos_settings_auto_select_stream", fallback: "Auto Select Stream"),
                    subtitle: L10n.string("tvos_settings_skip_the_stream_picker_and_choose_the_be_da51db1f", fallback: "Skip the stream picker and choose the best link. Hold Play on details to pick manually."),
                    isOn: $smartStreamSelection,
                    accentColor: accentColor
                )

                SettingsOptionRow(
                    title: L10n.string("tvos_settings_stream_quality", fallback: "Stream Quality"),
                    subtitle: L10n.string("tvos_settings_quality_target_used_when_selecting_a_lin_74ea86c2", fallback: "Quality target used when selecting a link; resume also matches last DV/HDR/Atmos"),
                    selection: $smartStreamQuality,
                    options: streamQualities,
                    accentColor: accentColor
                )
                .opacity(smartStreamSelection ? 1 : 0.46)
                .disabled(!smartStreamSelection)

                SettingsToggleRow(
                    title: L10n.string("tvos_settings_match_subtitle_language", fallback: "Match Subtitle Language"),
                    subtitle: L10n.string("tvos_settings_prefer_links_and_tracks_matching_preferr_cbe68328", fallback: "Prefer links and tracks matching Preferred Subtitle"),
                    isOn: $smartSubtitleMatching,
                    accentColor: accentColor
                )
                .opacity(smartStreamSelection ? 1 : 0.46)
                .disabled(!smartStreamSelection)

                SettingsToggleRow(
                    title: L10n.string("tvos_settings_cached_only", fallback: "Cached Only"),
                    subtitle: L10n.string("tvos_settings_prefer_debrid_cached_links_in_auto_selec_57c11672", fallback: "Prefer debrid-cached links in auto-select and the stream picker filter"),
                    isOn: $cachedOnlyStreams,
                    accentColor: accentColor
                )
            }

            SettingsGroup(
                title: L10n.string("tvos_playback_audio_subtitles", fallback: "Audio & Subtitles"),
                subtitle: L10n.string(
                    "tvos_playback_audio_subtitles_subtitle",
                    fallback: "Language and subtitle rendering defaults"
                )
            ) {
                SettingsActionRow(
                    title: L10n.string("tvos_playback_preferred_audio", fallback: "Preferred Audio"),
                    subtitle: L10n.string(
                        "tvos_playback_preferred_audio_subtitle",
                        fallback: "Default audio language"
                    ),
                    value: audioLanguageSummary,
                    accentColor: accentColor
                ) {
                    onAudioLanguage()
                }
                .focused(languageFocus, equals: .audio)

                SettingsActionRow(
                    title: L10n.string(
                        "tvos_playback_preferred_subtitle",
                        fallback: "Preferred Subtitle"
                    ),
                    subtitle: L10n.string(
                        "tvos_playback_preferred_subtitle_subtitle",
                        fallback: "Choose any number of languages in priority order"
                    ),
                    value: subtitleLanguageSummary,
                    accentColor: accentColor
                ) {
                    onSubtitleLanguages()
                }
                .focused(languageFocus, equals: .subtitles)

                SettingsToggleRow(
                    title: L10n.string("tvos_playback_forced_subtitles", fallback: "Forced Subtitles"),
                    subtitle: L10n.string(
                        "tvos_playback_forced_subtitles_subtitle",
                        fallback: "Use forced subtitles when a matching track exists"
                    ),
                    isOn: $forcedSubtitles,
                    accentColor: accentColor
                )

                SettingsOptionRow(
                    title: L10n.string("tvos_settings_ass_ssa_override", fallback: "ASS/SSA Override"),
                    subtitle: L10n.string("tvos_settings_strip_forces_dialogue_into_your_style_sa_2d8b1dff", fallback: "Strip forces dialogue into your style (safest). Scale keeps layout with size adjust. Force applies style aggressively."),
                    selection: $assOverrideMode,
                    options: assModes,
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: L10n.string("tmdb_trailers_title", fallback: "Trailers"), subtitle: L10n.string("tvos_settings_preview_playback_on_details_and_focused_posters", fallback: "Preview playback on details and focused posters")) {
                SettingsToggleRow(
                    title: L10n.string("tvos_settings_autoplay_trailers", fallback: "Autoplay Trailers"),
                    subtitle: L10n.string("tvos_settings_start_previews_after_focus_settles", fallback: "Start previews after focus settles"),
                    isOn: $trailersEnabled,
                    accentColor: accentColor
                )

                SettingsStepperRow(
                    title: L10n.string("tvos_settings_trailer_delay", fallback: "Trailer Delay"),
                    subtitle: L10n.string("tvos_settings_seconds_before_autoplay_starts", fallback: "Seconds before autoplay starts"),
                    value: $trailerDelay,
                    range: 2...15,
                    step: 1,
                    suffix: "s",
                    accentColor: accentColor
                )
                .opacity(trailersEnabled ? 1 : 0.46)
                .disabled(!trailersEnabled)
            }
        }
        .onAppear {
            let canonical = PlayerEngineSetting.migrated(from: playerEngine).settingsRawValue
            if playerEngine != canonical {
                playerEngine = canonical
            }
        }
    }

    private var audioLanguageSummary: String {
        SubtitleLanguagePreferences.settingsOptions.contains(audioLanguage)
            ? audioLanguage
            : "System"
    }

    private var subtitleLanguageSummary: String {
        let ordered = SubtitleLanguagePreferences.ordered(
            encoded: subtitleLanguages,
            primary: subtitleLanguage,
            secondary: subtitleLanguageSecondary,
            tertiary: subtitleLanguageTertiary
        )
        guard !ordered.isEmpty else { return L10n.string("tvos_settings_system", fallback: "System") }
        guard ordered.count > 2 else { return ordered.joined(separator: ", ") }
        return "\(ordered[0]), \(ordered[1]) +\(ordered.count - 2)"
    }
}

// MARK: - Subtitle Style tab

/// Thin wrapper used by the Settings sidebar tab.
private struct SubtitleStyleSettingsView: View {
    let accentColor: Color
    var body: some View { SubtitleStyleEditor(accentColor: accentColor) }
}

/// The full subtitle-appearance editor: a live preview plus every control.
/// Reused by the Settings tab and by the in-player styling panel. `onChange`
/// fires after any value changes so the player can re-apply the style to mpv
/// live while you watch.
struct SubtitleStyleEditor: View {
    let accentColor: Color
    var onChange: (() -> Void)? = nil

    @AppStorage(SubtitleStyleKey.textSize) private var textSize = SubtitleStyleDefaults.textSize
    @AppStorage(SubtitleStyleKey.bold) private var bold = SubtitleStyleDefaults.bold
    @AppStorage(SubtitleStyleKey.bottomOffset) private var bottomOffset = SubtitleStyleDefaults.bottomOffset
    @AppStorage(SubtitleStyleKey.horizontalMargin) private var horizontalMargin = SubtitleStyleDefaults.horizontalMargin
    @AppStorage(SubtitleStyleKey.letterSpacing) private var letterSpacing = SubtitleStyleDefaults.letterSpacing
    @AppStorage(SubtitleStyleKey.textColor) private var textColor = SubtitleStyleDefaults.textColor
    @AppStorage(SubtitleStyleKey.textOpacity) private var textOpacity = SubtitleStyleDefaults.textOpacity
    @AppStorage(SubtitleStyleKey.outlineEnabled) private var outlineEnabled = SubtitleStyleDefaults.outlineEnabled
    @AppStorage(SubtitleStyleKey.outlineColor) private var outlineColor = SubtitleStyleDefaults.outlineColor

    private var style: SubtitleStyle {
        SubtitleStyle(
            textSize: textSize,
            bold: bold,
            bottomOffset: bottomOffset,
            horizontalMargin: horizontalMargin,
            letterSpacing: letterSpacing,
            textColorHex: textColor,
            textOpacity: textOpacity,
            outlineEnabled: outlineEnabled,
            outlineColorHex: outlineColor
        )
    }

    /// Concatenation of every value; `.onChange` on it fires `onChange` once per edit.
    private var changeToken: String {
        "\(textSize)|\(bold)|\(bottomOffset)|\(horizontalMargin)|\(letterSpacing)|\(textColor)|\(textOpacity)|\(outlineEnabled)|\(outlineColor)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SubtitlePreviewCard(style: style)

            ScrollView {
                controls
                    // Generous trailing room so the last rows can scroll clear of
                    // the scroll view's bottom clip edge — without it, focusing the
                    // final stepper leaves its +/- controls sliced off the bottom.
                    .padding(.bottom, 140)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: changeToken) { _ in onChange?() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: L10n.string("tvos_settings_text", fallback: "Text"), subtitle: L10n.string("tvos_settings_size_weight_spacing_color_and_opacity_of_4755001d", fallback: "Size, weight, spacing, color, and opacity of the caption text")) {
                SettingsStepperRow(
                    title: L10n.string("tvos_settings_text_size", fallback: "Text Size"),
                    subtitle: L10n.string("tvos_settings_relative_subtitle_text_size", fallback: "Relative subtitle text size"),
                    value: $textSize,
                    range: 60...220,
                    step: 5,
                    suffix: "%",
                    accentColor: accentColor
                )
                .settingsEntryAnchor()

                SettingsToggleRow(
                    title: L10n.string("subtitle_bold", fallback: "Bold"),
                    subtitle: L10n.string("tvos_settings_use_a_heavier_caption_weight", fallback: "Use a heavier caption weight"),
                    isOn: $bold,
                    accentColor: accentColor
                )

                SettingsStepperRow(
                    title: L10n.string("tvos_settings_letter_spacing", fallback: "Letter Spacing"),
                    subtitle: L10n.string("tvos_settings_squeeze_the_text_together_or_open_it_up", fallback: "Squeeze the text together or open it up"),
                    value: $letterSpacing,
                    range: -8...40,
                    step: 2,
                    suffix: "",
                    accentColor: accentColor
                )

                SubtitleColorRow(
                    title: L10n.string("subtitle_style_text_color", fallback: "Text Color"),
                    subtitle: L10n.string("tvos_settings_caption_fill_color", fallback: "Caption fill color"),
                    selection: $textColor,
                    accentColor: accentColor
                )

                SettingsStepperRow(
                    title: L10n.string("subtitle_style_text_opacity", fallback: "Text Opacity"),
                    subtitle: L10n.string("tvos_settings_caption_transparency", fallback: "Caption transparency"),
                    value: $textOpacity,
                    range: 20...100,
                    step: 5,
                    suffix: "%",
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: L10n.string("tvos_settings_position", fallback: "Position"), subtitle: L10n.string("tvos_settings_where_captions_sit_on_screen", fallback: "Where captions sit on screen")) {
                SettingsStepperRow(
                    title: L10n.string("tvos_settings_vertical_position", fallback: "Vertical Position"),
                    subtitle: L10n.string("tvos_settings_raise_captions_up_off_the_bottom_edge", fallback: "Raise captions up off the bottom edge"),
                    value: $bottomOffset,
                    range: 0...160,
                    step: 4,
                    suffix: "",
                    accentColor: accentColor
                )

                SettingsStepperRow(
                    title: L10n.string("tvos_settings_horizontal_margin", fallback: "Horizontal Margin"),
                    subtitle: L10n.string("tvos_settings_inset_captions_in_from_the_left_and_right_edges", fallback: "Inset captions in from the left and right edges"),
                    value: $horizontalMargin,
                    range: 0...200,
                    step: 5,
                    suffix: "",
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: L10n.string("subtitle_outline", fallback: "Outline"), subtitle: L10n.string("tvos_settings_border_drawn_around_the_text_for_readability", fallback: "Border drawn around the text for readability")) {
                SettingsToggleRow(
                    title: L10n.string("subtitle_outline", fallback: "Outline"),
                    subtitle: L10n.string("tvos_settings_draw_a_border_around_the_text_for_readability", fallback: "Draw a border around the text for readability"),
                    isOn: $outlineEnabled,
                    accentColor: accentColor
                )

                SubtitleColorRow(
                    title: L10n.string("subtitle_outline_color", fallback: "Outline Color"),
                    subtitle: L10n.string("tvos_settings_border_color_drawn_around_the_text", fallback: "Border color drawn around the text"),
                    selection: $outlineColor,
                    accentColor: accentColor
                )
                .opacity(outlineEnabled ? 1 : 0.46)
                .disabled(!outlineEnabled)
            }

            SettingsGroup(title: L10n.string("subtitle_style_reset", fallback: "Reset"), subtitle: L10n.string("tvos_settings_restore_the_default_subtitle_appearance", fallback: "Restore the default subtitle appearance")) {
                SettingsActionRow(
                    title: L10n.string("subtitle_reset_defaults", fallback: "Reset Defaults"),
                    subtitle: L10n.string("tvos_settings_clears_every_value_on_this_screen", fallback: "Clears every value on this screen"),
                    value: L10n.string("subtitle_style_reset", fallback: "Reset"),
                    accentColor: accentColor,
                    action: resetDefaults
                )
            }
        }
    }

    private func resetDefaults() {
        textSize = SubtitleStyleDefaults.textSize
        bold = SubtitleStyleDefaults.bold
        bottomOffset = SubtitleStyleDefaults.bottomOffset
        horizontalMargin = SubtitleStyleDefaults.horizontalMargin
        letterSpacing = SubtitleStyleDefaults.letterSpacing
        textColor = SubtitleStyleDefaults.textColor
        textOpacity = SubtitleStyleDefaults.textOpacity
        outlineEnabled = SubtitleStyleDefaults.outlineEnabled
        outlineColor = SubtitleStyleDefaults.outlineColor
    }
}

/// Faux video frame that renders sample captions with the live style so the
/// user sees the result before pressing play.
private struct SubtitlePreviewCard: View {
    let style: SubtitleStyle

    private let sampleText = "The quick brown fox jumps over the lazy dog"

    private var fontSize: CGFloat {
        min(max(CGFloat(style.textSize) / 100.0 * 40.0, 16), 92)
    }

    private var previewBottomPadding: CGFloat {
        22 + CGFloat(style.bottomOffset) * 0.7
    }

    private var previewHorizontalPadding: CGFloat {
        16 + CGFloat(min(max(style.horizontalMargin, 0), 200)) / 200.0 * 130.0
    }

    private var previewTracking: CGFloat {
        CGFloat(style.letterSpacing) * 0.6
    }

    private var outlineWidth: CGFloat {
        max(2, fontSize * 0.05)
    }

    private var outlineOffsets: [CGPoint] {
        let w = outlineWidth
        return [
            CGPoint(x: -w, y: 0), CGPoint(x: w, y: 0),
            CGPoint(x: 0, y: -w), CGPoint(x: 0, y: w),
            CGPoint(x: -w, y: -w), CGPoint(x: w, y: -w),
            CGPoint(x: -w, y: w), CGPoint(x: w, y: w)
        ]
    }

    var body: some View {
        // Decorative backdrop only. The 320pt Circle's intrinsic size was warping
        // where `ZStack(.bottom)` placed the caption, dropping it below the card's
        // clipped 220pt bottom. Keeping the caption as a bottom *overlay* pins it to
        // the real 220pt frame instead, so its bottom padding is honored.
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.14, blue: 0.24),
                    Color(red: 0.05, green: 0.06, blue: 0.11),
                    .black
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 320, height: 320)
                .blur(radius: 60)
                .offset(x: -180, y: -70)
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            styledSubtitle
                .frame(maxWidth: .infinity)
                .padding(.horizontal, previewHorizontalPadding)
                .padding(.bottom, previewBottomPadding)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            Text(L10n.string("tvos_settings_preview", fallback: "PREVIEW"))
                .font(.system(size: 14, weight: .black))
                .tracking(2)
                .foregroundColor(.white.opacity(0.5))
                .padding(18)
        }
    }

    private var styledSubtitle: some View {
        let font = Font.system(size: fontSize, weight: style.bold ? .heavy : .semibold)
        let fill = Color(hex: style.textColorHex).opacity(Double(style.textOpacity) / 100.0)
        let outline = Color(hex: style.outlineColorHex)
        return ZStack {
            if style.outlineEnabled {
                ForEach(Array(outlineOffsets.enumerated()), id: \.offset) { _, point in
                    Text(sampleText)
                        .font(font)
                        .foregroundColor(outline)
                        .offset(x: point.x, y: point.y)
                }
            }
            Text(sampleText)
                .font(font)
                .foregroundColor(fill)
        }
        .tracking(previewTracking)
        .multilineTextAlignment(.center)
        .lineLimit(2)
        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
        .animation(.easeOut(duration: 0.12), value: fontSize)
    }
}

private struct SubtitleColorRow: View {
    let title: String
    let subtitle: String
    @Binding var selection: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 20) {
            SettingsRowText(title: title, subtitle: subtitle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                ForEach(SubtitlePalette.colors, id: \.self) { hex in
                    SubtitleColorSwatchButton(
                        hex: hex,
                        isSelected: selection.caseInsensitiveCompare(hex) == .orderedSame,
                        accentColor: accentColor
                    ) {
                        selection = hex
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 74)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous), isProminent: false)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct SubtitleColorSwatchButton: View {
    let hex: String
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: hex))
                .frame(width: 40, height: 40)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .strokeBorder(ringColor, lineWidth: isFocused ? AppFocusOutline.width : (isSelected ? 4 : 0))
                        .padding(-4)
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .entryLockable()
        .scaleEffect(isFocused ? 1.18 : 1.0)
        .zIndex(isFocused ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    private var ringColor: Color {
        if isFocused { return AppFocusOutline.color }
        return isSelected ? accentColor : .clear
    }
}

private struct LanguagePickerWindow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var selection: [String]
    let languages: [String]
    let allowsMultiple: Bool
    let accentColor: Color
    let onDone: () -> Void

    @FocusState private var focusedControl: Control?
    @State private var lastFocusedLanguage: String?

    private enum Control: Hashable {
        case language(String)
        case done
        case leftGuard
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 18) {
                    Image(systemName: systemImage)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(accentColor)
                        .frame(width: 58, height: 58)
                        .settingsGlass(shape: Circle(), isProminent: true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(title)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)
                        Text(subtitle)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(.white.opacity(0.58))
                    }
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(languages, id: \.self) { language in
                            LanguagePickerListRow(
                                language: language,
                                priority: priority(for: language),
                                isSelected: isSelected(language),
                                isFocused: focusedControl == .language(language),
                                accentColor: accentColor
                            ) {
                                toggle(language)
                            }
                            .focused($focusedControl, equals: .language(language))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(alignment: .leading) {
                    Button(action: {}) {
                        Color.white.opacity(0.001)
                            .frame(width: 24, height: 390)
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focused($focusedControl, equals: .leftGuard)
                    .focusEffectDisabledIfAvailable()
                    .offset(x: -18)
                    .accessibilityHidden(true)
                }
                .focusSection()

                HStack {
                    Spacer()
                    Button(action: onDone) {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 18, weight: .bold))
                            Text(L10n.string("tvos_common_done", fallback: "Done"))
                                .font(.system(size: 21, weight: .bold))
                        }
                        .foregroundColor(focusedControl == .done ? .black : .white)
                        .padding(.horizontal, 26)
                        .frame(height: 58)
                        .modifier(
                            TvDetailsGlassBackground(
                                filled: focusedControl == .done,
                                shape: Capsule()
                            )
                        )
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focused($focusedControl, equals: .done)
                    .focusEffectDisabledIfAvailable()
                    .scaleEffect(focusedControl == .done ? 1.06 : 1)
                    .animation(.easeOut(duration: 0.14), value: focusedControl == .done)
                }
            }
            .padding(34)
            .frame(width: 900)
            .settingsGlass(shape: RoundedRectangle(cornerRadius: 34, style: .continuous), isProminent: true)
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            )
            .onAppear {
                let initialLanguage = selectedLanguages.first ?? "System"
                let initialFocus = languages.contains(initialLanguage)
                    ? initialLanguage
                    : (languages.first ?? "System")
                lastFocusedLanguage = initialFocus
                DispatchQueue.main.async {
                    focusedControl = .language(initialFocus)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
        .onChange(of: focusedControl) { control in
            if case .language(let language) = control {
                lastFocusedLanguage = language
            } else if control == .leftGuard {
                let language = lastFocusedLanguage ?? selectedLanguages.first ?? "System"
                DispatchQueue.main.async {
                    focusedControl = .language(languages.contains(language) ? language : (languages.first ?? "System"))
                }
            }
        }
        .onMoveCommand(perform: handleHorizontalMove)
        .onExitCommand(perform: onDone)
    }

    private var selectedLanguages: [String] {
        SubtitleLanguagePreferences.ordered(selection)
    }

    private func priority(for language: String) -> Int? {
        guard allowsMultiple, language != "System" else { return nil }
        return selectedLanguages.firstIndex(of: language).map { $0 + 1 }
    }

    private func isSelected(_ language: String) -> Bool {
        if language == "System" {
            return selectedLanguages.isEmpty
        }
        return selectedLanguages.contains(language)
    }

    private func toggle(_ language: String) {
        if language == "System" {
            selection = []
            return
        }

        guard allowsMultiple else {
            selection = [language]
            return
        }

        var selected = selectedLanguages
        if let index = selected.firstIndex(of: language) {
            selected.remove(at: index)
        } else {
            selected.append(language)
        }
        selection = selected
    }

    private func handleHorizontalMove(_ direction: MoveCommandDirection) {
        guard direction == .right,
              case .language(let language) = focusedControl else {
            return
        }
        lastFocusedLanguage = language
        focusedControl = .done
    }
}

private struct LanguagePickerListRow: View {
    let language: String
    let priority: Int?
    let isSelected: Bool
    let isFocused: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(language)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 24)

                if let priority {
                    Text("\(priority)")
                        .font(.system(size: 18, weight: .black))
                        .foregroundColor(accentColor == .white ? .black : .white)
                        .frame(width: 34, height: 34)
                        .background(accentColor, in: Circle())
                }

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .black))
                        .foregroundColor(accentColor)
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 72)
            .settingsGlass(shape: Capsule(), isProminent: isFocused)
            .overlay(
                Capsule()
                    .strokeBorder(isFocused ? AppFocusOutline.color : Color.white.opacity(isSelected ? 0.28 : 0.12), lineWidth: isFocused ? AppFocusOutline.width : 1)
            )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focusEffectDisabledIfAvailable()
    }
}

private struct AdvancedSettingsView: View {
    let accentColor: Color

    @AppStorage(SettingsKey.fastNavigation) private var fastNavigation = false
    @AppStorage(SettingsKey.smoothFocus) private var smoothFocus = true
    @AppStorage(SettingsKey.playbackDiagnostics) private var playbackDiagnostics = false
    @AppStorage(SettingsKey.focusHighlighter) private var focusHighlighter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(
                title: L10n.string("advanced_section_performance", fallback: "Navigation"),
                subtitle: L10n.string(
                    "tvos_advanced_focus",
                    fallback: "Remote focus behavior for dense rows"
                )
            ) {
                SettingsToggleRow(
                    title: L10n.string("advanced_fast_horizontal_navigation", fallback: "Fast Horizontal Navigation"),
                    subtitle: L10n.string("tvos_settings_move_through_long_poster_rows_more_aggressively", fallback: "Move through long poster rows more aggressively"),
                    isOn: $fastNavigation,
                    accentColor: accentColor
                )
                .settingsEntryAnchor()

                SettingsToggleRow(
                    title: L10n.string("tvos_settings_smooth_bring_into_view", fallback: "Smooth Bring Into View"),
                    subtitle: L10n.string("tvos_settings_animate_focused_content_into_a_readable_position", fallback: "Animate focused content into a readable position"),
                    isOn: $smoothFocus,
                    accentColor: accentColor
                )
            }

            SettingsGroup(
                title: L10n.string("advanced_section_diagnostics", fallback: "Diagnostics"),
                subtitle: L10n.string(
                    "tvos_advanced_diagnostics",
                    fallback: "Local tools for debugging playback and focus"
                )
            ) {
                SettingsToggleRow(
                    title: L10n.string("tvos_settings_playback_issue_reports", fallback: "Playback Issue Reports"),
                    subtitle: L10n.string("tvos_settings_keep_diagnostic_snapshots_after_failed_p_cd841397", fallback: "Keep diagnostic snapshots after failed playback attempts"),
                    isOn: $playbackDiagnostics,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: L10n.string("tvos_settings_focus_highlighter", fallback: "Focus Highlighter"),
                    subtitle: L10n.string("tvos_settings_draw_extra_focus_outlines_for_layout_debugging", fallback: "Draw extra focus outlines for layout debugging"),
                    isOn: $focusHighlighter,
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: L10n.string("subtitle_style_reset", fallback: "Reset"), subtitle: L10n.string("tvos_settings_clear_local_tvos_settings_saved_by_this_screen", fallback: "Clear local tvOS settings saved by this screen")) {
                SettingsActionRow(
                    title: L10n.string("tvos_settings_reset_settings", fallback: "Reset Settings"),
                    subtitle: L10n.string("tvos_settings_restore_the_core_settings_defaults", fallback: "Restore the core settings defaults"),
                    value: L10n.string("subtitle_style_reset", fallback: "Reset"),
                    accentColor: accentColor,
                    action: resetSettings
                )
            }
        }
    }

    private func resetSettings() {
        // Reset only the active profile's settings, not other profiles'.
        let defaults = ProfileSettings.current
        SettingsKey.all.forEach { defaults.removeObject(forKey: $0) }
    }
}

private struct AboutSettingsView: View {
    let accentColor: Color
    @State private var showingLicenses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: L10n.string("tvos_settings_nuviotv", fallback: "NuvioTV"), subtitle: L10n.string("tvos_settings_build_and_runtime_information", fallback: "Build and runtime information")) {
                SettingsInfoRow(title: L10n.string("tvos_settings_app_version", fallback: "App Version"), value: appVersion)
                SettingsInfoRow(title: L10n.string("tvos_settings_engine_core", fallback: "Engine Core"), value: L10n.string("tvos_settings_pure_swift", fallback: "Pure Swift"))
                SettingsInfoRow(title: L10n.string("tvos_settings_playback_stack", fallback: "Playback Stack"), value: L10n.string("tvos_settings_avplayer_mpvkit", fallback: "AetherEngine / MPVKit"))
                SettingsInfoRow(title: L10n.string("tvos_settings_catalog_protocol", fallback: "Catalog Protocol"), value: L10n.string("tvos_settings_stremio_compatible", fallback: "Stremio compatible"))
            }

            SettingsGroup(
                title: L10n.string("about_licenses_attributions", fallback: "Open Source"),
                subtitle: L10n.string(
                    "about_licenses_attributions_subtitle",
                    fallback: "Data sources, acknowledgements, and open-source licenses"
                )
            ) {
                Text(L10n.string("tvos_settings_this_software_uses_swiftui_avplayer_mpvk_78048fa2", fallback: "This software uses SwiftUI, AetherEngine, MPVKit (libmpv), and Stremio-compatible catalog APIs."))
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)

                SettingsActionRow(
                    title: L10n.string(
                        "about_licenses_attributions",
                        fallback: "Licenses & Attributions"
                    ),
                    subtitle: L10n.string("tvos_settings_open_source_components_and_data_providers", fallback: "Open-source components and data providers"),
                    value: L10n.string("tvos_settings_view", fallback: "View"),
                    accentColor: accentColor
                ) {
                    showingLicenses = true
                }
                .settingsEntryAnchor()
            }
        }
        .sheet(isPresented: $showingLicenses) {
            LicensesAttributionsSheet(accentColor: accentColor)
                .modifier(ClearPresentationBackgroundIfAvailable())
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

/// Local attributions for components this tvOS build actually ships with.
private struct LicensesAttributionsSheet: View {
    let accentColor: Color
    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool

    private struct LicenseEntry: Identifiable {
        let id: String
        let title: String
        let body: String
        let license: String
    }

    private let appEntries: [LicenseEntry] = [
        LicenseEntry(
            id: "nuvio",
            title: L10n.string("tvos_settings_nuviotv", fallback: "NuvioTV"),
            body: "Native Apple TV app for browsing Stremio-compatible catalogs and playing streams.",
            license: "GPL-3.0"
        )
    ]

    private let dataEntries: [LicenseEntry] = [
        LicenseEntry(
            id: "tmdb",
            title: L10n.string("mdblist_tmdb_title", fallback: "TMDB"),
            body: "Optional metadata enrichment. This product uses the TMDB API but is not endorsed or certified by TMDB.",
            license: "TMDB API Terms"
        ),
        LicenseEntry(
            id: "trakt",
            title: L10n.string("mdblist_trakt_title", fallback: "Trakt"),
            body: "Optional watch progress, history, and recommendations when a Trakt account is linked.",
            license: "Trakt API Terms"
        ),
        LicenseEntry(
            id: "cinemeta",
            title: L10n.string("tvos_settings_cinemeta_stremio", fallback: "Cinemeta / Stremio"),
            body: "Default catalog and metadata endpoints using the Stremio-compatible add-on protocol.",
            license: "Stremio add-on protocol"
        ),
        LicenseEntry(
            id: "premiumize",
            title: L10n.string("tvos_settings_premiumize", fallback: "Premiumize"),
            body: "Optional debrid resolution and Cloud Library when an account is linked.",
            license: "Premiumize Terms"
        ),
        LicenseEntry(
            id: "torbox",
            title: L10n.string("tvos_settings_torbox", fallback: "TorBox"),
            body: "Optional debrid resolution and Cloud Library when an account is linked.",
            license: "TorBox Terms"
        ),
        LicenseEntry(
            id: "mdblist",
            title: L10n.string("tvos_settings_mdblist", fallback: "MDBList"),
            body: "Optional multi-source rating badges when an API key is configured.",
            license: "MDBList Terms"
        )
    ]

    private let playbackEntries: [LicenseEntry] = [
        LicenseEntry(
            id: "aetherengine",
            title: "AetherEngine 5.14.1",
            body: "Primary playback engine. Complete corresponding source and Nuvio's pinned changes: github.com/superuser404notfound/AetherEngine/tree/5.14.1 and the Vendor/AetherEngine directory in the NuvioTV source distribution.",
            license: "LGPL-3.0 + App Store exception"
        ),
        LicenseEntry(
            id: "aether-ffmpeg",
            title: "FFmpegBuild 2.1.3 (AetherLib*)",
            body: "Dynamically linked FFmpeg 8.1 libraries used by AetherEngine. Relinkable frameworks, license texts, build recipe, and exact source are available at github.com/superuser404notfound/FFmpegBuild/tree/2.1.3 and Vendor/FFmpegBuild.",
            license: "LGPL-2.1-or-later; dav1d BSD-2; zimg WTFPL"
        ),
        LicenseEntry(
            id: "mpvkit",
            title: L10n.string("tvos_settings_mpvkit_libmpv", fallback: "MPVKit / libmpv"),
            body: "One-way compatibility fallback for dual-URL media, audio controls, ASS Scale, and streams AetherEngine cannot open.",
            license: "GPL-2.0-or-later (libmpv) / project licenses"
        ),
        LicenseEntry(
            id: "ffmpeg",
            title: L10n.string("tvos_settings_ffmpeg_via_mpvkit", fallback: "FFmpeg (via MPVKit)"),
            body: "Demuxing, decoding helpers, and related libraries bundled with the MPVKit build.",
            license: "LGPL / GPL components per FFmpeg build"
        ),
        LicenseEntry(
            id: "apple-media",
            title: L10n.string("tvos_settings_avfoundation_avplayer", fallback: "Apple media frameworks"),
            body: "AVFoundation, VideoToolbox, Core Media, and AudioToolbox system APIs used by AetherEngine's native and hardware-accelerated paths.",
            license: "Apple system frameworks"
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("tvos_settings_licenses_attributions", fallback: "Licenses & Attributions"))
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                    Text(L10n.string("tvos_settings_components_used_by_this_tvos_build", fallback: "Components used by this tvOS build"))
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.62))
                }
                Spacer(minLength: 24)
                Button(action: { dismiss() }) {
                    Text(L10n.string("action_close", fallback: "Close"))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(closeFocused ? .black : .white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 16)
                        .background(
                            Capsule(style: .continuous)
                                .fill(closeFocused ? accentColor : Color.white.opacity(0.12))
                        )
                }
                .buttonStyle(PosterCardButtonStyle())
                .focused($closeFocused)
                .focusEffectDisabledIfAvailable()
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    licenseSection(title: L10n.string("tvos_settings_app", fallback: "App"), entries: appEntries)
                    licenseSection(title: L10n.string("tvos_settings_data_services", fallback: "Data & services"), entries: dataEntries)
                    licenseSection(title: L10n.string("settings_playback", fallback: "Playback"), entries: playbackEntries)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 48)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
        .onAppear { closeFocused = true }
    }

    @ViewBuilder
    private func licenseSection(title: String, entries: [LicenseEntry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white.opacity(0.9))

            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.title)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer(minLength: 16)
                        Text(entry.license)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(accentColor)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                    Text(entry.body)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .settingsGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous), isProminent: false)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
            }
        }
    }
}

// MARK: - Addons (moved here from the former Addons tab)

private struct AddonsSettingsSection: View {
    let accentColor: Color

    @AppStorage(SettingsKey.streamAddonManifestURL) private var streamAddonManifestURL = ""
    @AppStorage(SettingsKey.streamAddonManifestURLs) private var streamAddonManifestURLs = ""
    @AppStorage(SettingsKey.streamAddonManifestStates) private var streamAddonManifestStates = ""
    @State private var addonURLInput = ""
    @State private var addons: [AddonItem] = AddonItem.defaults
    @State private var syncedAddons: [SyncedAddon] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            SettingsGroup(title: L10n.string("tvos_settings_add_ons", fallback: "Add-ons"), subtitle: L10n.string("tvos_settings_stremio_compatible_catalogs_streams_and__cd03738a", fallback: "Stremio-compatible catalogs, streams, and subtitles")) {
                SettingsTextFieldRow(
                    title: L10n.string("tvos_settings_add_on_url", fallback: "Add-on URL"),
                    subtitle: L10n.string("tvos_settings_paste_a_stremio_manifest_link_or_stremio_2968c517", fallback: "Paste a Stremio manifest link or stremio:// install URL"),
                    placeholder: L10n.string(
                        "tvos_settings_addon_url_placeholder",
                        fallback: "https://.../manifest.json"
                    ),
                    text: $addonURLInput,
                    fieldWidth: 560,
                    onCommit: addAddonFromInput
                )
                .settingsEntryAnchor()

                ForEach(Array(syncedAddons.enumerated()), id: \.element.id) { index, addon in
                    SyncedAddonSettingsRow(
                        addon: addon,
                        accentColor: accentColor,
                        canMoveUp: index > 0,
                        canMoveDown: index < syncedAddons.count - 1,
                        onEnabledChange: { isEnabled in setAddonEnabled(at: index, isEnabled: isEnabled) },
                        onMove: { up in moveAddon(at: index, up: up) }
                    )
                }

                ForEach($addons) { $addon in
                    if !isCoveredBySyncedAddon(addon) {
                        AddonSettingsRow(addon: addon, accentColor: accentColor) {
                            toggle(addon)
                        }
                    }
                }
            }
        }
        .task(id: streamAddonManifestURL + "\n" + streamAddonManifestURLs + "\n" + streamAddonManifestStates) {
            await loadSyncedAddons()
        }
    }

    /// Reorders the configured manifests, rewrites the settings the repository
    /// reads (order = stream priority and Home row order), and pushes the new
    /// order to the account so the next sync pull can't revert it.
    private func moveAddon(at index: Int, up: Bool) {
        let target = up ? index - 1 : index + 1
        guard syncedAddons.indices.contains(index), syncedAddons.indices.contains(target) else { return }
        syncedAddons.swapAt(index, target)
        persistSyncedAddons()
    }

    private func setAddonEnabled(at index: Int, isEnabled: Bool) {
        guard syncedAddons.indices.contains(index) else { return }
        syncedAddons[index].isEnabled = isEnabled
        persistSyncedAddons()
    }

    /// Finalizing the URL field is an add operation, not just a local settings
    /// edit. Canonicalize the complete list and notify sync immediately so the
    /// new add-on reaches the user's other devices.
    private func addAddonFromInput() {
        guard let url = CinemetaCatalogRepository.normalizedManifestURL(from: addonURLInput) else { return }
        var preferences = CinemetaCatalogRepository.configuredStreamAddonPreferences
        if let index = preferences.firstIndex(where: { $0.url == url.absoluteString }) {
            preferences[index].enabled = true
        } else {
            preferences.append(StreamAddonPreference(url: url.absoluteString, enabled: true))
        }

        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences(preferences)
        streamAddonManifestURL = ProfileSettings.current.string(forKey: SettingsKey.streamAddonManifestURL) ?? ""
        streamAddonManifestURLs = ProfileSettings.current.string(forKey: SettingsKey.streamAddonManifestURLs) ?? ""
        streamAddonManifestStates = ProfileSettings.current.string(forKey: SettingsKey.streamAddonManifestStates) ?? ""
        addonURLInput = ""
        NotificationCenter.default.post(
            name: NuvioSyncManager.addonOrderChangedNotification,
            object: preferences
        )
    }

    private func persistSyncedAddons() {
        let preferences = syncedAddons.map {
            StreamAddonPreference(url: $0.url.absoluteString, enabled: $0.isEnabled)
        }
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences(preferences)
        streamAddonManifestURL = ProfileSettings.current.string(forKey: SettingsKey.streamAddonManifestURL) ?? ""
        streamAddonManifestURLs = ProfileSettings.current.string(forKey: SettingsKey.streamAddonManifestURLs) ?? ""
        streamAddonManifestStates = ProfileSettings.current.string(forKey: SettingsKey.streamAddonManifestStates) ?? ""
        NotificationCenter.default.post(
            name: NuvioSyncManager.addonOrderChangedNotification,
            object: preferences
        )
    }

    /// Lists every configured/synced manifest immediately (named by host), then
    /// upgrades each row with the real name/version/description from its
    /// manifest as the fetches come back.
    private func loadSyncedAddons() async {
        let preferences = CinemetaCatalogRepository.configuredStreamAddonPreferences
        // Keep already-resolved names/descriptions (e.g. across a reorder) so
        // rows don't flash back to host-derived names.
        var resolved = preferences.compactMap { preference -> SyncedAddon? in
            guard let url = CinemetaCatalogRepository.normalizedManifestURL(from: preference.url) else { return nil }
            var addon = syncedAddons.first { $0.url == url } ?? SyncedAddon(url: url)
            addon.isEnabled = preference.enabled
            return addon
        }
        syncedAddons = resolved

        for index in resolved.indices {
            guard !Task.isCancelled else { return }
            if let manifest = await StremioManifest.fetch(from: resolved[index].url) {
                resolved[index].apply(manifest)
                syncedAddons = resolved
            }
        }
    }

    /// Hides a built-in placeholder row when the account sync already provides
    /// the same addon (matched loosely by name/host, so the synced "Cinemeta"
    /// covers the built-in Cinemeta row instead of showing a duplicate).
    private func isCoveredBySyncedAddon(_ addon: AddonItem) -> Bool {
        let target = Self.normalizedAddonKey(addon.name)
        guard !target.isEmpty else { return false }
        return syncedAddons.contains { synced in
            Self.normalizedAddonKey(synced.name).contains(target)
                || Self.normalizedAddonKey(synced.url.host ?? "").contains(target)
        }
    }

    private static func normalizedAddonKey(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private func toggle(_ addon: AddonItem) {
        guard !addon.isLocked else { return }
        if let idx = addons.firstIndex(where: { $0.id == addon.id }) {
            addons[idx].isInstalled.toggle()
        }
    }
}

/// One add-on synced from the account (or entered manually), shown in the
/// Add-ons section. Starts with just the manifest URL; name/version/description
/// arrive once the manifest is fetched.
private struct SyncedAddon: Identifiable {
    let url: URL
    var name: String
    var version: String?
    var description: String?
    var isEnabled: Bool

    var id: String { url.absoluteString }

    init(url: URL, isEnabled: Bool = true) {
        self.url = url
        self.name = CinemetaCatalogRepository.streamAddonName(for: url)
        self.isEnabled = isEnabled
    }

    mutating func apply(_ manifest: StremioManifest) {
        if let manifestName = manifest.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !manifestName.isEmpty {
            name = manifestName
        }
        version = manifest.version
        description = manifest.description
    }

    var subtitle: String {
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? (url.host ?? url.absoluteString) : trimmed
    }
}

struct StremioManifest: Decodable {
    let name: String?
    let version: String?
    let description: String?

    static func fetch(from manifestURL: URL) async -> StremioManifest? {
        guard let (data, response) = try? await URLSession.shared.data(from: manifestURL),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            return nil
        }
        return try? JSONDecoder().decode(StremioManifest.self, from: data)
    }
}

private struct SyncedAddonSettingsRow: View {
    let addon: SyncedAddon
    let accentColor: Color
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    var onEnabledChange: ((Bool) -> Void)? = nil
    /// Called with `true` for up, `false` for down. nil hides the arrows.
    var onMove: ((Bool) -> Void)? = nil

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            rowButton

            if let onEnabledChange {
                AddonReorderButton(systemImage: addon.isEnabled ? "power.circle.fill" : "power.circle", disabled: false) {
                    onEnabledChange(!addon.isEnabled)
                }
            }

            if let onMove {
                AddonReorderButton(systemImage: "chevron.up", disabled: !canMoveUp) {
                    onMove(true)
                }
                AddonReorderButton(systemImage: "chevron.down", disabled: !canMoveDown) {
                    onMove(false)
                }
            }
        }
    }

    private var rowButton: some View {
        Button(action: { onEnabledChange?(!addon.isEnabled) }) {
            SettingsRowShell(isFocused: isFocused, accentColor: accentColor) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 26))
                    .foregroundColor(addon.isEnabled ? accentColor : .white.opacity(0.38))
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(addon.name)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(addon.isEnabled ? .white : .white.opacity(0.46))
                            .lineLimit(1)
                        if let version = addon.version, !version.isEmpty {
                            Text("v\(version)")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        Text(L10n.string("tvos_settings_synced", fallback: "Synced"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(accentColor)
                    }
                    Text(addon.subtitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(addon.isEnabled ? 0.56 : 0.36))
                        .lineLimit(2)
                }

                Spacer(minLength: 20)

                Text(addon.isEnabled ? L10n.string("settings_fusion_badge_url_active", fallback: "Active") : L10n.string("tvos_settings_disabled", fallback: "Disabled"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(addon.isEnabled ? .white.opacity(0.7) : .white.opacity(0.42))
                    .lineLimit(1)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .entryLockable()
    }
}

/// Chevron button for moving an add-on up/down in the priority order.
private struct AddonReorderButton: View {
    let systemImage: String
    let disabled: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(focused ? .black : .white.opacity(0.8))
                .frame(width: 52, height: 52)
                .background(focused ? Color.white : Color.white.opacity(0.1))
                .clipShape(Circle())
                .opacity(disabled ? 0.35 : 1)
                .scaleEffect(focused && !disabled ? 1.08 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .disabled(disabled)
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .animation(.easeOut(duration: 0.12), value: focused)
        .entryLockable()
    }
}

// MARK: - Home catalog reordering

/// Settings → Layout → Home Catalogs: reorder the rows Home shows. The list
/// comes from the snapshot Home writes on every load; moves persist to the
/// active profile's settings and re-apply to a mounted Home immediately.
private struct HomeCatalogOrderSection: View {
    let accentColor: Color
    @State private var rows: [(id: String, title: String)] = []

    var body: some View {
        SettingsGroup(title: L10n.string("tvos_settings_home_catalogs", fallback: "Home Catalogs"), subtitle: L10n.string("tvos_settings_controls_catalog_and_collection_row_orde_b7069193", fallback: "Controls catalog and collection row order on Home")) {
            if rows.isEmpty {
                SettingsInfoRow(title: L10n.string("tvos_settings_no_rows_recorded_yet", fallback: "No rows recorded yet"), value: L10n.string("tvos_settings_open_home_once", fallback: "Open Home once"))
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HomeCatalogOrderRow(
                        title: row.title,
                        accentColor: accentColor,
                        canMoveUp: index > 0,
                        canMoveDown: index < rows.count - 1
                    ) { up in
                        move(index, up: up)
                    }
                }
            }
        }
        .onAppear { rows = TVHomeCatalogOrder.snapshotRows() }
    }

    private func move(_ index: Int, up: Bool) {
        let target = up ? index - 1 : index + 1
        guard rows.indices.contains(index), rows.indices.contains(target) else { return }
        rows.swapAt(index, target)
        TVHomeCatalogOrder.save(rows.map(\.id))
        TVHomeCatalogOrder.writeSnapshotRows(rows)
    }
}

private struct HomeCatalogOrderRow: View {
    let title: String
    let accentColor: Color
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMove: (Bool) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button(action: {}) {
                SettingsRowShell(isFocused: isFocused, accentColor: accentColor) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 24))
                        .foregroundColor(accentColor)
                        .frame(width: 48, height: 48)

                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer(minLength: 20)
                }
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($isFocused)
            .focusEffectDisabledIfAvailable()
            .entryLockable()

            AddonReorderButton(systemImage: "chevron.up", disabled: !canMoveUp) { onMove(true) }
            AddonReorderButton(systemImage: "chevron.down", disabled: !canMoveDown) { onMove(false) }
        }
    }
}

// MARK: - Collections manager

/// Settings → Layout → Collections: Android-style Export / Import / New entry
/// points, liquid-glass panels, and a full create/edit form. Edits mutate the
/// raw synced JSON so Android-only fields survive the round-trip.
private struct CollectionsSettingsSection: View {
    let accentColor: Color

    @State private var collections: [[String: Any]] = []
    @State private var activeSheet: CollectionsSheet?
    @State private var statusToast: String?
    @State private var toastClearTask: Task<Void, Never>?

    var body: some View {
        SettingsGroup(title: L10n.string("tmdb_collections_title", fallback: "Collections"), subtitle: L10n.string("tvos_settings_group_catalogs_into_folders_on_your_home_screen", fallback: "Group catalogs into folders on your home screen")) {
            CollectionsActionBar(
                accentColor: accentColor,
                canExport: !collections.isEmpty,
                onExport: exportCollections,
                onImport: { activeSheet = .importCollections },
                onNew: { activeSheet = .editor(nil) }
            )

            if collections.isEmpty {
                Text(L10n.string("tvos_settings_no_collections_yet_use_new_collection_or_9375fe6e", fallback: "No collections yet. Use New Collection, or Import a JSON backup."))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(collections.enumerated()), id: \.offset) { index, collection in
                    CollectionSettingsRow(
                        name: (collection["title"] as? String) ?? "Untitled",
                        detail: detailText(for: collection),
                        isPinned: (collection["pinToTop"] as? Bool) ?? false,
                        accentColor: accentColor,
                        onEdit: { activeSheet = .editor(index) },
                        onTogglePin: { togglePin(index) },
                        onDelete: { remove(index) }
                    )
                }
            }

            if let statusToast {
                Text(statusToast)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(accentColor)
                    .transition(.opacity)
            }
        }
        .onAppear { collections = CollectionsStore.rawCollections() }
        .onReceive(NotificationCenter.default.publisher(for: CollectionsStore.changedNotification)) { _ in
            collections = CollectionsStore.rawCollections()
        }
        .sheet(item: $activeSheet) { sheet in
            Group {
                switch sheet {
                case .importCollections:
                    ImportCollectionsSheet(accentColor: accentColor) { imported in
                        importCollections(imported)
                    }
                case .editor(let index):
                    CollectionEditorSheet(
                        accentColor: accentColor,
                        existing: index.flatMap { collections[safe: $0] },
                        onSave: { payload in
                            if let index {
                                guard collections.indices.contains(index) else { return }
                                // Preserve unknown Android-only keys by merging onto the existing dict.
                                var merged = collections[index]
                                for (key, value) in payload { merged[key] = value }
                                collections[index] = merged
                            } else {
                                collections.append(payload)
                            }
                            CollectionsStore.saveLocalEdit(collections)
                        }
                    )
                }
            }
            // Let liquid glass frost over Settings instead of an opaque sheet plate.
            .modifier(ClearPresentationBackgroundIfAvailable())
        }
    }

    private func detailText(for collection: [String: Any]) -> String {
        let folders = (collection["folders"] as? [[String: Any]]) ?? []
        let sourceCount = folders.reduce(0) { partial, folder in
            partial + (((folder["sources"] as? [[String: Any]])?.count) ?? 0)
                + (((folder["catalogSources"] as? [[String: Any]])?.count) ?? 0)
        }
        let folderText = "\(folders.count) folder\(folders.count == 1 ? "" : "s")"
        return "\(folderText) • \(sourceCount) catalog\(sourceCount == 1 ? "" : "s")"
    }

    private func exportCollections() {
        guard let data = try? JSONSerialization.data(
            withJSONObject: collections,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            showToast("Export failed")
            return
        }
        // tvOS has no general pasteboard/share sheet for arbitrary files in this
        // context — write a stable JSON export the Import flow can re-load.
        let url = Self.collectionsExportURL
        do {
            try data.write(to: url, options: .atomic)
            showToast("Exported to Documents/nuvio-collections.json")
        } catch {
            showToast("Export failed: \(error.localizedDescription)")
        }
    }

    static var collectionsExportURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nuvio-collections.json")
    }

    private func importCollections(_ imported: [[String: Any]]) {
        // Merge by id: imported wins on collision, existing keep unique entries.
        var byId: [String: [String: Any]] = [:]
        for row in collections {
            if let id = row["id"] as? String { byId[id] = row }
        }
        for row in imported {
            if let id = row["id"] as? String { byId[id] = row }
        }
        // Preserve order: existing first, then newly imported ids.
        var merged: [[String: Any]] = []
        var seen = Set<String>()
        for row in collections {
            guard let id = row["id"] as? String, let latest = byId[id], seen.insert(id).inserted else { continue }
            merged.append(latest)
        }
        for row in imported {
            guard let id = row["id"] as? String, let latest = byId[id], seen.insert(id).inserted else { continue }
            merged.append(latest)
        }
        collections = merged
        CollectionsStore.saveLocalEdit(collections)
        showToast("Imported \(imported.count) collection\(imported.count == 1 ? "" : "s")")
    }

    private func togglePin(_ index: Int) {
        guard collections.indices.contains(index) else { return }
        let pinned = (collections[index]["pinToTop"] as? Bool) ?? false
        collections[index]["pinToTop"] = !pinned
        CollectionsStore.saveLocalEdit(collections)
    }

    private func remove(_ index: Int) {
        guard collections.indices.contains(index) else { return }
        collections.remove(at: index)
        CollectionsStore.saveLocalEdit(collections)
    }

    private func showToast(_ message: String) {
        toastClearTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { statusToast = message }
        toastClearTask = Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) { statusToast = nil }
            }
        }
    }
}

private enum CollectionsSheet: Identifiable {
    case importCollections
    case editor(Int?)

    var id: String {
        switch self {
        case .importCollections: return "import"
        case .editor(let index): return "editor-\(index.map(String.init) ?? "new")"
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Export / Import / New Collection actions — same Liquid Glass language as LoginView.
private struct CollectionsActionBar: View {
    let accentColor: Color
    let canExport: Bool
    let onExport: () -> Void
    let onImport: () -> Void
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            CollectionsGlassButton(
                title: L10n.string("tvos_settings_export", fallback: "Export"),
                systemImage: "square.and.arrow.up",
                prominent: false,
                disabled: !canExport,
                action: onExport
            )
            CollectionsGlassButton(
                title: L10n.string("action_import", fallback: "Import"),
                systemImage: "square.and.arrow.down",
                prominent: false,
                disabled: false,
                action: onImport
            )
            CollectionsGlassButton(
                title: L10n.string("tvos_settings_new_collection", fallback: "New Collection"),
                systemImage: "plus",
                prominent: true,
                disabled: false,
                action: onNew
            )
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .loginGlassPanel()
    }
}

/// Settings-style capsule button — flat glass fill + focus outline (matches
/// settings pills / FilterChip) so nested glass panels don't double-box.
private struct CollectionsGlassButton: View {
    let title: String
    var systemImage: String? = nil
    var prominent: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 22, weight: .semibold))
            .foregroundColor(foreground)
            .padding(.horizontal, 26)
            .frame(height: 58)
            .frame(minWidth: 180)
            .background(chipBackground, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: focused ? AppFocusOutline.width : 1)
            )
            .opacity(disabled ? 0.5 : 1)
            .scaleEffect(focused && !disabled ? 1.03 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .disabled(disabled)
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .animation(.easeOut(duration: 0.12), value: focused)
        .entryLockable()
    }

    private var foreground: Color {
        if focused || prominent { return .black }
        return .white.opacity(0.9)
    }

    private var chipBackground: Color {
        if focused { return .white }
        if prominent { return Color.white.opacity(0.88) }
        return Color.white.opacity(0.08)
    }

    private var borderColor: Color {
        if focused { return AppFocusOutline.color }
        return Color.white.opacity(prominent ? 0.20 : 0.14)
    }
}

private struct CollectionSettingsRow: View {
    let name: String
    let detail: String
    let isPinned: Bool
    let accentColor: Color
    let onEdit: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onEdit) {
                SettingsRowShell(isFocused: isFocused, accentColor: accentColor) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 24))
                        .foregroundColor(accentColor)
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(name)
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            if isPinned {
                                Text(L10n.string("tvos_settings_pinned", fallback: "PINNED"))
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(accentColor)
                            }
                        }
                        Text(
                            L10n.format(
                                "tvos_settings_detail_click_to_edit",
                                fallback: "%@ — click to edit",
                                detail
                            )
                        )
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.56))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 20)
                }
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($isFocused)
            .focusEffectDisabledIfAvailable()
            .entryLockable()

            AddonReorderButton(systemImage: isPinned ? "pin.slash" : "pin", disabled: false, action: onTogglePin)
            AddonReorderButton(systemImage: "trash", disabled: false, action: onDelete)
        }
    }
}

// MARK: Collection editor (New / Edit)

/// Full create/edit sheet matching Android CollectionEditor essentials:
/// name, pin-to-top, focus glow, view mode, folders, and catalog sources.
private struct CollectionEditorSheet: View {
    let accentColor: Color
    let existing: [String: Any]?
    let onSave: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""
    @State private var pinToTop = false
    @State private var focusGlowEnabled = true
    @State private var viewMode = "TABBED_GRID"
    @State private var showAllTab = true
    @State private var folders: [[String: Any]] = []
    @State private var sourcePicker: FolderSourcePicker?

    private var isNew: Bool { existing == nil }

    /// Which source-add flow is open for a folder index (Android: Catalog / TMDB / Trakt).
    private enum FolderSourcePicker: Identifiable {
        case catalogs(Int)
        case tmdb(Int)
        case trakt(Int)

        var id: String {
            switch self {
            case .catalogs(let i): return "catalogs-\(i)"
            case .tmdb(let i): return "tmdb-\(i)"
            case .trakt(let i): return "trakt-\(i)"
            }
        }

        var folderIndex: Int {
            switch self {
            case .catalogs(let i), .tmdb(let i), .trakt(let i): return i
            }
        }
    }

    private let viewModes: [(id: String, label: String)] = [
        ("TABBED_GRID", "Tabs"),
        ("ROWS", "Rows"),
        ("FOLLOW_LAYOUT", "Follow layout")
    ]

    var body: some View {
        // Match LanguagePickerWindow (Preferred Subtitle / Preferred Audio): same
        // scrim, 900pt panel width, settingsGlass chrome, and footer layout.
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                // Fixed header — above scroll content (zIndex) so scrolled rows
                // never paint through the title.
                HStack(spacing: 18) {
                    Image(systemName: isNew ? "folder.badge.plus" : "folder.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(accentColor)
                        .frame(width: 58, height: 58)
                        .settingsGlass(shape: Circle(), isProminent: true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(isNew ? L10n.string("tvos_settings_new_collection", fallback: "New Collection") : L10n.string("tvos_settings_edit_collection", fallback: "Edit Collection"))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)
                        Text(isNew
                             ? "Name the collection, pin it if you want, then add folders and catalogs."
                             : "Update folders, pin status, and catalog sources for this collection.")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 22)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.001)) // solid hit/layer for stacking
                .zIndex(2)

                // Clipped scroll region (same pattern as LanguagePickerWindow).
                // Do NOT use scrollClipDisabled — that let content bleed through
                // the header and Cancel/Create footer.
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        // Same glass search bar as the Search tab (magnifier +
                        // hidden UITextField + GlassCapsule), not a native TextField.
                        // Do not auto-focus / open the keyboard on present.
                        SettingsSearchStyleField(
                            text: $title,
                            placeholder: L10n.string("tvos_settings_collection_name", fallback: "Collection name"),
                            autoFocus: false
                        )

                        // Same row chrome as the rest of Settings (SettingsRowShell
                        // + focus outline) — avoids nested glass panels / double boxes.
                        SettingsToggleRow(
                            title: L10n.string("tvos_settings_pin_above_catalogs", fallback: "Pin above catalogs"),
                            subtitle: L10n.string("tvos_settings_show_this_collection_above_standard_home_rows", fallback: "Show this collection above standard Home rows"),
                            isOn: $pinToTop,
                            accentColor: accentColor
                        )

                        SettingsToggleRow(
                            title: L10n.string("tvos_settings_focus_glow", fallback: "Focus glow"),
                            subtitle: L10n.string("tvos_settings_soft_glow_around_focused_folder_cards_android", fallback: "Soft glow around focused folder cards (Android)"),
                            isOn: $focusGlowEnabled,
                            accentColor: accentColor
                        )

                        SettingsToggleRow(
                            title: L10n.string("tvos_settings_show_all_tab", fallback: "Show All tab"),
                            subtitle: L10n.string("tvos_settings_include_an_all_tab_when_browsing_folder_tabs", fallback: "Include an All tab when browsing folder tabs"),
                            isOn: $showAllTab,
                            accentColor: accentColor
                        )

                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.string("tvos_settings_view_mode", fallback: "View mode"))
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white.opacity(0.55))
                            HStack(spacing: 12) {
                                ForEach(viewModes, id: \.id) { mode in
                                    CollectionChipButton(
                                        title: mode.label,
                                        isSelected: viewMode == mode.id
                                    ) {
                                        viewMode = mode.id
                                    }
                                }
                            }
                        }

                        Divider().background(Color.white.opacity(0.1)).padding(.vertical, 2)

                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                Text(L10n.string("tvos_settings_folders", fallback: "Folders"))
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(.white)
                                Spacer()
                                CollectionsGlassButton(
                                    title: L10n.string("tvos_settings_add_folder", fallback: "Add folder"),
                                    systemImage: "plus",
                                    prominent: false,
                                    action: addFolder
                                )
                            }

                            if folders.isEmpty {
                                Text(L10n.string("tvos_settings_add_at_least_one_folder_then_attach_catalogs", fallback: "Add at least one folder, then attach catalogs."))
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.white.opacity(0.5))
                            }

                            ForEach(Array(folders.enumerated()), id: \.offset) { index, folder in
                                CollectionFolderEditorCard(
                                    folder: binding(forFolderAt: index),
                                    accentColor: accentColor,
                                    onAddCatalog: { sourcePicker = .catalogs(index) },
                                    onAddTmdb: { sourcePicker = .tmdb(index) },
                                    onAddTrakt: { sourcePicker = .trakt(index) },
                                    onDelete: { removeFolder(at: index) }
                                )
                            }
                        }
                    }
                    .padding(.top, 2)
                    // Room so the last focused control can scroll fully above footer.
                    .padding(.bottom, 36)
                    // Extra side inset so focus-scaled chips/buttons don't clip
                    // against the scroll/panel edges (Add folder, View mode, etc.).
                    .padding(.horizontal, 12)
                }
                .frame(maxHeight: 520)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .focusSection()
                .zIndex(0)

                // Fixed footer — sits above scroll so Cancel/Create never sit
                // under/over folder rows.
                HStack(spacing: 14) {
                    Spacer()
                    CollectionsGlassButton(title: L10n.string("action_cancel", fallback: "Cancel"), action: { dismiss() })
                    CollectionsGlassButton(
                        title: isNew ? L10n.string("library_list_create", fallback: "Create") : L10n.string("action_save", fallback: "Save"),
                        systemImage: isNew ? "plus" : "checkmark",
                        prominent: true,
                        disabled: !canSave,
                        action: save
                    )
                }
                .padding(.top, 22)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.001))
                .zIndex(2)
            }
            // Wider side padding than Preferred Subtitle (34) so scaled controls
            // clear the rounded glass edge instead of getting clipped.
            .padding(.vertical, 34)
            .padding(.horizontal, 48)
            .frame(width: 900)
            .settingsGlass(shape: RoundedRectangle(cornerRadius: 34, style: .continuous), isProminent: true)
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: loadExisting)
        .sheet(item: $sourcePicker) { picker in
            switch picker {
            case .catalogs(let index):
                CollectionCatalogPickerSheet(
                    collectionName: folderTitle(at: index),
                    selectedIds: selectedSourceIds(at: index),
                    onToggle: { option in toggleSource(option, at: index) }
                )
            case .tmdb(let index):
                CollectionTmdbSourceSheet(accentColor: accentColor) { payload in
                    appendSource(payload, at: index)
                }
            case .trakt(let index):
                CollectionTraktSourceSheet(accentColor: accentColor) { payload in
                    appendSource(payload, at: index)
                }
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !folders.isEmpty
    }

    private func loadExisting() {
        guard let existing else {
            // Seed one empty folder (title is placeholder-only until the user types).
            folders = [Self.makeEmptyFolder(title: "")]
            return
        }
        title = (existing["title"] as? String) ?? ""
        pinToTop = (existing["pinToTop"] as? Bool) ?? false
        focusGlowEnabled = (existing["focusGlowEnabled"] as? Bool) ?? true
        viewMode = (existing["viewMode"] as? String) ?? "TABBED_GRID"
        showAllTab = (existing["showAllTab"] as? Bool) ?? true
        folders = (existing["folders"] as? [[String: Any]]) ?? []
        if folders.isEmpty {
            folders = [Self.makeEmptyFolder(title: "")]
        }
    }

    private static func makeEmptyFolder(title: String) -> [String: Any] {
        [
            "id": UUID().uuidString,
            "title": title,
            "tileShape": "SQUARE",
            "hideTitle": false,
            "focusGifEnabled": true,
            "sources": [[String: Any]]()
        ]
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !folders.isEmpty else { return }
        // If the only folder still has an empty title, inherit the collection name.
        var savedFolders = folders
        if savedFolders.count == 1 {
            let folderTitle = (savedFolders[0]["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if folderTitle.isEmpty {
                savedFolders[0]["title"] = trimmed
            }
        }
        var payload: [String: Any] = [
            "id": (existing?["id"] as? String) ?? UUID().uuidString,
            "title": trimmed,
            "pinToTop": pinToTop,
            "focusGlowEnabled": focusGlowEnabled,
            "viewMode": viewMode,
            "showAllTab": showAllTab,
            "folders": savedFolders
        ]
        if let backdrop = existing?["backdropImageUrl"] as? String {
            payload["backdropImageUrl"] = backdrop
        }
        onSave(payload)
        dismiss()
    }

    private func addFolder() {
        folders.append(Self.makeEmptyFolder(title: ""))
    }

    private func appendSource(_ source: [String: Any], at index: Int) {
        guard folders.indices.contains(index) else { return }
        var sources = (folders[index]["sources"] as? [[String: Any]]) ?? []
        sources.append(source)
        folders[index]["sources"] = sources
    }

    private func removeFolder(at index: Int) {
        guard folders.indices.contains(index) else { return }
        folders.remove(at: index)
    }

    private func binding(forFolderAt index: Int) -> Binding<[String: Any]> {
        Binding(
            get: { folders.indices.contains(index) ? folders[index] : [:] },
            set: { newValue in
                guard folders.indices.contains(index) else { return }
                folders[index] = newValue
            }
        )
    }

    private func folderTitle(at index: Int) -> String {
        (folders[safe: index]?["title"] as? String) ?? "Folder"
    }

    private func selectedSourceIds(at index: Int) -> Set<String> {
        guard let folder = folders[safe: index] else { return [] }
        var ids = Set<String>()
        for source in (folder["sources"] as? [[String: Any]]) ?? [] {
            if let addonId = source["addonId"] as? String,
               let type = source["type"] as? String,
               let catalogId = source["catalogId"] as? String {
                ids.insert("\(addonId)_\(type)_\(catalogId)")
            }
        }
        return ids
    }

    private func toggleSource(_ option: AddonCatalogOption, at index: Int) {
        guard folders.indices.contains(index) else { return }
        var sources = (folders[index]["sources"] as? [[String: Any]]) ?? []
        let matches: ([String: Any]) -> Bool = { source in
            source["addonId"] as? String == option.addonId
                && source["type"] as? String == option.type
                && source["catalogId"] as? String == option.catalogId
        }
        if sources.contains(where: matches) {
            sources.removeAll(where: matches)
        } else {
            sources.append([
                "provider": "addon",
                "addonId": option.addonId,
                "type": option.type,
                "catalogId": option.catalogId
            ])
        }
        folders[index]["sources"] = sources
    }

}

/// Glass search-style field matching `SearchView.searchBar`: hidden UITextField
/// (no system white pill), optional magnifier + live text, clear, `GlassCapsule`.
private struct SettingsSearchStyleField: View {
    @Binding var text: String
    var placeholder: String = L10n.string("nav_search", fallback: "Search")
    var autoFocus: Bool = false
    var showsClear: Bool = true
    /// When false, omits the magnifying-glass (e.g. folder title with an icon outside).
    var showsMagnifier: Bool = true
    var height: CGFloat = 86
    var fontSize: CGFloat = 30
    var horizontalPadding: CGFloat = 34

    @FocusState private var isFocused: Bool
    @State private var isEditing = false

    var body: some View {
        ZStack(alignment: .leading) {
            HiddenSettingsTextField(
                text: $text,
                isEditing: $isEditing
            )
            .frame(width: 1, height: 1)
            .offset(x: -4_000)
            .allowsHitTesting(false)

            Button {
                isFocused = true
                isEditing = true
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PosterCardButtonStyle())
            .focused($isFocused)
            .focusEffectDisabledIfAvailable()

            HStack(spacing: showsMagnifier ? 18 : 0) {
                if showsMagnifier {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                }

                Text(text.isEmpty ? placeholder : text)
                    .font(.system(size: fontSize, weight: .regular))
                    .foregroundColor(text.isEmpty ? .white.opacity(0.45) : .white)
                    .lineLimit(1)
                    .allowsHitTesting(false)

                Spacer(minLength: 0)

                if showsClear && !text.isEmpty {
                    Button {
                        text = ""
                        isFocused = true
                        isEditing = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: fontSize))
                            .foregroundColor(.white.opacity(0.55))
                    }
                    .buttonStyle(PosterCardButtonStyle())
                    .focusEffectDisabledIfAvailable()
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCapsule(focused: isFocused || isEditing))
        .onAppear {
            guard autoFocus else { return }
            DispatchQueue.main.async {
                isFocused = true
                isEditing = true
            }
        }
    }
}

/// Settings-style chip (same glass language as category pills / FilterChip).
/// Uses a flat fill + focus outline instead of nested `loginGlassCapsule`
/// so chips do not read as a second glass box inside the editor panel.
private struct CollectionChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(textColor)
                .padding(.horizontal, 28)
                .frame(height: 52)
                .background(chipBackground, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(borderColor, lineWidth: focused ? AppFocusOutline.width : 1)
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .scaleEffect(focused ? 1.05 : 1)
        .animation(.easeOut(duration: 0.12), value: focused)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var textColor: Color {
        if focused { return .black }
        return isSelected ? .white.opacity(0.96) : .white.opacity(0.85)
    }

    private var chipBackground: Color {
        if focused { return .white }
        return Color.white.opacity(isSelected ? 0.18 : 0.06)
    }

    private var borderColor: Color {
        if focused { return AppFocusOutline.color }
        return Color.white.opacity(isSelected ? 0.28 : 0.12)
    }
}

/// Folder create/edit card matching Android `FolderEditorContent` field order:
/// title → cover (none/emoji/image) → focus GIF → hero backdrop/video/logo →
/// tile shape → hide title → catalogs (addon / TMDB / Trakt).
private struct CollectionFolderEditorCard: View {
    @Binding var folder: [String: Any]
    let accentColor: Color
    let onAddCatalog: () -> Void
    let onAddTmdb: () -> Void
    let onAddTrakt: () -> Void
    let onDelete: () -> Void

    private enum CoverMode: String, CaseIterable, Identifiable {
        case none = "None"
        case emoji = "Emoji"
        case image = "Image URL"
        var id: String { rawValue }
    }

    private let coverEmojis = ["📁", "🎬", "⭐", "🔥", "💎", "🎮", "📺", "🚀", "❤️", "🎵", "🍿", "🏆"]

    /// Matches Preferred Subtitle / LanguagePickerWindow panel radius.
    private let cardRadius: CGFloat = 34

    /// Dictionary subscripts on `Binding<[String: Any]>` do not write back
    /// (value-type copy). Always assign a full replacement dictionary.
    private func updateFolder(_ mutate: (inout [String: Any]) -> Void) {
        var copy = folder
        mutate(&copy)
        folder = copy
    }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { (folder[key] as? String) ?? "" },
            set: { newValue in
                updateFolder { dict in
                    // Title stays as "" (placeholder mode); other empty optionals drop the key.
                    if key == "title" {
                        dict[key] = newValue
                        return
                    }
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        dict.removeValue(forKey: key)
                    } else {
                        dict[key] = trimmed
                    }
                }
            }
        )
    }

    private func boolBinding(_ key: String, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { (folder[key] as? Bool) ?? defaultValue },
            set: { newValue in updateFolder { $0[key] = newValue } }
        )
    }

    private var tileShape: CollectionTileShape {
        CollectionTileShape.fromStored(folder["tileShape"] as? String)
    }

    private var sources: [[String: Any]] {
        (folder["sources"] as? [[String: Any]]) ?? []
    }

    private var coverMode: CoverMode {
        // Non-nil key = that mode, even when the value is still empty (placeholder).
        if folder["coverImageUrl"] != nil { return .image }
        if folder["coverEmoji"] != nil { return .emoji }
        return .none
    }

    private var coverImageBinding: Binding<String> {
        Binding(
            get: { (folder["coverImageUrl"] as? String) ?? "" },
            // Keep the key (even empty) so Image URL mode stays selected.
            set: { newValue in updateFolder { $0["coverImageUrl"] = newValue } }
        )
    }

    private var coverEmojiBinding: Binding<String> {
        Binding(
            get: { (folder["coverEmoji"] as? String) ?? "" },
            // Keep the key so Emoji mode stays selected while empty.
            set: { newValue in updateFolder { $0["coverEmoji"] = newValue } }
        )
    }

    private func setCoverMode(_ mode: CoverMode) {
        updateFolder { dict in
            switch mode {
            case .none:
                dict.removeValue(forKey: "coverImageUrl")
                dict.removeValue(forKey: "coverEmoji")
            case .emoji:
                dict.removeValue(forKey: "coverImageUrl")
                // Don't prefill emoji as "real" text — leave empty until user picks.
                if dict["coverEmoji"] == nil {
                    dict["coverEmoji"] = ""
                }
            case .image:
                dict.removeValue(forKey: "coverEmoji")
                if dict["coverImageUrl"] == nil {
                    dict["coverImageUrl"] = ""
                }
            }
        }
    }

    private func sourceLabel(_ source: [String: Any]) -> String {
        let provider = (source["provider"] as? String ?? "addon").lowercased()
        switch provider {
        case "tmdb":
            let title = (source["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let type = source["tmdbSourceType"] as? String ?? "TMDB"
            if let title, !title.isEmpty {
                return L10n.format("tvos_settings_tmdb_title", fallback: "TMDB · %@", title)
            }
            return L10n.format("tvos_settings_tmdb_type", fallback: "TMDB · %@", type)
        case "trakt":
            let title = (source["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let title, !title.isEmpty {
                return L10n.format("tvos_settings_trakt_title", fallback: "Trakt · %@", title)
            }
            if let id = source["traktListId"] {
                return L10n.format("tvos_settings_trakt_list_id", fallback: "Trakt · list %@", "\(id)")
            }
            return L10n.string("tvos_settings_trakt_list", fallback: "Trakt list")
        default:
            let catalogId = source["catalogId"] as? String ?? "catalog"
            let type = (source["type"] as? String ?? "").capitalized
            let addon = source["addonId"] as? String ?? "addon"
            return type.isEmpty ? "\(addon) · \(catalogId)" : "\(type) · \(catalogId)"
        }
    }

    private func removeSource(at index: Int) {
        updateFolder { dict in
            var list = (dict["sources"] as? [[String: Any]]) ?? []
            guard list.indices.contains(index) else { return }
            list.remove(at: index)
            dict["sources"] = list
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                // Same glass search bar as collection title — empty placeholder, no seed text.
                SettingsSearchStyleField(
                    text: stringBinding("title"),
                    placeholder: L10n.string("tvos_settings_folder_title", fallback: "Folder title"),
                    showsMagnifier: true,
                    height: 64,
                    fontSize: 24,
                    horizontalPadding: 24
                )

                CollectionsGlassButton(
                    title: L10n.string("tvos_settings_remove", fallback: "Remove"),
                    systemImage: "trash",
                    action: onDelete
                )
            }

            // MARK: Cover — None / Emoji / Image URL
            labeledSection("Cover") {
                HStack(spacing: 12) {
                    ForEach(CoverMode.allCases) { mode in
                        CollectionChipButton(
                            title: mode == .emoji && coverMode == .emoji
                                ? {
                                    let e = (folder["coverEmoji"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                    return e.isEmpty ? "Emoji" : "\(e) Emoji"
                                }()
                                : mode.rawValue,
                            isSelected: coverMode == mode
                        ) {
                            setCoverMode(mode)
                        }
                    }
                }

                if coverMode == .image {
                    SettingsSearchStyleField(
                        text: coverImageBinding,
                        placeholder: L10n.string("tvos_settings_image_url", fallback: "Image URL"),
                        height: 58,
                        fontSize: 20,
                        horizontalPadding: 22
                    )
                }

                if coverMode == .emoji {
                    SettingsSearchStyleField(
                        text: coverEmojiBinding,
                        placeholder: L10n.string("tvos_settings_type_or_pick_an_emoji", fallback: "Type or pick an emoji"),
                        showsMagnifier: false,
                        height: 58,
                        fontSize: 22,
                        horizontalPadding: 22
                    )
                    // Dedicated emoji chips — CollectionChipButton was clipping/hiding glyphs.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(coverEmojis, id: \.self) { emoji in
                                CollectionEmojiChip(
                                    emoji: emoji,
                                    isSelected: (folder["coverEmoji"] as? String) == emoji
                                ) {
                                    updateFolder { $0["coverEmoji"] = emoji }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                    }
                }
            }

            // MARK: Focus GIF
            labeledSection("Focus GIF") {
                SettingsSearchStyleField(
                    text: stringBinding("focusGifUrl"),
                    placeholder: L10n.string("tvos_settings_gif_animated_image_url_optional", fallback: "GIF / animated image URL (optional)"),
                    height: 58,
                    fontSize: 20,
                    horizontalPadding: 22
                )
                SettingsToggleRow(
                    title: L10n.string("tvos_settings_play_focus_gif", fallback: "Play focus GIF"),
                    subtitle: L10n.string("tvos_settings_show_the_gif_when_this_folder_card_is_focused", fallback: "Show the GIF when this folder card is focused"),
                    isOn: boolBinding("focusGifEnabled", default: true),
                    accentColor: accentColor
                )
            }

            // MARK: Modern Home hero fields (Android parity)
            labeledSection("Hero Backdrop (Modern Home)") {
                SettingsSearchStyleField(
                    text: stringBinding("heroBackdropUrl"),
                    placeholder: L10n.string("tvos_settings_custom_hero_backdrop_url_optional", fallback: "Custom hero backdrop URL (optional)"),
                    height: 58,
                    fontSize: 20,
                    horizontalPadding: 22
                )
            }

            labeledSection("Hero Video (Modern Home)") {
                SettingsSearchStyleField(
                    text: stringBinding("heroVideoUrl"),
                    placeholder: L10n.string("tvos_settings_custom_hero_video_url_optional", fallback: "Custom hero video URL (optional)"),
                    height: 58,
                    fontSize: 20,
                    horizontalPadding: 22
                )
            }

            labeledSection("Title Logo (Modern Home)") {
                SettingsSearchStyleField(
                    text: stringBinding("titleLogoUrl"),
                    placeholder: L10n.string("tvos_settings_custom_title_logo_url_optional", fallback: "Custom title logo URL (optional)"),
                    height: 58,
                    fontSize: 20,
                    horizontalPadding: 22
                )
            }

            // MARK: Tile shape (existing)
            labeledSection("Tile shape") {
                HStack(spacing: 12) {
                    ForEach(CollectionTileShape.allCases) { shape in
                        CollectionChipButton(
                            title: shape.label,
                            isSelected: tileShape == shape
                        ) {
                            updateFolder { $0["tileShape"] = shape.rawValue }
                        }
                    }
                }
                CollectionTileShapePreview(shape: tileShape)
            }

            // MARK: Hide title
            SettingsToggleRow(
                title: L10n.string("tvos_settings_hide_title", fallback: "Hide title"),
                subtitle: L10n.string("tvos_settings_hide_the_folder_name_on_the_home_card", fallback: "Hide the folder name on the Home card"),
                isOn: boolBinding("hideTitle", default: false),
                accentColor: accentColor
            )

            // MARK: Catalogs — Android: Add Catalog / TMDB / Trakt
            labeledSection("Catalogs") {
                if sources.isEmpty {
                    Text(L10n.string("tvos_settings_no_sources_yet", fallback: "No sources yet"))
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                } else {
                    VStack(spacing: 10) {
                        ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                            HStack(spacing: 12) {
                                Text(sourceLabel(source))
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                CollectionsGlassButton(
                                    title: L10n.string("tvos_settings_remove", fallback: "Remove"),
                                    systemImage: "xmark",
                                    action: { removeSource(at: index) }
                                )
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .settingsGlass(
                                shape: RoundedRectangle(cornerRadius: 18, style: .continuous),
                                isProminent: false
                            )
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        CollectionsGlassButton(
                            title: L10n.string("tvos_settings_add_catalog", fallback: "Add Catalog"),
                            systemImage: "plus",
                            action: onAddCatalog
                        )
                        CollectionsGlassButton(
                            title: L10n.string("tvos_settings_add_tmdb_source", fallback: "Add TMDB Source"),
                            systemImage: "plus",
                            action: onAddTmdb
                        )
                        CollectionsGlassButton(
                            title: L10n.string("tvos_settings_add_trakt_list", fallback: "Add Trakt List"),
                            systemImage: "plus",
                            action: onAddTrakt
                        )
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(22)
        .settingsGlass(shape: RoundedRectangle(cornerRadius: cardRadius, style: .continuous), isProminent: false)
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func labeledSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
            content()
        }
    }
}

/// Circular emoji picker chip — large glyph, no capsule clipping of emoji.
private struct CollectionEmojiChip: View {
    let emoji: String
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 30))
                .frame(width: 58, height: 58)
                .background(
                    Circle().fill(focused ? Color.white : Color.white.opacity(isSelected ? 0.22 : 0.10))
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            focused ? AppFocusOutline.color : Color.white.opacity(isSelected ? 0.45 : 0.16),
                            lineWidth: focused ? AppFocusOutline.width : 1
                        )
                )
                .scaleEffect(focused ? 1.08 : 1)
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($focused)
        .focusEffectDisabledIfAvailable()
        .animation(.easeOut(duration: 0.12), value: focused)
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

/// Small outline of poster / landscape / square so tile shape choice is visible.
private struct CollectionTileShapePreview: View {
    let shape: CollectionTileShape

    private var previewHeight: CGFloat { 72 }
    private var previewWidth: CGFloat { previewHeight * CGFloat(shape.aspectRatio) }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
                )
                .frame(width: previewWidth, height: previewHeight)
                .animation(.easeOut(duration: 0.16), value: shape)

            Text(shape.label)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: Import collections

private struct ImportCollectionsSheet: View {
    let accentColor: Color
    let onImport: ([[String: Any]]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: ImportMode = .file
    @State private var loadedRows: [[String: Any]]?
    @State private var urlText = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var statusNote: String?

    private enum ImportMode: String, CaseIterable, Identifiable {
        case file = "From export file"
        case url = "From URL"
        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color.tvBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 24) {
                Text(L10n.string("tvos_settings_import_collections", fallback: "Import Collections"))
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)

                Text(L10n.string("tvos_settings_import_a_nuvio_collections_json_export_s_e61b6e41", fallback: "Import a Nuvio collections JSON export (same format as Android). Use a prior Apple TV export, or host the JSON and fetch by URL."))
                    .font(.system(size: 22, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    ForEach(ImportMode.allCases) { item in
                        CollectionChipButton(
                            title: item.rawValue,
                            isSelected: mode == item
                        ) {
                            mode = item
                            errorMessage = nil
                            statusNote = nil
                            if item == .file { loadLocalExport() }
                        }
                    }
                }

                Group {
                    switch mode {
                    case .file:
                        VStack(alignment: .leading, spacing: 14) {
                            Text(L10n.string("tvos_settings_looks_for_documents_nuvio_collections_js_6c13671b", fallback: "Looks for Documents/nuvio-collections.json — the file written by Export on this Apple TV."))
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)

                            CollectionsGlassButton(
                                title: L10n.string("tvos_settings_reload_export_file", fallback: "Reload export file"),
                                systemImage: "arrow.clockwise",
                                action: loadLocalExport
                            )
                        }
                    case .url:
                        VStack(alignment: .leading, spacing: 14) {
                            TextField("https://…/nuvio-collections.json", text: $urlText)
                                .font(.system(size: 22, weight: .medium))
                                .padding(.horizontal, 24)
                                .frame(height: 58)
                                .modifier(GlassCapsule(focused: false))

                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                CollectionsGlassButton(
                                    title: L10n.string("tvos_settings_fetch_url", fallback: "Fetch URL"),
                                    systemImage: "arrow.down.circle",
                                    prominent: true,
                                    disabled: urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                    action: { Task { await fetchURL() } }
                                )
                            }
                        }
                    }
                }

                if let loadedRows {
                    Text(
                        L10n.format(
                            loadedRows.count == 1
                                ? "tvos_settings_ready_to_import_one"
                                : "tvos_settings_ready_to_import_many",
                            fallback: loadedRows.count == 1
                                ? "Ready to import %d collection"
                                : "Ready to import %d collections",
                            loadedRows.count
                        )
                    )
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Color(red: 0.49, green: 1.0, blue: 0.61))
                } else if let statusNote {
                    Text(statusNote)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(Color(red: 1.0, green: 0.43, blue: 0.43))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Spacer(minLength: 8)

                Divider().background(Color.white.opacity(0.1))

                HStack(spacing: 14) {
                    CollectionsGlassButton(title: L10n.string("action_cancel", fallback: "Cancel"), action: { dismiss() })
                    CollectionsGlassButton(
                        title: L10n.string("action_import", fallback: "Import"),
                        systemImage: "square.and.arrow.down",
                        prominent: true,
                        disabled: loadedRows == nil,
                        action: {
                            if let loadedRows {
                                onImport(loadedRows)
                                dismiss()
                            }
                        }
                    )
                }
            }
            .padding(40)
            .frame(maxWidth: 900, maxHeight: 780)
            .loginGlassPanel()
        }
        .onAppear { loadLocalExport() }
    }

    private func loadLocalExport() {
        let url = CollectionsSettingsSection.collectionsExportURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadedRows = nil
            statusNote = "No export file found yet. Use Export first, or switch to From URL."
            errorMessage = nil
            return
        }
        do {
            let data = try Data(contentsOf: url)
            guard let rows = parseCollections(data: data) else {
                loadedRows = nil
                errorMessage = "Export file is not valid collections JSON"
                return
            }
            loadedRows = rows
            statusNote = nil
            errorMessage = nil
        } catch {
            loadedRows = nil
            errorMessage = error.localizedDescription
        }
    }

    private func fetchURL() async {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            errorMessage = "Invalid URL"
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                errorMessage = "HTTP \(http.statusCode)"
                return
            }
            guard let rows = parseCollections(data: data) else {
                errorMessage = "URL did not return valid collections JSON"
                loadedRows = nil
                return
            }
            loadedRows = rows
            statusNote = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func parseCollections(data: Data) -> [[String: Any]]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        if let rows = object as? [[String: Any]] {
            return rows.allSatisfy({ $0["id"] is String && $0["title"] is String }) ? rows : nil
        }
        if let wrapped = object as? [String: Any],
           let rows = wrapped["collections"] as? [[String: Any]],
           rows.allSatisfy({ $0["id"] is String && $0["title"] is String }) {
            return rows
        }
        return nil
    }
}

private struct CollectionCatalogPickerSheet: View {
    let collectionName: String
    /// Ids of already-attached options at presentation time.
    let selectedIds: Set<String>
    let onToggle: (AddonCatalogOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var options: [AddonCatalogOption] = []
    @State private var localSelected: Set<String> = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()

            VStack(spacing: 24) {
                Text(
                    L10n.format(
                        "tvos_settings_add_catalogs_to_collection",
                        fallback: "Add Catalogs to %@",
                        collectionName
                    )
                )
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isLoading {
                    ProgressView().tint(.white)
                        .frame(maxHeight: .infinity)
                } else if options.isEmpty {
                    Text(L10n.string("tvos_settings_no_add_on_catalogs_available_install_add_99af8a31", fallback: "No add-on catalogs available. Install add-ons with catalogs first."))
                        .font(.system(size: 22))
                        .foregroundColor(.white.opacity(0.6))
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(options) { option in
                                let selected = localSelected.contains(option.id)
                                Button {
                                    if selected {
                                        localSelected.remove(option.id)
                                    } else {
                                        localSelected.insert(option.id)
                                    }
                                    onToggle(option)
                                } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 24))
                                            .foregroundColor(selected
                                                             ? Color(red: 0.49, green: 1.0, blue: 0.61)
                                                             : .white.opacity(0.4))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.catalogName)
                                                .font(.system(size: 22, weight: .semibold))
                                                .foregroundColor(.white)
                                                .lineLimit(1)
                                            Text("\(option.addonName) • \(option.type.capitalized)")
                                                .font(.system(size: 16, weight: .medium))
                                                .foregroundColor(.white.opacity(0.56))
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 16)
                                    .settingsGlass(
                                        shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
                                        isProminent: selected
                                    )
                                }
                                .buttonStyle(PosterCardButtonStyle())
                                .focusEffectDisabledIfAvailable()
                            }
                        }
                    }
                    .frame(maxHeight: 480)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                }

                HStack {
                    Spacer()
                    CollectionsGlassButton(
                        title: L10n.string("tvos_settings_done", fallback: "Done"),
                        systemImage: "checkmark",
                        prominent: true,
                        action: { dismiss() }
                    )
                }
            }
            .padding(.vertical, 34)
            .padding(.horizontal, 48)
            .frame(width: 900)
            .settingsGlass(shape: RoundedRectangle(cornerRadius: 34, style: .continuous), isProminent: true)
            .overlay(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            localSelected = selectedIds
            options = await CinemetaCatalogRepository().availableAddonCatalogs()
            isLoading = false
        }
    }
}

// MARK: - TMDB / Trakt source sheets (Android folder source buttons)

/// Minimal TMDB source form — writes Android-compatible `provider: tmdb` JSON.
private struct CollectionTmdbSourceSheet: View {
    let accentColor: Color
    let onAdd: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var titleText = ""
    @State private var tmdbIdText = ""
    @State private var sourceType = "DISCOVER"
    @State private var mediaType = "movie"

    private let sourceTypes = ["DISCOVER", "COLLECTION", "COMPANY", "NETWORK", "LIST", "PERSON", "DIRECTOR"]
    private let mediaTypes = [("movie", "Movie"), ("tv", "TV")]

    private var canAdd: Bool {
        !titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        sourceSheetChrome(title: L10n.string("tvos_settings_add_tmdb_source", fallback: "Add TMDB Source"), subtitle: L10n.string("tvos_settings_attach_a_tmdb_list_collection_company_or_b80d234f", fallback: "Attach a TMDB list, collection, company, or discover query.")) {
            labeled("Title") {
                SettingsSearchStyleField(text: $titleText, placeholder: L10n.string("tvos_settings_source_title", fallback: "Source title"), height: 58, fontSize: 20, horizontalPadding: 22)
            }
            labeled("TMDB ID (optional)") {
                SettingsSearchStyleField(text: $tmdbIdText, placeholder: L10n.string("tvos_settings_numeric_tmdb_id", fallback: "Numeric TMDB id"), height: 58, fontSize: 20, horizontalPadding: 22)
            }
            labeled("Source type") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(sourceTypes, id: \.self) { type in
                            CollectionChipButton(title: type.capitalized, isSelected: sourceType == type) {
                                sourceType = type
                            }
                        }
                    }
                }
            }
            labeled("Media type") {
                HStack(spacing: 12) {
                    ForEach(mediaTypes, id: \.0) { id, label in
                        CollectionChipButton(title: label, isSelected: mediaType == id) {
                            mediaType = id
                        }
                    }
                }
            }
        } footer: {
            CollectionsGlassButton(title: L10n.string("action_cancel", fallback: "Cancel"), action: { dismiss() })
            CollectionsGlassButton(
                title: L10n.string("tvos_settings_add", fallback: "Add"),
                systemImage: "plus",
                prominent: true,
                disabled: !canAdd,
                action: add
            )
        }
    }

    private func add() {
        let trimmedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        var payload: [String: Any] = [
            "provider": "tmdb",
            "tmdbSourceType": sourceType,
            "title": trimmedTitle,
            "mediaType": mediaType,
            "sortBy": "popularity.desc"
        ]
        if let id = Int(tmdbIdText.trimmingCharacters(in: .whitespacesAndNewlines)), id > 0 {
            payload["tmdbId"] = id
        }
        onAdd(payload)
        dismiss()
    }
}

/// Minimal Trakt list form — writes Android-compatible `provider: trakt` JSON.
private struct CollectionTraktSourceSheet: View {
    let accentColor: Color
    let onAdd: ([String: Any]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var titleText = ""
    @State private var listIdText = ""
    @State private var mediaType = "movie"

    private let mediaTypes = [("movie", "Movie"), ("tv", "TV")]

    private var canAdd: Bool {
        !titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && Int64(listIdText.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    var body: some View {
        sourceSheetChrome(title: L10n.string("tvos_settings_add_trakt_list", fallback: "Add Trakt List"), subtitle: L10n.string("tvos_settings_attach_a_public_trakt_list_by_numeric_list_id", fallback: "Attach a public Trakt list by numeric list id.")) {
            labeled("Title") {
                SettingsSearchStyleField(text: $titleText, placeholder: L10n.string("tvos_settings_list_title", fallback: "List title"), height: 58, fontSize: 20, horizontalPadding: 22)
            }
            labeled("Trakt list ID") {
                SettingsSearchStyleField(text: $listIdText, placeholder: L10n.string("tvos_settings_e_g_123456", fallback: "e.g. 123456"), height: 58, fontSize: 20, horizontalPadding: 22)
            }
            labeled("Media type") {
                HStack(spacing: 12) {
                    ForEach(mediaTypes, id: \.0) { id, label in
                        CollectionChipButton(title: label, isSelected: mediaType == id) {
                            mediaType = id
                        }
                    }
                }
            }
        } footer: {
            CollectionsGlassButton(title: L10n.string("action_cancel", fallback: "Cancel"), action: { dismiss() })
            CollectionsGlassButton(
                title: L10n.string("tvos_settings_add", fallback: "Add"),
                systemImage: "plus",
                prominent: true,
                disabled: !canAdd,
                action: add
            )
        }
    }

    private func add() {
        let trimmedTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let listId = Int64(listIdText.trimmingCharacters(in: .whitespacesAndNewlines)), listId > 0 else { return }
        guard !trimmedTitle.isEmpty else { return }
        onAdd([
            "provider": "trakt",
            "title": trimmedTitle,
            "traktListId": listId,
            "mediaType": mediaType,
            "sortBy": "rank",
            "sortHow": "asc"
        ])
        dismiss()
    }
}

/// Shared liquid-glass panel chrome for the TMDB / Trakt add sheets.
private func sourceSheetChrome<Content: View, Footer: View>(
    title: String,
    subtitle: String,
    @ViewBuilder content: () -> Content,
    @ViewBuilder footer: () -> Footer
) -> some View {
    ZStack {
        Color.black.opacity(0.62).ignoresSafeArea()
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            HStack(spacing: 14) {
                Spacer()
                footer()
            }
        }
        .padding(.vertical, 34)
        .padding(.horizontal, 48)
        .frame(width: 900)
        .settingsGlass(shape: RoundedRectangle(cornerRadius: 34, style: .continuous), isProminent: true)
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(Color.white.opacity(0.20), lineWidth: 1)
        )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

@ViewBuilder
private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.white.opacity(0.55))
        content()
    }
}

private struct AddonSettingsRow: View {
    let addon: AddonItem
    let accentColor: Color
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            SettingsRowShell(isFocused: isFocused, accentColor: accentColor) {
                Image(systemName: addon.logoSystemName)
                    .font(.system(size: 26))
                    .foregroundColor(addon.isOfficial ? accentColor : .white.opacity(0.8))
                    .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(addon.name)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("v\(addon.version)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                        if addon.isOfficial {
                            Text(L10n.string("tvos_settings_official", fallback: "Official"))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(accentColor)
                        }
                    }
                    Text(addon.description)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.56))
                        .lineLimit(2)
                }

                Spacer(minLength: 20)

                Text(statusLabel)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(statusColor)
                    .lineLimit(1)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .disabled(addon.isLocked)
        .entryLockable()
    }

    private var statusLabel: String {
        if addon.isLocked { return L10n.string("tvos_settings_locked", fallback: "Locked") }
        return addon.isInstalled ? "Uninstall" : "Install"
    }

    private var statusColor: Color {
        if addon.isLocked { return .white.opacity(0.32) }
        return addon.isInstalled ? .white.opacity(0.7) : accentColor
    }
}

private struct SettingsDetailHeader: View {
    let title: String
    let subtitle: String
    let iconName: String
    let accentColor: Color

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            Image(systemName: iconName)
                .font(.system(size: 36, weight: .semibold))
                .foregroundColor(accentColor)
                .frame(width: 70, height: 70)
                .settingsGlass(shape: Circle(), isProminent: true)
                .overlay(
                    Circle()
                        .strokeBorder(accentColor.opacity(0.55), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(subtitle)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(2)
            }

            Spacer()
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.white.opacity(0.56))
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                content
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsGlass(shape: RoundedRectangle(cornerRadius: 32, style: .continuous), isProminent: false)
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let accentColor: Color

    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            SettingsRowShell(isFocused: isFocused, accentColor: accentColor) {
                SettingsRowText(title: title, subtitle: subtitle)

                Spacer(minLength: 24)

                HStack(spacing: 10) {
                    Text(isOn ? L10n.string("subtitle_on", fallback: "On") : L10n.string("playback_afr_off", fallback: "Off"))
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white.opacity(0.78))
                        .frame(width: 34, alignment: .trailing)

                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isOn ? accentColor : Color.white.opacity(0.24))
                        .frame(width: 54, height: 30)
                        .overlay(alignment: isOn ? .trailing : .leading) {
                            Circle()
                                .fill(isOn && accentColor == .white ? Color.black : Color.white)
                                .frame(width: 22, height: 22)
                                .padding(4)
                        }
                }
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .entryLockable()
    }
}

private struct SettingsOptionRow: View {
    let title: String
    let subtitle: String
    @Binding var selection: String
    let options: [String]
    let accentColor: Color

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: selectNext) {
            SettingsRowShell(isFocused: isFocused, accentColor: accentColor) {
                SettingsRowText(title: title, subtitle: subtitle)

                Spacer(minLength: 24)

                HStack(spacing: 10) {
                    Text(L10n.optionLabel(currentStored))
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(accentColor)
                }
                .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .entryLockable()
    }

    private var currentStored: String {
        options.contains(selection) ? selection : (options.first ?? selection)
    }

    private func selectNext() {
        guard !options.isEmpty else { return }
        let currentIndex = options.firstIndex(of: currentStored) ?? 0
        selection = options[(currentIndex + 1) % options.count]
    }
}

/// Like `SettingsOptionRow` but presents all options in a dropdown-style picker
/// (the app's confirmation-dialog pattern) instead of cycling one-by-one — nicer
/// when a list has several entries, e.g. Preferred Audio.
private struct SettingsChoiceRow: View {
    let title: String
    let subtitle: String
    @Binding var selection: String
    let options: [String]
    let accentColor: Color

    @FocusState private var isFocused: Bool
    @State private var showOptions = false

    var body: some View {
        Button { showOptions = true } label: {
            SettingsRowShell(isFocused: isFocused, accentColor: accentColor) {
                SettingsRowText(title: title, subtitle: subtitle)

                Spacer(minLength: 24)

                HStack(spacing: 10) {
                    Text(L10n.optionLabel(currentStored))
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(accentColor)
                }
                .frame(maxWidth: 260, alignment: .trailing)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .entryLockable()
        .confirmationDialog(title, isPresented: $showOptions, titleVisibility: .visible) {
            ForEach(options, id: \.self) { option in
                Button(L10n.optionLabel(option)) { selection = option }
            }
        }
    }

    private var currentStored: String {
        options.contains(selection) ? selection : (options.first ?? selection)
    }
}

private struct SettingsStepperRow: View {
    let title: String
    let subtitle: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let suffix: String
    let accentColor: Color

    @FocusState private var isFocused: Bool

    var body: some View {
        SettingsRowShell(isFocused: isFocused, accentColor: accentColor) {
            SettingsRowText(title: title, subtitle: subtitle)

            Spacer(minLength: 24)

            HStack(spacing: 12) {
                SettingsMiniButton(
                    systemName: "minus",
                    accentColor: accentColor,
                    isAtBound: value <= range.lowerBound
                ) {
                    value = max(range.lowerBound, value - step)
                }

                Text("\(value)\(suffix)")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 78)

                SettingsMiniButton(
                    systemName: "plus",
                    accentColor: accentColor,
                    isAtBound: value >= range.upperBound
                ) {
                    value = min(range.upperBound, value + step)
                }
            }
        }
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
    }
}

private struct SettingsTextFieldRow: View {
    let title: String
    let subtitle: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var fieldWidth: CGFloat = 300
    var onCommit: () -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var isEditing = false

    var body: some View {
        // The whole row is the focusable button (not just the right-hand capsule),
        // so it matches every other settings row: full-width and left-aligned. That
        // also fixes detail-pane entry — a right-press from the sidebar lands on this
        // first row instead of skipping past the narrow capsule to the next row down.
        Button {
            isEditing = true
        } label: {
            SettingsRowShell(isFocused: isFocused, accentColor: .white) {
                SettingsRowText(title: title, subtitle: subtitle)

                Spacer(minLength: 24)

                SettingsGlassTextField(
                    text: $text,
                    placeholder: placeholder,
                    isSecure: isSecure,
                    focused: isFocused,
                    isEditing: $isEditing,
                    fieldWidth: fieldWidth,
                    onCommit: onCommit
                )
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .entryLockable()
    }
}

/// Display half of the text-field row, styled to match the Search tab's glass
/// capsule. A hidden, off-screen UITextField drives editing (a native focused
/// TextField/SecureField on tvOS always paints its own white pill); the owning
/// row supplies focus and toggles `isEditing` when clicked.
private struct SettingsGlassTextField: View {
    @Binding var text: String
    let placeholder: String
    var isSecure: Bool = false
    var focused: Bool
    @Binding var isEditing: Bool
    var fieldWidth: CGFloat = 300
    var onCommit: () -> Void = {}

    var body: some View {
        ZStack(alignment: .leading) {
            HiddenSettingsTextField(
                text: $text,
                isEditing: $isEditing,
                isSecure: isSecure,
                onCommit: onCommit
            )
                .frame(width: 1, height: 1)
                .offset(x: -4_000)
                .allowsHitTesting(false)

            Text(displayText)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(text.isEmpty ? .white.opacity(0.45) : .white)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .allowsHitTesting(false)
        }
        .frame(width: fieldWidth, height: 48)
        .modifier(GlassCapsule(focused: focused || isEditing))
    }

    private var displayText: String {
        guard !text.isEmpty else { return placeholder }
        return isSecure ? String(repeating: "•", count: text.count) : text
    }
}

private struct HiddenSettingsTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    var isSecure: Bool = false
    var onCommit: () -> Void = {}

    func makeUIView(context: Context) -> HiddenSettingsUITextField {
        let textField = HiddenSettingsUITextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.backgroundColor = .clear
        textField.textColor = .clear
        textField.tintColor = .clear
        textField.returnKeyType = .done
        textField.keyboardAppearance = .dark
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.isSecureTextEntry = isSecure
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ uiView: HiddenSettingsUITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        if isEditing && !uiView.isFirstResponder {
            DispatchQueue.main.async {
                uiView.becomeFirstResponder()
            }
        } else if !isEditing && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isEditing: $isEditing, onCommit: onCommit)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let text: Binding<String>
        private let isEditing: Binding<Bool>
        private let onCommit: () -> Void

        init(text: Binding<String>, isEditing: Binding<Bool>, onCommit: @escaping () -> Void) {
            self.text = text
            self.isEditing = isEditing
            self.onCommit = onCommit
        }

        @objc func textDidChange(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            isEditing.wrappedValue = false
            textField.resignFirstResponder()
            onCommit()
            return true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            isEditing.wrappedValue = false
        }
    }
}

private final class HiddenSettingsUITextField: UITextField {
    override var canBecomeFocused: Bool { false }
}

private struct SettingsActionRow: View {
    let title: String
    let subtitle: String
    let value: String
    let accentColor: Color
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            SettingsRowShell(isFocused: isFocused, accentColor: accentColor) {
                SettingsRowText(title: title, subtitle: subtitle)

                Spacer(minLength: 24)

                Text(value)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundColor(accentColor)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(accentColor)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .entryLockable()
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            Text(title)
                .font(.system(size: 21, weight: .semibold))
                .foregroundColor(.white)

            Spacer(minLength: 24)

            Text(value)
                .font(.system(size: 21, weight: .bold))
                .foregroundColor(.white.opacity(0.62))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 64)
        .settingsGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous), isProminent: false)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

struct SettingsSwatch: Identifiable {
    let id: String
    let label: String
    let color: Color
}

private struct SettingsSwatchRow: View {
    let swatches: [SettingsSwatch]
    @Binding var selection: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: 14) {
            ForEach(swatches) { swatch in
                SettingsSwatchButton(
                    swatch: swatch,
                    isSelected: selection == swatch.id,
                    accentColor: accentColor
                ) {
                    selection = swatch.id
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsSwatchButton: View {
    let swatch: SettingsSwatch
    let isSelected: Bool
    let accentColor: Color
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Circle()
                    .fill(swatch.color)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                    )
                .overlay(
                    Circle()
                        .strokeBorder(ringColor, lineWidth: isFocused ? AppFocusOutline.width : (isSelected ? 4 : 0))
                        .padding(-4)
                )

                Text(swatch.label)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(isFocused || isSelected ? 1 : 0.65))
                    .lineLimit(1)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .entryLockable()
        .scaleEffect(isFocused ? 1.18 : 1.0)
        .zIndex(isFocused ? 1 : 0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
    }

    private var ringColor: Color {
        if isFocused { return AppFocusOutline.color }
        return isSelected ? accentColor : .clear
    }
}

private struct SettingsRowShell<Content: View>: View {
    let isFocused: Bool
    let accentColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 16) {
            content
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 74)
        .settingsGlass(shape: RoundedRectangle(cornerRadius: 24, style: .continuous), isProminent: false)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(isFocused ? AppFocusOutline.color : Color.white.opacity(0.10), lineWidth: isFocused ? AppFocusOutline.width : 1)
        )
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct SettingsRowText: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text(subtitle)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white.opacity(0.56))
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
    }
}

private struct SettingsMiniButton: View {
    let systemName: String
    let accentColor: Color
    /// Whether the stepper is at its min/max — drives the dimmed look. Kept
    /// separate from `.disabled` so the entry-lock can disable focus without
    /// also dimming the button while the sidebar is focused.
    var isAtBound: Bool = false
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(isAtBound ? .white.opacity(0.32) : .white)
                .frame(width: 44, height: 44)
                .settingsGlass(shape: Circle(), isProminent: isFocused)
                .overlay(
                    Circle()
                        .strokeBorder(isFocused ? AppFocusOutline.color : Color.white.opacity(0.12), lineWidth: isFocused ? AppFocusOutline.width : 1)
                )
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .disabled(isAtBound)
        .entryLockable()
    }
}

private extension View {
    @ViewBuilder
    func settingsGlass<S: InsettableShape>(shape: S, isProminent: Bool) -> some View {
        if #available(tvOS 26.0, *) {
            self
                .background(isProminent ? Color.white.opacity(0.13) : Color.white.opacity(0.045), in: shape)
                .glassEffect(.regular, in: shape)
        } else {
            self.background(
                (isProminent ? Color.white.opacity(0.18) : Color.white.opacity(0.07)),
                in: shape
            )
        }
    }
}

/// Makes a sheet's system plate transparent so liquid-glass content can frost
/// over the presenter (Settings). No-op on older OS versions.
private struct ClearPresentationBackgroundIfAvailable: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(tvOS 16.4, *) {
            content.presentationBackground(.clear)
        } else {
            content
        }
    }
}

private struct SettingsSearchGlassBackground<S: InsettableShape>: ViewModifier {
    let filled: Bool
    let shape: S

    @ViewBuilder
    func body(content: Content) -> some View {
        if filled {
            content.background(Color.white, in: shape)
        } else if #available(tvOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

#if DEBUG
struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
#endif
