import SwiftUI
import UIKit

enum AppFocusOutline {
    static let color = Color.white
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

    var subtitle: String {
        switch self {
        case .account: return "Profile identity and local account preferences"
        case .appearance: return "Theme, language, and display comfort"
        case .layout: return "Home rows, discovery, posters, and metadata"
        case .integrations: return "Trakt, TMDB, MDBList, and debrid keys"
        case .playback: return "Player, subtitles, audio, trailers, and cache"
        case .subtitles: return "How subtitles look on every video you watch"
        case .advanced: return "Focus behavior, diagnostics, and reset tools"
        case .about: return "Version, engine, and open-source notices"
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
    /// JSON `[String]` of account catalog keys (`<addonId>_<type>_<catalogId>`)
    /// in the account's Home order. The repository orders the add-on catalog
    /// rows by this; kept separate from `homeCatalogOrder` (the local tvOS
    /// reorder) so a pull never disturbs the built-in rows or a local reorder.
    static let homeCatalogSyncedOrder = "nuvio.tv.settings.layout.homeCatalogSyncedOrder"
    static let heroEnabled = "nuvio.tv.settings.layout.heroEnabled"
    static let posterLabels = "nuvio.tv.settings.layout.posterLabels"
    static let catalogAddonNames = "nuvio.tv.settings.layout.catalogAddonNames"
    static let discoverLocation = "nuvio.tv.settings.layout.discoverLocation"
    static let continueWatchingSort = "nuvio.tv.settings.layout.continueWatchingSort"
    static let showUnairedNextUp = "nuvio.tv.settings.layout.showUnairedNextUp"
    static let hideUnreleased = "nuvio.tv.settings.layout.hideUnreleased"
    static let showFullDates = "nuvio.tv.settings.layout.showFullDates"

    static let traktConnected = "nuvio.tv.settings.integrations.traktConnected"
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
    /// Android TV account screen, so Torbox and Premiumize can stay connected
    /// at the same time.
    static let torboxAccessToken = "nuvio.tv.settings.integrations.torboxAccessToken"
    static let premiumizeAccessToken = "nuvio.tv.settings.integrations.premiumizeAccessToken"
    static let streamAddonManifestURL = "nuvio.tv.settings.integrations.streamAddonManifestURL"
    static let streamAddonManifestURLs = "nuvio.tv.settings.integrations.streamAddonManifestURLs"
    static let streamAddonManifestStates = "nuvio.tv.settings.integrations.streamAddonManifestStates"

    static let playerEngine = "nuvio.tv.settings.playback.playerEngine"
    static let externalPlayer = "nuvio.tv.settings.playback.externalPlayer"
    static let smartStreamSelection = "nuvio.tv.settings.playback.smartStreamSelection"
    static let smartStreamQuality = "nuvio.tv.settings.playback.smartStreamQuality"
    static let smartSubtitleMatching = "nuvio.tv.settings.playback.smartSubtitleMatching"
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

    static let fastNavigation = "nuvio.tv.settings.advanced.fastNavigation"
    static let smoothFocus = "nuvio.tv.settings.advanced.smoothFocus"
    static let playbackDiagnostics = "nuvio.tv.settings.advanced.playbackDiagnostics"
    static let focusHighlighter = "nuvio.tv.settings.advanced.focusHighlighter"

    static let all = [
        profileName, profilePinEnabled, profileAutoSelectLast, accountSyncWatchState,
        theme, bodyColor, font, language, amoled, amoledSurfaces, reduceMotion,
        homeLayout, heroEnabled, posterLabels, catalogAddonNames, discoverLocation,
        continueWatchingSort, showUnairedNextUp, hideUnreleased, showFullDates,
        traktConnected, traktContinueWatchingDaysCap, traktShowMetaComments,
        traktWatchProgressSource, traktLibrarySourceMode, traktMoreLikeThisSource,
        tmdbEnabled, tmdbApiKey, mdbListEnabled, mdbListApiKey,
        debridProvider, debridApiKey, torboxAccessToken, premiumizeAccessToken,
        streamAddonManifestURL, streamAddonManifestURLs,
        streamAddonManifestStates,
        playerEngine, externalPlayer, smartStreamSelection, smartStreamQuality, smartSubtitleMatching,
        autoPlayNext, trailersEnabled, trailerDelay, audioLanguage,
        subtitleLanguages, subtitleLanguage, subtitleLanguageSecondary, subtitleLanguageTertiary,
        forcedSubtitles, subtitleSize, frameRateMatching, networkCache, playbackTrackSelections,
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

        let appLanguage = defaults.string(forKey: SettingsKey.language) ?? "System"
        if !disabledValues.contains(appLanguage), supportedLanguages.contains(appLanguage) {
            return appLanguage
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
        case .charcoal: return Color(red: 0.015, green: 0.015, blue: 0.018)
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
    case audio
    case subtitles
}

struct SettingsView: View {
    let activeProfile: Profile?
    let accountEmail: String?
    let isAuthenticated: Bool
    let onSignIn: (() -> Void)?
    let onSignOut: (() -> Void)?

    init(
        activeProfile: Profile? = nil,
        accountEmail: String? = nil,
        isAuthenticated: Bool = false,
        onSignIn: (() -> Void)? = nil,
        onSignOut: (() -> Void)? = nil
    ) {
        self.activeProfile = activeProfile
        self.accountEmail = accountEmail
        self.isAuthenticated = isAuthenticated
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
    @AppStorage(SettingsKey.audioLanguage) private var audioLanguage = "System"
    @AppStorage(SettingsKey.subtitleLanguages) private var subtitleLanguages = ""
    @AppStorage(SettingsKey.subtitleLanguage) private var subtitleLanguage = "System"
    @AppStorage(SettingsKey.subtitleLanguageSecondary) private var subtitleLanguageSecondary = "None"
    @AppStorage(SettingsKey.subtitleLanguageTertiary) private var subtitleLanguageTertiary = "None"

    private let pickerLanguages = SubtitleLanguagePreferences.settingsOptions

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
                    title: picker == .audio ? "Preferred Audio" : "Preferred Subtitle",
                    subtitle: picker == .audio
                        ? "Choose the default audio language."
                        : "Choose any languages in priority order. System shows every language in the player.",
                    systemImage: picker == .audio ? "speaker.wave.2.fill" : "captions.bubble.fill",
                    selection: picker == .audio ? audioLanguageSelection : subtitleLanguageSelection,
                    languages: pickerLanguages,
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

    private func dismissLanguagePicker(_ picker: LanguagePickerKind) {
        presentedLanguagePicker = nil
        DispatchQueue.main.async {
            focusedLanguagePreference = picker
        }
    }

    private var categoryGrid: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Settings")
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
            title: selectedCategory.rawValue,
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
                onSignIn: onSignIn,
                onSignOut: onSignOut
            )
        case .appearance:
            AppearanceSettingsView(accentColor: accentColor)
        case .layout:
            LayoutDiscoverySettingsView(accentColor: accentColor)
        case .integrations:
            IntegrationSettingsView(accentColor: accentColor)
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

                Text(category.rawValue)
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
    let onSignIn: (() -> Void)?
    let onSignOut: (() -> Void)?

    @AppStorage(SettingsKey.profileName) private var profileName = "Nuvio User"
    @AppStorage(SettingsKey.profilePinEnabled) private var pinEnabled = false
    @AppStorage(SettingsKey.profileAutoSelectLast) private var autoSelectLastProfile = true
    @AppStorage(SettingsKey.accountSyncWatchState) private var syncWatchState = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Profile", subtitle: "Local profile defaults for this Apple TV") {
                HStack(spacing: 22) {
                    Circle()
                        .fill(accentColor.opacity(0.86))
                        .frame(width: 84, height: 84)
                        .overlay(
                            Text(profileInitial)
                                .font(.system(size: 38, weight: .black))
                                .foregroundColor(accentColor == .white ? .black : .white)
                        )

                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayProfileName)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)

                        Text(pinEnabled ? "PIN protection enabled" : "PIN protection disabled")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(.white.opacity(0.58))
                    }

                    Spacer()
                }
                .padding(.bottom, 6)

                // First focusable row in the pane carries the entry anchor —
                // without one the entry lock leaves the pane unenterable.
                SettingsToggleRow(
                    title: "PIN Protection",
                    subtitle: "Require the profile PIN before opening protected profiles",
                    isOn: $pinEnabled,
                    accentColor: accentColor
                )
                .settingsEntryAnchor()

                SettingsToggleRow(
                    title: "Open Last Profile",
                    subtitle: "Resume with the most recently selected profile",
                    isOn: $autoSelectLastProfile,
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: "Nuvio Account", subtitle: "Connected account and sync controls") {
                SettingsInfoRow(title: "Status", value: isAuthenticated ? "Signed In" : "Not Signed In")

                if let accountEmail, !accountEmail.isEmpty {
                    SettingsInfoRow(title: "Email", value: accountEmail)
                }

                SettingsToggleRow(
                    title: "Sync Watched State",
                    subtitle: "Keep watched history, resume points, and library state eligible for sync",
                    isOn: $syncWatchState,
                    accentColor: accentColor
                )

                if isAuthenticated {
                    SettingsActionRow(
                        title: "Sign Out",
                        subtitle: "Remove this Nuvio account from this Apple TV",
                        value: "Disconnect",
                        accentColor: Color(red: 1.0, green: 0.43, blue: 0.43)
                    ) {
                        onSignOut?()
                    }
                    .opacity(onSignOut != nil ? 1 : 0.46)
                    .disabled(onSignOut == nil)
                } else {
                    SettingsActionRow(
                        title: "Sign In",
                        subtitle: "Connect a Nuvio account to sync profiles, add-ons, and progress",
                        value: "Connect",
                        accentColor: accentColor
                    ) {
                        onSignIn?()
                    }
                    .opacity(onSignIn != nil ? 1 : 0.46)
                    .disabled(onSignIn == nil)
                }
            }
        }
    }

    private var displayProfileName: String {
        guard isAuthenticated else { return "Nuvio Guest" }
        return ProfileDisplayName.resolve(profile: activeProfile, settingsName: profileName)
    }

    private var profileInitial: String {
        let trimmedName = displayProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmedName.first ?? "N")).uppercased()
    }
}

