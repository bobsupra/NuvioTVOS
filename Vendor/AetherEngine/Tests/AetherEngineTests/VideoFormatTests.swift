import Testing
@testable import AetherEngine

@Suite("VideoFormat")
struct VideoFormatTests {

    @Test("All five cases are distinct under Equatable")
    func allCasesAreDistinct() {
        let all: [VideoFormat] = [.sdr, .hdr10, .hdr10Plus, .dolbyVision, .hlg]
        for (i, a) in all.enumerated() {
            for (j, b) in all.enumerated() {
                if i == j {
                    #expect(a == b)
                } else {
                    #expect(a != b)
                }
            }
        }
    }

    @Test("Sendable across actor boundary")
    func sendableCrossesActorBoundary() async {
        let format: VideoFormat = .dolbyVision
        let received = await Task.detached { format }.value
        #expect(received == .dolbyVision)
    }
}
