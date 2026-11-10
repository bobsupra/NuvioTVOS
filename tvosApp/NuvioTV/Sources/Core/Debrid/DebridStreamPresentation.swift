import Foundation

struct DebridStreamPresentation {
    private let store: UserDefaults
    private let localDebridService: LocalDebridService

    init(
        store: UserDefaults = ProfileSettings.current,
        localDebridService: LocalDebridService = LocalDebridService()
    ) {
        self.store = store
        self.localDebridService = localDebridService
    }

    static func present(streams: [NuvioStream], store: UserDefaults = ProfileSettings.current) async -> [NuvioStream] {
        await DebridStreamPresentation(store: store).present(streams: streams)
    }

    var isDebridEnabled: Bool {
        let enabled = store.object(forKey: SettingsKey.debridEnabled) as? Bool ?? true
        let selectedKind = DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider))
        let token = DebridCredentials.token(for: selectedKind, store: store)
        return enabled && selectedKind.hasResolver && !token.isEmpty
    }

    var activeProvider: DebridProviderKind {
        DebridProviderKind(settingsValue: store.string(forKey: SettingsKey.debridProvider))
    }

    /// Takes raw streams from an add-on group, checks debrid cache for any
    /// torrent streams, formats cached streams as "[resolution] [TB/RD/PM] Instant",
    /// and filters out uncached torrent streams when debrid resolving is enabled.
    func present(streams: [NuvioStream]) async -> [NuvioStream] {
        guard isDebridEnabled else { return streams }
        let provider = activeProvider
        let token = DebridCredentials.token(for: provider, store: store)
        guard !token.isEmpty else { return streams }

        // Only check torrent-only streams that require debrid resolution
        let torrentStreams = streams.filter { $0.isDebridResolvable }
        guard !torrentStreams.isEmpty else { return streams }

        let hashes = Array(Set(torrentStreams.compactMap(\.effectiveInfoHash)))
        let statuses = await localDebridService.checkCached(provider: provider, apiKey: token, hashes: hashes)

        return streams.compactMap { stream -> NuvioStream? in
            guard stream.isDebridResolvable else {
                // Direct URL stream (already resolved by add-on or direct HTTP)
                return stream
            }
            guard let infoHash = stream.effectiveInfoHash?.lowercased() else { return nil }

            switch statuses[infoHash] ?? .unknown {
            case .cached(let cachedItem):
                return formattedDebridStream(stream, provider: provider, cachedItem: cachedItem)
            case .notCached:
                // Confirmed uncached torrents stay filtered while Debrid is enabled.
                return nil
            case .unknown:
                // Keep add-on metadata and cache claims intact when the provider
                // cannot confirm availability; the card labels this uncertainty.
                return stream.withDebridCacheStatusUnavailable(true)
            }
        }
    }

    private func formattedDebridStream(
        _ stream: NuvioStream,
        provider: DebridProviderKind,
        cachedItem: LocalDebridCachedItem
    ) -> NuvioStream {
        let tags = StreamQualityTags.parse(stream: stream)
        let resLabel: String = {
            if tags.resolution >= 2160 { return "4K" }
            if tags.resolution >= 1440 { return "1440p" }
            if tags.resolution >= 1080 { return "1080p" }
            if tags.resolution >= 720 { return "720p" }
            if tags.resolution > 0 { return "\(tags.resolution)p" }
            return ""
        }()

        let shortName = provider.shortName.isEmpty ? "Debrid" : provider.shortName
        let formattedName: String = {
            if !resLabel.isEmpty {
                return "\(resLabel) \(shortName) Instant"
            } else {
                return "\(shortName) Instant"
            }
        }()

        let finalSize = stream.videoSize ?? cachedItem.size
        let finalFilename = stream.filename ?? cachedItem.name

        return NuvioStream(
            url: stream.url,
            name: formattedName,
            description: stream.description,
            addonName: stream.addonName,
            subtitles: stream.subtitles,
            addonLogoURL: stream.addonLogoURL,
            infoHash: stream.infoHash,
            fileIdx: stream.effectiveFileIdx,
            sources: stream.sources,
            filename: finalFilename,
            videoSize: finalSize,
            bingeGroup: stream.bingeGroup,
            isCached: true,
            httpHeaders: stream.httpHeaders
        )
    }
}
