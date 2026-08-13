//
//  StreamsRepository.swift
//  NuvioTV
//
//  App-lifetime stream discovery, modeled after Android StreamsRepository:
//  one stateful group per compatible add-on, concurrent fetches, request-key
//  caching so returning from playback reuses results without re-querying.
//

import Foundation

/// Shared stream discovery used by Details and player source switching.
/// Jobs outlive DetailsViewModel so playback / leaving details never cancel
/// an in-flight search.
@MainActor
final class StreamsRepository: ObservableObject {
    static let shared = StreamsRepository()

    /// Bounded per-add-on stream request timeout (seconds). Dead providers
    /// finish as failed without blocking the rest or smart autoplay forever.
    static let streamRequestTimeout: TimeInterval = 18

    @Published private(set) var state = StreamsDiscoveryState()

    private var activeJob: Task<Void, Never>?
    private var activeRequestKey: String?

    /// Actor-backed success-only cache (no permanent failure entries).
    private static let manifestCache = StreamManifestCache()

    private init() {}

    // MARK: - Request key

    nonisolated static func requestKey(
        type: String,
        videoId: String,
        season: Int? = nil,
        episode: Int? = nil
    ) -> String {
        "\(type)::\(videoId)::\(season.map(String.init) ?? "")::\(episode.map(String.init) ?? "")"
    }

    /// Parse `tt1234567:1:5`-style series episode ids into season/episode.
    nonisolated static func seasonEpisode(fromVideoId videoId: String) -> (season: Int?, episode: Int?) {
        let parts = videoId.split(separator: ":")
        guard parts.count >= 3,
              let season = Int(parts[parts.count - 2]),
              let episode = Int(parts[parts.count - 1]) else {
            return (nil, nil)
        }
        return (season, episode)
    }

    /// Stremio stream requests carry season/episode embedded in `videoId`
    /// ("tt1234567:1:5"); `SMBIndexedTitle.contentId` is the bare Cinemeta id.
    nonisolated private static func baseContentId(from videoId: String) -> String {
        String(videoId.split(separator: ":").first ?? Substring(videoId))
    }

