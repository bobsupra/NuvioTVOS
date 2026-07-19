//
//  AppLanguage.swift
//  NuvioTV
//
//  In-app language selection matching Android TV's supported locales.
//

import Combine
import Foundation
import SwiftUI

/// Languages available for the app UI, matching Android TV `locale_config` /
/// ThemeSettingsScreen (plus System default).
enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
    case system = ""
    case english = "en"
    case russian = "ru"
    case arabic = "ar"
    case bulgarian = "bg"
    case bosnian = "bs"
    case danish = "da"
    case german = "de"
    case greek = "el"
    case spanish = "es"
    case spanishLatinAmerica = "es-419"
    case hungarian = "hu"
    case french = "fr"
    case indonesian = "in"
    case italian = "it"
    case norwegian = "no"
    case polish = "pl"
    case portuguesePortugal = "pt-PT"
    case portugueseBrazil = "pt-BR"
    case turkish = "tr"
    case ukrainian = "uk"
    case czech = "cs"
    case slovak = "sk"
    case slovenian = "sl"
    case swedish = "sv"
    case tamil = "ta"
    case romanian = "ro"
    case japanese = "ja"
    case dutch = "nl"
    case vietnamese = "vi"
    case hindi = "hi"
    case lithuanian = "lt"
    case hebrew = "he"
    case chineseSimplified = "zh-CN"
    case chineseTraditional = "zh-TW"

    var id: String { rawValue.isEmpty ? "system" : rawValue }

    /// BCP-47 tag stored in settings, or empty string for system default.
    var tag: String { rawValue }

    /// Native endonym shown in the picker (e.g. "Deutsch", "日本語").
    var nativeDisplayName: String {
        if self == .system {
            return L10n.string("appearance_language_system", fallback: "System default")
        }
        let locale = Locale(identifier: tag)
        let name = locale.localizedString(forIdentifier: tag)
            ?? Locale(identifier: "en").localizedString(forIdentifier: tag)
            ?? tag
        guard let first = name.first else { return name }
        return String(first).uppercased() + name.dropFirst()
    }

    /// English name used by subtitle/audio preference matching.
    var audioLanguageName: String? {
        switch self {
        case .system: return nil
        case .english: return "English"
        case .russian: return "Russian"
        case .arabic: return "Arabic"
        case .bulgarian: return "Bulgarian"
        case .bosnian: return "Bosnian"
        case .danish: return "Danish"
        case .german: return "German"
        case .greek: return "Greek"
        case .spanish, .spanishLatinAmerica: return "Spanish"
        case .hungarian: return "Hungarian"
        case .french: return "French"
        case .indonesian: return "Indonesian"
        case .italian: return "Italian"
        case .norwegian: return "Norwegian"
        case .polish: return "Polish"
        case .portuguesePortugal, .portugueseBrazil: return "Portuguese"
        case .turkish: return "Turkish"
        case .ukrainian: return "Ukrainian"
        case .czech: return "Czech"
        case .slovak: return "Slovak"
        case .slovenian: return "Slovenian"
        case .swedish: return "Swedish"
        case .tamil: return "Tamil"
        case .romanian: return "Romanian"
        case .japanese: return "Japanese"
        case .dutch: return "Dutch"
        case .vietnamese: return "Vietnamese"
        case .hindi: return "Hindi"
        case .lithuanian: return "Lithuanian"
        case .hebrew: return "Hebrew"
        case .chineseSimplified, .chineseTraditional: return "Chinese"
        }
    }

    /// Foundation locale used for dates, numbers, and layout direction.
    var locale: Locale {
        if self == .system {
            return .autoupdatingCurrent
        }
        return Locale(identifier: tag)
    }

    static func fromStored(_ value: String?) -> AppLanguage {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw.caseInsensitiveCompare("System") == .orderedSame
            || raw.caseInsensitiveCompare("system") == .orderedSame
            || raw.caseInsensitiveCompare("device") == .orderedSame {
            return .system
        }
        // Legacy display-name values from the audio-fallback placeholder.
        if let byName = legacyDisplayNameMap[raw] {
            return byName
        }
        if let exact = AppLanguage(rawValue: raw) {
            return exact
        }
        // Tolerate underscore / case variants (pt_BR, ZH-cn, id for Indonesian).
        let normalized = raw.replacingOccurrences(of: "_", with: "-")
        if let exact = AppLanguage(rawValue: normalized) {
            return exact
        }
        if normalized.caseInsensitiveCompare("id") == .orderedSame {
            return .indonesian
        }
        if normalized.caseInsensitiveCompare("nb") == .orderedSame
            || normalized.caseInsensitiveCompare("nn") == .orderedSame {
            return .norwegian
        }
        if normalized.caseInsensitiveCompare("iw") == .orderedSame {
            return .hebrew
        }
        if let match = allCases.first(where: { $0.tag.caseInsensitiveCompare(normalized) == .orderedSame }) {
            return match
        }
        return .system
    }

    /// Languages offered in the picker (System first, then alphabetical by native name).
    static var pickerLanguages: [AppLanguage] {
        let rest = allCases
            .filter { $0 != .system }
            .sorted {
                $0.nativeDisplayName.localizedCaseInsensitiveCompare($1.nativeDisplayName) == .orderedAscending
            }
        return [.system] + rest
    }

    private static let legacyDisplayNameMap: [String: AppLanguage] = [
        "English": .english,
        "Arabic": .arabic,
        "Bulgarian": .bulgarian,
        "Chinese": .chineseSimplified,
        "Croatian": .system, // not in Android TV app set; fall back to system
        "Czech": .czech,
        "Danish": .danish,
        "Dutch": .dutch,
        "Finnish": .system,
        "French": .french,
        "German": .german,
        "Greek": .greek,
        "Hebrew": .hebrew,
        "Hindi": .hindi,
        "Hungarian": .hungarian,
        "Indonesian": .indonesian,
        "Italian": .italian,
        "Japanese": .japanese,
        "Korean": .system,
        "Norwegian": .norwegian,
        "Polish": .polish,
        "Portuguese": .portuguesePortugal,
        "Romanian": .romanian,
        "Russian": .russian,
        "Spanish": .spanish,
        "Swedish": .swedish,
        "Thai": .system,
        "Turkish": .turkish,
        "Ukrainian": .ukrainian,
        "Vietnamese": .vietnamese,
    ]
}

