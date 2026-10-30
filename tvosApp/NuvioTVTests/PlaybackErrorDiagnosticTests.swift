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

    func testHttp403ReportsAccessDeniedWithoutClaimingTheLinkExpired() {
        let rawError = "HTTP 403 Forbidden"
        let streamURL = URL(string: "https://aiostreams.elfhosted.com/playback/token123")!

        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: rawError,
            streamURL: streamURL
        )

        XCTAssertEqual(diag.origin, .hostingProvider)
        XCTAssertTrue(diag.isHostingIssue)
        XCTAssertEqual(diag.badgeText, "STREAM ACCESS DENIED")
        XCTAssertEqual(diag.title, "Stream Access Denied")
        XCTAssertTrue(diag.message.contains("HTTP 403"))
        XCTAssertTrue(diag.message.contains("may need refreshing"))
        XCTAssertFalse(diag.message.localizedCaseInsensitiveContains("expired"))
        XCTAssertTrue(diag.technicalDetails?.contains("Status: HTTP 403 (Forbidden)") == true)
        XCTAssertTrue(diag.technicalDetails?.contains(rawError) == true)
        XCTAssertEqual(diag.httpStatusCode, 403)
    }

    func testHttp401Remains401() {
        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: "HTTP/1.1 401 Unauthorized",
            streamURL: URL(string: "https://stream.example/play")!
        )

        XCTAssertEqual(diag.badgeText, "STREAM ACCESS DENIED")
        XCTAssertEqual(diag.title, "Stream Access Denied")
        XCTAssertTrue(diag.message.contains("HTTP 401 (Unauthorized)"))
        XCTAssertFalse(diag.message.contains("HTTP 403"))
        XCTAssertTrue(diag.technicalDetails?.contains("Status: HTTP 401 (Unauthorized)") == true)
        XCTAssertEqual(diag.httpStatusCode, 401)
        XCTAssertNil(makeSupportReport(for: diag))
    }

    func testRecognizesExplicitHttp403FormsInNestedErrors() {
        let explicitHTTP403Errors = [
            "HTTP403",
            "HTTP403.",
            "HTTP/1.1 403",
            "HTTP status code:403",
            "Origin answered HTTP403 for the source",
            "Origin answered HTTP403, request denied",
            "FFmpeg server returned403",
            "Error Domain=AVFoundationErrorDomain Code=-11800 underlying=FFmpeg server returned 403"
        ]

        for rawError in explicitHTTP403Errors {
            let diag = PlaybackErrorDiagnostic.analyze(
                errorMessage: rawError,
                streamURL: URL(string: "https://stream.example/play")!
            )
            XCTAssertEqual(diag.badgeText, "STREAM ACCESS DENIED", rawError)
            XCTAssertTrue(diag.message.contains("HTTP 403 (Forbidden)"), rawError)
            XCTAssertEqual(diag.httpStatusCode, 403, rawError)
            XCTAssertTrue(diag.technicalDetails?.contains(rawError) == true, rawError)
        }
    }

    func testNonHTTPCodesGenericAuthWordsAndURLDigitsDoNotImplyAccessDenied() {
        let rawErrors = [
            "Decoder session failed (OSStatus -14033)",
            "Error Domain=NSOSStatusErrorDomain Code=-14033",
            "CoreMedia error Code=403",
            "decoder expired",
            "forbidden",
            "unauthorized",
            "Error Code403",
            "HTTP 4030 Forbidden",
            "HTTP -403 Forbidden",
            "/Media/HTTP403.mkv",
            "movie.HTTP403.mkv",
            "HTTP403decoder",
            "HTTP403.mkv",
            "Failed to open https://stream.example/files/403-forbidden-movie403.mkv?token=403"
        ]
        let streamURL = URL(string: "https://stream.example/files/403/movie403.mkv?token=403")!

        for rawError in rawErrors {
            let diag = PlaybackErrorDiagnostic.analyze(errorMessage: rawError, streamURL: streamURL)
            XCTAssertNotEqual(diag.title, "Stream Access Denied", rawError)
            XCTAssertNotEqual(diag.badgeText, "STREAM ACCESS DENIED", rawError)
            XCTAssertNil(diag.httpStatusCode, rawError)
            XCTAssertNil(makeSupportReport(for: diag), rawError)
        }
    }

    func testHttp403SupportReportContainsOnlyAllowlistedContext() throws {
        let rawError = "HTTP 403 Forbidden: https://user:password@private.example/video?token=secret-token"
        let streamURL = URL(string: "https://user:password@private.example/video?token=secret-token")!
        let diagnostic = PlaybackErrorDiagnostic.analyze(errorMessage: rawError, streamURL: streamURL)
        let report = try XCTUnwrap(makeSupportReport(for: diagnostic))
        let screenshotText = [
            diagnostic.badgeText,
            diagnostic.title,
            diagnostic.message,
            report.statusLine,
            report.playbackLine,
            report.sharingPrompt
        ].joined(separator: "\n")

        XCTAssertTrue(screenshotText.contains("HTTP 403"))
        XCTAssertTrue(screenshotText.contains("AetherEngine"))
        XCTAssertTrue(screenshotText.contains("App 3.4.4 (Build 75)"))
        XCTAssertTrue(screenshotText.contains("First frame rendered this session: No"))
        XCTAssertTrue(screenshotText.contains("Photograph this screen and send it to support."))

        for privateValue in ["user", "password", "private.example", "secret-token", "https://", rawError] {
            XCTAssertFalse(screenshotText.localizedCaseInsensitiveContains(privateValue), "Report exposed \(privateValue)")
        }
    }

    private func makeSupportReport(for diagnostic: PlaybackErrorDiagnostic) -> PlaybackErrorSupportReport? {
        PlaybackErrorSupportReport(
            httpStatusCode: diagnostic.httpStatusCode,
            engine: .aether,
            appVersion: "3.4.4",
            buildNumber: "75",
            renderedFirstFrame: false
        )
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

    func testCannotFindHostCode1003() {
        let rawError = "Error Domain=NSURLErrorDomain Code=-1003 \"A server with the specified hostname could not be found.\""
        let streamURL = URL(string: "https://unknown.download.real-debrid.com/d/123/movie.mp4")!

        let diag = PlaybackErrorDiagnostic.analyze(
            errorMessage: rawError,
            streamURL: streamURL
        )

        XCTAssertEqual(diag.origin, .network)
        XCTAssertTrue(diag.isNetworkIssue)
        XCTAssertFalse(diag.isHostingIssue)
        XCTAssertEqual(diag.badgeText, "DNS / HOST UNRESOLVED")
        XCTAssertEqual(diag.title, "Cannot Resolve Stream Host")
        XCTAssertEqual(diag.host, "unknown.download.real-debrid.com")
        XCTAssertTrue(diag.message.contains("unknown.download.real-debrid.com"))
        XCTAssertTrue(diag.suggestedAction.contains("DNS"))
    }
}

