import XCTest
@testable import NuvioTV

final class IPTVFailureKindTests: XCTestCase {
    func testCommonFailuresMapToUsefulCategories() {
        XCTAssertEqual(IPTVFailureKind.classify(IPTVPlaylistLoadError.httpStatus(403)), .authentication)
        XCTAssertEqual(IPTVFailureKind.classify(IPTVXtreamError.authenticationFailed), .authentication)
        XCTAssertEqual(IPTVFailureKind.classify(IPTVStalkerError.tooLarge), .tooLarge)
        XCTAssertEqual(IPTVFailureKind.classify(IPTVPlaylistParser.ParserError.hlsPlaylist), .invalidContent)
        XCTAssertEqual(IPTVFailureKind.classify(URLError(.timedOut)), .network)
        XCTAssertEqual(IPTVFailureKind.invalidContent.localizationKey, "iptv_error_content")
        XCTAssertEqual(IPTVFailureKind.authentication.localizationKey, "iptv_error_auth")
        XCTAssertEqual(IPTVFailureKind.network.localizationKey, "iptv_error_network")
        XCTAssertEqual(IPTVFailureKind.tooLarge.localizationKey, "iptv_error_size")
        XCTAssertEqual(IPTVFailureKind.storage.localizationKey, "iptv_error_storage")
        XCTAssertEqual(IPTVFailureKind.invalidAddress.localizationKey, "iptv_error_address")
        XCTAssertEqual(IPTVFailureKind.other.localizationKey, "iptv_load_error")
    }
}