// MARK: - Locale manager

/// Loads, persists, and applies the selected app language.
final class AppLocaleManager: ObservableObject {
    static let shared = AppLocaleManager()

    static let storageKey = SettingsKey.language

    @Published private(set) var language: AppLanguage
    @Published private(set) var revision: UInt = 0

    private init() {
        // Prefer the active profile store (matches @AppStorage), then standard.
        let stored = ProfileSettings.current.string(forKey: Self.storageKey)
            ?? UserDefaults.standard.string(forKey: Self.storageKey)
        language = AppLanguage.fromStored(stored)
        applyToProcess(language, bumpRevision: false)
    }

    var locale: Locale { language.locale }

    var currentDisplayName: String { language.nativeDisplayName }

    /// Updates language from a stored tag (settings UI / profile switch).
    func applyStoredTag(_ raw: String?) {
        setLanguage(AppLanguage.fromStored(raw), persist: true)
    }

    func setLanguage(_ next: AppLanguage, persist: Bool = true) {
        let previous = language
        if persist {
            // Profile-scoped setting (synced) and a standard fallback for cold start.
            ProfileSettings.current.set(next.tag, forKey: Self.storageKey)
            UserDefaults.standard.set(next.tag, forKey: Self.storageKey)
        }
        language = next
        applyToProcess(next, bumpRevision: previous != next)
    }

    /// Re-read from the current profile store (call on profile switch).
    func reloadFromProfileStore() {
        let stored = ProfileSettings.current.string(forKey: Self.storageKey)
        setLanguage(AppLanguage.fromStored(stored), persist: false)
    }

