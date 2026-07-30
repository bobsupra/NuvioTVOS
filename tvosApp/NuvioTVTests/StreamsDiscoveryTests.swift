//
//  StreamsDiscoveryTests.swift
//  NuvioTVTests
//
//  Regression coverage for stream discovery behavior aligned with Android
//  StreamsRepository (stable instance ids, metadata preservation, request keys).
//

import XCTest
@testable import NuvioTV

final class StreamsDiscoveryTests: XCTestCase {

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
}
