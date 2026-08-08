import Testing
@testable import AetherEngine

/// #260: the source/item axis relation is a step function of item time, not a scalar. These pin the
/// step behaviour that a single `playlistShiftSeconds` cannot express.
@Suite("Presentation axis map")
struct PresentationAxisMapTests {

    @Test("An empty map states nothing rather than guessing zero")
    func emptyMapReturnsNil() {
        let map = PresentationAxisMap()
        #expect(map.isEmpty)
        #expect(map.shiftSeconds(atItemSeconds: 0) == nil)
        #expect(map.sourceSeconds(forItemSeconds: 12.5) == nil)
        #expect(map.itemSeconds(forSourceSeconds: 12.5) == nil)
    }

    @Test("An anchored map covers the whole timeline")
    func anchoredCoversEverything() {
        let map = PresentationAxisMap.anchored(shiftSeconds: -0.083333)
        #expect(map.shiftSeconds(atItemSeconds: -1e9) == -0.083333)
        #expect(map.sourceSeconds(forItemSeconds: 10) == 10 - 0.083333)
        #expect(map.itemSeconds(forSourceSeconds: 10 - 0.083333) == 10)
    }

    @Test("The first seam anchors at -infinity regardless of where the producer starts")
    func firstSeamAnchors() {
        var map = PresentationAxisMap()
        map.appendSeam(shiftSeconds: 2, activatingAtItemSeconds: 48)
        #expect(map.seams.count == 1)
        #expect(map.seams[0].itemSeconds == -.infinity)
        #expect(map.shiftSeconds(atItemSeconds: 0) == 2)
    }

    /// The property the collapse destroyed: content below the seam keeps folding with the shift it was
    /// muxed under, which is what AVPlayer still has in its buffer.
    @Test("A forward restart leaves the old epoch on the old shift")
    func forwardRestartKeepsOldEpoch() {
        var map = PresentationAxisMap.anchored(shiftSeconds: 0.5)
        map.appendSeam(shiftSeconds: 3.92, activatingAtItemSeconds: 600)

        #expect(map.shiftSeconds(atItemSeconds: 599.9) == 0.5)
        #expect(map.shiftSeconds(atItemSeconds: 600) == 3.92)
        #expect(map.sourceSeconds(forItemSeconds: 599.9) == 599.9 + 0.5)
        #expect(map.sourceSeconds(forItemSeconds: 600) == 600 + 3.92)
        // What a collapsed history would have answered for the old-epoch position, i.e. the error a
        // consumer inherits: 3.42 s on the witness magnitude from AE#105.
        #expect(map.shiftSeconds(atItemSeconds: 599.9) != 3.92)
    }

    @Test("A backward restart drops the seams it rewrites")
    func backwardRestartTruncatesFuture() {
        var map = PresentationAxisMap.anchored(shiftSeconds: 0.5)
        map.appendSeam(shiftSeconds: 1.5, activatingAtItemSeconds: 300)
        map.appendSeam(shiftSeconds: 2.5, activatingAtItemSeconds: 600)
        #expect(map.seams.count == 3)

        // Seek back to 200: the producer rewrites everything from there forward, so the 300 and 600
        // seams describe bytes that no longer exist.
        map.appendSeam(shiftSeconds: 0.75, activatingAtItemSeconds: 200)
        #expect(map.seams.count == 2)
        #expect(map.shiftSeconds(atItemSeconds: 199) == 0.5)
        #expect(map.shiftSeconds(atItemSeconds: 200) == 0.75)
        #expect(map.shiftSeconds(atItemSeconds: 650) == 0.75)
    }

    @Test("A seam at an existing position replaces it")
    func seamReplacesSamePosition() {
        var map = PresentationAxisMap.anchored(shiftSeconds: 0.5)
        map.appendSeam(shiftSeconds: 1.5, activatingAtItemSeconds: 300)
        map.appendSeam(shiftSeconds: 1.75, activatingAtItemSeconds: 300)
        #expect(map.seams.count == 2)
        #expect(map.shiftSeconds(atItemSeconds: 300) == 1.75)
    }

    @Test("Round trip across a seam, in both directions")
    func roundTripAcrossSeam() throws {
        var map = PresentationAxisMap.anchored(shiftSeconds: -0.083333)
        map.appendSeam(shiftSeconds: 1.25, activatingAtItemSeconds: 100)

        for item in [0.0, 50.0, 99.999, 100.0, 250.0] {
            let source = try #require(map.sourceSeconds(forItemSeconds: item))
            let back = try #require(map.itemSeconds(forSourceSeconds: source))
            #expect(abs(back - item) < 1e-9,
                    "round trip broke at item \(item) (source \(source), back \(back))")
        }
    }

    /// Trimming must not leave a hole at the bottom: a lookup below the oldest seam would answer nil
    /// and the host would lose the axis for content it can still be showing.
    @Test("The history cap keeps an anchor at the bottom")
    func capReanchorsOldest() {
        var map = PresentationAxisMap.anchored(shiftSeconds: 0)
        for i in 1...(PresentationAxisMap.maxSeams + 10) {
            map.appendSeam(shiftSeconds: Double(i), activatingAtItemSeconds: Double(i) * 10)
        }
        #expect(map.seams.count == PresentationAxisMap.maxSeams)
        #expect(map.seams[0].itemSeconds == -.infinity)
        #expect(map.shiftSeconds(atItemSeconds: 0) != nil)
        #expect(map.shiftSeconds(atItemSeconds: -1e6) != nil)
        #expect(map.shiftSeconds(atItemSeconds: Double(PresentationAxisMap.maxSeams + 10) * 10)
                == Double(PresentationAxisMap.maxSeams + 10))
    }
}
