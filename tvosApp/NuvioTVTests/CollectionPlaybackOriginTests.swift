import XCTest
@testable import NuvioTV

final class CollectionPlaybackOriginTests: XCTestCase {
    private let netflix = CollectionOriginReference(collectionID: "services", folderID: "netflix")
    private let hulu = CollectionOriginReference(collectionID: "services", folderID: "hulu")

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "CollectionPlaybackOriginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func context(
        _ meta: NuvioMeta, profile: String = "a",
        origin: CollectionOriginReference? = nil, resume: Bool = false
    ) -> CollectionPlaybackContext {
        CollectionPlaybackContext(
            profileID: profile, contentID: meta.id, type: meta.type,
            origin: origin, preservesStoredOrigin: resume
        )
    }

    private func start(
        _ meta: NuvioMeta, _ context: CollectionPlaybackContext,
        activeProfile: String = "a", defaults: UserDefaults
    ) {
        CollectionPlaybackOriginStore.recordStarted(
            meta: meta, context: context, activeProfileID: activeProfile, defaults: defaults
        )
    }

    private func folder(
        style: String? = nil, sources: [[String: Any]], title: String = "Custom"
    ) throws -> TVCollectionFolderItem {
        var json: [String: Any] = ["id": "f", "title": title, "sources": sources]
        if let style { json["presentationStyle"] = style }
        let value = try JSONDecoder().decode(
            NuvioCollectionFolder.self, from: JSONSerialization.data(withJSONObject: json)
        )
        return TVCollectionFolderItem(collectionId: "c", folder: value, sources: value.resolvedSources)
    }

    func testGenresAndNamesAloneNeverBecomeServiceOrigins() throws {
        let genre: [[String: Any]] = [
            ["provider": "tmdb", "tmdbSourceType": "DISCOVER", "filters": ["withGenres": "28"]]
        ]
        let namedNetflix = try folder(sources: genre, title: "Netflix")
        XCTAssertNil(CollectionOriginPresentation.service(folder: namedNetflix))
        let addonGenre = try folder(sources: [
            ["addonId": "custom", "catalogId": "movies", "genre": "Action"]
        ])
        XCTAssertNil(CollectionOriginPresentation.service(folder: addonGenre))
    }

    func testExplicitCustomServiceAndProviderFiltersAreEligible() throws {
        let custom = try folder(style: "STREAMING_SERVICE", sources: [
            ["addonId": "custom", "catalogId": "movies"]
        ])
        XCTAssertNotNil(CollectionOriginPresentation.service(folder: custom))
        let provider = try folder(sources: [
            ["provider": "tmdb", "tmdbSourceType": "DISCOVER", "filters": ["withWatchProviders": "8"]]
        ])
        XCTAssertNotNil(CollectionOriginPresentation.service(folder: provider))
        let studio = try folder(style: "STUDIO_FRANCHISE", sources: [
            ["provider": "tmdb", "tmdbSourceType": "DISCOVER", "filters": ["withWatchProviders": "8"]]
        ])
        XCTAssertNil(CollectionOriginPresentation.service(folder: studio))
        XCTAssertNil(CollectionOriginPresentation.service(folder: try folder(style: "STREAMING_SERVICE", sources: [])))
    }

    func testResumePreservesOriginButNewUnscopedPlaybackClearsIt() {
        withDefaults { defaults in
            let meta = NuvioMeta(id: "tt123", name: "Title", type: "movie")
            start(meta, context(meta, origin: netflix), defaults: defaults)
            start(meta, context(meta, resume: true), defaults: defaults)
            XCTAssertEqual(CollectionPlaybackOriginStore.entries(profileID: "a", defaults: defaults).first?.origin, netflix)
            start(meta, context(meta), defaults: defaults)
            XCTAssertTrue(CollectionPlaybackOriginStore.entries(profileID: "a", defaults: defaults).isEmpty)
        }
    }

    func testLatestServiceReplacesAnnotationWithoutCreatingAnotherTitleEntry() {
        withDefaults { defaults in
            let meta = NuvioMeta(id: "tt123", name: "Series", type: "series")
            start(meta, context(meta, origin: netflix), defaults: defaults)
            start(meta, context(meta, origin: hulu), defaults: defaults)
            let entries = CollectionPlaybackOriginStore.entries(profileID: "a", defaults: defaults)
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.origin, hulu)
        }
    }

    func testProfilesAreIsolatedAndStaleProfileCallbacksAreIgnored() {
        withDefaults { defaults in
            let meta = NuvioMeta(id: "tt123", name: "Title", type: "movie")
            start(meta, context(meta, origin: netflix), defaults: defaults)
            start(meta, context(meta, profile: "a", origin: hulu), activeProfile: "b", defaults: defaults)
            XCTAssertEqual(CollectionPlaybackOriginStore.entries(profileID: "a", defaults: defaults).first?.origin, netflix)
            XCTAssertTrue(CollectionPlaybackOriginStore.entries(profileID: "b", defaults: defaults).isEmpty)
        }
    }

    func testAliasesMatchAcrossCatalogsButMovieAndSeriesRemainDistinct() {
        withDefaults { defaults in
            let local = NuvioMeta(id: "tt123", name: "Title", tmdbId: 12, type: "movie")
            start(local, context(local, origin: netflix), defaults: defaults)
            let alias = NuvioMeta(id: "tmdb:12", name: "Renamed", type: "movie")
            let series = NuvioMeta(id: "tmdb:12", name: "Series", type: "series")
            let badge = CollectionOriginPresentation(reference: netflix, title: "Netflix", imageURLs: [], emoji: nil)
            let found = CollectionPlaybackOriginStore.presentations(
                for: [alias], profileID: "a", services: [netflix: badge], defaults: defaults
            )
            XCTAssertEqual(found[alias.id]?.reference, netflix)
            // A movie and series can legitimately share a TMDB numeric ID.
            XCTAssertTrue(CollectionPlaybackOriginStore.presentations(
                for: [series], profileID: "a", services: [netflix: badge], defaults: defaults
            ).isEmpty)
        }
    }

    func testUnrelatedRecommendationDoesNotInheritTheRootCollection() {
        withDefaults { defaults in
            let root = NuvioMeta(id: "tt123", name: "Root", type: "movie")
            let related = NuvioMeta(id: "tt456", name: "Related", type: "movie")
            start(related, context(related, origin: hulu), defaults: defaults)
            start(related, context(root, origin: netflix), defaults: defaults)
            XCTAssertTrue(CollectionPlaybackOriginStore.entries(profileID: "a", defaults: defaults).isEmpty)
        }
    }

    func testRemovedCollectionGetsNoBadgeAndAnnotationsSurviveStoreReads() {
        withDefaults { defaults in
            let meta = NuvioMeta(id: "tt123", name: "Title", type: "movie")
            start(meta, context(meta, origin: netflix), defaults: defaults)
            XCTAssertEqual(CollectionPlaybackOriginStore.entries(profileID: "a", defaults: defaults).count, 1)
            XCTAssertTrue(CollectionPlaybackOriginStore.presentations(
                for: [meta], profileID: "a", services: [:], defaults: defaults
            ).isEmpty)
            CollectionPlaybackOriginStore.eraseProfile("a", defaults: defaults)
            XCTAssertTrue(CollectionPlaybackOriginStore.entries(profileID: "a", defaults: defaults).isEmpty)
        }
    }

    func testExternalSessionKeepsCapturedContextAndLegacySessionsStillDecode() throws {
        try withDefaults { defaults in
            let meta = NuvioMeta(id: "tt123", name: "Title", type: "movie")
            let session = ExternalPlaybackSession(
                id: "session", meta: meta, sourceURL: "https://example.com/video",
                season: nil, episode: nil, duration: 100, profileID: "a",
                collectionContext: context(meta, origin: netflix)
            )
            ExternalPlaybackSessionStore.save(session, defaults: defaults)
            XCTAssertEqual(ExternalPlaybackSessionStore.load(defaults: defaults)?.collectionContext, session.collectionContext)
            let data = try JSONEncoder().encode(session)
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            legacy.removeValue(forKey: "collectionContext")
            let decoded = try JSONDecoder().decode(
                ExternalPlaybackSession.self, from: JSONSerialization.data(withJSONObject: legacy)
            )
            XCTAssertNil(decoded.collectionContext)
        }
    }
}
