// Tests/AetherEngineTests/Issue377FoldWitnessTests.swift
// AE#377 round 4: the fold line was handed to the reporter as a witness that a fresh redirect
// target had been REACHED, and a grep for it between the pin drop and the exhaustion was read as
// ruling the metering shape out. It cannot carry that. `chainHead` is process-wide and only ever
// grows (`resetForTesting` is its sole reset), so the line fires on a target's FIRST fold in the
// process and every later hop through that same target is silent. On a source that rotates over a
// pool of edge hosts, most of the pool is already folded within minutes, so an absent line is
// compatible with any number of hops through an already-known target. The line has to say that
// about itself, because the reader of a trace has no other way to know it.
import XCTest
@testable import AetherEngine

private final class Issue377FoldLogTap: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let previous: ((String) -> Void)?

    init() {
        previous = EngineLog.handler
        let sink = { [self] (line: String) in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
        EngineLog.handler = sink
    }

    func restore() { EngineLog.handler = previous }

    func matching(_ needle: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines.filter { $0.contains(needle) }
    }
}

final class Issue377FoldWitnessTests: XCTestCase {

    private let source = URL(string: "https://proxy.example.dev/stream/abc?token=one")!
    private let target = URL(string: "https://nexus-097.cdn.example.st/file.mkv?sig=aaa")!

    private var tap: Issue377FoldLogTap!

    override func setUp() {
        super.setUp()
        OriginRequestBudget.shared.resetForTesting()
        tap = Issue377FoldLogTap()
    }

    override func tearDown() {
        tap.restore()
        tap = nil
        OriginRequestBudget.shared.resetForTesting()
        super.tearDown()
    }

    /// The property that makes an absent line uninformative: the second hop through a target the
    /// chain already holds logs nothing, and a re-minted link for that host is the same origin.
    func testASecondHopThroughAKnownTargetIsSilent() {
        OriginRequestBudget.shared.noteRedirect(from: source, to: target)
        let reMinted = URL(string: "https://nexus-097.cdn.example.st/file.mkv?sig=zzz")!
        OriginRequestBudget.shared.noteRedirect(from: source, to: reMinted)

        XCTAssertEqual(tap.matching("is served through").count, 1)
    }

    /// So the one line that does fire has to name its own scope. Whoever greps a capture for it is
    /// otherwise reading a first-contact record as a per-hop record, which is what cost this round.
    func testTheFoldLineNamesItsOwnScope() {
        OriginRequestBudget.shared.noteRedirect(from: source, to: target)

        let folds = tap.matching("is served through")
        XCTAssertEqual(folds.count, 1)
        XCTAssertTrue(folds[0].contains("absent line is not an absent hop"), folds[0])
    }
}
