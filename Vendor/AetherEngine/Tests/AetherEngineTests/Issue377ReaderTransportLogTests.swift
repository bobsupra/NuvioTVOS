// Tests/AetherEngineTests/Issue377ReaderTransportLogTests.swift
// AE#377: the transport line answered its question in the field (the reporter's CDN turned out to be
// http/1.1, so a connection cap does bind there), but the reuse half of the same line could not be read.
// It was emitted at the FIRST metrics callback for an origin, where "connection new" is what a first
// connection nearly always is, so it said "new" for every http/1.1 origin regardless of whether the
// session went on to reuse that connection a hundred times. These tests pin that the transport verdict
// still lands on the first connection, and that reuse is only claimed once there is a sample behind it.
import XCTest
@testable import AetherEngine

/// Captures `EngineLog` lines for one test. The handler is global, so it is restored on every path.
private final class Issue377LogTap: @unchecked Sendable {
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

final class Issue377ReaderTransportLogTests: XCTestCase {

    private var tap: Issue377LogTap!

    override func setUp() {
        super.setUp()
        ReaderTransportLog.resetForTesting()
        tap = Issue377LogTap()
    }

    override func tearDown() {
        tap.restore()
        tap = nil
        ReaderTransportLog.resetForTesting()
        super.tearDown()
    }

    // MARK: The transport verdict

    func testTransportLineLandsOnTheFirstConnectionAndOnlyOnce() {
        for _ in 0..<5 {
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: true,
                                    originKey: "https://cdn.example.com")
        }
        XCTAssertEqual(tap.matching("origin transport:").count, 1)
    }

    func testMultiplexedTransportSaysAConnectionCapBoundsNothing() {
        ReaderTransportLog.note(protocolName: "h2", reusedConnection: false,
                                originKey: "https://cdn.example.com")
        let line = tap.matching("origin transport:").first ?? ""
        XCTAssertTrue(line.contains("h2"), line)
        XCTAssertTrue(line.contains("bounds nothing"), line)
    }

    func testSerialTransportSaysAConnectionCapBoundsRequests() {
        ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: false,
                                originKey: "https://nexus-128.example.st")
        let line = tap.matching("origin transport:").first ?? ""
        XCTAssertTrue(line.contains("http/1.1"), line)
        XCTAssertTrue(line.contains("one request per connection"), line)
        XCTAssertTrue(line.contains("bounds requests"), line)
    }

    func testTransportVerdictIsPerOrigin() {
        ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: false,
                                originKey: "https://portal.example.com")
        ReaderTransportLog.note(protocolName: "h2", reusedConnection: false,
                                originKey: "https://cdn.example.com")
        XCTAssertEqual(tap.matching("origin transport:").count, 2)
    }

    // MARK: The reuse tally

    /// The defect this file exists for: a first connection is not evidence about reuse, so nothing may
    /// be claimed about it yet.
    func testNoReuseClaimBeforeThereIsASample() {
        ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: false,
                                originKey: "https://cdn.example.com")
        XCTAssertTrue(tap.matching("origin connections:").isEmpty)
        XCTAssertFalse(tap.matching("origin transport:").first?.contains("connection new") ?? false)
    }

    func testReuseIsReportedOnceTheSampleIsInAndCountsBothSides() {
        let size = ReaderTransportLog.reuseSampleSize
        ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: false,
                                originKey: "https://cdn.example.com")
        for _ in 1..<size {
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: true,
                                    originKey: "https://cdn.example.com")
        }
        let line = tap.matching("origin connections:").first ?? ""
        XCTAssertTrue(line.contains("\(size - 1) of \(size) reader connections reused"), line)
    }

    func testAnOriginThatNeverReusesSaysWhatThatCosts() {
        for _ in 0..<ReaderTransportLog.reuseSampleSize {
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: false,
                                    originKey: "https://cdn.example.com")
        }
        let line = tap.matching("origin connections:").first ?? ""
        XCTAssertTrue(line.contains("0 of \(ReaderTransportLog.reuseSampleSize)"), line)
        XCTAssertTrue(line.contains("fresh handshake"), line)
    }

    /// One line per origin, like the transport line: a session reconnecting for an hour must not turn
    /// this into a per-connection trace.
    func testReuseIsReportedOnlyOncePerOrigin() {
        for _ in 0..<(ReaderTransportLog.reuseSampleSize * 4) {
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: true,
                                    originKey: "https://cdn.example.com")
        }
        XCTAssertEqual(tap.matching("origin connections:").count, 1)
    }

    func testTalliesDoNotBleedBetweenOrigins() {
        for _ in 0..<(ReaderTransportLog.reuseSampleSize - 1) {
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: true,
                                    originKey: "https://portal.example.com")
            ReaderTransportLog.note(protocolName: "http/1.1", reusedConnection: true,
                                    originKey: "https://cdn.example.com")
        }
        XCTAssertTrue(tap.matching("origin connections:").isEmpty,
                      "two origins one connection short of the sample must not add up to one sample")
    }
}