    /// Local files already indexed for this title/episode, as a synthetic
    /// "Local (SMB)" group — resolved synchronously (no network round trip),
    /// so it can lead the stream list the instant discovery starts.
    private func localStreamGroup(type: String, videoId: String) -> AddonStreamGroup? {
        let contentId = Self.baseContentId(from: videoId)
        let se = Self.seasonEpisode(fromVideoId: videoId)
        let files = SMBLibraryIndex.shared.files(forContentId: contentId, season: se.season, episode: se.episode)
        guard !files.isEmpty else { return nil }

        let serversByID = Dictionary(uniqueKeysWithValues: SMBServerStore.shared.servers.map { ($0.id, $0) })
        let streams: [NuvioStream] = files.compactMap { file -> NuvioStream? in
            guard let server = serversByID[file.serverID] else { return nil }
            return NuvioStream(
                url: file.streamPath(hostAndPort: server.hostAndPort),
                name: server.displayName,
                description: ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file),
                addonName: "Local (SMB)",
                filename: file.filename,
                videoSize: file.size
            )
        }
        guard !streams.isEmpty else { return nil }
        return AddonStreamGroup(addonId: "local.smb", displayName: "Local (SMB)", streams: streams, isLoading: false)
    }

    /// Titles already synced from a Jellyfin server, as a synthetic
    /// "Jellyfin" group — same synchronous, no-round-trip shape as
    /// `localStreamGroup`, since the sync step already resolved the item ids.
    private func jellyfinStreamGroup(type: String, videoId: String) -> AddonStreamGroup? {
        let contentId = Self.baseContentId(from: videoId)
        let se = Self.seasonEpisode(fromVideoId: videoId)
        guard let title = JellyfinLibraryIndex.shared.titles().first(where: { $0.contentId == contentId }),
              let server = JellyfinServerStore.shared.server(id: title.serverID),
              let baseURL = server.baseURL else { return nil }
        let items = title.items.filter { $0.season == se.season && $0.episode == se.episode }
        guard !items.isEmpty else { return nil }

        let token = JellyfinCredentialStore.token(forServerID: server.id)
        let streams: [NuvioStream] = items.compactMap { item -> NuvioStream? in
            guard let url = item.streamURL(baseURL: baseURL, accessToken: token) else { return nil }
            return NuvioStream(
                url: url.absoluteString,
                name: server.displayName,
                description: item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                addonName: "Jellyfin",
                videoSize: item.size
            )
        }
        guard !streams.isEmpty else { return nil }
        return AddonStreamGroup(addonId: "local.jellyfin", displayName: "Jellyfin", streams: streams, isLoading: false)
    }

    // MARK: - Public API

    func load(
        type: String,
        videoId: String,
        season: Int? = nil,
        episode: Int? = nil,
        forceRefresh: Bool = false
    ) {
        let se = (season == nil && episode == nil)
            ? Self.seasonEpisode(fromVideoId: videoId)
            : (season, episode)
        let key = Self.requestKey(type: type, videoId: videoId, season: se.0, episode: se.1)
        let current = state

        if !forceRefresh,
           activeRequestKey == key,
           current.hasResolvedTargets || current.isAnyLoading || current.emptyStateReason != nil {
            print("[StreamsRepo] skip reload key=\(key) groups=\(current.groups.count) loading=\(current.isAnyLoading)")
            return
        }

        activeRequestKey = key
        activeJob?.cancel()
        activeJob = Task { [weak self] in
            await self?.runDiscovery(
                requestKey: key,
                type: type,
                videoId: videoId
            )
        }
    }

    func reload(
        type: String,
        videoId: String,
        season: Int? = nil,
        episode: Int? = nil
    ) {
        load(type: type, videoId: videoId, season: season, episode: episode, forceRefresh: true)
    }

    /// One-shot collect for player source switching / next-episode resolve.
    /// Reuses an in-flight or completed request for the same key.
    func collectStreams(
        type: String,
        videoId: String,
        season: Int? = nil,
        episode: Int? = nil,
        forceRefresh: Bool = false
    ) async -> [NuvioStream] {
        let se = (season == nil && episode == nil)
            ? Self.seasonEpisode(fromVideoId: videoId)
            : (season, episode)
        let key = Self.requestKey(type: type, videoId: videoId, season: se.0, episode: se.1)

        load(type: type, videoId: videoId, season: se.0, episode: se.1, forceRefresh: forceRefresh)

        // Wait until this key is no longer loading (or a newer key took over).
        while !Task.isCancelled {
            let snapshot = state
            if snapshot.requestKey == key, snapshot.hasResolvedTargets, !snapshot.isAnyLoading {
                return snapshot.allStreams
            }
            if activeRequestKey != key, snapshot.requestKey != key {
                // A different search replaced ours mid-wait; return whatever
                // we still hold for the original key if any, else empty.
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return state.requestKey == key ? state.allStreams : []
    }

    // MARK: - Discovery

    private func runDiscovery(requestKey: String, type: String, videoId: String) async {
        state = StreamsDiscoveryState(
            requestKey: requestKey,
            revision: state.revision &+ 1,
            isAnyLoading: true
        )

        let localGroup = localStreamGroup(type: type, videoId: videoId)
        let jellyfinGroup = jellyfinStreamGroup(type: type, videoId: videoId)
        let ownedGroups = [localGroup, jellyfinGroup].compactMap { $0 }

        let preferences = CinemetaCatalogRepository.configuredStreamAddonPreferences
        let enabledURLs = preferences.compactMap { pref -> URL? in
            guard pref.enabled else { return nil }
            return CinemetaCatalogRepository.normalizedManifestURL(from: pref.url)
        }

        print("[StreamsRepo] configured=\(preferences.count) enabled=\(enabledURLs.count) type=\(type) id=\(videoId)")

        guard !enabledURLs.isEmpty else {
            // A NAS-only/Jellyfin-only user with no add-ons configured still
            // has their owned media — that must not read as "no add-ons
            // configured".
            state = StreamsDiscoveryState(
                requestKey: requestKey,
                revision: state.revision &+ 1,
                groups: ownedGroups,
                isAnyLoading: false,
                emptyStateReason: ownedGroups.isEmpty ? .noAddonsConfigured : nil,
                hasResolvedTargets: true
            )
            print("[StreamsRepo] no enabled add-ons, owned=\(ownedGroups.reduce(0) { $0 + $1.streams.count })")
            return
        }

        // Load missing manifests concurrently (app-lifetime cache).
        let manifestsByURL = await Self.loadManifestsConcurrently(urls: enabledURLs)

        // Preserve configured order; only include stream-capable, id-compatible add-ons.
        var targets: [StreamAddonTarget] = []
        for url in enabledURLs {
            guard let manifest = manifestsByURL[url] else { continue }
            guard manifest.supportsResource("stream", type: type, id: videoId) else { continue }
            let displayName = manifest.displayName
                ?? CinemetaCatalogRepository.streamAddonName(for: url)
            targets.append(
                StreamAddonTarget(
                    addonId: Self.stableAddonId(manifest: manifest, manifestURL: url),
                    displayName: displayName,
                    manifestURL: url,
                    logo: manifest.logo
                )
            )
        }

        print("[StreamsRepo] compatible=\(targets.count) of enabled=\(enabledURLs.count)")

        guard !targets.isEmpty else {
            state = StreamsDiscoveryState(
                requestKey: requestKey,
                revision: state.revision &+ 1,
                groups: [],
                isAnyLoading: false,
                emptyStateReason: .noCompatibleAddons,
                hasResolvedTargets: true
            )
            print("[StreamsRepo] no compatible stream add-ons")
            return
        }

        // Create every group as loading *before* any request so chips appear immediately.
        // The owned groups (if any) are already resolved — no network round
        // trip — so they lead the list and never carry a loading state.
        let initialGroups = ownedGroups + targets.map {
            AddonStreamGroup(
                addonId: $0.addonId,
                displayName: $0.displayName,
                streams: [],
                isLoading: true,
                error: nil
            )
        }
        state = StreamsDiscoveryState(
            requestKey: requestKey,
            revision: state.revision &+ 1,
            groups: initialGroups,
            isAnyLoading: true,
            emptyStateReason: nil,
            hasResolvedTargets: true
        )

        await withTaskGroup(of: GroupUpdate.self) { group in
            for target in targets {
                group.addTask {
                    await Self.fetchAddonGroup(target: target, type: type, videoId: videoId)
                }
            }

            for await update in group {
                guard !Task.isCancelled else { break }
                guard self.activeRequestKey == requestKey else { break }
                // Keep isAnyLoading true for the whole stream phase so the last
                // group completing cannot drop observers before external subtitles.
                apply(update: update, requestKey: requestKey, forceLoading: true)
            }
        }

        guard activeRequestKey == requestKey else { return }

        // Stream groups are done, but smart subtitle matching must not run until
        // external subtitle decoration finishes. Stay "loading" through that step.
        publish(groups: state.groups, requestKey: requestKey, forceLoading: true)

        let externalSubtitles = await fetchExternalSubtitles(type: type, videoId: videoId)
        guard activeRequestKey == requestKey else { return }

        var finalGroups = state.groups
        if !externalSubtitles.isEmpty {
            finalGroups = finalGroups.map { group in
                var copy = group
                copy.streams = group.streams.map { $0.mergingExternalSubtitles(externalSubtitles) }
                return copy
            }
        }
        publish(groups: finalGroups, requestKey: requestKey, forceLoading: false)
        print(
            "[StreamsRepo] done key=\(requestKey) groups=\(finalGroups.count) streams=\(finalGroups.flatMap(\.streams).count) empty=\(String(describing: state.emptyStateReason)) subtitles=\(externalSubtitles.count)"
        )
    }

    private func apply(update: GroupUpdate, requestKey: String, forceLoading: Bool) {
        var groups = state.groups
        guard let index = groups.firstIndex(where: { $0.addonId == update.addonId }) else { return }
        groups[index] = update.group
        publish(groups: groups, requestKey: requestKey, forceLoading: forceLoading)
    }

    private func publish(groups: [AddonStreamGroup], requestKey: String, forceLoading: Bool) {
        let groupLoading = groups.contains(where: \.isLoading)
        let anyLoading = forceLoading || groupLoading
        let emptyReason: StreamsEmptyStateReason? = {
            if anyLoading { return nil }
            if groups.contains(where: { !$0.streams.isEmpty }) { return nil }
            if groups.isEmpty { return .noCompatibleAddons }
            return .noStreamsFound
        }()
        state = StreamsDiscoveryState(
            requestKey: requestKey,
            revision: state.revision &+ 1,
            groups: groups,
            isAnyLoading: anyLoading,
            emptyStateReason: emptyReason,
            hasResolvedTargets: true
        )
    }

    // MARK: - Per-add-on fetch

    private struct StreamAddonTarget {
        let addonId: String
        let displayName: String
        let manifestURL: URL
        let logo: String?
    }

    private struct GroupUpdate {
        let addonId: String
        let group: AddonStreamGroup
    }

    /// Stable instance id matching Android: `addon:<manifestId>:<manifestUrl>`.
    /// Multiple installs of the same add-on (Torrentio/AIO configs) share
    /// `manifest.id` but must remain distinct groups and SwiftUI identities.
    nonisolated static func stableAddonId(manifestId: String, manifestURL: URL) -> String {
        let id = manifestId.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedId = id.isEmpty ? "unknown" : id
        return "addon:\(resolvedId):\(manifestURL.absoluteString)"
    }

    nonisolated private static func stableAddonId(manifest: StreamAddonManifest, manifestURL: URL) -> String {
        stableAddonId(manifestId: manifest.id, manifestURL: manifestURL)
    }

    private static func fetchAddonGroup(
        target: StreamAddonTarget,
        type: String,
        videoId: String
    ) async -> GroupUpdate {
        let streamURL = target.manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("stream")
            .appendingPathComponent(type)
            .appendingPathComponent("\(videoId).json")

        do {
            let streams = try await fetchStreams(
                from: streamURL,
                addonName: target.displayName,
                logo: target.logo
            )
            print("[StreamsRepo] completed addon=\(target.displayName) id=\(target.addonId) streams=\(streams.count)")
            return GroupUpdate(
                addonId: target.addonId,
                group: AddonStreamGroup(
                    addonId: target.addonId,
                    displayName: target.displayName,
                    streams: streams,
                    isLoading: false,
                    error: streams.isEmpty ? nil : nil
                )
            )
        } catch {
            let message = (error as? URLError)?.code == .timedOut
                ? "Timed out"
                : error.localizedDescription
            print("[StreamsRepo] failed addon=\(target.displayName) id=\(target.addonId) error=\(message)")
            return GroupUpdate(
                addonId: target.addonId,
                group: AddonStreamGroup(
                    addonId: target.addonId,
                    displayName: target.displayName,
                    streams: [],
                    isLoading: false,
                    error: message
                )
            )
        }
    }

    private static func fetchStreams(
        from url: URL,
        addonName: String,
        logo: String?
    ) async throws -> [NuvioStream] {
        var request = URLRequest(url: url)
        request.timeoutInterval = streamRequestTimeout
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(StreamAddonResponse.self, from: data)
        return decoded.streams.compactMap { raw in
            guard let stream = raw.toNuvioStream(addonName: addonName) else { return nil }
            return logo.map { stream.withAddonLogoURL($0) } ?? stream
        }
    }

    // MARK: - Manifest cache

    private static func loadManifestsConcurrently(urls: [URL]) async -> [URL: StreamAddonManifest] {
        var result: [URL: StreamAddonManifest] = [:]
        var missing: [URL] = []

        for url in urls {
            if let cached = await manifestCache.success(for: url) {
                result[url] = cached
            } else {
                missing.append(url)
            }
        }

        guard !missing.isEmpty else { return result }

        await withTaskGroup(of: (URL, StreamAddonManifest?).self) { group in
            for url in missing {
                group.addTask {
                    let manifest = await fetchManifest(url)
                    return (url, manifest)
                }
            }
            for await (url, manifest) in group {
                // Success-only: a temporary failure must not block retries on the
                // next open (that recreated the "only Meteor" missing-addons case).
                if let manifest {
                    await manifestCache.storeSuccess(manifest, for: url)
                    result[url] = manifest
                } else {
                    print("[StreamsRepo] manifest fetch failed url=\(url.absoluteString) (not cached)")
                }
            }
        }
        return result
    }

    private static func fetchManifest(_ url: URL) async -> StreamAddonManifest? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode,
              let manifest = try? JSONDecoder().decode(StreamAddonManifest.self, from: data) else {
            return nil
        }
        return manifest
    }

    /// Prefetch / reuse for CatalogRepository home rows when available.
    static func cachedManifest(for url: URL) async -> StreamAddonManifest? {
        await manifestCache.success(for: url)
    }

    static func storeManifest(_ manifest: StreamAddonManifest, for url: URL) async {
        await manifestCache.storeSuccess(manifest, for: url)
    }

    // MARK: - External subtitles

    private func fetchExternalSubtitles(type: String, videoId: String) async -> [NuvioSubtitle] {
        let subtitleType = Self.isSeriesType(type) ? "series" : "movie"
        let builtIn: [(name: String, url: URL)] = [
            (
                "OpenSubtitles v3",
                URL(string: "https://opensubtitles-v3.strem.io/manifest.json")!
            )
        ]

        var endpoints: [(name: String, subtitleURL: URL)] = builtIn.map { item in
            (
                item.name,
                item.url
                    .deletingLastPathComponent()
                    .appendingPathComponent("subtitles")
                    .appendingPathComponent(subtitleType)
                    .appendingPathComponent("\(videoId).json")
            )
        }

        let enabledURLs = CinemetaCatalogRepository.configuredStreamAddonManifestURLs
        let manifests = await Self.loadManifestsConcurrently(urls: enabledURLs)
        for url in enabledURLs {
            guard let manifest = manifests[url],
                  manifest.supportsResource("subtitles", type: subtitleType, id: videoId) else {
                continue
            }
            let name = manifest.displayName ?? CinemetaCatalogRepository.streamAddonName(for: url)
            let subtitleURL = url
                .deletingLastPathComponent()
                .appendingPathComponent("subtitles")
                .appendingPathComponent(subtitleType)
                .appendingPathComponent("\(videoId).json")
            endpoints.append((name, subtitleURL))
        }

        var accumulated: [NuvioSubtitle] = []
        var seen = Set<String>()
        await withTaskGroup(of: [NuvioSubtitle].self) { group in
            for endpoint in endpoints {
                group.addTask {
                    await Self.fetchSubtitles(from: endpoint.subtitleURL, source: endpoint.name)
                }
            }
            for await batch in group {
                for subtitle in batch where seen.insert(subtitle.url).inserted {
                    accumulated.append(subtitle)
                }
            }
        }
        return accumulated
    }

    private static func fetchSubtitles(from url: URL, source: String) async -> [NuvioSubtitle] {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                return []
            }
            let decoded = try JSONDecoder().decode(StreamSubtitleResponse.self, from: data)
            return decoded.subtitles.compactMap { $0.toNuvioSubtitle(source: source) }
        } catch {
            print("[StreamsRepo] subtitles failed source=\(source) error=\(error.localizedDescription)")
            return []
        }
    }

    private static func isSeriesType(_ type: String) -> Bool {
        ["series", "show", "tv", "tvshow"].contains(type.lowercased())
    }
}

