import Foundation

extension SettingsKey {
    static let aniListEnabled = "nuvio.tv.settings.integrations.aniListEnabled"
    static let aniListTitleLanguage = "nuvio.tv.settings.integrations.aniListTitleLanguage"
    static let aniListSeasonMode = "nuvio.tv.settings.integrations.aniListSeasonMode"
    static let aniListHomeRows = "nuvio.tv.settings.integrations.aniListHomeRows"
    static let aniListSearch = "nuvio.tv.settings.integrations.aniListSearch"
    static let aniListHideCinemetaDuplicates = "nuvio.tv.settings.integrations.aniListHideCinemetaDuplicates"
    static let aniListEpisodeDetails = "nuvio.tv.settings.integrations.aniListEpisodeDetails"
    static let aniListAdult = "nuvio.tv.settings.integrations.aniListAdult"
    static let aniListClientID = "nuvio.tv.settings.integrations.aniListClientID"
    static let aniListScrobble = "nuvio.tv.settings.integrations.aniListScrobble"
    static let aniListScrobbleCinemeta = "nuvio.tv.settings.integrations.aniListScrobbleCinemeta"
    static let aniListListRows = "nuvio.tv.settings.integrations.aniListListRows"
    static let aniListOtherAddons = "nuvio.tv.settings.integrations.aniListOtherAddons"
}

/// Settings → Integrations → AniList. Anime from AniList keep their `anilist:` ids everywhere,
/// so add-ons that declare the `anilist` prefix are asked with `anilist:ID` (a film) or
/// `anilist:ID:EP` (an episode, numbered as on AniList).
enum AniListSettings {
    enum TitleLanguage: String, CaseIterable {
        case romaji
        case english
        case native

        var label: String {
            switch self {
            case .romaji: return "Romaji"
            case .english: return "English"
            case .native: return "Native"
            }
        }
    }

    /// How the seasons of a series show: all of them as one title with a tab per AniList
    /// entry, or every AniList entry as a title of its own, as on AniList.
    enum SeasonMode: String, CaseIterable {
        case merged
        case separate

        var label: String {
            switch self {
            case .merged: return "One Title"
            case .separate: return "Each Entry"
            }
        }
    }

    static func isEnabled(in store: UserDefaults = ProfileSettings.current) -> Bool {
        store.bool(forKey: SettingsKey.aniListEnabled)
    }

    static var isEnabled: Bool { isEnabled(in: ProfileSettings.current) }

    static var titleLanguage: TitleLanguage {
        TitleLanguage(rawValue: ProfileSettings.current.string(forKey: SettingsKey.aniListTitleLanguage) ?? "") ?? .romaji
    }

    static var seasonMode: SeasonMode {
        SeasonMode(rawValue: ProfileSettings.current.string(forKey: SettingsKey.aniListSeasonMode) ?? "") ?? .merged
    }

    /// Whether Home has any row of AniList's or MyAnimeList's (both come under AniList's add-on
    /// id): AniList Catalogs, MAL Catalogs.
    static func showsHomeRows(in store: UserDefaults = ProfileSettings.current) -> Bool {
        (isEnabled(in: store) && !AniListCatalogs.chosen(in: store).isEmpty)
            || (MALSettings.isEnabled(in: store) && !MALCatalogs.chosen(in: store).isEmpty)
    }

    /// Whether a row under AniList's add-on id belongs on Home and in Layout: chosen in AniList
    /// Catalogs or MAL Catalogs (lists only when logged in). Rows remembered from before the
    /// catalog windows, or switched off since, stay out; their place in the order is kept.
    static func showsHomeRow(catalogId: String?, in store: UserDefaults = ProfileSettings.current) -> Bool {
        guard let catalogId, !catalogId.isEmpty else { return showsHomeRows(in: store) }
        if catalogId.hasPrefix(MALCatalogs.idPrefix) {
            guard MALSettings.isEnabled(in: store), MALCatalogs.chosen(in: store).contains(where: { $0.id == catalogId }) else { return false }
            return !MALCatalogs.isList(catalogId) || MALAccount.isLoggedIn
        }
        guard isEnabled(in: store), AniListCatalogs.chosen(in: store).contains(where: { $0.id == catalogId }) else { return false }
        return !catalogId.hasPrefix("list-") || AniListAccount.isLoggedIn
    }

    /// The catalog id of a Home row under AniList's add-on id, from the row or its id.
    static func homeCatalogID(rowID: String, catalogId: String?) -> String? {
        if let catalogId, !catalogId.isEmpty { return catalogId }
        let prefix = "addon_\(AniListService.addonID)_\(AniListService.homeContentType)_"
        return rowID.hasPrefix(prefix) ? String(rowID.dropFirst(prefix.count)) : nil
    }