private struct AppearanceSettingsView: View {
    let accentColor: Color

    @AppStorage(SettingsKey.theme) private var theme = SettingsAccent.white.rawValue
    @AppStorage(SettingsKey.bodyColor) private var bodyColor = SettingsBackground.charcoal.rawValue
    @AppStorage(SettingsKey.font) private var font = "Inter"
    @AppStorage(SettingsKey.language) private var language = "System"
    @AppStorage(SettingsKey.amoled) private var amoled = false
    @AppStorage(SettingsKey.amoledSurfaces) private var amoledSurfaces = false
    @AppStorage(SettingsKey.reduceMotion) private var reduceMotion = false

    private let fonts = ["Inter", "System", "Rounded", "Serif"]
    private let languages = SubtitleLanguagePreferences.settingsOptions

    private var accentSwatches: [SettingsSwatch] {
        SettingsAccent.allCases.map { SettingsSwatch(id: $0.rawValue, label: $0.rawValue, color: $0.color) }
    }

    private var backgroundSwatches: [SettingsSwatch] {
        SettingsBackground.allCases.map { SettingsSwatch(id: $0.rawValue, label: $0.rawValue, color: $0.swatchColor) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Focus Outline", subtitle: "Accent color used for focused cards and controls") {
                SettingsSwatchRow(swatches: accentSwatches, selection: $theme, accentColor: accentColor)
                    .settingsEntryAnchor()
            }

            SettingsGroup(title: "App Background", subtitle: "Body background color behind every screen") {
                SettingsSwatchRow(swatches: backgroundSwatches, selection: $bodyColor, accentColor: accentColor)

                SettingsToggleRow(
                    title: "AMOLED Mode",
                    subtitle: "Force a pure black background, overriding the choice above",
                    isOn: $amoled,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: "AMOLED Surfaces",
                    subtitle: "Flatten card and row surfaces when AMOLED mode is enabled",
                    isOn: $amoledSurfaces,
                    accentColor: accentColor
                )
                .opacity(amoled ? 1 : 0.46)
                .disabled(!amoled)
            }

            SettingsGroup(title: "Text & Motion", subtitle: "Readable defaults for the TV room") {
                SettingsOptionRow(
                    title: "Font",
                    subtitle: "Preferred app typeface",
                    selection: $font,
                    options: fonts,
                    accentColor: accentColor
                )

                SettingsOptionRow(
                    title: "Language",
                    subtitle: "Interface language preference",
                    selection: $language,
                    options: languages,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: "Reduce Motion",
                    subtitle: "Use calmer focus transitions and page motion",
                    isOn: $reduceMotion,
                    accentColor: accentColor
                )
            }
        }
    }
}