// MARK: - Actor-backed success-only manifest cache

/// App-lifetime cache of successfully decoded manifests.
/// Failures are never stored, so a flaky host is retried on the next discovery.
actor StreamManifestCache {
    private var successes: [URL: StreamAddonManifest] = [:]

    func success(for url: URL) -> StreamAddonManifest? {
        successes[url]
    }

    func storeSuccess(_ manifest: StreamAddonManifest, for url: URL) {
        successes[url] = manifest
    }

    /// Test / diagnostics helper.
    func removeAll() {
        successes.removeAll()
    }
}

// MARK: - Manifest / response models (stream discovery)

struct StreamAddonManifest: Decodable {
    let id: String
    let name: String?
    let logo: String?
    let types: [String]?
    let idPrefixes: [String]?
    let resources: [StreamAddonManifestResource]?

    var displayName: String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @_optimize(none)
    func supportsResource(_ name: String, type: String, id: String) -> Bool {
        guard let resources, !resources.isEmpty else { return false }
        let fallbackTypes = types ?? []
        let fallbackPrefixes = idPrefixes ?? []
        for resource in resources {
            if resource.name.caseInsensitiveCompare(name) == .orderedSame,
               resource.supportsType(type, fallbackTypes: fallbackTypes),
               resource.supportsId(id, fallbackPrefixes: fallbackPrefixes) {
                return true
            }
        }
        return false
    }
}

