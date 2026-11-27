import Foundation
import XCTest
@testable import NuvioTV

final class UsenetTuneTests: XCTestCase {
    private func reading(_ connections: Int, _ mbps: Double, port: Int = 563) -> UsenetTuneReading {
        UsenetTuneReading(port: port, connections: connections, megabitsPerSecond: mbps)
    }

    func testTheProbeReachesAtLeastTheSetCount() {
        XCTAssertEqual(UsenetTunePlan.probeCap(allowance: 20), 100)
        XCTAssertEqual(UsenetTunePlan.probeCap(allowance: 150), 150)
        XCTAssertEqual(UsenetTunePlan.probeCap(allowance: 500), 200)
    }

    func testALimitLeavesRoomForAnotherDevice() {
        XCTAssertEqual(UsenetTunePlan.usable(limit: 50, tried: 50), 45)
        XCTAssertEqual(UsenetTunePlan.usable(limit: 8, tried: 8), 7)
        XCTAssertEqual(UsenetTunePlan.usable(limit: 1, tried: 1), 1)
        XCTAssertEqual(UsenetTunePlan.usable(limit: nil, tried: 100), 100)
    }

    func testTheLadderEndsAtTheUsableCount() {
        XCTAssertEqual(UsenetTunePlan.ladder(usable: 45), [4, 8, 12, 16, 24, 32, 45])
        XCTAssertEqual(UsenetTunePlan.ladder(usable: 16), [4, 8, 12, 16])
        XCTAssertEqual(UsenetTunePlan.ladder(usable: 3), [3])
    }

    func testEncryptedPortsStayEncrypted() {
        XCTAssertEqual(UsenetTunePlan.ports(port: 563, useSSL: true), [563, 443])
        XCTAssertEqual(UsenetTunePlan.ports(port: 443, useSSL: true), [443, 563])
        XCTAssertEqual(UsenetTunePlan.ports(port: 119, useSSL: false), [119])
        XCTAssertEqual(UsenetTunePlan.ports(port: 8080, useSSL: false), [8080, 119])
    }

    func testAnotherPortOnlyWhenClearlyFaster() {
        XCTAssertEqual(UsenetTunePlan.bestPort(current: 563, readings: [reading(8, 100), reading(8, 105, port: 443)]), 563)
        XCTAssertEqual(UsenetTunePlan.bestPort(current: 563, readings: [reading(8, 100), reading(8, 130, port: 443)]), 443)
        // The current port didn't connect: the one that did.
        XCTAssertEqual(UsenetTunePlan.bestPort(current: 563, readings: [reading(8, 80, port: 443)]), 443)
    }

    func testTheRoundStopsWhenMoreConnectionsStopHelping() {
        XCTAssertFalse(UsenetTunePlan.flattened([100, 180]))
        XCTAssertFalse(UsenetTunePlan.flattened([100, 180, 250]))
        XCTAssertTrue(UsenetTunePlan.flattened([100, 180, 182, 183]))
        XCTAssertFalse(UsenetTunePlan.flattened([100, 180, 182, 240]))
    }

    func testTheFewestConnectionsNearTheBest() {
        let readings = [reading(4, 120), reading(8, 230), reading(12, 300), reading(16, 310), reading(24, 312)]
        XCTAssertEqual(UsenetTunePlan.fastestConnections(readings), 12)
        XCTAssertNil(UsenetTunePlan.fastestConnections([]))
    }

    func testRecommendation() {
        let speeds: [Int: Double] = [4: 120, 8: 230, 12: 300, 16: 310, 20: 311]
        // Clearly faster with more: raised.
        XCTAssertEqual(UsenetTunePlan.recommend(current: 8, fastest: 12, limit: nil, tried: 100, speeds: speeds), 12)
        // As fast already: kept, not lowered.
        XCTAssertEqual(UsenetTunePlan.recommend(current: 20, fastest: 12, limit: nil, tried: 100, speeds: speeds), 20)
        // Over the plan's limit: brought within it.
        XCTAssertEqual(UsenetTunePlan.recommend(current: 60, fastest: 12, limit: 30, tried: 30, speeds: speeds), 27)
    }

    func testTheTestArticlesComeFromTheNZB() throws {
        let nzb = Data("""
            <?xml version="1.0" encoding="UTF-8"?><nzb xmlns="http://www.newzbin.com/DTD/2003/nzb">
            <file poster="a@b" date="0" subject="[1/2] - &quot;test.bin&quot; yEnc (1/2)"><groups><group>alt.binaries.test</group></groups>
            <segments><segment bytes="700" number="2">a2@x</segment><segment bytes="700" number="1">a1@x</segment></segments></file>
            <file poster="a@b" date="0" subject="[2/2] - &quot;test.par2&quot; yEnc (1/1)"><groups><group>alt.binaries.test</group></groups>
            <segments><segment bytes="10" number="1">p@x</segment></segments></file>
            </nzb>
            """.utf8)
        XCTAssertEqual(UsenetTunePlan.messageIDs(nzb), ["a1@x", "a2@x", "p@x"])
        XCTAssertEqual(UsenetTunePlan.messageIDs(Data("not an nzb".utf8)), [])
    }
}
