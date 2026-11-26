import Foundation

enum PlayerContentWarningCategory: String, CaseIterable, Sendable {
    case nudity = "SEXUAL_CONTENT"
    case violence = "VIOLENCE"
    case profanity = "PROFANITY"
    case alcohol = "ALCOHOL_DRUGS"
    case frightening = "FRIGHTENING_INTENSE_SCENES"

    var localizationKey: String {
        switch self {
        case .nudity: return "parental_nudity"
        case .violence: return "parental_violence"
        case .profanity: return "parental_profanity"
        case .alcohol: return "parental_alcohol"
        case .frightening: return "parental_frightening"
        }
    }

    var fallbackLabel: String {
        switch self {
        case .nudity: return "Nudity"
        case .violence: return "Violence"
        case .profanity: return "Profanity"
        case .alcohol: return "Alcohol/Drugs"
        case .frightening: return "Frightening"
        }
    }

    var order: Int {
        switch self {
        case .nudity: return 0
        case .violence: return 1
        case .profanity: return 2
        case .alcohol: return 3
        case .frightening: return 4
        }
    }
}

enum PlayerContentWarningSeverity: String, Equatable, Sendable {
    case severe
    case moderate
    case mild

    init?(rawSeverity: String) {
        self.init(rawValue: rawSeverity.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var localizationKey: String {
        switch self {
        case .severe: return "parental_severity_severe"
        case .moderate: return "parental_severity_moderate"
        case .mild: return "parental_severity_mild"
        }
    }

    var fallbackLabel: String {
        switch self {
        case .severe: return "Severe"
        case .moderate: return "Moderate"
        case .mild: return "Mild"
        }
    }
}

struct PlayerContentWarning: Identifiable, Equatable, Sendable {
    let category: PlayerContentWarningCategory
    let severity: String

    var id: String { category.rawValue }

    var severityLevel: PlayerContentWarningSeverity? {
        PlayerContentWarningSeverity(rawSeverity: severity)
    }

    var severityLocalizationKey: String? {
        severityLevel?.localizationKey
    }

    var localizedCategoryLabel: String {
        L10n.string(category.localizationKey, fallback: category.fallbackLabel)
    }

    var localizedSeverityLabel: String {
        if let level = severityLevel {
            return L10n.string(level.localizationKey, fallback: level.fallbackLabel)
        }
        return severity.capitalized
    }
}

enum DetailsParentalGuideSettings {
    static func isEnabled(in settings: UserDefaults = ProfileSettings.current) -> Bool {
        settings.bool(forKey: SettingsKey.detailsShowParentalGuide)
    }
}

actor ContentWarningsRepository {
    static let shared = ContentWarningsRepository()

    private var cache: [String: [PlayerContentWarning]] = [:]

    func warnings(for meta: NuvioMeta) async -> [PlayerContentWarning] {
        var triedIMDbIDs = Set<String>()

        for imdbID in Self.directIMDbIDs(for: meta) {
            guard !Task.isCancelled else { return [] }
            guard triedIMDbIDs.insert(imdbID).inserted else { continue }
            let found = await warnings(for: imdbID)
            guard !Task.isCancelled else { return [] }
            if !found.isEmpty { return found }
        }

        if let animeIMDbID = await Self.animeMappedIMDbID(for: meta),
           triedIMDbIDs.insert(animeIMDbID).inserted {
            guard !Task.isCancelled else { return [] }
            let found = await warnings(for: animeIMDbID)
            guard !Task.isCancelled else { return [] }
            if !found.isEmpty { return found }
        }

        if let apiKey = TmdbDetailsService.currentApiKey {
            let client = CalendarTmdb.Client(apiKey: apiKey)
            let isSeries = meta.isSeries || NuvioMeta.isSeriesType(meta.type)
            for tmdbID in Self.tmdbIDs(for: meta) {
                guard !Task.isCancelled else { return [] }
                do {
                    let resolved = try await client.imdbId(
                        tmdbId: tmdbID,
                        kind: isSeries ? .series : .movie
                    )
                    guard !Task.isCancelled else { return [] }
                    guard let resolved,
                          let imdbID = Self.normalizedIMDbID(resolved),
                          triedIMDbIDs.insert(imdbID).inserted else {
                        continue
                    }
                    let found = await warnings(for: imdbID)
                    guard !Task.isCancelled else { return [] }
                    if !found.isEmpty { return found }
                } catch {
                    guard !Task.isCancelled else { return [] }
                }
            }
        }

        return []
    }

    func warnings(for imdbID: String) async -> [PlayerContentWarning] {
        guard let normalizedID = Self.normalizedIMDbID(imdbID) else { return [] }
        if let cached = cache[normalizedID] { return cached }
        guard !Task.isCancelled else { return [] }

        var request = URLRequest(url: URL(string: "https://api.tiffara.com/titles/\(normalizedID)/parentsGuide")!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return [] }
            guard let response = response as? HTTPURLResponse else { return [] }
            if response.statusCode == 404 || response.statusCode == 410 {
                cache[normalizedID] = []
                return []
            }
            guard (200..<300).contains(response.statusCode) else { return [] }
            let result = try Self.decodeWarnings(from: data)
            guard !Task.isCancelled else { return [] }
            cache[normalizedID] = result
            return result
        } catch {
            return []
        }
    }

    static func decodeWarnings(from data: Data) throws -> [PlayerContentWarning] {
        let decoded = try JSONDecoder().decode(ParentsGuideResponse.self, from: data)
        return map(decoded.parentsGuide)
    }

    static func directIMDbIDs(for meta: NuvioMeta) -> [String] {
        var seen = Set<String>()
        return [meta.imdbId.flatMap(normalizedIMDbID), normalizedIMDbID(meta.id)]
            .compactMap { $0 }
            .filter { seen.insert($0).inserted }
    }

    static func tmdbIDs(for meta: NuvioMeta) -> [Int] {
        var ids: [Int] = []
        if let tmdbId = meta.tmdbId, tmdbId > 0 {
            ids.append(tmdbId)
        }
        if let parsed = extractTMDBID(from: meta.id), !ids.contains(parsed) {
            ids.append(parsed)
        }
        return ids
    }

    private static func animeMappedIMDbID(for meta: NuvioMeta) async -> String? {
        if let aniListID = AniListMetaBuilder.aniListID(from: meta.id), aniListID > 0 {
            if let mapped = await AniListOfflineMaps.shared.imdb(aniListID: aniListID) {
                return normalizedIMDbID(mapped)
            }
        }
        if let malID = AnimeSource.malID(from: meta.id),
           let aniListID = await AniListOfflineMaps.shared.aniListID(mal: malID),
           let mapped = await AniListOfflineMaps.shared.imdb(aniListID: aniListID) {
            return normalizedIMDbID(mapped)
        }
        if let kitsuID = AnimeSource.kitsuID(from: meta.id),
           let aniListID = await AniListOfflineMaps.shared.aniListID(kitsu: kitsuID),
           let mapped = await AniListOfflineMaps.shared.imdb(aniListID: aniListID) {
            return normalizedIMDbID(mapped)
        }
        return nil
    }

    static func normalizedIMDbID(_ value: String) -> String? {
        guard let range = value.range(of: #"tt\d+"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return value[range].lowercased()
    }

    private static func extractTMDBID(from value: String) -> Int? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let tokens = normalized.split(whereSeparator: { $0 == ":" || $0 == "/" || $0 == "|" })
        guard let tmdbIndex = tokens.firstIndex(where: { $0.caseInsensitiveCompare("tmdb") == .orderedSame }),
              tokens.indices.contains(tmdbIndex + 1),
              let parsed = Int(tokens[tmdbIndex + 1]),
              parsed > 0 else {
            return nil
        }
        return parsed
    }

    private static func map(_ guide: [ParentsGuideCategory]) -> [PlayerContentWarning] {
        let byCategory = Dictionary(
            guide.compactMap { category -> (String, ParentsGuideCategory)? in
                guard let name = category.category?.uppercased() else { return nil }
                return (name, category)
            },
            uniquingKeysWith: { first, _ in first }
        )

        let warnings = PlayerContentWarningCategory.allCases.compactMap { category -> PlayerContentWarning? in
            guard let record = byCategory[category.rawValue],
                  let severity = dominantSeverity(in: record.severityBreakdowns) else {
                return nil
            }
            return PlayerContentWarning(category: category, severity: severity)
        }

        let severityOrder = ["severe": 0, "moderate": 1, "mild": 2]
        return warnings.sorted { lhs, rhs in
            let leftOrder = severityOrder[lhs.severity.lowercased()] ?? 3
            let rightOrder = severityOrder[rhs.severity.lowercased()] ?? 3
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            return lhs.category.order < rhs.category.order
        }.prefix(5).map { $0 }
    }

    private static func dominantSeverity(in breakdowns: [ParentsGuideSeverity]?) -> String? {
        guard let breakdowns else { return nil }
        let noneVotes = breakdowns.first(where: { $0.severityLevel?.lowercased() == "none" })?.voteCount ?? 0
        var dominant: (severity: String, votes: Int)?

        // Keep the first severity in IMDb's response when non-none vote totals tie.
        for breakdown in breakdowns {
            guard let severity = breakdown.severityLevel?.lowercased(),
                  !severity.isEmpty,
                  severity != "none" else { continue }
            let votes = breakdown.voteCount ?? 0
            if dominant == nil || votes > dominant!.votes {
                dominant = (severity, votes)
            }
        }

        guard let dominant, dominant.votes > noneVotes else { return nil }
        return dominant.severity
    }
}

private struct ParentsGuideResponse: Decodable {
    let parentsGuide: [ParentsGuideCategory]

    enum CodingKeys: String, CodingKey {
        case parentsGuide
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        parentsGuide = try container.decodeIfPresent([ParentsGuideCategory].self, forKey: .parentsGuide) ?? []
    }
}

private struct ParentsGuideCategory: Decodable {
    let category: String?
    let severityBreakdowns: [ParentsGuideSeverity]?
}

private struct ParentsGuideSeverity: Decodable {
    let severityLevel: String?
    let voteCount: Int?
}
