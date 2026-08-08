import Foundation
import Combine
import Testing
@testable import AetherEngine

/// AE#38 follow-up (rrgomes' production report on the shipped signal): `isSeeking`/`seekTarget` are a
/// level, and a level cannot say why it fell. These cover the three defects that report named plus the
/// deferred-stash hole, all from the consumer's side: which events a host actually sees.
struct Issue38SeekEventsTests {

    // MARK: - Rejections (the seek never reached a host)

    @MainActor
    @Test("a seek with no session reports rejected instead of vanishing")
    func rejectedWithoutSession() async throws {
        let engine = try AetherEngine()
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        await engine.seek(to: 42)   // state == .idle

        #expect(events.count == 1)
        #expect(events.first?.outcome == .rejected(.noActiveSession))
        #expect(events.first?.target == 42)
        #expect(engine.isSeeking == false)
    }

    // MARK: - The deferred stash (#127/#178)

    @MainActor
    @Test("a seek stashed during load carries the seek signal, not just an optimistic clock")
    func stashedSeekIsInFlight() async throws {
        let engine = try AetherEngine()
        engine.state = .loading
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        await engine.seek(to: 42)

        // The clock publishes a position nothing has reached yet; without the flag a sync host
        // broadcasts it as truth. That is the hole this closes.
        #expect(engine.clock.currentTime == 42)
        #expect(engine.isSeeking)
        #expect(engine.seekTarget == 42)
        #expect(events.map(\.outcome) == [.began])
        #expect(events.first?.origin == .deferred)
    }

    @MainActor
    @Test("a second stashed seek supersedes the first")
    func stashLatestWinsEmitsSuperseded() async throws {
        let engine = try AetherEngine()
        engine.state = .loading
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        await engine.seek(to: 42)
        await engine.seek(to: 97)

        #expect(events.map(\.outcome) == [.began, .superseded, .began])
        #expect(events.map(\.target) == [42, 42, 97])
        #expect(events[1].id == events[0].id)     // the superseded one is the first seek
        #expect(events[2].id != events[0].id)
        #expect(engine.seekTarget == 97)
    }

    @MainActor
    @Test("a load that dies under the stash rejects it instead of leaving the signal set")
    func stashDiscardRejects() async throws {
        let engine = try AetherEngine()
        engine.state = .loading
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        await engine.seek(to: 42)
        engine.state = .error("load failed")

        #expect(events.map(\.outcome) == [.began, .rejected(.noActiveSession)])
        #expect(engine.isSeeking == false)
        #expect(engine.seekTarget == nil)
    }

    @MainActor
    @Test("the stash hands over to its replay without dropping isSeeking")
    func stashHandoverKeepsSignalContinuous() async throws {
        let engine = try AetherEngine()
        engine.duration = 600
        engine.state = .loading
        var levels: [Bool] = []
        let sub = engine.$isSeeking.sink { levels.append($0) }
        defer { sub.cancel() }

        await engine.seek(to: 42)
        engine.state = .playing   // autostart path resolves the stash and replays the seek
        for _ in 0..<200 {
            if levels.count > 2 { break }
            await Task.yield()
        }

        // false (initial) -> true (stash) -> false (replayed seek landed). A gap at the handover would
        // show up as an extra true/false pair, and a consumer would broadcast into it.
        #expect(levels == [false, true, false])
    }

    @MainActor
    @Test("the replayed seek closes the stash as superseded and lands under its own id")
    func stashReplayEmitsSupersededThenLanded() async throws {
        let engine = try AetherEngine()
        engine.duration = 600
        engine.state = .loading
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        await engine.seek(to: 42)
        engine.state = .playing
        for _ in 0..<200 {
            if events.count >= 4 { break }
            await Task.yield()
        }

        #expect(events.count == 4)
        #expect(events[0].origin == .deferred)
        #expect(events[0].outcome == .began)
        #expect(events[1].outcome == .superseded)
        #expect(events[2].origin == .programmatic)
        #expect(events[2].outcome == .began)
        #expect(events[2].target == 42)
        if case .landed = events[3].outcome {} else { Issue.record("expected a landing, got \(events[3])") }
        #expect(events[3].id == events[2].id)     // terminator carries the seek's own id
        #expect(engine.isSeeking == false)
    }

    // MARK: - Native scrub landing (the falling edge that preceded the picture)

    @Test("a forward scrub lands when the picture reaches the restarted region")
    func scrubLandingForward() {
        #expect(AetherEngine.nativeScrubLanded(rendered: 100, target: 100, frozen: 20))
        // The restart target is a LOWER bound, not a point: it aims at the segment containing the
        // requested time, so a landing above it is still a landing (seektest: restart 84.0, landing 90.0).
        #expect(AetherEngine.nativeScrubLanded(rendered: 106, target: 100, frozen: 20))
        #expect(AetherEngine.nativeScrubLanded(rendered: 130, target: 100, frozen: 20))
        // The frozen pre-scrub picture must never read as a landing, nor must the old buffer draining
        // forward under a pending seek.
        #expect(!AetherEngine.nativeScrubLanded(rendered: 20, target: 100, frozen: 20))
        #expect(!AetherEngine.nativeScrubLanded(rendered: 25, target: 100, frozen: 20))
    }

