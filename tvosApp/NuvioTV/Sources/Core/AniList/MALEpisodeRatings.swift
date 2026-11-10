import Foundation

/// Each episode's score on MyAnimeList, 1–5 from the poll under the episode's discussion, read
/// from Tenrai (a Jikan v4–compatible API over MyAnimeList; Jikan's public API closed on
/// 2026-10-01). Settings → Integrations → AniList → MAL Episode Ratings. Anime only: an AniList
/// episode by its entry's MAL id, a Cinemeta anime episode through the offline tables.
///
/// One request answers 100 episodes of a MAL entry, so a season's cards cost one request; pages
/// are kept 12 hours, and a 429 stops asking for as long as Tenrai says.
enum MALEpisodeRatings {
    static let source = "mal_episode"
    static let displayName = "MAL"
    static let assetName = "rating_myanimelist"
    static let maxScore: Double = 5
    /// Changed in one place if Tenrai moves (its v2) or a self-hosted Jikan v4 server is used.
    static let baseURL = URL(string: "https://api.tenrai.org/v1")!
    static let pageSize = 100

    struct Target: Hashable, Sendable {
        let malID: Int
        let episode: Int
    }

    struct PageKey: Hashable, Sendable {
        let malID: Int
        let page: Int
    }

    static var isEnabled: Bool { MALSettings.showsEpisodeRatings }

    // MARK: Ratings

    /// The score of every asked episode that has one, by the ids asked.
    static func ratings(forEpisodeIDs ids: [String]) async -> [String: NuvioExternalRating] {
        guard isEnabled, !ids.isEmpty else { return [:] }
        var targets: [String: Target] = [:]
        for id in Set(ids) {
            if let target = await target(forEpisodeID: id) { targets[id] = target }
        }
        guard !targets.isEmpty else { return [:] }

        var scores: [PageKey: [Int: Double]] = [:]
        let keys = Set(targets.values.map { PageKey(malID: $0.malID, page: page(of: $0.episode)) })
        for key in keys.sorted(by: { ($0.malID, $0.page) < ($1.malID, $1.page) }) {
            scores[key] = await MALEpisodeScoreStore.shared.scores(for: key)
        }

        var result: [String: NuvioExternalRating] = [:]
        for (id, target) in targets {
            let key = PageKey(malID: target.malID, page: page(of: target.episode))
            guard let score = scores[key]?[target.episode] else { continue }
            result[id] = rating(score)
        }
        return result
    }

    static func rating(forEpisodeID id: String) async -> NuvioExternalRating? {
        await ratings(forEpisodeIDs: [id])[id]
    }

    static func rating(_ score: Double) -> NuvioExternalRating {
        NuvioExternalRating(source: source, value: score, name: displayName, max: maxScore)
    }

    /// As MAL shows it: two decimals, "4.76".
    static func formatted(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    // MARK: Ids

    /// The MAL entry and episode of `anilist:ENTRY:EPISODE` or a Cinemeta `ttIMDB:SEASON:EPISODE`.
    static func target(forEpisodeID id: String) async -> Target? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if let entry = AniListMetaBuilder.aniListID(from: trimmed) {
            guard parts.count == 3, let episode = Int(parts[2]), episode > 0,
                  let mal = await malID(aniListID: entry) else { return nil }
            return Target(malID: mal, episode: episode)
        }
        guard let cinemeta = cinemetaEpisode(trimmed),
              let found = await AniListOfflineMaps.shared.aniListEpisode(
                  imdb: cinemeta.imdb, tmdbTV: nil, season: cinemeta.season, episode: cinemeta.episode
              ),
              found.episode > 0,
              let mal = await malID(aniListID: found.aniListID) else { return nil }
        return Target(malID: mal, episode: found.episode)
    }

