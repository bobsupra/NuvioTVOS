//
//  CatalogRepositoryIntegrationTests.swift
//  NuvioTVTests
//
//  Integration-style tests for the catalog repository boundary.
//  Uses MockCatalogRepository; production uses CinemetaCatalogRepository.
//

import XCTest
@testable import NuvioTV

final class CatalogRepositoryIntegrationTests: XCTestCase {

    var repository: CatalogRepository!

    override func setUp() {
        repository = MockCatalogRepository()
    }

    override func tearDown() {
        repository = nil
    }

    // MARK: - Basic repository tests

    func testRepositoryInitialization() async throws {
        XCTAssertNotNil(repository, "Repository should be initialized")

        let catalogs = try await repository.getHomeCatalogs()
        XCTAssertNotNil(catalogs, "Should be able to fetch catalogs")
    }

    // MARK: - Catalog fetching tests

    func testFetchHomeCatalogs() async throws {
        let catalogs = try await repository.getHomeCatalogs()
        XCTAssertFalse(catalogs.isEmpty, "Mock repository should return home catalogs")
    }

    func testFetchMetadata() async throws {
        let catalogs = try await repository.getHomeCatalogs()
        guard let first = catalogs.first, let itemId = first.itemIds.first else {
            XCTFail("Mock catalogs should include at least one item id")
            return
        }
        let meta = try await repository.getMetadata(id: itemId, type: first.contentType ?? "movie")
        XCTAssertEqual(meta.id, itemId)
    }
}
