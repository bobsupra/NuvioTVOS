//
//  PluginPlatformTests.swift
//  NuvioTVTests
//
//  Apple TV extensions of the plugin platform: kept-alive contexts,
//  progressive results, file storage, the network log, plugin routes and
//  streams resolved on play. In PluginRuntimeTests so CI runs them with the
//  other plugin tests.
//

import XCTest
@testable import NuvioTV

extension PluginRuntimeTests {

    // MARK: - Kept-alive contexts

    func testManifestKeepAliveAndConfigPage() throws {
        let json = """
        {
          "name": "R", "version": "1",
          "scrapers": [
            { "id": "a", "name": "A", "filename": "a.js" },
            { "id": "b", "name": "B", "filename": "b.js", "supportedPlatforms": ["android", "tvos"] },
            { "id": "c", "name": "C", "filename": "c.js", "supportedPlatforms": ["tvos"], "keepAlive": false },
            { "id": "d", "name": "D", "filename": "d.js", "keepAlive": true, "configPage": true }
          ]
        }
        """
        let scrapers = try PluginManifest.parse(Data(json.utf8)).scrapers
        XCTAssertEqual(scrapers.map(\.runsPersistently), [false, true, false, true])
        XCTAssertEqual(scrapers.map(\.configPage), [false, false, false, true])
    }

    func testKeptAliveProvidersKeepTheirStateBetweenCalls() async throws {
        let scraperID = "test:alive:\(UUID().uuidString)"
        defer {
            PluginInstancePool.shared.retire(scraperId: scraperID)
            PluginInstancePool.shared.retire(scraperId: scraperID + ":fresh")
        }
        let code = """
        var calls = 0;
        module.exports.count = function () { calls += 1; return calls; };
        """
        for expected in 1...3 {
            let result = try await PluginRuntime.call(code: code, scraperId: scraperID, function: "count", timeout: 10, keepAlive: true)
            XCTAssertEqual(result as? Int, expected)
        }
        // Without keepAlive every call gets a fresh context, as on Android.
        for _ in 1...2 {
            let result = try await PluginRuntime.call(code: code, scraperId: scraperID + ":fresh", function: "count", timeout: 10)
            XCTAssertEqual(result as? Int, 1)
        }
        // Other settings (or code) → a new context.
        let changed = try await PluginRuntime.call(
            code: code, scraperId: scraperID, settings: ["a": 1], function: "count", timeout: 10, keepAlive: true
        )
        XCTAssertEqual(changed as? Int, 1)
    }

    func testKeptAliveContextAnswersCallsInParallel() async throws {
        let scraperID = "test:parallel:\(UUID().uuidString)"
        defer { PluginInstancePool.shared.retire(scraperId: scraperID) }
        let code = """
        module.exports.wait = function (ms, tag) {
          return new Promise(function (resolve) { setTimeout(function () { resolve(tag); }, ms); });
        };
        """
        let started = Date()
        async let slow = PluginRuntime.call(code: code, scraperId: scraperID, function: "wait", arguments: [400, "slow"], timeout: 10, keepAlive: true)
        async let fast = PluginRuntime.call(code: code, scraperId: scraperID, function: "wait", arguments: [50, "fast"], timeout: 10, keepAlive: true)
        let (first, second) = try await (slow, fast)
        XCTAssertEqual(first as? String, "slow")
        XCTAssertEqual(second as? String, "fast")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testTimedOutKeptAliveContextIsReplaced() async throws {
        let scraperID = "test:hang:\(UUID().uuidString)"
        defer { PluginInstancePool.shared.retire(scraperId: scraperID) }
        let code = """
        var calls = 0;
        module.exports.hang = function () { calls += 1; return new Promise(function () {}); };
        module.exports.count = function () { return calls; };
        """
        do {
            _ = try await PluginRuntime.call(code: code, scraperId: scraperID, function: "hang", timeout: 0.3, keepAlive: true)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? PluginRuntimeError, .timedOut(0.3))
        }
        let count = try await PluginRuntime.call(code: code, scraperId: scraperID, function: "count", timeout: 10, keepAlive: true)
        XCTAssertEqual(count as? Int, 0, "a context that timed out is not reused")
    }

    // MARK: - Progressive results

