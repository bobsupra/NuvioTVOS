//
//  StreamsDiscoveryTests.swift
//  NuvioTVTests
//
//  Regression coverage for stream discovery behavior aligned with Android
//  StreamsRepository (stable instance ids, metadata preservation, request keys).
//

import XCTest
@testable import NuvioTV

private enum TestStreamError: Error { case failed }

final class StreamsDiscoveryTests: XCTestCase {

    func testStreamRequestRetryPolicyRetriesTransientErrorsOnly() {
        XCTAssertFalse(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(URLError(.timedOut)))
        XCTAssertTrue(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(URLError(.networkConnectionLost)))
        XCTAssertTrue(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(URLError(.cannotConnectToHost)))
        XCTAssertFalse(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(URLError(.cancelled)))
        XCTAssertFalse(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(URLError(.badServerResponse)))
        XCTAssertFalse(StreamsRepository.StreamRequestRetryPolicy.shouldRetry(TestStreamError.failed))
    }

    func testMergingExternalSubtitlesPreservesTorrentMetadata() {
        let torrent = NuvioStream(
            url: nil,
            name: "1080p WEB-DL",
            description: "Torrentio\n12 GB",
            addonName: "Torrentio",
            subtitles: [
                NuvioSubtitle(url: "https://example.com/a.srt", language: "en", label: "English")
            ],
            addonLogoURL: "https://example.com/logo.png",
            infoHash: "abcdef0123456789abcdef0123456789abcdef01",
            fileIdx: 2,
            sources: ["tracker:udp://tracker.example/announce"],
            filename: "Show.S01E01.1080p.mkv",
            httpHeaders: [
                "Referer": "https://portal.example/",
                "User-Agent": "ExamplePlayer/1.0"
            ]
        )

        let external = [
            NuvioSubtitle(url: "https://example.com/b.srt", language: "es", label: "Spanish", source: "OpenSubtitles")
        ]
        let merged = torrent.mergingExternalSubtitles(external)

        XCTAssertNil(merged.url)
        XCTAssertEqual(merged.infoHash, torrent.infoHash)
        XCTAssertEqual(merged.fileIdx, 2)
        XCTAssertEqual(merged.sources, torrent.sources)
        XCTAssertEqual(merged.filename, torrent.filename)
        XCTAssertEqual(merged.addonLogoURL, torrent.addonLogoURL)
        XCTAssertEqual(merged.addonName, "Torrentio")
        XCTAssertEqual(merged.httpHeaders, torrent.httpHeaders)
        XCTAssertEqual(merged.subtitles.count, 2)
        XCTAssertTrue(merged.subtitles.contains { $0.url == "https://example.com/b.srt" })
    }

    func testMergingExternalSubtitlesDedupesByURL() {
        let stream = NuvioStream(
            url: "https://cdn.example/video.mp4",
            name: "Stream",
            description: nil,
            addonName: "AIO",
            subtitles: [
                NuvioSubtitle(url: "https://example.com/same.srt", language: "en", label: "EN")
            ]
        )
        let external = [
            NuvioSubtitle(url: "https://example.com/same.srt", language: "en", label: "EN2"),
            NuvioSubtitle(url: "https://example.com/new.srt", language: "fr", label: "FR")
        ]
        let merged = stream.mergingExternalSubtitles(external)
        XCTAssertEqual(merged.subtitles.count, 2)
        XCTAssertEqual(merged.url, stream.url)
    }

    func testRequestKeyIncludesTypeIdSeasonEpisode() {
        let key = StreamsRepository.requestKey(type: "series", videoId: "tt1:1:2", season: 1, episode: 2)
        XCTAssertEqual(key, "series::tt1:1:2::1::2")

        let movieKey = StreamsRepository.requestKey(type: "movie", videoId: "tt99")
        XCTAssertEqual(movieKey, "movie::tt99::::")
    }

    func testConfiguredSubtitleManifestURLsIncludeOnlyEnabledInstalledAddons() throws {
        let suiteName = "NuvioTVTests.SubtitleAddonPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let openSubtitlesURL = "https://opensubtitles-v3.strem.io/manifest.json"

        XCTAssertTrue(CinemetaCatalogRepository.configuredStreamAddonManifestURLs(in: defaults).isEmpty)

        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences(
            [StreamAddonPreference(url: openSubtitlesURL, enabled: false)], in: defaults)
        XCTAssertTrue(CinemetaCatalogRepository.configuredStreamAddonManifestURLs(in: defaults).isEmpty)

        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences(
            [StreamAddonPreference(url: openSubtitlesURL, enabled: true)], in: defaults)
        XCTAssertEqual(
            CinemetaCatalogRepository.configuredStreamAddonManifestURLs(in: defaults),
            [try XCTUnwrap(URL(string: openSubtitlesURL))]
        )

        // Removing the installed preference removes it from the next request snapshot.
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences([], in: defaults)
        XCTAssertTrue(CinemetaCatalogRepository.configuredStreamAddonManifestURLs(in: defaults).isEmpty)
    }

    func testConfiguredSubtitleSearchDoesNotAddAnUninstalledProvider() async {
        let repository = CinemetaCatalogRepository()
        let addons = await repository.configuredSubtitleAddons(
            id: "tt1234567", type: "movie", manifestURLs: [])
        XCTAssertTrue(addons.isEmpty)
    }

    func testExternalSubtitleProvidersRequireConfiguredCompatibleManifest() throws {
        let providerURL = try XCTUnwrap(URL(string: "https://opensubtitles-v3.strem.io/manifest.json"))
        let unconfiguredURL = try XCTUnwrap(URL(string: "https://other.example/manifest.json"))
        let compatible = try JSONDecoder().decode(StreamAddonManifest.self, from: Data(
            #"{"id":"com.example.subtitles","name":"Example Subs","types":["movie"],"idPrefixes":["tt"],"resources":[{"name":"subtitles","types":["movie"]}]}"#.utf8
        ))
        let streamOnly = try JSONDecoder().decode(StreamAddonManifest.self, from: Data(
            #"{"id":"com.example.streams","name":"Streams Only","types":["movie"],"resources":["stream"]}"#.utf8
        ))
        let manifests = [providerURL: compatible, unconfiguredURL: streamOnly]

        let absent = StreamsRepository.compatibleExternalSubtitleProviders(
            manifestURLs: [], manifests: manifests, type: "movie", id: "tt1234567")
        XCTAssertTrue(absent.isEmpty)

        let disabledOrDeleted = StreamsRepository.compatibleExternalSubtitleProviders(
            manifestURLs: [unconfiguredURL], manifests: manifests, type: "movie", id: "tt1234567")
        XCTAssertTrue(disabledOrDeleted.isEmpty)

        let enabled = StreamsRepository.compatibleExternalSubtitleProviders(
            manifestURLs: [providerURL, unconfiguredURL], manifests: manifests,
            type: "movie", id: "tt1234567")
        XCTAssertEqual(enabled.map(\.manifestURL), [providerURL])
        XCTAssertEqual(enabled.map(\.name), ["Example Subs"])
    }

    func testSameTitleDiscoveryDoesNotReuseResultsAfterAddonConfigurationChanges() {
        let key = StreamsRepository.requestKey(type: "movie", videoId: "tt1234567")
        let providerURL = URL(string: "https://opensubtitles-v3.strem.io/manifest.json")!

        XCTAssertTrue(StreamsRepository.requestConfigurationMatches(
            activeRequestKey: key, requestKey: key,
            activeAddonManifestURLs: [providerURL], configuredAddonManifestURLs: [providerURL]))
        XCTAssertFalse(StreamsRepository.requestConfigurationMatches(
            activeRequestKey: key, requestKey: key,
            activeAddonManifestURLs: [providerURL], configuredAddonManifestURLs: []))
        XCTAssertFalse(StreamsRepository.requestConfigurationMatches(
            activeRequestKey: key, requestKey: key,
            activeAddonManifestURLs: [], configuredAddonManifestURLs: [providerURL]))
    }

    func testSeasonEpisodeParsedFromVideoId() {
        let se = StreamsRepository.seasonEpisode(fromVideoId: "tt0944947:2:5")
        XCTAssertEqual(se.season, 2)
        XCTAssertEqual(se.episode, 5)

        let movie = StreamsRepository.seasonEpisode(fromVideoId: "tt0111161")
        XCTAssertNil(movie.season)
        XCTAssertNil(movie.episode)
    }

