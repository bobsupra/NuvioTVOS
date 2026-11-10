import Foundation

extension SettingsKey {
    static let malEnabled = "nuvio.tv.settings.integrations.malEnabled"
    static let malClientID = "nuvio.tv.settings.integrations.malClientID"
    static let malEpisodeRatings = "nuvio.tv.settings.integrations.malEpisodeRatings"
    static let malScrobble = "nuvio.tv.settings.integrations.malScrobble"
    static let malAdult = "nuvio.tv.settings.integrations.malAdult"
    static let malCatalogs = "nuvio.tv.settings.integrations.malCatalogs"
    static let aniListCatalogs = "nuvio.tv.settings.integrations.aniListCatalogs"
    static let malDetailsButton = "nuvio.tv.settings.integrations.malDetailsButton"
    static let aniListDetailsButton = "nuvio.tv.settings.integrations.aniListDetailsButton"
    static let malPlusStatus = "nuvio.tv.settings.integrations.malPlusStatus"
    static let malSeriesScore = "nuvio.tv.settings.integrations.malSeriesScore"
    static let aniListScore = "nuvio.tv.settings.integrations.aniListScore"
    static let aniListPlusStatus = "nuvio.tv.settings.integrations.aniListPlusStatus"
}

/// Settings → Integrations → Anime Integrations → MyAnimeList. MAL titles open as the AniList
/// titles they map to (offline tables), so details, episodes, streams and add-on ids work as for
/// AniList; catalogs and scores come from Tenrai, the viewer's lists from MAL's own API.
enum MALSettings {
    static func isEnabled(in store: UserDefaults = ProfileSettings.current) -> Bool {
        bool(SettingsKey.malEnabled, default: false, in: store)
    }

    static var isEnabled: Bool { isEnabled(in: ProfileSettings.current) }

    /// The Client ID of the viewer's own MAL API client (myanimelist.net/apiconfig, type "other").
    static var clientID: String {
        (ProfileSettings.current.string(forKey: SettingsKey.malClientID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Each anime episode's MAL score (1–5) on episode cards. Works with MyAnimeList off too.
    static var showsEpisodeRatings: Bool { followingMAL(SettingsKey.malEpisodeRatings) }

    /// The series' MAL score straight from MAL instead of MDBList's copy. Works with MyAnimeList
    /// off too.
    static var usesOwnScore: Bool { followingMAL(SettingsKey.malSeriesScore) }

    /// A score setting: as switched, or, never switched, as MyAnimeList is on.
    static func followingMAL(_ key: String, in store: UserDefaults = ProfileSettings.current) -> Bool {
        store.object(forKey: key) == nil ? isEnabled(in: store) : store.bool(forKey: key)
    }

    /// Watched episodes written to the viewer's MAL list.
    static var scrobbles: Bool {
        MALAccount.isLoggedIn && bool(SettingsKey.malScrobble, default: true)
    }

    static var showsAdult: Bool {
        bool(SettingsKey.malAdult, default: false)
    }

    /// What "+" in details writes to the viewer's MAL list.
    enum PlusStatus: String, CaseIterable {
        case planToWatch = "plan_to_watch"
        case watching
        case off

        var label: String {
            switch self {
            case .planToWatch: return "Plan to Watch"
            case .watching: return "Watching"
            case .off: return "Nothing"
            }
        }
    }

    static var plusStatus: PlusStatus {
        PlusStatus(rawValue: ProfileSettings.current.string(forKey: SettingsKey.malPlusStatus) ?? "") ?? .planToWatch
    }

    /// The MAL button in details (status, score, remove), when logged in.
    static var showsDetailsButton: Bool {
        MALAccount.isLoggedIn && bool(SettingsKey.malDetailsButton, default: true)
    }

    private static func bool(_ key: String, default value: Bool, in store: UserDefaults = ProfileSettings.current) -> Bool {
        store.object(forKey: key) == nil ? value : store.bool(forKey: key)
    }
}

// MARK: - Catalog choice (AniList Catalogs, MAL Catalogs)

/// One catalog the viewer can put on Home: its id says how it is asked for, its title is the row's.
struct AnimeCatalogChoice: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let title: String
}

/// A group of the catalog window ("Genres", "Studios"…). `more` opens a longer list loaded when
/// asked (every AniList tag, the viewer's custom lists).
struct AnimeCatalogSection: Identifiable, Sendable {
    let id: String
    let title: String
    var subtitle: String? = nil
    let choices: [AnimeCatalogChoice]
    var more: AnimeCatalogMore? = nil
}

struct AnimeCatalogMore: Sendable {
    let title: String
    let subtitle: String
    let load: @Sendable () async -> [AnimeCatalogSection]
}

/// The chosen catalogs, in the order they were switched on, kept per profile as JSON.
enum AnimeCatalogSelection {
    static func chosen(key: String, fallback: [AnimeCatalogChoice], in store: UserDefaults = ProfileSettings.current) -> [AnimeCatalogChoice] {
        guard let text = store.string(forKey: key) else { return fallback }
        return decode(text) ?? fallback
    }

    static func save(_ choices: [AnimeCatalogChoice], key: String, in store: UserDefaults = ProfileSettings.current) {
        store.set(encode(choices), forKey: key)
        AniListSettings.notifyHomeChanged()
    }

    static func toggled(_ choice: AnimeCatalogChoice, in choices: [AnimeCatalogChoice]) -> [AnimeCatalogChoice] {
        if choices.contains(where: { $0.id == choice.id }) {
            return choices.filter { $0.id != choice.id }
        }
        return choices + [choice]
    }

    static func encode(_ choices: [AnimeCatalogChoice]) -> String {
        (try? JSONEncoder().encode(choices)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// A short stable fingerprint of a choice (Home's source signature).
    static func signature(_ choices: [AnimeCatalogChoice]) -> String {
        var hash: UInt64 = 5381
        for byte in choices.map(\.id).joined(separator: ",").utf8 {
            hash = (hash &<< 5) &+ hash &+ UInt64(byte)
        }
        return "\(choices.count)-" + String(hash, radix: 36)
    }

    static func decode(_ text: String) -> [AnimeCatalogChoice]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([AnimeCatalogChoice].self, from: data)
    }
}
