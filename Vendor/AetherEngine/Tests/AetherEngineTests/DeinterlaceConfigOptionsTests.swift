import Testing
@testable import AetherEngine

struct DeinterlaceConfigOptionsTests {
    @Test("LoadOptions defaults to auto hardware, field rate")
    func defaults() {
        let o = LoadOptions()
        #expect(o.deinterlaceMode == .auto)
        #expect(o.deinterlaceFieldRate == .field)
        #expect(o.teletextPage == nil)  // Phase-1 field still present
    }

    @Test("deinterlace options are settable and Equatable")
    func settable() {
        let a = LoadOptions(deinterlaceMode: .software, deinterlaceFieldRate: .frame)
        #expect(a.deinterlaceMode == .software)
        #expect(a.deinterlaceFieldRate == .frame)
        #expect(a != LoadOptions())
    }
}
