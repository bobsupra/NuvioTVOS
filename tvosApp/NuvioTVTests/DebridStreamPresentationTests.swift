import XCTest
@testable import NuvioTV

final class DebridStreamPresentationTests: XCTestCase {
    private var testStore: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "test.debrid.presentation.\(UUID().uuidString)"
        testStore = UserDefaults(suiteName: suiteName)!
        LocalDebridTestURLProtocol.handler = nil
        LocalDebridTestURLProtocol.firstBatchHashes = []
    }

    override func tearDown() {
        testStore.removePersistentDomain(forName: suiteName)
        LocalDebridTestURLProtocol.handler = nil
        LocalDebridTestURLProtocol.firstBatchHashes = []
        super.tearDown()
    }

    func testProviderKindShortNames() {
        XCTAssertEqual(DebridProviderKind.torbox.shortName, "TB")
        XCTAssertEqual(DebridProviderKind.realDebrid.shortName, "RD")
        XCTAssertEqual(DebridProviderKind.premiumize.shortName, "PM")
        XCTAssertEqual(DebridProviderKind.allDebrid.shortName, "AD")
        XCTAssertEqual(DebridProviderKind.debridLink.shortName, "DL")
        XCTAssertEqual(DebridProviderKind.none.shortName, "")
    }

    func testPassesThroughWhenDebridDisabled() async {
        testStore.set(false, forKey: SettingsKey.debridEnabled)
        testStore.set(DebridProviderKind.torbox.rawValue, forKey: SettingsKey.debridProvider)
        testStore.set("test-token", forKey: SettingsKey.torboxAccessToken)

        let presentation = DebridStreamPresentation(store: testStore)
        XCTAssertFalse(presentation.isDebridEnabled)

        let rawStream = NuvioStream(
            url: nil,
            name: "Torrentio 1080p",
            description: "1080p | 2.5 GB",
            addonName: "Torrentio",
            infoHash: "0123456789abcdef0123456789abcdef01234567"
        )

        let results = await presentation.present(streams: [rawStream])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Torrentio 1080p")
        XCTAssertFalse(results.first?.isCached == true)
    }

    func testPassesThroughWhenNoTokenConfigured() async {
        testStore.set(true, forKey: SettingsKey.debridEnabled)
        testStore.set(DebridProviderKind.torbox.rawValue, forKey: SettingsKey.debridProvider)
        testStore.set("", forKey: SettingsKey.torboxAccessToken)

        let presentation = DebridStreamPresentation(store: testStore)
        XCTAssertFalse(presentation.isDebridEnabled)

        let rawStream = NuvioStream(
            url: nil,
            name: "Torrentio 1080p",
            description: nil,
            addonName: "Torrentio",
            infoHash: "0123456789abcdef0123456789abcdef01234567"
        )

        let results = await presentation.present(streams: [rawStream])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Torrentio 1080p")
    }

    func testDirectHTTPStreamsAreNeverFilteredOrModified() async {
        testStore.set(true, forKey: SettingsKey.debridEnabled)
        testStore.set(DebridProviderKind.torbox.rawValue, forKey: SettingsKey.debridProvider)
        testStore.set("test-token", forKey: SettingsKey.torboxAccessToken)

        let presentation = DebridStreamPresentation(store: testStore)

        let directStream = NuvioStream(
            url: "https://example.com/direct_stream.mkv",
            name: "Direct HTTP",
            description: nil,
            addonName: "HTTP Addon"
        )

        let results = await presentation.present(streams: [directStream])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.url, "https://example.com/direct_stream.mkv")
        XCTAssertEqual(results.first?.name, "Direct HTTP")
    }

    func testFailedRealDebridCheckKeepsTorrentAndPreservesAddonCacheClaim() async throws {
        configureRealDebrid()
        LocalDebridTestURLProtocol.handler = { request in
            try Self.response(
                for: request,
                status: 403,
                json: ["error": "disabled_endpoint", "error_code": 37]
            )
        }
        let service = LocalDebridService(session: Self.mockSession())
        let presentation = DebridStreamPresentation(store: testStore, localDebridService: service)
        let stream = NuvioStream(
            url: nil,
            name: "Torrentio 1080p",
            description: "1080p | 2 GB",
            addonName: "Torrentio",
            infoHash: Self.uniqueHash(),
            isCached: true
        )

        let results = await presentation.present(streams: [stream])

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "Torrentio 1080p")
        XCTAssertTrue(results[0].isCached == true)
        XCTAssertTrue(results[0].debridCacheStatusUnavailable == true)
        XCTAssertTrue(results[0].isDebridResolvable)
        XCTAssertFalse(results[0].isNotPlayable)
    }

    func testPartialRealDebridResultsKeepOmittedAndFailedHashesUnknown() async throws {
        configureRealDebrid()
        LocalDebridTestURLProtocol.handler = { request in
            let requestedHashes = request.url?.path.split(separator: "/").filter { $0.count == 40 } ?? []
            guard requestedHashes.count == 50 else {
                return try Self.response(for: request, status: 503, json: [String: Any]())
            }
            let body: [String: Any] = [
                String(requestedHashes[0]): ["rd": [["1": ["filename": "cached.mkv", "filesize": 1_000]]]],
                String(requestedHashes[1]): ["rd": []]
            ]
            return try Self.response(for: request, status: 200, json: body)
        }
        let service = LocalDebridService(session: Self.mockSession())
        let presentation = DebridStreamPresentation(store: testStore, localDebridService: service)
        let streams = (0..<51).map { index in
            NuvioStream(
                url: nil,
                name: "Torrentio 1080p",
                description: nil,
                addonName: "Torrentio",
                infoHash: Self.uniqueHash(seed: index),
                isCached: false
            )
        }

        let results = await presentation.present(streams: streams)
        let resultByHash = Dictionary(uniqueKeysWithValues: results.compactMap { stream in
            stream.effectiveInfoHash.map { ($0, stream) }
        })
        let firstBatchHashes = LocalDebridTestURLProtocol.firstBatchHashes
        XCTAssertEqual(firstBatchHashes.count, 50)
        let cachedHash = firstBatchHashes[0]
        let uncachedHash = firstBatchHashes[1]
        let omittedHash = firstBatchHashes[2]
        let failedBatchHash = streams.first { !firstBatchHashes.contains($0.effectiveInfoHash ?? "") }?.effectiveInfoHash

        XCTAssertEqual(resultByHash[cachedHash]?.name, "1080p RD Instant")
        XCTAssertNil(resultByHash[uncachedHash])
        XCTAssertEqual(resultByHash[omittedHash]?.name, "Torrentio 1080p")
        XCTAssertTrue(resultByHash[omittedHash]?.debridCacheStatusUnavailable == true)
        XCTAssertEqual(resultByHash[failedBatchHash ?? ""]?.name, "Torrentio 1080p")
        XCTAssertTrue(resultByHash[failedBatchHash ?? ""]?.debridCacheStatusUnavailable == true)
        XCTAssertTrue(resultByHash[omittedHash]?.isCached == false)
    }

    func testDebridResolverRespectsDebridEnabledSetting() {
        testStore.set(false, forKey: SettingsKey.debridEnabled)
        testStore.set(DebridProviderKind.torbox.rawValue, forKey: SettingsKey.debridProvider)
        testStore.set("test-token", forKey: SettingsKey.torboxAccessToken)

        let resolver = DebridResolver(store: testStore)
        XCTAssertFalse(resolver.isEnabled)

        testStore.set(true, forKey: SettingsKey.debridEnabled)
        let resolverEnabled = DebridResolver(store: testStore)
        XCTAssertTrue(resolverEnabled.isEnabled)
    }

    func testCloudLibraryServiceRespectsCloudLibraryEnabledSetting() {
        testStore.set(false, forKey: SettingsKey.cloudLibraryEnabled)
        testStore.set(DebridProviderKind.torbox.rawValue, forKey: SettingsKey.debridProvider)
        testStore.set("test-token", forKey: SettingsKey.torboxAccessToken)

        let service = CloudLibraryService(store: testStore)
        XCTAssertFalse(service.isAvailable)

        testStore.set(true, forKey: SettingsKey.cloudLibraryEnabled)
        let serviceEnabled = CloudLibraryService(store: testStore)
        XCTAssertTrue(serviceEnabled.isAvailable)
    }

    private func configureRealDebrid() {
        testStore.set(true, forKey: SettingsKey.debridEnabled)
        testStore.set(DebridProviderKind.realDebrid.rawValue, forKey: SettingsKey.debridProvider)
        testStore.set("test-token", forKey: SettingsKey.realDebridAccessToken)
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalDebridTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(for request: URLRequest, status: Int, json: [String: Any]) throws -> (HTTPURLResponse, Data) {
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, data)
    }

    private static func uniqueHash(seed: Int = Int.random(in: 1...Int.max)) -> String {
        let hex = String(UInt64.random(in: 1...UInt64.max) ^ UInt64(seed), radix: 16)
        return String(repeating: "0", count: 40 - hex.count) + hex
    }
}

private final class LocalDebridTestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    static var firstBatchHashes: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            let requestedHashes = request.url?.path.split(separator: "/").filter { $0.count == 40 }.map(String.init) ?? []
            if requestedHashes.count == 50 {
                Self.firstBatchHashes = requestedHashes
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