    @Test("a backward scrub does not accept the still-ahead pre-scrub playhead")
    func scrubLandingBackward() {
        // Backward scrub from 900 to the segment starting at 100.
        #expect(!AetherEngine.nativeScrubLanded(rendered: 900, target: 100, frozen: 900))
        #expect(!AetherEngine.nativeScrubLanded(rendered: 905, target: 100, frozen: 900))  // old buffer draining
        #expect(AetherEngine.nativeScrubLanded(rendered: 101, target: 100, frozen: 900))
        #expect(AetherEngine.nativeScrubLanded(rendered: 200, target: 100, frozen: 900))
        // Below the restarted region is not a landing in it.
        #expect(!AetherEngine.nativeScrubLanded(rendered: 50, target: 100, frozen: 900))
    }

    @Test("a non-finite rendered position is never a landing")
    func scrubLandingRejectsGarbage() {
        #expect(!AetherEngine.nativeScrubLanded(rendered: .nan, target: 100, frozen: 20))
        #expect(!AetherEngine.nativeScrubLanded(rendered: .infinity, target: .nan, frozen: 20))
    }

    @MainActor
    @Test("the armed landing watch closes the scrub only once the picture reaches the target")
    func scrubWatchClosesOnPicture() async throws {
        let engine = try AetherEngine()
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        engine.nativeScrubSeekTicket = AetherEngine.SeekTicket(id: 7, target: 100, origin: .nativeScrub)
        engine.pendingScrubLanding = AetherEngine.PendingScrubLanding(
            displayTarget: 100, playlistTarget: 100, frozenRendered: 20)

        engine.checkPendingScrubLanding(rendered: 30)      // producer restarted, picture still behind
        #expect(events.isEmpty)
        #expect(engine.pendingScrubLanding != nil)

        engine.checkPendingScrubLanding(rendered: 101)     // picture arrived
        #expect(events.count == 1)
        #expect(events.first?.id == 7)
        if case .landed(let rendered) = events[0].outcome {
            #expect(rendered == 101)
        } else {
            Issue.record("expected a landing, got \(events[0])")
        }
        #expect(engine.pendingScrubLanding == nil)
        #expect(engine.isSeeking == false)
    }

    @MainActor
    @Test("a scrub restart opens and closes a ticket, and records who owns the restart")
    func scrubTicketLifecycle() async throws {
        let engine = try AetherEngine()
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        engine.setNativeScrubSeek(inFlight: true, target: 84)
        #expect(engine.isSeeking)
        #expect(engine.seekTarget == 84)
        // No programmatic seek is in flight, so this restart is a user scrub and the landing watch owns it.
        #expect(engine.scrubRestartOwnedByProgrammaticSeek == false)

        // Without a native host there is nothing to watch, so the drain settles it as before.
        engine.setNativeScrubSeek(inFlight: false, target: nil)
        #expect(engine.isSeeking == false)
        #expect(engine.seekTarget == nil)
        #expect(events.map(\.origin) == [.nativeScrub, .nativeScrub])
        #expect(events.first?.outcome == .began)
        if case .landed = events[1].outcome {} else { Issue.record("expected a landing, got \(events[1])") }
    }

    // MARK: - The give-up, and the late landing a level signal cannot carry

    @MainActor
    @Test("a stalled seek keeps its ticket so the late landing arrives under the same id")
    func stalledSeekLandsLate() async throws {
        let engine = try AetherEngine()
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        engine.programmaticSeekTicket = AetherEngine.SeekTicket(id: 11, target: 1288, origin: .programmatic)
        engine.reportSeekStalled()                       // budget spent, clock parked at the target
        #expect(events.map(\.outcome) == [.stalled])

        engine.finalizeLateRecoverySeekLanding(rendered: 1286.4)   // source finally served it

        #expect(events.count == 2)
        #expect(events[1].id == 11)
        if case .landed(let rendered) = events[1].outcome {
            #expect(rendered == 1286.4)
        } else {
            Issue.record("expected a late landing, got \(events[1])")
        }
    }

    @MainActor
    @Test("a landed seek is not reported twice when the sink settles behind it")
    func noDoubleLandingReport() async throws {
        let engine = try AetherEngine()
        var events: [SeekEvent] = []
        let sub = engine.seekEvents.sink { events.append($0) }
        defer { sub.cancel() }

        engine.programmaticSeekTicket = AetherEngine.SeekTicket(id: 12, target: 500, origin: .programmatic)
        engine.finalizeLateRecoverySeekLanding(rendered: 500.2)
        engine.finalizeLateRecoverySeekLanding(rendered: 500.4)   // a second tick through the same hook

        #expect(events.count == 1)
    }
}
