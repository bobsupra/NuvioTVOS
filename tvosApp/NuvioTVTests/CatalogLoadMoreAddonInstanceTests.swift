import XCTest
@testable import NuvioTV

/// The same add-on can be installed more than once with different
/// configurations, and every copy reports the same manifest id. A later page
/// of a catalog must come from the copy its first page came from; asking
/// another copy fails, and the row or grid stopped after its first page.
final class CatalogLoadMoreAddonInstanceTests: XCTestCase {
    private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        private static var requested: [URL] = []
        static var replies: [String: Data] = [:]

        static func reset() {
            lock.withLock { requested = []; replies = [:] }
        }

        static var catalogRequests: [URL] {
            lock.withLock { requested.filter { $0.path.contains("/catalog/") } }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            let data: Data? = Self.lock.withLock {
                Self.requested.append(url)
                return Self.replies["\(url.host ?? "")\(url.path)"]
            }
            let response = HTTPURLResponse(url: url, statusCode: data == nil ? 404 : 200,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data ?? Data())
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private let copyA = "https://lists-a.invalid/token-a/manifest.json"
    private let copyB = "https://lists-b.invalid/token-b/manifest.json"
    private var session: URLSession!
    private var saved: [String: Any?] = [:]
    private let keys = [SettingsKey.streamAddonManifestStates, SettingsKey.streamAddonManifestURLs,
                        SettingsKey.streamAddonManifestURL, SettingsKey.cinemetaDisabled]

    override func setUp() async throws {
        try await super.setUp()
        let defaults = ProfileSettings.current
        for key in keys { saved[key] = defaults.object(forKey: key) }
        defaults.set("[{\"url\":\"\(copyA)\",\"enabled\":true},{\"url\":\"\(copyB)\",\"enabled\":true}]",
                     forKey: SettingsKey.streamAddonManifestStates)
        defaults.set("\(copyA)\n\(copyB)", forKey: SettingsKey.streamAddonManifestURLs)
        defaults.set(copyA, forKey: SettingsKey.streamAddonManifestURL)
        defaults.set(true, forKey: SettingsKey.cinemetaDisabled)

        FixtureURLProtocol.reset()
        let empty = Data(#"{"metas":[]}"#.utf8)
        FixtureURLProtocol.replies = [
            // Same id; copy A has "list-a" and "top", copy B has "list-b" and "top".
            "lists-a.invalid/token-a/manifest.json": Data(#"{"id":"com.lists","name":"Lists","types":["movie"],"catalogs":[{"type":"movie","id":"list-a","extra":[{"name":"skip"}]},{"type":"movie","id":"top","extra":[{"name":"skip"}]}]}"#.utf8),
            "lists-b.invalid/token-b/manifest.json": Data(#"{"id":"com.lists","name":"Lists","types":["movie"],"catalogs":[{"type":"movie","id":"list-b","extra":[{"name":"skip"}]},{"type":"movie","id":"top","extra":[{"name":"skip"}]}]}"#.utf8),
            "lists-a.invalid/token-a/catalog/movie/list-a/skip=20.json": empty,
            "lists-a.invalid/token-a/catalog/movie/top/skip=20.json": empty,
            "lists-b.invalid/token-b/catalog/movie/list-b/skip=20.json": empty,
            "lists-b.invalid/token-b/catalog/movie/top/skip=20.json": empty,
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        session = URLSession(configuration: configuration)
        await StremioManifestDataCache.shared.clear()
        await StremioManifestDataCache.shared.setSessionForTesting(session)
        CinemetaCatalogRepository.setNetworkSessionForTesting(session)
    }

    override func tearDown() async throws {
        await StremioManifestDataCache.shared.setSessionForTesting(nil)
        await StremioManifestDataCache.shared.clear()
        CinemetaCatalogRepository.setNetworkSessionForTesting(nil)
        session.invalidateAndCancel()
        FixtureURLProtocol.reset()
        let defaults = ProfileSettings.current
        for key in keys {
            if let value = saved[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        try await super.tearDown()
    }

    private func nextPage(catalogId: String, manifestURL: String?) async throws -> [String] {
        _ = try await CinemetaCatalogRepository().browseCatalog(
            addonId: "com.lists", manifestURL: manifestURL,
            contentType: "movie", catalogId: catalogId, skip: 20, genre: nil
        )
        return FixtureURLProtocol.catalogRequests.map { "\($0.host ?? "")\($0.path)" }
    }

    func testByIdTheNextPageGoesToTheCopyThatHasTheCatalog() async throws {
        // Copy A comes first and has the same id, but not this catalog.
        let requests = try await nextPage(catalogId: "list-b", manifestURL: nil)
        XCTAssertEqual(requests, ["lists-b.invalid/token-b/catalog/movie/list-b/skip=20.json"])
    }

    func testTheRowsOwnInstallIsUsedWhenBothCopiesHaveTheCatalog() async throws {
        // Both copies list "top"; only the row's own install has its configuration.
        let requests = try await nextPage(catalogId: "top", manifestURL: copyB)
        XCTAssertEqual(requests, ["lists-b.invalid/token-b/catalog/movie/top/skip=20.json"])
    }

    func testAnInstallThatWasRemovedFallsBackToTheId() async throws {
        let removed = "https://lists-c.invalid/token-c/manifest.json"
        let requests = try await nextPage(catalogId: "list-a", manifestURL: removed)
        XCTAssertEqual(requests, ["lists-a.invalid/token-a/catalog/movie/list-a/skip=20.json"])
    }
}
