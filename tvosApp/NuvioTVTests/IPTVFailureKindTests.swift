import XCTest
@testable import NuvioTV

final class IPTVFailureKindTests: XCTestCase {
    func testCommonFailuresMapToUsefulCategories() {
        XCTAssertEqual(IPTVFailureKind.classify(IPTVPlaylistLoadError.httpStatus(403)), .authentication)
        XCTAssertEqual(IPTVFailureKind.classify(IPTVXtreamError.authenticationFailed), .authentication)
        XCTAssertEqual(IPTVFailureKind.classify(IPTVStalkerError.tooLarge), .tooLarge)
        XCTAssertEqual(IPTVFailureKind.classify(IPTVPlaylistParser.ParserError.hlsPlaylist), .invalidContent)
        XCTAssertEqual(IPTVFailureKind.classify(URLError(.timedOut)), .network)
    }
}
