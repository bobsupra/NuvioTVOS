import Foundation

/// Shuffle play for a series: the Details "Shuffle" button starts a random
/// episode, and while that series plays, Up Next picks another random one
/// instead of the following episode.
///
/// - Episodes don't repeat until every eligible one has played.
/// - Unwatched episodes come first; once all are watched, any aired one can play.
/// - Specials (season 0) and episodes that haven't aired are skipped.
///
/// A session lasts until the app closes or the user plays the series normally
/// (a regular Play or episode pick ends it).
@MainActor
final class EpisodeShuffle {
    static let shared = EpisodeShuffle()

    private struct Session {
        var played: Set<String> = []
        /// The pick shown as Up Next for a given current episode, so the card
        /// and the autoplay agree.
        var nextPickByCurrentID: [String: String] = [:]
    }

    private var sessions: [String: Session] = [:]
    private var random: () -> Double

    init(random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        self.random = random
    }

    func isActive(seriesID: String) -> Bool {
        sessions[seriesID] != nil
    }

    /// Starts shuffle for a series and returns the first episode to play.
    func start(
        seriesID: String,
        episodes: [NuvioVideo],
        isWatched: (NuvioVideo) -> Bool
    ) -> NuvioVideo? {
        sessions[seriesID] = Session()
        guard let first = pick(from: episodes, excluding: nil, played: [], isWatched: isWatched) else {
            sessions[seriesID] = nil
            return nil
        }
        sessions[seriesID]?.played.insert(first.id)
        return first
    }

    func stop(seriesID: String) {
        sessions[seriesID] = nil
    }

    /// The random episode to offer after `current`, or nil when shuffle is off
    /// for this series.
    func next(
        seriesID: String,
        after current: NuvioVideo?,
        episodes: [NuvioVideo],
        isWatched: (NuvioVideo) -> Bool
    ) -> NuvioVideo? {
        guard var session = sessions[seriesID] else { return nil }
        if let current { session.played.insert(current.id) }
        let currentKey = current?.id ?? ""
        if let pickedID = session.nextPickByCurrentID[currentKey],
           let picked = episodes.first(where: { $0.id == pickedID }),
           !session.played.contains(picked.id) {
            sessions[seriesID] = session
            return picked
        }
        var choice = pick(from: episodes, excluding: current?.id, played: session.played, isWatched: isWatched)
        if choice == nil {
            // Every eligible episode has played: start a new round.
            session.played = current.map { [$0.id] } ?? []
            choice = pick(from: episodes, excluding: current?.id, played: session.played, isWatched: { _ in false })
        }
        if let choice { session.nextPickByCurrentID[currentKey] = choice.id }
        sessions[seriesID] = session
        return choice
    }

    /// Shuffle only makes sense for shows whose episodes stand on their own
    /// (sitcoms, animated comedies, reality, talk and game shows, kids' shows),
    /// not for a story told in order. Judged from the genres the metadata
    /// reports: an episodic genre, and none that marks a serialized story.
    static func suitsShuffle(genres: [String]?) -> Bool {
        let normalized = Set((genres ?? []).map {
            $0.lowercased().filter { $0.isLetter }
        })
        guard !normalized.isEmpty else { return false }
        let episodic: Set<String> = [
            "comedy", "sitcom", "reality", "realitytv", "talk", "talkshow", "gameshow",
            "kids", "family", "children", "news", "sketch", "standup",
        ]
        let serialized: Set<String> = ["drama", "thriller", "mystery", "horror", "soap", "war"]
        return !normalized.isDisjoint(with: episodic) && normalized.isDisjoint(with: serialized)
    }

    static func isEligible(_ episode: NuvioVideo) -> Bool {
        episode.season > 0 && EpisodeReleasePolicy.hasAired(episode.released)
    }

    private func pick(
        from episodes: [NuvioVideo],
        excluding currentID: String?,
        played: Set<String>,
        isWatched: (NuvioVideo) -> Bool
    ) -> NuvioVideo? {
        let candidates = episodes.filter {
            Self.isEligible($0) && $0.id != currentID && !played.contains($0.id)
        }
        let unwatched = candidates.filter { !isWatched($0) }
        let pool = unwatched.isEmpty ? candidates : unwatched
        guard !pool.isEmpty else { return nil }
        let index = min(pool.count - 1, Int(random() * Double(pool.count)))
        return pool[index]
    }
}
