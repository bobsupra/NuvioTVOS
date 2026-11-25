import XCTest
@testable import NuvioTV

final class StreamBadgeSizingTests: XCTestCase {
    func testFileSizeBadgeUsesDecimalUnitsForReportedBytes() {
        // AIOStreams lists this release as 9.77 GB; the badge must agree.
        let stream = NuvioStream(
            url: "https://cdn.example/a.mkv",
            name: "TB 2160p WEB-DL",
            description: "9.77 GB",
            addonName: "AIOStreams",
            videoSize: 9_770_000_000
        )
        XCTAssertEqual(StreamBadgeSizing.fileSizeLabel(for: stream), "9.8 GB")
    }

    func testFileSizeBadgeReadsDecimalUnitsFromText() {
        let gigabytes = NuvioStream(
            url: "https://cdn.example/b.mkv",
            name: "1080p",
            description: "8.13 GB",
            addonName: "Plex"
        )
        XCTAssertEqual(StreamBadgeSizing.fileSizeBytes(for: gigabytes), 8_130_000_000)
        XCTAssertEqual(StreamBadgeSizing.fileSizeLabel(for: gigabytes), "8.1 GB")

        let megabytes = NuvioStream(
            url: "https://cdn.example/c.mkv",
            name: "480p",
            description: "167 MB",
            addonName: "Torrentio"
        )
        XCTAssertEqual(StreamBadgeSizing.fileSizeLabel(for: megabytes), "167 MB")
    }
}
