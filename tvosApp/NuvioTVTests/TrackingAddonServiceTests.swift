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

    private actor Recorder {
        private(set) var events: [String] = []
        func add(_ event: String) { events.append(event) }
    }

    func testEventsForOneAddonArriveInOrderEvenWhenTheFirstIsSlow() async {
        let queue = TrackingEventQueue()
        let recorder = Recorder()
        queue.enqueue(key: "addon") {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await recorder.add("start")
        }
        queue.enqueue(key: "addon") {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await recorder.add("pause")
        }
        let last = queue.enqueue(key: "addon") { await recorder.add("stop") }
        await last.value
        let events = await recorder.events
        XCTAssertEqual(events, ["start", "pause", "stop"])
    }

    func testASlowAddonDoesNotHoldUpAnother() async {
        let queue = TrackingEventQueue()
        let recorder = Recorder()
        let slow = queue.enqueue(key: "slow") {
            try? await Task.sleep(nanoseconds: 300_000_000)
            await recorder.add("slow")
        }
        let fast = queue.enqueue(key: "fast") { await recorder.add("fast") }
        await fast.value
        let afterFast = await recorder.events
        XCTAssertEqual(afterFast, ["fast"])
        await slow.value
    }

    /// A profile's settings with the tracker installed and, optionally, approved.
    private func profileDefaults(_ name: String, approved: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(#"[{"url":"\#(manifestURL.absoluteString)","enabled":true}]"#, forKey: SettingsKey.streamAddonManifestStates)
        TrackingAddonService.setApproved(approved, manifestURL: manifestURL, in: defaults)
        return defaults
    }

    private func deliverStart(defaults: UserDefaults, recorder: Recorder) async {
        await TrackingAddonService.deliver(
            to: manifestURL, resource: "player", type: "movie", id: "tt1",
            defaults: defaults,
            urls: { [$0] },
            send: { request in await recorder.add(request.url?.absoluteString ?? "") },
            manifest: { _ in TrackingAddonManifest(resources: [.init(name: "player")]) }
        )
    }

    func testAQueuedEventIsDroppedWhenTheAddonIsTurnedOffWhileItWaits() async {
        let defaults = profileDefaults("TrackingQueueTurnedOff", approved: true)
        XCTAssertTrue(TrackingAddonService.mayReceiveEvents(manifestURL, in: defaults))
        let queue = TrackingEventQueue()
        let recorder = Recorder()
        queue.enqueue(key: manifestURL.absoluteString) {
            try? await Task.sleep(nanoseconds: 200_000_000)   // a slow earlier request
        }
        let waiting = queue.enqueue(key: manifestURL.absoluteString) {
            await self.deliverStart(defaults: defaults, recorder: recorder)
        }
        TrackingAddonService.setApproved(false, manifestURL: manifestURL, in: defaults)
        await waiting.value
        let sent = await recorder.events
        XCTAssertEqual(sent, [])
    }

    func testAQueuedEventIsSentWhenTheAddonStaysOn() async {
        let defaults = profileDefaults("TrackingQueueStaysOn", approved: true)
        let queue = TrackingEventQueue()
        let recorder = Recorder()
        queue.enqueue(key: manifestURL.absoluteString) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await queue.enqueue(key: manifestURL.absoluteString) {
            await self.deliverStart(defaults: defaults, recorder: recorder)
        }.value
        let sent = await recorder.events
        XCTAssertEqual(sent, [manifestURL.absoluteString])
    }

    func testEventsUseTheApprovalOfTheProfileThatProducedThem() async {
        // Switching profiles doesn't drop them: each event carries its own
        // profile's settings, not whichever profile is active when it runs.
        let approving = profileDefaults("TrackingProfileApproving", approved: true)
        let other = profileDefaults("TrackingProfileOther", approved: false)
        let recorder = Recorder()
        await deliverStart(defaults: approving, recorder: recorder)
        await deliverStart(defaults: other, recorder: recorder)
        let sent = await recorder.events
        XCTAssertEqual(sent.count, 1)
    }

    private func deliverStart(
        defaults: UserDefaults,
        recorder: Recorder,
        whileManifestLoads change: @escaping @Sendable () -> Void
    ) async {
        await TrackingAddonService.deliver(
            to: manifestURL, resource: "player", type: "movie", id: "tt1",
            defaults: defaults,
            urls: { [$0] },
            send: { request in await recorder.add(request.url?.absoluteString ?? "") },
            manifest: { _ in
                change()
                return TrackingAddonManifest(resources: [.init(name: "player")])
            }
        )
    }

    func testNothingIsSentWhenTheAddonIsTurnedOffWhileItsManifestLoads() async {
        let defaults = profileDefaults("TrackingManifestTurnedOff", approved: true)
        let recorder = Recorder()
        let url = manifestURL
        await deliverStart(defaults: defaults, recorder: recorder) {
            TrackingAddonService.setApproved(false, manifestURL: url, in: defaults)
        }
        let sent = await recorder.events
        XCTAssertEqual(sent, [])
    }

    func testNothingIsSentWhenTheAddonIsDisabledWhileItsManifestLoads() async {
        let defaults = profileDefaults("TrackingManifestDisabled", approved: true)
        let recorder = Recorder()
        let url = manifestURL
        await deliverStart(defaults: defaults, recorder: recorder) {
            defaults.set(#"[{"url":"\#(url.absoluteString)","enabled":false}]"#, forKey: SettingsKey.streamAddonManifestStates)
        }
        let sent = await recorder.events
        XCTAssertEqual(sent, [])
    }

    func testNothingIsSentWhenTheAddonIsUninstalledWhileItsManifestLoads() async {
        let defaults = profileDefaults("TrackingManifestUninstalled", approved: true)
        let recorder = Recorder()
        await deliverStart(defaults: defaults, recorder: recorder) {
            defaults.set("[]", forKey: SettingsKey.streamAddonManifestStates)
        }
        let sent = await recorder.events
        XCTAssertEqual(sent, [])
    }
}
