import XCTest
@testable import NuvioTV

final class IPTVReshapedSourceMappingTests: XCTestCase {
    func testM3UImportReusesLocalIDByCanonicalIdentity() {
        let existingID = UUID()
        let existing = IPTVSource(id: existingID, name: "Local", playlistURL: "https://example.test/live.m3u")
        let imported = IPTVReshapedSourceMapping.source(from: [
            "id": "reshaped-source",
            "type": "M3u",
            "url": "HTTPS://EXAMPLE.TEST/LIVE.M3U",
            "name": "Upstream",
            "epg": "https://example.test/guide.xml",
            "ua": "FixtureAgent",
        ], existingSources: [existing])

        XCTAssertEqual(imported?.id, existingID)
        XCTAssertEqual(imported?.kind, .m3u)
        XCTAssertEqual(IPTVReshapedSourceMapping.canonicalIdentity(for: existing), "m3u|https://example.test/live.m3u")
    }

    func testXtreamReimportPreservesLocalOutputSetting() {
        let existingID = UUID()
        let existing = IPTVSource(id: existingID, name: "Local", playlistURL: "https://xtream.example.test:8443",
                                  kind: .xtream, username: "viewer", password: "local-secret", xtreamOutput: .hls)
        let imported = IPTVReshapedSourceMapping.source(from: [
            "type": "Xtream", "server": "HTTPS://XTREAM.EXAMPLE.TEST:8443", "user": "viewer",
            "password": "upstream-secret", "name": "Upstream",
        ], existingSources: [existing])

        XCTAssertEqual(imported?.id, existingID)
        XCTAssertEqual(imported?.xtreamOutput, .hls)
    }

    func testXtreamAndStalkerImportTheirTypeSpecificFields() {
        let xtream = IPTVReshapedSourceMapping.source(from: [
            "type": "Xtream", "server": "https://xtream.example.test:8443", "user": "viewer",
            "password": "secret", "name": "Live",
        ])
        XCTAssertEqual(xtream?.kind, .xtream)
        XCTAssertEqual(xtream?.playlistURL, "https://xtream.example.test:8443")
        XCTAssertEqual(xtream?.username, "viewer")
        XCTAssertEqual(xtream?.password, "secret")

        let stalker = IPTVReshapedSourceMapping.source(from: [
            "type": "Stalker", "portal": "https://portal.example.test/server/load.php",
            "mac": "00:1A:79:01:02:03", "user": "", "password": "", "name": "Portal",
        ])
        XCTAssertEqual(stalker?.kind, .stalker)
        XCTAssertEqual(stalker?.playlistURL, "https://portal.example.test/server/load.php")
        XCTAssertEqual(stalker?.mac, "00:1A:79:01:02:03")
    }

    func testMergePreservesUpstreamIDAndUnmodeledFields() {
        let source = IPTVSource(id: UUID(), name: "Renamed", playlistURL: "https://example.test/new.m3u")
        let original: [String: Any] = [
            "id": "upstream-id",
            "type": "M3u",
            "url": "https://example.test/old.m3u",
            "name": "Old name",
            "epg": "https://example.test/guide.xml",
            "ua": "FixtureAgent",
            "future_field": ["preserve": true],
        ]

        let merged = IPTVReshapedSourceMapping.merging(source, into: original)
        XCTAssertEqual(merged?["id"] as? String, "upstream-id")
        XCTAssertEqual(merged?["url"] as? String, "https://example.test/new.m3u")
        XCTAssertEqual(merged?["name"] as? String, "Renamed")
        XCTAssertEqual(merged?["epg"] as? String, "https://example.test/guide.xml")
        XCTAssertEqual(merged?["ua"] as? String, "FixtureAgent")
        XCTAssertEqual((merged?["future_field"] as? [String: Bool])?["preserve"], true)
    }

    func testImportedFilesAndUnsupportedTypesAreRejected() {
        XCTAssertNil(IPTVReshapedSourceMapping.source(from: [
            "id": "file-id", "type": "M3uFile", "url": "Imported playlist.m3u",
            "file": "drive-file-id", "hash": "fixture-hash",
        ]))
        XCTAssertNil(IPTVReshapedSourceMapping.canonicalIdentity(in: [
            "type": "M3uFile", "url": "Imported playlist.m3u",
        ]))
        XCTAssertNil(IPTVReshapedSourceMapping.source(from: ["type": "Unknown", "url": "https://example.test"]))
    }
}