    func testStableAddonIdIncludesManifestURLLikeAndroid() {
        let urlA = URL(string: "https://torrentio.strem.fun/manifest.json")!
        let urlB = URL(string: "https://torrentio.strem.fun/qualityfilter=480p/manifest.json")!
        let idA = StreamsRepository.stableAddonId(manifestId: "com.stremio.torrentio.addon", manifestURL: urlA)
        let idB = StreamsRepository.stableAddonId(manifestId: "com.stremio.torrentio.addon", manifestURL: urlB)

        XCTAssertEqual(idA, "addon:com.stremio.torrentio.addon:https://torrentio.strem.fun/manifest.json")
        XCTAssertEqual(idB, "addon:com.stremio.torrentio.addon:https://torrentio.strem.fun/qualityfilter=480p/manifest.json")
        XCTAssertNotEqual(idA, idB, "Same manifest.id with different URLs must not collide")
    }

    func testAddonDiagnosticsOmitCredentialsFromURLAndErrorText() {
        let url = URL(string: "https://user:password@example.com:8443/%7B%22auth_token%22%3A%22path-secret%22%7D/manifest.json?token=query-secret#fragment-secret")!
        let error = NSError(
            domain: NSURLErrorDomain, code: URLError.cancelled.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Request failed: \(url.absoluteString)"]
        )
        let diagnostic = AddonTransportUrls.diagnosticDescription(for: url, error: error)
        XCTAssertTrue(diagnostic.contains("https://example.com:8443"))
        XCTAssertTrue(diagnostic.contains("code=-999"))
        for credential in ["user:", "password", "auth_token", "path-secret", "query-secret", "fragment-secret", "manifest.json"] {
            XCTAssertFalse(diagnostic.contains(credential), "Diagnostics exposed \(credential)")
        }
    }

    func testAddonStreamGroupUsesStableIdNotDisplayName() {
        let group = AddonStreamGroup(
            addonId: "addon:com.stremio.torrentio.addon:https://example.com/manifest.json",
            displayName: "Torrentio",
            streams: [],
            isLoading: true
        )
        XCTAssertEqual(group.id, group.addonId)
        XCTAssertNotEqual(group.id, group.displayName)
    }

    func testManifestCacheStoresSuccessOnly() async {
        let cache = StreamManifestCache()
        let url = URL(string: "https://example.com/manifest.json")!
        let missing = await cache.success(for: url)
        XCTAssertNil(missing)

        let manifest = StreamAddonManifest(
            id: "com.example.addon",
            name: "Example",
            logo: nil,
            types: ["movie"],
            idPrefixes: ["tt"],
            resources: nil
        )
        await cache.storeSuccess(manifest, for: url)
        let cached = await cache.success(for: url)
        XCTAssertEqual(cached?.id, "com.example.addon")
        XCTAssertEqual(cached?.name, "Example")
    }

    func testTMDBMetadataUsesImdbIDForCanonicalStreamIdentity() throws {
        let data = Data(
            #"{"id":"tmdb:687163","name":"Example","type":"movie","imdb_id":" tt12042730 "}"#.utf8
        )
        let decoded = try JSONDecoder().decode(CinemetaMeta.self, from: data)
        let meta = decoded.toMeta(fallbackType: "movie")

        XCTAssertEqual(meta.imdbId, "tt12042730")
        XCTAssertEqual(meta.streamId, "tt12042730")
    }

    func testFullMetadataRequiresCanonicalImdbIdentityForMovies() {
        let tmdbOnly = makeMeta(id: "tmdb:687163", imdbId: nil)
        let canonical = makeMeta(id: "tmdb:687163", imdbId: "tt12042730")
        let canonicalId = makeMeta(id: "tt12042730", imdbId: nil)

        XCTAssertFalse(CinemetaCatalogRepository.isFullMetadata(tmdbOnly))
        XCTAssertTrue(CinemetaCatalogRepository.isFullMetadata(canonical))
        XCTAssertTrue(CinemetaCatalogRepository.isFullMetadata(canonicalId))
    }

    func testSeriesWithEmptyVideosIsNotFullMetadata() {
        let meta = makeMeta(id: "tt12042730", imdbId: "tt12042730", type: "series", videos: [])

        XCTAssertFalse(CinemetaCatalogRepository.isFullMetadata(meta))
    }

    func testVideoInferredMovieWithCanonicalIdentityIsFullMetadata() {
        let meta = NuvioMeta(
            id: "tt12042730",
            name: "Example",
            description: nil,
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: "tt12042730",
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
            status: nil,
            videos: [NuvioVideo(id: "tt12042730:1:1", title: "Episode", season: 1, episode: 1, thumbnail: nil, overview: nil, released: nil, rating: nil)],
            trailerYtIds: nil,
            externalRatings: nil
        )

        XCTAssertTrue(meta.isSeries)
        XCTAssertTrue(CinemetaCatalogRepository.isFullMetadata(meta))
    }

    func testUnicodeDigitIMDbIDIsRejected() {
        XCTAssertNil(NuvioMeta.canonicalImdbID(from: "tt१२३४५६७"))
    }

    func testCanonicalIMDbMetadataUsesSeriesFirstFallbackOrdering() {
        XCTAssertEqual(
            CinemetaCatalogRepository.cinemetaMetadataTypesToTry(
                primaryType: "series",
                canonicalImdbID: NuvioMeta.canonicalImdbID(from: " rpdb:TT12042730 ")
            ),
            ["series", "movie"]
        )
        XCTAssertEqual(
            CinemetaCatalogRepository.cinemetaMetadataTypesToTry(
                primaryType: "series",
                canonicalImdbID: "tmdb:123"
            ),
            ["series"]
        )
    }

