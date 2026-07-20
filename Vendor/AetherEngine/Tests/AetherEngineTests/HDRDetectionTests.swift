import Testing
import AetherLibavutil
@testable import AetherEngine

struct HDRDetectionTests {
    @Test("PQ and HLG transfer characteristics are HDR")
    func hdrTransfers() {
        #expect(FrameDecodeContext.isHDRTransfer(AVCOL_TRC_SMPTE2084))
        #expect(FrameDecodeContext.isHDRTransfer(AVCOL_TRC_ARIB_STD_B67))
    }
    @Test("SDR transfers are not HDR")
    func sdrTransfers() {
        #expect(!FrameDecodeContext.isHDRTransfer(AVCOL_TRC_BT709))
        #expect(!FrameDecodeContext.isHDRTransfer(AVCOL_TRC_UNSPECIFIED))
    }
}
