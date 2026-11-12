import XCTest
@testable import NuvioTV

final class ReshapedSyncDocTests: XCTestCase {
    typealias JSON = ReshapedSyncDoc.JSONValue
    typealias Entry = ReshapedSyncDoc.Entry

    func testDecodePreservesUnknownSectionsAndDistinguishesNullFromTombstone() throws {
        let source = #"{"v":1,"s":{"future/section":{"nested":{"v":{"items":[true,null,7,"text"]},"t":42},"json-null":{"v":null,"t":43},"deleted":{"t":44}}}}"#
        let decoded = try ReshapedSyncDoc.decode(source)

        XCTAssertEqual(decoded["future/section"]?["nested"], Entry(value: .object([
            "items": .array([.boolean(true), .null, .integer(7), .string("text")]),
        ]), time: 42))
        XCTAssertEqual(decoded["future/section"]?["json-null"], Entry(value: .null, time: 43))
        XCTAssertEqual(decoded["future/section"]?["deleted"], Entry(value: nil, time: 44))
        XCTAssertEqual(try ReshapedSyncDoc.decode(ReshapedSyncDoc.encode(decoded)), decoded)
    }

    func testMalformedDocumentsAndEntriesAreIgnoredButNewerVersionsAreRejected() throws {
        XCTAssertEqual(try ReshapedSyncDoc.decode(nil), [:])
        XCTAssertEqual(try ReshapedSyncDoc.decode("not json"), [:])
        XCTAssertEqual(try ReshapedSyncDoc.decode(#"{"v":1,"s":{"unknown":false,"valid":{"bad":{"v":true},"good":{"v":1,"t":5}}}}"#), [
            "valid": ["good": Entry(value: .integer(1), time: 5)],
        ])
        XCTAssertThrowsError(try ReshapedSyncDoc.decode(#"{"v":2,"s":{}}"#)) { error in
            XCTAssertEqual(error as? ReshapedSyncDoc.DecodeError, .newerFormat)
        }
    }

    func testStampKeepsUnknownSectionsAndUsesZeroForNewSections() {
        let base: ReshapedSyncDoc.Sections = [
            "other-device": ["keep": Entry(value: .string("retained"), time: 5)],
            "settings": [
                "same": Entry(value: .boolean(true), time: 10),
                "edit": Entry(value: .string("old"), time: 11),
                "delete": Entry(value: .integer(1), time: 12),
            ],
        ]
        let result = ReshapedSyncDoc.stamp(base: base, current: [
            "settings": ["same": .boolean(true), "edit": .string("new"), "new": .null],
            "new-section": ["default": .boolean(false)],
        ], now: 100)

        XCTAssertEqual(result["other-device"], base["other-device"])
        XCTAssertEqual(result["settings"]?["same"], Entry(value: .boolean(true), time: 10))
        XCTAssertEqual(result["settings"]?["edit"], Entry(value: .string("new"), time: 100))
        XCTAssertEqual(result["settings"]?["delete"], Entry(value: nil, time: 100))
        XCTAssertEqual(result["settings"]?["new"], Entry(value: .null, time: 100))
        XCTAssertEqual(result["new-section"]?["default"], Entry(value: .boolean(false), time: 0))
    }

    func testMergeUsesLatestEntryAndRightSideWinsTies() {
        let left: ReshapedSyncDoc.Sections = [
            "s": ["tie": Entry(value: .string("left"), time: 3), "left-only": Entry(value: .integer(1), time: 1)],
        ]
        let right: ReshapedSyncDoc.Sections = [
            "s": ["tie": Entry(value: .string("right"), time: 3), "newer": Entry(value: .integer(2), time: 9)],
        ]

        XCTAssertEqual(ReshapedSyncDoc.merge(left, right)["s"], [
            "tie": Entry(value: .string("right"), time: 3),
            "left-only": Entry(value: .integer(1), time: 1),
            "newer": Entry(value: .integer(2), time: 9),
        ])
    }

    func testPruneAndStampTimeRespectTombstoneBoundariesAndSeenEdits() {
        let now: Int64 = 10_000_000
        let old = now - ReshapedSyncDoc.tombstoneRetentionMilliseconds
        let sections: ReshapedSyncDoc.Sections = [
            "s": [
                "old-delete": Entry(value: nil, time: old),
                "recent-delete": Entry(value: nil, time: old + 1),
                "future-delete": Entry(value: nil, time: now + 50),
                "old-value": Entry(value: .string("keep"), time: old),
            ],
            "empty-after-prune": ["old-delete": Entry(value: nil, time: old)],
        ]
        let pruned = ReshapedSyncDoc.prune(sections, now: now)

        XCTAssertNil(pruned["empty-after-prune"])
        XCTAssertNil(pruned["s"]?["old-delete"])
        XCTAssertEqual(pruned["s"]?["recent-delete"], Entry(value: nil, time: old + 1))
        XCTAssertEqual(pruned["s"]?["future-delete"], Entry(value: nil, time: now + 50))
        XCTAssertEqual(pruned["s"]?["old-value"], Entry(value: .string("keep"), time: old))
        XCTAssertEqual(ReshapedSyncDoc.stampTime(clock: 1, seen: sections), now + 51)
        XCTAssertEqual(ReshapedSyncDoc.stampTime(clock: now + 100), now + 100)
    }
}
