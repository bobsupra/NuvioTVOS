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

    // MARK: - Collection GIF Hardware Acceleration & Timing Tests

    func testAnimatedGIFCacheGCDAndFrameExpansion() {
        XCTAssertEqual(AnimatedGIFCache.greatestCommonDivisor(10, 20), 10)
        XCTAssertEqual(AnimatedGIFCache.greatestCommonDivisor(15, 25), 5)
        XCTAssertEqual(AnimatedGIFCache.greatestCommonDivisor(7, 13), 1)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10))
        let img1 = renderer.image { ctx in ctx.cgContext.setFillColor(UIColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }
        let img2 = renderer.image { ctx in ctx.cgContext.setFillColor(UIColor.blue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10)) }

        let frames = [
            (image: img1, delayCentiseconds: 10),
            (image: img2, delayCentiseconds: 20)
        ]

        let expanded = AnimatedGIFCache.expandFrames(frames: frames)
        XCTAssertNotNil(expanded)
        XCTAssertEqual(expanded?.images.count, 3) // 1 img1 + 2 img2
        XCTAssertEqual(expanded?.duration ?? 0, 0.30, accuracy: 0.001)

        let metrics = AnimatedGIFCache.telemetryMetrics()
        XCTAssertGreaterThanOrEqual(metrics.maxCost, 0)
    }

    func testDecodedAnimatedImageKeyframeAnimationAttributes() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let img1 = renderer.image { ctx in ctx.cgContext.setFillColor(UIColor.red.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        let img2 = renderer.image { ctx in ctx.cgContext.setFillColor(UIColor.green.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        let img3 = renderer.image { ctx in ctx.cgContext.setFillColor(UIColor.blue.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20)) }

        guard let cg1 = img1.cgImage, let cg2 = img2.cgImage, let cg3 = img3.cgImage else {
            XCTFail("Failed to obtain CGImage from test images")
            return
        }

        let keyTimes: [NSNumber] = [0.0, 0.25, 0.75]
        let decoded = DecodedAnimatedImage(
            animatedImage: img1,
            firstFrame: img1,
            frameCount: 3,
            duration: 0.40,
            totalByteCost: 4096,
            cgFrames: [cg1, cg2, cg3],
            keyTimes: keyTimes
        )

        XCTAssertTrue(decoded.isAnimated)
        XCTAssertEqual(decoded.frameCount, 3)
        XCTAssertEqual(decoded.duration, 0.40, accuracy: 0.001)
        XCTAssertEqual(decoded.cgFrames.count, 3)
        XCTAssertEqual(decoded.keyTimes, keyTimes)

        let animation = decoded.makeKeyframeAnimation()
        XCTAssertEqual(animation.keyPath, "contents")
        XCTAssertEqual(animation.calculationMode, .discrete)
        XCTAssertEqual(animation.repeatCount, .infinity)
        XCTAssertFalse(animation.isRemovedOnCompletion)
        XCTAssertEqual(animation.duration, 0.40, accuracy: 0.001)
        XCTAssertEqual((animation.values as? [CGImage])?.count, 3)
        XCTAssertEqual(animation.keyTimes, keyTimes)
    }

    func testCollectionFolderEffectiveCoverImageSelection() throws {
        // When focusGifEnabled is true, coverImageUrl is authoritative for the static tile
        let folderWithGifFocus: [String: Any] = [
            "id": "netflix",
            "title": "Netflix",
            "coverImageUrl": "https://example.com/netflix_static.png",
            "focusGifUrl": "https://example.com/netflix_animated.gif",
            "focusGifEnabled": true,
            "sources": []
        ]
        let data1 = try JSONSerialization.data(withJSONObject: folderWithGifFocus)
        let decoded1 = try JSONDecoder().decode(NuvioCollectionFolder.self, from: data1)
        let item1 = TVCollectionFolderItem(collectionId: "c", folder: decoded1, sources: [])
        XCTAssertEqual(item1.activeFocusGifURLString, "https://example.com/netflix_animated.gif")

        // When focusGifEnabled is false, focusGifUrl acts as regular poster (priority over cover image)
        let folderWithGifAsPoster: [String: Any] = [
            "id": "anime",
            "title": "Anime",
            "coverImageUrl": "https://example.com/anime_static.png",
            "focusGifUrl": "https://example.com/anime_poster.gif",
            "focusGifEnabled": false,
            "sources": []
        ]
        let data2 = try JSONSerialization.data(withJSONObject: folderWithGifAsPoster)
        let decoded2 = try JSONDecoder().decode(NuvioCollectionFolder.self, from: data2)
        let item2 = TVCollectionFolderItem(collectionId: "c", folder: decoded2, sources: [])
        XCTAssertNil(item2.activeFocusGifURLString)
    }
}
