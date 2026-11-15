import Foundation

/// The TMDB candidates Surprise Me gathered, and the AI picks queued from them,
/// kept only while they still fit what they were gathered for: the same
/// profile, TMDB still on, and the same history.
///
/// The view outlives these: the tab stays alive across profile switches and
/// setting changes, and fetching or asking the AI takes a while. Anything
/// gathered for an older key is dropped, and an answer that arrives after the
/// key changed is ignored.
struct SurpriseMeCandidatePool {
    struct Key: Equatable {
        var profileScope: String
        var useTMDB: Bool
        /// Distinct titles watched, saved or in progress: candidates are
        /// seeded from these, so they're gathered again when it changes.
        var historyCount: Int
        /// Anything else the candidates depend on (e.g. movies, series or both).
        var variant: String = ""
    }

    enum Change: Equatable {
        case unchanged
        /// Candidates and the AI queue were dropped; gather again.
        case candidatesStale
        /// Another profile: also drop what was shown and offered.
        case profileChanged
    }

    private(set) var key: Key?
    private(set) var online: [NuvioMeta] = []
    private(set) var aiQueue: [SurpriseMeAIPick] = []

    /// Moves to `newKey`, dropping whatever was gathered for another one.
    mutating func prepare(for newKey: Key) -> Change {
        guard newKey != key else { return .unchanged }
        let profileChanged = key.map { $0.profileScope != newKey.profileScope } ?? false
        key = newKey
        online = []
        aiQueue = []
        return profileChanged ? .profileChanged : .candidatesStale
    }

    /// TMDB is on for the current key and nothing was gathered yet.
    var needsOnlineCandidates: Bool { key?.useTMDB == true && online.isEmpty }

    /// Keeps candidates fetched for `requested` only if it is still the
    /// current key (same profile and history, TMDB still on).
    @discardableResult
    mutating func accept(online fetched: [NuvioMeta], for requested: Key) -> Bool {
        guard requested == key, requested.useTMDB else { return false }
        online = fetched
        return true
    }

    /// Queues AI picks asked for under `requested`, only if it is still current.
    @discardableResult
    mutating func accept(aiQueue picks: [SurpriseMeAIPick], for requested: Key) -> Bool {
        guard requested == key else { return false }
        aiQueue = picks
        return true
    }

    mutating func nextQueuedPick() -> SurpriseMeAIPick? {
        aiQueue.isEmpty ? nil : aiQueue.removeFirst()
    }

    /// Home's titles, plus the TMDB ones only while TMDB is on.
    func candidates(home: [NuvioMeta]) -> [NuvioMeta] {
        home + (key?.useTMDB == true ? online : [])
    }
}