    func testEmitDeliversListsBeforeTheResult() async throws {
        let code = """
        module.exports.getStreams = async function (id, type, season, episode, context) {
          context.emit([{ url: 'https://cdn.example.com/1.mkv' }]);
          await new Promise(function (resolve) { setTimeout(resolve, 20); });
          context.emit([{ url: 'https://cdn.example.com/2.mkv' }]);
          return [{ url: 'https://cdn.example.com/1.mkv' }, { url: 'https://cdn.example.com/2.mkv' }, { url: 'https://cdn.example.com/3.mkv' }];
        };
        """
        let emitted = PluginEmitRecorder()
        let arguments: [Any] = ["tt0133093", "movie", NSNull(), NSNull(), [String: Any]()]
        let result = try await PluginRuntime.call(
            code: code, scraperId: "test:emit", function: "getStreams", arguments: arguments, timeout: 10,
            emitArgument: 4, onEmit: { emitted.append($0) }
        )
        XCTAssertEqual((result as? [Any])?.count, 3)
        let lists = emitted.items.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String: Any]] }
        XCTAssertEqual(lists.map { $0.first?["url"] as? String }, ["https://cdn.example.com/1.mkv", "https://cdn.example.com/2.mkv"])

        // Nobody listening: emit is still there and does nothing.
        let quiet = try await PluginRuntime.call(
            code: code, scraperId: "test:emit", function: "getStreams", arguments: arguments, timeout: 10, emitArgument: 4
        )
        XCTAssertEqual((quiet as? [Any])?.count, 3)
    }

    // MARK: - Files and settings

    func testPluginFilesAndSavedSettings() async throws {
        let scraperID = "test:files:\(UUID().uuidString)"
        let scope = ProfileSettings.activeProfileScope
        defer {
            PluginFileStore.removeAll(scraperID: scraperID, scope: scope)
            PluginSettingsVault.remove(scraperID: scraperID)
        }
        let code = """
        module.exports.run = function () {
          NUVIO.files.write('index/ä b.json', JSON.stringify({ n: 1 }));
          NUVIO.files.write('other', 'x');
          var listed = NUVIO.files.list();
          var back = JSON.parse(NUVIO.files.read('index/ä b.json'));
          NUVIO.files.remove('other');
          var saved = NUVIO.settings.save({ token: 'abc', on: true });
          return { listed: listed, n: back.n, after: NUVIO.files.list(), usage: NUVIO.files.usage(),
                   missing: NUVIO.files.read('nope'), saved: saved, token: NUVIO.settings.get().token };
        };
        """
        let result = try await PluginRuntime.call(code: code, scraperId: scraperID, function: "run", timeout: 10)
        let object = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(object["listed"] as? [String], ["index/ä b.json", "other"])
        XCTAssertEqual(object["n"] as? Int, 1)
        XCTAssertEqual(object["after"] as? [String], ["index/ä b.json"])
        XCTAssertEqual(object["usage"] as? Int, 7)
        XCTAssertTrue(object["missing"] is NSNull)
        if object["saved"] as? Bool == true {
            XCTAssertEqual(object["token"] as? String, "abc")
            XCTAssertEqual(PluginSettingsVault.settings(scraperID: scraperID)["token"] as? String, "abc")
        }

        // Another context sees the same files.
        let again = try await PluginRuntime.call(
            code: "module.exports.read = function () { return NUVIO.files.read('index/ä b.json'); };",
            scraperId: scraperID, function: "read", timeout: 10
        )
        XCTAssertEqual(again as? String, #"{"n":1}"#)
    }

    func testPluginFileNamesStayInTheirFolder() {
        for name in ["../../etc/passwd", "a/b/c.json", "ž", String(repeating: "x", count: 180), String(repeating: "ž", count: 90)] {
            let file = try? XCTUnwrap(PluginFileStore.fileName(for: name))
            XCTAssertFalse(file?.contains("/") ?? true, name)
            XCTAssertFalse(file?.contains("..") ?? true, name)
            XCTAssertLessThanOrEqual(file?.utf8.count ?? 999, 255, "file names longer than 255 bytes can't be created")
            XCTAssertEqual(file.flatMap(PluginFileStore.name(forFileName:)), name)
        }
        XCTAssertNil(PluginFileStore.fileName(for: ""))
        XCTAssertNil(PluginFileStore.fileName(for: String(repeating: "x", count: 181)))
    }

    // MARK: - Network log

    func testNetworkLogHidesKeys() {
        let url = URL(string: "https://user:pw@api.example.com/api/abcdefghijklmnopqrstuvwxyz123456/x?t=search&apikey=SECRET1&q=matrix&wst=W&my_token=T")!
        let text = PluginNetworkLog.redact(url)
        for secret in ["SECRET1", "pw", "abcdefghijklmnopqrstuvwxyz123456", "wst=W", "my_token=T"] {
            XCTAssertFalse(text.contains(secret), "\(secret) in \(text)")
        }
        XCTAssertTrue(text.hasPrefix("https://api.example.com/api/••••/x?"), text)
        XCTAssertTrue(text.contains("t=search"), text)
        XCTAssertTrue(text.contains("q=matrix"), text)
        XCTAssertTrue(text.contains("apikey=••••"), text)
    }

    func testRequestsAndCallTimesAreLogged() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PluginURLProtocolStub.self]
        PluginRuntime.session = PluginRuntime.makeSession(configuration: configuration)
        PluginURLProtocolStub.handler = { _ in (200, ["Content-Type": "text/plain"], Data("ok".utf8)) }
        let scraperID = "test:netlog:\(UUID().uuidString)"
        defer { PluginLogStore.shared.clear(scraperID) }
        let code = """
        module.exports.go = async function () {
          var r = await fetch('https://api.example.com/find?apikey=SECRET2&q=x');
          return r.status;
        };
        """
        let status = try await PluginRuntime.call(code: code, scraperId: scraperID, function: "go", timeout: 10)
        XCTAssertEqual(status as? Int, 200)
        let lines = PluginLogStore.shared.entries(for: scraperID).filter { $0.level == .net }.map(\.message)
        XCTAssertTrue(lines.contains { $0.hasPrefix("GET https://api.example.com/find?apikey=••••&q=x → 200 · ") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("⏱ go answered in ") }, lines.joined(separator: "\n"))
        XCTAssertFalse(lines.joined().contains("SECRET2"))
    }

    // MARK: - Routes and resolve on play

    func testStreamsWithResolveGoThroughTheDevice() throws {
        let stream = try XCTUnwrap(PluginStreamDiscovery.stream(from: [
            "name": "Webshare 1080p",
            "resolve": ["ident": "abc123", "size": 2] as [String: Any],
            "behaviorHints": ["filename": "Movie (2024) 1080p.mkv"]
        ], providerName: "Webshare", scraperID: "repo:webshare"))
        let url = try XCTUnwrap(stream.url.flatMap(URLComponents.init(string:)))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, PluginLoopbackServer.host)
        let key = PluginAddonRegistry.key(for: "repo:webshare")
        XCTAssertTrue(url.path.hasSuffix("/resolve/\(key)/Movie__2024__1080p.mkv"), url.path)
        let encoded = try XCTUnwrap(url.queryItems?.first(where: { $0.name == "p" })?.value)
        let payload = try XCTUnwrap(PluginRoutes.data(fromBase64URL: encoded))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["ident"] as? String, "abc123")
        XCTAssertEqual(object["size"] as? Int, 2)

        // Without a provider id (or with a url) nothing is resolved.
        XCTAssertNil(PluginStreamDiscovery.stream(from: ["resolve": ["a": 1]], providerName: "P"))
        let direct = try XCTUnwrap(PluginStreamDiscovery.stream(
            from: ["url": "https://cdn.example.com/a.mp4", "resolve": ["a": 1]], providerName: "P", scraperID: "repo:p"
        ))
        XCTAssertEqual(direct.url, "https://cdn.example.com/a.mp4")
        // Too big to put in an address.
        XCTAssertNil(PluginStreamDiscovery.stream(
            from: ["resolve": String(repeating: "x", count: 10_000)], providerName: "P", scraperID: "repo:p"
        ))
    }

    func testResolveStreamResultsAndPluginResponses() {
        XCTAssertEqual(PluginRoutes.resolvedURL(from: "https://cdn.example.com/a.mkv", scraperID: "x"), "https://cdn.example.com/a.mkv")
        XCTAssertEqual(
            PluginRoutes.resolvedURL(from: ["url": " https://cdn.example.com/b.mkv "] as [String: Any], scraperID: "x"),
            "https://cdn.example.com/b.mkv"
        )
        XCTAssertNil(PluginRoutes.resolvedURL(from: "magnet:?xt=urn:btih:abc", scraperID: "x"))
        XCTAssertNil(PluginRoutes.resolvedURL(from: NSNull(), scraperID: "x"))

        let page = PluginRoutes.response(from: "<h1>Setup</h1>")
        XCTAssertEqual(page.status, 200)
        XCTAssertTrue(page.contentType.hasPrefix("text/html"))

        let json = PluginRoutes.response(from: ["json": ["ok": true], "headers": ["X-A": "1", "Content-Length": "9"]] as [String: Any])
        XCTAssertEqual(json.contentType, "application/json; charset=utf-8")
        XCTAssertEqual(String(decoding: json.body, as: UTF8.self), #"{"ok":true}"#)
        XCTAssertEqual(json.headers, ["X-A": "1"])

        let redirect = PluginRoutes.response(from: ["redirect": "https://example.com/next"] as [String: Any])
        XCTAssertEqual(redirect.status, 302)
        XCTAssertEqual(redirect.headers["Location"], "https://example.com/next")

        let binary = PluginRoutes.response(from: ["status": 206, "bodyBase64": "AAEC", "contentType": "video/mp2t"] as [String: Any])
        XCTAssertEqual(binary.status, 206)
        XCTAssertEqual(binary.body, Data([0, 1, 2]))
        XCTAssertEqual(binary.contentType, "video/mp2t")

        XCTAssertEqual(PluginRoutes.response(from: NSNull()).status, 404)
        XCTAssertEqual(PluginRoutes.response(from: ["status": 9999, "body": "x"] as [String: Any]).status, 200)
    }

    func testPluginRequestObject() {
        typealias Request = PluginHTTPServerCore.Request
        let form = Request(
            method: "POST", path: "/plugin/k/save", query: ["a": "1"], body: Data("token=a%2Bb+c&on=1".utf8),
            headers: ["content-type": "application/x-www-form-urlencoded", "cookie": "secret", "host": "10.0.0.2:8765"]
        )
        let object = PluginRoutes.requestObject(form, path: "/save", origin: "setup", baseURL: "http://10.0.0.2:8765/t/plugin/k/")
        XCTAssertEqual(object["method"] as? String, "POST")
        XCTAssertEqual(object["path"] as? String, "/save")
        XCTAssertEqual(object["form"] as? [String: String], ["token": "a+b c", "on": "1"])
        XCTAssertNil((object["headers"] as? [String: String])?["cookie"])
        XCTAssertEqual(object["baseUrl"] as? String, "http://10.0.0.2:8765/t/plugin/k/")

        let json = Request(method: "POST", path: "/", query: [:], body: Data(#"{"x":[1]}"#.utf8), headers: ["content-type": "application/json"])
        XCTAssertEqual((PluginRoutes.requestObject(json, path: "/", origin: "device", baseURL: "")["json"] as? [String: Any])?["x"] as? [Int], [1])

        XCTAssertEqual(PluginRoutes.path(after: 2, in: "/plugin/abc/sub/a%20b.m3u8"), "/sub/a b.m3u8")
        XCTAssertEqual(PluginRoutes.path(after: 2, in: "/plugin/abc"), "/")
        XCTAssertEqual(PluginRoutes.path(after: 2, in: "/plugin/abc/"), "/")
    }

    func testOnDeviceServerAnswersOnLoopback() async throws {
        let server = PluginLoopbackServer(token: "looptest\(Int.random(in: 1000...9999))")
        defer { server.stop() }
        await server.waitUntilReady()
        XCTAssertTrue(server.isReady)
        let base = server.baseURL
        XCTAssertEqual(base.host, "127.0.0.1")

        let (_, unknown) = try await URLSession.shared.data(from: base.appendingPathComponent("resolve/unknown/stream"))
        XCTAssertEqual((unknown as? HTTPURLResponse)?.statusCode, 404)
        let wrongToken = URL(string: "http://127.0.0.1:\(base.port ?? 0)/nope/resolve/x/y")!
        let (_, outside) = try await URLSession.shared.data(from: wrongToken)
        XCTAssertEqual((outside as? HTTPURLResponse)?.statusCode, 404)
    }

    @MainActor
    func testWebAPIChangesNeedTheSetupPageHeader() async throws {
        typealias Request = PluginHTTPServerCore.Request
        let store = PluginStore.shared
        let previous = store.autoUpdates
        defer { store.setAutoUpdates(previous) }
        let body = Data(#"{"enabled":false}"#.utf8)

        let forged = await PluginWebAPI.handle(Request(method: "POST", path: "/api/auto-update", query: [:], body: body))
        XCTAssertEqual(forged.status, 403)
        XCTAssertEqual(store.autoUpdates, previous)

        let real = await PluginWebAPI.handle(Request(
            method: "POST", path: "/api/auto-update", query: [:], body: body, headers: ["x-nuvio": "1"]
        ))
        XCTAssertEqual(real.status, 200)
        XCTAssertFalse(store.autoUpdates)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: real.body) as? [String: Any])
        XCTAssertEqual(json["autoUpdate"] as? Bool, false)

        let page = await PluginWebAPI.handle(Request(method: "GET", path: "/plugin/unknown/", query: [:], body: Data()))
        XCTAssertEqual(page.status, 404)
        XCTAssertEqual(page.headers["Content-Security-Policy"], PluginRoutes.setupPagePolicy)
    }
}

/// Collects `emit` lists in tests.
final class PluginEmitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ item: String) {
        lock.lock()
        stored.append(item)
        lock.unlock()
    }

    var items: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
