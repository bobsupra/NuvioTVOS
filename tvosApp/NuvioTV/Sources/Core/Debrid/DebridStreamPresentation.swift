import Foundation

struct DebridStreamPresentation {
    private let store: UserDefaults

    init(store: UserDefaults = ProfileSettings.current) {
        self.store = store
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
        let service = LocalDebridService()
        let cachedMap = await service.checkCached(provider: provider, apiKey: token, hashes: hashes)

        return streams.compactMap { stream -> NuvioStream? in
            guard stream.isDebridResolvable else {
                // Direct URL stream (already resolved by add-on or direct HTTP)
                return stream
            }
            guard let infoHash = stream.effectiveInfoHash?.lowercased() else { return nil }

            if let cachedMap {
                guard let cachedItem = cachedMap[infoHash] else {
                    // Uncached torrent: filter out so user only sees instantly playable streams
                    return nil
                }
                return formattedDebridStream(stream, provider: provider, cachedItem: cachedItem)
            } else {
                // If cache check network call failed completely (e.g. offline),
                // pass through so user can still attempt click-time resolution
                return stream
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
