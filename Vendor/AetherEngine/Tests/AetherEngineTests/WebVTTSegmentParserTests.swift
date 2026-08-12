import XCTest
@testable import AetherEngine

/// AE#359. Fixtures are real MDR Sachsen segments off `master-subs-1200.m3u8`, including their 164
/// hour LOCAL clock. The numbers a cue carries mean nothing on their own, and X-TIMESTAMP-MAP does
/// not rescue them either: measured against this provider its anchor sits two hours off the picture.
/// What places a cue is the segment it arrived in, see the mapping tests below.
final class WebVTTSegmentParserTests: XCTestCase {

    private let seg133 = """
    WEBVTT
    X-TIMESTAMP-MAP=LOCAL:159:04:22.306,MPEGTS:183000

    164:04:24.000 --> 164:04:25.440
    Alles klar?
    - Ja, ja.

    164:04:25.920 --> 164:04:26.000
    Fahren wir in die Sachsenklinik!
    - Nein, es geht gleich wieder.
    """

    private let seg134 = """
    WEBVTT
    X-TIMESTAMP-MAP=LOCAL:159:04:22.306,MPEGTS:183000

    164:04:26.000 --> 164:04:28.000
    Fahren wir in die Sachsenklinik!
    - Nein, es geht gleich wieder.
    """

    private func seconds(_ h: Double, _ m: Double, _ s: Double) -> Double { h * 3600 + m * 60 + s }

    // MARK: - Parsing

    func testReadsTheTimestampMapAndBothCues() throws {
        let segment = try XCTUnwrap(WebVTTSegmentParser.parse(seg133))
        XCTAssertEqual(segment.anchorMPEGTS90k, 183_000)
        XCTAssertEqual(segment.anchorLocalSeconds, seconds(159, 4, 22.306), accuracy: 0.001)
        XCTAssertEqual(segment.cues.count, 2)
        XCTAssertEqual(segment.cues.first?.text, "Alles klar?\n- Ja, ja.")
        XCTAssertEqual(segment.cues.first?.start ?? 0, seconds(164, 4, 24.0), accuracy: 0.001)
        XCTAssertEqual(segment.cues.first?.end ?? 0, seconds(164, 4, 25.44), accuracy: 0.001)
    }

    /// Without the map there is no way to place a cue on the program clock, and taking the numbers at
    /// face value would put subtitles hours away from the picture. Refusing is the honest outcome.
    func testRefusesASegmentWithoutATimestampMap() {
        XCTAssertNil(WebVTTSegmentParser.parse("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi"))
    }

    func testAcceptsTheMapWithItsFieldsInEitherOrder() throws {
        let text = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:10.000\n\n00:00:11.000 --> 00:00:12.000\nhi"
        let segment = try XCTUnwrap(WebVTTSegmentParser.parse(text))
        XCTAssertEqual(segment.anchorMPEGTS90k, 900_000)
        XCTAssertEqual(segment.anchorLocalSeconds, 10, accuracy: 0.001)
    }

    /// Cue settings sit on the timing line and are not dialogue; an identifier may precede it.
    func testIgnoresCueIdentifiersAndSettings() throws {
        let text = """
        WEBVTT
        X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0

        cue-7
        00:00:01.000 --> 00:00:02.000 line:0 position:50%
        Text
        """
        let segment = try XCTUnwrap(WebVTTSegmentParser.parse(text))
        XCTAssertEqual(segment.cues.count, 1)
        XCTAssertEqual(segment.cues.first?.text, "Text")
    }

    // MARK: - Mapping onto the player clock

    private let anchorWall = Date(timeIntervalSince1970: 1_000_000)

    private func cues(_ segment: WebVTTSegment, segmentOffset: Double, anchorEngineTime: Double = 100,
                      duration: Double = 2, nextID: inout Int) -> [SubtitleCue] {
        WebVTTSegmentParser.cues(from: segment,
                                 segmentWallStart: anchorWall.addingTimeInterval(segmentOffset),
                                 segmentDuration: duration,
                                 anchorWall: anchorWall,
                                 anchorEngineTime: anchorEngineTime,
                                 nextID: &nextID)
    }

