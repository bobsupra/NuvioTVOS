import Foundation

enum IPTVChannelFilter {
    private static let sportsEventTokens: Set<String> = [
        "nfl", "mlb", "nhl", "nba", "wnba", "nascar", "ufc", "pga", "lpga",
        "fifa", "uefa", "f1", "formula1",
        "wimbledon", "olympics", "olympic", "ncaa",
        "mls", "xfl", "boxing", "mma", "hockey", "pwhl", "tennis", "golf", "rugby", "cricket"
    ]
    private static let excludedSportsListingTokens: Set<String> = [
        "studio", "news", "highlights", "highlight", "recap", "replay", "rerun",
        "classic", "review", "analysis", "preview", "talk", "documentary", "network"
    ]

    /// Classifies scheduled programme titles only; this does not independently verify a live feed.
    static func isSportsEventTitle(_ title: String) -> Bool {
        let tokens = title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty,
              excludedSportsListingTokens.isDisjoint(with: tokens) else { return false }

        let titleWords = tokens.joined(separator: " ")
        let studioTitles = ["nfl live", "mlb tonight", "nascar race hub"]
        guard !studioTitles.contains(where: { titleWords.contains($0) }) else { return false }

        if !sportsEventTokens.isDisjoint(with: tokens) { return true }

        if titleWords.contains("premier league") || titleWords.contains("champions league")
            || titleWords.contains("formula 1") {
            return true
        }

        // Generic team matchups are recognizable when a known team name is paired with a matchup marker.
        let matchupMarkers: Set<String> = ["vs", "v", "at"]
        let hasKnownTeam = !Set(["seahawks", "mariners", "kraken", "sounders"]).isDisjoint(with: tokens)
            || titleWords.contains("seattle storm")
        return hasKnownTeam
            && !matchupMarkers.isDisjoint(with: tokens)
    }

    static func matches(name: String, group: String?, query: String, selectedGroup: String?, currentProgrammeTitle: String? = nil) -> Bool {
        if let selectedGroup, group != selectedGroup { return false }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || name.localizedStandardContains(term) || (currentProgrammeTitle?.localizedStandardContains(term) ?? false)
    }

    static func groups(in channels: [IPTVChannel]) -> [String] {
        Set(channels.compactMap(\.group)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

struct IPTVCategoryPreferences: Codable {
    var order: [String] = []
    var hiddenGroupIDs: Set<String> = []
    var customNames: [String: String] = [:]

    static let empty = IPTVCategoryPreferences()
}

/// Category labels and visibility are local settings, namespaced by the
/// profile's defaults store and the source's stable UUID.
enum IPTVCategoryPreferencesStore {
    private static let keyPrefix = "iptv.categoryPreferences.v1."

    static func load(defaults: UserDefaults, sourceID: UUID) -> IPTVCategoryPreferences {
        guard let data = defaults.data(forKey: key(for: sourceID)),
              let preferences = try? JSONDecoder().decode(IPTVCategoryPreferences.self, from: data) else {
            return .empty
        }
        return preferences
    }

    static func orderedGroups(
        _ groupIDs: [String],
        preferences: IPTVCategoryPreferences,
        includingHidden: Bool = false
    ) -> [String] {
        let available = Set(groupIDs.filter { $0 != "Alle" })
        var ordered: [String] = []
        for groupID in preferences.order where available.contains(groupID) && !ordered.contains(groupID) {
            ordered.append(groupID)
        }
        ordered.append(contentsOf: groupIDs
            .filter { $0 != "Alle" && !ordered.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        return includingHidden ? ordered : ordered.filter { !preferences.hiddenGroupIDs.contains($0) }
    }

    static func move(
        groupID: String,
        by offset: Int,
        among groupIDs: [String],
        visibleGroupIDs: [String]? = nil,
        defaults: UserDefaults,
        sourceID: UUID
    ) {
        var preferences = load(defaults: defaults, sourceID: sourceID)
        let available = Set(groupIDs.filter { $0 != "Alle" })
        var ordered: [String] = []
        for existingID in preferences.order where !ordered.contains(existingID) {
            ordered.append(existingID)
        }
        ordered.append(contentsOf: orderedGroups(groupIDs, preferences: preferences, includingHidden: true)
            .filter { !ordered.contains($0) })

        let displayed = Set(visibleGroupIDs ?? groupIDs)
        let movementOrder = ordered.filter { available.contains($0) && displayed.contains($0) }
        guard let index = movementOrder.firstIndex(of: groupID) else { return }
        let destination = index + offset
        guard movementOrder.indices.contains(destination),
              let sourceIndex = ordered.firstIndex(of: groupID),
              let destinationIndex = ordered.firstIndex(of: movementOrder[destination]) else { return }
        ordered.swapAt(sourceIndex, destinationIndex)
        preferences.order = ordered
        save(preferences, defaults: defaults, sourceID: sourceID)
    }

    static func setHidden(
        _ hidden: Bool,
        for groupID: String,
        defaults: UserDefaults,
        sourceID: UUID
    ) {
        var preferences = load(defaults: defaults, sourceID: sourceID)
        if hidden {
            preferences.hiddenGroupIDs.insert(groupID)
        } else {
            preferences.hiddenGroupIDs.remove(groupID)
        }
        save(preferences, defaults: defaults, sourceID: sourceID)
    }

    @discardableResult
    static func rename(
        _ name: String,
        for groupID: String,
        defaults: UserDefaults,
        sourceID: UUID
    ) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        var preferences = load(defaults: defaults, sourceID: sourceID)
        if name == groupID {
            preferences.customNames.removeValue(forKey: groupID)
        } else {
            preferences.customNames[groupID] = name
        }
        save(preferences, defaults: defaults, sourceID: sourceID)
        return true
    }

    static func remove(sourceID: UUID, defaults: UserDefaults) {
        defaults.removeObject(forKey: key(for: sourceID))
    }

    static func removeAll(defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(keyPrefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func save(_ preferences: IPTVCategoryPreferences, defaults: UserDefaults, sourceID: UUID) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key(for: sourceID))
    }

    private static func key(for sourceID: UUID) -> String {
        keyPrefix + sourceID.uuidString
    }
}