struct StreamAddonManifestResource: Decodable {
    let name: String
    let types: [String]
    let idPrefixes: [String]?

    enum CodingKeys: String, CodingKey {
        case name, types, idPrefixes
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let value = try? singleValue.decode(String.self) {
            name = value
            types = []
            idPrefixes = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        types = (try? container.decode([String].self, forKey: .types)) ?? []
        idPrefixes = try? container.decode([String].self, forKey: .idPrefixes)
    }

    func supportsType(_ type: String, fallbackTypes: [String]) -> Bool {
        let supportedTypes = types.isEmpty ? fallbackTypes : types
        guard !supportedTypes.isEmpty else { return true }
        return supportedTypes.contains { $0.caseInsensitiveCompare(type) == .orderedSame }
    }

    func supportsId(_ id: String, fallbackPrefixes: [String]) -> Bool {
        let prefixes = (idPrefixes?.isEmpty == false) ? (idPrefixes ?? []) : fallbackPrefixes
        guard !prefixes.isEmpty else { return true }
        return prefixes.contains { id.lowercased().hasPrefix($0.lowercased()) }
    }
}

private struct StreamAddonResponse: Decodable {
    let streams: [StreamAddonStreamDTO]
}

private struct StreamSubtitleResponse: Decodable {
    let subtitles: [StreamAddonSubtitleDTO]
}

struct StreamAddonStreamDTO: Decodable {
    let url: String?
    let externalUrl: String?
    let name: String?
    let title: String?
    let description: String?
    let subtitles: [StreamAddonSubtitleDTO]?
    let behaviorHints: StreamAddonBehaviorHints?
    let infoHash: String?
    let fileIdx: Int?
    let sources: [String]?