    func testRPDBWrappedMetadataUsesCanonicalImdbIdentity() throws {
        let data = Data(
            #"{"id":" rpdb:TT1234567 ","name":"Example","type":"movie"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(CinemetaMeta.self, from: data)
        let meta = decoded.toMeta(fallbackType: "movie")

        XCTAssertEqual(meta.imdbId, "tt1234567")
        XCTAssertEqual(meta.streamId, "tt1234567")
    }

    func testProxyRequestHeadersAreRetainedForPlayback() throws {
        let data = Data(
            #"""
            {
              "url": "https://media.example/stream.m3u8",
              "name": "KhmerAve",
              "behaviorHints": {
                "proxyHeaders": {
                  "request": {
                    "Referer": "https://ok.ru/",
                    "User-Agent": "Mozilla/5.0"
                  },
                  "response": { "Set-Cookie": "must-not-be-forwarded" }
                }
              }
            }
            """#.utf8
        )

        let raw = try JSONDecoder().decode(StreamAddonStreamDTO.self, from: data)
        let stream = try XCTUnwrap(raw.toNuvioStream(addonName: "KhmerDub"))

        XCTAssertEqual(
            stream.httpHeaders,
            ["Referer": "https://ok.ru/", "User-Agent": "Mozilla/5.0"]
        )
    }

    // MARK: - Stream picker list derivation / focus isolation

    func testDisplayedStreamsUpdateWhenFilterOrSortChanges() {
        let torrentio = makeStream(url: "https://cdn.example/a.mkv", name: "4K HDR", addon: "Torrentio")
        let aio = makeStream(url: "https://cdn.example/b.mkv", name: "1080p", addon: "AIOStreams")
        let groups = [
            AddonStreamGroup(addonId: "addon:torrentio", displayName: "Torrentio", streams: [torrentio], isLoading: false),
            AddonStreamGroup(addonId: "addon:aio", displayName: "AIOStreams", streams: [aio], isLoading: false)
        ]
        let flat = [torrentio, aio]

        let allDefault = StreamPickerListBuilder.displayedStreams(
            streams: flat, groups: groups, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        XCTAssertEqual(allDefault.map(\.id), [torrentio.id, aio.id])

        let onlyTorrentio = StreamPickerListBuilder.displayedStreams(
            streams: flat, groups: groups, selectedAddonId: "addon:torrentio", sortOption: .default, includeDebrid: false
        )
        XCTAssertEqual(onlyTorrentio.map(\.id), [torrentio.id])

        let byName = StreamPickerListBuilder.displayedStreams(
            streams: flat, groups: groups, selectedAddonId: nil, sortOption: .name, includeDebrid: false
        )
        XCTAssertEqual(byName.map(\.id), [aio.id, torrentio.id], "Name sort is alphabetical by stream name")

        let byQuality = StreamPickerListBuilder.displayedStreams(
            streams: flat, groups: groups, selectedAddonId: nil, sortOption: .quality, includeDebrid: false
        )
        XCTAssertEqual(byQuality.first?.id, torrentio.id, "4K should rank above 1080p")
    }

    func testFocusChangeDoesNotChangeDerivedStreamList() {
        let streams = [
            makeStream(url: "https://cdn.example/1.mkv", name: "1080p", addon: "A"),
            makeStream(url: "https://cdn.example/2.mkv", name: "720p", addon: "B")
        ]
        let groups = [
            AddonStreamGroup(addonId: "a", displayName: "A", streams: [streams[0]], isLoading: false),
            AddonStreamGroup(addonId: "b", displayName: "B", streams: [streams[1]], isLoading: false)
        ]

        let cacheKeyA = StreamPickerListBuilder.cacheKey(
            revision: 7, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        let listA = StreamPickerListBuilder.displayedStreams(
            streams: streams, groups: groups, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        // Simulate a focus-only re-render: the repository revision and list
        // options are unchanged, so the constant-size cache key stays equal.
        let cacheKeyB = StreamPickerListBuilder.cacheKey(
            revision: 7, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        let listB = StreamPickerListBuilder.displayedStreams(
            streams: streams, groups: groups, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )

        XCTAssertEqual(cacheKeyA, cacheKeyB)
        XCTAssertEqual(listA.map(\.id), listB.map(\.id))
        XCTAssertEqual(listA.map(\.id), streams.map(\.id))
    }

    func testRevisionInvalidatesCacheWhenSubtitlesChangeWithoutIdentityChange() {
        let original = makeStream(
            url: "https://cdn.example/same.mkv",
            name: "1080p",
            addon: "AIOStreams"
        )
        let decorated = original.mergingExternalSubtitles([
            NuvioSubtitle(
                url: "https://subs.example/external.srt",
                language: "en",
                label: "English",
                source: "OpenSubtitles"
            )
        ])

        XCTAssertEqual(original.id, decorated.id)

        let before = StreamPickerListBuilder.cacheKey(
            revision: 20, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        let after = StreamPickerListBuilder.cacheKey(
            revision: 21, selectedAddonId: nil, sortOption: .default, includeDebrid: false
        )
        XCTAssertNotEqual(before, after, "Every repository publication must invalidate the picker cache")

        let refreshed = StreamPickerListBuilder.displayedStreams(
            streams: [decorated],
            groups: [
                AddonStreamGroup(
                    addonId: "aio",
                    displayName: "AIOStreams",
                    streams: [decorated],
                    isLoading: false
                )
            ],
            selectedAddonId: nil,
            sortOption: .default,
            includeDebrid: false
        )
        XCTAssertEqual(refreshed.first?.subtitles.map(\.url), ["https://subs.example/external.srt"])
    }

    func testAV1DetectionIgnoresSubtitleData() {
        let av1InName = makeStream(
            url: "https://cdn.example/av1.mkv",
            name: "Title AV1 1080p",
            addon: "Torrentio",
            subtitles: []
        )
        let av1OnlyInSubtitle = makeStream(
            url: "https://cdn.example/h264.mkv",
            name: "Title 1080p x264",
            addon: "Torrentio",
            subtitles: [
                NuvioSubtitle(
                    url: "https://example.com/track-av1-metadata.srt",
                    language: "av1",
                    label: "AV1 Forced"
                )
            ]
        )
        let av01InFilename = NuvioStream(
            url: "https://cdn.example/file.mkv",
            name: "Title",
            description: nil,
            addonName: "Torrentio",
            filename: "Show.S01E01.AV01.mkv"
        )

        XCTAssertTrue(SmartPlaybackSelector.isAV1LabeledStream(av1InName))
        XCTAssertFalse(
            SmartPlaybackSelector.isAV1LabeledStream(av1OnlyInSubtitle),
            "Subtitle language/label/URL must not trigger AV1 filtering"
        )
        XCTAssertTrue(SmartPlaybackSelector.isAV1LabeledStream(av01InFilename))
    }

    func testStableStreamOrderingAndIdentities() {
        let a = makeStream(url: "https://cdn.example/a.mkv", name: "A", addon: "Torrentio")
        let b = makeStream(url: "https://cdn.example/b.mkv", name: "B", addon: "AIO")
        let debridOnly = NuvioStream(
            url: nil,
            name: "C debrid",
            description: "12 GB",
            addonName: "Torrentio",
            infoHash: "abcdef0123456789abcdef0123456789abcdef01",
            fileIdx: 0
        )
        let shell = NuvioStream(url: nil, name: "Shell", description: "x", addonName: "X")

        // URL / infoHash identities are stable across repeated access.
        XCTAssertEqual(a.id, a.id)
        XCTAssertEqual(a.id, "https://cdn.example/a.mkv")
        XCTAssertEqual(debridOnly.id, "abcdef0123456789abcdef0123456789abcdef01:0")
        XCTAssertEqual(shell.id, shell.id)
        XCTAssertFalse(shell.id.contains("-"), "Fallback id must not be a fresh UUID")

        let groups = [
            AddonStreamGroup(addonId: "t", displayName: "Torrentio", streams: [a, debridOnly], isLoading: false),
            AddonStreamGroup(addonId: "aio", displayName: "AIO", streams: [b], isLoading: false)
        ]
        // "All" preserves add-on group order (Android-style), not alphabetical addon names.
        let all = StreamPickerListBuilder.displayedStreams(
            streams: [a, debridOnly, b],
            groups: groups,
            selectedAddonId: nil,
            sortOption: .default,
            includeDebrid: true
        )
        XCTAssertEqual(all.map(\.id), [a.id, debridOnly.id, b.id])

        // Without debrid, torrent-only streams drop out; order of remaining stays.
        let noDebrid = StreamPickerListBuilder.displayedStreams(
            streams: [a, debridOnly, b],
            groups: groups,
            selectedAddonId: nil,
            sortOption: .default,
            includeDebrid: false
        )
        XCTAssertEqual(noDebrid.map(\.id), [a.id, b.id])
    }

    // MARK: - Helpers

    private func makeStream(
        url: String,
        name: String,
        addon: String,
        subtitles: [NuvioSubtitle] = []
    ) -> NuvioStream {
        NuvioStream(
            url: url,
            name: name,
            description: nil,
            addonName: addon,
            subtitles: subtitles
        )
    }

    private func makeMeta(
        id: String,
        imdbId: String?,
        type: String = "movie",
        videos: [NuvioVideo]? = nil
    ) -> NuvioMeta {
        return NuvioMeta(
            id: id,
            name: "Example",
            description: "Description",
            posterUrl: nil,
            backgroundUrl: nil,
            logoUrl: nil,
            imdbId: imdbId,
            tmdbId: 687163,
            type: type,
            year: 2024,
            genres: nil,
            rating: nil,
            releaseInfo: nil,
            runtime: nil,
            cast: nil,
            director: ["Director"],
            writer: nil,
            certification: nil,
            country: nil,
            released: nil,
            status: nil,
            videos: videos,
            trailerYtIds: nil,
            externalRatings: nil
        )
    }

    // MARK: - Addon Transport URLs & Type Equivalence Tests

    func testAddonTransportUrlsPreservesQueryAndEncodesIds() {
        let manifestWithQuery = URL(string: "https://penguplay.com/stremio/manifest.json?token=secret123&profile=main")!
        let streamURL = AddonTransportUrls.buildResourceURL(
            manifestURL: manifestWithQuery,
            resource: "stream",
            type: "series",
            id: "tt1234567:1:5"
        )
        XCTAssertEqual(
            streamURL?.absoluteString,
            "https://penguplay.com/stremio/stream/series/tt1234567%3A1%3A5.json?token=secret123&profile=main"
        )

        let simpleManifest = URL(string: "https://v3-cinemeta.strem.io/manifest.json")!
        let metaURL = AddonTransportUrls.buildResourceURL(
            manifestURL: simpleManifest,
            resource: "meta",
            type: "movie",
            id: "tt9876543"
        )
        XCTAssertEqual(
            metaURL?.absoluteString,
            "https://v3-cinemeta.strem.io/meta/movie/tt9876543.json"
        )

        let pathConfiguredManifest = URL(string: "https://comet.example.com/eyJmb28iOiJiYXIifQ==/manifest.json")!
        let cometStreamURL = AddonTransportUrls.buildResourceURL(
            manifestURL: pathConfiguredManifest,
            resource: "stream",
            type: "series",
            id: "tt1234567:2:3"
        )
        XCTAssertEqual(
            cometStreamURL?.absoluteString,
            "https://comet.example.com/eyJmb28iOiJiYXIifQ==/stream/series/tt1234567%3A2%3A3.json"
        )
    }

    func testSupportsResourceNormalizesTvAndSeriesTypes() throws {
        let manifestJson = """
        {
            "id": "org.pengu.stream",
            "name": "PenguPlay",
            "resources": [
                {
                    "name": "stream",
                    "types": ["tv", "movie"],
                    "idPrefixes": ["tt"]
                }
            ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(StreamAddonManifest.self, from: manifestJson)

        // "series" should match "tv"
        XCTAssertTrue(manifest.supportsResource("stream", type: "series", id: "tt1234567:1:1"))
        // "tv" matches "tv"
        XCTAssertTrue(manifest.supportsResource("stream", type: "tv", id: "tt1234567:1:1"))
        // "movie" matches "movie"
        XCTAssertTrue(manifest.supportsResource("stream", type: "movie", id: "tt1234567"))
        // "movies" matches "movie"
        XCTAssertTrue(manifest.supportsResource("stream", type: "movies", id: "tt1234567"))
        // Non-matching id prefix should fail
        XCTAssertFalse(manifest.supportsResource("stream", type: "series", id: "kitsu:1234"))
    }

    // MARK: - Stream Picker Pagination & Lazy Slicing

    private func makePaginationTestStreams(count: Int, addon: String = "Torrentio") -> [NuvioStream] {
        (1...count).map { i in
            NuvioStream(
                url: "https://example.com/stream\(i).mp4",
                name: "Stream \(i) - 1080p",
                description: "\(addon)\n\(i) GB",
                addonName: addon
            )
        }
    }

    func testPaginatedSliceWithEmptyStreamsReturnsEmpty() {
        let empty: [NuvioStream] = []
        let slice = StreamPickerListBuilder.paginatedSlice(streams: empty, limit: 20)
        XCTAssertTrue(slice.isEmpty)
        XCTAssertFalse(StreamPickerListBuilder.hasMorePages(totalCount: 0, currentLimit: 20))
    }

    func testPaginatedSliceWithZeroOrNegativeLimitReturnsEmpty() {
        let streams = makePaginationTestStreams(count: 10)
        XCTAssertTrue(StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 0).isEmpty)
        XCTAssertTrue(StreamPickerListBuilder.paginatedSlice(streams: streams, limit: -5).isEmpty)
    }

    func testPaginatedSliceWithinFirstPage() {
        let streams = makePaginationTestStreams(count: 50)
        let page1 = StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 20)
        XCTAssertEqual(page1.count, 20)
        XCTAssertEqual(page1.first?.name, "Stream 1 - 1080p")
        XCTAssertEqual(page1.last?.name, "Stream 20 - 1080p")
        XCTAssertTrue(StreamPickerListBuilder.hasMorePages(totalCount: streams.count, currentLimit: 20))
    }

    func testPaginatedSliceExpandingLimitLoadsNextPages() {
        let streams = makePaginationTestStreams(count: 50)

        let page1 = StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 20)
        XCTAssertEqual(page1.count, 20)

        let page2 = StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 40)
        XCTAssertEqual(page2.count, 40)
        XCTAssertEqual(page2.first?.name, "Stream 1 - 1080p")
        XCTAssertEqual(page2[19].name, "Stream 20 - 1080p")
        XCTAssertEqual(page2[20].name, "Stream 21 - 1080p")
        XCTAssertEqual(page2.last?.name, "Stream 40 - 1080p")
        XCTAssertTrue(StreamPickerListBuilder.hasMorePages(totalCount: streams.count, currentLimit: 40))

        let page3 = StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 60)
        XCTAssertEqual(page3.count, 50)
        XCTAssertEqual(page3.last?.name, "Stream 50 - 1080p")
        XCTAssertFalse(StreamPickerListBuilder.hasMorePages(totalCount: streams.count, currentLimit: 60))
    }

    func testPaginatedSliceWithLimitExceedingTotalCount() {
        let streams = makePaginationTestStreams(count: 7)
        let slice = StreamPickerListBuilder.paginatedSlice(streams: streams, limit: 20)
        XCTAssertEqual(slice.count, 7)
        XCTAssertFalse(StreamPickerListBuilder.hasMorePages(totalCount: streams.count, currentLimit: 20))
    }

    func testPaginationWithDisplayedStreamsAndAddonFilter() {
        let addon1Streams = makePaginationTestStreams(count: 30, addon: "Torrentio")
        let addon2Streams = makePaginationTestStreams(count: 15, addon: "MediaFusion")
        let allStreams = addon1Streams + addon2Streams

        let group1 = AddonStreamGroup(
            addonId: "torrentio",
            displayName: "Torrentio",
            streams: addon1Streams,
            isLoading: false
        )
        let group2 = AddonStreamGroup(
            addonId: "mediafusion",
            displayName: "MediaFusion",
            streams: addon2Streams,
            isLoading: false
        )

        // All streams: 45 items total, 20 on first page
        let allDisplayed = StreamPickerListBuilder.displayedStreams(
            streams: allStreams,
            groups: [group1, group2],
            selectedAddonId: nil,
            sortOption: .default,
            includeDebrid: true
        )
        XCTAssertEqual(allDisplayed.count, 45)
        let allPage1 = StreamPickerListBuilder.paginatedSlice(streams: allDisplayed, limit: 20)
        XCTAssertEqual(allPage1.count, 20)
        XCTAssertTrue(StreamPickerListBuilder.hasMorePages(totalCount: allDisplayed.count, currentLimit: 20))

        // Filter by MediaFusion: 15 items total, 15 on first page (hasMore is false)
        let filteredDisplayed = StreamPickerListBuilder.displayedStreams(
            streams: allStreams,
            groups: [group1, group2],
            selectedAddonId: "mediafusion",
            sortOption: .default,
            includeDebrid: true
        )
        XCTAssertEqual(filteredDisplayed.count, 15)
        let filteredPage1 = StreamPickerListBuilder.paginatedSlice(streams: filteredDisplayed, limit: 20)
        XCTAssertEqual(filteredPage1.count, 15)
        XCTAssertFalse(StreamPickerListBuilder.hasMorePages(totalCount: filteredDisplayed.count, currentLimit: 20))
    }

    func testSmartPlaybackSelectorEvaluatesFullStreamPool() {
        // Construct 50 streams where only stream 48 has a 4K resolution
        let streams = (1...50).map { i in
            NuvioStream(
                url: "https://example.com/stream\(i).mp4",
                name: i == 48 ? "Movie 4K UHD Remux" : "Movie 720p WEB-DL",
                description: "Size \(i) GB",
                addonName: "Torrentio"
            )
        }

        // Auto-play selector must be able to select the 4K stream regardless of UI page limit
        let best = SmartPlaybackSelector.bestStream(
            from: streams,
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false,
            includeDebrid: true,
            cachedOnly: false
        )
        XCTAssertNotNil(best)
        XCTAssertEqual(best?.name, "Movie 4K UHD Remux")
    }

    func testUnavailableNoticesAreNarrowAndExcludeSmartCandidates() {
        let scheduled = NuvioStream(
            url: "https://example.com/scheduled-4k.mkv",
            name: "Movie 4K UHD",
            description: "Note: Starts in 19 min",
            addonName: "Addon"
        )
        let locked = NuvioStream(
            url: "https://example.com/locked-4k.mkv",
            name: "Movie 2160p",
            description: "🔒\u{FE0F} Locked",
            addonName: "Addon"
        )
        let available = makeStream(
            url: "https://example.com/movie-720p.mkv",
            name: "Movie 720p",
            addon: "Addon"
        )
        let lockedNote = NuvioStream(
            url: "https://example.com/locked-note.mkv",
            name: "Movie",
            description: "Note: Locked",
            addonName: "Addon"
        )
        let upgradeNotice = NuvioStream(
            url: "https://example.com/upgrade.mkv",
            name: "CDN (Premium)",
            description: "🔒 Upgrade to watch",
            addonName: "Premium"
        )
        let signInNotice = NuvioStream(
            url: "https://example.com/login.mkv",
            name: "Stream",
            description: "Sign in required",
            addonName: "Addon"
        )

        XCTAssertEqual(scheduled.unavailabilityReason, "Starts in 19 min.")
        XCTAssertEqual(locked.unavailabilityReason, "This source is locked.")
        XCTAssertEqual(lockedNote.unavailabilityReason, "This source is locked.")
        XCTAssertEqual(upgradeNotice.unavailabilityReason, "This source requires an upgrade to watch.")
        XCTAssertNotNil(signInNotice.unavailabilityReason)

        let lockedTitle = makeStream(url: "https://example.com/locked-title.mkv", name: "Locked", addon: "Addon")
        let lockedInTitle = makeStream(url: "https://example.com/locked-in.mkv", name: "Locked In", addon: "Addon")
        let futureProse = NuvioStream(
            url: "https://example.com/prose.mkv",
            name: "Movie",
            description: "The movie starts in 19 minutes after the recap.",
            addonName: "Addon",
            filename: "Note: Starts in 19 min"
        )
        let premiumNameOnly = makeStream(
            url: "https://example.com/premium.mkv",
            name: "CDN (Premium)",
            addon: "Premium"
        )
        XCTAssertNil(lockedTitle.unavailabilityReason)
        XCTAssertNil(lockedInTitle.unavailabilityReason)
        XCTAssertNil(futureProse.unavailabilityReason)
        XCTAssertNil(premiumNameOnly.unavailabilityReason)

        let best = SmartPlaybackSelector.bestStream(
            from: [scheduled, locked, available],
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false
        )
        XCTAssertEqual(best?.id, available.id, "Smart playback should skip notices and use the next available source")
        XCTAssertNil(SmartPlaybackSelector.bestStream(
            from: [scheduled, locked],
            qualityPreference: "Highest",
            subtitleLanguages: [],
            shouldMatchSubtitles: false
        ), "An all-unavailable pool has no smart candidate")
    }

    func testUnavailableCardsStayManualAndDoNotDisplaceLowQualityFallback() {
        let scheduled = NuvioStream(
            url: "https://example.com/scheduled.mkv",
            name: "Movie 4K",
            description: "Note: Starts in 19 min",
            addonName: "Addon"
        )
        let preview = NuvioStream(
            url: "https://example.com/preview-480p.mkv",
            name: "Movie 480p",
            description: nil,
            addonName: "Preview Addon"
        )

        let automatic = SmartPlaybackSelector.playableStreams(
            from: [scheduled, preview],
            preserveAddonStreams: true
        )
        XCTAssertEqual(automatic.map(\.id), [preview.id], "Top-result pools must exclude the notice and retain the real 480p fallback")

        for preserveAddonStreams in [false, true] {
            let manual = StreamPickerListBuilder.displayedStreams(
                streams: [scheduled, preview],
                groups: [],
                selectedAddonId: nil,
                sortOption: .default,
                includeDebrid: false,
                preserveAddonStreams: preserveAddonStreams
            )
            XCTAssertEqual(Set(manual.map(\.id)), Set([scheduled.id, preview.id]))
        }

        let upgradeShell = NuvioStream(
            url: nil,
            name: "CDN (Premium)",
            description: "🔒 Upgrade to watch",
            addonName: "Premium"
        )
        let manualShells = StreamPickerListBuilder.displayedStreams(
            streams: [upgradeShell],
            groups: [],
            selectedAddonId: nil,
            sortOption: .default,
            includeDebrid: false
        )
        XCTAssertEqual(manualShells.map(\.id), [upgradeShell.id], "URL-less notice shells remain selectable in the manual list")
        XCTAssertTrue(SmartPlaybackSelector.playableStreams(from: [upgradeShell]).isEmpty)
    }

    // MARK: - AIOStreams Heterogeneous Decoding Resilience (#105)

    func testAIOStreamsHeterogeneousResponseDecodesResiliently() throws {
        let json = """
        {
            "streams": [
                {
                    "name": "AIOStream 1",
                    "title": "Movie.2024.1080p.WEBRip",
                    "url": "https://aiostreams.example/playback/rd/stream1.mkv",
                    "fileIdx": "0",
                    "sources": ["tracker:udp://tracker.example:6969", null],
                    "behaviorHints": {
                        "cached": 1,
                        "videoSize": "2147483648",
                        "proxyHeaders": {
                            "request": {
                                "User-Agent": "Nuvio/1.0",
                                "Content-Length": 1024
                            }
                        },
                        "storyboard": {
                            "url": "https://aiostreams.example/storyboard.vtt"
                        }
                    }
                },
                {
                    "name": "AIOStream 2",
                    "title": "Movie.2024.2160p.HDR",
                    "url": "https://aiostreams.example/playback/rd/stream2.mkv",
                    "fileIdx": 2,
                    "behaviorHints": {
                        "isCached": "true",
                        "videoSize": 5368709120.0,
                        "storyboard": "https://aiostreams.example/storyboard2.vtt"
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(StreamAddonResponse.self, from: json)
        let streams = decoded.streams
        XCTAssertNotNil(streams)
        XCTAssertEqual(streams?.count, 2)

        let s1 = try XCTUnwrap(streams?.first)
        XCTAssertEqual(s1.fileIdx, 0)
        XCTAssertEqual(s1.sources, ["tracker:udp://tracker.example:6969"])
        XCTAssertEqual(s1.behaviorHints?.cached, true)
        XCTAssertEqual(s1.behaviorHints?.videoSize, 2147483648)
        XCTAssertEqual(s1.behaviorHints?.proxyHeaders?.request?["User-Agent"], "Nuvio/1.0")
        XCTAssertEqual(s1.behaviorHints?.proxyHeaders?.request?["Content-Length"], "1024")
        XCTAssertEqual(s1.behaviorHints?.storyboard, "https://aiostreams.example/storyboard.vtt")

        let s2 = try XCTUnwrap(streams?.last)
        XCTAssertEqual(s2.fileIdx, 2)
        XCTAssertEqual(s2.behaviorHints?.isCached, true)
        XCTAssertEqual(s2.behaviorHints?.videoSize, 5368709120)
        XCTAssertEqual(s2.behaviorHints?.storyboard, "https://aiostreams.example/storyboard2.vtt")

        let nuvio1 = s1.toNuvioStream(addonName: "AIOStreams")
        XCTAssertNotNil(nuvio1)
        XCTAssertEqual(nuvio1?.isCached, true)
        XCTAssertEqual(nuvio1?.fileIdx, 0)
        XCTAssertEqual(nuvio1?.trickplayURL?.absoluteString, "https://aiostreams.example/storyboard.vtt")
    }

    func testLossyStreamListDropsCorruptStreamWithoutFailingArray() throws {
        let json = """
        {
            "streams": [
                {
                    "name": "Valid Stream 1",
                    "url": "https://aiostreams.example/1.mkv"
                },
                "completely-invalid-non-object-stream",
                {
                    "name": "Valid Stream 2",
                    "url": "https://aiostreams.example/2.mkv"
                }
            ]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(StreamAddonResponse.self, from: json)
        let streams = decoded.streams
        XCTAssertNotNil(streams)
        XCTAssertEqual(streams?.count, 2)
        XCTAssertEqual(streams?.first?.name, "Valid Stream 1")
        XCTAssertEqual(streams?.last?.name, "Valid Stream 2")
    }

    func testAddonTransportUrlsSubtitleExtraFormatting() {
        let segment = AddonTransportUrls.buildSubtitleExtraPathSegment(
            videoHash: "8e245d9679d31e12",
            videoSize: 734003200,
            filename: "The Matrix (1999) 1080p.mkv"
        )
        XCTAssertEqual(
            segment,
            "videoHash=8e245d9679d31e12&videoSize=734003200&filename=The%20Matrix%20%281999%29%201080p.mkv"
        )

        let segmentNil = AddonTransportUrls.buildSubtitleExtraPathSegment(
            videoHash: nil,
            videoSize: nil,
            filename: nil
        )
        XCTAssertNil(segmentNil)

        let segmentFilenameOnly = AddonTransportUrls.buildSubtitleExtraPathSegment(
            videoHash: nil,
            videoSize: nil,
            filename: "movie.mp4"
        )
        XCTAssertEqual(segmentFilenameOnly, "filename=movie.mp4")
    }

    func testAddonTransportUrlsBuildSubtitleURL() {
        let manifestURL = URL(string: "https://opensubtitles-v3.strem.io/manifest.json")!
        let urlWithExtras = AddonTransportUrls.buildSubtitleURL(
            manifestURL: manifestURL,
            type: "movie",
            id: "tt0133093",
            videoHash: "8e245d9679d31e12",
            videoSize: 734003200,
            filename: "The Matrix 1999.mkv"
        )
        XCTAssertEqual(
            urlWithExtras?.absoluteString,
            "https://opensubtitles-v3.strem.io/subtitles/movie/tt0133093/videoHash=8e245d9679d31e12&videoSize=734003200&filename=The%20Matrix%201999.mkv.json"
        )

        let urlWithoutExtras = AddonTransportUrls.buildSubtitleURL(
            manifestURL: manifestURL,
            type: "movie",
            id: "tt0133093"
        )
        XCTAssertEqual(
            urlWithoutExtras?.absoluteString,
            "https://opensubtitles-v3.strem.io/subtitles/movie/tt0133093.json"
        )
    }

    func testStreamAddonDecodesVideoHashAndMapsToNuvioStream() throws {
        let json = """
        {
            "streams": [
                {
                    "name": "OpenSubtitles Match",
                    "url": "https://debrid.example/stream.mkv",
                    "behaviorHints": {
                        "videoHash": "8e245d9679d31e12",
                        "videoSize": 1073741824,
                        "filename": "Movie.2024.1080p.mkv"
                    }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(StreamAddonResponse.self, from: json)
        let streamDTO = try XCTUnwrap(response.streams?.first)
        XCTAssertEqual(streamDTO.behaviorHints?.videoHash, "8e245d9679d31e12")
        XCTAssertEqual(streamDTO.behaviorHints?.videoSize, 1073741824)
        XCTAssertEqual(streamDTO.behaviorHints?.filename, "Movie.2024.1080p.mkv")

        let stream = try XCTUnwrap(streamDTO.toNuvioStream(addonName: "DebridAddon"))
        XCTAssertEqual(stream.videoHash, "8e245d9679d31e12")
        XCTAssertEqual(stream.videoSize, 1073741824)
        XCTAssertEqual(stream.filename, "Movie.2024.1080p.mkv")
    }

    @MainActor
    func testDMMOpaquePlayRouteInfersShortDiscFilenameForRouting() throws {
        let opaqueURL = "https://selfhost.example/api/stremio/user-123/play/file-token?auth=opaque"
        let json = """
        {
            "streams": [{
                "name": "DMM Cast for Real-Debrid",
                "title": "Movie.2024.1080p.BluRay.iso\\n12.34 GB",
                "url": "\(opaqueURL)"
            }]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(StreamAddonResponse.self, from: json)
        let dto = try XCTUnwrap(response.streams?.first)
        let stream = try XCTUnwrap(dto.toNuvioStream(addonName: "DMM Cast for Real-Debrid"))
        XCTAssertEqual(stream.filename, "Movie.2024.1080p.BluRay.iso")
        XCTAssertEqual(stream.url, opaqueURL)

        let url = try XCTUnwrap(URL(string: opaqueURL))
        let request = PlaybackLoadRequest(videoURL: url, filename: stream.filename)
        let policy = PlaybackBackendPolicy.resolve(.init(
            urlString: opaqueURL,
            filename: stream.filename,
            engineSetting: .mpv,
            requiresMPVAudioControls: false,
            assMode: .off
        ))
        XCTAssertEqual(policy.backend, .aether)
        XCTAssertFalse(PlaybackSessionCoordinator.shouldUseHybridDiskCache(isEnabled: true, request: request))
    }

    func testDMMOpaquePlayRouteReconstructsLongWrappedDiscFilename() throws {
        let expectedMidpointFilename = "The.Wonderful.World.Of.Dune.Part.Two.2024.2160p.UHD.BluRay.HEVC.DV.TrueHD.Atmos.Remux.iso"
        let expectedExtensionEdgeFilename = "The.Wonderful.World.Of.Dune.Part.Two.2024.2160p.UHD.BluRay.HEVC.DV.TrueHD.Atmos.Remux.iso"
        XCTAssertGreaterThan(expectedMidpointFilename.count, 60)
        let json = """
        {
            "streams": [
                {
                    "name": "DMM Cast for Real-Debrid",
                    "title": "The.Wonderful.World.Of.Dune.Part.Two.2024.21-\\n60p.UHD.BluRay.HEVC.DV.TrueHD.Atmos.Remux.iso\\nAudio: TrueHD Atmos\\nCredits: DMM",
                    "url": "https://dmm.home.example/api/stremio/user-123/play/midpoint-token?auth=opaque"
                },
                {
                    "name": "DMM Cast for Real-Debrid",
                    "title": "The.Wonderful.World.Of.Dune.Part.Two.2024.2160p.UHD.BluRay.HEVC.DV.TrueHD.Atmos.Remux.i-\\nso\\nAudio: TrueHD Atmos\\nCredits: DMM",
                    "url": "https://dmm.home.example/api/stremio/user-123/play/extension-edge-token?auth=opaque"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(StreamAddonResponse.self, from: json)
        let dtos = try XCTUnwrap(response.streams)
        let midpointStream = try XCTUnwrap(dtos[0].toNuvioStream(addonName: "DMM Cast for Real-Debrid"))
        let extensionEdgeStream = try XCTUnwrap(dtos[1].toNuvioStream(addonName: "DMM Cast for Real-Debrid"))
        XCTAssertEqual(midpointStream.filename, expectedMidpointFilename)
        XCTAssertEqual(extensionEdgeStream.filename, expectedExtensionEdgeFilename)
    }

    func testDMMExplicitBehaviorHintAndClientResolveFilenamesPrecedeTitleInference() throws {
        let json = """
        {
            "streams": [
                {
                    "name": "DMM Cast for Real-Debrid",
                    "title": "Inferred.behavior.iso",
                    "url": "https://dmm.example/api/stremio/user/play/behavior-token",
                    "behaviorHints": { "filename": "Behavior.filename.mkv" },
                    "clientResolve": { "filename": "Resolve.filename.iso" }
                },
                {
                    "name": "DMM Cast for Real-Debrid",
                    "title": "Inferred.resolve.iso",
                    "url": "https://dmm.example/api/stremio/user/play/resolve-token",
                    "clientResolve": { "filename": "Resolve.filename.mkv" }
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(StreamAddonResponse.self, from: json)
        let dtos = try XCTUnwrap(response.streams)
        let behaviorHintStream = try XCTUnwrap(dtos[0].toNuvioStream(addonName: "DMM Cast for Real-Debrid"))
        let resolveStream = try XCTUnwrap(dtos[1].toNuvioStream(addonName: "DMM Cast for Real-Debrid"))
        XCTAssertEqual(behaviorHintStream.filename, "Behavior.filename.mkv")
        XCTAssertEqual(resolveStream.filename, "Resolve.filename.mkv")
    }

    func testDMMFilenameInferenceRequiresDiscFirstLineExactAddonAndExactPlayPath() throws {
        let json = """
        {
            "streams": [
                {
                    "title": "Movie.2024.1080p.WEB-DL.mkv\\nAudio: DTS-HD MA.iso\\nCredits: backup.iso",
                    "url": "https://dmm.example/api/stremio/user/play/valid-token"
                },
                {
                    "title": "Movie.iso",
                    "url": "https://dmm.example/api/stremio/user/play"
                },
                {
                    "title": "Movie.iso",
                    "url": "https://dmm.example/api/stremio//play/empty-user"
                },
                {
                    "title": "Movie.iso",
                    "url": "https://dmm.example/api/stremio/user/play/"
                },
                {
                    "title": "Movie.iso",
                    "url": "https://dmm.example/api/stremio/user/play/extra/path"
                },
                {
                    "title": "Movie.iso",
                    "url": "https://dmm.example/api/stremio/user/stream/not-play"
                },
                {
                    "title": "Movie.iso",
                    "url": "https://dmm.example/api/stremio/user/play/other-addon"
                }
            ]
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(StreamAddonResponse.self, from: json)
        let dtos = try XCTUnwrap(response.streams)
        let dmmFilenames = dtos.prefix(6).map {
            $0.toNuvioStream(addonName: "DMM Cast for Real-Debrid")?.filename
        }
        XCTAssertEqual(dmmFilenames, [nil, nil, nil, nil, nil, nil])
        XCTAssertNil(dtos[6].toNuvioStream(addonName: "Some Other Addon")?.filename)
    }

    func testOpenSubtitlesHasherComputesDeterministicChecksum() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("test_hasher_\\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // Create a 131072-byte (128 KB) buffer with known contents:
        // first 64KB filled with 0x01, second 64KB filled with 0x02.
        var data = Data(count: 131072)
        data.withUnsafeMutableBytes { ptr in
            ptr.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0x01, count: 65536)
            (ptr.baseAddress! + 65536).initializeMemory(as: UInt8.self, repeating: 0x02, count: 65536)
        }
        try data.write(to: fileURL)

        let result = OpenSubtitlesHasher.computeHashAndSize(for: fileURL)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.size, 131072)
        XCTAssertEqual(result?.hash.count, 16)

        let hashOnly = OpenSubtitlesHasher.computeHash(for: fileURL)
        XCTAssertEqual(hashOnly, result?.hash)

        // File under 64KB should return nil
        let smallFileURL = tempDir.appendingPathComponent("test_small_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: smallFileURL) }
        try Data(count: 1024).write(to: smallFileURL)
        XCTAssertNil(OpenSubtitlesHasher.computeHash(for: smallFileURL))
    }

    func testCachedOnlyFilterPreservesDirectPenguStreams() {
        let penguStream = NuvioStream(
            url: "https://penguplay.com/stremio/stream/series/tt1234567%3A1%3A1.json?token=secret123",
            name: "1080p WEB-DL",
            description: "PenguPlay Direct",
            addonName: "PenguPlay"
        )
        let uncachedTorrentio = NuvioStream(
            url: "https://cdn.example/u.mkv",
            name: "1080p WEB-DL",
            description: "12 GB",
            addonName: "Torrentio"
        )

        let playable = SmartPlaybackSelector.playableStreams(
            from: [penguStream, uncachedTorrentio],
            includeDebrid: false,
            cachedOnly: true
        )

        XCTAssertTrue(playable.contains(where: { $0.id == penguStream.id }))
        XCTAssertFalse(playable.contains(where: { $0.id == uncachedTorrentio.id }))
        XCTAssertTrue(penguStream.isLikelyCached)
        XCTAssertFalse(uncachedTorrentio.isLikelyCached)
    }

    func testFetchStreamsReturnsEmptyOn404NotFound() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockStreamHTTPURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { MockStreamHTTPURLProtocol.handler = nil }

        MockStreamHTTPURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data("{\"streams\":[]}".utf8))
        }

        let streams = try await StreamsRepository.fetchStreams(
            from: URL(string: "https://peerflix.example/stream/movie/tt31349844.json")!,
            addonName: "Peerflix",
            logo: nil,
            session: session
        )
        XCTAssertEqual(streams, [])
    }

    func testFetchStreamsThrowsOn500InternalServerError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockStreamHTTPURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { MockStreamHTTPURLProtocol.handler = nil }

        MockStreamHTTPURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        do {
            _ = try await StreamsRepository.fetchStreams(
                from: URL(string: "https://peerflix.example/stream/movie/tt31349844.json")!,
                addonName: "Peerflix",
                logo: nil,
                session: session
            )
            XCTFail("Expected URLError to be thrown on 500 status code")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
    }

    // MARK: - AIOStreams Custom Name Sync & Display (#395)

    func testStreamAddonPreferenceCodingBackwardCompatibility() throws {
        // Legacy JSON without "name" field
        let legacyJSON = """
        [{"url":"https://aiostreams.elfhosted.com/1/manifest.json","enabled":true}]
        """
        let decodedLegacy = try JSONDecoder().decode([StreamAddonPreference].self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decodedLegacy.count, 1)
        XCTAssertEqual(decodedLegacy[0].url, "https://aiostreams.elfhosted.com/1/manifest.json")
        XCTAssertTrue(decodedLegacy[0].enabled)
        XCTAssertNil(decodedLegacy[0].name)

        // Modern JSON with custom "name" field
        let modernPref = StreamAddonPreference(
            url: "https://aiostreams.elfhosted.com/1/manifest.json",
            enabled: true,
            name: "AIOStreams - 4K Remux"
        )
        let modernData = try JSONEncoder().encode([modernPref])
        let decodedModern = try JSONDecoder().decode([StreamAddonPreference].self, from: modernData)
        XCTAssertEqual(decodedModern.count, 1)
        XCTAssertEqual(decodedModern[0].name, "AIOStreams - 4K Remux")
    }

    func testAIOStreamsDisplayNamePriority() throws {
        let suiteName = "NuvioTVTests.AIOStreamsNameSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let aioURL1 = try XCTUnwrap(URL(string: "https://aiostreams.elfhosted.com/movies/manifest.json"))
        let aioURL2 = try XCTUnwrap(URL(string: "https://aiostreams.elfhosted.com/shows/manifest.json"))
        let aioURLDefault = try XCTUnwrap(URL(string: "https://aiostreams.elfhosted.com/default/manifest.json"))

        let preferences = [
            StreamAddonPreference(url: aioURL1.absoluteString, enabled: true, name: "AIOStreams Movies"),
            StreamAddonPreference(url: aioURL2.absoluteString, enabled: true, name: "AIOStreams Shows"),
            StreamAddonPreference(url: aioURLDefault.absoluteString, enabled: true, name: nil)
        ]
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences(preferences, in: defaults)

        // Custom names override generic manifest name "AIOStreams"
        let name1 = CinemetaCatalogRepository.streamAddonDisplayName(for: aioURL1, manifestName: "AIOStreams", in: defaults)
        let name2 = CinemetaCatalogRepository.streamAddonDisplayName(for: aioURL2, manifestName: "AIOStreams", in: defaults)
        XCTAssertEqual(name1, "AIOStreams Movies")
        XCTAssertEqual(name2, "AIOStreams Shows")

        // Without custom name, falls back to manifest displayName
        let nameManifest = CinemetaCatalogRepository.streamAddonDisplayName(for: aioURLDefault, manifestName: "Custom Manifest Name", in: defaults)
        XCTAssertEqual(nameManifest, "Custom Manifest Name")

        // Without custom name or manifest displayName, falls back to host-based streamAddonName
        let nameFallback = CinemetaCatalogRepository.streamAddonDisplayName(for: aioURLDefault, manifestName: nil, in: defaults)
        XCTAssertEqual(nameFallback, "AIOStreams")
    }

    func testNormalizedPreferencesPreservesAndMergesNames() throws {
        let suiteName = "NuvioTVTests.NormalizedPrefs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let prefs = [
            StreamAddonPreference(url: "https://aiostreams.example/manifest.json", enabled: true, name: "AIO 1"),
            StreamAddonPreference(url: "https://aiostreams.example/manifest.json", enabled: false, name: "AIO Updated")
        ]
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences(prefs, in: defaults)
        let configured = CinemetaCatalogRepository.configuredStreamAddonPreferences(in: defaults)

        XCTAssertEqual(configured.count, 1)
        XCTAssertEqual(configured[0].name, "AIO 1")
    }

    func testBaseContentIdExtractsExpectedRoot() {
        XCTAssertEqual(StreamsRepository.baseContentId(from: "tt1856101"), "tt1856101")
        XCTAssertEqual(StreamsRepository.baseContentId(from: "tt0903747:1:2"), "tt0903747")
        XCTAssertEqual(StreamsRepository.baseContentId(from: "tmdb:335984"), "tmdb:335984")
        XCTAssertEqual(StreamsRepository.baseContentId(from: "tmdb:1396:1:2"), "tmdb:1396")
        XCTAssertEqual(StreamsRepository.baseContentId(from: "jellyfin-server1-item1"), "jellyfin-server1-item1")
        XCTAssertEqual(StreamsRepository.baseContentId(from: "jellyfin-server1-series1:2:3"), "jellyfin-server1-series1")
    }

    @MainActor
    func testJellyfinLibraryIndexTitlesMatching() {
        let serverID = "srv-\(UUID().uuidString)"
        let title = JellyfinIndexedTitle(
            contentId: "jellyfin-\(serverID)-item42",
            serverID: serverID,
            libraryID: "lib1",
            libraryName: "Movies",
            itemId: "item42",
            type: "movie",
            name: "Blade Runner 2049",
            overview: "A young blade runner...",
            year: 2017,
            genres: ["Sci-Fi"],
            communityRating: 8.0,
            officialRating: "R",
            premiereDate: "2017-10-06",
            runTimeTicks: 164 * 60 * 10_000_000,
            imdbId: "tt1856101",
            tmdbId: 335984,
            primaryImageTag: "tag1",
            backdropImageTag: "tag2",
            cast: ["Ryan Gosling"],
            directors: ["Denis Villeneuve"],
            items: [
                JellyfinIndexedItem(
                    itemId: "item42",
                    container: "mkv",
                    size: 15_000_000_000,
                    season: nil,
                    episode: nil,
                    episodeName: nil,
                    episodeOverview: nil,
                    episodePremiereDate: nil,
                    episodeImageTag: nil
                )
            ]
        )

        JellyfinLibraryIndex.shared.replace(titles: [title], forServerID: serverID)
        defer { JellyfinLibraryIndex.shared.removeAll(forServerID: serverID) }

        // Match by synthetic contentId
        XCTAssertEqual(JellyfinLibraryIndex.shared.titles(matching: "jellyfin-\(serverID)-item42").count, 1)
        // Match by raw itemId
        XCTAssertEqual(JellyfinLibraryIndex.shared.titles(matching: "item42").count, 1)
        // Match by canonical IMDb ID (what NuvioMeta.streamId outputs for Blade Runner 2049)
        XCTAssertEqual(JellyfinLibraryIndex.shared.titles(matching: "tt1856101").count, 1)
        XCTAssertEqual(JellyfinLibraryIndex.shared.titles(matching: "imdb:1856101").count, 1)
        XCTAssertEqual(JellyfinLibraryIndex.shared.titles(matching: "1856101").count, 1)
        // Match by TMDB ID
        XCTAssertEqual(JellyfinLibraryIndex.shared.titles(matching: "tmdb:335984").count, 1)
        // Non-matches
        XCTAssertTrue(JellyfinLibraryIndex.shared.titles(matching: "tt9999999").isEmpty)
        XCTAssertTrue(JellyfinLibraryIndex.shared.titles(matching: "tmdb:9999999").isEmpty)
        XCTAssertTrue(JellyfinLibraryIndex.shared.titles(matching: "").isEmpty)
    }

    @MainActor
    func testJellyfinStreamGroupResolvesWhenPlayUsesImdbStreamId() async throws {
        let suiteName = "NuvioTVTests.JellyfinPlay.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let previousProfileID = ProfileSettings.activeProfileID
        let previousProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        let testProfileID = "jellyfin-play-\(UUID().uuidString)"
        ProfileSettings.setActiveProfile(testProfileID, isPrimary: false)
        defer {
            if let previousProfileID {
                ProfileSettings.setActiveProfile(previousProfileID, isPrimary: previousProfileIsPrimary)
            }
        }

        // Configure Jellyfin server
        let serverID = "srv-\(UUID().uuidString)"
        let server = JellyfinServerConfig(
            id: serverID,
            displayName: "Home Jellyfin",
            baseURLString: "http://127.0.0.1:8096",
            authKind: .apiKey,
            username: "user",
            userId: "uid-1",
            selectedLibraryIDs: ["lib-1"],
            lastSyncDate: Date(),
            lastSyncTitleCount: 1,
            syncAutomatically: false
        )
        JellyfinServerStore.shared.upsert(server)
        JellyfinCredentialStore.save("test-token-123", forServerID: serverID)
        defer {
            JellyfinServerStore.shared.remove(serverID)
        }

        // Index Blade Runner 2049 with IMDb id tt1856101
        let title = JellyfinIndexedTitle(
            contentId: "jellyfin-\(serverID)-item42",
            serverID: serverID,
            libraryID: "lib-1",
            libraryName: "Movies",
            itemId: "item42",
            type: "movie",
            name: "Blade Runner 2049",
            overview: "A young blade runner...",
            year: 2017,
            genres: ["Sci-Fi"],
            communityRating: 8.0,
            officialRating: "R",
            premiereDate: "2017-10-06",
            runTimeTicks: 164 * 60 * 10_000_000,
            imdbId: "tt1856101",
            tmdbId: 335984,
            primaryImageTag: "tag1",
            backdropImageTag: "tag2",
            cast: ["Ryan Gosling"],
            directors: ["Denis Villeneuve"],
            items: [
                JellyfinIndexedItem(
                    itemId: "item42",
                    container: "mkv",
                    size: 15_000_000_000,
                    season: nil,
                    episode: nil,
                    episodeName: nil,
                    episodeOverview: nil,
                    episodePremiereDate: nil,
                    episodeImageTag: nil
                )
            ]
        )
        JellyfinLibraryIndex.shared.replace(titles: [title], forServerID: serverID)

        // Clear any external add-ons so only local sources are evaluated (matching #401 reproduction)
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences([], in: ProfileSettings.current)

        // When user plays, NuvioMeta.streamId substitutes IMDb ID "tt1856101"
        let streams = await StreamsRepository.shared.collectStreams(type: "movie", videoId: "tt1856101", forceRefresh: true)

        XCTAssertFalse(streams.isEmpty, "Jellyfin stream should be resolved for IMDb ID tt1856101")
        XCTAssertEqual(streams.first?.addonName, "Jellyfin")
        XCTAssertEqual(streams.first?.name, "Home Jellyfin")
        XCTAssertTrue(streams.first?.url?.contains("Videos/item42/stream") ?? false)
        XCTAssertTrue(streams.first?.url?.contains("api_key=test-token-123") ?? false)

        // Verify discovery state does not report "No compatible add-ons"
        let state = StreamsRepository.shared.state
        XCTAssertNil(state.emptyStateReason, "Empty state reason should be nil when Jellyfin stream is present")
        let jellyfinGroup = state.groups.first(where: { $0.addonId == "local.jellyfin" })
        XCTAssertNotNil(jellyfinGroup)
        XCTAssertEqual(jellyfinGroup?.streams.count, 1)
    }

    @MainActor
    func testJellyfinStreamGroupResolvesSeriesEpisodeWhenUsingCanonicalEpisodeStreamId() async throws {
        let previousProfileID = ProfileSettings.activeProfileID
        let previousProfileIsPrimary = ProfileSettings.isPrimaryProfileStore(ProfileSettings.current)
        let testProfileID = "jellyfin-series-\(UUID().uuidString)"
        ProfileSettings.setActiveProfile(testProfileID, isPrimary: false)
        defer {
            if let previousProfileID {
                ProfileSettings.setActiveProfile(previousProfileID, isPrimary: previousProfileIsPrimary)
            }
        }

        let serverID = "srv-\(UUID().uuidString)"
        let server = JellyfinServerConfig(
            id: serverID,
            displayName: "Home Jellyfin",
            baseURLString: "http://127.0.0.1:8096",
            authKind: .apiKey,
            username: "user",
            userId: "uid-1",
            selectedLibraryIDs: ["lib-shows"],
            lastSyncDate: Date(),
            lastSyncTitleCount: 1,
            syncAutomatically: false
        )
        JellyfinServerStore.shared.upsert(server)
        JellyfinCredentialStore.save("test-token-series", forServerID: serverID)
        defer {
            JellyfinServerStore.shared.remove(serverID)
        }

        let seriesTitle = JellyfinIndexedTitle(
            contentId: "jellyfin-\(serverID)-series100",
            serverID: serverID,
            libraryID: "lib-shows",
            libraryName: "TV Shows",
            itemId: "series100",
            type: "series",
            name: "Breaking Bad",
            overview: "Chemistry teacher...",
            year: 2008,
            genres: ["Drama"],
            communityRating: 9.5,
            officialRating: "TV-MA",
            premiereDate: "2008-01-20",
            runTimeTicks: 48 * 60 * 10_000_000,
            imdbId: "tt0903747",
            tmdbId: 1396,
            primaryImageTag: "tag1",
            backdropImageTag: "tag2",
            cast: ["Bryan Cranston"],
            directors: ["Vince Gilligan"],
            items: [
                JellyfinIndexedItem(
                    itemId: "ep-s1e1",
                    container: "mp4",
                    size: 2_000_000_000,
                    season: 1,
                    episode: 1,
                    episodeName: "Pilot",
                    episodeOverview: nil,
                    episodePremiereDate: nil,
                    episodeImageTag: nil
                ),
                JellyfinIndexedItem(
                    itemId: "ep-s1e2",
                    container: "mp4",
                    size: 2_100_000_000,
                    season: 1,
                    episode: 2,
                    episodeName: "Cat's in the Bag...",
                    episodeOverview: nil,
                    episodePremiereDate: nil,
                    episodeImageTag: nil
                )
            ]
        )
        JellyfinLibraryIndex.shared.replace(titles: [seriesTitle], forServerID: serverID)
        CinemetaCatalogRepository.setConfiguredStreamAddonPreferences([], in: ProfileSettings.current)

        // Episode play uses canonicalEpisodeStreamId e.g. "tt0903747:1:2"
        let streams = await StreamsRepository.shared.collectStreams(type: "series", videoId: "tt0903747:1:2", forceRefresh: true)

        XCTAssertEqual(streams.count, 1)
        XCTAssertEqual(streams.first?.addonName, "Jellyfin")
        XCTAssertTrue(streams.first?.url?.contains("Videos/ep-s1e2/stream") ?? false)
    }
}

private final class MockStreamHTTPURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}


