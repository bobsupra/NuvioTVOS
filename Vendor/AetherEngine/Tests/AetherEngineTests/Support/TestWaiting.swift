import Foundation

/// The one place this suite waits for something to happen.
///
/// Before this there were thirteen private copies of it in thirteen files, in three different
/// shapes, and the same mistake had to be found and fixed in each of them separately: three rounds
/// of red CI in one night came from two copies that parked a waiter on the global dispatch pool
/// and then gave the park a wall-clock deadline.
///
/// The two rules the shapes below encode:
///
/// **A step that HAS to happen gets no deadline of its own.** Any finite bound can be overrun by an
/// oversubscribed machine, and the bound then decides what the test reports rather than the code
/// under test. On this suite's runner that is not theoretical: a green run routinely has hundreds
/// of test durations above 60 s. The hang catcher is a `.timeLimit` trait on the test, which
/// reports a hang AS one, with a name attached.
///
/// **The sleep has to be allowed to throw.** `try?` swallows the cancellation the `.timeLimit`
/// trait sends, `Task.sleep` then returns at once, and the wait spins hot until the CI job's own
/// ceiling kills it: one 30 minute hang on main, with the log of the killed job discarded, so not
/// even the test's name survived.
///
/// `#isolation` carries the caller's actor in, so a `@MainActor` test can pass a condition that
/// reads main-actor state without the closure having to hop.
func waitFor(isolation: isolated (any Actor)? = #isolation,
             _ condition: () -> Bool) async throws {
    while !condition() {
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// The bounded form, for the rare case where the BOUND is the assertion: "this must not have
/// happened within n seconds". Returns whether the condition came true, and never asserts on its
/// own. A positive event that the test needs in order to measure anything belongs in `waitFor`
/// above, not here with a number that a loaded machine can spend for it.
@discardableResult
func waitFor(upTo budget: Duration,
             isolation: isolated (any Actor)? = #isolation,
             _ condition: () -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + budget
    while !condition() {
        if clock.now >= deadline { return condition() }
        try await Task.sleep(for: .milliseconds(20))
    }
    return true
}