private struct LayoutDiscoverySettingsView: View {
    let accentColor: Color

    @AppStorage(SettingsKey.homeLayout) private var homeLayout = "Modern"
    @AppStorage(SettingsKey.heroEnabled) private var heroEnabled = true
    @AppStorage(SettingsKey.posterLabels) private var posterLabels = false
    @AppStorage(SettingsKey.catalogAddonNames) private var catalogAddonNames = true
    @AppStorage(SettingsKey.discoverLocation) private var discoverLocation = "Search"
    @AppStorage(SettingsKey.continueWatchingSort) private var continueWatchingSort = "Default"
    @AppStorage(SettingsKey.showUnairedNextUp) private var showUnairedNextUp = true
    @AppStorage(SettingsKey.hideUnreleased) private var hideUnreleased = false
    @AppStorage(SettingsKey.showFullDates) private var showFullDates = true

    private let layouts = ["Modern", "Classic", "Compact"]
    private let discoverLocations = ["Search", "Home", "Library", "Off"]
    private let continueWatchingSorts = ["Default", "Recently watched", "Release order", "Next up"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Home Layout", subtitle: "How the home screen presents rows and artwork") {
                SettingsOptionRow(
                    title: "Layout",
                    subtitle: "Primary home browsing style",
                    selection: $homeLayout,
                    options: layouts,
                    accentColor: accentColor
                )
                .settingsEntryAnchor()

                SettingsToggleRow(
                    title: "Hero Section",
                    subtitle: "Show featured artwork above catalog rows",
                    isOn: $heroEnabled,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: "Poster Labels",
                    subtitle: "Show titles below poster cards",
                    isOn: $posterLabels,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: "Catalog Add-on Names",
                    subtitle: "Show source add-on names beside catalog titles",
                    isOn: $catalogAddonNames,
                    accentColor: accentColor
                )
            }

            HomeCatalogOrderSection(accentColor: accentColor)

            CollectionsSettingsSection(accentColor: accentColor)

            SettingsGroup(title: "Discovery", subtitle: "Visibility rules for discovery and continue watching") {
                SettingsOptionRow(
                    title: "Discover Entry",
                    subtitle: "Where the discover surface appears",
                    selection: $discoverLocation,
                    options: discoverLocations,
                    accentColor: accentColor
                )

                SettingsOptionRow(
                    title: "Continue Watching",
                    subtitle: "Default order for resume rows",
                    selection: $continueWatchingSort,
                    options: continueWatchingSorts,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: "Show Unaired Next Up",
                    subtitle: "Keep upcoming episodes in Continue Watching with their air date",
                    isOn: $showUnairedNextUp,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: "Hide Unreleased Content",
                    subtitle: "Filter titles before their known release date",
                    isOn: $hideUnreleased,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: "Show Full Release Dates",
                    subtitle: "Prefer exact dates when metadata provides them",
                    isOn: $showFullDates,
                    accentColor: accentColor
                )
            }
        }
    }
}

private struct IntegrationSettingsView: View {
    let accentColor: Color

    @StateObject private var traktViewModel = TraktSettingsViewModel()
    @AppStorage(SettingsKey.tmdbEnabled) private var tmdbEnabled = false
    @AppStorage(SettingsKey.tmdbApiKey) private var tmdbApiKey = ""
    @AppStorage(SettingsKey.mdbListEnabled) private var mdbListEnabled = false
    @AppStorage(SettingsKey.mdbListApiKey) private var mdbListApiKey = ""
    @AppStorage(SettingsKey.debridProvider) private var debridProvider = "None"
    @AppStorage(SettingsKey.debridApiKey) private var debridApiKey = ""
    @AppStorage(SettingsKey.torboxAccessToken) private var torboxAccessToken = ""
    @AppStorage(SettingsKey.premiumizeAccessToken) private var premiumizeAccessToken = ""
    @State private var debridAccountToConnect: DebridAccountProvider?
    @StateObject private var debridConnection = DebridAccountConnectionViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            AddonsSettingsSection(accentColor: accentColor)

            SettingsGroup(title: "Trakt", subtitle: "Watchlist, progress, history, comments, and recommendations") {
                TraktConnectionSettingsCard(viewModel: traktViewModel, accentColor: accentColor)
            }

