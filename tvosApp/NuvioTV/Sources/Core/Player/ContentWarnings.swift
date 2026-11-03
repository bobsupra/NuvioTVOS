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

struct PlayerContentWarning: Identifiable, Equatable, Sendable {
    let category: PlayerContentWarningCategory
    let severity: String

    var id: String { category.rawValue }

    var severityLocalizationKey: String? {
        switch severity.lowercased() {
        case "severe": return "parental_severity_severe"
        case "moderate": return "parental_severity_moderate"
        case "mild": return "parental_severity_mild"
        default: return nil
        }
    }
}

actor ContentWarningsRepository {
    static let shared = ContentWarningsRepository()

    private var cache: [String: [PlayerContentWarning]] = [:]

    func warnings(for imdbID: String) async -> [PlayerContentWarning] {
        guard let normalizedID = Self.normalizedIMDbID(imdbID) else { return [] }
        if let cached = cache[normalizedID] { return cached }
        guard !Task.isCancelled else { return [] }

        var request = URLRequest(url: URL(string: "https://api.imdbapi.dev/titles/\(normalizedID)/parentsGuide")!)
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
            let decoded = try JSONDecoder().decode(ParentsGuideResponse.self, from: data)
            let result = Self.map(decoded.parentsGuide)
            guard !Task.isCancelled else { return [] }
            cache[normalizedID] = result
            return result
        } catch {
            return []
        }
    }

    private static func normalizedIMDbID(_ value: String) -> String? {
        guard let range = value.range(of: #"tt\d+"#, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        return value[range].lowercased()
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
