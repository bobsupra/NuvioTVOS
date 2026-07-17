import Foundation

enum IntroDBConfig {
    static var apiURL: String {
        value("INTRODB_API_URL", fallback: "https://api.introdb.app")
    }

    private static func value(_ key: String, fallback: String) -> String {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
           let resolved = resolvedValue(value) {
            return resolved
        }
        if let value = ProcessInfo.processInfo.environment[key],
           let resolved = resolvedValue(value) {
            return resolved
        }
        return fallback
    }

    private static func resolvedValue(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !(trimmed.hasPrefix("$(") && trimmed.hasSuffix(")")) else { return nil }
        return trimmed
    }
}

struct SkipInterval: Identifiable, Equatable {
    var id: String { "\(provider):\(type):\(startTime):\(endTime)" }
    let startTime: Double
    let endTime: Double
    let type: String
    let provider: String

    /// Outro / credits / ending — paired with the Next Episode card.
    var isEnding: Bool {
        switch type.lowercased() {
        case "outro", "ed", "credits", "ending", "mixed-ed":
            return true
        default:
            return false
        }
    }

    var label: String {
        switch type.lowercased() {
        case "intro", "op", "opening", "mixed-op":
            return "Skip Intro"
        case "outro", "ed", "credits", "ending", "mixed-ed":
            return "Skip Ending"
        case "recap":
            return "Skip Recap"
        default:
            return "Skip"
        }
    }
}

private struct IntroDBSegmentsResponse: Decodable {
    let intro: IntroDBSegment?
    let recap: IntroDBSegment?
    let outro: IntroDBSegment?
}

private struct IntroDBSegment: Decodable {
    let startSec: FlexibleSeconds?
    let endSec: FlexibleSeconds?
    let startMs: Double?
    let endMs: Double?

    enum CodingKeys: String, CodingKey {
        case startSec = "start_sec"
        case endSec = "end_sec"
        case startMs = "start_ms"
        case endMs = "end_ms"
    }
}

private struct FlexibleSeconds: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let double = try? container.decode(Double.self) {
            value = double
            return
        }
        let string = try container.decode(String.self)
        if let double = Double(string) {
            value = double
            return
        }
        let parts = string.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 2:
            value = parts[0] * 60 + parts[1]
        case 3:
            value = parts[0] * 3600 + parts[1] * 60 + parts[2]
        default:
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported time value"
            )
        }
    }
}

final class IntroDBSkipService {
    static let shared = IntroDBSkipService()

    private let session: URLSession
    private let decoder = JSONDecoder()
    private var cache: [String: [SkipInterval]] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func intervals(imdbId: String?, season: Int?, episode: Int?) async -> [SkipInterval] {
        guard let imdbId = normalizedImdbId(imdbId),
              let season,
              let episode else {
            return []
        }

        let cacheKey = "\(imdbId):\(season):\(episode)"
        if let cached = cache[cacheKey] { return cached }

        guard var components = URLComponents(string: normalizedBase + "/segments") else {
            return []
        }
        components.queryItems = [
            URLQueryItem(name: "imdb_id", value: imdbId),
            URLQueryItem(name: "season", value: "\(season)"),
            URLQueryItem(name: "episode", value: "\(episode)")
        ]
        guard let url = components.url else { return [] }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                cache[cacheKey] = []
                return []
            }
            let decoded = try decoder.decode(IntroDBSegmentsResponse.self, from: data)
            let intervals = [
                decoded.recap?.interval(type: "recap"),
                decoded.intro?.interval(type: "intro"),
                decoded.outro?.interval(type: "outro")
            ]
            .compactMap { $0 }
            .sorted { $0.startTime < $1.startTime }
            cache[cacheKey] = intervals
            return intervals
        } catch {
            cache[cacheKey] = []
            return []
        }
    }

    private var normalizedBase: String {
        var base = IntroDBConfig.apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    private func normalizedImdbId(_ value: String?) -> String? {
        guard let value else { return nil }
        let pattern = #"tt\d{6,}"#
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        return String(value[range])
    }
}

private extension IntroDBSegment {
    func interval(type: String) -> SkipInterval? {
        let start = startSec?.value ?? startMs.map { $0 / 1000.0 }
        let end = endSec?.value ?? endMs.map { $0 / 1000.0 }
        guard let start, let end, end > start else { return nil }
        return SkipInterval(startTime: start, endTime: end, type: type, provider: "introdb")
    }
}
