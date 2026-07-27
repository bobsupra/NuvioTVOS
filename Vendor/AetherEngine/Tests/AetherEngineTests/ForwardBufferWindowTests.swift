import Foundation
import Testing
@testable import AetherEngine

@Suite("Configurable forward-buffer window clamp (#102)")
struct ForwardBufferWindowTests {

    @Test("nil requests the historical default of 10 segments")
    func nilKeepsDefault() {
        #expect(HLSVideoEngine.clampedForwardWindow(nil) == 10)
    }

    @Test("in-range values pass through unchanged")
    func inRangePassesThrough() {
        #expect(HLSVideoEngine.clampedForwardWindow(10) == 10)
        #expect(HLSVideoEngine.clampedForwardWindow(4) == 4)
        #expect(HLSVideoEngine.clampedForwardWindow(50) == 50)
        #expect(HLSVideoEngine.clampedForwardWindow(150) == 150)
        #expect(HLSVideoEngine.clampedForwardWindow(900) == 900)
        #expect(HLSVideoEngine.clampedForwardWindow(2700) == 2700)
    }

    @Test("values below the floor clamp up to 4 (AVPlayer prefetch would starve)")
    func belowFloorClampsUp() {
        #expect(HLSVideoEngine.clampedForwardWindow(3) == 4)
        #expect(HLSVideoEngine.clampedForwardWindow(0) == 4)
        #expect(HLSVideoEngine.clampedForwardWindow(-5) == 4)
    }

    @Test("values above the sanity ceiling clamp down to 2700 (~3 h, whole-film bound)")
    func aboveCeilingClampsDown() {
        #expect(HLSVideoEngine.clampedForwardWindow(2701) == 2700)
        #expect(HLSVideoEngine.clampedForwardWindow(Int.max) == 2700)
    }

    @Test("LoadOptions defaults forwardBufferSegments to nil")
    func loadOptionsDefaultsNil() {
        let opts = LoadOptions()
        #expect(opts.forwardBufferSegments == nil)
    }

    @Test("LoadOptions carries an explicit forwardBufferSegments")
    func loadOptionsCarriesValue() {
        let opts = LoadOptions(forwardBufferSegments: 120)
        #expect(opts.forwardBufferSegments == 120)
    }
}