    /// `tt0388629:2:5` → the IMDb id, season 2, episode 5. Specials (season 0) aren't on MAL's list.
    static func cinemetaEpisode(_ id: String) -> (imdb: String, season: Int, episode: Int)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0].hasPrefix("tt"), parts[0].count > 2,
              let season = Int(parts[1]), let episode = Int(parts[2]), season > 0, episode > 0 else { return nil }
        return (parts[0], season, episode)
    }

    static func page(of episode: Int) -> Int {
        max(1, (episode - 1) / pageSize + 1)
    }

    /// From the offline tables, else asked of AniList (kept a week).
    static func malID(aniListID: Int) async -> Int? {
        if let mal = await AniListOfflineMaps.shared.entry(aniListID: aniListID)?.mal, mal > 0 { return mal }
        guard let data = try? await AniListClient.shared.query(
            malIDQuery, variables: ["id": aniListID], ttl: 7 * 24 * 3600, notesStatus: false
        ) else { return nil }
        return malID(fromAniList: data)
    }

    static let malIDQuery = "query ($id: Int) { Media(id: $id, type: ANIME) { idMal } }"

    static func malID(fromAniList data: Data) -> Int? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let media = (root["data"] as? [String: Any])?["Media"] as? [String: Any],
              let mal = media["idMal"] as? Int, mal > 0 else { return nil }
        return mal
    }

    // MARK: Tenrai

    static func url(for key: PageKey) -> URL {
        let path = baseURL.appendingPathComponent("anime/\(key.malID)/episodes")
        guard key.page > 1, var components = URLComponents(url: path, resolvingAgainstBaseURL: false) else { return path }
        components.queryItems = [URLQueryItem(name: "page", value: String(key.page))]
        return components.url ?? path
    }

    private struct EpisodesPage: Decodable {
        let data: [Episode]?

        struct Episode: Decodable {
            let number: Int?
            let score: Double?

            enum CodingKeys: String, CodingKey {
                case number = "mal_id"
                case score
            }
        }
    }

    /// Episode number → score; an episode nobody voted on (score 0) is left out.
    static func scores(fromPage data: Data) -> [Int: Double]? {
        guard let page = try? JSONDecoder().decode(EpisodesPage.self, from: data), let episodes = page.data else { return nil }
        var scores: [Int: Double] = [:]
        for episode in episodes {
            guard let number = episode.number, let score = episode.score, score > 0, score <= maxScore else { continue }
            scores[number] = score
        }
        return scores
    }
}

/// Pages of episode scores, kept 12 hours (a failed answer 15 minutes), one request per page at a
/// time, nothing asked while Tenrai says to wait.
actor MALEpisodeScoreStore {
    static let shared = MALEpisodeScoreStore()

    static let keepFor: TimeInterval = 12 * 3600
    static let keepFailureFor: TimeInterval = 15 * 60
    static let defaultWait: TimeInterval = 60

    enum Answer: Sendable, Equatable {
        case scores([Int: Double])
        case wait(TimeInterval)
        case failed
    }

    typealias Fetch = @Sendable (URL) async -> Answer

    private var pages: [MALEpisodeRatings.PageKey: (scores: [Int: Double], until: Date)] = [:]
    private var inFlight: [MALEpisodeRatings.PageKey: Task<Answer, Never>] = [:]
    private var waitUntil: Date?
    private let fetch: Fetch

    init(fetch: @escaping Fetch = MALEpisodeScoreStore.live) {
        self.fetch = fetch
    }

    func scores(for key: MALEpisodeRatings.PageKey, now: Date = Date()) async -> [Int: Double] {
        if let kept = pages[key], kept.until > now { return kept.scores }
        if let waitUntil, waitUntil > now { return pages[key]?.scores ?? [:] }
        if let running = inFlight[key] { return Self.scores(in: await running.value) ?? pages[key]?.scores ?? [:] }

        let url = MALEpisodeRatings.url(for: key)
        let fetch = self.fetch
        let task = Task { await fetch(url) }
        inFlight[key] = task
        let answer = await task.value
        inFlight[key] = nil

        switch answer {
        case .scores(let scores):
            pages[key] = (scores, now.addingTimeInterval(Self.keepFor))
            return scores
        case .wait(let seconds):
            waitUntil = now.addingTimeInterval(seconds)
            return pages[key]?.scores ?? [:]
        case .failed:
            let earlier = pages[key]?.scores ?? [:]
            pages[key] = (earlier, now.addingTimeInterval(Self.keepFailureFor))
            return earlier
        }
    }

    func forget() {
        pages = [:]
        waitUntil = nil
    }

    private static func scores(in answer: Answer) -> [Int: Double]? {
        if case .scores(let scores) = answer { return scores }
        return nil
    }

    static let live: Fetch = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let reply = try? await URLSession.shared.data(for: request),
              let http = reply.1 as? HTTPURLResponse else { return .failed }
        return MALEpisodeScoreStore.answer(
            status: http.statusCode,
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            data: reply.0
        )
    }

    static func answer(status: Int, retryAfter: String?, data: Data) -> Answer {
        switch status {
        case 200..<300:
            return MALEpisodeRatings.scores(fromPage: data).map(Answer.scores) ?? .failed
        case 404:
            // MAL has no episode list for it: nothing to show, no need to ask again soon.
            return .scores([:])
        case 429, 503:
            let seconds = retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) } ?? defaultWait
            return .wait(min(max(seconds, 1), 3600))
        default:
            return .failed
        }
    }
}