    /// AniList's average score beside the others, for anime from Cinemeta too. Works with AniList
    /// off; never switched, it follows AniList being on.
    static var showsScore: Bool {
        let store = ProfileSettings.current
        return store.object(forKey: SettingsKey.aniListScore) == nil ? isEnabled(in: store) : store.bool(forKey: SettingsKey.aniListScore)
    }

    /// The offline tables are needed: for AniList's or MAL's titles, or only for their scores.
    static var needsOfflineTables: Bool {
        opensTitles || showsScore || MALSettings.usesOwnScore || MALSettings.showsEpisodeRatings
    }

    /// AniList titles open, play and convert their ids: with AniList on, or MyAnimeList on (its
    /// titles open as the AniList titles they map to).
    static var opensTitles: Bool { isEnabled || MALSettings.isEnabled }

    static var showsHomeRows: Bool { showsHomeRows(in: ProfileSettings.current) }

    static var searchesAniList: Bool {
        isEnabled && bool(SettingsKey.aniListSearch, default: true)
    }

    static var hidesCinemetaDuplicates: Bool {
        searchesAniList && bool(SettingsKey.aniListHideCinemetaDuplicates, default: false)
    }

    static var usesEpisodeDetails: Bool {
        bool(SettingsKey.aniListEpisodeDetails, default: true)
    }

    /// What "+" in details writes to the viewer's AniList list.
    enum PlusStatus: String, CaseIterable {
        case planning = "PLANNING"
        case watching = "CURRENT"
        case off

        var label: String {
            switch self {
            case .planning: return "Planning"
            case .watching: return "Watching"
            case .off: return "Nothing"
            }
        }
    }

    static var plusStatus: PlusStatus {
        PlusStatus(rawValue: ProfileSettings.current.string(forKey: SettingsKey.aniListPlusStatus) ?? "") ?? .planning
    }

    /// The AniList button in details (status, score, favourite), when logged in.
    static var showsDetailsButton: Bool {
        AniListAccount.isLoggedIn && bool(SettingsKey.aniListDetailsButton, default: true)
    }

    static var showsAdult: Bool {
        bool(SettingsKey.aniListAdult, default: false)
    }

    /// The Client ID of the viewer's AniList API client, which AniList asks for when they log in.
    static var clientID: String {
        (ProfileSettings.current.string(forKey: SettingsKey.aniListClientID) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Write how far the viewer watched an AniList title to their AniList list.
    static var scrobbles: Bool {
        AniListAccount.isLoggedIn && bool(SettingsKey.aniListScrobble, default: true)
    }

    /// Also for anime from Cinemeta, found on AniList by their TMDB/IMDb id and air dates.
    static var scrobblesCinemeta: Bool {
        scrobbles && bool(SettingsKey.aniListScrobbleCinemeta, default: true)
    }

    /// Ask add-ons that don't take anilist: ids by the title's Kitsu or IMDb id.
    static var asksOtherAddons: Bool {
        bool(SettingsKey.aniListOtherAddons, default: true)
    }

    /// The viewer's lists (Watching, Planning, Paused) as Home rows.
    static var showsListRows: Bool {
        AniListAccount.isLoggedIn && AniListCatalogs.hasLists()
    }

    /// What Home and Search read from these settings. It is part of their source signatures, so
    /// turning AniList on or changing what it shows reloads Home and drops cached search results.
    static var sourceSignature: String {
        guard isEnabled || MALSettings.isEnabled else { return "anilist:off" }
        return [
            isEnabled ? "anilist:on" : "anilist:mal-only",
            MALSettings.isEnabled ? "mal:\(MALCatalogs.signature())" : "mal:off",
            "catalogs:\(AnimeCatalogSelection.signature(AniListCatalogs.chosen()))",
            showsHomeRows ? "rows" : "norows",
            searchesAniList ? "search" : "nosearch",
            hidesCinemetaDuplicates ? "dedupe" : "all",
            titleLanguage.rawValue,
            showsAdult ? "adult" : "safe",
            showsListRows ? "lists:\(AniListAccount.login?.viewerID ?? 0)" : "nolists",
        ].joined(separator: ",")
    }

    /// Asks Home to load its rows again after a change that adds or removes AniList rows.
    static func notifyHomeChanged() {
        NotificationCenter.default.post(name: TVHomeCatalogOrder.changedNotification, object: nil)
        NotificationCenter.default.post(name: TVHomeCatalogOrder.snapshotChangedNotification, object: nil)
    }

    private static func bool(_ key: String, default value: Bool, in store: UserDefaults = ProfileSettings.current) -> Bool {
        store.object(forKey: key) == nil ? value : store.bool(forKey: key)
    }
}
