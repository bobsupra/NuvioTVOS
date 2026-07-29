import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// #231 (rrgomes, from a session that logged `cancelled=false harvested=22` mid-playback with
/// nothing bringing the reader back): the #151 prefetcher left its loop on the first failed read,
/// via `guard let pkt = try? demuxer.readPacket() else { break }`. That guard cannot tell EOF from
/// an error, so a transport failure on the side reader, a stall that exhausts the read deadline or
/// a reconnect that gives up all ended the session for good. The only thing that started a new one
/// was `prefetchNeedsReanchor` on a drain-tick jump, which means a seek or a producer re-anchor: a
/// viewer who does not seek never got the reader back, and subtitles beyond the pump's own forward
/// park quietly starved for the rest of the session with no signal of their own.
///
/// Two parts: distinguish EOF from an error at the exit, and restart on error, bounded.
struct Issue231PrefetchRestartTests {

    // MARK: - EOF is not an error

    /// The exit reason has to survive to the caller for any of the rest to be possible. EOF and
    /// cancellation are covered in Issue151SubtitleForwardPrefetchTests; this is the error.
    @Test("a failed read exits as readFailed, not as an EOF")
    func readErrorIsDistinguishedFromEOF() async throws {
        // Long enough that the loop outlives libavformat's read-ahead buffer and has to refill from
        // the reader: the failure has to land mid-session, not during open.
        let events = (0..<4_000).map { (ms: 1_000 + $0 * 100, durationMs: 500) }
        let fixture = MatroskaSubtitleFixture.make(durationMs: 500_000, events: events)
        let reader = FailingIOReader(data: fixture)
        let demuxer = Demuxer()
        try demuxer.open(reader: reader, formatHint: "matroska")
        defer { demuxer.close() }

        // Arm only now: open and find_stream_info do their own reads, and the defect is about a
        // side connection dropping mid-playback. Returning a negative value (not 0) is what
        // separates that from EOF at the CustomIOReaderBridge boundary.
        reader.armFailure()

        let store = SubtitlePacketStore()
        let outcome = await SubtitleForwardPrefetcher.run(
            demuxer: demuxer, store: store,
            streamIndices: [0], assemblyIndices: [],
            pacingIndex: -1,
            leadSeconds: 3600, parkPollNanoseconds: 1_000_000,
            playhead: { 0.0 })

        #expect(outcome.exit == .readFailed,
                "a mid-session read failure must not look like the end of the source")
        #expect(outcome.exit.isRestartable)
    }

    /// The classification the restart loop acts on. EOF is the expected end of a prefetch session,
    /// cancellation is deliberate, and a source that will not open is the documented best-effort
    /// case; none of them should reconnect.
    @Test("only a read failure is restartable")
    func onlyReadFailureIsRestartable() {
        #expect(SubtitleForwardPrefetcher.Exit.readFailed.isRestartable)
        #expect(!SubtitleForwardPrefetcher.Exit.endOfFile.isRestartable)
        #expect(!SubtitleForwardPrefetcher.Exit.cancelled.isRestartable)
        #expect(!SubtitleForwardPrefetcher.Exit.openFailed.isRestartable)
    }

    // MARK: - Restart budget

    private static func budget(maxConsecutive: Int = 3, maxRestarts: Int = 8)
    -> SubtitleForwardPrefetcher.RestartBudget {
        SubtitleForwardPrefetcher.RestartBudget(
            maxConsecutiveFailures: maxConsecutive, maxRestarts: maxRestarts,
            backoffNanoseconds: 1_000_000_000)
    }

    /// A dead link: nothing harvested between failures, so the budget runs out quickly rather than
    /// hammering a source that is not coming back.
    @Test("consecutive barren failures exhaust the budget and back off further each time")
    func barrenFailuresExhaustTheBudget() {
        var budget = Self.budget()
        #expect(budget.chargeFailure(harvested: 0) == 1_000_000_000)
        #expect(budget.chargeFailure(harvested: 0) == 2_000_000_000)
        #expect(budget.chargeFailure(harvested: 0) == 4_000_000_000)
        #expect(budget.chargeFailure(harvested: 0) == nil, "the fourth is past the ceiling")
        #expect(budget.consecutiveFailures == 4)
    }

    /// A session that produced cues and only then broke is a fresh transport failure, not the tail
    /// of a dying link, so it gets a fresh budget. This is the reporter's shape: harvested=22, then
    /// the reader died.
    @Test("a productive session resets the consecutive-failure budget")
    func productiveSessionResetsBudget() {
        var budget = Self.budget()
        _ = budget.chargeFailure(harvested: 0)
        _ = budget.chargeFailure(harvested: 0)
        #expect(budget.consecutiveFailures == 2)

        #expect(budget.chargeFailure(harvested: 22) == 1_000_000_000,
                "a session that harvested cues starts the backoff over")
        #expect(budget.consecutiveFailures == 1)
        #expect(budget.chargeFailure(harvested: 0) == 2_000_000_000)
    }

    /// The reset must not become a licence to reconnect forever: a source that fails in a loop
    /// after harvesting one packet each time hits the total ceiling instead.
    @Test("the total ceiling bounds a source that fails in a loop")
    func totalCeilingBoundsRepeatedProductiveFailures() {
        var budget = Self.budget(maxRestarts: 4)
        for attempt in 1...4 {
            #expect(budget.chargeFailure(harvested: 1) != nil, "attempt \(attempt) is within budget")
        }
        #expect(budget.chargeFailure(harvested: 1) == nil,
                "a resetting budget must still stop at the total ceiling")
        #expect(budget.restarts == 5)
    }

    /// Engine defaults must be self-consistent: a run of barren failures has to be reachable before
    /// the total ceiling, or the consecutive limit would be dead configuration.
    @Test("engine defaults leave the consecutive limit reachable")
    func engineDefaultsAreConsistent() {
        #expect(AetherEngine.subtitleForwardPrefetchMaxConsecutiveFailures
                <= AetherEngine.subtitleForwardPrefetchMaxRestarts)
        #expect(AetherEngine.subtitleForwardPrefetchMaxConsecutiveFailures > 0)
        #expect(AetherEngine.subtitleForwardPrefetchRestartBackoffNanoseconds > 0)
    }
}

/// Serves `data` normally until armed, then reports a hard error on every read. The in-memory
/// stand-in for the reporter's side connection dropping mid-playback.
private final class FailingIOReader: IOReader, @unchecked Sendable {
    private let data: Data
    private var position = 0
    private var armed = false
    private let lock = NSLock()

    init(data: Data) {
        self.data = data
    }

    func armFailure() {
        lock.lock(); armed = true; lock.unlock()
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        lock.lock()
        defer { lock.unlock() }
        guard !armed else { return -1 }
        guard position < data.count else { return 0 }
        let n = min(Int(size), data.count - position)
        data.copyBytes(to: UnsafeMutableBufferPointer(start: buffer, count: n),
                       from: position..<(position + n))
        position += n
        return Int32(n)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return Int64(data.count) }
        lock.lock()
        defer { lock.unlock() }
        let target: Int
        switch whence {
        case SEEK_SET: target = Int(offset)
        case SEEK_CUR: target = position + Int(offset)
        case SEEK_END: target = data.count + Int(offset)
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = min(target, data.count)
        return Int64(position)
    }

    func close() {}
}
