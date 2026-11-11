//
//  PluginAIOBridgeTests.swift
//  NuvioTVTests
//
//  Plugins set "Through AIOStreams" reach the AIOStreams in
//  Nuvio as Stremio add-ons (PluginAIOBridge) — their manifests, their
//  streams as Stremio stream objects, and what Nuvio keeps for itself.
//

import XCTest
@testable import NuvioTV

final class PluginAIOBridgeTests: XCTestCase {
    private func record(
        resources: [String],
        idPrefixes: [String]? = nil,
        catalogs: String? = nil,
        ratingSources: String? = nil,
        version: String = "1.0.0",
        throughAIO: Bool? = true
    ) -> PluginScraperRecord {
        var record = PluginScraperRecord(
            id: "https://example.com/manifest.json:aio-test", repositoryURL: "https://example.com/manifest.json",
            scraperID: "aio-test", name: "AIO Test", description: "", version: version, filename: "aio-test.js",
            supportedTypes: ["movie", "tv"], enabled: true, manifestEnabled: true, hasSettings: false, logo: nil,
            contentLanguage: [], formats: nil, declaresSeriesType: nil, resources: resources, idPrefixes: idPrefixes,
            catalogsJSON: catalogs, ratingSourcesJSON: ratingSources
        )
        record.throughAIO = throughAIO
        return record
    }

    func testManifestHasStreamsSubtitlesCatalogsAndMetadataButNoRatings() throws {
        let plugin = record(
            resources: ["stream", "subtitles", "catalog", "meta", "ratings"],
            idPrefixes: ["tvmaze:", "tt"],
            catalogs: #"[{"type":"tv","id":"today","name":"Today"}]"#,
            ratingSources: #"[{"source":"tvmaze","name":"TVmaze","max":10}]"#
        )
        let manifest = PluginAIOBridge.manifest(for: plugin)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(manifest))
        XCTAssertEqual(manifest["id"] as? String, "nuvio.plugin.aio." + PluginAddonRegistry.key(for: plugin.id))
        XCTAssertEqual(manifest["name"] as? String, "AIO Test")
        XCTAssertEqual(manifest["version"] as? String, "1.0.0")
        let resources = try XCTUnwrap(manifest["resources"] as? [[String: Any]])
        XCTAssertEqual(resources.compactMap { $0["name"] as? String }, ["catalog", "meta", "stream", "subtitles"])
        let stream = try XCTUnwrap(resources.first { $0["name"] as? String == "stream" })
        XCTAssertEqual(stream["idPrefixes"] as? [String], ["tvmaze:", "tt"])
        XCTAssertEqual(Set(stream["types"] as? [String] ?? []), ["movie", "series"])
        XCTAssertEqual((manifest["catalogs"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(manifest["ratingSources"], "ratings stay in Nuvio")
    }

    func testStreamsWithoutOwnPrefixesAreForIMDbAndTMDBIds() throws {
        let manifest = PluginAIOBridge.manifest(for: record(resources: ["stream"], version: "7"))
        let resources = try XCTUnwrap(manifest["resources"] as? [[String: Any]])
        XCTAssertEqual(resources.count, 1)
        XCTAssertEqual(resources[0]["idPrefixes"] as? [String], ["tt", "tmdb:"])
        XCTAssertEqual(manifest["version"] as? String, "1.0.0", "AIOStreams wants x.y.z")
        XCTAssertEqual((manifest["catalogs"] as? [[String: Any]])?.count, 0)
    }

    func testGetStreamsResultsBecomeStremioStreamsAndUnplayableOnesAreLeftOut() throws {
        let plugin = record(resources: ["stream"])
        let result: [Any] = [
            ["url": "https://cdn.example.com/a.mkv", "name": "Host", "title": "Movie 1080p", "headers": ["Referer": "https://example.com/"]],
            ["title": "nothing to play"],
            ["infoHash": "0123456789abcdef0123456789abcdef01234567", "fileIdx": 2, "name": "Torrent"],
            ["nzbUrl": "https://indexer.example.com/get/1.nzb", "name": "Usenet"],
            "not an object"
        ]
        let streams = PluginAIOBridge.streamObjects(from: result, scraper: plugin)
        XCTAssertEqual(streams.count, 3)
        XCTAssertEqual(streams[0]["url"] as? String, "https://cdn.example.com/a.mkv")
        XCTAssertEqual(streams[0]["title"] as? String, "Movie 1080p")
        let hints = try XCTUnwrap(streams[0]["behaviorHints"] as? [String: Any])
        let headers = (hints["proxyHeaders"] as? [String: Any])?["request"] as? [String: Any]
        XCTAssertEqual(headers?["Referer"] as? String, "https://example.com/", "AIOStreams passes the plugin's headers on")
        XCTAssertEqual(streams[1]["infoHash"] as? String, "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(streams[1]["fileIdx"] as? Int, 2)
        XCTAssertEqual(streams[2]["nzbUrl"] as? String, "https://indexer.example.com/get/1.nzb")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["streams": streams]))
        XCTAssertTrue(PluginAIOBridge.streamObjects(from: ["streams": []], scraper: plugin).isEmpty)
    }

    func testNuvioShowsThePluginItselfWhileAIOStreamsDoesNotServeIt() {
        // AIOStreams is not running in the tests: every plugin is shown directly.
        XCTAssertFalse(AIOStreamsHost.isServingAddon)
        XCTAssertFalse(PluginAIOBridge.servesThroughAIO(record(resources: ["stream"], throughAIO: true)))
        XCTAssertFalse(PluginAIOBridge.servesThroughAIO(record(resources: ["stream"], throughAIO: nil)))
    }

    func testRatingsOnlyManifestForWhileAIOStreamsServesTheRest() throws {
        let plugin = record(
            resources: ["catalog", "ratings"],
            idPrefixes: ["tt"],
            catalogs: #"[{"type":"movie","id":"top","name":"Top"}]"#,
            ratingSources: #"[{"source":"aio-test","name":"Test","max":10}]"#
        )
        let ratings = try XCTUnwrap(PluginAddonRegistry.manifest(for: plugin, only: [PluginResources.ratings]))
        XCTAssertEqual((ratings["resources"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["ratings"])
        XCTAssertEqual((ratings["catalogs"] as? [[String: Any]])?.count ?? 0, 0)
        XCTAssertNil(PluginAddonRegistry.manifest(for: record(resources: ["catalog"], catalogs: #"[{"type":"movie","id":"top","name":"Top"}]"#), only: [PluginResources.ratings]))
        // The whole virtual add-on is unchanged.
        let all = try XCTUnwrap(PluginAddonRegistry.manifest(for: plugin))
        XCTAssertEqual((all["resources"] as? [[String: Any]])?.compactMap { $0["name"] as? String }, ["catalog", "ratings"])
    }

    func testHandleAnswersHealthAndUnknownPaths() async {
        func request(_ path: String) -> PluginAIOBridge.Request {
            PluginAIOBridge.Request(method: "GET", path: path, query: [:], body: Data())
        }
        let health = await PluginAIOBridge.handle(request("stremio/health"))
        XCTAssertEqual(health.status, 200)
        let unknown = await PluginAIOBridge.handle(request("stremio/p/0000000000000000/manifest.json"))
        XCTAssertEqual(unknown.status, 404)
    }
}
