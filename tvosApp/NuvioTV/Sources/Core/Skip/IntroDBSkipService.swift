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

    /// Movie credits
    var isMovieCredits: Bool {
        type.lowercased() == "movie-credits"
    }

    /// Post-credits scene
    var isPostCredits: Bool {
        type.lowercased() == "post-credits"
    }

    /// Opening / intro / OP
    var isIntro: Bool {
        switch type.lowercased() {
        case "intro", "op", "opening", "mixed-op":
            return true
        default:
            return false
        }
    }

    /// Recap sequence
    var isRecap: Bool {
        switch type.lowercased() {
        case "recap":
            return true
        default:
            return false
        }
    }

    func label(targetsPostCredits: Bool = false) -> String {
        switch type.lowercased() {
        case "intro", "op", "opening", "mixed-op":
            return L10n.string("skip_intro", fallback: "Skip Intro")
        case "recap":
            return L10n.string("skip_recap", fallback: "Skip Recap")
        case "movie-credits":
            return targetsPostCredits
                ? L10n.string("skip_to_post_credits", fallback: "Skip to Post-Credits")
                : L10n.string("skip_movie_credits", fallback: "Skip Credits")
        case "outro", "ed", "credits", "ending", "mixed-ed":
            return targetsPostCredits
                ? L10n.string("skip_to_post_credits", fallback: "Skip to Post-Credits")
                : L10n.string("skip_ending", fallback: "Skip Ending")
        default:
            return L10n.string("skip", fallback: "Skip")
        }
    }

    var label: String {
        label(targetsPostCredits: false)
    }

    func followingPostCreditsScene(intervals: [SkipInterval], duration: Double) -> SkipInterval? {
        guard isMovieCredits || isEnding else { return nil }
        // Explicit post-credits scene from IntroDb
        let explicit = intervals.filter {
            $0.isPostCredits && $0.startTime.isFinite && $0.endTime.isFinite &&
                $0.startTime >= endTime && $0.endTime > $0.startTime &&
                (duration <= 0 || $0.startTime < duration)
        }.min { $0.startTime < $1.startTime }
        if let explicit { return explicit }
        // Heuristic: significant content after credits/outro suggests a post-credits scene (> 5 seconds).
        if duration > 0 {
            let gap = duration - endTime
            if gap > 5.0 {
                return SkipInterval(
                    startTime: endTime,
                    endTime: duration,
                    type: "post-credits",
                    provider: "heuristic"
                )
            }
        }
        return nil
    }
}

private struct IntroDBSegmentsResponse: Decodable {
    let intro: IntroDBSegment?
    let recap: IntroDBSegment?
    let outro: IntroDBSegment?
    let postCredits: IntroDBSegment?

    enum CodingKeys: String, CodingKey {
        case intro
        case recap
        case outro
        case postCredits = "post_credits"
    }
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

final class IntroDBSkipService: @unchecked Sendable {
    static let shared = IntroDBSkipService()

    private let session: URLSession
    private let stateLock = NSLock()
    private var cache: [String: [SkipInterval]] = [:]
    struct SeasonSample {
        let episode: Int
        let intervals: [SkipInterval]
        let duration: Double
    }
    private var seasonSamples: [String: [Int: SeasonSample]] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    func intervals(
        imdbId: String?,
        season: Int? = nil,
        episode: Int? = nil,
        duration: Double? = nil,
        isMovie: Bool = false
    ) async -> [SkipInterval] {
        guard let imdbId = normalizedImdbId(imdbId) else {
            return []
        }

        let cacheKey: String
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "imdb_id", value: imdbId)]
        if let season, let episode {
            cacheKey = "\(imdbId):\(season):\(episode)"
            queryItems.append(URLQueryItem(name: "season", value: "\(season)"))
            queryItems.append(URLQueryItem(name: "episode", value: "\(episode)"))
        } else {
            cacheKey = isMovie ? "movie:\(imdbId)" : imdbId
            if isMovie {
                queryItems.append(URLQueryItem(name: "is_movie", value: "true"))
            }
        }
        if let cached = cachedIntervals(for: cacheKey) {
            if let season, let episode, let duration, duration > 0 { seedSeasonTemplate(imdbId: imdbId, season: season, episode: episode, intervals: cached, duration: duration) }
            return mergedWithSeasonInference(cached, imdbId: imdbId, season: season, episode: episode, duration: duration)
        }

