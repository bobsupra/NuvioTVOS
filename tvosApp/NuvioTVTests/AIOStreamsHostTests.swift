//
//  AIOStreamsHostTests.swift
//  NuvioTVTests
//
//  Only with AIO_TESTS=1 (TEST_RUNNER_AIO_TESTS for xcodebuild), as it downloads
//  AIOStreams' official image and leaves AIOStreams running for the rest of the
//  test run: installs the original AIOStreams from its official
//  image and starts it in Node.js inside the app on the tvOS simulator, as on
//  Apple TV; checks the version and for updates, saves a configuration like its page does and
//  asks the resulting addon for streams; then checks the backup, the warm-up
//  and that a configuration AIOStreams lost comes back from the backup.
//  Prints the timings and the log.
//

import XCTest
@testable import NuvioTV

@MainActor
final class AIOStreamsHostTests: XCTestCase {

    func testOriginalAIOStreamsRunsInsideNuvio() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AIO_TESTS"] == "1",
                          "Set AIO_TESTS=1 (TEST_RUNNER_AIO_TESTS) to run AIOStreams in the simulator")
        try XCTSkipUnless(AIOStreamsHost.isBundled, "This build has no AIOStreams installer")
        let aio = AIOStreamsHost.shared
        // AIOStreams runs on in this test run: its addon must not show up in the add-on lists
        // other tests check.
        addTeardownBlock { @MainActor in AIOStreamsHost.shared.setAddonEnabled(false) }
        let started = Date()
        aio.start()
        aio.setLogVisible(true)

        try await waitUntil(seconds: 600) {
            switch aio.phase {
            case .starting, .stopped: return false
            default: return true
            }
        }
        report("start", since: started)
        guard aio.phase == .running else {
            XCTFail("AIOStreams did not start: \(aio.phase)")
            return
        }

        // Installed from the official image; Nuvio's version port answers.
        await aio.refreshVersions()
        XCTAssertFalse(aio.packageVersion.isEmpty, "installed version")
        await aio.checkForUpdates()
        note("AIO-TEST installed \(aio.packageVersion) · newest \(aio.latestVersion ?? "?") · \(aio.updateStatus ?? "")")
        XCTAssertNotNil(aio.latestVersion, "check for updates")

        let local = "http://127.0.0.1:\(AIOStreamsHost.aioPort)"
        let page = "http://127.0.0.1:\(AIOStreamsHost.lanPort)"
        let health = try await status("\(local)/api/v1/health")
        XCTAssertEqual(health, 200)
        let configurationPage = try await status("\(page)/stremio/configure")
        XCTAssertEqual(configurationPage, 200, "configuration page through Nuvio's proxy")

        // Save a configuration through the proxy, as the page would: AIOStreams'
        // starter template with Torrentio only and no TMDB features.
        let body = try configuration()
        var request = URLRequest(url: URL(string: "\(page)/api/v1/user")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 120
        let (created, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201, String(decoding: created.prefix(400), as: UTF8.self))

        try await waitUntil(seconds: 15) { aio.manifestURL != nil }
        let manifest = try XCTUnwrap(aio.manifestURL, "Nuvio did not get the addon address")
        XCTAssertEqual(AIOStreamsHost.addonManifestURLs.map(\.absoluteString), [manifest], "the addon is offered to Nuvio")
        let manifestStatus = try await status(manifest)
        XCTAssertEqual(manifestStatus, 200)

        let streamURL = manifest.replacingOccurrences(of: "/manifest.json", with: "/stream/movie/tt0133093.json")
        for attempt in 1...2 {
            let begin = Date()
            let (data, answer) = try await URLSession.shared.data(from: URL(string: streamURL)!)
            XCTAssertEqual((answer as? HTTPURLResponse)?.statusCode, 200)
            let streams = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["streams"] as? [[String: Any]] ?? []
            note("AIO-TEST stream request \(attempt): \(streams.count) streams in \(Int(Date().timeIntervalSince(begin) * 1000)) ms; first: \(String(describing: streams.first?["name"] ?? "-"))")
        }
        // A title asked by two ids: AIOStreams' answers merged, every stream once.
        let first = try await StreamsRepository.fetchStreams(from: URL(string: streamURL)!, addonName: "AIOStreams", logo: nil)
        let again = try await StreamsRepository.fetchStreams(from: URL(string: streamURL)!, addonName: "AIOStreams", logo: nil)
        let merged = StreamsRepository.mergeStreamLists([first, again])
        note("AIO-TEST merge of two answers: \(first.count) + \(again.count) → \(merged.count)")
        XCTAssertEqual(merged.count, first.count, "the same answer twice merges into one")
        XCTAssertTrue(AIOStreamsHost.isAIOAddon(URL(string: manifest)!), "the addon is recognised as AIOStreams'")
        note("AIO-TEST ready in \(aio.startupSeconds ?? -1) s · Node \(aio.nodeMemoryMB ?? -1) MB · app \(aio.appMemoryMB ?? -1) MB · \(aio.packageVersion)")
        try await waitUntil(seconds: 10) { aio.startupProfile?.contains("first streams") == true }
        note("AIO-TEST times of the start: \(aio.startupProfile ?? "none")")
        XCTAssertNotNil(aio.startupProfile, "the times of the start")

        // The configuration page's save left a backup, and the warm-up ran.
        try await waitUntil(seconds: 15) { aio.hasBackup }
        XCTAssertTrue(aio.hasBackup, "the configuration is backed up")
        try await waitUntil(seconds: 120) { aio.lastWarmUp != nil }
        note("AIO-TEST warm-up: \(aio.lastWarmUp ?? "did not run")")
        XCTAssertNotNil(aio.lastWarmUp)

        // AIOStreams loses the configuration (as when tvOS clears Caches):
        // Nuvio restores it from the backup, with a new addon address.
        let uuid = try XCTUnwrap(AIOStreamsHost.uuid(fromManifest: manifest))
        var delete = URLRequest(url: URL(string: "\(local)/api/v1/user")!)
        delete.httpMethod = "DELETE"
        delete.setValue("Basic " + Data("\(uuid):nuvio-simulator-test".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let (deleted, deleteResponse) = try await URLSession.shared.data(for: delete)
        XCTAssertEqual((deleteResponse as? HTTPURLResponse)?.statusCode, 200, String(decoding: deleted.prefix(300), as: UTF8.self))
        await aio.checkConfiguration()
        let restored = try XCTUnwrap(aio.manifestURL, "restored from the backup")
        XCTAssertNotEqual(restored, manifest)
        XCTAssertEqual(AIOStreamsHost.addonManifestURLs.map(\.absoluteString), [restored])
        let restoredStreams = try await status(restored.replacingOccurrences(of: "/manifest.json", with: "/stream/movie/tt0133093.json"))
        XCTAssertEqual(restoredStreams, 200)
        note("AIO-TEST restore: \(AIOStreamsHost.uuid(fromManifest: restored) ?? "?") replaces \(uuid), streams HTTP \(restoredStreams)")
        note("AIO-TEST log:\n" + aio.logLines.suffix(60).joined(separator: "\n"))
    }

    /// An AniList title: the ids the AIOStreams addon is asked by, per setting.
    func testAnimeSearchRequestIDs() {
        let all: (String) -> Bool = { _ in true }
        let title = "anilist:16498:5"
        let alternatives = ["kitsu:7442:5", "tt2560140:1:5"]
        func ids(_ request: AIOStreamsHost.AnimeRequest, _ supports: (String) -> Bool = { _ in true }) -> [String] {
            AIOStreamsHost.requestIDs(videoId: title, alternatives: alternatives, request: request, supports: supports)
        }
        // Anything but an AniList title: its own id, whatever the setting.
        XCTAssertEqual(AIOStreamsHost.requestIDs(videoId: "tt0133093", alternatives: [], request: .both, supports: all), ["tt0133093"])
        XCTAssertEqual(AIOStreamsHost.requestIDs(videoId: "tt0133093", alternatives: [], request: .both, supports: { _ in false }), [])
        // An AniList title; of the converted ids IMDb first.
        XCTAssertEqual(ids(.aniList), [title])
        XCTAssertEqual(ids(.converted), ["tt2560140:1:5"])
        XCTAssertEqual(ids(.both), [title, "tt2560140:1:5"])
        // AIOStreams without anilist add-ons: the converted id, whatever the setting.
        let noAniList: (String) -> Bool = { !$0.hasPrefix("anilist:") }
        XCTAssertEqual(ids(.aniList, noAniList), ["tt2560140:1:5"])
        XCTAssertEqual(ids(.both, noAniList), ["tt2560140:1:5"])
        // AIOStreams without IMDb add-ons: Kitsu.
        XCTAssertEqual(ids(.both, { !$0.hasPrefix("tt") }), [title, "kitsu:7442:5"])
        // No conversion (yet): the AniList id alone.
        XCTAssertEqual(AIOStreamsHost.requestIDs(videoId: title, alternatives: [], request: .both, supports: all), [title])

        XCTAssertTrue(AIOStreamsHost.isAIOAddon(URL(string: "http://127.0.0.1:\(AIOStreamsHost.aioPort)/stremio/u/p/manifest.json")!))
        XCTAssertFalse(AIOStreamsHost.isAIOAddon(URL(string: "https://torrentio.strem.fun/manifest.json")!))
        XCTAssertFalse(AIOStreamsHost.isAIOAddon(URL(string: "http://127.0.0.1:\(AIOStreamsHost.aioPort)/api/v1/health")!))
    }

    /// Two answers merged: what the second repeats is left out, nothing of the first.
    func testMergingTwoAnswersKeepsEachStreamOnce() {
        let hash = "abcdef0123456789abcdef0123456789abcdef01"
        let a = NuvioStream(url: "https://aio.example/play/1", name: "TB 1080p", description: nil, addonName: "AIO",
                            filename: "Show.S01E05.1080p.mkv", videoSize: 1_000)
        // The same file through another debrid service, in the same answer: stays.
        let aOtherService = NuvioStream(url: "https://aio.example/play/2", name: "RD 1080p", description: nil, addonName: "AIO",
                                        filename: "Show.S01E05.1080p.mkv", videoSize: 1_000)
        let b = NuvioStream(url: nil, name: "P2P 720p", description: nil, addonName: "AIO", infoHash: hash, fileIdx: 2)
        // The second answer: a again (another link), b again, and c.
        let aAgain = NuvioStream(url: "https://aio.example/play/1?id=tt", name: "TB 1080p", description: nil, addonName: "AIO",
                                 filename: "show.s01e05.1080p.mkv", videoSize: 1_000)
        let bAgain = NuvioStream(url: nil, name: "P2P 720p", description: nil, addonName: "AIO", infoHash: hash.uppercased(), fileIdx: 2)
        let c = NuvioStream(url: "https://aio.example/play/3", name: "TB 2160p", description: nil, addonName: "AIO")
        let merged = StreamsRepository.mergeStreamLists([[a, aOtherService, b], [aAgain, c, bAgain]])
        XCTAssertEqual(merged.map(\.name), ["TB 1080p", "RD 1080p", "P2P 720p", "TB 2160p"])
    }

    // MARK: - Helpers

    /// Printed, and written to the file in AIO_REPORT (set by the workflow as
    /// TEST_RUNNER_AIO_REPORT), because xcodebuild -quiet hides test output.
    private func note(_ text: String) {
        print(text)
        guard let path = ProcessInfo.processInfo.environment["AIO_REPORT"], !path.isEmpty else { return }
        let line = Data((text + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: line)
        }
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func status(_ url: String) async throws -> Int {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 60
        let (_, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func report(_ step: String, since start: Date) {
        note("AIO-TEST \(step): \(String(format: "%.1f", Date().timeIntervalSince(start))) s, phase \(AIOStreamsHost.shared.phase)")
        note("AIO-TEST log so far:\n" + AIOStreamsHost.shared.logLines.suffix(40).joined(separator: "\n"))
    }

    /// The starter template from the installed version.
    private func configuration() throws -> Data {
        let home = try XCTUnwrap(AIOStreamsHost.versionsHome)
        let versions = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent("versions.json"))) as? [String: Any])
        let current = try XCTUnwrap(versions["current"] as? String)
        let template = home
            .appendingPathComponent(current)
            .appendingPathComponent("resources/templates/debrid-starter.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: template)) as? [String: Any])
        var config = try XCTUnwrap(object["config"] as? [String: Any])
        let presets = (config["presets"] as? [[String: Any]]) ?? []
        config["presets"] = presets.filter { $0["type"] as? String == "torrentio" }
        config["tmdbApiKey"] = nil
        config["tmdbAccessToken"] = nil
        for key in ["titleMatching", "yearMatching", "digitalReleaseFilter"] {
            if var feature = config[key] as? [String: Any] {
                feature["enabled"] = false
                config[key] = feature
            }
        }
        return try JSONSerialization.data(withJSONObject: ["config": config, "password": "nuvio-simulator-test"])
    }
}
