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
        reporter.seeked(item, to: 40, duration: 100)
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

    // MARK: Duration arriving after playing

    @MainActor
    private func recordingReporter() -> (TrackingAddonPlaybackReporter, () -> [String]) {
        var events: [String] = []
        let reporter = TrackingAddonPlaybackReporter { action, item, time, duration in
            events.append("\(action.rawValue) \(item.videoId) \(Int(time))/\(Int(duration))")
        }
        return (reporter, { events })
    }

    private let film = TrackingAddonPlaybackReporter.Item(type: "movie", videoId: "tt1")

    @MainActor
    func testStartWaitsForTheDurationAndGoesOutWhenItArrives() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 0, duration: 0)
        XCTAssertEqual(events(), [])

        reporter.durationAvailable(item: film, currentTime: 2, duration: 100)
        XCTAssertEqual(events(), ["start tt1 2/100"])
        // Further time updates send nothing more.
        reporter.durationAvailable(item: film, currentTime: 3, duration: 100)
        XCTAssertEqual(events(), ["start tt1 2/100"])
    }

    @MainActor
    func testAPauseBeforeTheDurationGoesOutAfterTheStart() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 0, duration: 0)
        reporter.report(.pause, item: film, currentTime: 0, duration: 0)
        reporter.durationAvailable(item: film, currentTime: 4, duration: 100)
        XCTAssertEqual(events(), ["start tt1 4/100", "pause tt1 4/100"])
    }

    @MainActor
    func testAStatusChangeWithTheDurationSendsWhatWaitedFirst() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 0, duration: 0)
        reporter.report(.pause, item: film, currentTime: 6, duration: 100)
        XCTAssertEqual(events(), ["start tt1 6/100", "pause tt1 6/100"])
    }

    @MainActor
    func testClosingBeforeTheDurationIsKnownSendsNothing() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 0, duration: 0)
        reporter.report(.pause, item: film, currentTime: 0, duration: 0)
        reporter.stop(timingFor: film, currentTime: 0, duration: 0)
        reporter.durationAvailable(item: film, currentTime: 1, duration: 100)
        XCTAssertEqual(events(), [])
    }

    @MainActor
    func testClosingOnceTheDurationIsKnownSendsStartThenStop() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 0, duration: 0)
        // Closed before a time update published it, but the duration is known by now.
        reporter.stop(timingFor: film, currentTime: 9, duration: 100)
        XCTAssertEqual(events(), ["start tt1 9/100", "stop tt1 9/100"])
    }

    @MainActor
    func testAnotherVideoBeforeTheDurationDropsTheFirstOnesEvents() {
        let (reporter, events) = recordingReporter()
        let episode = TrackingAddonPlaybackReporter.Item(type: "series", videoId: "tt2:1:1")
        reporter.report(.start, item: film, currentTime: 0, duration: 0)
        reporter.report(.start, item: episode, currentTime: 0, duration: 0)
        reporter.durationAvailable(item: episode, currentTime: 1, duration: 1_500)
        XCTAssertEqual(events(), ["start tt2:1:1 1/1500"])
    }

    @MainActor
    func testASeekBeforeAnythingWasSentSendsNothing() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 0, duration: 0)
        reporter.seeked(film, to: 30, duration: 100)
        XCTAssertEqual(events(), [])
        reporter.durationAvailable(item: film, currentTime: 30, duration: 100)
        XCTAssertEqual(events(), ["start tt1 30/100"])
    }

    // MARK: Pending events and another item's timing

    private let other = TrackingAddonPlaybackReporter.Item(type: "series", videoId: "tt9:1:2")

    @MainActor
    func testAnotherItemsStatusEventDropsThePendingEventsInsteadOfLendingThemItsTiming() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 0, duration: 0)
        reporter.report(.pause, item: film, currentTime: 0, duration: 0)
        // B reports with its own known duration while A still waits.
        reporter.report(.start, item: other, currentTime: 12, duration: 2_400)
        XCTAssertEqual(events(), ["start tt9:1:2 12/2400"], "A must not go out with B's position and duration")
        // A's duration arriving later can't bring A's events back.
        reporter.durationAvailable(item: film, currentTime: 3, duration: 100)
        XCTAssertEqual(events(), ["start tt9:1:2 12/2400"])
    }

    @MainActor
    func testAnotherItemsTimeUpdateDropsThePendingEvents() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 0, duration: 0)
        // A time update for B (the player moved on) while A still waits.
        reporter.durationAvailable(item: other, currentTime: 12, duration: 2_400)
        XCTAssertEqual(events(), [])
        reporter.durationAvailable(item: film, currentTime: 3, duration: 100)
        XCTAssertEqual(events(), [])
        // B's own events then go out normally.
        reporter.report(.start, item: other, currentTime: 13, duration: 2_400)
        XCTAssertEqual(events(), ["start tt9:1:2 13/2400"])
    }

    @MainActor
    func testATimeUpdateWithNoTrackableItemDropsPendingEvents() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 0, duration: 0)
        reporter.durationAvailable(item: nil, currentTime: 5, duration: 100)
        reporter.durationAvailable(item: film, currentTime: 6, duration: 100)
        XCTAssertEqual(events(), [])
    }

    @MainActor
    func testClosingWithAnotherItemsTimingSendsNothingForThePendingOne() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 0, duration: 0)
        reporter.stop(timingFor: other, currentTime: 40, duration: 2_400)
        XCTAssertEqual(events(), [])
    }

    // MARK: Stopping the reported item

    @MainActor
    func testChangingFromAStartedItemToAnotherStopsTheFirst() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 10, duration: 100)
        reporter.report(.start, item: other, currentTime: 0, duration: 2_400)
        XCTAssertEqual(events(), ["start tt1 10/100", "stop tt1 10/100", "start tt9:1:2 0/2400"])
    }

    @MainActor
    func testStopWithoutArgumentsStopsTheReportedItemAtItsLastPosition() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 10, duration: 100)
        reporter.report(.pause, item: film, currentTime: 25, duration: 100)
        reporter.stop()
        XCTAssertEqual(events(), ["start tt1 10/100", "pause tt1 25/100", "stop tt1 25/100"])
        // Already stopped: nothing more.
        reporter.stop()
        XCTAssertEqual(events().count, 3)
    }

    @MainActor
    func testClosingWithAnotherItemsTimingStopsTheReportedItemWithItsOwnTiming() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 30, duration: 100)
        // The player's time already belongs to B, which was never reported.
        reporter.stop(timingFor: other, currentTime: 40, duration: 2_400)
        XCTAssertEqual(events(), ["start tt1 30/100", "stop tt1 30/100"], "A keeps its own timing, and B gets no stop")
    }

    @MainActor
    func testClosingWithTheReportedItemsTimingUsesIt() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 30, duration: 100)
        reporter.stop(timingFor: film, currentTime: 55, duration: 100)
        XCTAssertEqual(events(), ["start tt1 30/100", "stop tt1 55/100"])
    }

    // MARK: Seeks and item identity

    @MainActor
    func testASeekInTheReportedItemSendsItsState() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 10, duration: 100)
        reporter.seeked(film, to: 60, duration: 100)
        XCTAssertEqual(events(), ["start tt1 10/100", "start tt1 60/100"])
    }

    @MainActor
    func testASeekInTheNextVideoIsNotSentAsProgressForThePreviousOne() {
        let (reporter, events) = recordingReporter()
        reporter.report(.start, item: film, currentTime: 90, duration: 100)
        // The next episode loads and resumes at 20 min before its first status is reported.
        reporter.seeked(other, to: 1_200, duration: 2_400)
        reporter.seeked(nil, to: 1_200, duration: 2_400)
        XCTAssertEqual(events(), ["start tt1 90/100"])

        // Its first status then stops A at A's own position and starts B.
        reporter.report(.start, item: other, currentTime: 1_200, duration: 2_400)
        XCTAssertEqual(events(), ["start tt1 90/100", "stop tt1 90/100", "start tt9:1:2 1200/2400"])
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

    // MARK: Events owned by another profile

    func testAnEventGoesWhereItsOwnProfileConsentedEvenIfAnotherIsActive() {
        let owner = "tracking-owner-\(UUID().uuidString)"
        let other = "tracking-other-\(UUID().uuidString)"
        defer {
            for id in [owner, other] {
                UserDefaults.standard.removePersistentDomain(forName: "nuvio.tv.profile.settings.\(id)")
            }
        }
        let ownerDefaults = ProfileSettings.store(for: owner)
        ownerDefaults.set(#"[{"url":"\#(manifestURL.absoluteString)","enabled":true}]"#, forKey: SettingsKey.streamAddonManifestStates)
        TrackingAddonService.setApproved(true, manifestURL: manifestURL, in: ownerDefaults)
        // The other profile has the add-on installed but never consented.
        ProfileSettings.store(for: other).set(
            #"[{"url":"\#(manifestURL.absoluteString)","enabled":true}]"#, forKey: SettingsKey.streamAddonManifestStates
        )

        let forOwner = TrackingAddonService.eventTargets(profileID: .some(owner))
        XCTAssertEqual(forOwner.profileID, owner)
        XCTAssertEqual(forOwner.manifestURLs, [manifestURL])
        XCTAssertEqual(TrackingAddonService.eventTargets(profileID: .some(other)).manifestURLs, [])
    }
}

