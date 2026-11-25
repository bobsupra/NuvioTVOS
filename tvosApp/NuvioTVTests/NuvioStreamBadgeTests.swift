import XCTest
@testable import NuvioTV

final class NuvioStreamBadgeTests: XCTestCase {
    private func names(_ text: String) -> [String] {
        NuvioStreamBadge.badges(in: text).map { badge in
            switch badge {
            case .dolbyVision(let layer): return layer.map { "DV-\($0)" } ?? "DV"
            case .hdr10Plus: return "HDR10+"
            case .atmos: return "Atmos"
            case .trueHD: return "TrueHD"
            case .dolbyDigitalPlus: return "DD+"
            case .dtsX: return "DTS:X"
            case .dtsHDMA: return "DTS-HD-MA"
            case .dtsHD(let variant): return variant.map { "DTS-HD-\($0)" } ?? "DTS-HD"
            case .dts: return "DTS"
            default: return badge.label ?? ""
            }
        }
    }

    func testReadsBadgesInFixedOrder() {
        XCTAssertEqual(
            names("Film.2160p.UHD.BluRay.REMUX.DV.FEL.HDR10.TrueHD.Atmos.7.1.HEVC"),
            ["4K", "DV-FEL", "HDR10", "Atmos", "TrueHD", "7.1", "REMUX", "HEVC"]
        )
        XCTAssertEqual(
            names("TB 2160p WEB-DL\nHDR10+ / DV / 10bit • HEVC\nAtmos / DD+ • 5.1"),
            ["4K", "DV", "HDR10+", "Atmos", "DD+", "5.1", "WEB-DL", "HEVC", "10-bit"]
        )
    }

    func testChannelLayoutRunsIntoCodec() {
        XCTAssertEqual(
            names("Film 2160p WEB-DL DDP5.1 Atmos DV HDR10Plus H.265"),
            ["4K", "DV", "HDR10+", "Atmos", "DD+", "5.1", "WEB-DL", "HEVC"]
        )
        XCTAssertEqual(names("Film 1080p WEBRip DD5.1 H264"), ["1080p", "DD", "5.1", "WEBRip", "H.264"])
    }

    func testFileSizeAndBitrateAreNotChannels() {
        XCTAssertEqual(names("Movie 1080p WEB-DL AAC\n5.1 GB"), ["1080p", "AAC", "WEB-DL"])
        XCTAssertEqual(names("Show 720p HDTV x264\n7.1 Mbps"), ["720p", "HDTV", "H.264"])
        XCTAssertEqual(names("Film 720p WEB-DL AAC2.0 size 2.0 GiB"), ["720p", "AAC", "2.0", "WEB-DL"])
    }

    func testPlainHDRIsNotHDR10() {
        XCTAssertEqual(names("Film 2160p HDR HEVC AC3 DD 5.1 2.0GB"), ["4K", "HDR", "DD", "5.1", "HEVC"])
    }

    func testDTSVariants() {
        XCTAssertEqual(names("Film 1080p BluRay DTS-HD MA 5.1 x265 10bit"), ["1080p", "DTS-HD-MA", "5.1", "BluRay", "HEVC", "10-bit"])
        XCTAssertEqual(names("Film 1080p BluRay DTS-HD Master Audio 7.1"), ["1080p", "DTS-HD-MA", "7.1", "BluRay"])
        XCTAssertEqual(names("Film 1080p BluRay DTS-X 7.1"), ["1080p", "DTS:X", "7.1", "BluRay"])
        XCTAssertEqual(names("Film 1080p BluRay DTS-HD 5.1"), ["1080p", "DTS-HD", "5.1", "BluRay"])
        XCTAssertEqual(names("Film 1080p BluRay DTS 5.1 FLAC"), ["1080p", "DTS", "5.1", "BluRay"])
    }

    func testDolbyVisionLayerNeedsCapitals() {
        XCTAssertEqual(
            names("Film 1080p BluRay DTS-HD HRA 2.0 Mel Gibson DV"),
            ["1080p", "DV", "DTS-HD-HRA", "2.0", "BluRay"]
        )
    }

    func testOtherFormats() {
        XCTAssertEqual(names("Film 480p DVDRip XviD"), ["480p", "DVD"])
        XCTAssertEqual(names("Film 1440p AV1 Opus IMAX 3D"), ["1440p", "Opus", "AV1", "IMAX", "3D"])
        XCTAssertEqual(names("Isaac 1080p HLG LPCM 2.0"), ["1080p", "HLG", "PCM", "2.0"])
    }
}