    /// Call as early as possible at process start.
    static func bootstrap() {
        _ = shared
    }

    private func applyToProcess(_ language: AppLanguage, bumpRevision: Bool) {
        let defaults = UserDefaults.standard
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
            defaults.removeObject(forKey: "AppleLocale")
        } else {
            defaults.set([language.tag], forKey: "AppleLanguages")
            defaults.set(language.tag, forKey: "AppleLocale")
        }
        defaults.synchronize()
        L10n.reload(languageTag: language == .system ? nil : language.tag)
        if bumpRevision {
            revision &+= 1
        }
    }
}

// MARK: - L10n

/// Lightweight string table backed by `AppLanguageCatalog.json` (ported from Android).
enum L10n {
    private static var catalog: [String: [String: String]] = loadCatalog()
    private static var activeTag: String?
    private static var activeTable: [String: String] = [:]

    static func reload(languageTag: String?) {
        activeTag = languageTag
        let english = catalog["en"] ?? [:]
        let selected: [String: String]
        if let tag = languageTag, let table = catalog[tag] {
            selected = table
        } else if let preferred = Locale.preferredLanguages.first {
            // System: pick best matching catalog entry.
            let match = resolveCatalogTag(for: preferred)
            selected = catalog[match] ?? english
            activeTag = match
        } else {
            selected = english
            activeTag = "en"
        }
        // English underlay so partial locales (and tvOS-only keys) still resolve.
        var merged = english
        for (key, value) in selected where !value.isEmpty {
            merged[key] = value
        }
        activeTable = merged
    }

    static func string(_ key: String, fallback: String) -> String {
        if activeTable.isEmpty {
            reload(languageTag: AppLocaleManager.shared.language == .system
                ? nil
                : AppLocaleManager.shared.language.tag)
        }
        if let value = activeTable[key], !value.isEmpty {
            return value
        }
        return fallback
    }

    /// Formats Android-style templates (`%1$s`, `%d`) with the active locale.
    static func format(_ key: String, fallback: String, _ args: CVarArg...) -> String {
        var template = string(key, fallback: fallback)
        for index in 1...9 {
            template = template
                .replacingOccurrences(of: "%\(index)$s", with: "%@")
                .replacingOccurrences(of: "%\(index)$d", with: "%d")
                .replacingOccurrences(of: "%\(index)$f", with: "%f")
        }
        return String(format: template, locale: AppLocaleManager.shared.locale, arguments: args)
    }

    /// Localized *display* label for stored settings option values.
    /// Storage stays English (e.g. `"Modern"`) so preferences keep working.
    static func optionLabel(_ stored: String) -> String {
        switch stored {
        case "System":
            return string("tvos_common_system", fallback: "System")
        case "None":
            return string("action_none", fallback: "None")
        case "Off":
            return string("tvos_common_off", fallback: "Off")
        case "On":
            return string("tvos_common_on", fallback: "On")
        case "Auto":
            return string("tvos_settings_option_auto", fallback: "Auto")
        case "Modern":
            return string("tvos_settings_option_modern", fallback: "Modern")
        case "Compact":
            return string("tvos_settings_option_compact", fallback: "Compact")
        case "Search":
            return string("nav_search", fallback: "Search")
        case "Home":
            return string("nav_home", fallback: "Home")
        case "Library":
            return string("nav_library", fallback: "Library")
        case "Default":
            return string("tvos_settings_option_default", fallback: "Default")
        case "Recently watched":
            return string("tvos_settings_option_recently_watched", fallback: "Recently watched")
        case "Release order":
            return string("tvos_settings_option_release_order", fallback: "Release order")
        case "Next up":
            return string("tvos_settings_option_next_up", fallback: "Next up")
        case "Highest":
            return string("tvos_settings_option_highest", fallback: "Highest")
        case "Smallest":
            return string("tvos_settings_option_smallest", fallback: "Smallest")
        case "On start/stop":
            return string("tvos_settings_option_on_start_stop", fallback: "On start/stop")
        case "Always":
            return string("tvos_settings_option_always", fallback: "Always")
        case "Conservative":
            return string("tvos_settings_option_conservative", fallback: "Conservative")
        case "Medium":
            return string("tvos_settings_option_medium", fallback: "Medium")
        case "Large":
            return string("tvos_settings_option_large", fallback: "Large")
        case "Max":
            return string("tvos_settings_option_max", fallback: "Max")
        case "Strip":
            return string("tvos_settings_option_strip", fallback: "Strip")
        case "Scale":
            return string("tvos_settings_option_scale", fallback: "Scale")
        case "Force":
            return string("tvos_settings_option_force", fallback: "Force")
        case "Movie":
            return string("type_movie", fallback: "Movie")
        case "TV":
            return string("type_series", fallback: "TV")
        case "Built-in":
            return string("tvos_settings_option_built_in", fallback: "Built-in")
        default:
            return stored
        }
    }

