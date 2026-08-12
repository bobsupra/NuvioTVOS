import XCTest
@testable import NuvioTV

/// Cover for Home's landscape shelf artwork: the merge that fills a compact
/// catalog card from its full `/meta` record must never clobber catalog-
/// provided artwork, and the Stremio `logo` field must decode into
/// `NuvioMeta.logoUrl` so `PosterCard` can draw it in the landscape overlay.
final class CatalogArtworkMergeTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testMergeFillsMissingArtworkAndIdentifiers() {
        let catalog = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            description: "catalog copy",
            posterUrl: "https://cdn.example/poster.jpg",
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt0903747",
            tmdbId: nil,
            type: "series",
            year: 2008,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil
        )
        let full = NuvioMeta(
            id: "tt0903747",
            name: "Breaking Bad",
            description: "full copy",
            posterUrl: "https://cdn.example/tmdb-poster.jpg",
            backgroundUrl: "https://cdn.example/backdrop.jpg",
            logoUrl: "https://cdn.example/logo.png",
            imdbId: "tt0903747",
            tmdbId: 1396,
            type: "series",
            year: 2008,
            genres: ["Crime"],
            rating: 9.5,
            releaseInfo: "2008",
            runtime: "47 min",
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: "Ended",
            videos: nil,
            trailerYtIds: ["abc"]
        )

        let merged = catalog.fillingMissingHeroMetadata(from: full)

        // Catalog-provided poster wins over refreshed artwork.
        XCTAssertEqual(merged.posterUrl, "https://cdn.example/poster.jpg")
        // Missing backdrop/logo are filled.
        XCTAssertEqual(merged.backgroundUrl, "https://cdn.example/backdrop.jpg")
        XCTAssertEqual(merged.logoUrl, "https://cdn.example/logo.png")
        // Missing identifiers, runtime, and status are filled.
        XCTAssertEqual(merged.tmdbId, 1396)
        XCTAssertEqual(merged.runtime, "47 min")
        XCTAssertEqual(merged.status, "Ended")
        // Catalog copy is preserved; refreshed copy never replaces it.
        XCTAssertEqual(merged.description, "catalog copy")
        XCTAssertNil(merged.genres)
        XCTAssertNil(merged.rating)
    }

    func testMergeKeepsSourceLogoAndTreatsBlankArtworkAsMissing() {
        let catalog = NuvioMeta(
            id: "tt0111161",
            name: "The Shawshank Redemption",
            description: nil,
            posterUrl: "https://cdn.example/poster.jpg",
            backgroundUrl: "   ",
            logoUrl: "https://source.example/logo.png",
            imdbId: nil,
            tmdbId: nil,
            type: "movie",
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil
        )
        let full = NuvioMeta(
            id: "tt0111161",
            name: "The Shawshank Redemption",
            description: nil,
            posterUrl: "https://cdn.example/tmdb-poster.jpg",
            backgroundUrl: "https://cdn.example/backdrop.jpg",
            logoUrl: "https://tmdb.example/logo.png",
            imdbId: "tt0111161",
            tmdbId: 278,
            type: "movie",
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: "142 min",
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil
        )

        let merged = catalog.fillingMissingHeroMetadata(from: full)

        // A source-provided logo is never replaced by a TMDB one.
        XCTAssertEqual(merged.logoUrl, "https://source.example/logo.png")
        // A blank backdrop counts as missing and is filled.
        XCTAssertEqual(merged.backgroundUrl, "https://cdn.example/backdrop.jpg")
        XCTAssertEqual(merged.runtime, "142 min")
        XCTAssertEqual(merged.tmdbId, 278)
    }

    /// A Stremio catalog page's `logo` field must survive decoding so Home can
    /// draw the title logo in the landscape overlay — the field this feature
    /// depends on after the merge above fills it in.
    func testDecodesStremioLogoField() throws {
        let json = Data("""
        {"metas":[{
          "id":"tt0903747","type":"series","name":"Breaking Bad",
          "poster":"https://images.example/poster.jpg",
          "background":"https://images.example/backdrop.jpg",
          "logo":"https://images.example/logo.png",
          "imdbRating":"9.5","runtime":"47 min","status":"Ended"
        }]}
        """.utf8)

        let response = try decoder.decode(CinemetaCatalogResponse.self, from: json)
        let meta = try XCTUnwrap(response.metas.first).toMeta(fallbackType: "series")

        XCTAssertEqual(meta.logoUrl, "https://images.example/logo.png")
        XCTAssertEqual(meta.backgroundUrl, "https://images.example/backdrop.jpg")
        XCTAssertEqual(meta.posterUrl, "https://images.example/poster.jpg")
        XCTAssertEqual(meta.runtime, "47 min")
        XCTAssertEqual(meta.status, "Ended")
        XCTAssertEqual(meta.imdbId, "tt0903747")
    }

    /// Search returns an IMDb-first compact record while watch history knows
    /// the title only as `tmdb:<id>`. Only the aliases the background
    /// enrichment adds can make the Search card resolve to the same watched
    /// record — movie-title matching must never be used, since duplicate
    /// names make that unsafe.
    func testEnrichedSearchResultMatchesTMDBFirstWatchedRecord() {
        let searchResult = makeMeta(
            id: "tt0903747",
            imdbId: nil,
            tmdbId: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            runtime: nil,
            status: nil
        )
        let watched = makeMeta(
            id: "tmdb:1396",
            imdbId: nil,
            tmdbId: 1396,
            backgroundUrl: nil,
            logoUrl: nil,
            runtime: nil,
            status: nil
        )

        XCTAssertFalse(
            WatchedStore.sameContent(searchResult, watched),
            "compact search record cannot match a TMDB-first watched record yet"
        )

        // The refreshed /meta record carries both aliases (plus artwork).
        let full = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: 1396,
            posterUrl: "https://cdn.example/refreshed-poster.jpg",
            backgroundUrl: "https://cdn.example/backdrop.jpg",
            logoUrl: "https://cdn.example/logo.png",
            runtime: "47 min",
            status: "Ended"
        )
        let enriched = searchResult.mergingSearchMetadata(from: full)

        XCTAssertEqual(enriched.id, "tt0903747", "original result id / focus identity is preserved")
        XCTAssertEqual(enriched.imdbId, "tt0903747")
        XCTAssertEqual(enriched.tmdbId, 1396)
        XCTAssertEqual(enriched.backgroundUrl, "https://cdn.example/backdrop.jpg")
        XCTAssertEqual(enriched.logoUrl, "https://cdn.example/logo.png")
        XCTAssertTrue(
            WatchedStore.sameContent(enriched, watched),
            "enriched aliases must match the TMDB-first watched record"
        )
        XCTAssertFalse(
            WatchedStore.sameContent(enriched, makeMeta(id: "tmdb:999", imdbId: nil, tmdbId: 999)),
            "alias matching must never fall back to movie titles"
        )
    }

    /// The background search enrichment keeps result ids, order, and complete
    /// records untouched while merging the missing aliases/artwork into the
    /// compact leading results.
    func testSearchEnrichmentPreservesIDsAndFillsAliasesAndArtwork() async {
        let rawResult = makeMeta(
            id: "tt0903747",
            imdbId: nil,
            tmdbId: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            runtime: nil,
            status: nil
        )
        // A fully-populated record needs no refresh — it must pass through
        // untouched (and not generate a repository request).
        let complete = makeMeta(
            id: "tt0133093",
            imdbId: "tt0133093",
            tmdbId: 603,
            type: "movie",
            backgroundUrl: "https://cdn.example/b.jpg",
            logoUrl: "https://cdn.example/l.png",
            runtime: "136 min",
            status: nil
        )
        let full = makeMeta(
            id: "tt0903747",
            imdbId: "tt0903747",
            tmdbId: 1396,
            posterUrl: "https://cdn.example/refreshed-poster.jpg",
            backgroundUrl: "https://cdn.example/backdrop.jpg",
            logoUrl: "https://cdn.example/logo.png",
            runtime: "47 min",
            status: "Ended"
        )

        let repository = StubRefreshRepository(fullByID: ["tt0903747": full])
        let enriched = await SearchResultEnrichment.enrich(
            [rawResult, complete],
            repository: repository
        )

        XCTAssertEqual(enriched.map(\.id), ["tt0903747", "tt0133093"], "ids and order are preserved")
        XCTAssertEqual(enriched[0].imdbId, "tt0903747")
        XCTAssertEqual(enriched[0].tmdbId, 1396)
        XCTAssertEqual(enriched[0].posterUrl, "https://cdn.example/refreshed-poster.jpg")
        XCTAssertEqual(enriched[0].backgroundUrl, "https://cdn.example/backdrop.jpg")
        XCTAssertEqual(enriched[0].logoUrl, "https://cdn.example/logo.png")
        XCTAssertEqual(enriched[0].runtime, "47 min")
        XCTAssertEqual(enriched[0].status, "Ended")
        XCTAssertEqual(enriched[1].tmdbId, 603, "complete record must be untouched")
    }

    private func makeMeta(
        id: String,
        imdbId: String?,
        tmdbId: Int?,
        type: String = "series",
        posterUrl: String? = "https://cdn.example/poster.jpg",
        backgroundUrl: String? = "bg",
        logoUrl: String? = "logo",
        runtime: String? = "45 min",
        status: String? = "Ended"
    ) -> NuvioMeta {
        NuvioMeta(
            id: id,
            name: "Test Title",
            description: nil,
            posterUrl: posterUrl,
            backgroundUrl: backgroundUrl,
            logoUrl: logoUrl,
            imdbId: imdbId,
            tmdbId: tmdbId,
            type: type,
            year: nil,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: runtime,
            cast: nil,
            director: nil,
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: status
        )
    }
}

/// Repository stub whose `/meta` refresh answers from a fixed table, so the
/// search-enrichment helper can be tested without network access.
private final class StubRefreshRepository: MockCatalogRepository {
    private let fullByID: [String: NuvioMeta]

    init(fullByID: [String: NuvioMeta]) {
        self.fullByID = fullByID
    }

    override func refreshMetadata(id: String, type: String) async throws -> NuvioMeta {
        if let full = fullByID[id] { return full }
        throw URLError(.badServerResponse)
    }
}
