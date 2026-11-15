import Foundation

/// Skip Intro and Skip Ending for Plex files, from the markers Plex detected
/// in the file itself.
///
/// Plex measures its markers on the exact file being played, so they take the
/// place of IntroDB's or the chapters' segment of the same kind. Kinds Plex
/// doesn't detect (recap, post-credits scene) still come from the other sources.
@MainActor
enum PlexSkipMarkers {
    nonisolated static let provider = "plex"

    private static var cache: [PlexPlaybackSync.Item: [SkipInterval]] = [:]

    /// The segments for a stream URL, or none when it isn't a Plex file or the
    /// server has no markers for it.
    static func intervals(forStreamURL urlString: String?, isMovie: Bool) async -> [SkipInterval] {
        guard let url = urlString.flatMap(URL.init(string:)),
              let item = PlexPlaybackSync.shared.item(for: url) else { return [] }
        if let cached = cache[item] { return cached }
        guard let client = PlexSessionManager.shared.client(forServerID: item.serverID) else { return [] }
        do {
            let markers = try await client.markers(ratingKey: item.ratingKey)
            let intervals = Self.intervals(from: markers, isMovie: isMovie)
            // None yet can mean Plex hasn't analyzed the file: ask again next play.
            if !intervals.isEmpty { cache[item] = intervals }
            return intervals
        } catch {
            // Not cached: the next play asks again.
            print("[Plex] markers unavailable: \(error.localizedDescription)")
            return []
        }
    }

    /// Plex markers as skip segments. The final credits marker (the last one
    /// when none is flagged) is the ending of an episode, or a movie's credits.
    /// Credits that a scene follows can still be skipped, but don't count as
    /// the ending, so the next episode isn't offered before the scene. Other
    /// marker types (commercials in DVR recordings) are left out.
    nonisolated static func intervals(from markers: [PlexClient.Marker], isMovie: Bool) -> [SkipInterval] {
        let credits = markers.filter { $0.type.lowercased() == "credits" }
        let ending = credits.last(where: { $0.final == true }) ?? credits.max { $0.startTimeOffset < $1.startTimeOffset }
        return markers.compactMap { marker -> SkipInterval? in
            let type: String
            switch marker.type.lowercased() {
            case "intro": type = "intro"
            case "credits":
                if marker == ending {
                    type = isMovie ? "movie-credits" : "credits"
                } else {
                    type = SkipInterval.creditsBeforeSceneType
                }
            default: return nil
            }
            let start = Double(marker.startTimeOffset) / 1000
            let end = Double(marker.endTimeOffset) / 1000
            guard start >= 0, end > start else { return nil }
            return SkipInterval(startTime: start, endTime: end, type: type, provider: provider)
        }
        .sorted { $0.startTime < $1.startTime }
    }

    /// `others` with Plex's segments in place of theirs of the same kind.
    /// A post-credits scene that starts inside Plex's credits ends them early,
    /// so skipping the credits never skips the scene.
    nonisolated static func merged(plex: [SkipInterval], others: [SkipInterval]) -> [SkipInterval] {
        guard !plex.isEmpty else { return others }
        let kept = others.filter { interval in !plex.contains { replaces($0, interval) } }
        let postCredits = kept.filter(\.isPostCredits)
        let adjusted = plex.compactMap { interval -> SkipInterval? in
            guard interval.isEnding || interval.isMovieCredits,
                  let scene = postCredits
                    .filter({ $0.startTime > interval.startTime && $0.startTime < interval.endTime })
                    .min(by: { $0.startTime < $1.startTime }) else { return interval }
            return SkipInterval(
                startTime: interval.startTime,
                endTime: scene.startTime,
                type: interval.type,
                provider: interval.provider
            )
        }
        return (kept + adjusted).sorted { $0.startTime < $1.startTime }
    }

    /// Whether Plex's `plexInterval` takes the place of `other`: both an intro,
    /// or both the ending.
    nonisolated static func replaces(_ plexInterval: SkipInterval, _ other: SkipInterval) -> Bool {
        if plexInterval.isIntro { return other.isIntro }
        if plexInterval.isEnding || plexInterval.isMovieCredits { return other.isEnding || other.isMovieCredits }
        return false
    }
}
