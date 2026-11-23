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

    /// True for a result `present` renamed after the debrid service confirmed
    /// it: a torrent marked cached whose name ends as `formattedDebridStream`
    /// writes it for this provider.
    static func isFormattedResult(_ stream: NuvioStream, provider: DebridProviderKind) -> Bool {
        guard stream.isCached == true, stream.isDebridResolvable, let name = stream.name else { return false }
        let shortName = provider.shortName.isEmpty ? "Debrid" : provider.shortName
        return name == "\(shortName) Instant" || name.hasSuffix(" \(shortName) Instant")
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

/// Settings → Connected Services → Result Management: Result rules, Max
/// results, Per resolution limit, Per quality limit and Size range. The
/// rules reorder and filter the debrid results in the source lists a viewer
/// picks from, and the limits trim what is left. Other sources are never
/// hidden or moved, and auto-select and the reload after a failed link rank
/// every source.
struct DebridResultLimits {
    static let maxResultChoices = [0, 5, 10, 20, 50]
    static let perGroupChoices = [0, 1, 2, 3, 5]
    /// "min-max" in GB, 0 for no bound, as the other apps offer them.
    static let anySize = "Any"
    static let sizeRanges = [anySize, "0-5", "0-10", "5-20", "10-50", "20-100"]

    let isDebridEnabled: Bool
    let maxResults: Int
    let maxPerResolution: Int
    let maxPerQuality: Int
    let sizeMinGB: Int
    let sizeMaxGB: Int
    /// The preferred, required and excluded values (see `DebridResultRules`).
    let rules: DebridResultRules

    init(settings: UserDefaults) {
        isDebridEnabled = DebridResolver(store: settings).isEnabled
        maxResults = max(settings.integer(forKey: SettingsKey.debridMaxResults), 0)
        maxPerResolution = max(settings.integer(forKey: SettingsKey.debridMaxPerResolution), 0)
        maxPerQuality = max(settings.integer(forKey: SettingsKey.debridMaxPerQuality), 0)
        let range = settings.string(forKey: SettingsKey.debridSizeRange) ?? Self.anySize
        let bounds = Self.sizeRanges.contains(range) ? range.split(separator: "-").compactMap { Int($0) } : []
        sizeMinGB = bounds.count == 2 ? bounds[0] : 0
        sizeMaxGB = bounds.count == 2 ? bounds[1] : 0
        rules = DebridResultRules.load(settings: settings)
    }

    /// False with the defaults, when every result is shown.
    var isActive: Bool {
        isDebridEnabled
            && (maxResults > 0 || maxPerResolution > 0 || maxPerQuality > 0 || sizeMinGB > 0 || sizeMaxGB > 0
                || !rules.isEmpty)
    }

    /// A torrent the debrid service resolves, or a link marked as cached there.
    static func isDebridResult(_ stream: NuvioStream) -> Bool {
        guard !stream.isNotPlayable else { return false }
        return stream.isDebridResolvable
            || stream.isCached == true
            || StreamQualityTags.parse(stream: stream).isCached
    }

    /// `sorted` with the debrid results that have a preferred value moved
    /// ahead of the other debrid results, and without the ones the rules
    /// hide or the limits cut. Should that leave nothing to play, `sorted`
    /// is returned as it came.
    func applied(to sorted: [NuvioStream]) -> [NuvioStream] {
        guard isActive else { return sorted }
        let ordered = rules.preferredFirst(sorted, isRuled: Self.isDebridResult)
        let filtersByRule = rules.hasFilters
        let bytesPerGB: Int64 = 1_073_741_824
        var shown = 0
        var perResolution: [Int: Int] = [:]
        var perQuality: [DebridStreamQuality: Int] = [:]
        let limited = ordered.filter { stream in
            guard Self.isDebridResult(stream) else { return true }
            if filtersByRule, !rules.matches(DebridStreamFacts.facts(for: stream)) { return false }
            // A result of unknown size passes the size range.
            let size = StreamPickerListBuilder.sizeBytes(for: stream)
            if size > 0 {
                if sizeMinGB > 0, size < Int64(sizeMinGB) * bytesPerGB { return false }
                if sizeMaxGB > 0, size > Int64(sizeMaxGB) * bytesPerGB { return false }
            }
            if maxResults > 0, shown >= maxResults { return false }
            let resolution = StreamPickerListBuilder.resolution(for: stream)
            let quality = StreamPickerListBuilder.streamQuality(for: stream)
            if maxPerResolution > 0, perResolution[resolution, default: 0] >= maxPerResolution { return false }
            if maxPerQuality > 0, perQuality[quality, default: 0] >= maxPerQuality { return false }
            shown += 1
            perResolution[resolution, default: 0] += 1
            perQuality[quality, default: 0] += 1
            return true
        }
        let isPlayable: (NuvioStream) -> Bool = { !$0.isNotPlayable && $0.unavailabilityReason == nil }
        if !limited.contains(where: isPlayable), sorted.contains(where: isPlayable) {
            return sorted
        }
        return limited
    }
}