            SettingsGroup(title: "Metadata Providers", subtitle: "Optional API keys for richer metadata and rating badges") {
                SettingsToggleRow(
                    title: "TMDB Metadata",
                    subtitle: "Enable custom TMDB metadata enrichment",
                    isOn: $tmdbEnabled,
                    accentColor: accentColor
                )

                SettingsTextFieldRow(
                    title: "TMDB API Key",
                    subtitle: "Stored locally on this Apple TV",
                    placeholder: "Not set",
                    text: $tmdbApiKey,
                    isSecure: true
                )

                SettingsToggleRow(
                    title: "MDBList Ratings",
                    subtitle: "Show ratings from IMDb, TMDB, Rotten Tomatoes, and Metacritic",
                    isOn: $mdbListEnabled,
                    accentColor: accentColor
                )

                SettingsTextFieldRow(
                    title: "MDBList API Key",
                    subtitle: "Stored locally on this Apple TV",
                    placeholder: "Not set",
                    text: $mdbListApiKey,
                    isSecure: true
                )
            }

            SettingsGroup(title: "Accounts", subtitle: "Link a debrid account from your phone or browser") {
                SettingsActionRow(
                    title: "Torbox",
                    subtitle: "Link your Torbox account in the browser.",
                    value: isConnected(.torbox) ? "Connected" : "Not set",
                    accentColor: accentColor
                ) {
                    debridAccountToConnect = .torbox
                }

                SettingsActionRow(
                    title: "Premiumize",
                    subtitle: "Link your Premiumize account in the browser.",
                    value: isConnected(.premiumize) ? "Connected" : "Not set",
                    accentColor: accentColor
                ) {
                    debridAccountToConnect = .premiumize
                }
            }
        }
        .onAppear { traktViewModel.reload() }
        .task { traktViewModel.fetchAccountConnection(auto: true) }
        .sheet(item: $debridAccountToConnect) { provider in
            DebridDeviceAuthorizationSheet(
                provider: provider,
                isConnected: isConnected(provider),
                viewModel: debridConnection
            )
        }
    }

    private func isConnected(_ provider: DebridAccountProvider) -> Bool {
        switch provider {
        case .torbox:
            if !torboxAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        case .premiumize:
            if !premiumizeAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        }
        return debridProvider == provider.debridKind.rawValue &&
            !debridApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Matches Android TV's debrid account dialog: start the provider device flow,
/// render its QR, show the short code, then persist the returned access token.
private struct DebridDeviceAuthorizationSheet: View {
    let provider: DebridAccountProvider
    let isConnected: Bool
    @ObservedObject var viewModel: DebridAccountConnectionViewModel

    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 28) {
            Text(isConnected ? "\(provider.displayName) Connected" : "Connect \(provider.displayName)")
                .font(.system(size: 42, weight: .regular))
                .foregroundColor(.white)

            if isConnected {
                Text("This Apple TV is linked to your \(provider.displayName) account.")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundColor(.white.opacity(0.66))
                    .multilineTextAlignment(.center)

                HStack(spacing: 18) {
                    dialogButton(title: "Cancel", isPrimary: false) { dismiss() }
                    dialogButton(title: "Disconnect", isPrimary: true) {
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
                Text("Scan the QR and enter this code to approve Nuvio.")
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
                dialogButton(title: "Cancel", isPrimary: true) { dismiss() }
            } else {
                Text(viewModel.statusMessage ?? "Unable to start account linking.")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(Color(red: 1.0, green: 0.43, blue: 0.43))
                    .multilineTextAlignment(.center)
                HStack(spacing: 18) {
                    dialogButton(title: "Cancel", isPrimary: false) { dismiss() }
                    dialogButton(title: "Retry", isPrimary: true) { viewModel.connect(provider) }
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
            Text(viewModel.statusMessage ?? "Waiting for approval…")
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

    private var activationURL: String {
        if let code = viewModel.deviceUserCode, !code.isEmpty {
            return "https://trakt.tv/activate/\(code)"
        }
        return viewModel.verificationURL ?? "https://trakt.tv/activate"
    }

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
            case .disconnected:
                disconnectedBody
            case .awaitingApproval:
                awaitingApprovalBody
            case .connected:
                connectedBody
            }

            if let message = viewModel.statusMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white.opacity(0.62))
            }

            if let error = viewModel.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Color(red: 1.0, green: 0.43, blue: 0.43))
            }
        }
    }

    private var disconnectedBody: some View {
        VStack(spacing: 12) {
            SettingsActionRow(
                title: "Fetch Trakt Connection",
                subtitle: viewModel.credentialsConfigured
                    ? "Check your Nuvio account for an existing Trakt login"
                    : "Nuvio Trakt proxy is not configured",
                value: viewModel.isLoading ? "Checking..." : "Fetch",
                accentColor: accentColor
            ) {
                viewModel.fetchAccountConnection()
            }

            SettingsActionRow(
                title: "Start Trakt Login",
                subtitle: "Use a Trakt activation code on this Apple TV",
                value: viewModel.isLoading ? "Starting..." : "Connect",
                accentColor: accentColor
            ) {
                viewModel.connect()
            }
        }
    }

    private var awaitingApprovalBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Go to trakt.tv/activate and enter:")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))

                    Text(viewModel.deviceUserCode ?? "-")
                        .font(.system(size: 42, weight: .black))
                        .tracking(4)
                        .foregroundColor(accentColor)

                    Text(activationURL)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white.opacity(0.54))
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                if let image = QRCode.image(from: activationURL, scale: 8) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 144, height: 144)
                        .padding(10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }

            HStack(spacing: 12) {
                SettingsActionRow(
                    title: "Retry Polling",
                    subtitle: "Ask Trakt again after approving the code",
                    value: viewModel.isPolling ? "Waiting" : "Retry",
                    accentColor: accentColor
                ) {
                    viewModel.retryPolling()
                }

                SettingsActionRow(
                    title: "Cancel",
                    subtitle: "Clear this device-code login attempt",
                    value: "Cancel",
                    accentColor: accentColor
                ) {
                    viewModel.cancelDeviceFlow()
                }
            }
        }
    }

    private var connectedBody: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                SettingsInfoRow(title: "Movies", value: statValue(viewModel.connectedStats?.moviesWatched))
                SettingsInfoRow(title: "Shows", value: statValue(viewModel.connectedStats?.showsWatched))
            }

            HStack(spacing: 12) {
                SettingsInfoRow(title: "Episodes", value: statValue(viewModel.connectedStats?.episodesWatched))
                SettingsInfoRow(title: "Hours", value: viewModel.connectedStats?.totalWatchedHours.map { "\($0)h" } ?? "-")
            }

            SettingsActionRow(
                title: "Sync Now",
                subtitle: "Refresh Trakt user info and cached stats",
                value: viewModel.isLoading ? "Syncing" : "Refresh",
                accentColor: accentColor
            ) {
                viewModel.refreshNow()
            }

            SettingsActionRow(
                title: "Library Source",
                subtitle: "Choose where saved library items should come from",
                value: viewModel.librarySourceMode.label,
                accentColor: accentColor
            ) {
                viewModel.cycleLibrarySource()
            }

            SettingsActionRow(
                title: "Watch Progress",
                subtitle: "Choose the source for Resume and Continue Watching",
                value: viewModel.watchProgressSource.label,
                accentColor: accentColor
            ) {
                viewModel.cycleWatchProgressSource()
            }

            SettingsActionRow(
                title: "Continue Watching Window",
                subtitle: "Trakt history considered for Continue Watching",
                value: continueWatchingLabel,
                accentColor: accentColor
            ) {
                viewModel.cycleContinueWatchingDaysCap()
            }

            SettingsActionRow(
                title: "Comments",
                subtitle: "Show Trakt reviews on metadata screens",
                value: viewModel.showMetaComments ? "On" : "Off",
                accentColor: accentColor
            ) {
                viewModel.toggleComments()
            }

            SettingsActionRow(
                title: "More Like This",
                subtitle: "Recommendation source for related titles",
                value: viewModel.moreLikeThisSource.label,
                accentColor: accentColor
            ) {
                viewModel.cycleMoreLikeThisSource()
            }

            SettingsActionRow(
                title: "Disconnect",
                subtitle: "Remove this profile's Trakt tokens from this Apple TV",
                value: "Disconnect",
                accentColor: accentColor
            ) {
                viewModel.disconnect()
            }
        }
    }

    private var statusTitle: String {
        switch viewModel.mode {
        case .disconnected: return "Not connected"
        case .awaitingApproval: return "Waiting for approval"
        case .connected:
            return "Connected as \(viewModel.username?.isEmpty == false ? viewModel.username! : "Trakt User")"
        }
    }

    private var statusSubtitle: String {
        switch viewModel.mode {
        case .disconnected:
            return "Connect Trakt to enable account-level watchlist, progress, comments, and recommendations."
        case .awaitingApproval:
            return "Approve this Apple TV in Trakt, then Nuvio will save the token for the active profile."
        case .connected:
            return "This profile can use Trakt-backed sync and metadata settings."
        }
    }

    private var continueWatchingLabel: String {
        viewModel.continueWatchingDaysCap == TraktDefaults.continueWatchingDaysCapAll
            ? "All history"
            : "\(viewModel.continueWatchingDaysCap) days"
    }

    private func statValue(_ value: Int?) -> String {
        value.map(String.init) ?? (viewModel.isStatsLoading ? "..." : "-")
    }
}