    func toNuvioStream(addonName: String) -> NuvioStream? {
        let streamURL = cleaned(url) ?? cleaned(externalUrl)
        let hash = cleaned(infoHash)?.lowercased()
        guard streamURL != nil || hash != nil else { return nil }

        let displayName = cleaned(name) ?? cleaned(title) ?? "Stream"
        var detailLines: [String] = []
        if let title = cleaned(title), title != displayName {
            detailLines.append(title)
        }
        if let description = cleaned(description) {
            detailLines.append(description)
        } else if let size = behaviorHints?.videoSize {
            detailLines.append("Size \(Self.sizeFormatter.string(fromByteCount: size))")
        }

        return NuvioStream(
            url: streamURL,
            name: displayName,
            description: detailLines.joined(separator: "\n"),
            addonName: addonName,
            subtitles: subtitles?.compactMap { $0.toNuvioSubtitle(source: addonName) } ?? [],
            infoHash: hash,
            fileIdx: fileIdx,
            sources: sources ?? [],
            filename: cleaned(behaviorHints?.filename),
            videoSize: behaviorHints?.videoSize,
            bingeGroup: cleaned(behaviorHints?.bingeGroup),
            isCached: behaviorHints?.cached ?? behaviorHints?.isCached,
            httpHeaders: behaviorHints?.proxyHeaders?.request
        )
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter
    }()
}

struct StreamAddonSubtitleDTO: Decodable {
    let url: String?
    let language: String?
    let lang: String?
    let title: String?
    let name: String?
    let id: String?

    func toNuvioSubtitle(source: String? = nil) -> NuvioSubtitle? {
        guard let subtitleURL = cleaned(url) else { return nil }
        let subtitleLanguage = cleaned(language) ?? cleaned(lang) ?? "Unknown"
        return NuvioSubtitle(
            url: subtitleURL,
            language: subtitleLanguage,
            label: cleaned(title) ?? cleaned(name) ?? cleaned(id),
            source: source
        )
    }

    private func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct StreamAddonBehaviorHints: Decodable {
    let videoSize: Int64?
    let filename: String?
    let bingeGroup: String?
    let cached: Bool?
    let isCached: Bool?
    let proxyHeaders: StreamAddonProxyHeaders?
}

/// Stremio stream add-ons can require request headers for the media host.
/// Response headers describe proxy behavior and are not sent by clients.
struct StreamAddonProxyHeaders: Decodable {
    let request: [String: String]?
}
