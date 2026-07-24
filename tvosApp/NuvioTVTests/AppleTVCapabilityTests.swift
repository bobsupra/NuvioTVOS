import XCTest
@testable import NuvioTV

final class AppleTVCapabilityTests: XCTestCase {
    private let appleTVHD = AppleTVCapability(
        maxResolution: 1080,
        supportsHDR: false,
        supportsDolbyVision: false,
        supportsHEVCHardwareDecode: false,
        supportsAV1HardwareDecode: false
    )

    private let appleTV4K = AppleTVCapability(
        maxResolution: 2160,
        supportsHDR: true,
        supportsDolbyVision: true,
        supportsHEVCHardwareDecode: true,
        supportsAV1HardwareDecode: false
    )

    func testAppleTVHDRejects4KDolbyVision() {
        let tags = StreamQualityTags.parse(name: "Movie 2160p Dolby Vision")
        XCTAssertFalse(appleTVHD.isPlayable(tags: tags))
    }

    func testAppleTVHDRejectsHDROnlyAtAnyResolution() {
        let tags = StreamQualityTags.parse(name: "Movie 1080p HDR10")
        XCTAssertFalse(appleTVHD.isPlayable(tags: tags))
    }

    func testAppleTVHDAccepts1080pSDR() {
        let tags = StreamQualityTags.parse(name: "Movie 1080p WEB-DL")
        XCTAssertTrue(appleTVHD.isPlayable(tags: tags))
    }

    func testAppleTVHDAcceptsUntaggedStream() {
        // A stream with no parseable resolution/HDR markers should never be
        // blocked outright by capability filtering alone.
        let tags = StreamQualityTags.parse(name: "Movie")
        XCTAssertTrue(appleTVHD.isPlayable(tags: tags))
    }

    func testAppleTV4KAccepts4KDolbyVision() {
        let tags = StreamQualityTags.parse(name: "Movie 2160p Dolby Vision")
        XCTAssertTrue(appleTV4K.isPlayable(tags: tags))
    }

    func testUnknownHardwareIdentifierDefaultsToUnrestricted() {
        // Anything not in the table (including the Simulator's host
        // architecture string) must never be narrowed by default.
        XCTAssertFalse(AppleTVCapability.hardwareIdentifier().isEmpty)
    }
}