private struct PlaybackSettingsView: View {
    let accentColor: Color
    let languageFocus: FocusState<LanguagePickerKind?>.Binding
    let onAudioLanguage: () -> Void
    let onSubtitleLanguages: () -> Void

    @AppStorage(SettingsKey.playerEngine) private var playerEngine = "Auto"
    @AppStorage(SettingsKey.externalPlayer) private var externalPlayer = ExternalPlayer.builtIn.rawValue
    @AppStorage(SettingsKey.smartStreamSelection) private var smartStreamSelection = false
    @AppStorage(SettingsKey.smartStreamQuality) private var smartStreamQuality = "Highest"
    @AppStorage(SettingsKey.smartSubtitleMatching) private var smartSubtitleMatching = true
    @AppStorage(SettingsKey.autoPlayNext) private var autoPlayNext = true
    @AppStorage(SettingsKey.trailersEnabled) private var trailersEnabled = true
    @AppStorage(SettingsKey.trailerDelay) private var trailerDelay = 7
    @AppStorage(SettingsKey.audioLanguage) private var audioLanguage = "System"
    @AppStorage(SettingsKey.subtitleLanguages) private var subtitleLanguages = ""
    @AppStorage(SettingsKey.subtitleLanguage) private var subtitleLanguage = "System"
    @AppStorage(SettingsKey.subtitleLanguageSecondary) private var subtitleLanguageSecondary = "None"
    @AppStorage(SettingsKey.subtitleLanguageTertiary) private var subtitleLanguageTertiary = "None"
    @AppStorage(SettingsKey.forcedSubtitles) private var forcedSubtitles = true
    @AppStorage(SettingsKey.frameRateMatching) private var frameRateMatching = "Off"
    @AppStorage(SettingsKey.networkCache) private var networkCache = "Auto"

    private let engines = ["Auto", "AVPlayer", "MPVKit"]
    private let externalPlayers = ExternalPlayer.settingsOptions
    private let streamQualities = ["Highest", "4K", "1080p", "720p", "Smallest"]
    private let frameRateModes = ["Off", "On start/stop", "Always"]
    private let cacheModes = ["Auto", "Small", "Medium", "Large"]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Player", subtitle: "Playback engine and episode flow") {
                SettingsOptionRow(
                    title: "Player Engine",
                    subtitle: "Preferred internal playback path",
                    selection: $playerEngine,
                    options: engines,
                    accentColor: accentColor
                )
                .settingsEntryAnchor()

