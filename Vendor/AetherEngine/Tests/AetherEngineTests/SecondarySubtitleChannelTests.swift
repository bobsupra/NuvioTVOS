import XCTest
import AetherLibavcodec
@testable import AetherEngine

final class SecondarySubtitleChannelTests: XCTestCase {

    // Documents the basis of the secondary text-only guard: the four
    // bitmap subtitle codecs must classify as bitmap, text codecs must not.
    func testBitmapCodecClassification() {
        XCTAssertTrue(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_HDMV_PGS_SUBTITLE))
        XCTAssertTrue(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_DVB_SUBTITLE))
        XCTAssertTrue(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_DVD_SUBTITLE))
        XCTAssertTrue(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_XSUB))
        XCTAssertFalse(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_SUBRIP))
        XCTAssertFalse(EmbeddedSubtitleDecoder.isBitmapCodec(AV_CODEC_ID_ASS))
    }

    @MainActor
    func testSecondaryChannelDefaultsAndIndependentClear() throws {
        let engine = try AetherEngine()
        XCTAssertEqual(engine.secondarySubtitleCues.count, 0)
        XCTAssertFalse(engine.isSecondarySubtitleActive)
        XCTAssertFalse(engine.isLoadingSecondarySubtitles)
        // Clearing one channel must not flip the other's flags.
        engine.clearSecondarySubtitle()
        XCTAssertFalse(engine.isSecondarySubtitleActive)
        engine.clearSubtitle()
        XCTAssertFalse(engine.isSubtitleActive)
        XCTAssertFalse(engine.isSecondarySubtitleActive)
    }
}