        guard var components = URLComponents(string: normalizedBase + "/segments") else {
            return []
        }
        components.queryItems = queryItems
        guard let url = components.url else { return [] }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return inferredSeasonIntervals(imdbId: imdbId, season: season, episode: episode, duration: duration)
            }
            let decoded = try JSONDecoder().decode(IntroDBSegmentsResponse.self, from: data)
            let intervals: [SkipInterval]
            if isMovie {
                let credits = decoded.outro?.interval(type: "movie-credits")
                let postCredits = decoded.postCredits?.interval(type: "post-credits")
                let safeCredits: SkipInterval?
                if let credits, let postCredits,
                   postCredits.startTime < credits.endTime, postCredits.endTime > credits.startTime {
                    if postCredits.startTime > credits.startTime {
                        safeCredits = SkipInterval(
                            startTime: credits.startTime,
                            endTime: postCredits.startTime,
                            type: credits.type,
                            provider: credits.provider
                        )
                    } else {
                        safeCredits = nil
                    }
                } else {
                    safeCredits = credits
                }
                intervals = [safeCredits, postCredits].compactMap { $0 }.sorted { $0.startTime < $1.startTime }
            } else {
                let outro = decoded.outro?.interval(type: "outro")
                let postCredits = decoded.postCredits?.interval(type: "post-credits")
                intervals = [
                    decoded.recap?.interval(type: "recap"),
                    decoded.intro?.interval(type: "intro"),
                    outro,
                    postCredits
                ]
                .compactMap { $0 }
                .sorted { $0.startTime < $1.startTime }
            }
            storeCachedIntervals(intervals, for: cacheKey)
            if let season, let episode, let duration, duration > 0 { seedSeasonTemplate(imdbId: imdbId, season: season, episode: episode, intervals: intervals, duration: duration) }
            return mergedWithSeasonInference(intervals, imdbId: imdbId, season: season, episode: episode, duration: duration)
        } catch {
            // A failed request is transient; do not turn it into an
            // authoritative empty result. A same-season template is a safe
            // fallback only when the target duration is known.
            return inferredSeasonIntervals(imdbId: imdbId, season: season, episode: episode, duration: duration)
        }
    }

    private func inferredSeasonIntervals(imdbId: String, season: Int?, episode: Int?, duration: Double?) -> [SkipInterval] {
        guard let season, episode != nil, let duration, duration > 0,
              let samples = seasonSampleSnapshot(imdbId: imdbId, season: season) else { return [] }
        return Self.consensusIntervals(samples: Array(samples.values), targetDuration: duration)
    }

    private func mergedWithSeasonInference(_ exact: [SkipInterval], imdbId: String, season: Int?, episode: Int?, duration: Double?) -> [SkipInterval] {
        guard let season, episode != nil, let duration, duration > 0,
              let samples = seasonSampleSnapshot(imdbId: imdbId, season: season) else { return exact }
        let inferred = Self.consensusIntervals(samples: Array(samples.values), targetDuration: duration)
        return Self.mergingExactIntervals(exact, with: inferred)
    }

    /// Seeds a same-season template after an exact episode response and after
    /// the player has learned the media duration.
    func seedSeasonTemplate(imdbId: String?, season: Int?, episode: Int? = nil, intervals: [SkipInterval], duration: Double) {
        guard let imdbId = normalizedImdbId(imdbId), let season, let episode, season >= 0,
              duration > 0, !intervals.contains(where: { $0.provider == "introdb-season" }) else { return }
        stateLock.lock()
        seasonSamples["\(imdbId):\(season)", default: [:]][episode] = SeasonSample(
            episode: episode,
            intervals: intervals,
            duration: duration
        )
        stateLock.unlock()
    }

    private func cachedIntervals(for key: String) -> [SkipInterval]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cache[key]
    }

    private func storeCachedIntervals(_ intervals: [SkipInterval], for key: String) {
        stateLock.lock()
        cache[key] = intervals
        stateLock.unlock()
    }

    private func seasonSampleSnapshot(imdbId: String, season: Int) -> [Int: SeasonSample]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return seasonSamples["\(imdbId):\(season)"]
    }

    /// Exact episode markers always win; a season template only fills segment
    /// types that the episode response omitted.
    static func mergingExactIntervals(
        _ exact: [SkipInterval],
        with inferred: [SkipInterval]
    ) -> [SkipInterval] {
        let exactTypes = Set(exact.map { $0.type.lowercased() })
        return (exact + inferred.filter { !exactTypes.contains($0.type.lowercased()) })
            .sorted { $0.startTime < $1.startTime }
    }

    static func consensusIntervals(samples: [SeasonSample], targetDuration: Double) -> [SkipInterval] {
        guard samples.count >= 2 else { return [] }
        let types = Set(samples.flatMap { $0.intervals.map { $0.type.lowercased() } })
            .filter { $0 != "post-credits" }
        return types.compactMap { type -> SkipInterval? in
            let values = samples.compactMap { sample -> (sample: SeasonSample, interval: SkipInterval)? in
                guard let interval = sample.intervals.first(where: { $0.type.lowercased() == type }) else { return nil }
                return (sample, interval)
            }
            guard values.count >= 2 else { return nil }
            let ending = values[0].interval.isEnding
            func anchor(_ value: (sample: SeasonSample, interval: SkipInterval)) -> (Double, Double) {
                if ending {
                    return (value.sample.duration - value.interval.startTime, value.sample.duration - value.interval.endTime)
                }
                return (value.interval.startTime, value.interval.endTime)
            }
            let candidates = values.map { candidate in
                let center = anchor(candidate)
                var cluster = values.filter {
                    let point = anchor($0)
                    return abs(point.0 - center.0) <= 5 && abs(point.1 - center.1) <= 5
                }
                let med = (median(cluster.map { anchor($0).0 }), median(cluster.map { anchor($0).1 }))
                cluster = cluster.filter {
                    let point = anchor($0)
                    return abs(point.0 - med.0) <= 5 && abs(point.1 - med.1) <= 5
                }
                let spread = cluster.map { let p = anchor($0); return abs(p.0 - med.0) + abs(p.1 - med.1) }.max() ?? .infinity
                return (cluster, spread, med)
            }
            guard let cluster = candidates.sorted(by: {
                if $0.0.count != $1.0.count { return $0.0.count > $1.0.count }
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.2.0 != $1.2.0 ? $0.2.0 < $1.2.0 : $0.2.1 < $1.2.1
            }).first?.0 else { return nil }
            guard cluster.count >= 2 else { return nil }
            let points = cluster.map { anchor($0) }
            let start = median(points.map { $0.0 }), endValue = median(points.map { $0.1 })
            if ending {
                let inferredStart = targetDuration - start
                let inferredEnd = targetDuration - endValue
                guard inferredStart >= 0, inferredEnd > inferredStart, inferredEnd <= targetDuration else { return nil }
                return SkipInterval(startTime: inferredStart, endTime: inferredEnd, type: cluster[0].interval.type, provider: "introdb-season")
            }
            return SkipInterval(startTime: start, endTime: endValue, type: cluster[0].interval.type, provider: "introdb-season")
        }.sorted { $0.startTime < $1.startTime }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        if sorted.count.isMultiple(of: 2) {
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        return sorted[sorted.count / 2]
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
