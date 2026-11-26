import XCTest
@testable import NuvioTV

/// The IMDb id Trakt requests are sent with, read from a title's id.
final class TraktMetaIDsTests: XCTestCase {
    private func meta(_ id: String, imdbId: String? = nil) -> NuvioMeta {
        NuvioMeta(id: id, name: "Title", imdbId: imdbId, type: "series")
    }

    /// Some add-ons put their own prefix in front of the IMDb id.
    func testAnIMDbIDAfterAnAddonPrefixIsFound() {
        XCTAssertEqual(TraktMetaIDs.imdb(for: meta("cotonet:tt16418808")), "tt16418808")
        XCTAssertEqual(TraktMetaIDs.imdb(for: meta("ptgdrive:tt12853970")), "tt12853970")
        XCTAssertEqual(TraktMetaIDs.imdb(for: meta("cotonet:tt16418808:1:3")), "tt16418808")
    }

    func testIDsThatAlreadyWorkedReadTheSame() {
        XCTAssertEqual(TraktMetaIDs.imdb(for: meta("tt0944947")), "tt0944947")
        XCTAssertEqual(TraktMetaIDs.imdb(for: meta("tt0944947:1:2")), "tt0944947")
        XCTAssertEqual(TraktMetaIDs.imdb(for: meta("cotonet:tt9", imdbId: "tt5")), "tt5")
    }

    func testIDsWithoutAnIMDbIDHaveNone() {
        XCTAssertNil(TraktMetaIDs.imdb(for: meta("tmdb:1399")))
        XCTAssertNil(TraktMetaIDs.imdb(for: meta("kitsu:12")))
        XCTAssertNil(TraktMetaIDs.imdb(for: meta("addon:ttx12")))
        XCTAssertNil(TraktMetaIDs.imdb(for: meta("addon:tt")))
    }
}