    /// A cue lands at its segment's distance from the joined segment, plus its offset inside that
    /// segment. The LOCAL clock's absolute value is irrelevant, which is the whole point: on MDR it
    /// sits at 164 hours and its X-TIMESTAMP-MAP anchor is two hours off the picture.
    func testACueLandsAtItsSegmentPlusItsOffsetInside() throws {
        let segment = try XCTUnwrap(WebVTTSegmentParser.parse(seg133))
        var nextID = 0
        let mapped = cues(segment, segmentOffset: 30, nextID: &nextID)
        // 164:04:24.000 sits 0 s into the 2 s segment starting at 164:04:24.
        XCTAssertEqual(mapped.first?.startTime ?? 0, 130, accuracy: 0.001)
        // 164:04:25.920 sits 1.92 s into that same segment.
        XCTAssertEqual(mapped.last?.startTime ?? 0, 131.92, accuracy: 0.001)
    }

    func testCueDurationSurvivesTheMapping() throws {
        let segment = try XCTUnwrap(WebVTTSegmentParser.parse(seg133))
        var nextID = 0
        let mapped = cues(segment, segmentOffset: 0, nextID: &nextID)
        XCTAssertEqual((mapped.first?.endTime ?? 0) - (mapped.first?.startTime ?? 0), 1.44, accuracy: 0.001)
    }

    /// The offset inside a segment can never exceed the segment, whatever phase the provider's LOCAL
    /// clock runs on. Without the clamp a misaligned grid would push cues into the next segment.
    func testTheOffsetInsideASegmentIsClamped() throws {
        let text = """
        WEBVTT
        X-TIMESTAMP-MAP=LOCAL:00:00:00.000,MPEGTS:0

        00:00:07.500 --> 00:00:08.000
        late
        """
        let segment = try XCTUnwrap(WebVTTSegmentParser.parse(text))
        var nextID = 0
        let mapped = cues(segment, segmentOffset: 0, duration: 2, nextID: &nextID)
        XCTAssertLessThanOrEqual(mapped.first?.startTime ?? 0, 102)
        XCTAssertGreaterThanOrEqual(mapped.first?.startTime ?? 0, 100)
    }

    // MARK: - Cross-segment repeats

    func testACueRepeatedInTheNextSegmentExtendsTheExistingOne() throws {
        var nextID = 0
        let first = cues(try XCTUnwrap(WebVTTSegmentParser.parse(seg133)), segmentOffset: 0, nextID: &nextID)
        let second = cues(try XCTUnwrap(WebVTTSegmentParser.parse(seg134)), segmentOffset: 2, nextID: &nextID)
        let merged = WebVTTSegmentParser.merged(into: first, adding: second, nextID: &nextID)
        XCTAssertEqual(merged.count, 2, "the repeated line must extend its cue, not become a third one")
        let last = try XCTUnwrap(merged.last)
        XCTAssertEqual(last.endTime - last.startTime, 2.08, accuracy: 0.01)
    }

    func testADifferentLineIsAppended() throws {
        var nextID = 0
        let first = cues(try XCTUnwrap(WebVTTSegmentParser.parse(seg133)), segmentOffset: 0, nextID: &nextID)
        let other = """
        WEBVTT
        X-TIMESTAMP-MAP=LOCAL:159:04:22.306,MPEGTS:183000

        164:04:26.000 --> 164:04:28.000
        Etwas ganz anderes
        """
        let second = cues(try XCTUnwrap(WebVTTSegmentParser.parse(other)), segmentOffset: 2, nextID: &nextID)
        XCTAssertEqual(WebVTTSegmentParser.merged(into: first, adding: second, nextID: &nextID).count, 3)
    }

    /// Refetching the same segment (playlist poll before the window moved) must change nothing.
    func testResendingTheSameSegmentIsIdempotent() throws {
        var nextID = 0
        let batch = cues(try XCTUnwrap(WebVTTSegmentParser.parse(seg133)), segmentOffset: 0, nextID: &nextID)
        let again = cues(try XCTUnwrap(WebVTTSegmentParser.parse(seg133)), segmentOffset: 0, nextID: &nextID)
        let merged = WebVTTSegmentParser.merged(into: batch, adding: again, nextID: &nextID)
        XCTAssertEqual(merged.count, batch.count)
    }
}