    private static func resolveCatalogTag(for preferred: String) -> String {
        let preferred = preferred.replacingOccurrences(of: "_", with: "-")
        if catalog[preferred] != nil { return preferred }
        // Try language-region variants used by Android.
        let lower = preferred.lowercased()
        if lower.hasPrefix("zh-hant") || lower.hasPrefix("zh-tw") || lower == "zh-hk" {
            return "zh-TW"
        }
        if lower.hasPrefix("zh") {
            return "zh-CN"
        }
        if lower.hasPrefix("pt-br") || lower == "pt-br" {
            return "pt-BR"
        }
        if lower.hasPrefix("pt") {
            return "pt-PT"
        }
        if lower.hasPrefix("es-419") || lower.hasPrefix("es-mx") || lower.hasPrefix("es-ar")
            || lower.hasPrefix("es-co") || lower.hasPrefix("es-cl") {
            return "es-419"
        }
        if lower.hasPrefix("nb") || lower.hasPrefix("nn") || lower.hasPrefix("no") {
            return "no"
        }
        if lower.hasPrefix("id") || lower.hasPrefix("in") {
            return "in"
        }
        if lower.hasPrefix("he") || lower.hasPrefix("iw") {
            return "he"
        }
        let lang = String(preferred.split(separator: "-").first ?? Substring(preferred))
        if catalog[lang] != nil { return lang }
        // Indonesian stored as "in" in Android resources.
        if lang == "id", catalog["in"] != nil { return "in" }
        return "en"
    }

    private static func loadCatalog() -> [String: [String: String]] {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "AppLanguageCatalog", withExtension: "json"),
            Bundle.main.url(forResource: "AppLanguageCatalog", withExtension: "json", subdirectory: "Resources"),
        ]
        for url in candidates.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
                return decoded
            }
        }
        return [:]
    }
}

// MARK: - SwiftUI helpers

private struct AppLocaleKey: EnvironmentKey {
    static let defaultValue: Locale = AppLocaleManager.shared.locale
}

extension EnvironmentValues {
    var appLocale: Locale {
        get { self[AppLocaleKey.self] }
        set { self[AppLocaleKey.self] = newValue }
    }
}

extension View {
    /// Applies the selected app language locale and forces redraw on change.
    func appliesAppLocale() -> some View {
        modifier(AppLocaleViewModifier())
    }
}

private struct AppLocaleViewModifier: ViewModifier {
    @ObservedObject private var manager = AppLocaleManager.shared

    func body(content: Content) -> some View {
        content
            .environment(\.locale, manager.locale)
            .environment(\.layoutDirection, layoutDirection(for: manager.language))
            .environment(\.appLocale, manager.locale)
            .id(manager.revision)
    }

    private func layoutDirection(for language: AppLanguage) -> LayoutDirection {
        switch language {
        case .arabic, .hebrew:
            return .rightToLeft
        case .system:
            return Locale.characterDirection(forLanguage: Locale.preferredLanguages.first ?? "en") == .rightToLeft
                ? .rightToLeft
                : .leftToRight
        default:
            return .leftToRight
        }
    }
}