                SettingsOptionRow(
                    title: "External Player",
                    subtitle: "Hand streams to another installed app (Infuse, VLC, Outplayer)",
                    selection: $externalPlayer,
                    options: externalPlayers,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: "Auto-Play Next Episode",
                    subtitle: "Play the next episode automatically with a 10-second countdown. Off keeps the Next Episode card with a manual Play.",
                    isOn: $autoPlayNext,
                    accentColor: accentColor
                )

                SettingsOptionRow(
                    title: "Frame Rate Matching",
                    subtitle: "Match display refresh to video where supported",
                    selection: $frameRateMatching,
                    options: frameRateModes,
                    accentColor: accentColor
                )

                SettingsOptionRow(
                    title: "Network Cache",
                    subtitle: "Preload buffer size — Auto scales to device RAM, Large forces 1 GB",
                    selection: $networkCache,
                    options: cacheModes,
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: "Smart Playback", subtitle: "Automatically choose streams and matching subtitles") {
                SettingsToggleRow(
                    title: "Auto Select Stream",
                    subtitle: "Skip the stream picker and choose the best matching link",
                    isOn: $smartStreamSelection,
                    accentColor: accentColor
                )

                SettingsOptionRow(
                    title: "Stream Quality",
                    subtitle: "Quality target used when selecting a link",
                    selection: $smartStreamQuality,
                    options: streamQualities,
                    accentColor: accentColor
                )
                .opacity(smartStreamSelection ? 1 : 0.46)
                .disabled(!smartStreamSelection)

                SettingsToggleRow(
                    title: "Match Subtitle Language",
                    subtitle: "Prefer links and tracks matching Preferred Subtitle",
                    isOn: $smartSubtitleMatching,
                    accentColor: accentColor
                )
                .opacity(smartStreamSelection ? 1 : 0.46)
                .disabled(!smartStreamSelection)
            }

