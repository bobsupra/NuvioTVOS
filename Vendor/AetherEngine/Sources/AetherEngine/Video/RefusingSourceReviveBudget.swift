import Foundation

/// #377 round 6: how long a session keeps trying a source that is REFUSING it, as ONE number.
///
/// The reporter measured what his origin actually does: it serves for about six minutes, refuses
/// every NEW request for about four, and then recovers on its own. Nothing about that is
/// concurrency, request count or volume (seven 1 KB requests one minute apart were enough to reach
/// it), and re-resolving through the source does not clear it, because the source hands back the
/// same edge host. So the only thing that decides whether such a session lives is how long the
/// engine is willing to keep asking. His recovery arrived at 243 s.
///
/// The engine was willing for 212 s, and nothing said so. That figure was the SUM of two counters
/// that did not know about each other: four paced revive attempts (3, 8, 20, 45 s = 76 s), each
/// followed by a reopen that walks the reader's own seven-rung reconnect ladder against the
/// refusing origin (about 34 s, unpaced and uncounted here). A session's lifetime being an
/// emergent product of two unrelated constants is how it came to be 31 s short of an origin that
/// heals itself, and it is also why making the reopen cheaper would have silently shortened the
/// session's life by two thirds. The budget is stated here instead, and the attempt count follows
/// from it rather than the other way round.
///
/// It is a budget per refusal WINDOW, not per session. The previous gate was never reset, so a
/// session that survived one window began the next with part of its budget already spent and the
/// third with none: on a two hour film against an origin with this shape, the later windows were
/// given up on for arithmetic reasons rather than measured ones. A gap longer than any that can
/// occur INSIDE a window is the separator, since every in-window gap is bounded by one ladder rung
/// plus one reopen (45 + ~34 s at the widest), and the healthy stretch between windows on the
/// origin this comes from is minutes. Getting the separation wrong is benign in both directions: a
/// window that reads as new gets a full budget, one that reads as a continuation keeps counting.
struct RefusingSourceReviveBudget {

    /// Wall clock a single refusal window may consume before the session is called. Covers the
    /// four-minute window measured on the reporter's origin with room for one that runs long,
    /// while staying short enough that a source which is genuinely gone still fails the session.
    static let defaultBudgetSeconds: TimeInterval = 600

    /// A gap longer than this starts a new window. See the type's note for the derivation.
    static let defaultNewWindowAfterSeconds: TimeInterval = 180

    let budgetSeconds: TimeInterval
    let newWindowAfterSeconds: TimeInterval

    /// Attempts inside the CURRENT window. Paces the revive ladder, and is reported, but no longer
    /// decides anything: the clock does.
    private(set) var attempts = 0
    private var windowStartedAt: DispatchTime?
    private var lastAdmittedAt: DispatchTime?

    init(budgetSeconds: TimeInterval = defaultBudgetSeconds,
         newWindowAfterSeconds: TimeInterval = defaultNewWindowAfterSeconds) {
        self.budgetSeconds = budgetSeconds
        self.newWindowAfterSeconds = newWindowAfterSeconds
    }

    /// Records one refusal-caused pump death. True while this window's budget has time left.
    ///
    /// `now` is injectable so the behaviour can be pinned without a test that sleeps for ten
    /// minutes, which would be a margin against a derived time bound and the first thing a loaded
    /// machine takes away.
    mutating func admit(now: DispatchTime = .now()) -> Bool {
        let continuing = lastAdmittedAt.map { Self.seconds(from: $0, to: now) <= newWindowAfterSeconds } ?? false
        lastAdmittedAt = now
        guard continuing, let started = windowStartedAt else {
            windowStartedAt = now
            attempts = 1
            // A fresh window is worth an attempt, unless there is no budget at all: a zero budget
            // has to mean "grants nothing", or it cannot express a spent one.
            return budgetSeconds > 0
        }
        attempts += 1
        return Self.seconds(from: started, to: now) < budgetSeconds
    }

    /// Seconds this window has been refusing, for the lines that have to state the budget rather
    /// than a count.
    func elapsedSeconds(now: DispatchTime = .now()) -> TimeInterval {
        guard let started = windowStartedAt else { return 0 }
        return Self.seconds(from: started, to: now)
    }

    private static func seconds(from: DispatchTime, to: DispatchTime) -> TimeInterval {
        guard to.uptimeNanoseconds >= from.uptimeNanoseconds else { return 0 }
        return Double(to.uptimeNanoseconds - from.uptimeNanoseconds) / 1_000_000_000
    }
}
