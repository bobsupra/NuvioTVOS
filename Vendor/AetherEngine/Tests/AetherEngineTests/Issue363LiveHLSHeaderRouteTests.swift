import Foundation
import XCTest
@testable import AetherEngine

/// AE#363: a tokenized IPTV origin that enforces per-request headers had two ways to end a live load and
/// no way to reach the one path that provably carries those headers on every fetch.
///
/// Measured against a header-enforcing fixture origin (`aetherctl hlsfixture --require-header`) before any
/// of this was written: `LoadOptions.httpHeaders` survive both a cross-origin 302 and an absolutely
/// referenced second origin on the AVPlayer bypass, so the reporter's stated cause (AVFoundation dropping
/// them over the redirect) is not what these tests pin. What they pin is the routing around a refusal:
///
/// 1. `.url(m3u8) + isLive` without `nativeRemoteHLS` used to throw `hlsPlaylistOnRawLivePath`, although
///    the engine holds `HLSLiveIngestReader`, which puts `options.httpHeaders` on the playlist, every
///    segment and every AES key. The VOD side has rerouted itself since AE#154; live now does too.
/// 2. An origin that refuses the native mount surfaced as a terminal `.error` with an NSURLError the host
///    cannot act on. Both refusal statuses were measured on the fixture: HTTP 401 reaches the item as
///    `NSURLErrorDomain/-1013`, HTTP 403 as `-1102`, and both arrive that way whether the refusal hit the
///    master playlist or the first segment (neither ever reaches readyToPlay).
final class Issue363LiveHLSHeaderRouteTests: XCTestCase {

    // MARK: - Raw live path: route instead of failing closed

    func testLiveRawPathMisrouteRoutesOntoTheIngest() {
        XCTAssertTrue(RemoteHLSMediaSelection.shouldRouteLiveOntoIngest(
            failure: AVIOReaderError.hlsPlaylistOnRawLivePath, isCustomSource: false))
    }

    func testCustomSourceKeepsTheTypedRejection() {
        // A custom reader has no URL to build an ingest from, so the typed error stays the answer.
        XCTAssertFalse(RemoteHLSMediaSelection.shouldRouteLiveOntoIngest(
            failure: AVIOReaderError.hlsPlaylistOnRawLivePath, isCustomSource: true))
    }

    func testVODMisrouteIsNotTheLiveRoute() {
        // AE#154 owns that one and sends it to the native bypass; the two must not answer each other.
        XCTAssertFalse(RemoteHLSMediaSelection.shouldRouteLiveOntoIngest(
            failure: AVIOReaderError.hlsPlaylistOnVODPath, isCustomSource: false))
        XCTAssertFalse(RemoteHLSMediaSelection.shouldReroute(
            failure: AVIOReaderError.hlsPlaylistOnRawLivePath, isCustomSource: false))
    }

    func testUnrelatedProbeFailuresDoNotRoute() {
        XCTAssertFalse(RemoteHLSMediaSelection.shouldRouteLiveOntoIngest(
            failure: AVIOReaderError.requestTimeout, isCustomSource: false))
        XCTAssertFalse(RemoteHLSMediaSelection.shouldRouteLiveOntoIngest(
            failure: DemuxerError.openFailed(code: -5), isCustomSource: false))
        XCTAssertFalse(RemoteHLSMediaSelection.shouldRouteLiveOntoIngest(
            failure: nil, isCustomSource: false))
    }

    // MARK: - Origin refusal on the native bypass

    func testMeasuredRefusalCodesAreRecognised() {
        // The two codes a header-enforcing origin actually produced on the fixture.
        XCTAssertTrue(RemoteHLSIngestFallback.isOriginRefusal(
            domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired))   // HTTP 401
        XCTAssertTrue(RemoteHLSIngestFallback.isOriginRefusal(
            domain: NSURLErrorDomain, code: NSURLErrorNoPermissionsToReadFile))      // HTTP 403
    }

    func testTransportFailuresAreNotRefusals() {
        // A dead network is not an origin decision, and rerouting onto a second client would only
        // spend the same failure twice.
        XCTAssertFalse(RemoteHLSIngestFallback.isOriginRefusal(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        XCTAssertFalse(RemoteHLSIngestFallback.isOriginRefusal(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        // 404 arrives from CoreMedia, not NSURLError, and means the resource is gone for everyone.
        XCTAssertFalse(RemoteHLSIngestFallback.isOriginRefusal(
            domain: "CoreMediaErrorDomain", code: -12938))
        XCTAssertFalse(RemoteHLSIngestFallback.isOriginRefusal(
            domain: "CoreMediaErrorDomain", code: NSURLErrorNoPermissionsToReadFile))
    }

    func testRefusalReroutesOnlyOnceAndOnlyWhenArmed() {
        XCTAssertTrue(RemoteHLSIngestFallback.shouldRerouteOnOriginRefusal(
            domain: NSURLErrorDomain, code: NSURLErrorNoPermissionsToReadFile,
            armed: true, alreadyRerouted: false))
        // VOD / loopback sessions and hosts that opted out are not armed.
        XCTAssertFalse(RemoteHLSIngestFallback.shouldRerouteOnOriginRefusal(
            domain: NSURLErrorDomain, code: NSURLErrorNoPermissionsToReadFile,
            armed: false, alreadyRerouted: false))
        // The ingest session's own failures must not bounce back into another reroute.
        XCTAssertFalse(RemoteHLSIngestFallback.shouldRerouteOnOriginRefusal(
            domain: NSURLErrorDomain, code: NSURLErrorNoPermissionsToReadFile,
            armed: true, alreadyRerouted: true))
    }

    func testArmingStillFollowsTheLiveFallbackContract() {
        // The refusal reroute rides the same gate as the #168 carriage reroute: live, fallback enabled.
        XCTAssertTrue(RemoteHLSIngestFallback.shouldArm(isLive: true, fallbackEnabled: true))
        XCTAssertFalse(RemoteHLSIngestFallback.shouldArm(isLive: true, fallbackEnabled: false))
        XCTAssertFalse(RemoteHLSIngestFallback.shouldArm(isLive: false, fallbackEnabled: true))
    }
}