            SettingsGroup(title: "Audio & Subtitles", subtitle: "Language and subtitle rendering defaults") {
                SettingsActionRow(
                    title: "Preferred Audio",
                    subtitle: "Default audio language",
                    value: audioLanguageSummary,
                    accentColor: accentColor
                ) {
                    onAudioLanguage()
                }
                .focused(languageFocus, equals: .audio)

                SettingsActionRow(
                    title: "Preferred Subtitle",
                    subtitle: "Choose any number of languages in priority order",
                    value: subtitleLanguageSummary,
                    accentColor: accentColor
                ) {
                    onSubtitleLanguages()
                }
                .focused(languageFocus, equals: .subtitles)

                SettingsToggleRow(
                    title: "Forced Subtitles",
                    subtitle: "Use forced subtitles when a matching track exists",
                    isOn: $forcedSubtitles,
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: "Trailers", subtitle: "Preview playback on details and focused posters") {
                SettingsToggleRow(
                    title: "Autoplay Trailers",
                    subtitle: "Start previews after focus settles",
                    isOn: $trailersEnabled,
                    accentColor: accentColor
                )

                SettingsStepperRow(
                    title: "Trailer Delay",
                    subtitle: "Seconds before autoplay starts",
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
        guard !ordered.isEmpty else { return "System" }
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
            SettingsGroup(title: "Text", subtitle: "Size, weight, spacing, color, and opacity of the caption text") {
                SettingsStepperRow(
                    title: "Text Size",
                    subtitle: "Relative subtitle text size",
                    value: $textSize,
                    range: 60...220,
                    step: 5,
                    suffix: "%",
                    accentColor: accentColor
                )
                .settingsEntryAnchor()

                SettingsToggleRow(
                    title: "Bold",
                    subtitle: "Use a heavier caption weight",
                    isOn: $bold,
                    accentColor: accentColor
                )

                SettingsStepperRow(
                    title: "Letter Spacing",
                    subtitle: "Squeeze the text together or open it up",
                    value: $letterSpacing,
                    range: -8...40,
                    step: 2,
                    suffix: "",
                    accentColor: accentColor
                )

                SubtitleColorRow(
                    title: "Text Color",
                    subtitle: "Caption fill color",
                    selection: $textColor,
                    accentColor: accentColor
                )

                SettingsStepperRow(
                    title: "Text Opacity",
                    subtitle: "Caption transparency",
                    value: $textOpacity,
                    range: 20...100,
                    step: 5,
                    suffix: "%",
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: "Position", subtitle: "Where captions sit on screen") {
                SettingsStepperRow(
                    title: "Vertical Position",
                    subtitle: "Raise captions up off the bottom edge",
                    value: $bottomOffset,
                    range: 0...160,
                    step: 4,
                    suffix: "",
                    accentColor: accentColor
                )

                SettingsStepperRow(
                    title: "Horizontal Margin",
                    subtitle: "Inset captions in from the left and right edges",
                    value: $horizontalMargin,
                    range: 0...200,
                    step: 5,
                    suffix: "",
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: "Outline", subtitle: "Border drawn around the text for readability") {
                SettingsToggleRow(
                    title: "Outline",
                    subtitle: "Draw a border around the text for readability",
                    isOn: $outlineEnabled,
                    accentColor: accentColor
                )

                SubtitleColorRow(
                    title: "Outline Color",
                    subtitle: "Border color drawn around the text",
                    selection: $outlineColor,
                    accentColor: accentColor
                )
                .opacity(outlineEnabled ? 1 : 0.46)
                .disabled(!outlineEnabled)
            }

            SettingsGroup(title: "Reset", subtitle: "Restore the default subtitle appearance") {
                SettingsActionRow(
                    title: "Reset Defaults",
                    subtitle: "Clears every value on this screen",
                    value: "Reset",
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
            Text("PREVIEW")
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
                            Text("Done")
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
            SettingsGroup(title: "Navigation", subtitle: "Remote focus behavior for dense rows") {
                SettingsToggleRow(
                    title: "Fast Horizontal Navigation",
                    subtitle: "Move through long poster rows more aggressively",
                    isOn: $fastNavigation,
                    accentColor: accentColor
                )
                .settingsEntryAnchor()

                SettingsToggleRow(
                    title: "Smooth Bring Into View",
                    subtitle: "Animate focused content into a readable position",
                    isOn: $smoothFocus,
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: "Diagnostics", subtitle: "Local tools for debugging playback and focus") {
                SettingsToggleRow(
                    title: "Playback Issue Reports",
                    subtitle: "Keep diagnostic snapshots after failed playback attempts",
                    isOn: $playbackDiagnostics,
                    accentColor: accentColor
                )

                SettingsToggleRow(
                    title: "Focus Highlighter",
                    subtitle: "Draw extra focus outlines for layout debugging",
                    isOn: $focusHighlighter,
                    accentColor: accentColor
                )
            }

            SettingsGroup(title: "Reset", subtitle: "Clear local tvOS settings saved by this screen") {
                SettingsActionRow(
                    title: "Reset Settings",
                    subtitle: "Restore the core settings defaults",
                    value: "Reset",
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

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "NuvioTV", subtitle: "Build and runtime information") {
                SettingsInfoRow(title: "App Version", value: appVersion)
                SettingsInfoRow(title: "Engine Core", value: "NuvioCore-FFI v0.4.8")
                SettingsInfoRow(title: "Playback Stack", value: "AVKit / MPVKit")
                SettingsInfoRow(title: "Catalog Protocol", value: "Stremio compatible")
            }

            SettingsGroup(title: "Open Source", subtitle: "Project components used by this tvOS app") {
                Text("This software uses SwiftUI, AVKit, MPVKit wrappers, the Nuvio Rust SDK surface, and Stremio-compatible catalog APIs.")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)

                SettingsActionRow(
                    title: "Licenses & Attributions",
                    subtitle: "Bundled attribution view is not connected in this prototype",
                    value: "Local",
                    accentColor: accentColor,
                    action: {}
                )
                .settingsEntryAnchor()
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

// MARK: - Addons (moved here from the former Addons tab)

private struct AddonsSettingsSection: View {
    let accentColor: Color

    @AppStorage(SettingsKey.streamAddonManifestURL) private var streamAddonManifestURL = ""
    @AppStorage(SettingsKey.streamAddonManifestURLs) private var streamAddonManifestURLs = ""
    @AppStorage(SettingsKey.streamAddonManifestStates) private var streamAddonManifestStates = ""
    @State private var addons: [AddonItem] = AddonItem.defaults
    @State private var syncedAddons: [SyncedAddon] = []

    var body: some View {
        SettingsGroup(title: "Add-ons", subtitle: "Stremio-compatible catalog and stream sources") {
            SettingsTextFieldRow(
                title: "Stream Add-on URL",
                subtitle: "Paste your configured Stremio manifest link",
                placeholder: "https://.../manifest.json",
                text: $streamAddonManifestURL,
                fieldWidth: 560
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
                        Text("Synced")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(accentColor)
                    }
                    Text(addon.subtitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(addon.isEnabled ? 0.56 : 0.36))
                        .lineLimit(2)
                }

                Spacer(minLength: 20)

                Text(addon.isEnabled ? "Active" : "Disabled")
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
        SettingsGroup(title: "Home Catalogs", subtitle: "Controls catalog and collection row order on Home") {
            if rows.isEmpty {
                SettingsInfoRow(title: "No rows recorded yet", value: "Open Home once")
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

/// Settings → Layout → Collections: view, create, pin, and delete the
/// account's collections and attach add-on catalogs to them. Edits mutate the
/// raw synced JSON (so Android-only fields survive) and push to the account.
private struct CollectionsSettingsSection: View {
    let accentColor: Color

    @State private var collections: [[String: Any]] = []
    @State private var showingCreate = false
    @State private var pickerTarget: CollectionPickerTarget?

    var body: some View {
        SettingsGroup(title: "Collections", subtitle: "Group catalogs into folders on your home screen") {
            ForEach(Array(collections.enumerated()), id: \.offset) { index, collection in
                CollectionSettingsRow(
                    name: (collection["title"] as? String) ?? "Untitled",
                    detail: detailText(for: collection),
                    isPinned: (collection["pinToTop"] as? Bool) ?? false,
                    accentColor: accentColor,
                    onAddCatalog: { pickerTarget = CollectionPickerTarget(index: index) },
                    onTogglePin: { togglePin(index) },
                    onDelete: { remove(index) }
                )
            }

            CreateCollectionRow(accentColor: accentColor) {
                showingCreate = true
            }
        }
        .onAppear { collections = CollectionsStore.rawCollections() }
        .onReceive(NotificationCenter.default.publisher(for: CollectionsStore.changedNotification)) { _ in
            collections = CollectionsStore.rawCollections()
        }
        .sheet(isPresented: $showingCreate) {
            CreateCollectionSheet { name in
                create(named: name)
            }
        }
        .sheet(item: $pickerTarget) { target in
            CollectionCatalogPickerSheet(
                collectionName: (collections[safe: target.index]?["title"] as? String) ?? "",
                selectedIds: selectedSourceIds(at: target.index),
                onToggle: { option in toggleSource(option, at: target.index) }
            )
        }
    }

    private func detailText(for collection: [String: Any]) -> String {
        let folders = (collection["folders"] as? [[String: Any]]) ?? []
        let sourceCount = folders.reduce(0) { $0 + ((($1["sources"] as? [[String: Any]])?.count) ?? 0) }
        let folderText = "\(folders.count) folder\(folders.count == 1 ? "" : "s")"
        return "\(folderText) • \(sourceCount) catalog\(sourceCount == 1 ? "" : "s")"
    }

    private func create(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        collections.append([
            "id": UUID().uuidString,
            "title": trimmed,
            "pinToTop": false,
            "viewMode": "TABBED_GRID",
            "showAllTab": true,
            "folders": [[
                "id": UUID().uuidString,
                "title": trimmed,
                "tileShape": "SQUARE",
                "hideTitle": false,
                "sources": [[String: Any]]()
            ]]
        ])
        CollectionsStore.saveLocalEdit(collections)
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

    /// Sources already attached anywhere in the collection, as option ids.
    private func selectedSourceIds(at index: Int) -> Set<String> {
        guard let folders = collections[safe: index]?["folders"] as? [[String: Any]] else { return [] }
        var ids = Set<String>()
        for folder in folders {
            for source in (folder["sources"] as? [[String: Any]]) ?? [] {
                if let addonId = source["addonId"] as? String,
                   let type = source["type"] as? String,
                   let catalogId = source["catalogId"] as? String {
                    ids.insert("\(addonId)_\(type)_\(catalogId)")
                }
            }
        }
        return ids
    }

    /// Adds/removes the catalog in the collection's first folder (created on
    /// demand), leaving every other field of the JSON untouched.
    private func toggleSource(_ option: AddonCatalogOption, at index: Int) {
        guard collections.indices.contains(index) else { return }
        var folders = (collections[index]["folders"] as? [[String: Any]]) ?? []
        if folders.isEmpty {
            folders = [[
                "id": UUID().uuidString,
                "title": (collections[index]["title"] as? String) ?? "Folder",
                "tileShape": "SQUARE",
                "hideTitle": false,
                "sources": [[String: Any]]()
            ]]
        }

        let matches: ([String: Any]) -> Bool = { source in
            source["addonId"] as? String == option.addonId
                && source["type"] as? String == option.type
                && source["catalogId"] as? String == option.catalogId
        }

        if selectedSourceIds(at: index).contains(option.id) {
            for folderIndex in folders.indices {
                var sources = (folders[folderIndex]["sources"] as? [[String: Any]]) ?? []
                sources.removeAll(where: matches)
                folders[folderIndex]["sources"] = sources
            }
        } else {
            var sources = (folders[0]["sources"] as? [[String: Any]]) ?? []
            sources.append([
                "provider": "addon",
                "addonId": option.addonId,
                "type": option.type,
                "catalogId": option.catalogId
            ])
            folders[0]["sources"] = sources
        }

        collections[index]["folders"] = folders
        CollectionsStore.saveLocalEdit(collections)
    }
}

private struct CollectionPickerTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct CollectionSettingsRow: View {
    let name: String
    let detail: String
    let isPinned: Bool
    let accentColor: Color
    let onAddCatalog: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onAddCatalog) {
                SettingsRowShell(isFocused: isFocused, accentColor: accentColor) {
                    Image(systemName: "folder")
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
                                Text("PINNED")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(accentColor)
                            }
                        }
                        Text("\(detail) — click to add catalogs")
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

private struct CreateCollectionRow: View {
    let accentColor: Color
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            SettingsRowShell(isFocused: isFocused, accentColor: accentColor) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 24))
                    .foregroundColor(accentColor)
                    .frame(width: 48, height: 48)

                Text("New Collection")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)

                Spacer(minLength: 20)
            }
        }
        .buttonStyle(PosterCardButtonStyle())
        .focused($isFocused)
        .focusEffectDisabledIfAvailable()
        .entryLockable()
    }
}

private struct CreateCollectionSheet: View {
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(spacing: 28) {
            Text("New Collection")
                .font(.system(size: 38, weight: .bold))
                .foregroundColor(.white)

            TextField("Collection name", text: $name)
                .frame(maxWidth: 700)

            HStack(spacing: 20) {
                Button("Create") {
                    onCreate(name)
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Cancel") { dismiss() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
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
        VStack(spacing: 24) {
            Text("Add Catalogs to \(collectionName)")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)

            if isLoading {
                ProgressView().tint(.white)
                    .frame(maxHeight: .infinity)
            } else if options.isEmpty {
                Text("No add-on catalogs available. Install add-ons with catalogs first.")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(options) { option in
                            Button {
                                if localSelected.contains(option.id) {
                                    localSelected.remove(option.id)
                                } else {
                                    localSelected.insert(option.id)
                                }
                                onToggle(option)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: localSelected.contains(option.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 24))
                                        .foregroundColor(localSelected.contains(option.id) ? .green : .white.opacity(0.4))
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
                                .padding(.vertical, 14)
                            }
                        }
                    }
                    .padding(.horizontal, 80)
                }
            }

            Button("Done") { dismiss() }
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
        .task {
            localSelected = selectedIds
            options = await CinemetaCatalogRepository().availableAddonCatalogs()
            isLoading = false
        }
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
                            Text("Official")
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
        if addon.isLocked { return "Locked" }
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
                    Text(isOn ? "On" : "Off")
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
                    Text(currentValue)
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

    private var currentValue: String {
        options.contains(selection) ? selection : (options.first ?? selection)
    }

    private func selectNext() {
        guard !options.isEmpty else { return }
        let currentIndex = options.firstIndex(of: currentValue) ?? 0
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
                    Text(currentValue)
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
                Button(option) { selection = option }
            }
        }
    }

    private var currentValue: String {
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
                    fieldWidth: fieldWidth
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

    var body: some View {
        ZStack(alignment: .leading) {
            HiddenSettingsTextField(text: $text, isEditing: $isEditing, isSecure: isSecure)
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
        Coordinator(text: $text, isEditing: $isEditing)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let text: Binding<String>
        private let isEditing: Binding<Bool>

        init(text: Binding<String>, isEditing: Binding<Bool>) {
            self.text = text
            self.isEditing = isEditing
        }

        @objc func textDidChange(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            isEditing.wrappedValue = false
            textField.resignFirstResponder()
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
