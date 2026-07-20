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
    }

    @Test("values below the floor clamp up to 4 (AVPlayer prefetch would starve)")
    func belowFloorClampsUp() {
        #expect(HLSVideoEngine.clampedForwardWindow(3) == 4)
        #expect(HLSVideoEngine.clampedForwardWindow(0) == 4)
        #expect(HLSVideoEngine.clampedForwardWindow(-5) == 4)
    }

    @Test("values above the ceiling clamp down to 150 (disk/demux cost)")
    func aboveCeilingClampsDown() {
        #expect(HLSVideoEngine.clampedForwardWindow(151) == 150)
        #expect(HLSVideoEngine.clampedForwardWindow(1000) == 150)
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
