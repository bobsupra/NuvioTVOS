import XCTest
@testable import NuvioTV

final class TrackingAddonServiceTests: XCTestCase {
    private let manifestURL = URL(string: "https://tracker.example.com/abc123/manifest.json")!

    func testPlayerURLMatchesStremioProtocol() {
        let url = TrackingAddonService.playerURL(
            manifestURL: manifestURL,
            type: "series",
            videoId: "tt0898266:9:17",
            action: .start,
            currentTimeMs: 61_500,
            durationMs: 1_320_000
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://tracker.example.com/abc123/player/series/tt0898266%3A9%3A17/action=start&currentTime=61500&duration=1320000.json"
        )
    }

    func testPlayerURLKeepsManifestQuery() {
        let url = TrackingAddonService.playerURL(
            manifestURL: URL(string: "https://tracker.example.com/manifest.json?token=xyz")!,
            type: "movie",
            videoId: "tt1254207",
            action: .stop,
            currentTimeMs: 0,
            durationMs: 5_000
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://tracker.example.com/player/movie/tt1254207/action=stop&currentTime=0&duration=5000.json?token=xyz"
        )
    }

    func testLibraryURLs() {
        XCTAssertEqual(
            TrackingAddonService.libraryURLs(manifestURL: manifestURL, type: "movie", id: "tt1254207", action: .libraryAdd)
                .map(\.absoluteString),
            ["https://tracker.example.com/abc123/library/movie/tt1254207/action=libraryAdd.json"]
        )
        XCTAssertEqual(
            TrackingAddonService.libraryURLs(
                manifestURL: manifestURL,
                type: "series",
                id: "tt0898266",
                action: .watched,
                videoIds: ["tt0898266:1:1", "tt0898266:1:2"]
            ).map(\.absoluteString),
            ["https://tracker.example.com/abc123/library/series/tt0898266/action=watched&videoId=tt0898266%3A1%3A1,tt0898266%3A1%3A2.json"]
        )
    }

    func testWatchedVideoIdsAreSplitIntoEventsOfAtMost100() {
        let ids = (1...150).map { "tt1:1:\($0)" }
        let extras = TrackingAddonService.libraryExtras(action: .watched, videoIds: ids)
        XCTAssertEqual(extras.count, 2)
        XCTAssertEqual(extras[0].components(separatedBy: ",").count, 100)
        XCTAssertEqual(extras[1].components(separatedBy: ",").count, 50)
    }

    func testVideoIdsAreIgnoredForMembershipActions() {
        XCTAssertEqual(
            TrackingAddonService.libraryExtras(action: .libraryRemove, videoIds: ["tt1:1:1"]),
            ["action=libraryRemove"]
        )
    }

    func testManifestDecodingAndMatching() throws {
        let json = """
        {
          "id": "org.example.tracker",
          "name": "Tracker",
          "types": ["movie", "series"],
          "idPrefixes": ["tt"],
          "resources": ["catalog", { "name": "player", "types": ["movie"] }, "library"]
        }
        """
        let manifest = try JSONDecoder().decode(TrackingAddonManifest.self, from: Data(json.utf8))
        XCTAssertTrue(manifest.isTrackingAddon)
        XCTAssertTrue(manifest.tracksPlayback)
        XCTAssertTrue(manifest.tracksLibrary)
        XCTAssertTrue(manifest.supports("player", type: "movie", id: "tt1254207"))
        XCTAssertFalse(manifest.supports("player", type: "series", id: "tt0898266:1:1"))
        XCTAssertTrue(manifest.supports("library", type: "series", id: "tt0898266"))
        XCTAssertFalse(manifest.supports("library", type: "series", id: "kitsu:1"))
    }

    func testManifestWithoutTrackingResources() throws {
        let json = #"{ "id": "a", "resources": ["stream", "catalog"] }"#
        let manifest = try JSONDecoder().decode(TrackingAddonManifest.self, from: Data(json.utf8))
        XCTAssertFalse(manifest.isTrackingAddon)
    }

    func testConsentIsStoredPerManifest() {
        let defaults = UserDefaults(suiteName: "TrackingAddonServiceTests")!
        defaults.removePersistentDomain(forName: "TrackingAddonServiceTests")
        XCTAssertFalse(TrackingAddonService.isApproved(manifestURL, in: defaults))
        TrackingAddonService.setApproved(true, manifestURL: manifestURL, in: defaults)
        XCTAssertTrue(TrackingAddonService.isApproved(manifestURL, in: defaults))
        TrackingAddonService.setApproved(false, manifestURL: manifestURL, in: defaults)
        XCTAssertFalse(TrackingAddonService.isApproved(manifestURL, in: defaults))
    }

    @MainActor
    func testReporterSendsStartPauseSeekAndStop() {
        var events: [String] = []
        let reporter = TrackingAddonPlaybackReporter { action, item, time, duration in
            events.append("\(action.rawValue) \(item.videoId) \(Int(time))/\(Int(duration))")
        }
        let item = TrackingAddonPlaybackReporter.Item(type: "movie", videoId: "tt1")

        reporter.report(.start, item: item, currentTime: 0, duration: 100)
        reporter.report(.start, item: item, currentTime: 5, duration: 100)
        reporter.report(.pause, item: item, currentTime: 10, duration: 100)
        reporter.seeked(to: 40, duration: 100)
        reporter.report(.start, item: item, currentTime: 40, duration: 100)
        reporter.stop(currentTime: 55, duration: 100)
        reporter.stop(currentTime: 55, duration: 100)

        XCTAssertEqual(events, [
            "start tt1 0/100",
            "pause tt1 10/100",
            "pause tt1 40/100",
            "start tt1 40/100",
            "stop tt1 55/100",
        ])
    }

    @MainActor
    func testReporterStopsThePreviousVideoWhenTheVideoChanges() {
        var events: [String] = []
        let reporter = TrackingAddonPlaybackReporter { action, item, time, _ in
            events.append("\(action.rawValue) \(item.videoId) \(Int(time))")
        }
        let first = TrackingAddonPlaybackReporter.Item(type: "series", videoId: "tt1:1:1")
        let second = TrackingAddonPlaybackReporter.Item(type: "series", videoId: "tt1:1:2")

        reporter.report(.start, item: first, currentTime: 1300, duration: 1320)
        reporter.report(.start, item: second, currentTime: 0, duration: 1320)

        XCTAssertEqual(events, ["start tt1:1:1 1300", "stop tt1:1:1 1300", "start tt1:1:2 0"])
    }

    @MainActor
    func testReporterIgnoresUnknownDuration() {
        var events: [String] = []
        let reporter = TrackingAddonPlaybackReporter { action, _, _, _ in events.append(action.rawValue) }
        reporter.report(.start, item: .init(type: "movie", videoId: "tt1"), currentTime: 0, duration: 0)
        reporter.stop()
        XCTAssertEqual(events, [])
    }
}
