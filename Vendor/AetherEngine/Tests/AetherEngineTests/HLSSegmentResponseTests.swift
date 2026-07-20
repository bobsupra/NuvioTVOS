import Testing
@testable import AetherEngine

/// #50: in-range cache miss must not surface as a fatal 404 (AVPlayer treats VOD 404 as terminal
/// loadFailed). Only index >= segmentCount is genuinely not found; [0, segmentCount) is retriable.
@Suite("Segment response classification (#50)")
struct HLSSegmentResponseTests {

    @Test("Present data serves regardless of index")
    func presentDataServes() {
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 5, segmentCount: 110, hasData: true) == .serve)
        // Even past the count: serve if bytes exist (live list can grow between count-read and fetch).
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 200, segmentCount: 110, hasData: true) == .serve)
    }

    @Test("In-range miss is retriable, not 404 (the #50 wedge)")
    func inRangeMissIsRetriable() {
        // rrgomes' device indices: all < segmentCount, evicted from the ~16-19-segment live window.
        for idx in [0, 7, 19, 21, 33, 66, 93, 109] {
            #expect(HLSLocalServer.classifySegmentResponse(
                index: idx, segmentCount: 110, hasData: false) == .retryLater,
                "seg\(idx) is in-range (< 110) and must be retriable, never 404")
        }
    }

    @Test("Out-of-range miss is a genuine 404")
    func outOfRangeMissIsNotFound() {
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 110, segmentCount: 110, hasData: false) == .notFound)
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 250, segmentCount: 110, hasData: false) == .notFound)
    }

    @Test("Unknown segment count (provider not ready) is a 404, not a hang")
    func unknownCountIsNotFound() {
        // provider == nil -> segmentCount = -1; nothing is in-range.
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 0, segmentCount: -1, hasData: false) == .notFound)
        #expect(HLSLocalServer.classifySegmentResponse(
            index: 5, segmentCount: 0, hasData: false) == .notFound)
    }
}
