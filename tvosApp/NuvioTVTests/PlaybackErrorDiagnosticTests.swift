import XCTest
@testable import NuvioTV

final class PlaybackErrorDiagnosticTests: XCTestCase {

    func testHostConnectionRefusedCode1004() {
        let rawError = "Task <F389B3E7-0AF7-46E4-9694-0115B2A19BF7>.<1> HTTP load failed, 0/0 bytes (error code: -1004 [1:61])"
        let streamURL = URL(string: "https://nexus-226.nord.tb-cdn.st/dld/1540d500-7774-4825-901b-ecd15214d771?token=85d92d72")!

        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: rawError,
            streamURL: streamURL
        )

        XCTAssertEqual(diag.origin, .hostingProvider)
        XCTAssertTrue(diag.isHostingIssue)
        XCTAssertFalse(diag.isNetworkIssue)
        XCTAssertEqual(diag.badgeText, "STREAM HOST OFFLINE")
        XCTAssertEqual(diag.host, "nexus-226.nord.tb-cdn.st")
        XCTAssertTrue(diag.message.contains("nexus-226.nord.tb-cdn.st"))
        XCTAssertTrue(diag.message.contains("refused the connection or is offline"))
    }

    func testExpiredLinkHttp403() {
        let rawError = "HTTP 403 Forbidden"
        let streamURL = URL(string: "https://aiostreams.elfhosted.com/playback/token123")!

        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: rawError,
            streamURL: streamURL
        )

        XCTAssertEqual(diag.origin, .hostingProvider)
        XCTAssertTrue(diag.isHostingIssue)
        XCTAssertEqual(diag.badgeText, "STREAM LINK EXPIRED")
        XCTAssertEqual(diag.title, "Stream Link Expired")
        XCTAssertTrue(diag.message.contains("HTTP 403"))
    }

    func testRateLimitedHttp429() {
        let rawError = "Origin answered HTTP 429 for the source"
        let streamURL = URL(string: "https://nexus-226.nord.tb-cdn.st/dld/token123")!

        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: rawError,
            streamURL: streamURL
        )

        XCTAssertEqual(diag.origin, .hostingProvider)
        XCTAssertTrue(diag.isHostingIssue)
        XCTAssertEqual(diag.badgeText, "RATE LIMITED (429)")
        XCTAssertEqual(diag.title, "Stream Host Rate Limited")
        XCTAssertTrue(diag.message.contains("HTTP 429"))
        XCTAssertTrue(diag.message.contains("nexus-226.nord.tb-cdn.st"))
    }

    func testFileNotFoundHttp404() {
        let rawError = "HTTP 404 Not Found"
        let streamURL = URL(string: "https://example.com/stream.mkv")!

        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: rawError,
            streamURL: streamURL
        )

        XCTAssertEqual(diag.origin, .hostingProvider)
        XCTAssertTrue(diag.isHostingIssue)
        XCTAssertEqual(diag.badgeText, "FILE NOT FOUND")
        XCTAssertEqual(diag.title, "Stream File Missing")
    }

    func testServerOutageHttp502() {
        let rawError = "HTTP 502 Bad Gateway"
        let streamURL = URL(string: "https://debrid.example.org/play")!

        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: rawError,
            streamURL: streamURL
        )

        XCTAssertEqual(diag.origin, .hostingProvider)
        XCTAssertTrue(diag.isHostingIssue)
        XCTAssertEqual(diag.badgeText, "HOST SERVER ERROR")
        XCTAssertEqual(diag.title, "Hosting Server Error")
    }

    func testNetworkOfflineCode1009() {
        let rawError = "Error Domain=NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\""
        let streamURL = URL(string: "https://nexus-226.nord.tb-cdn.st/dld/123")!

        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: rawError,
            streamURL: streamURL
        )

        XCTAssertEqual(diag.origin, .network)
        XCTAssertTrue(diag.isNetworkIssue)
        XCTAssertFalse(diag.isHostingIssue)
        XCTAssertEqual(diag.badgeText, "NO INTERNET CONNECTION")
        XCTAssertEqual(diag.title, "Internet Connection Offline")
    }

    func testCorruptStreamDemuxerFailureOnRemoteURL() {
        let rawError = "Demuxer: open failed (Invalid data found when processing input (-1094995529))"
        let streamURL = URL(string: "https://nexus-226.nord.tb-cdn.st/dld/123")!

        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: rawError,
            streamURL: streamURL
        )

        XCTAssertEqual(diag.origin, .hostingProvider)
        XCTAssertTrue(diag.isHostingIssue)
        XCTAssertEqual(diag.badgeText, "STREAM UNAVAILABLE")
        XCTAssertEqual(diag.title, "Stream Source Invalid")
    }

    func testSimulatorAV1Compatibility() {
        let rawError = "AV1 playback is unavailable in the Apple TV Simulator. Choose an H.264 or HEVC stream."

        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: rawError
        )

        XCTAssertEqual(diag.origin, .compatibility)
        XCTAssertFalse(diag.isHostingIssue)
        XCTAssertEqual(diag.badgeText, "SIMULATOR COMPATIBILITY")
        XCTAssertEqual(diag.title, "Unsupported Simulator Format")
    }

    func testEngineUnavailable() {
        let rawError = "AetherEngine is unavailable on this device."

        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: rawError
        )

        XCTAssertEqual(diag.origin, .playerEngine)
        XCTAssertFalse(diag.isHostingIssue)
        XCTAssertEqual(diag.badgeText, "PLAYER ENGINE")
        XCTAssertEqual(diag.title, "Player Engine Unavailable")
    }
}
