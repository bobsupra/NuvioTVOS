import XCTest
import Foundation
@testable import NuvioTV

final class SearchHistoryTests: XCTestCase {
    func testSanitizeDiscardsShortAndEmptyQueries() {
        let input = ["", " ", "S", "a", "  b  "]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertTrue(output.isEmpty)
    }

    func testSanitizePrunesSubstringsAndPrefixes() {
        let input = ["Silo", "Sil", "Si", "S"]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertEqual(output, ["Silo"])
    }

    func testSanitizeDeduplicatesCaseInsensitively() {
        let input = ["Silo", "silo", "SILO"]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertEqual(output, ["Silo"])
    }

    func testSanitizePreservesDistinctQueries() {
        let input = ["Star Wars", "Star Trek", "Dune"]
        let output = SearchHistoryStore.sanitize(input)
        XCTAssertEqual(output, ["Star Wars", "Star Trek", "Dune"])
    }

    func testSanitizeRespectsMaxCount() {
        let input = (1...12).map { "Movie \($0)" }
        let output = SearchHistoryStore.sanitize(input, maxCount: 8)
        XCTAssertEqual(output.count, 8)
        XCTAssertEqual(output.first, "Movie 1")
        XCTAssertEqual(output.last, "Movie 8")
    }

    func testCommitReplacesIntermediateTypingPrefixes() {
        var current: [String] = []
        var session: String? = nil

        // User types 'S' (ignored because < 2)
        (current, session) = SearchHistoryStore.commit("S", current: current, sessionQuery: session)
        XCTAssertEqual(current, [])
        XCTAssertNil(session)

        // User types 'Si'
        (current, session) = SearchHistoryStore.commit("Si", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Si"])
        XCTAssertEqual(session, "Si")

        // User types 'Sil'
        (current, session) = SearchHistoryStore.commit("Sil", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Sil"])
        XCTAssertEqual(session, "Sil")

        // User types 'Silo'
        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo"])
        XCTAssertEqual(session, "Silo")
    }

    func testCommitHandlesBackspacingInSameSession() {
        var current: [String] = []
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo"])

        // User backspaces to "Sil" in same session
        (current, session) = SearchHistoryStore.commit("Sil", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Sil"])
        XCTAssertEqual(session, "Sil")

        // User changes to "Sila"
        (current, session) = SearchHistoryStore.commit("Sila", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Sila"])
        XCTAssertEqual(session, "Sila")
    }

    func testCommitPreservesUnrelatedQueries() {
        var current = ["Dune", "Inception"]
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo", "Dune", "Inception"])
    }

    func testCommitMovesExistingQueryToFront() {
        var current = ["Dune", "Silo", "Batman"]
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Silo", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Silo", "Dune", "Batman"])
    }

    func testCommitPrunesSubstringOfMultiWordQuery() {
        var current: [String] = []
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("The", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["The"])

        (current, session) = SearchHistoryStore.commit("The Bat", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["The Bat"])

        (current, session) = SearchHistoryStore.commit("The Batman", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["The Batman"])
    }

    func testCommitPreservesDistinctPrefixShares() {
        var current = ["Star Wars"]
        var session: String? = nil

        (current, session) = SearchHistoryStore.commit("Star Trek", current: current, sessionQuery: session)
        XCTAssertEqual(current, ["Star Trek", "Star Wars"])
    }
}

// MARK: - Search and Discover Request Lifecycle Tests

private final class ControllableLifecycleRepository: MockCatalogRepository {
    var searchHandler: ((String) async throws -> [NuvioMeta])?
    var searchOutcomeHandler: ((String) async throws -> CatalogSearchOutcome)?
    var refreshMetadataHandler: ((String, String) async throws -> NuvioMeta)?
    var browseDiscoverHandler: ((DiscoverCatalogOption, Int, String?) async throws -> CatalogPage)?

    override func search(query: String) async throws -> [NuvioMeta] {
        if let searchHandler {
            return try await searchHandler(query)
        }
        return [
            NuvioMeta(
                id: "meta_\(query)",
                name: "Result for \(query)",
                posterUrl: nil,
                backgroundUrl: nil,
                logoUrl: nil,
                imdbId: nil,
                tmdbId: nil,
                type: "movie",
                year: 2024
            )
        ]
    }

    override func searchWithOutcome(query: String) async throws -> CatalogSearchOutcome {
        if let searchOutcomeHandler {
            return try await searchOutcomeHandler(query)
        }
        return try await super.searchWithOutcome(query: query)
    }

    override func refreshMetadata(id: String, type: String) async throws -> NuvioMeta {
        if let refreshMetadataHandler {
            return try await refreshMetadataHandler(id, type)
        }
        return try await super.refreshMetadata(id: id, type: type)
    }

    override func getDiscoverSources() async -> [DiscoverCatalogOption] {
        [
            DiscoverCatalogOption(
                key: "movie:top",
                addonId: "mock.addon",
                addonName: "Mock Addon",
                manifestURL: URL(string: "https://example.com/manifest.json")!,
                type: "movie",
                catalogId: "top",
                catalogName: "Popular Movies",
                genreOptions: ["action", "drama"],
                genreRequired: false,
                supportsPagination: true
            ),
            DiscoverCatalogOption(
                key: "series:top",
                addonId: "mock.addon",
                addonName: "Mock Addon",
                manifestURL: URL(string: "https://example.com/manifest.json")!,
                type: "series",
                catalogId: "top",
                catalogName: "Popular Series",
                genreOptions: ["drama", "comedy"],
                genreRequired: false,
                supportsPagination: true
            )
        ]
    }

    override func browseDiscover(
        option: DiscoverCatalogOption,
        page: Int,
        genre: String?
    ) async throws -> CatalogPage {
        if let browseDiscoverHandler {
            return try await browseDiscoverHandler(option, page, genre)
        }
        let items = (1...5).map { i in
            NuvioMeta(
                id: "\(option.type)_\(page)_\(i)",
                name: "Item \(option.type) \(page) \(i)",
                posterUrl: nil,
                backgroundUrl: nil,
                logoUrl: nil,
                imdbId: nil,
                tmdbId: nil,
                type: option.type,
                year: 2024
            )
        }
        return CatalogPage(items: items, hasMore: page < 3, page: page)
    }
}

@MainActor
private protocol SearchLifecycleModel: AnyObject {
    var searchText: String { get set }
    var results: [NuvioMeta] { get }
    var isLoading: Bool { get }
    var error: String? { get }
    func performSearch(query: String)
}

extension SearchViewModel: SearchLifecycleModel {}
extension NetflixSearchViewModel: SearchLifecycleModel {}

private actor SearchRequestCounter {
    private var count = 0

    func next() -> Int {
        count += 1
        return count
    }

    func current() -> Int { count }
}

final class SearchAndDiscoverLifecycleTests: XCTestCase {
    @MainActor
    func testSearchRapidQueryChangePreservesFinalDebouncedQuery() async throws {
        let repo = ControllableLifecycleRepository()
        try await assertRapidQueryChangeRecovers(
            SearchViewModel(repository: repo), repository: repo
        )
    }

    @MainActor
    func testNetflixSearchRapidQueryChangePreservesFinalDebouncedQuery() async throws {
        let repo = ControllableLifecycleRepository()
        try await assertRapidQueryChangeRecovers(
            NetflixSearchViewModel(repository: repo), repository: repo
        )
    }

    func testSearchRequestsMovieAndSeriesAddonSearchCatalogsWhenHomeRowsAreDisabled() async throws {
        let defaults = ProfileSettings.current
        let cinemetaManifestURL = "https://v3-cinemeta.strem.io/manifest.json"
        let addonManifestURL = "https://aiometa-addon.invalid/manifest.json"
        let disabledDuplicateManifestURL = "https://aiometa-disabled.invalid/manifest.json"
        let addonMovieSearchURL = "https://aiometa-addon.invalid/catalog/movie/search.movie/search=Matrix.json"
        let addonSeriesSearchURL = "https://aiometa-addon.invalid/catalog/series/search.series/search=Matrix.json"
        let addonMoviePopularURL = "https://aiometa-addon.invalid/catalog/movie/popular/search=Matrix.json"
        let addonSeriesPopularURL = "https://aiometa-addon.invalid/catalog/series/popular/search=Matrix.json"
        let disabledBrowseCatalogKeys = [
            TVHomeCatalogOrder.catalogSettingsKey(
                addonId: "aiometadata", contentType: "movie", catalogId: "popular"
            ),
            TVHomeCatalogOrder.catalogSettingsKey(
                addonId: "aiometadata", contentType: "series", catalogId: "popular"
            ),
            TVHomeCatalogOrder.catalogSettingsKey(
                addonId: CinemetaCatalogRepository.cinemetaAddonId, contentType: "movie", catalogId: "top"
            ),
            TVHomeCatalogOrder.catalogSettingsKey(
                addonId: CinemetaCatalogRepository.cinemetaAddonId, contentType: "movie", catalogId: "imdbRating"
            ),
            TVHomeCatalogOrder.catalogSettingsKey(
                addonId: CinemetaCatalogRepository.cinemetaAddonId, contentType: "series", catalogId: "top"
            ),
            TVHomeCatalogOrder.catalogSettingsKey(
                addonId: CinemetaCatalogRepository.cinemetaAddonId, contentType: "series", catalogId: "imdbRating"
            )
        ]

        let previousAddonStates = defaults.object(forKey: SettingsKey.streamAddonManifestStates)
        let previousAddonURLs = defaults.object(forKey: SettingsKey.streamAddonManifestURLs)
        let previousSingleAddonURL = defaults.object(forKey: SettingsKey.streamAddonManifestURL)
        let previousCinemetaDisabled = defaults.object(forKey: SettingsKey.cinemetaDisabled)
        let previousDisabledAddonIDs = defaults.object(forKey: SettingsKey.homeCatalogDisabledAddonIDs)
        let previousDisabledAddonNames = defaults.object(forKey: SettingsKey.homeCatalogDisabledAddonNames)
        let previousDisabledCatalogs = HomeCatalogPayloadStore.data(forKey: SettingsKey.homeCatalogDisabled)

        let fixturePreferences = "[{\"url\":\"\(cinemetaManifestURL)\",\"enabled\":true},{\"url\":\"\(addonManifestURL)\",\"enabled\":true},{\"url\":\"\(disabledDuplicateManifestURL)\",\"enabled\":false}]"
        let fixtureDisabledCatalogs = try JSONEncoder().encode(disabledBrowseCatalogKeys)
        let fixtureSessionConfiguration = URLSessionConfiguration.ephemeral
        fixtureSessionConfiguration.protocolClasses = [SearchManifestFixtureURLProtocol.self]
        let fixtureSession = URLSession(configuration: fixtureSessionConfiguration)
        let requestRecorder = SearchFixtureRequestRecorder()

        func restore(_ key: String, to value: Any?) {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        func resetFixtureSession() async {
            await StremioManifestDataCache.shared.setSessionForTesting(nil)
            await StremioManifestDataCache.shared.clear()
            CinemetaCatalogRepository.setNetworkSessionForTesting(nil)
            fixtureSession.invalidateAndCancel()
        }

        defer {
            SearchManifestFixtureURLProtocol.reset()
            CinemetaCatalogRepository.setNetworkSessionForTesting(nil)
            fixtureSession.invalidateAndCancel()
            restore(SettingsKey.streamAddonManifestStates, to: previousAddonStates)
            restore(SettingsKey.streamAddonManifestURLs, to: previousAddonURLs)
            restore(SettingsKey.streamAddonManifestURL, to: previousSingleAddonURL)
            restore(SettingsKey.cinemetaDisabled, to: previousCinemetaDisabled)
            restore(SettingsKey.homeCatalogDisabledAddonIDs, to: previousDisabledAddonIDs)
            restore(SettingsKey.homeCatalogDisabledAddonNames, to: previousDisabledAddonNames)
            if let previousDisabledCatalogs {
                _ = HomeCatalogPayloadStore.write(previousDisabledCatalogs, forKey: SettingsKey.homeCatalogDisabled)
            } else {
                HomeCatalogPayloadStore.remove(forKey: SettingsKey.homeCatalogDisabled)
            }
        }

        defaults.set(fixturePreferences, forKey: SettingsKey.streamAddonManifestStates)
        defaults.set("\(cinemetaManifestURL)\n\(addonManifestURL)", forKey: SettingsKey.streamAddonManifestURLs)
        defaults.set(cinemetaManifestURL, forKey: SettingsKey.streamAddonManifestURL)
        defaults.set(false, forKey: SettingsKey.cinemetaDisabled)
        defaults.set(Data("[\"com.linvo.cinemeta\",\"aiometadata\"]".utf8), forKey: SettingsKey.homeCatalogDisabledAddonIDs)
        defaults.set(Data("[]".utf8), forKey: SettingsKey.homeCatalogDisabledAddonNames)
        XCTAssertTrue(HomeCatalogPayloadStore.write(fixtureDisabledCatalogs, forKey: SettingsKey.homeCatalogDisabled))

        let cinemetaManifest = Data(#"{"id":"com.linvo.cinemeta","name":"Cinemeta","types":["movie","series"],"catalogs":[]}"#.utf8)
        let addonManifest = Data(#"{"id":"aiometadata","name":"AIO Metadata","types":["movie","series"],"catalogs":[{"type":"movie","id":"search.movie","extra":[{"name":"search","isRequired":true},{"name":"skip"}]},{"type":"series","id":"search.series","extra":[{"name":"search","isRequired":true},{"name":"skip"}]},{"type":"movie","id":"popular","name":"Popular Movies","extra":[{"name":"search","isRequired":false}]},{"type":"series","id":"popular","name":"Popular Series","extra":[{"name":"search","isRequired":false}]}]}"#.utf8)
        let cinemetaMovie = Data(#"{"metas":[{"id":"tt8880001","name":"Cinemeta Movie Fixture","type":"movie"}]}"#.utf8)
        let cinemetaSeries = Data(#"{"metas":[{"id":"tt8880002","name":"Cinemeta Series Fixture","type":"series"}]}"#.utf8)
        let addonMovie = Data(#"{"metas":[{"id":"aiometa-movie-search-1","name":"AIO Movie Search Fixture","type":"movie"}]}"#.utf8)
        let addonSeries = Data(#"{"metas":[{"id":"aiometa-series-search-1","name":"AIO Series Search Fixture","type":"series"}]}"#.utf8)

        SearchManifestFixtureURLProtocol.install { request in
            guard let url = request.url else { return nil }
            requestRecorder.record(url)
            switch (url.host, url.path) {
            case ("v3-cinemeta.strem.io", "/manifest.json"):
                return .init(statusCode: 200, data: cinemetaManifest)
            case ("aiometa-addon.invalid", "/manifest.json"):
                return .init(statusCode: 200, data: addonManifest)
            case ("aiometa-disabled.invalid", "/manifest.json"):
                return .init(statusCode: 200, data: addonManifest)
            case ("v3-cinemeta.strem.io", "/catalog/movie/top/search=Matrix.json"):
                return .init(statusCode: 200, data: cinemetaMovie)
            case ("v3-cinemeta.strem.io", "/catalog/series/top/search=Matrix.json"):
                return .init(statusCode: 200, data: cinemetaSeries)
            case ("aiometa-addon.invalid", "/catalog/movie/search.movie/search=Matrix.json"):
                return .init(statusCode: 200, data: addonMovie)
            case ("aiometa-addon.invalid", "/catalog/series/search.series/search=Matrix.json"):
                return .init(statusCode: 200, data: addonSeries)
            case ("aiometa-addon.invalid", "/catalog/movie/popular/search=Matrix.json"),
                 ("aiometa-addon.invalid", "/catalog/series/popular/search=Matrix.json"):
                return .init(statusCode: 200, data: Data(#"{"metas":[]}"#.utf8))
            default:
                return .init(statusCode: 404, data: Data())
            }
        }

        await StremioManifestDataCache.shared.clear()
        await StremioManifestDataCache.shared.setSessionForTesting(fixtureSession)
        CinemetaCatalogRepository.setNetworkSessionForTesting(fixtureSession)

        XCTAssertTrue(CinemetaCatalogRepository.isCinemetaEnabled)
        XCTAssertEqual(TVHomeCatalogOrder.disabledCatalogKeys(), Set(disabledBrowseCatalogKeys))

        let repository = CinemetaCatalogRepository()
        let idOnlyResults: [NuvioMeta]
        let nameOnlyResults: [NuvioMeta]
        let explicitlyDisabledCinemetaResults: [NuvioMeta]
        do {
            idOnlyResults = try await repository.search(query: "Matrix")

            // A name-only stale Home snapshot must not suppress an enabled URL either.
            defaults.set(Data("[]".utf8), forKey: SettingsKey.homeCatalogDisabledAddonIDs)
            defaults.set(Data("[\"aiometadata\",\"cinemeta\"]".utf8), forKey: SettingsKey.homeCatalogDisabledAddonNames)
            nameOnlyResults = try await repository.search(query: "Matrix")

            // The explicit preference remains authoritative for Cinemeta.
            CinemetaCatalogRepository.setCinemetaDisabled(true, in: defaults)
            explicitlyDisabledCinemetaResults = try await repository.search(query: "Matrix")
        } catch {
            await resetFixtureSession()
            throw error
        }
        await resetFixtureSession()

        let requestedURLs = Set(requestRecorder.urls)
        XCTAssertTrue(requestedURLs.contains(addonMovieSearchURL), "Missing add-on movie search request: \(requestedURLs)")
        XCTAssertTrue(requestedURLs.contains(addonSeriesSearchURL), "Missing add-on series search request: \(requestedURLs)")
        XCTAssertTrue(requestedURLs.contains(addonMoviePopularURL), "Home-disabled movie catalog was not searched: \(requestedURLs)")
        XCTAssertTrue(requestedURLs.contains(addonSeriesPopularURL), "Home-disabled series catalog was not searched: \(requestedURLs)")
        XCTAssertFalse(requestedURLs.contains(disabledDuplicateManifestURL))
        for results in [idOnlyResults, nameOnlyResults] {
            XCTAssertTrue(results.contains(where: { $0.id == "tt8880001" }))
            XCTAssertTrue(results.contains(where: { $0.id == "tt8880002" }))
            XCTAssertTrue(results.contains(where: { $0.id == "aiometa-movie-search-1" }))
            XCTAssertTrue(results.contains(where: { $0.id == "aiometa-series-search-1" }))
        }
        XCTAssertTrue(explicitlyDisabledCinemetaResults.contains(where: { $0.id == "aiometa-movie-search-1" }))
        XCTAssertTrue(explicitlyDisabledCinemetaResults.contains(where: { $0.id == "aiometa-series-search-1" }))
        XCTAssertFalse(explicitlyDisabledCinemetaResults.contains(where: { $0.id == "tt8880001" }))
        XCTAssertFalse(explicitlyDisabledCinemetaResults.contains(where: { $0.id == "tt8880002" }))
    }

    func testRepositorySearchOutcomeDistinguishesFailuresFromSuccessfulEmptyResults() async throws {
        let defaults = ProfileSettings.current
        let failedManifestURL = URL(string: "https://failed-manifest.invalid/manifest.json")!
        let partialCatalogURL = URL(string: "https://partial-catalog.invalid/manifest.json")!
        let emptyCatalogURL = URL(string: "https://empty-catalog.invalid/manifest.json")!
        let retryManifestURL = URL(string: "https://retry-manifest.invalid/manifest.json")!
        let previousAddonStates = defaults.object(forKey: SettingsKey.streamAddonManifestStates)
        let previousAddonURLs = defaults.object(forKey: SettingsKey.streamAddonManifestURLs)
        let previousSingleAddonURL = defaults.object(forKey: SettingsKey.streamAddonManifestURL)
        let previousCinemetaDisabled = defaults.object(forKey: SettingsKey.cinemetaDisabled)
        let fixtureSessionConfiguration = URLSessionConfiguration.ephemeral
        fixtureSessionConfiguration.protocolClasses = [SearchManifestFixtureURLProtocol.self]
        let fixtureSession = URLSession(configuration: fixtureSessionConfiguration)
        let requestRecorder = SearchFixtureRequestRecorder()

        func configure(_ manifestURL: URL) {
            let json = "[{\"url\":\"\(manifestURL.absoluteString)\",\"enabled\":true}]"
            defaults.set(json, forKey: SettingsKey.streamAddonManifestStates)
            defaults.set(manifestURL.absoluteString, forKey: SettingsKey.streamAddonManifestURLs)
            defaults.set(manifestURL.absoluteString, forKey: SettingsKey.streamAddonManifestURL)
        }

        func restore(_ key: String, to value: Any?) {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        func resetFixtureSession() async {
            await StremioManifestDataCache.shared.setSessionForTesting(nil)
            await StremioManifestDataCache.shared.clear()
            CinemetaCatalogRepository.setNetworkSessionForTesting(nil)
            fixtureSession.invalidateAndCancel()
        }

        defer {
            SearchManifestFixtureURLProtocol.reset()
            CinemetaCatalogRepository.setNetworkSessionForTesting(nil)
            fixtureSession.invalidateAndCancel()
            restore(SettingsKey.streamAddonManifestStates, to: previousAddonStates)
            restore(SettingsKey.streamAddonManifestURLs, to: previousAddonURLs)
            restore(SettingsKey.streamAddonManifestURL, to: previousSingleAddonURL)
            restore(SettingsKey.cinemetaDisabled, to: previousCinemetaDisabled)
        }

        let partialManifest = Data(#"{"id":"partial.addon","name":"Partial Addon","types":["movie"],"catalogs":[{"type":"movie","id":"failed","extra":[{"name":"search","isRequired":true}]},{"type":"movie","id":"success","extra":[{"name":"search","isRequired":true}]}]}"#.utf8)
        let emptyManifest = Data(#"{"id":"empty.addon","name":"Empty Addon","types":["movie"],"catalogs":[{"type":"movie","id":"empty","extra":[{"name":"search","isRequired":true}]}]}"#.utf8)
        let partialCatalog = Data(#"{"metas":[{"id":"partial-search-result","name":"Partial Search Result","type":"movie"}]}"#.utf8)

        SearchManifestFixtureURLProtocol.install { request in
            guard let url = request.url else { return nil }
            requestRecorder.record(url)
            switch (url.host, url.path) {
            case ("failed-manifest.invalid", "/manifest.json"):
                return .init(statusCode: 503, data: Data())
            case ("partial-catalog.invalid", "/manifest.json"):
                return .init(statusCode: 200, data: partialManifest)
            case ("partial-catalog.invalid", "/catalog/movie/failed/search=Matrix.json"):
                return .init(statusCode: 500, data: Data())
            case ("partial-catalog.invalid", "/catalog/movie/success/search=Matrix.json"):
                return .init(statusCode: 200, data: partialCatalog)
            case ("empty-catalog.invalid", "/manifest.json"):
                return .init(statusCode: 200, data: emptyManifest)
            case ("empty-catalog.invalid", "/catalog/movie/empty/search=Matrix.json"):
                return .init(statusCode: 200, data: Data(#"{"metas":[]}"#.utf8))
            default:
                return .init(statusCode: 404, data: Data())
            }
        }

        defaults.set(true, forKey: SettingsKey.cinemetaDisabled)
        await StremioManifestDataCache.shared.setSessionForTesting(fixtureSession)
        CinemetaCatalogRepository.setNetworkSessionForTesting(fixtureSession)

        let repository = CinemetaCatalogRepository()
        do {
            configure(failedManifestURL)
            let failedManifest = try await repository.searchWithOutcome(query: "Matrix")
            XCTAssertFalse(failedManifest.isComplete)
            XCTAssertTrue(failedManifest.results.isEmpty)

            configure(partialCatalogURL)
            let partialCatalogOutcome = try await repository.searchWithOutcome(query: "Matrix")
            XCTAssertFalse(partialCatalogOutcome.isComplete)
            XCTAssertEqual(partialCatalogOutcome.results.map(\.id), ["partial-search-result"])

            configure(emptyCatalogURL)
            let successfulEmpty = try await repository.searchWithOutcome(query: "Matrix")
            XCTAssertTrue(successfulEmpty.isComplete)
            XCTAssertTrue(successfulEmpty.results.isEmpty)

            configure(retryManifestURL)
            let malformedManifestStarted = expectation(description: "malformed manifest request started")
            SearchManifestFixtureURLProtocol.install { request in
                guard let url = request.url else { return nil }
                requestRecorder.record(url)
                guard url == retryManifestURL else { return .init(statusCode: 404, data: Data()) }
                malformedManifestStarted.fulfill()
                return .init(statusCode: 200, data: Data("not json".utf8), delay: 1.0)
            }

            async let firstMalformedRequest = repository.searchWithOutcome(query: "Matrix")
            await fulfillment(of: [malformedManifestStarted], timeout: 2)
            async let secondMalformedRequest = repository.searchWithOutcome(query: "Matrix")
            let (firstMalformed, secondMalformed) = try await (firstMalformedRequest, secondMalformedRequest)
            XCTAssertFalse(firstMalformed.isComplete)
            XCTAssertFalse(secondMalformed.isComplete)
            XCTAssertEqual(
                requestRecorder.urls.filter { $0 == retryManifestURL.absoluteString }.count,
                1,
                "Concurrent callers should share the malformed manifest fetch"
            )

            let retryManifest = Data(#"{"id":"retry.addon","name":"Retry Addon","types":["movie"],"catalogs":[{"type":"movie","id":"search","extra":[{"name":"search","isRequired":true}]}]}"#.utf8)
            let retryCatalog = Data(#"{"metas":[{"id":"recovered-after-malformed","name":"Recovered After Malformed Manifest","type":"movie"}]}"#.utf8)
            SearchManifestFixtureURLProtocol.install { request in
                guard let url = request.url else { return nil }
                requestRecorder.record(url)
                switch (url.host, url.path) {
                case ("retry-manifest.invalid", "/manifest.json"):
                    return .init(statusCode: 200, data: retryManifest)
                case ("retry-manifest.invalid", "/catalog/movie/search/search=Matrix.json"):
                    return .init(statusCode: 200, data: retryCatalog)
                default:
                    return .init(statusCode: 404, data: Data())
                }
            }

            let recovered = try await repository.searchWithOutcome(query: "Matrix")
            XCTAssertTrue(recovered.isComplete)
            XCTAssertEqual(recovered.results.map(\.id), ["recovered-after-malformed"])
            XCTAssertEqual(
                requestRecorder.urls.filter { $0 == retryManifestURL.absoluteString }.count,
                2,
                "Retry should fetch the same URL again after undecodable bytes were evicted"
            )
        } catch {
            await resetFixtureSession()
            throw error
        }
        await resetFixtureSession()
    }

    func testMalformedCachedManifestIsEvictedWithoutRemovingUnrelatedOrNewerResponses() async throws {
        let defaults = ProfileSettings.current
        let manifestURL = URL(string: "https://urlcache-retry.invalid/manifest.json")!
        let finalResponseURL = URL(string: "https://cdn-urlcache.invalid/manifests/manifest.json")!
        let unrelatedURL = URL(string: "https://unrelated-urlcache.invalid/manifest.json")!
        let malformedBytes = Data("not a manifest".utf8)
        let unrelatedBytes = Data("unrelated response".utf8)
        let previousAddonStates = defaults.object(forKey: SettingsKey.streamAddonManifestStates)
        let previousAddonURLs = defaults.object(forKey: SettingsKey.streamAddonManifestURLs)
        let previousSingleAddonURL = defaults.object(forKey: SettingsKey.streamAddonManifestURL)
        let previousCinemetaDisabled = defaults.object(forKey: SettingsKey.cinemetaDisabled)

        let fixtureURLCache = URLCache(memoryCapacity: 1_000_000, diskCapacity: 0, diskPath: nil)
        let finalResponseRequest = URLRequest(url: finalResponseURL)
        let unrelatedRequest = URLRequest(url: unrelatedURL)
        let cacheableHeaders = [
            "Content-Type": "application/json",
            "Cache-Control": "public, max-age=3600"
        ]
        // Seed a cacheable 200 at the destination URL without depending on
        // URLSession's custom-protocol redirect callback behavior.
        let malformedResponse = HTTPURLResponse(
            url: finalResponseURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: cacheableHeaders
        )!
        let unrelatedResponse = HTTPURLResponse(
            url: unrelatedURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: cacheableHeaders
        )!
        fixtureURLCache.storeCachedResponse(
            CachedURLResponse(response: malformedResponse, data: malformedBytes, storagePolicy: .allowed),
            for: finalResponseRequest
        )
        fixtureURLCache.storeCachedResponse(
            CachedURLResponse(response: unrelatedResponse, data: unrelatedBytes, storagePolicy: .allowed),
            for: unrelatedRequest
        )
        XCTAssertEqual(
            (fixtureURLCache.cachedResponse(for: finalResponseRequest)?.response as? HTTPURLResponse)?.statusCode,
            200
        )

        let fixtureSessionConfiguration = URLSessionConfiguration.ephemeral
        fixtureSessionConfiguration.protocolClasses = [SearchManifestFixtureURLProtocol.self]
        fixtureSessionConfiguration.urlCache = fixtureURLCache
        fixtureSessionConfiguration.requestCachePolicy = .useProtocolCachePolicy
        let fixtureSession = URLSession(configuration: fixtureSessionConfiguration)
        let requestRecorder = SearchFixtureRequestRecorder()

        func restore(_ key: String, to value: Any?) {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        func resetFixtureSession() async {
            await StremioManifestDataCache.shared.setSessionForTesting(nil)
            await StremioManifestDataCache.shared.clear()
            CinemetaCatalogRepository.setNetworkSessionForTesting(nil)
            fixtureSession.invalidateAndCancel()
        }

        defer {
            SearchManifestFixtureURLProtocol.reset()
            CinemetaCatalogRepository.setNetworkSessionForTesting(nil)
            fixtureSession.invalidateAndCancel()
            restore(SettingsKey.streamAddonManifestStates, to: previousAddonStates)
            restore(SettingsKey.streamAddonManifestURLs, to: previousAddonURLs)
            restore(SettingsKey.streamAddonManifestURL, to: previousSingleAddonURL)
            restore(SettingsKey.cinemetaDisabled, to: previousCinemetaDisabled)
        }

        defaults.set("[{\"url\":\"\(manifestURL.absoluteString)\",\"enabled\":true}]", forKey: SettingsKey.streamAddonManifestStates)
        defaults.set(manifestURL.absoluteString, forKey: SettingsKey.streamAddonManifestURLs)
        defaults.set(manifestURL.absoluteString, forKey: SettingsKey.streamAddonManifestURL)
        defaults.set(true, forKey: SettingsKey.cinemetaDisabled)

        let validManifest = Data(#"{"id":"urlcache.retry","name":"URLCache Retry","types":["movie"],"catalogs":[{"type":"movie","id":"search","extra":[{"name":"search","isRequired":true}]}]}"#.utf8)
        let catalogResponse = Data(#"{"metas":[{"id":"urlcache-recovered","name":"Recovered from URLCache","type":"movie"}]}"#.utf8)
        let malformedResponseStarted = expectation(description: "malformed response started")
        SearchManifestFixtureURLProtocol.install { request in
            guard let url = request.url else { return nil }
            requestRecorder.record(url)
            if url == manifestURL {
                malformedResponseStarted.fulfill()
                return .init(statusCode: 200, data: malformedBytes, delay: 0.4, responseURL: finalResponseURL)
            }
            return .init(statusCode: 404, data: Data())
        }

        await StremioManifestDataCache.shared.setSessionForTesting(fixtureSession, urlCache: fixtureURLCache)
        CinemetaCatalogRepository.setNetworkSessionForTesting(fixtureSession)

        let repository = CinemetaCatalogRepository()
        do {
            async let malformedSearch = repository.searchWithOutcome(query: "Matrix")
            await fulfillment(of: [malformedResponseStarted], timeout: 2)
            await StremioManifestDataCache.shared.clear()
            let malformedOutcome = try await malformedSearch
            XCTAssertFalse(malformedOutcome.isComplete)
            XCTAssertTrue(malformedOutcome.results.isEmpty)
            XCTAssertNil(fixtureURLCache.cachedResponse(for: finalResponseRequest))
            XCTAssertEqual(fixtureURLCache.cachedResponse(for: unrelatedRequest)?.data, unrelatedBytes)

            let manifestRequestsBeforeRetry = requestRecorder.urls.filter { $0 == manifestURL.absoluteString }.count
            SearchManifestFixtureURLProtocol.install { request in
                guard let url = request.url else { return nil }
                requestRecorder.record(url)
                switch (url.host, url.path) {
                case ("urlcache-retry.invalid", "/manifest.json"):
                    return .init(statusCode: 200, data: validManifest, responseURL: finalResponseURL)
                case ("urlcache-retry.invalid", "/catalog/movie/search/search=Matrix.json"):
                    return .init(statusCode: 200, data: catalogResponse)
                default:
                    return .init(statusCode: 404, data: Data())
                }
            }

            let recovered = try await repository.searchWithOutcome(query: "Matrix")
            XCTAssertTrue(recovered.isComplete)
            XCTAssertEqual(recovered.results.map(\.id), ["urlcache-recovered"])
            XCTAssertEqual(
                requestRecorder.urls.filter { $0 == manifestURL.absoluteString }.count,
                manifestRequestsBeforeRetry + 1
            )

            let newerResponse = HTTPURLResponse(
                url: finalResponseURL,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: cacheableHeaders
            )!
            fixtureURLCache.storeCachedResponse(
                CachedURLResponse(response: newerResponse, data: validManifest, storagePolicy: .allowed),
                for: finalResponseRequest
            )
            let staleMalformedEntry = StremioManifestDataEntry(
                identity: UUID(),
                data: malformedBytes,
                responseURL: finalResponseURL,
                urlCache: fixtureURLCache
            )
            await StremioManifestDataCache.shared.discardCachedData(for: manifestURL, matching: staleMalformedEntry)
            XCTAssertEqual(fixtureURLCache.cachedResponse(for: finalResponseRequest)?.data, validManifest)
            XCTAssertEqual(fixtureURLCache.cachedResponse(for: unrelatedRequest)?.data, unrelatedBytes)
        } catch {
            await resetFixtureSession()
            throw error
        }
        await resetFixtureSession()
    }

    func testManifestCacheClearReturnsCompletedBytesWithoutRepublishing() async throws {
        let manifestURL = URL(string: "https://clear-manifest.invalid/manifest.json")!
        let firstBytes = Data("first response".utf8)
        let secondBytes = Data("second response".utf8)
        let requestRecorder = SearchFixtureRequestRecorder()
        let firstRequestStarted = expectation(description: "first manifest request started")
        let fixtureSessionConfiguration = URLSessionConfiguration.ephemeral
        fixtureSessionConfiguration.protocolClasses = [SearchManifestFixtureURLProtocol.self]
        let fixtureSession = URLSession(configuration: fixtureSessionConfiguration)

        SearchManifestFixtureURLProtocol.install { request in
            guard let url = request.url else { return nil }
            requestRecorder.record(url)
            guard url == manifestURL else { return .init(statusCode: 404, data: Data()) }
            let count = requestRecorder.urls.filter { $0 == manifestURL.absoluteString }.count
            if count == 1 {
                firstRequestStarted.fulfill()
                return .init(statusCode: 200, data: firstBytes, delay: 0.4)
            }
            return .init(statusCode: 200, data: secondBytes)
        }

        await StremioManifestDataCache.shared.setSessionForTesting(fixtureSession)
        defer {
            SearchManifestFixtureURLProtocol.reset()
            fixtureSession.invalidateAndCancel()
        }

        async let oldWaiter = StremioManifestDataCache.shared.data(for: manifestURL)
        await fulfillment(of: [firstRequestStarted], timeout: 2)
        await StremioManifestDataCache.shared.clear()
        let completedBytes = await oldWaiter
        XCTAssertEqual(completedBytes, firstBytes)

        let nextAccess = await StremioManifestDataCache.shared.data(for: manifestURL)
        XCTAssertEqual(nextAccess, secondBytes)
        XCTAssertEqual(requestRecorder.urls.filter { $0 == manifestURL.absoluteString }.count, 2)
        await StremioManifestDataCache.shared.setSessionForTesting(nil)
    }

    func testOldManifestEntryCannotEvictNewIdenticalBytesAfterClear() async {
        let manifestURL = URL(string: "https://identity-manifest.invalid/manifest.json")!
        let identicalBytes = Data("same bytes from both flights".utf8)
        let requestRecorder = SearchFixtureRequestRecorder()
        let fixtureSessionConfiguration = URLSessionConfiguration.ephemeral
        fixtureSessionConfiguration.protocolClasses = [SearchManifestFixtureURLProtocol.self]
        let fixtureSession = URLSession(configuration: fixtureSessionConfiguration)

        SearchManifestFixtureURLProtocol.install { request in
            guard let url = request.url else { return nil }
            requestRecorder.record(url)
            guard url == manifestURL else { return .init(statusCode: 404, data: Data()) }
            return .init(statusCode: 200, data: identicalBytes)
        }

        await StremioManifestDataCache.shared.setSessionForTesting(fixtureSession)
        defer {
            SearchManifestFixtureURLProtocol.reset()
            fixtureSession.invalidateAndCancel()
        }

        guard let oldEntry = await StremioManifestDataCache.shared.dataEntry(for: manifestURL) else {
            XCTFail("Old manifest request should return bytes")
            await StremioManifestDataCache.shared.setSessionForTesting(nil)
            return
        }
        await StremioManifestDataCache.shared.clear()

        guard let newEntry = await StremioManifestDataCache.shared.dataEntry(for: manifestURL) else {
            XCTFail("Replacement manifest request should return bytes")
            await StremioManifestDataCache.shared.setSessionForTesting(nil)
            return
        }
        XCTAssertEqual(newEntry.data, oldEntry.data)
        XCTAssertNotEqual(newEntry.identity, oldEntry.identity)

        await StremioManifestDataCache.shared.discardCachedData(for: manifestURL, matching: oldEntry)
        let cachedEntryAfterStaleFailure = await StremioManifestDataCache.shared.dataEntry(for: manifestURL)
        XCTAssertEqual(cachedEntryAfterStaleFailure?.identity, newEntry.identity)
        XCTAssertEqual(requestRecorder.urls.filter { $0 == manifestURL.absoluteString }.count, 2)
        await StremioManifestDataCache.shared.setSessionForTesting(nil)
    }

    @MainActor
    func testSearchViewModelsRetryIncompleteEmptyOutcomes() async throws {
        let previousRecentSearches = UserDefaults.standard.object(forKey: SearchHistoryStore.storageKey)
        defer { restoreRecentSearches(previousRecentSearches) }

        let searchRepository = ControllableLifecycleRepository()
        try await assertIncompleteEmptyOutcomeRetries(
            SearchViewModel(repository: searchRepository, searchTimeout: 3),
            repository: searchRepository
        )

        let netflixRepository = ControllableLifecycleRepository()
        try await assertIncompleteEmptyOutcomeRetries(
            NetflixSearchViewModel(repository: netflixRepository, searchTimeout: 3),
            repository: netflixRepository
        )
    }

    @MainActor
    func testSearchViewModelsDoNotCachePartialResultsAfterEnrichment() async throws {
        let previousRecentSearches = UserDefaults.standard.object(forKey: SearchHistoryStore.storageKey)
        defer { restoreRecentSearches(previousRecentSearches) }

        let searchRepository = ControllableLifecycleRepository()
        try await assertPartialOutcomeRetriesAfterEnrichment(
            SearchViewModel(repository: searchRepository, searchTimeout: 3),
            repository: searchRepository
        )

        let netflixRepository = ControllableLifecycleRepository()
        try await assertPartialOutcomeRetriesAfterEnrichment(
            NetflixSearchViewModel(repository: netflixRepository, searchTimeout: 3),
            repository: netflixRepository
        )
    }

    @MainActor
    func testSearchViewModelsCacheSuccessfulEmptyOutcomes() async throws {
        let previousRecentSearches = UserDefaults.standard.object(forKey: SearchHistoryStore.storageKey)
        defer { restoreRecentSearches(previousRecentSearches) }

        let searchRepository = ControllableLifecycleRepository()
        try await assertCompleteEmptyOutcomeIsCached(
            SearchViewModel(repository: searchRepository, searchTimeout: 3),
            repository: searchRepository
        )

        let netflixRepository = ControllableLifecycleRepository()
        try await assertCompleteEmptyOutcomeIsCached(
            NetflixSearchViewModel(repository: netflixRepository, searchTimeout: 3),
            repository: netflixRepository
        )
    }

    @MainActor
    private func assertIncompleteEmptyOutcomeRetries(
        _ viewModel: any SearchLifecycleModel,
        repository: ControllableLifecycleRepository
    ) async throws {
        let firstSearchStarted = expectation(description: "first incomplete search started")
        let retryStarted = expectation(description: "incomplete search retried")
        let counter = SearchRequestCounter()
        repository.searchOutcomeHandler = { _ in
            if await counter.next() == 1 {
                firstSearchStarted.fulfill()
                return CatalogSearchOutcome(results: [], isComplete: false)
            }
            retryStarted.fulfill()
            return CatalogSearchOutcome(
                results: [self.completeSearchMeta(id: "recovered", name: "Recovered", type: "movie")],
                isComplete: true
            )
        }

        viewModel.searchText = "Retry Empty"
        await fulfillment(of: [firstSearchStarted], timeout: 3)
        try await waitForSearchToFinish(viewModel)
        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertEqual(
            viewModel.error,
            L10n.string(
                "search_error_network",
                fallback: "Couldn’t complete search. Check your connection and try again."
            )
        )

        viewModel.performSearch(query: "Retry Empty")
        await fulfillment(of: [retryStarted], timeout: 2)
        try await waitForSearchToFinish(viewModel)
        XCTAssertEqual(viewModel.results.map(\.id), ["recovered"])
        XCTAssertNil(viewModel.error)
        let searchCount = await counter.current()
        XCTAssertEqual(searchCount, 2)
    }

    @MainActor
    private func assertPartialOutcomeRetriesAfterEnrichment(
        _ viewModel: any SearchLifecycleModel,
        repository: ControllableLifecycleRepository
    ) async throws {
        let defaults = ProfileSettings.current
        let previousTmdbHomeEnrichment = defaults.object(forKey: SettingsKey.tmdbApplyToHome)
        defaults.set(false, forKey: SettingsKey.tmdbApplyToHome)
        defer {
            if let previousTmdbHomeEnrichment {
                defaults.set(previousTmdbHomeEnrichment, forKey: SettingsKey.tmdbApplyToHome)
            } else {
                defaults.removeObject(forKey: SettingsKey.tmdbApplyToHome)
            }
        }

        let firstSearchStarted = expectation(description: "first partial search started")
        let firstEnrichmentStarted = expectation(description: "partial result enrichment started")
        let retryStarted = expectation(description: "partial search retried")
        let counter = SearchRequestCounter()
        repository.searchOutcomeHandler = { _ in
            if await counter.next() == 1 {
                firstSearchStarted.fulfill()
                return CatalogSearchOutcome(
                    results: [NuvioMeta(id: "partial", name: "Partial", type: "movie")],
                    isComplete: false
                )
            }
            retryStarted.fulfill()
            return CatalogSearchOutcome(
                results: [self.completeSearchMeta(id: "recovered-partial", name: "Recovered", type: "movie")],
                isComplete: true
            )
        }
        repository.refreshMetadataHandler = { id, type in
            firstEnrichmentStarted.fulfill()
            return self.completeSearchMeta(id: id, name: "Enriched Partial", type: type)
        }

        viewModel.searchText = "Retry Partial"
        await fulfillment(of: [firstSearchStarted], timeout: 3)
        try await waitForSearchToFinish(viewModel)
        XCTAssertEqual(viewModel.results.map(\.id), ["partial"])
        XCTAssertNil(viewModel.error)

        await fulfillment(of: [firstEnrichmentStarted], timeout: 2)
        let enrichmentDeadline = Date().addingTimeInterval(2)
        while viewModel.results.first?.posterUrl != "enriched-poster" && Date() < enrichmentDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(viewModel.results.first?.posterUrl, "enriched-poster")

        viewModel.performSearch(query: "Retry Partial")
        await fulfillment(of: [retryStarted], timeout: 2)
        try await waitForSearchToFinish(viewModel)
        XCTAssertEqual(viewModel.results.map(\.id), ["recovered-partial"])
        let searchCount = await counter.current()
        XCTAssertEqual(searchCount, 2)
    }

    @MainActor
    private func assertCompleteEmptyOutcomeIsCached(
        _ viewModel: any SearchLifecycleModel,
        repository: ControllableLifecycleRepository
    ) async throws {
        let firstSearchStarted = expectation(description: "complete empty search started")
        let counter = SearchRequestCounter()
        repository.searchOutcomeHandler = { _ in
            _ = await counter.next()
            firstSearchStarted.fulfill()
            return CatalogSearchOutcome(results: [], isComplete: true)
        }

        viewModel.searchText = "No Matches"
        await fulfillment(of: [firstSearchStarted], timeout: 3)
        try await waitForSearchToFinish(viewModel)
        XCTAssertTrue(viewModel.results.isEmpty)
        XCTAssertNil(viewModel.error)

        viewModel.performSearch(query: "No Matches")
        XCTAssertFalse(viewModel.isLoading)
        let searchCount = await counter.current()
        XCTAssertEqual(searchCount, 1)
    }

    @MainActor
    private func waitForSearchToFinish(
        _ viewModel: any SearchLifecycleModel,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while viewModel.isLoading && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(viewModel.isLoading)
    }

    private func completeSearchMeta(id: String, name: String, type: String) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: name,
            posterUrl: "enriched-poster",
            backgroundUrl: "enriched-backdrop",
            logoUrl: "enriched-logo",
            imdbId: "tt1234567",
            tmdbId: 123,
            type: type,
            year: 2024,
            runtime: "100 min"
        )
    }

    private func restoreRecentSearches(_ value: Any?) {
        if let value {
            UserDefaults.standard.set(value, forKey: SearchHistoryStore.storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SearchHistoryStore.storageKey)
        }
    }

    @MainActor
    private func assertRapidQueryChangeRecovers(
        _ viewModel: any SearchLifecycleModel,
        repository: ControllableLifecycleRepository
    ) async throws {
        let firstStarted = expectation(description: "first debounced request started")
        let secondStarted = expectation(description: "replacement request started")
        let releaseFirst = expectation(description: "release cancelled first request")
        let firstReturned = expectation(description: "first request returned despite cancellation")
        let counter = SearchRequestCounter()
        repository.searchHandler = { query in
            let requestNumber = await counter.next()
            XCTAssertEqual(query, "Matrix")
            if requestNumber == 1 {
                firstStarted.fulfill()
                // Ignore cancellation like a provider that finishes an already-issued request.
                await self.fulfillment(of: [releaseFirst], timeout: 5)
                firstReturned.fulfill()
            } else if requestNumber == 2 {
                secondStarted.fulfill()
            } else {
                XCTFail("Unexpected extra search request")
            }
            return [NuvioMeta(id: "request_\(requestNumber)", name: "Result for Matrix", type: "movie")]
        }
        defer { viewModel.searchText = "" }

        // The first query must already have passed debounce and still be in flight.
        viewModel.searchText = "Matrix"
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertTrue(viewModel.isLoading)
        viewModel.searchText = "Matrix Reloaded"
        viewModel.searchText = "Matrix"

        await fulfillment(of: [secondStarted], timeout: 2)
        releaseFirst.fulfill()
        await fulfillment(of: [firstReturned], timeout: 1)

        let deadline = Date().addingTimeInterval(1)
        while viewModel.isLoading && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(viewModel.isLoading)
        XCTAssertEqual(viewModel.results.map(\.id), ["request_2"])
    }

    @MainActor
    func testDelayedSearchCannotOverwriteCachedResults() async throws {
        let repo = ControllableLifecycleRepository()
        let fastSearchStarted = expectation(description: "fast search started")
        let slowSearchStarted = expectation(description: "slow search started")
        let slowSearchCanFinish = expectation(description: "slow search can finish")
        let slowSearchReturned = expectation(description: "stale slow search returned")
        repo.searchHandler = { query in
            if query == "Slow" {
                slowSearchStarted.fulfill()
                await self.fulfillment(of: [slowSearchCanFinish], timeout: 5.0)
                slowSearchReturned.fulfill()
                return [
                    NuvioMeta(
                        id: "slow_1",
                        name: "Result for Slow",
                        posterUrl: nil,
                        backgroundUrl: nil,
                        logoUrl: nil,
                        imdbId: nil,
                        tmdbId: nil,
                        type: "movie",
                        year: 2024
                    )
                ]
            }
            fastSearchStarted.fulfill()
            return [
                NuvioMeta(
                    id: "meta_\(query)",
                    name: "Result for \(query)",
                    posterUrl: nil,
                    backgroundUrl: nil,
                    logoUrl: nil,
                    imdbId: nil,
                    tmdbId: nil,
                    type: "movie",
                    year: 2024
                )
            ]
        }

        // Drive the same debounced path as the UI so its initial empty-query
        // debounce cannot clear the directly-started result mid-test.
        let viewModel = SearchViewModel(repository: repo)
        viewModel.searchText = "Fast"
        await fulfillment(of: [fastSearchStarted], timeout: 2.0)
        try await waitForSearchToFinish(viewModel)
        XCTAssertEqual(viewModel.results.first?.name, "Result for Fast")

        // Slow search starts while the complete fast result remains cached.
        viewModel.searchText = "Slow"
        await fulfillment(of: [slowSearchStarted], timeout: 2.0)
        XCTAssertTrue(viewModel.isLoading)

        // While slow is in-flight, user switches back to "Fast" (which is cached)
        viewModel.searchText = "Fast"
        XCTAssertEqual(viewModel.results.first?.name, "Result for Fast")
        XCTAssertFalse(viewModel.isLoading)

        // Allow slow search to finally finish
        slowSearchCanFinish.fulfill()
        await fulfillment(of: [slowSearchReturned], timeout: 1.0)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Stale slow search must NOT overwrite the cached fast search
        XCTAssertEqual(viewModel.results.first?.name, "Result for Fast")
        XCTAssertFalse(viewModel.isLoading)
    }

    @MainActor
    func testSearchTimeoutGracefullyRecoversFromHangingRepository() async throws {
        let repo = ControllableLifecycleRepository()
        let viewModel = SearchViewModel(repository: repo, searchTimeout: 0.1)

        let searchStarted = expectation(description: "search started")
        repo.searchHandler = { query in
            searchStarted.fulfill()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return [NuvioMeta(id: "too_late", name: "Too Late", type: "movie")]
        }

        viewModel.performSearch(query: "HangingQuery")
        await fulfillment(of: [searchStarted], timeout: 2.0)
        XCTAssertTrue(viewModel.isLoading)

        let deadline = Date().addingTimeInterval(1.0)
        while viewModel.isLoading && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNotNil(viewModel.error)
        XCTAssertTrue(viewModel.results.isEmpty)
    }

    @MainActor
    func testNetflixSearchTimeoutGracefullyRecoversFromHangingRepository() async throws {
        let repo = ControllableLifecycleRepository()
        let viewModel = NetflixSearchViewModel(repository: repo, searchTimeout: 0.1)

        let searchStarted = expectation(description: "netflix search started")
        repo.searchHandler = { query in
            searchStarted.fulfill()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return [NuvioMeta(id: "too_late", name: "Too Late", type: "movie")]
        }

        viewModel.performSearch(query: "HangingQuery")
        await fulfillment(of: [searchStarted], timeout: 2.0)
        XCTAssertTrue(viewModel.isLoading)

        let deadline = Date().addingTimeInterval(1.0)
        while viewModel.isLoading && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNotNil(viewModel.error)
        XCTAssertTrue(viewModel.results.isEmpty)
    }

    func testSearchKeepsFastAddonWhenAnotherManifestExceedsDiscoveryDeadline() async throws {
        let defaults = ProfileSettings.current
        let previousPreferences = CinemetaCatalogRepository.configuredStreamAddonPreferences(in: defaults)
        let previousCinemetaDisabled = defaults.object(forKey: SettingsKey.cinemetaDisabled)
        let fastManifestURL = URL(string: "https://fast-addon.invalid/manifest.json")!
        let slowManifestURL = URL(string: "https://slow-addon.invalid/manifest.json")!
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [SearchManifestFixtureURLProtocol.self]
        let fixtureSession = URLSession(configuration: sessionConfiguration)
        await StremioManifestDataCache.shared.clear()
        await StremioManifestDataCache.shared.setSessionForTesting(fixtureSession)
        CinemetaCatalogRepository.setNetworkSessionForTesting(fixtureSession)
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences(
            [
                StreamAddonPreference(url: fastManifestURL.absoluteString, enabled: true),
                StreamAddonPreference(url: slowManifestURL.absoluteString, enabled: true)
            ],
            in: defaults
        )
        CinemetaCatalogRepository.setCinemetaDisabled(true, in: defaults)
        XCTAssertFalse(CinemetaCatalogRepository.isCinemetaEnabled)
        XCTAssertEqual(
            CinemetaCatalogRepository.configuredStreamAddonManifestURLs,
            [fastManifestURL, slowManifestURL]
        )
        func resetFixtureSession() async {
            await StremioManifestDataCache.shared.setSessionForTesting(nil)
            await StremioManifestDataCache.shared.clear()
            CinemetaCatalogRepository.setNetworkSessionForTesting(nil)
            fixtureSession.invalidateAndCancel()
        }
        defer {
            SearchManifestFixtureURLProtocol.reset()
            CinemetaCatalogRepository.setNetworkSessionForTesting(nil)
            fixtureSession.invalidateAndCancel()
            CinemetaCatalogRepository.setConfiguredStreamAddonPreferences(previousPreferences, in: defaults)
            if let previousCinemetaDisabled {
                defaults.set(previousCinemetaDisabled, forKey: SettingsKey.cinemetaDisabled)
            } else {
                defaults.removeObject(forKey: SettingsKey.cinemetaDisabled)
            }
        }

        let fastManifest = Data(#"{"id":"fast.addon","name":"Fast Addon","types":["movie"],"catalogs":[{"type":"movie","id":"search","extra":[{"name":"search","isRequired":true}]}]}"#.utf8)
        let fastCatalog = Data(#"{"metas":[{"id":"tt1234567","name":"Fast Addon Result","type":"movie"}]}"#.utf8)
        SearchManifestFixtureURLProtocol.install { request in
            guard let url = request.url else { return nil }
            if url.host == "fast-addon.invalid", url.path == "/manifest.json" {
                return .init(statusCode: 200, data: fastManifest)
            }
            if url.host == "slow-addon.invalid", url.path == "/manifest.json" {
                return .init(statusCode: 200, data: fastManifest, delay: 5)
            }
            if url.host == "fast-addon.invalid", url.path.hasPrefix("/catalog/") {
                return .init(statusCode: 200, data: fastCatalog)
            }
            return .init(statusCode: 404, data: Data())
        }

        let startedAt = Date()
        let results: [NuvioMeta]
        do {
            results = try await CinemetaCatalogRepository().search(query: "Matrix")
        } catch {
            await resetFixtureSession()
            throw error
        }
        await resetFixtureSession()
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 4, "one slow manifest should not extend discovery past its deadline")
        XCTAssertEqual(results.map(\.id), ["tt1234567"])
        XCTAssertEqual(results.first?.name, "Fast Addon Result")
    }

    @MainActor
    func testSearchStaleCompletionCannotCancelReplacementTimeout() async throws {
        let repo = ControllableLifecycleRepository()
        try await assertStaleSearchCompletionDoesNotCancelTimeout(
            SearchViewModel(repository: repo, searchTimeout: 0.3), repository: repo
        )
    }

    @MainActor
    func testNetflixSearchStaleCompletionCannotCancelReplacementTimeout() async throws {
        let repo = ControllableLifecycleRepository()
        try await assertStaleSearchCompletionDoesNotCancelTimeout(
            NetflixSearchViewModel(repository: repo, searchTimeout: 0.3), repository: repo
        )
    }

    @MainActor
    private func assertStaleSearchCompletionDoesNotCancelTimeout(
        _ viewModel: any SearchLifecycleModel,
        repository: ControllableLifecycleRepository
    ) async throws {
        let oldStarted = expectation(description: "stale request started")
        let replacementStarted = expectation(description: "replacement request started")
        let releaseOld = expectation(description: "release stale request")
        let oldReturned = expectation(description: "stale request returned")
        repository.searchHandler = { query in
            switch query {
            case "Old query":
                oldStarted.fulfill()
                await self.fulfillment(of: [releaseOld], timeout: 3)
                oldReturned.fulfill()
                return [NuvioMeta(id: "stale", name: "Stale", type: "movie")]
            case "Replacement query":
                replacementStarted.fulfill()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return [NuvioMeta(id: "late", name: "Late", type: "movie")]
            default:
                XCTFail("Unexpected query: \(query)")
                return []
            }
        }

        viewModel.performSearch(query: "Old query")
        await fulfillment(of: [oldStarted], timeout: 2)
        viewModel.performSearch(query: "Replacement query")
        await fulfillment(of: [replacementStarted], timeout: 2)

        releaseOld.fulfill()
        await fulfillment(of: [oldReturned], timeout: 1)

        let deadline = Date().addingTimeInterval(1)
        while viewModel.isLoading && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(viewModel.isLoading, "replacement watchdog should still time out after stale completion")
        XCTAssertTrue(viewModel.error?.localizedCaseInsensitiveContains("timed out") == true)
        XCTAssertTrue(viewModel.results.isEmpty)
    }

    @MainActor
    func testDiscoverReloadCancelsInFlightPaginationAndGuardsState() async throws {
        let repo = ControllableLifecycleRepository()
        let paginationStarted = expectation(description: "pagination started")
        let paginationCanFinish = expectation(description: "pagination can finish")

        repo.browseDiscoverHandler = { option, page, genre in
            if page == 2 && option.type == "movie" {
                paginationStarted.fulfill()
                await self.fulfillment(of: [paginationCanFinish], timeout: 5.0)
                return CatalogPage(
                    items: [
                        NuvioMeta(
                            id: "stale_page2_movie",
                            name: "Stale Page 2 Movie",
                            posterUrl: nil,
                            backgroundUrl: nil,
                            logoUrl: nil,
                            imdbId: nil,
                            tmdbId: nil,
                            type: "movie",
                            year: 2024
                        )
                    ],
                    hasMore: false,
                    page: 2
                )
            }
            let items = (1...5).map { i in
                NuvioMeta(
                    id: "\(option.type)_\(page)_\(i)",
                    name: "\(option.type) \(page) \(i)",
                    posterUrl: nil,
                    backgroundUrl: nil,
                    logoUrl: nil,
                    imdbId: nil,
                    tmdbId: nil,
                    type: option.type,
                    year: 2024
                )
            }
            return CatalogPage(items: items, hasMore: true, page: page)
        }

        let viewModel = DiscoverViewModel(repository: repo)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.items.count, 5)

        // Trigger pagination (loading page 2)
        viewModel.loadMoreIfNeeded(currentItem: viewModel.items.last!)
        await fulfillment(of: [paginationStarted], timeout: 2.0)
        XCTAssertTrue(viewModel.isLoadingMore)

        // User switches type to series, which triggers reload()
        viewModel.setType("series")
        try await Task.sleep(nanoseconds: 100_000_000)

        // Now let the stale page 2 from "movie" finish
        paginationCanFinish.fulfill()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify: items contains series items only, NOT contaminated by stale movie page 2
        XCTAssertTrue(viewModel.items.allSatisfy { $0.type == "series" })
        XCTAssertFalse(viewModel.items.contains(where: { $0.id == "stale_page2_movie" }))
        XCTAssertFalse(viewModel.isLoadingMore)
        XCTAssertTrue(viewModel.hasMore)
    }
}

private final class SearchManifestFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let statusCode: Int
        let data: Data
        var delay: TimeInterval = 0
        var responseURL: URL? = nil
    }

    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> Reply?)?
    private let stateLock = NSLock()
    private var stopped = false

    static func install(_ newHandler: @escaping (URLRequest) -> Reply?) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    private static func reply(for request: URLRequest) -> Reply? {
        lock.lock()
        let currentHandler = handler
        lock.unlock()
        return currentHandler?(request)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let reply = Self.reply(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [weak self] in
                self?.finish(reply)
            }
        } else {
            finish(reply)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private func finish(_ reply: Reply) {
        stateLock.lock()
        let isStopped = stopped
        stateLock.unlock()
        guard !isStopped,
              let url = request.url,
              let response = HTTPURLResponse(
                url: reply.responseURL ?? url,
                statusCode: reply.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class SearchFixtureRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [String] = []

    var urls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }

    func record(_ url: URL) {
        lock.lock()
        recordedURLs.append(url.absoluteString)
        lock.unlock()
    }
}

// MARK: - Collection Folder Pagination Tests

final class CollectionFolderPaginationTests: XCTestCase {
    func testPagination40TitlesSinglePage() {
        let source = NuvioCollectionSource(provider: "addon", addonId: "cinemeta", type: "movie", catalogId: "top")
        let items = (0..<40).map { NuvioMeta(id: "item_\($0)", name: "Item \($0)", type: "movie") }
        let page = CatalogPage(items: items, hasMore: false, page: 1)

        let initial = CollectionFolderBrowseView.calculatePagination(page: page, source: source, requestedCursor: 0, pageSize: 40)
        XCTAssertEqual(initial.displayItems.count, 40)
        XCTAssertEqual(initial.nextCursor, 40)
        XCTAssertFalse(initial.hasMore)
    }

    func testPagination60TitlesExposesEveryItemWithoutSkipsOrLoops() {
        let source = NuvioCollectionSource(provider: "addon", addonId: "cinemeta", type: "movie", catalogId: "top")
        let allItems = (0..<60).map { NuvioMeta(id: "item_\($0)", name: "Item \($0)", type: "movie") }

        // Initial load returns 60 items with hasMore = false (e.g. all in one batch from source)
        let page1 = CatalogPage(items: allItems, hasMore: false, page: 1)
        let p1 = CollectionFolderBrowseView.calculatePagination(page: page1, source: source, requestedCursor: 0, pageSize: 40)
        XCTAssertEqual(p1.displayItems.count, 40)
        XCTAssertEqual(p1.displayItems.map(\.id), (0..<40).map { "item_\($0)" })
        XCTAssertEqual(p1.nextCursor, 40)
        XCTAssertTrue(p1.hasMore, "Should have more because 60 exceeds pageSize 40")

        // Next load requests cursor 40, receives remaining items 40..<60 (20 items)
        let page2Items = Array(allItems.dropFirst(40))
        let page2 = CatalogPage(items: page2Items, hasMore: false, page: 2)
        let p2 = CollectionFolderBrowseView.calculatePagination(page: page2, source: source, requestedCursor: 40, pageSize: 40)
        XCTAssertEqual(p2.displayItems.count, 20)
        XCTAssertEqual(p2.displayItems.map(\.id), (40..<60).map { "item_\($0)" })
        XCTAssertEqual(p2.nextCursor, 60)
        XCTAssertFalse(p2.hasMore, "Should have no more because 20 does not exceed 40 and page.hasMore is false")

        let combined = p1.displayItems + p2.displayItems
        XCTAssertEqual(combined.count, 60)
        XCTAssertEqual(combined.map(\.id), allItems.map(\.id))
    }

    func testPagination100TitlesExposesEveryItemWithoutSkipsOrLoops() {
        let source = NuvioCollectionSource(provider: "addon", addonId: "cinemeta", type: "movie", catalogId: "top")
        let allItems = (0..<100).map { NuvioMeta(id: "item_\($0)", name: "Item \($0)", type: "movie") }

        // Load 1: cursor 0
        let page1 = CatalogPage(items: allItems, hasMore: false, page: 1)
        let p1 = CollectionFolderBrowseView.calculatePagination(page: page1, source: source, requestedCursor: 0, pageSize: 40)
        XCTAssertEqual(p1.displayItems.count, 40)
        XCTAssertEqual(p1.nextCursor, 40)
        XCTAssertTrue(p1.hasMore)

        // Load 2: cursor 40 (source returns items 40..<100 = 60 items)
        let page2 = CatalogPage(items: Array(allItems.dropFirst(40)), hasMore: false, page: 2)
        let p2 = CollectionFolderBrowseView.calculatePagination(page: page2, source: source, requestedCursor: 40, pageSize: 40)
        XCTAssertEqual(p2.displayItems.count, 40)
        XCTAssertEqual(p2.nextCursor, 80)
        XCTAssertTrue(p2.hasMore)

        // Load 3: cursor 80 (source returns items 80..<100 = 20 items)
        let page3 = CatalogPage(items: Array(allItems.dropFirst(80)), hasMore: false, page: 3)
        let p3 = CollectionFolderBrowseView.calculatePagination(page: page3, source: source, requestedCursor: 80, pageSize: 40)
        XCTAssertEqual(p3.displayItems.count, 20)
        XCTAssertEqual(p3.nextCursor, 100)
        XCTAssertFalse(p3.hasMore)

        let combined = p1.displayItems + p2.displayItems + p3.displayItems
        XCTAssertEqual(combined.count, 100)
        XCTAssertEqual(combined.map(\.id), allItems.map(\.id))
    }

    func testPagination140TitlesExposesEveryItemWithoutSkipsOrLoops() {
        let source = NuvioCollectionSource(provider: "addon", addonId: "cinemeta", type: "movie", catalogId: "top")
        let allItems = (0..<140).map { NuvioMeta(id: "item_\($0)", name: "Item \($0)", type: "movie") }

        // Load 1: cursor 0 -> returns items 0..<100 (hasMore = true)
        let p1 = CollectionFolderBrowseView.calculatePagination(
            page: CatalogPage(items: Array(allItems.prefix(100)), hasMore: true, page: 1),
            source: source,
            requestedCursor: 0,
            pageSize: 40
        )
        XCTAssertEqual(p1.displayItems.count, 40)
        XCTAssertEqual(p1.nextCursor, 40)
        XCTAssertTrue(p1.hasMore)

        // Load 2: cursor 40 -> returns items 40..<140 (100 items, hasMore = true)
        let p2 = CollectionFolderBrowseView.calculatePagination(
            page: CatalogPage(items: Array(allItems.dropFirst(40).prefix(100)), hasMore: true, page: 2),
            source: source,
            requestedCursor: 40,
            pageSize: 40
        )
        XCTAssertEqual(p2.displayItems.count, 40)
        XCTAssertEqual(p2.nextCursor, 80)
        XCTAssertTrue(p2.hasMore)

        // Load 3: cursor 80 -> returns items 80..<140 (60 items, hasMore = false)
        let p3 = CollectionFolderBrowseView.calculatePagination(
            page: CatalogPage(items: Array(allItems.dropFirst(80)), hasMore: false, page: 3),
            source: source,
            requestedCursor: 80,
            pageSize: 40
        )
        XCTAssertEqual(p3.displayItems.count, 40)
        XCTAssertEqual(p3.nextCursor, 120)
        XCTAssertTrue(p3.hasMore)

        // Load 4: cursor 120 -> returns items 120..<140 (20 items, hasMore = false)
        let p4 = CollectionFolderBrowseView.calculatePagination(
            page: CatalogPage(items: Array(allItems.dropFirst(120)), hasMore: false, page: 4),
            source: source,
            requestedCursor: 120,
            pageSize: 40
        )
        XCTAssertEqual(p4.displayItems.count, 20)
        XCTAssertEqual(p4.nextCursor, 140)
        XCTAssertFalse(p4.hasMore)

        let combined = p1.displayItems + p2.displayItems + p3.displayItems + p4.displayItems
        XCTAssertEqual(combined.count, 140)
        XCTAssertEqual(combined.map(\.id), allItems.map(\.id))
    }

    func testPaginationPreservesHasMoreIndependentOfDisplayDeduplication() {
        let source = NuvioCollectionSource(provider: "addon", addonId: "cinemeta", type: "movie", catalogId: "top")
        let items = (0..<40).map { NuvioMeta(id: "dup_\($0)", name: "Dup \($0)", type: "movie") }
        let page = CatalogPage(items: items, hasMore: true, page: 1)
        let result = CollectionFolderBrowseView.calculatePagination(page: page, source: source, requestedCursor: 0, pageSize: 40)
        XCTAssertEqual(result.displayItems.count, 40)
        XCTAssertEqual(result.nextCursor, 40)
        XCTAssertTrue(result.hasMore)
    }
}

// MARK: - Cloud Library Lifecycle Tests

final class CloudLibraryLifecycleTests: XCTestCase {
    @MainActor
    func testCloudLibraryCancelsResolvingOnDepartureAndRejectsStaleCallback() async throws {
        let testStore = UserDefaults(suiteName: "CloudLibraryTests.\(UUID().uuidString)")!
        let viewModel = CloudLibraryViewModel(store: testStore)

        let item = CloudItem(
            providerId: "torbox",
            id: "item1",
            type: .torrent,
            name: "Test Item",
            status: "completed",
            sizeBytes: 1024,
            files: [
                CloudFile(id: "f1", name: "File 1", sizeBytes: 1024, mimeType: "video/mp4", playable: true, playbackUrl: nil)
            ]
        )
        let file = item.files[0]

        var resolvedCalled = false
        viewModel.play(item: item, file: file) { _, _ in
            resolvedCalled = true
        }

        // Cancel immediately simulating screen departure
        viewModel.cancelResolving()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(resolvedCalled, "Callback should be rejected on cancellation")
        XCTAssertNil(viewModel.resolvingKey)
        XCTAssertNil(viewModel.playbackErrorMessage)
    }

    @MainActor
    func testCloudLibraryPlaybackErrorSetsPlaybackErrorMessageRegardlessOfItemsEmpty() async throws {
        let testStore = UserDefaults(suiteName: "CloudLibraryTests.\(UUID().uuidString)")!
        let viewModel = CloudLibraryViewModel(store: testStore)

        let item = CloudItem(
            providerId: "torbox",
            id: "item1",
            type: .torrent,
            name: "Test Item",
            status: "completed",
            sizeBytes: 1024,
            files: [
                CloudFile(id: "f1", name: "File 1", sizeBytes: 1024, mimeType: "video/mp4", playable: true, playbackUrl: nil)
            ]
        )
        let file = item.files[0]

        // When items are empty and playback fails
        viewModel.play(item: item, file: file) { _, _ in }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNotNil(viewModel.playbackErrorMessage, "Playback error should be set for empty items")
        viewModel.clearPlaybackError()
        XCTAssertNil(viewModel.playbackErrorMessage)

        // When items are not empty and playback fails
        // Playback error message must STILL be set so native alert is triggered!
        viewModel.play(item: item, file: file) { _, _ in }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNotNil(viewModel.playbackErrorMessage, "Playback error must be set regardless of items.isEmpty")
    }

    @MainActor
    func testCloudLibraryPreservesOpenItemAndFocusedKey() {
        let testStore = UserDefaults(suiteName: "CloudLibraryTests.\(UUID().uuidString)")!
        let viewModel = CloudLibraryViewModel(store: testStore)

        let item = CloudItem(
            providerId: "torbox",
            id: "item1",
            type: .torrent,
            name: "Test Folder",
            status: "completed",
            sizeBytes: 2048,
            files: [
                CloudFile(id: "f1", name: "Ep 1", sizeBytes: 1024, mimeType: "video/mp4", playable: true, playbackUrl: nil),
                CloudFile(id: "f2", name: "Ep 2", sizeBytes: 1024, mimeType: "video/mp4", playable: true, playbackUrl: nil)
            ]
        )

        viewModel.openItem = item
        viewModel.focusedKey = "torbox:torrent:item1:f2"

        XCTAssertEqual(viewModel.openItem?.id, "item1")
        XCTAssertEqual(viewModel.focusedKey, "torbox:torrent:item1:f2")
    }

    @MainActor
    func testCloudPlaybackPreservesSingleFileItemFocus() {
        let testStore = UserDefaults(suiteName: "CloudLibraryTests.\(UUID().uuidString)")!
        let viewModel = CloudLibraryViewModel(store: testStore)
        let file = CloudFile(id: "f1", name: "Movie", sizeBytes: nil, mimeType: "video/mp4", playable: true, playbackUrl: nil)
        let item = CloudItem(providerId: "torbox", id: "single", type: .torrent, name: "Movie", status: nil, sizeBytes: nil, files: [file])

        // The top-level list focuses the item, not a file row inside a folder.
        viewModel.focusedKey = item.stableKey
        viewModel.play(item: item, file: file) { _, _ in }
        defer { viewModel.cancelResolving() }

        XCTAssertEqual(viewModel.resolvingKey, "\(item.stableKey):\(file.id)")
        XCTAssertEqual(viewModel.focusedKey, item.stableKey)
    }

    @MainActor
    func testCloudPlaybackPreservesFolderFileFocus() {
        let testStore = UserDefaults(suiteName: "CloudLibraryTests.\(UUID().uuidString)")!
        let viewModel = CloudLibraryViewModel(store: testStore)
        let files = ["f1", "f2"].map {
            CloudFile(id: $0, name: $0, sizeBytes: nil, mimeType: "video/mp4", playable: true, playbackUrl: nil)
        }
        let item = CloudItem(providerId: "torbox", id: "folder", type: .torrent, name: "Season", status: nil, sizeBytes: nil, files: files)
        let focusedFileKey = "\(item.stableKey):\(files[1].id)"
        viewModel.openItem = item
        viewModel.focusedKey = focusedFileKey

        viewModel.play(item: item, file: files[1]) { _, _ in }
        defer { viewModel.cancelResolving() }

        XCTAssertEqual(viewModel.openItem, item)
        XCTAssertEqual(viewModel.focusedKey, focusedFileKey)
    }

    func testTVScreenIsPlayerProperty() {
        let playerScreen = TVScreen.player(
            url: URL(string: "https://example.com/video.mp4")!,
            meta: NuvioMeta(id: "test", name: "Test", type: "movie"),
            subtitle: "",
            httpHeaders: [:],
            externalSubtitles: [],
            resumeFrom: nil
        )
        XCTAssertTrue(playerScreen.isPlayer)
        XCTAssertFalse(TVScreen.cloudLibrary.isPlayer)
        XCTAssertFalse(TVScreen.main.isPlayer)
    }

    func testTVOSKeyboardLayoutModeCases() {
        XCTAssertEqual(TVOSKeyboardLayoutMode.linear.rawValue, "Linear")
        XCTAssertEqual(TVOSKeyboardLayoutMode.grid.rawValue, "Grid")
        XCTAssertEqual(TVOSKeyboardLayoutMode.allCases.count, 2)
    }
}
