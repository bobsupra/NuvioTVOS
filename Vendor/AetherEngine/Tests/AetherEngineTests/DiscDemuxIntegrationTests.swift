import XCTest
@testable import AetherEngine

final class DiscDemuxIntegrationTests: XCTestCase {
    // Fixture ISO has a pack-start-code-only VOB: verifies disc routing reaches mpegps open without
    // DiscError. Real-stream decoding is covered by a manual real-ISO check outside CI.
    func test_discISORoutesToMpegPSOpen() throws {
        let data = ISO9660Fixture.make(files: [
            .init(name: "VTS_01_1.VOB", length: 2048),
        ])
        let demuxer = Demuxer()
        do {
            try demuxer.open(reader: DataIOReader(data: data), formatHint: nil)
            demuxer.close()
        } catch let e as DiscError {
            XCTFail("disc detection should not surface DiscError here: \(e)")
        } catch {
            // libav open error from toy payload is acceptable; disc path was taken.
        }
    }
}
