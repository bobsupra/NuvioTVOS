import XCTest
@testable import NuvioTV

final class FocusedStreamWarmPolicyTests: XCTestCase {
    private let addons = [
        URL(string: "https://aiostreams.example.com/stremio/abc/manifest.json")!,
        URL(string: "https://torrentio.strem.fun/realdebrid=x/manifest.json")!,
    ]

    func testLinksAnAddonResolvesOnRequestAreNeverWarmed() {
        // AIOStreams (Debrid or Usenet) and Torrentio links point back at the add-on.
        for raw in [
            "https://aiostreams.example.com/api/v1/debrid/playback/xyz/file.mkv",
            "https://aiostreams.example.com/usenet/nzbdav/abc",
            "https://torrentio.strem.fun/resolve/realdebrid/key/hash/null/0/file.mkv",
        ] {
            XCTAssertFalse(
                FocusedStreamWarmPolicy.mayWarm(url: URL(string: raw)!, backgroundPreFetchEnabled: true, addonManifestURLs: addons),
                raw
            )
        }
    }

    func testDirectFilesAreWarmedOnlyWithBackgroundPreFetchOn() {
        let direct = URL(string: "https://cdn.example.net/movies/file.mp4")!
        XCTAssertTrue(FocusedStreamWarmPolicy.mayWarm(url: direct, backgroundPreFetchEnabled: true, addonManifestURLs: addons))
        XCTAssertFalse(FocusedStreamWarmPolicy.mayWarm(url: direct, backgroundPreFetchEnabled: false, addonManifestURLs: addons))
    }

    func testOnlyWebLinksAreWarmed() {
        let magnet = URL(string: "magnet:?xt=urn:btih:abc")!
        XCTAssertFalse(FocusedStreamWarmPolicy.mayWarm(url: magnet, backgroundPreFetchEnabled: true, addonManifestURLs: []))
    }
}
