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
        /// `SurpriseMeHistory.signature`: changes whenever a title is added,
        /// removed or moves, not only when the count does. Candidates are
        /// seeded from the history, so they're gathered again when it changes.
        var historySignature: Int
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

    /// What a TMDB or AI request was made under. The generation only moves
    /// forward, so after A → B → A a request from the first A is still told
    /// apart from the current A.
    struct Ticket: Equatable {
        let key: Key
        let generation: UInt64
    }

    private(set) var key: Key?
    private(set) var generation: UInt64 = 0
    private(set) var online: [NuvioMeta] = []
    private(set) var aiQueue: [SurpriseMeAIPick] = []

    /// The ticket for a request made now, or nil before the first `prepare`.
    var ticket: Ticket? { key.map { Ticket(key: $0, generation: generation) } }

    /// Moves to `newKey`, dropping whatever was gathered for another one.
    mutating func prepare(for newKey: Key) -> Change {
        guard newKey != key else { return .unchanged }
        let profileChanged = key.map { $0.profileScope != newKey.profileScope } ?? false
        key = newKey
        generation &+= 1
        online = []
        aiQueue = []
        return profileChanged ? .profileChanged : .candidatesStale
    }

    private func isCurrent(_ ticket: Ticket) -> Bool {
        ticket.generation == generation && ticket.key == key
    }

    /// TMDB is on for the current key and nothing was gathered yet.
    var needsOnlineCandidates: Bool { key?.useTMDB == true && online.isEmpty }

    /// Keeps candidates fetched under `ticket` only if nothing changed since
    /// (same profile and history, TMDB still on, no change and back).
    @discardableResult
    mutating func accept(online fetched: [NuvioMeta], for ticket: Ticket) -> Bool {
        guard isCurrent(ticket), ticket.key.useTMDB else { return false }
        online = fetched
        return true
    }

    /// Queues AI picks asked for under `ticket`, only if it is still current.
    @discardableResult
    mutating func accept(aiQueue picks: [SurpriseMeAIPick], for ticket: Ticket) -> Bool {
        guard isCurrent(ticket) else { return false }
        aiQueue = picks
        return true
    }

    /// Whether an answer asked for under `ticket` still applies.
    func stillCurrent(_ ticket: Ticket) -> Bool { isCurrent(ticket) }

    mutating func nextQueuedPick() -> SurpriseMeAIPick? {
        aiQueue.isEmpty ? nil : aiQueue.removeFirst()
    }

    /// Home's titles, plus the TMDB ones only while TMDB is on.
    func candidates(home: [NuvioMeta]) -> [NuvioMeta] {
        home + (key?.useTMDB == true ? online : [])
    }
}
